-- 2026-11-18 スマレジにだけある賃金の行（事業所別を含む）を、承認の流れで取り込む（設計書: docs/設計書_事業所別の賃金と交通費の取り込み_2026-11-18.md §1）
--   ① hr_wage_external_request(p_id, p_reason): 「未承認の賃金変更」(wage_external_changes, kind='new_row', open) から、
--      既存の賃金の変更申請（hr_pay_change_request＝本部確認 → 社長の最終承認）を1件作る。申請を作っただけでは賃金は変わらない。
--   ② 承認で employee_wage_settings に行が入るとき、申請の内容が控えと同じなら「スマレジ反映済み」の印で入れる（スマレジへ再送しない）。
--      同時に控えを approved で閉じる。内容が違えば何もしない（通常どおり反映待ちになる）。
--   ※ 金額違い（amount_changed）と削除（deleted）は対象外（これまでどおり手動）。
--   rollback: 2026-11-18_wage_external_request_rollback.sql

create or replace function public.hr_wage_external_request(p_id uuid, p_reason text default null, p_actor uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare e wage_external_changes%rowtype; v_actor uuid; v_res jsonb; v_payload jsonb;
begin
  v_actor := public.onboarding_resolve_actor(p_actor);
  select * into e from wage_external_changes where id = p_id for update;
  if not found then raise exception '対象が見つかりません'; end if;
  if e.status <> 'open' then raise exception 'すでに処理済みです（%）', e.status; end if;
  if e.kind <> 'new_row' then raise exception 'この種類（%）は、ここからは取り込めません。賃金カードで直接直してください', e.kind; end if;
  if e.smaregi_value is null or coalesce((e.smaregi_value ->> 'wage')::int, 0) <= 0 then raise exception 'スマレジの金額が読み取れていません'; end if;
  if e.request_id is not null and exists (select 1 from profile_change_requests q where q.id = e.request_id and q.status = 'pending') then
    raise exception 'すでに承認待ちの申請があります';
  end if;
  v_payload := jsonb_strip_nulls(jsonb_build_object('contract_id', e.contract_id, 'division', e.division, 'store_id', e.store_id,
                'wage', (e.smaregi_value ->> 'wage')::int, 'holiday_wage', nullif(e.smaregi_value ->> 'holiday_wage', '')::int, 'from_external', e.id));
  v_res := public.hr_pay_change_request(e.user_id, 'wage', v_payload, e.effective_date, null,
             coalesce(nullif(trim(coalesce(p_reason, '')), ''), 'スマレジで直接追加された賃金の行を、管理システムへ取り込む申請'), v_actor);
  update wage_external_changes set request_id = (v_res ->> 'request_id')::uuid where id = e.id;
  return v_res;
end $$;
revoke all on function public.hr_wage_external_request(uuid, text, uuid) from public, anon;
grant execute on function public.hr_wage_external_request(uuid, text, uuid) to authenticated, service_role;

create or replace function public.wage_external_link_before_insert() returns trigger language plpgsql security definer set search_path to 'public' as $$
declare e wage_external_changes%rowtype;
begin
  select * into e from wage_external_changes x
   where x.status = 'open' and x.kind = 'new_row' and x.request_id is not null
     and x.user_id = new.user_id and x.contract_id = new.contract_id and x.division = new.division
     and x.store_id is not distinct from new.store_id and x.effective_date = new.effective_date
     and (x.smaregi_value ->> 'wage')::int = new.wage
     and nullif(x.smaregi_value ->> 'holiday_wage', '')::int is not distinct from new.holiday_wage
   limit 1;
  if found and e.smaregi_wage_apply_id is not null then
    new.sync_status := 'synced'; new.sync_error := null; new.smaregi_wage_apply_id := e.smaregi_wage_apply_id; new.synced_at := now();
    update wage_external_changes set status = 'approved', resolved_at = now(), resolve_note = '承認の流れで取り込み（スマレジには再送していません）' where id = e.id;
  end if;
  return new;
end $$;
drop trigger if exists wage_external_link_before_insert on public.employee_wage_settings;
create trigger wage_external_link_before_insert before insert on public.employee_wage_settings for each row execute function public.wage_external_link_before_insert();
