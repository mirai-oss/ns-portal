-- 2026-11-18 スマレジに合わせる（金額違い・削除）。設計書 §1 の続き。直前の 2026-11-18_wage_external_request.sql を前提にする
--   ① hr_wage_external_request: 追加行（new_row）に加えて、金額違い（amount_changed）も、承認の流れで「スマレジの金額に直す」申請を作れるようにする
--   ② 承認で金額が直るとき（hr_save_wage の更新）、内容がスマレジの値と同じなら「反映済み」に戻す（スマレジへ再送しない）。AFTER トリガ
--   ③ hr_wage_external_align_deleted(p_id, p_reason): スマレジ側で削除された行に、管理システムを合わせる（行を削除）。
--      スマレジには何も送らない（もう消えている）。本部・社長・マスターのみ・理由が必須・控えは approved で閉じる・変更の記録（employee_change_events）は既存のトリガが残す
--   rollback: 2026-11-18_wage_external_align_rollback.sql

create or replace function public.hr_wage_external_request(p_id uuid, p_reason text default null, p_actor uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare e wage_external_changes%rowtype; v_actor uuid; v_res jsonb; v_payload jsonb;
begin
  v_actor := public.onboarding_resolve_actor(p_actor);
  select * into e from wage_external_changes where id = p_id for update;
  if not found then raise exception '対象が見つかりません'; end if;
  if e.status <> 'open' then raise exception 'すでに処理済みです（%）', e.status; end if;
  if e.kind not in ('new_row', 'amount_changed') then raise exception 'この種類（%）は、ここからは取り込めません', e.kind; end if;
  if e.smaregi_value is null or coalesce((e.smaregi_value ->> 'wage')::int, 0) <= 0 then raise exception 'スマレジの金額が読み取れていません'; end if;
  if e.request_id is not null and exists (select 1 from profile_change_requests q where q.id = e.request_id and q.status = 'pending') then
    raise exception 'すでに承認待ちの申請があります';
  end if;
  v_payload := jsonb_strip_nulls(jsonb_build_object('contract_id', e.contract_id, 'division', e.division, 'store_id', e.store_id,
                'wage', (e.smaregi_value ->> 'wage')::int, 'holiday_wage', nullif(e.smaregi_value ->> 'holiday_wage', '')::int, 'from_external', e.id));
  v_res := public.hr_pay_change_request(e.user_id, 'wage', v_payload, e.effective_date, null,
             coalesce(nullif(trim(coalesce(p_reason, '')), ''), case when e.kind = 'amount_changed' then 'スマレジの金額に合わせる申請（スマレジで直接変更された金額）' else 'スマレジで直接追加された賃金の行を、管理システムへ取り込む申請' end), v_actor);
  update wage_external_changes set request_id = (v_res ->> 'request_id')::uuid where id = e.id;
  return v_res;
end $$;

create or replace function public.wage_external_link_after_write() returns trigger language plpgsql security definer set search_path to 'public' as $$
declare e wage_external_changes%rowtype;
begin
  if new.sync_status is distinct from 'pending' then return null; end if;
  select * into e from wage_external_changes x
   where x.status = 'open' and x.kind = 'amount_changed' and x.request_id is not null
     and x.user_id = new.user_id and x.contract_id = new.contract_id and x.division = new.division
     and x.store_id is not distinct from new.store_id and x.effective_date = new.effective_date
     and (x.smaregi_value ->> 'wage')::int = new.wage
     and nullif(x.smaregi_value ->> 'holiday_wage', '')::int is not distinct from new.holiday_wage
   limit 1;
  if found then
    update employee_wage_settings set sync_status = 'synced', sync_error = null, synced_at = now() where id = new.id;
    update wage_external_changes set status = 'approved', resolved_at = now(), resolve_note = '承認の流れで、スマレジの金額に合わせました（スマレジには再送していません）' where id = e.id;
  end if;
  return null;
end $$;
drop trigger if exists wage_external_link_after_write on public.employee_wage_settings;
create trigger wage_external_link_after_write after insert or update on public.employee_wage_settings for each row execute function public.wage_external_link_after_write();

create or replace function public.hr_wage_external_align_deleted(p_id uuid, p_reason text, p_actor uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare e wage_external_changes%rowtype; v_actor uuid; w employee_wage_settings%rowtype;
begin
  v_actor := public.onboarding_resolve_actor(p_actor);
  if nullif(trim(coalesce(p_reason, '')), '') is null then raise exception '理由を入れてください'; end if;
  select * into e from wage_external_changes where id = p_id for update;
  if not found then raise exception '対象が見つかりません'; end if;
  if e.status <> 'open' or e.kind <> 'deleted' then raise exception 'スマレジで削除された行の控え（未処理）だけが対象です'; end if;
  select * into w from employee_wage_settings s where s.user_id = e.user_id and s.contract_id = e.contract_id and s.division = e.division
     and s.store_id is not distinct from e.store_id and s.effective_date = e.effective_date for update;
  if not found then raise exception '管理システム側の行がすでにありません'; end if;
  if (e.system_value ->> 'wage')::int is distinct from w.wage then raise exception '管理システムの金額が、控えを作ったときから変わっています。もう一度照合してください'; end if;
  perform set_config('employee_change.via_approval', e.id::text, true);
  delete from employee_wage_settings where id = w.id;
  perform set_config('employee_change.via_approval', '', true);
  update wage_external_changes set status = 'approved', resolved_at = now(), resolved_by = v_actor,
         resolve_note = '管理システムの行を、スマレジの削除に合わせて削除（スマレジには何も送っていません）: ' || trim(p_reason) where id = e.id;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.hr_wage_external_align_deleted(uuid, text, uuid) from public, anon;
grant execute on function public.hr_wage_external_align_deleted(uuid, text, uuid) to authenticated, service_role;
