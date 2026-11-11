-- 給与確定前の安全確認と保留（開発 2・2026-11-12）: 未承認の賃金変更がある人・月を特定して、給料確定・振込データ・現金手渡しを止める
--   設計: docs/設計書_従業員情報変更の連動_2026-11-10.md §21.8・§25
--   ★ 本番未適用（開発・テストのみ承認。適用・スイッチ変更は別途承認）。戻し方: 2026-11-12_payroll_wage_guard_rollback.sql
--
--   適用しただけでは何も変わらない。動くのは、スイッチ app_settings.employee_change.payroll_wage_guard が true のときだけ（既定 false）。
--   前提: 開発 1 のスイッチ B（wage_import_hold）が true で、スマレジの賃金の照合が済んでいること（照合の記録が無い・古いときは、安全側に止める）。
--
--   止めるもの（スイッチが true のとき）:
--     ・給料確定（法人×月）: その法人に「全体停止の理由」があるか、保留の人が 1 人でもいれば、確定できない
--       （給料確定は法人×月の単位で、人ごとに分けて確定する作りが無いため。保留を解く＝是正する、または社長の承認による例外解除）
--     ・振込データ: 保留の人を外す（既存の「口座変更の承認待ち」の除外と同じ仕組みに、理由を足して載せる）。全体停止の法人があれば、その月の出力は記録できない
--     ・現金手渡し: 保留の人の確認・サイン・完了を受け付けない
--   例外の解除: 社長（役割 CEO）の承認が必須。本部の人は申請（理由つき）までしかできない。マスター権限では代用できない。申請・承認・却下・取り下げを履歴に残す
--   止められないもの: スマレジ側の給与計算・Web 給与明細・管理システムを通らない振込（設計書 §21.8）

update app_settings set value = '{"payroll_wage_guard": false, "wage_guard_max_age_hours": 24, "wage_guard_unread_ratio": 0.2}'::jsonb || value where key = 'employee_change';

-- ============ 1. 照合の記録（スマレジの賃金を最後まで読めたか・いつ・だれを読めなかったか） ============
create table if not exists wage_reconcile_runs (
  id            uuid primary key default gen_random_uuid(),
  contract_id   text not null,
  source        text,
  hold_enabled  boolean not null default false,     -- 保留（スイッチ B）が有効な状態で行った照合か（有効でない照合は、関所の判定に使わない）
  started_at    timestamptz not null default now(),
  finished_at   timestamptz,
  total         integer not null default 0,         -- 対象の人数
  processed     integer not null default 0,         -- 処理した人数
  persons       integer not null default 0,         -- スマレジを読めた人数
  unread_users  uuid[] not null default '{}',       -- 読めなかった人
  unread_count  integer not null default 0,
  unmapped_rows integer not null default 0,         -- 管理システムの店舗に対応しない行（だれの・どこの賃金か特定できない）
  ok            boolean                              -- 最後まで終わったか
);
create index if not exists wage_reconcile_runs_idx on wage_reconcile_runs (contract_id, finished_at desc);
alter table wage_reconcile_runs enable row level security;
drop policy if exists wage_reconcile_runs_read on wage_reconcile_runs;
create policy wage_reconcile_runs_read on wage_reconcile_runs for select using (hq_can_manage() or invoice_can_access());

-- Edge Function（smaregi-sync の一括の照合）が、1 回の呼び出しごとに記録する。書けるのはサービスだけ
create or replace function hr_wage_reconcile_log(p_contract text, p_offset integer, p_total integer, p_processed integer, p_persons integer, p_unread uuid[], p_unmapped integer, p_done boolean, p_hold boolean, p_source text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not onboarding_is_service() then raise exception '権限がありません'; end if;
  if coalesce(p_offset, 0) > 0 then
    select id into v_id from wage_reconcile_runs where contract_id = p_contract and finished_at is null and started_at > now() - interval '1 hour' order by started_at desc limit 1;
  end if;
  if v_id is null then
    -- 途中から始まった記録（先頭を読んでいない）は、最後まで終わっても ok にしない
    insert into wage_reconcile_runs(contract_id, source, hold_enabled, total, ok) values (p_contract, p_source, coalesce(p_hold, false), coalesce(p_total, 0), case when coalesce(p_offset, 0) > 0 then false end) returning id into v_id;
  end if;
  update wage_reconcile_runs set total = coalesce(p_total, total), processed = processed + coalesce(p_processed, 0), persons = persons + coalesce(p_persons, 0),
         unread_users = unread_users || coalesce(p_unread, '{}'), unread_count = unread_count + coalesce(cardinality(p_unread), 0), unmapped_rows = unmapped_rows + coalesce(p_unmapped, 0),
         hold_enabled = hold_enabled and coalesce(p_hold, false),
         finished_at = case when p_done then now() else finished_at end,
         ok = case when p_done then (ok is distinct from false) and processed + coalesce(p_processed, 0) >= coalesce(p_total, total) else ok end
   where id = v_id;
  return v_id;
end $$;

-- ============ 2. 例外の解除（社長の承認が必須） ============
create table if not exists payroll_wage_hold_releases (
  id             uuid primary key default gen_random_uuid(),
  scope          text not null check (scope in ('person', 'corp')),   -- person＝その人のその月だけ／corp＝その法人のその月の「全体停止」だけ
  year_month     text not null check (year_month ~ '^\d{4}-\d{2}$'),
  corporation_id uuid not null,
  user_id        uuid,
  reason         text not null,
  hold_snapshot  jsonb,                 -- 申請した時点の、止まっている理由
  requested_by   uuid not null,
  requested_at   timestamptz not null default now(),
  status         text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'cancelled')),
  decided_by     uuid,
  decided_at     timestamptz,
  decide_note    text,
  check ((scope = 'person') = (user_id is not null))
);
create unique index if not exists payroll_wage_hold_releases_live_uq on payroll_wage_hold_releases
  (scope, year_month, corporation_id, coalesce(user_id, '00000000-0000-0000-0000-000000000000'::uuid)) where status in ('pending', 'approved');
create table if not exists payroll_wage_hold_release_log (
  id         uuid primary key default gen_random_uuid(),
  release_id uuid not null references payroll_wage_hold_releases(id),
  action     text not null check (action in ('request', 'approve', 'reject', 'cancel')),
  actor_id   uuid,
  actor_role text,
  comment    text,
  at         timestamptz not null default clock_timestamp()
);
alter table payroll_wage_hold_releases enable row level security;
alter table payroll_wage_hold_release_log enable row level security;
drop policy if exists payroll_wage_hold_releases_read on payroll_wage_hold_releases;
create policy payroll_wage_hold_releases_read on payroll_wage_hold_releases for select using (hq_can_manage() or invoice_can_access());
drop policy if exists payroll_wage_hold_release_log_read on payroll_wage_hold_release_log;
create policy payroll_wage_hold_release_log_read on payroll_wage_hold_release_log for select using (hq_can_manage() or invoice_can_access());
-- 履歴は書き換え・削除できない
create or replace function payroll_wage_hold_release_log_guard() returns trigger language plpgsql as $$
begin raise exception '例外解除の履歴は、書き換え・削除できません'; end $$;
drop trigger if exists payroll_wage_hold_release_log_guard on payroll_wage_hold_release_log;
create trigger payroll_wage_hold_release_log_guard before update or delete on payroll_wage_hold_release_log for each row execute function payroll_wage_hold_release_log_guard();

-- 振込の除外の記録に、理由を持たせる（既存の行は「口座変更の承認待ち」）
alter table payroll_transfer_holds add column if not exists reasons text[] not null default '{bank_change}';

-- ============ 3. 判定（ここ 1 か所） ============
create or replace function payroll_wage_guard_enabled() returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select (value ->> 'payroll_wage_guard')::boolean from app_settings where key = 'employee_change'), false)
$$;
create or replace function payroll_wage_guard_label(p_code text) returns text language sql immutable as $$
  select case p_code
    when 'hold_switch_off'   then 'スマレジにだけある賃金の行を保留する設定が有効になっていないため、照合の結果を使えません'
    when 'reconcile_missing' then 'スマレジの賃金の照合が、まだ 1 回も済んでいません'
    when 'reconcile_failed'  then '直近の照合が、最後まで終わっていません（失敗・中断）'
    when 'reconcile_stale'   then '照合の結果が古くなっています（期限切れ）'
    when 'too_many_unread'   then '照合で、スマレジの賃金を読めなかった人が多すぎます'
    when 'unmapped'          then '管理システムの店舗に対応しない賃金の行があります（だれの・どの店舗の賃金か特定できません）'
    when 'external_open'     then 'スマレジで直接変更された賃金が未承認です'
    when 'request_pending'   then '賃金変更の申請が承認待ちです'
    when 'unread'            then '照合で、この人のスマレジの賃金を読めませんでした'
    else p_code end
$$;

--   返すもの: enabled／stop_all（その法人のその月を全体で止めるか）／stop_reasons／holds（人ごとの保留と理由）／released（社長の承認で例外解除した人）／reconcile（照合の記録）
--   対象の月: 賃金の行の適用開始日が、その月の末日以前（行の削除は、月に関係なく対象）
create or replace function payroll_wage_guard_i(p_year_month text, p_corp uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_cfg jsonb; v_hold_sw boolean; v_age numeric; v_ratio numeric; v_first date; v_end date; c record; r wage_reconcile_runs%rowtype;
  v_stop jsonb := '[]'::jsonb; v_unread uuid[] := '{}'; v_contracts text[]; v_runs jsonb := '[]'::jsonb; v_rel uuid[]; v_corp_rel boolean; v_holds jsonb; v_released jsonb; v_code text;
begin
  select value into v_cfg from app_settings where key = 'employee_change';
  if not coalesce((v_cfg ->> 'payroll_wage_guard')::boolean, false) then
    return jsonb_build_object('enabled', false, 'stop_all', false, 'stop_reasons', '[]'::jsonb, 'holds', '[]'::jsonb, 'released', '[]'::jsonb);
  end if;
  if p_year_month is null or p_year_month !~ '^\d{4}-\d{2}$' then raise exception '月（YYYY-MM）が不正です'; end if;
  v_first := to_date(p_year_month || '-01', 'YYYY-MM-DD'); v_end := (v_first + interval '1 month' - interval '1 day')::date;
  v_hold_sw := coalesce((v_cfg ->> 'wage_import_hold')::boolean, false);
  v_age := coalesce((v_cfg ->> 'wage_guard_max_age_hours')::numeric, 24); v_ratio := coalesce((v_cfg ->> 'wage_guard_unread_ratio')::numeric, 0.2);
  select coalesce(array_agg(sc.contract_id), '{}') into v_contracts from smaregi_contracts sc where sc.corporation_id = p_corp and coalesce(sc.is_active, true);
  if cardinality(v_contracts) = 0 then   -- スマレジの契約が無い法人: 関所の対象外
    return jsonb_build_object('enabled', true, 'applicable', false, 'stop_all', false, 'stop_reasons', '[]'::jsonb, 'holds', '[]'::jsonb, 'released', '[]'::jsonb);
  end if;
  for c in select sc.contract_id, sc.label from smaregi_contracts sc where sc.contract_id = any(v_contracts) order by sc.contract_id loop
    r := null;
    select * into r from wage_reconcile_runs w where w.contract_id = c.contract_id and w.hold_enabled and w.finished_at is not null order by w.finished_at desc limit 1;
    v_runs := v_runs || jsonb_build_object('contract_id', c.contract_id, 'label', c.label, 'finished_at', r.finished_at, 'total', r.total, 'unread', r.unread_count, 'ok', r.ok);
    v_code := case
      when not v_hold_sw then 'hold_switch_off'
      when r.id is null then 'reconcile_missing'
      when r.ok is not true then 'reconcile_failed'
      when r.finished_at < now() - (v_age || ' hours')::interval then 'reconcile_stale'
      when r.total > 0 and r.unread_count::numeric / r.total > v_ratio then 'too_many_unread'
      when r.unmapped_rows > 0 then 'unmapped' end;
    if v_code is not null then
      v_stop := v_stop || jsonb_build_object('code', v_code, 'contract_id', c.contract_id, 'contract_label', c.label, 'label', payroll_wage_guard_label(v_code));
    else
      v_unread := v_unread || r.unread_users;   -- 少数の読めなかった人は、その人だけを保留
    end if;
  end loop;
  select coalesce(array_agg(x.user_id), '{}') into v_rel from payroll_wage_hold_releases x where x.scope = 'person' and x.year_month = p_year_month and x.corporation_id = p_corp and x.status = 'approved';
  v_corp_rel := exists (select 1 from payroll_wage_hold_releases x where x.scope = 'corp' and x.year_month = p_year_month and x.corporation_id = p_corp and x.status = 'approved');
  with h as (
    select e.user_id, 'external_open'::text reason from wage_external_changes e
     where e.status = 'open' and e.contract_id = any(v_contracts) and (e.kind = 'deleted' or e.effective_date <= v_end)
    union
    select q.user_id, 'request_pending' from profile_change_requests q
     where q.field = 'wage' and q.status = 'pending' and (q.effective_date is null or q.effective_date <= v_end)
       and exists (select 1 from employee_smaregi_links l where l.user_id = q.user_id and l.contract_id = any(v_contracts) and (l.effective_to is null or l.effective_to >= v_first))
    union
    select u, 'unread' from unnest(v_unread) u),
  g as (select h.user_id, jsonb_agg(distinct h.reason) reasons from h group by h.user_id)
  select coalesce(jsonb_agg(jsonb_build_object('user_id', g.user_id, 'reasons', g.reasons) order by g.user_id) filter (where not (g.user_id = any(v_rel))), '[]'::jsonb),
         coalesce(jsonb_agg(jsonb_build_object('user_id', g.user_id, 'reasons', g.reasons) order by g.user_id) filter (where g.user_id = any(v_rel)), '[]'::jsonb)
    into v_holds, v_released from g;
  return jsonb_build_object('enabled', true, 'applicable', true, 'year_month', p_year_month, 'corporation_id', p_corp,
    'stop_all', jsonb_array_length(v_stop) > 0 and not v_corp_rel, 'stop_released', jsonb_array_length(v_stop) > 0 and v_corp_rel,
    'stop_reasons', v_stop, 'holds', coalesce(v_holds, '[]'::jsonb), 'released', coalesce(v_released, '[]'::jsonb), 'reconcile', v_runs);
end $$;

-- その月に保留の人（全部の法人ぶん）
create or replace function payroll_wage_holds(p_year_month text)
returns table(user_id uuid, reasons text[]) language sql stable security definer set search_path = public as $$
  select x.user_id, array_agg(distinct x.reason order by x.reason)
    from (select (h ->> 'user_id')::uuid user_id, jsonb_array_elements_text(h -> 'reasons') reason
            from (select distinct sc.corporation_id from smaregi_contracts sc where sc.corporation_id is not null and coalesce(sc.is_active, true)) c,
                 jsonb_array_elements(payroll_wage_guard_i(p_year_month, c.corporation_id) -> 'holds') h
           where payroll_wage_guard_enabled()) x
   group by x.user_id
$$;
-- その月に全体で止めている法人（その月の給与データがある法人だけ）
create or replace function payroll_wage_stop(p_year_month text)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('corporation_id', c.corporation_id, 'corp_name', (select name from corporations k where k.id = c.corporation_id), 'reasons', g -> 'stop_reasons') order by c.corporation_id), '[]'::jsonb)
    from (select distinct sc.corporation_id from smaregi_contracts sc where sc.corporation_id is not null and coalesce(sc.is_active, true)
             and exists (select 1 from sf_payroll_sync sp where sp.year_month = p_year_month and sp.contract_id = sc.contract_id)) c,
         lateral payroll_wage_guard_i(p_year_month, c.corporation_id) g
   where payroll_wage_guard_enabled() and (g ->> 'stop_all')::boolean
$$;
create or replace function payroll_wage_guard_summary(p_year_month text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('enabled', payroll_wage_guard_enabled(), 'stop', payroll_wage_stop(p_year_month), 'hold_count', (select count(*) from payroll_wage_holds(p_year_month)))
$$;
create or replace function payroll_wage_stop_text(p_stop jsonb) returns text language sql immutable as $$
  select string_agg(coalesce(s ->> 'corp_name', '') || case when s ? 'corp_name' then ': ' else '' end ||
           (select string_agg(distinct coalesce(x ->> 'label', x ->> 'code'), '／') from jsonb_array_elements(coalesce(s -> 'reasons', '[]'::jsonb)) x), '　')
    from jsonb_array_elements(coalesce(p_stop, '[]'::jsonb)) s
$$;

-- ============ 4. 振込の除外の理由（文言）と、除外の記録の更新 ============
create or replace function pay_transfer_hold_reason_label(p_reasons text[]) returns text language sql immutable as $$
  select case when 'wage_unapproved' = any(p_reasons) and 'bank_change' = any(p_reasons) then '口座変更の承認待ち・未承認の賃金変更'
              when 'wage_unapproved' = any(p_reasons) then '未承認の賃金変更' else '口座変更の承認待ち' end
$$;
create or replace function pay_transfer_hold_reason_text(p_reasons text[]) returns text language sql immutable as $$
  select case when 'wage_unapproved' = any(p_reasons) and 'bank_change' = any(p_reasons) then '口座変更の申請が承認待ち・未承認の賃金変更があったため（振込先と金額が確定していない）'
              when 'wage_unapproved' = any(p_reasons) then '未承認の賃金変更があったため（金額が確定していない）'
              else '口座変更の申請が承認待ちだったため（振込先が確定していない）' end
$$;
-- 出力の記録の直後: 今回外した人の除外の記録に理由を付ける。賃金が理由の人は「除外中」
create or replace function pay_transfer_holds_wage_fix(p_year_month text, p_users uuid[])
returns void language plpgsql security definer set search_path = public as $$
begin
  update payroll_transfer_holds h set
         reasons = case when x.wage and x.bank then '{bank_change,wage_unapproved}'::text[] when x.wage then '{wage_unapproved}'::text[] else '{bank_change}'::text[] end,
         status = case when x.wage then 'held' else h.status end,
         resolved_at = case when x.wage then null else h.resolved_at end
    from (select u.id,
                 exists (select 1 from payroll_wage_holds(p_year_month) w where w.user_id = u.id) wage,
                 exists (select 1 from profile_change_requests q where q.user_id = u.id and q.field = 'bank_account' and q.status = 'pending') bank
            from unnest(coalesce(p_users, '{}')) u(id)) x
   where h.year_month = p_year_month and h.user_id = x.id and h.status <> 'done';
end $$;
-- 振込の準備のとき: 賃金の保留が解けた人を「その人の分が未出力」に進める（口座変更の承認待ちが残っていれば、除外中のまま）
create or replace function pay_transfer_holds_wage_refresh(p_year_month text)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  update payroll_transfer_holds h set
         status = case when b.bank then 'held' else 'ready' end,
         reasons = case when b.bank then '{bank_change}'::text[] else h.reasons end,
         resolved_at = case when b.bank then null else now() end
    from (select h2.user_id, exists (select 1 from profile_change_requests q where q.user_id = h2.user_id and q.field = 'bank_account' and q.status = 'pending') bank
            from payroll_transfer_holds h2 where h2.year_month = p_year_month) b
   where h.year_month = p_year_month and h.user_id = b.user_id and h.status = 'held' and 'wage_unapproved' = any(h.reasons)
     and not exists (select 1 from payroll_wage_holds(p_year_month) w where w.user_id = h.user_id);
  get diagnostics n = row_count;
  return n;
end $$;

-- ============ 5. 関所（給料確定・振込データ・現金手渡し） ============
-- 給料確定: その法人に全体停止の理由があるか、保留の人がいれば、確定の印を付けられない
create or replace function payroll_finalized_wage_guard() returns trigger language plpgsql security definer set search_path = public as $$
declare g jsonb; v_names text; n integer;
begin
  if not payroll_wage_guard_enabled() then return new; end if;
  if exists (select 1 from payroll_finalized f where f.year_month = new.year_month and f.corporation_id = new.corporation_id) then return new; end if;   -- 既に確定済み（押し直し）
  g := payroll_wage_guard_i(new.year_month, new.corporation_id);
  if (g ->> 'stop_all')::boolean then
    raise exception '% 月分の給料確定は停止中です。%。スマレジの賃金の照合（賃金の取り込み）を実行してから、もう一度確定してください。照合できない事情があるときは、社長の承認による例外解除が必要です',
      new.year_month, (select string_agg(distinct coalesce(x ->> 'label', x ->> 'code'), '／') from jsonb_array_elements(g -> 'stop_reasons') x);
  end if;
  n := jsonb_array_length(g -> 'holds');
  if n > 0 then
    select string_agg(coalesce(u.name, '—') || 'さん', '、') into v_names from (select (h ->> 'user_id')::uuid id from jsonb_array_elements(g -> 'holds') h limit 5) x left join users u on u.id = x.id;
    raise exception '% 月分の給料確定は停止中です。未承認の賃金変更がある人が % 人います（%）。従業員ページで確認・是正してください。是正できない事情があるときは、社長の承認による例外解除が必要です',
      new.year_month, n, v_names || case when n > 5 then ' ほか' else '' end;
  end if;
  return new;
end $$;
drop trigger if exists payroll_finalized_wage_guard on payroll_finalized;
create trigger payroll_finalized_wage_guard before insert on payroll_finalized for each row execute function payroll_finalized_wage_guard();

-- 振込データ: 正しい手順の出力（出力の印つき）を記録するとき。全体停止の法人があれば記録できない＝画面は CSV を渡さない。保留の人が除外されていない出力も記録できない
create or replace function payroll_transfer_schedule_wage_guard() returns trigger language plpgsql security definer set search_path = public as $$
declare v_stop jsonb; v_holds uuid[]; v_names text;
begin
  if coalesce(current_setting('employee_change.schedule_internal', true), '') <> '' then return new; end if;
  if not payroll_wage_guard_enabled() then return new; end if;
  if not (new.export_ok is true and new.export_token is not null and (tg_op = 'INSERT' or new.export_token is distinct from old.export_token)) then return new; end if;
  v_stop := payroll_wage_stop(new.year_month);
  if jsonb_array_length(v_stop) > 0 then
    raise exception '% 月分の振込データは出力できません（停止中）。%。スマレジの賃金の照合を実行してからやり直してください。照合できない事情があるときは、社長の承認による例外解除が必要です。この CSV は使わないでください', new.year_month, payroll_wage_stop_text(v_stop);
  end if;
  select t.hold_users into v_holds from payroll_transfer_export_tokens t where t.token = new.export_token;
  select string_agg(coalesce((select name from users u where u.id = h.user_id), '—') || 'さん', '、') into v_names
    from pay_transfer_pending_holds(new.year_month) h where h.request_id is null and not (h.user_id = any(coalesce(v_holds, '{}')));
  if v_names is not null then
    raise exception '% 月分の振込データは出力できません。未承認の賃金変更がある人（%）が除外されていません。画面を再読み込みしてからやり直してください。この CSV は使わないでください', new.year_month, v_names;
  end if;
  return new;
end $$;
drop trigger if exists payroll_transfer_schedule_wage_guard on payroll_transfer_schedule;
create trigger payroll_transfer_schedule_wage_guard before insert or update on payroll_transfer_schedule for each row execute function payroll_transfer_schedule_wage_guard();

-- 現金手渡し: 保留の人（または全体停止の法人）の、金額確認・引き出し・サイン・完了を受け付けない。取消・やり直しのための更新は通す
create or replace function cash_handoff_wage_guard() returns trigger language plpgsql security definer set search_path = public as $$
declare g jsonb; v_corp uuid; v_progress boolean;
begin
  if not payroll_wage_guard_enabled() then return new; end if;
  v_progress := tg_op = 'INSERT'
     or (new.payer_checked_at is not null and old.payer_checked_at is null) or (new.receiver_checked_at is not null and old.receiver_checked_at is null)
     or (new.completed_at is not null and old.completed_at is null) or (new.amount_confirmed and not old.amount_confirmed)
     or (new.withdrawn_at is not null and old.withdrawn_at is null);
  if not v_progress then return new; end if;
  select sc.corporation_id into v_corp from smaregi_contracts sc where sc.contract_id = new.contract_id;
  if v_corp is null then return new; end if;
  g := payroll_wage_guard_i(new.year_month, v_corp);
  if (g ->> 'stop_all')::boolean then
    raise exception '% 月分の現金手渡しは停止中です（賃金の照合が済んでいません）。本部に確認してください', new.year_month;
  end if;
  if exists (select 1 from jsonb_array_elements(g -> 'holds') h where (h ->> 'user_id')::uuid = new.user_id) then
    raise exception 'この人の % 月分の現金手渡しは保留中です（未承認の賃金変更があります）。本部に確認してください', new.year_month;
  end if;
  return new;
end $$;
drop trigger if exists cash_handoff_wage_guard on sf_cash_handoff_signatures;
create trigger cash_handoff_wage_guard before insert or update on sf_cash_handoff_signatures for each row execute function cash_handoff_wage_guard();

-- 現金手渡しの画面用: 保留中の人（理由の中身・金額は返さない）
create or replace function cash_handoff_wage_holds(p_year_month text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO', 'HQ', 'TENCHO', 'TEAM'))) then raise exception '権限がありません'; end if;
  return jsonb_build_object('enabled', payroll_wage_guard_enabled(),
    'hold_user_ids', coalesce((select jsonb_agg(w.user_id) from payroll_wage_holds(p_year_month) w), '[]'::jsonb),
    'stop_contract_ids', coalesce((select jsonb_agg(sc.contract_id) from jsonb_array_elements(payroll_wage_stop(p_year_month)) s join smaregi_contracts sc on sc.corporation_id = (s ->> 'corporation_id')::uuid), '[]'::jsonb));
end $$;

-- ============ 6. 画面から呼ぶもの: 状況の表示と、例外解除の申請・承認 ============
create or replace function hr_payroll_wage_guard_status(p_year_month text, p_corp_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not (hq_can_manage() or invoice_can_access() or onboarding_is_service()) then raise exception '権限がありません'; end if;
  return jsonb_build_object('enabled', payroll_wage_guard_enabled(), 'year_month', p_year_month,
    'corporations', coalesce((select jsonb_agg(
        g.j || jsonb_build_object('corp_name', (select name from corporations k where k.id = c.corporation_id),
          'holds', coalesce((select jsonb_agg(h || jsonb_build_object('user_name', (select name from users u where u.id = (h ->> 'user_id')::uuid),
                     'reason_labels', (select jsonb_agg(payroll_wage_guard_label(x)) from jsonb_array_elements_text(h -> 'reasons') x))) from jsonb_array_elements(g.j -> 'holds') h), '[]'::jsonb),
          'released', coalesce((select jsonb_agg(h || jsonb_build_object('user_name', (select name from users u where u.id = (h ->> 'user_id')::uuid))) from jsonb_array_elements(g.j -> 'released') h), '[]'::jsonb),
          'releases', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'scope', x.scope, 'user_id', x.user_id, 'user_name', (select name from users u where u.id = x.user_id), 'reason', x.reason, 'status', x.status,
                     'requested_by_name', (select name from users u where u.id = x.requested_by), 'requested_at', x.requested_at,
                     'decided_by_name', (select name from users u where u.id = x.decided_by), 'decided_at', x.decided_at, 'decide_note', x.decide_note) order by x.requested_at desc)
                   from payroll_wage_hold_releases x where x.year_month = p_year_month and x.corporation_id = c.corporation_id), '[]'::jsonb)) order by c.corporation_id)
      from (select distinct sc.corporation_id from smaregi_contracts sc where sc.corporation_id is not null and coalesce(sc.is_active, true) and (p_corp_id is null or sc.corporation_id = p_corp_id)) c,
           lateral (select payroll_wage_guard_i(p_year_month, c.corporation_id) j) g), '[]'::jsonb));
end $$;

-- 例外解除の申請（本部・社長・マスター）。申請しただけでは解除されない
create or replace function hr_payroll_wage_hold_release_request(p_year_month text, p_corp_id uuid, p_user uuid, p_reason text, p_actor uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_actor uuid; g jsonb; v_id uuid; v_scope text := case when p_user is null then 'corp' else 'person' end; v_snap jsonb;
begin
  v_actor := onboarding_resolve_actor(p_actor);
  if not payroll_wage_guard_enabled() then raise exception '関所が無効のため、例外解除の申請は不要です'; end if;
  if length(btrim(coalesce(p_reason, ''))) < 5 then raise exception '理由を入力してください（5 文字以上）'; end if;
  if length(p_reason) > 500 then raise exception '理由は 500 文字までです'; end if;
  g := payroll_wage_guard_i(p_year_month, p_corp_id);
  if v_scope = 'corp' then
    if not (g ->> 'stop_all')::boolean then raise exception 'この法人のこの月は、全体では止まっていません'; end if;
    v_snap := g -> 'stop_reasons';
  else
    select h -> 'reasons' into v_snap from jsonb_array_elements(g -> 'holds') h where (h ->> 'user_id')::uuid = p_user;
    if v_snap is null then raise exception 'この人は、この月の保留の対象ではありません'; end if;
  end if;
  if exists (select 1 from payroll_wage_hold_releases x where x.scope = v_scope and x.year_month = p_year_month and x.corporation_id = p_corp_id and x.user_id is not distinct from p_user and x.status = 'pending') then
    raise exception '同じ内容の例外解除の申請が、すでに承認待ちです';
  end if;
  insert into payroll_wage_hold_releases(scope, year_month, corporation_id, user_id, reason, hold_snapshot, requested_by) values (v_scope, p_year_month, p_corp_id, p_user, btrim(p_reason), v_snap, v_actor) returning id into v_id;
  insert into payroll_wage_hold_release_log(release_id, action, actor_id, actor_role, comment) values (v_id, 'request', v_actor, (select role from users where id = v_actor), btrim(p_reason));
  return jsonb_build_object('ok', true, 'id', v_id, 'status', 'pending', 'message', '例外解除を申請しました。社長の承認が済むまで、保留は解除されません');
end $$;

-- 例外解除の承認・却下: 社長（役割 CEO）だけ。マスター権限では代用できない。対象が自分自身のときは不可
create or replace function hr_payroll_wage_hold_release_decide(p_release uuid, p_decision text, p_comment text default null, p_actor uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_actor uuid; x payroll_wage_hold_releases%rowtype;
begin
  if auth.uid() is not null then v_actor := auth.uid(); elsif onboarding_is_service() then v_actor := p_actor; else raise exception '認証が必要です'; end if;
  if v_actor is null then raise exception '操作者が特定できません'; end if;
  if not exists (select 1 from users u where u.id = v_actor and u.is_active and u.role = 'CEO') then raise exception '例外解除を承認・却下できるのは社長だけです（マスター権限・本部の権限では代用できません）'; end if;
  if p_decision not in ('approved', 'rejected') then raise exception '不正な操作です'; end if;
  select * into x from payroll_wage_hold_releases where id = p_release for update;
  if x.id is null then raise exception '申請が見つかりません'; end if;
  if x.status <> 'pending' then raise exception 'この申請は、すでに処理されています（%）', x.status; end if;
  if x.user_id = v_actor then raise exception '自分自身の給与の保留は、自分では解除できません'; end if;
  if p_decision = 'rejected' and length(btrim(coalesce(p_comment, ''))) < 1 then raise exception '却下の理由を入力してください'; end if;
  update payroll_wage_hold_releases set status = p_decision, decided_by = v_actor, decided_at = now(), decide_note = nullif(btrim(coalesce(p_comment, '')), '') where id = x.id;
  insert into payroll_wage_hold_release_log(release_id, action, actor_id, actor_role, comment) values (x.id, case p_decision when 'approved' then 'approve' else 'reject' end, v_actor, 'CEO', nullif(btrim(coalesce(p_comment, '')), ''));
  return jsonb_build_object('ok', true, 'id', x.id, 'status', p_decision);
end $$;

-- 例外解除の取り下げ（承認待ちのあいだ・申請した人か社長）／承認済みの解除の取り消し（社長だけ。保留に戻る）
create or replace function hr_payroll_wage_hold_release_cancel(p_release uuid, p_comment text default null, p_actor uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_actor uuid; x payroll_wage_hold_releases%rowtype; v_ceo boolean;
begin
  v_actor := onboarding_resolve_actor(p_actor);
  select * into x from payroll_wage_hold_releases where id = p_release for update;
  if x.id is null then raise exception '申請が見つかりません'; end if;
  v_ceo := exists (select 1 from users u where u.id = v_actor and u.is_active and u.role = 'CEO');
  if x.status = 'pending' then
    if not (x.requested_by = v_actor or v_ceo) then raise exception '取り下げできるのは、申請した人か社長だけです'; end if;
  elsif x.status = 'approved' then
    if not v_ceo then raise exception '承認済みの例外解除を取り消せるのは社長だけです'; end if;
  else raise exception 'この申請は、すでに処理されています（%）', x.status; end if;
  update payroll_wage_hold_releases set status = 'cancelled', decide_note = coalesce(nullif(btrim(coalesce(p_comment, '')), ''), decide_note) where id = x.id;
  insert into payroll_wage_hold_release_log(release_id, action, actor_id, actor_role, comment) values (x.id, 'cancel', v_actor, (select role from users where id = v_actor), nullif(btrim(coalesce(p_comment, '')), ''));
  return jsonb_build_object('ok', true, 'id', x.id, 'status', 'cancelled');
end $$;

revoke all on function hr_wage_reconcile_log(text, integer, integer, integer, integer, uuid[], integer, boolean, boolean, text), payroll_wage_guard_enabled(), payroll_wage_guard_i(text, uuid), payroll_wage_holds(text), payroll_wage_stop(text),
  payroll_wage_guard_summary(text), pay_transfer_holds_wage_fix(text, uuid[]), pay_transfer_holds_wage_refresh(text), payroll_finalized_wage_guard(), payroll_transfer_schedule_wage_guard(), cash_handoff_wage_guard(),
  cash_handoff_wage_holds(text), hr_payroll_wage_guard_status(text, uuid), hr_payroll_wage_hold_release_request(text, uuid, uuid, text, uuid), hr_payroll_wage_hold_release_decide(uuid, text, text, uuid), hr_payroll_wage_hold_release_cancel(uuid, text, uuid)
  from public, anon, authenticated;
grant execute on function hr_wage_reconcile_log(text, integer, integer, integer, integer, uuid[], integer, boolean, boolean, text), payroll_wage_guard_i(text, uuid), payroll_wage_holds(text), payroll_wage_stop(text), payroll_wage_guard_summary(text) to service_role;
grant execute on function cash_handoff_wage_holds(text), hr_payroll_wage_guard_status(text, uuid), hr_payroll_wage_hold_release_request(text, uuid, uuid, text, uuid), hr_payroll_wage_hold_release_decide(uuid, text, text, uuid), hr_payroll_wage_hold_release_cancel(uuid, text, uuid) to authenticated, service_role;

-- ============ 7. 既存の振込の関数に差し込む（本番のいまの定義に、決めた箇所だけ足したもの。ほかの行は本番のまま） ============
CREATE OR REPLACE FUNCTION public.pay_transfer_pending_holds(p_year_month text)
 RETURNS TABLE(user_id uuid, request_id uuid)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select q.user_id, q.id from profile_change_requests q
   where q.field = 'bank_account' and q.status = 'pending' and (q.effective_year_month is null or q.effective_year_month <= p_year_month)
     -- いま銀行振込の口座が登録されている人だけ（口座が未登録・現金手渡しの人は、もともと振込データに入らない＝従来どおりの扱い）
     and exists (select 1 from payroll_bank_accounts b where b.user_id = q.user_id and coalesce(b.payment_method, 'bank_transfer') <> 'cash')
     and not exists (select 1 from payroll_transfer_schedule t where t.year_month = p_year_month
                      and t.created_at < coalesce((select (value ->> 'transfer_guard_since')::timestamptz from app_settings where key = 'employee_change'), '-infinity'::timestamptz))
     and not exists (select 1 from payroll_transfer_account_snapshots s where s.year_month = p_year_month and s.user_id = q.user_id)
  union all
  -- 2026-11-12 開発 2: 未承認の賃金変更がある人（関所が有効のときだけ。口座変更で既に外す人は重ねない）
  select w.user_id, null::uuid from payroll_wage_holds(p_year_month) w
   where exists (select 1 from payroll_bank_accounts b where b.user_id = w.user_id and coalesce(b.payment_method, 'bank_transfer') <> 'cash')
     and not exists (select 1 from payroll_transfer_schedule t where t.year_month = p_year_month
                      and t.created_at < coalesce((select (value ->> 'transfer_guard_since')::timestamptz from app_settings where key = 'employee_change'), '-infinity'::timestamptz))
     and not exists (select 1 from payroll_transfer_account_snapshots s where s.year_month = p_year_month and s.user_id = w.user_id)
     and not exists (select 1 from profile_change_requests q2 where q2.user_id = w.user_id and q2.field = 'bank_account' and q2.status = 'pending' and (q2.effective_year_month is null or q2.effective_year_month <= p_year_month))
$function$;

CREATE OR REPLACE FUNCTION public.payroll_transfer_schedule_after()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_new int := 0; v_on boolean; v_holds uuid[];
begin
  if coalesce(current_setting('employee_change.schedule_internal', true), '') <> '' then return null; end if;   -- 【要確認】タスクの印を付けるだけの内部の更新
  begin
    if new.invalid_export_at is not null and (tg_op = 'INSERT' or new.invalid_export_at is distinct from old.invalid_export_at) then
      -- ⑥ 印の無い出力: 確定として扱わない（控え・除外の処理をしない）。本部に知らせる
      perform pay_transfer_invalid_export_task(new.year_month);
      return null;
    end if;
    if new.export_ok is not true then return null; end if;
    if exists (select 1 from payroll_transfer_export_tokens t where t.token = new.export_token and t.used_at is not null) then return null; end if;   -- 同じ印では 1 回だけ処理する
    update payroll_transfer_export_tokens set used_at = now() where token = new.export_token;
    -- ① 画面に「除外する」と伝えた人（出力の印に控えてある）を、除外として記録。その後に申請が片付いていれば「その人の分が未出力」から始める
    select t.hold_users into v_holds from payroll_transfer_export_tokens t where t.token = new.export_token;
    with ins as (
      insert into payroll_transfer_holds(year_month, user_id, request_id, status, resolved_at)
      select new.year_month, u.id,
             (select q.id from profile_change_requests q where q.user_id = u.id and q.field = 'bank_account' order by (q.status = 'pending') desc, q.requested_at desc limit 1),
             case when exists (select 1 from profile_change_requests q where q.user_id = u.id and q.field = 'bank_account' and q.status = 'pending') then 'held' else 'ready' end,
             case when exists (select 1 from profile_change_requests q where q.user_id = u.id and q.field = 'bank_account' and q.status = 'pending') then null else now() end
        from unnest(coalesce(v_holds, '{}')) as u(id)
       where not exists (select 1 from payroll_transfer_account_snapshots sn where sn.year_month = new.year_month and sn.user_id = u.id)
      on conflict (year_month, user_id) do update set request_id = excluded.request_id, status = excluded.status, resolved_at = excluded.resolved_at where payroll_transfer_holds.status <> excluded.status and payroll_transfer_holds.status <> 'done'
      returning 1)
    select count(*) into v_new from ins;
    perform pay_transfer_holds_wage_fix(new.year_month, coalesce(v_holds, '{}'));   -- 2026-11-12 開発 2: 除外の理由（口座変更／未承認の賃金変更）を記録
    -- ② それ以外の人の口座の控え（最初の出力時点のもの。出し直しても自動では変えない。出力後に口座を登録した人・除外が解けた人だけ足される）
    insert into payroll_transfer_account_snapshots(year_month, user_id, account, taken_by)
    select new.year_month, b.user_id, to_jsonb(b) - 'created_at' - 'updated_at' - 'updated_by' - 'user_id', auth.uid() from payroll_bank_accounts b
     where not (b.user_id = any(coalesce(v_holds, '{}')))
    on conflict (year_month, user_id) do nothing;
    -- ③ 除外が解けていた人（ready）は、今回の出力で振込データに入った＝完了
    update payroll_transfer_holds h set status = 'done', done_at = now() where h.year_month = new.year_month and h.status = 'ready' and not (h.user_id = any(coalesce(v_holds, '{}')))
       and exists (select 1 from payroll_transfer_account_snapshots s where s.year_month = h.year_month and s.user_id = h.user_id);
    perform pay_transfer_hold_task_sync(new.year_month);
    if v_new > 0 then
      select coalesce((value ->> 'pay_request_notify_enabled')::boolean, false) into v_on from app_settings where key = 'employee_change';
      if coalesce(v_on, false) then perform pay_change_notify_op('transfer_hold', jsonb_build_object('year_month', new.year_month)); end if;
    end if;
    perform hr_apply_due_bank_changes_internal();   -- この回の出力が済んだので、次の回からの予約を反映
  exception when others then perform employee_change_log_error('payroll_transfer_schedule', lower(tg_op), null, sqlerrm);
  end;
  return null;
end $function$;

CREATE OR REPLACE FUNCTION public.pay_transfer_hold_task_sync(p_year_month text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_task uuid; v_step uuid; h record; v_item uuid; v_assignee uuid; v_open int; v_cstep uuid; v_title text;
begin
  -- 既存の「給与振込確認」タスク（出力のたびに作られる／更新される）。除外した人を「未振込」として載せる
  select st.id into v_cstep from transfer_confirm_task_links l join hq_tasks k on k.id = l.hq_task_id join hq_task_steps st on st.task_id = k.id
   where l.kind = 'payroll' and l.scope_key = p_year_month and k.deleted_at is null order by st.sort_order limit 1;
  for h in select * from payroll_transfer_holds where year_month = p_year_month loop
    v_title := '⚠️ 未振込: ' || coalesce((select name from users where id = h.user_id), '—') || 'さん（' || pay_transfer_hold_reason_label(h.reasons) || 'で除外）';
    if v_cstep is not null then
      if h.status in ('held', 'ready') and not exists (select 1 from hq_step_checklist_items c where c.step_id = v_cstep and c.title = v_title) then
        insert into hq_step_checklist_items(step_id, title, sort_order) values (v_cstep, v_title, 5);
      elsif h.status = 'done' then
        update hq_step_checklist_items set checked_at = now(), checked_by = auth.uid() where step_id = v_cstep and title = v_title and checked_at is null;
      end if;
    end if;
  end loop;
  select hq_task_id into v_task from payroll_transfer_holds where year_month = p_year_month and hq_task_id is not null limit 1;
  if v_task is null then
    if not exists (select 1 from payroll_transfer_holds where year_month = p_year_month and status in ('held', 'ready')) then return null; end if;
    select u.id into v_assignee from users u where u.name in ('青山純', '原　美香', '齋藤　隆治') and u.is_active order by array_position(array['青山純', '原　美香', '齋藤　隆治'], u.name) limit 1;
    insert into hq_tasks(title, corp, freq, target_date, due_date, notes, description, visibility, created_by, is_urgent)
    values ('【振込漏れ注意】' || p_year_month || ' 月分の給与振込: ' || case when exists (select 1 from payroll_transfer_holds x where x.year_month = p_year_month and 'wage_unapproved' = any(x.reasons)) then '確認待ちで除外した人がいます' else '口座変更の確認待ちで除外した人がいます' end, 'トーホー', 'once', current_date, least(pay_run_date(p_year_month), current_date + 3), '',
            p_year_month || ' 月分（' || pay_run_date(p_year_month) || ' 支給）の振込データから、口座変更の申請が承認待ちの人を除外しました。このままでは、その人に振り込まれません。'
            || E'\n' || '① 従業員ページで口座変更の申請を承認（どの支給回からかを選ぶ）または却下する ② 振込画面で「除外していた人の分を出力」して振り込む。'
            || case when exists (select 1 from payroll_transfer_holds x where x.year_month = p_year_month and 'wage_unapproved' = any(x.reasons)) then E'\n' || '※ 未承認の賃金変更（スマレジで直接変更・承認待ちの申請）が理由の人は、従業員ページで確認・是正してください。是正できない事情があるときは、社長の承認による例外解除が必要です。金額はここには表示しません。' else '' end
            || E'\n' || '②まで終わると、このタスクのチェックは自動で付きます。口座番号などはここには表示しません。', 'all', auth.uid(), true)
    returning id into v_task;
    insert into hq_task_steps(task_id, title, assignee_id, sort_order, kind, due_date) values (v_task, '除外した人の申請を処理し、その人の分の振込データを出力する', v_assignee, 10, 'step', least(pay_run_date(p_year_month), current_date + 3)) returning id into v_step;
    insert into hq_task_activity(task_id, actor_id, kind, detail) values (v_task, auth.uid(), 'create', '振込データの出力で除外した人がいるため自動作成');
  else
    select id into v_step from hq_task_steps where task_id = v_task order by sort_order limit 1;
  end if;
  for h in select * from payroll_transfer_holds where year_month = p_year_month loop
    if h.checklist_item_id is null then
      insert into hq_step_checklist_items(step_id, title, sort_order) values (v_step, coalesce((select name from users where id = h.user_id), '—') || 'さん', 10) returning id into v_item;
      update payroll_transfer_holds set hq_task_id = v_task, checklist_item_id = v_item where year_month = h.year_month and user_id = h.user_id;
      h.checklist_item_id := v_item;
    end if;
    if h.status = 'done' then update hq_step_checklist_items set checked_at = coalesce(checked_at, now()), checked_by = coalesce(checked_by, auth.uid()) where id = h.checklist_item_id; end if;
  end loop;
  select count(*) into v_open from payroll_transfer_holds where year_month = p_year_month and status in ('held', 'ready');
  if v_open = 0 then update hq_task_steps set completed_at = now(), completed_by = auth.uid() where task_id = v_task and completed_at is null; end if;
  return v_task;
end $function$;

CREATE OR REPLACE FUNCTION public.hr_payroll_transfer_prepare(p_year_month text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_applied integer := 0; v_snap jsonb; v_token uuid; v_hold uuid[];
begin
  if not (invoice_can_access() or onboarding_is_service()) then raise exception '権限がありません'; end if;
  if p_year_month !~ '^\d{4}-\d{2}$' then raise exception '月（YYYY-MM）が不正です'; end if;
  if pay_transfer_paused() then   -- ⑤ 切り替え作業中: 何もしないで「停止中」だけ返す
    return jsonb_build_object('ok', true, 'paused', true, 'year_month', p_year_month, 'attention', '[]'::jsonb, 'hold', '[]'::jsonb, 'ready', '[]'::jsonb, 'hold_records', '[]'::jsonb);
  end if;
  perform pay_transfer_holds_wage_refresh(p_year_month);   -- 2026-11-12 開発 2: 賃金の保留が解けた人を「その人の分が未出力」に進める
  begin v_applied := hr_apply_due_bank_changes_internal();
  exception when others then perform employee_change_log_error('payroll_transfer_prepare', 'apply_due', null, sqlerrm); end;
  -- 口座の控えは、登録口座を読める人（マスター・本部）にだけ返す
  if (is_profile_approver() or onboarding_is_service()) and exists (select 1 from payroll_transfer_schedule where year_month = p_year_month and export_ok is not false) then
    select jsonb_object_agg(s.user_id, s.account || jsonb_build_object('user_id', s.user_id, '_source', s.source)) into v_snap from payroll_transfer_account_snapshots s where s.year_month = p_year_month;
  end if;
  -- ⑥ 出力の印を発行（この呼び出しのあとの出力 1 回ぶん。除外するよう伝えた人を控える）
  select coalesce(array_agg(h.user_id), '{}') into v_hold from pay_transfer_pending_holds(p_year_month) h;
  if auth.uid() is not null then
    delete from payroll_transfer_export_tokens where issued_at < now() - interval '2 days';
    insert into payroll_transfer_export_tokens(year_month, user_id, hold_users) values (p_year_month, auth.uid(), v_hold) returning token into v_token;
  end if;
  return jsonb_build_object('ok', true, 'paused', false, 'export_token', v_token, 'year_month', p_year_month, 'state', pay_run_state(p_year_month), 'pay_date', pay_run_date(p_year_month), 'applied', v_applied,
    'snapshot', v_snap, 'attention', hr_pay_change_attention_internal(p_year_month),
    -- hold=この回の振込データに入れてはいけない人（未承認の口座変更が影響）／ready=除外していたが申請が片付いた人（その人の分を出す）
    'hold', (select coalesce(jsonb_agg(jsonb_build_object('user_id', h.user_id, 'user_name', (select name from users u where u.id = h.user_id), 'request_id', h.request_id, 'reason', case when h.request_id is null then 'wage_unapproved' else 'bank_change' end)), '[]'::jsonb) from pay_transfer_pending_holds(p_year_month) h),
    -- 2026-11-12 開発 2: 未承認の賃金変更の関所（止めている法人・人ごとの保留の人数）。関所が無効なら enabled=false
    'wage_guard', payroll_wage_guard_summary(p_year_month),
    'ready', (select coalesce(jsonb_agg(jsonb_build_object('user_id', h.user_id, 'user_name', (select name from users u where u.id = h.user_id))), '[]'::jsonb) from payroll_transfer_holds h where h.year_month = p_year_month and h.status = 'ready'),
    'transfer_pending_mode', coalesce((select value ->> 'transfer_pending_mode' from app_settings where key = 'employee_change'), 'exclude'),
    -- 除外の記録（誰が・なぜ・いまの状況）。振込が済んだもの（done）も履歴として返す
    'hold_records', (select coalesce(jsonb_agg(jsonb_build_object('user_id', h.user_id, 'user_name', (select name from users u where u.id = h.user_id), 'status', h.status,
                       'reason', pay_transfer_hold_reason_text(h.reasons), 'reasons', to_jsonb(h.reasons),
                       'status_label', case h.status when 'held' then case when 'wage_unapproved' = any(h.reasons) then '除外中（賃金変更の確認・是正、または社長の承認による例外解除が必要）' else '除外中（申請の承認・却下が必要）' end when 'ready' then '申請は処理済み・この人の分の振込データが未出力' else '振込データ出力済み' end,
                       'request_status', (select q.status from profile_change_requests q where q.id = h.request_id), 'excluded_at', h.created_at, 'resolved_at', h.resolved_at, 'done_at', h.done_at) order by h.created_at), '[]'::jsonb)
                      from payroll_transfer_holds h where h.year_month = p_year_month),
    'bank_approval_required', coalesce((select (value ->> 'bank_approval_required')::boolean from app_settings where key = 'employee_change'), false));
end $function$;

CREATE OR REPLACE FUNCTION public.hr_pay_change_attention_internal(p_year_month text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object('kind', x.kind, 'field', x.field, 'request_id', x.id, 'user_id', x.user_id, 'user_name', x.user_name, 'message', x.message) order by x.ord, x.requested_at), '[]'::jsonb)
  from (
    select q.id, q.field, q.user_id, q.requested_at, (select name from users u where u.id = q.user_id) user_name,
      case when q.apply_status in ('blocked_exported', 'blocked_finalized') then 'conflict'
           when q.status = 'pending' then 'unapproved' else 'sync_error' end kind,
      case when q.apply_status in ('blocked_exported', 'blocked_finalized') then 1 when q.status = 'pending' then 2 else 3 end ord,
      case when q.apply_status = 'blocked_exported' then '口座変更が未反映です（決めた支給回は振込データ出力済み）。支給回を選び直すか、個別の確認・承認をしてください'
           when q.apply_status = 'blocked_finalized' then '賃金変更が未反映です（適用開始月の給与が確定済み）'
           when q.status = 'pending' and q.field = 'bank_account' then '口座変更の申請が承認待ちです（承認されるまで今の口座のまま振り込みます）'
           when q.status = 'pending' then '賃金変更の申請が承認待ちです（適用開始日 ' || coalesce(q.effective_date::text, '—') || '）'
           else 'スマレジへの賃金の同期がエラーです（賃金カードから再実行してください）' end message
    from profile_change_requests q
    where q.field in ('wage', 'bank_account') and (
         (q.status = 'approved' and q.apply_status in ('blocked_exported', 'blocked_finalized'))
      or (q.status = 'pending' and (q.field = 'bank_account' or p_year_month is null or q.effective_date <= (to_date(p_year_month || '-01', 'YYYY-MM-DD') + interval '1 month' - interval '1 day')::date))
      or (q.status = 'approved' and q.field = 'wage' and q.apply_status = 'applied' and exists (select 1 from employee_wage_settings w where w.id = nullif(q.apply_ref ->> 'wage_setting_id', '')::uuid and w.sync_status = 'error')))
    union all
    -- 振込データから除外した人（振込漏れ防止）: 除外中／申請は片付いたが、その人の分の振込データがまだ
    select h.request_id, 'bank_account', h.user_id, h.created_at, (select name from users u where u.id = h.user_id), 'transfer_hold', 0,
      case when h.status = 'held' then h.year_month || ' 月分の振込データから除外中です（' || case when 'wage_unapproved' = any(h.reasons) then pay_transfer_hold_reason_label(h.reasons) else '口座変更の申請が承認待ち' end || '）。このままでは振り込まれません'
           else h.year_month || ' 月分の振込データが未出力です（' || case when 'wage_unapproved' = any(h.reasons) and not ('bank_change' = any(h.reasons)) then '賃金変更の確認は済みました' else '口座変更の申請は処理済み' end || '）。振込画面で「除外していた人の分を出力」してください' end
      || case when pay_run_state(h.year_month) = 'paid' then '【支給日（' || pay_run_date(h.year_month) || '）を過ぎています】' else '' end
    from payroll_transfer_holds h where h.status in ('held', 'ready')   -- 振込が済む（done）まで、支給日を過ぎても出し続ける
    union all
    -- 古い画面・直接の API からの出力（【要確認】のタスクを完了にするまで出し続ける）
    select null::uuid, 'bank_account', null::uuid, sc.invalid_export_at, '振込画面', 'invalid_export', 0,
      sc.year_month || ' 月分の振込 CSV が古い画面から出力されました。そのファイルは使わず、画面を再読み込みして出力し直してください（本部タスク【要確認】を確認）'
    from payroll_transfer_schedule sc where sc.invalid_export_at is not null and exists (select 1 from hq_tasks k where k.id = sc.invalid_task_id and k.status <> 'done' and k.deleted_at is null)
  ) x
$function$;

CREATE OR REPLACE FUNCTION public.payroll_transfer_confirm_step_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_ym text; v_names text;
begin
  if not (new.completed_at is not null and old.completed_at is null) then return new; end if;
  begin
    select l.scope_key into v_ym from transfer_confirm_task_links l where l.kind = 'payroll' and l.hq_task_id = new.task_id limit 1;
    if v_ym is not null then
      select string_agg((select name from users u where u.id = h.user_id) || 'さん', '、') into v_names from payroll_transfer_holds h where h.year_month = v_ym and h.status in ('held', 'ready');
    end if;
  exception when others then v_names := null;   -- 判定そのものの失敗では、本部タスクの操作を止めない
  end;
  if v_names is not null then
    raise exception '% 月分の給与振込は、まだ完了にできません。確認待ち（口座変更の承認待ち・未承認の賃金変更）で振込データから除外した人の振込が済んでいません（%）。申請・賃金変更の確認を済ませ、振込画面で「除外していた人の分を出力」して振り込んでから完了にしてください', v_ym, v_names;
  end if;
  return new;
end $function$;
