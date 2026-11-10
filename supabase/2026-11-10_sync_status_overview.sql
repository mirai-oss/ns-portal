-- 同期状況の一覧と、読み取りだけの不一致照合（ステップ 4・2026-11-10）
--   設計: docs/設計書_従業員情報変更の連動_2026-11-10.md §11
--   ★ 本番未適用（開発・テストのみ承認。適用は別途承認）。戻し方: 2026-11-10_sync_status_overview_rollback.sql
--   前提: 2026-11-10_employee_change_events.sql（適用済み）と 2026-11-10_pay_change_requests.sql（ステップ 3。先に適用する）
--
--   ねらい: 全従業員について「承認待ち・未同期・同期エラー・情報不一致・交通費の再確認待ち」を 1 か所で確認できるようにする。
--     ・一覧に出るのは対応が必要な人だけ（正常な人には何も発生しない）。氏名と項目名だけを出し、住所・口座番号・金額などの値は出さない
--     ・新しい状態の表は作らない。既存の各表の状態（申請の status／各設定の sync_status／既存の所属照合 staff_store_mismatch／交通費の再確認）を読むだけ
--     ・不一致照合は「外部は読み取りだけ」。既存の読み取り（賃金の一括読み取り wage_pull_all など）の結果を、管理システム内の表 employee_sync_mismatches に記録する。
--       外部（スマレジ等）も管理システムの正本も、照合では書き換えない（直すのは人が選ぶ: 既存の同期を実行／管理システムを直す）
--     ・本部タスクは、対応が必要なものだけを 1 件のタスクのチェック項目にまとめる（hr_sync_status_task_sync）。
--       自動で連動するかは app_settings.employee_change.sync_task_auto（既定 false＝画面のボタンを押したときだけ）

-- ============ 1. 不一致照合の結果（管理システム内の記録） ============
create table if not exists employee_sync_mismatches (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  kind text not null check (kind in ('wage', 'store', 'commute', 'tax', 'name', 'address', 'active', 'info_copy')),
  scope text not null default '',          -- 契約 ID など（同じ人でも契約ごとに分ける）
  source text not null,                    -- どの照合で見つけたか（例: wage_pull_all）
  detail jsonb,                            -- 本部だけが読む詳細（一覧には出さない）
  detected_at timestamptz not null default now(), last_seen_at timestamptz not null default now(),
  resolved_at timestamptz, resolved_by uuid, resolve_note text
);
create unique index if not exists employee_sync_mismatches_open on employee_sync_mismatches(user_id, kind, scope) where resolved_at is null;
-- いつ・何を・何人ぶん照合したか（「最後に照合した日時」を一覧に出す）
create table if not exists employee_sync_checks (
  kind text not null, scope text not null default '', checked_at timestamptz not null default now(), checked_by uuid, checked_count integer not null default 0, found_count integer not null default 0,
  primary key (kind, scope)
);
-- 本部タスクのチェック項目との対応（同じ要対応を二重に載せない）
create table if not exists employee_sync_task_items (
  key text primary key, user_id uuid, cat text, label text, task_id uuid, checklist_item_id uuid, opened_at timestamptz not null default now(), closed_at timestamptz
);
alter table employee_sync_mismatches enable row level security;
alter table employee_sync_checks enable row level security;
alter table employee_sync_task_items enable row level security;
drop policy if exists employee_sync_mismatches_read on employee_sync_mismatches;
create policy employee_sync_mismatches_read on employee_sync_mismatches for select using (hq_can_manage());
drop policy if exists employee_sync_checks_read on employee_sync_checks;
create policy employee_sync_checks_read on employee_sync_checks for select using (hq_can_manage());
drop policy if exists employee_sync_task_items_read on employee_sync_task_items;
create policy employee_sync_task_items_read on employee_sync_task_items for select using (hq_can_manage());
update app_settings set value = '{"sync_task_auto": false}'::jsonb || value where key = 'employee_change';

-- ============ 2. 対応が必要なもの（既存の各表を読むだけ） ============
--   cat: approval_pending=承認待ち／unsynced=未同期／sync_error=同期エラー／mismatch=情報不一致／commute_recheck=交通費の再確認待ち
--   has_task: すでに専用の本部タスクがある（口座・賃金の変更申請、振込データからの除外）＝まとめのタスクには重ねて載せない
create or replace function hr_sync_status_issues()
returns table(user_id uuid, cat text, key text, label text, since timestamptz, has_task boolean)
language sql stable security definer set search_path = public as $$
  -- 承認待ち
  select q.user_id, 'approval_pending', 'pcr:' || q.id, '変更申請の承認待ち（' || case q.field when 'name' then '氏名' when 'kana' then 'フリガナ' when 'phone' then '電話番号' when 'address' then '住所' when 'bank_account' then '給与振込口座'
           when 'contact_email' then '連絡用メール' when 'id_document' then '身分証明書' when 'wage' then '賃金' else q.field end || '）', q.requested_at, q.hq_task_id is not null
    from profile_change_requests q where q.status = 'pending' and q.apply_status not in ('blocked_exported', 'blocked_finalized')
  union all
  select r.user_id, 'approval_pending', 'hcr:' || r.id, '異動・退職などの申請の承認待ち', r.requested_at, false from hr_change_requests r where r.status = 'pending' and r.user_id is not null
  union all
  select c.user_id, 'approval_pending', 'commute:' || c.user_id, '交通費（通勤経路）の承認待ち', c.submitted_at, false from employee_commute c where c.submitted_at is not null and c.approved_at is null and c.recheck_required_at is null
  -- 未同期（承認・登録は済んだが、スマレジ等にまだ反映されていない）
  union all
  select w.user_id, 'unsynced', 'wage:' || w.id, '賃金がスマレジに未反映（適用開始日 ' || w.effective_date || '）', w.updated_at, false from employee_wage_settings w where w.sync_status = 'pending'
  union all
  select s.user_id, 'unsynced', 'commute_setting:' || s.id, '交通費の設定がスマレジに未反映', s.updated_at, false from employee_commute_settings s where s.sync_status in ('pending', 'queued')
  union all
  select x.user_id, 'unsynced', 'tax:' || x.user_id, '源泉・扶養の設定がスマレジに未反映', x.updated_at, false from employee_tax_settings x where x.sync_status in ('pending', 'queued')
  union all
  select y.user_id, 'unsynced', 'year_end:' || y.user_id || ':' || y.target_year, '年末調整の情報がスマレジに未反映', y.updated_at, false from employee_year_end y where y.sync_status in ('pending', 'queued')
  union all
  select p.user_id, 'unsynced', 'profile:' || p.user_id, '従業員情報がスマレジに未反映', p.updated_at, false from employee_profiles p where p.smaregi_sync_status = 'pending'
  union all
  select r.user_id, 'unsynced', 'hcr_sync:' || r.id, '異動・退職の承認内容がスマレジに未反映', r.approved_at, false from hr_change_requests r where r.status = 'approved' and r.sync_status = 'unsynced' and r.user_id is not null
  -- 同期エラー・未反映で止まっているもの
  union all
  select w.user_id, 'sync_error', 'wage:' || w.id, '賃金のスマレジ同期がエラー（適用開始日 ' || w.effective_date || '）', w.updated_at, false from employee_wage_settings w where w.sync_status = 'error'
  union all
  select s.user_id, 'sync_error', 'commute_setting:' || s.id, '交通費の設定のスマレジ同期がエラー', s.updated_at, false from employee_commute_settings s where s.sync_status = 'error'
  union all
  select x.user_id, 'sync_error', 'tax:' || x.user_id, '源泉・扶養の設定のスマレジ同期がエラー', x.updated_at, false from employee_tax_settings x where x.sync_status = 'error'
  union all
  select y.user_id, 'sync_error', 'year_end:' || y.user_id || ':' || y.target_year, '年末調整の情報のスマレジ同期がエラー', y.updated_at, false from employee_year_end y where y.sync_status = 'error'
  union all
  select p.user_id, 'sync_error', 'profile:' || p.user_id, '従業員情報のスマレジ同期がエラー', p.updated_at, false from employee_profiles p where p.smaregi_sync_status = 'error'
  union all
  select r.user_id, 'sync_error', 'hcr_sync:' || r.id, '異動・退職のスマレジ同期がエラー', r.updated_at, false from hr_change_requests r where r.status = 'approved' and r.sync_status = 'error' and r.user_id is not null
  union all
  select q.user_id, 'sync_error', 'pcr_blocked:' || q.id, case when q.apply_status = 'blocked_exported' then '口座変更が未反映（決めた支給回は振込データ出力済み）' else '賃金変更が未反映（適用開始月の給与が確定済み）' end, q.requested_at, false
    from profile_change_requests q where q.status in ('pending', 'approved') and q.apply_status in ('blocked_exported', 'blocked_finalized')
  union all
  select h.user_id, 'sync_error', 'transfer_hold:' || h.year_month || ':' || h.user_id, h.year_month || ' 月分の振込データから除外中（振込漏れに注意）', h.created_at, true
    from payroll_transfer_holds h where h.status in ('held', 'ready')
  -- 情報不一致（読み取りの照合で見つかったもの。既存の所属照合と、照合結果の表）
  union all
  select m.user_id, 'mismatch', 'store:' || m.user_id || ':' || m.contract_id, '所属店舗がスマレジと不一致', m.detected_at, false from staff_store_mismatch m
  union all
  select m.user_id, 'mismatch', 'mm:' || m.id, case m.kind when 'wage' then '賃金がスマレジと不一致' when 'store' then '所属店舗がスマレジと不一致' when 'commute' then '交通費の設定がスマレジと不一致' when 'tax' then '源泉・扶養の設定がスマレジと不一致'
           when 'name' then '氏名が他システムと不一致' when 'address' then '住所が他システムと不一致' when 'active' then '在籍の状態がスマレジと不一致' else '社内情報管理システムの写しと不一致' end, m.detected_at, false
    from employee_sync_mismatches m where m.resolved_at is null
  -- 交通費の再確認待ち（住所・最寄り駅・所属・雇用形態の変更で起動したもの）
  union all
  select e.user_id, 'commute_recheck', 'effect:' || e.id, '交通費の再確認待ち（' || array_to_string(e.reasons, '・') || 'の変更）', e.created_at, false from employee_change_effects e where e.effect_key = 'commute_recheck' and e.status in ('pending', 'in_progress')
$$;

-- ============ 3. 一覧（本部系だけ。対応が必要な人だけを返す） ============
create or replace function hr_sync_status_overview()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not (hq_can_manage() or onboarding_is_service()) then raise exception '権限がありません'; end if;
  with i as (select * from hr_sync_status_issues()),
  per as (
    select i.user_id, min(case i.cat when 'sync_error' then 1 when 'mismatch' then 2 when 'approval_pending' then 3 when 'commute_recheck' then 4 else 5 end) sev, min(i.since) oldest,
           jsonb_agg(jsonb_build_object('cat', i.cat, 'key', i.key, 'label', i.label, 'since', i.since, 'has_task', i.has_task) order by case i.cat when 'sync_error' then 1 when 'mismatch' then 2 when 'approval_pending' then 3 when 'commute_recheck' then 4 else 5 end, i.since) issues
      from i group by i.user_id)
  select jsonb_build_object('ok', true, 'generated_at', now(),
    'counts', (select coalesce(jsonb_object_agg(c.cat, c.n), '{}'::jsonb) from (select cat, count(*) n from i group by cat) c),
    'employee_count', (select count(*) from per),
    'normal_count', (select count(*) from users u where u.is_active and not exists (select 1 from per where per.user_id = u.id)),
    'employees', (select coalesce(jsonb_agg(jsonb_build_object('user_id', per.user_id, 'user_name', u.name, 'is_active', u.is_active,
                      'stores', (select string_agg(s.name, '・' order by us.is_primary desc, s.sort_order) from user_stores us join stores s on s.id = us.store_id where us.user_id = per.user_id),
                      'issues', per.issues) order by per.sev, per.oldest), '[]'::jsonb) from per join users u on u.id = per.user_id),
    'checks', (select coalesce(jsonb_agg(jsonb_build_object('kind', k.kind, 'scope', k.scope, 'checked_at', k.checked_at, 'checked_count', k.checked_count, 'found_count', k.found_count) order by k.kind, k.scope), '[]'::jsonb) from employee_sync_checks k),
    'open_task_items', (select count(*) from employee_sync_task_items t where t.closed_at is null),
    'task_auto', coalesce((select (value ->> 'sync_task_auto')::boolean from app_settings where key = 'employee_change'), false)) into v;
  return v;
end $$;

-- ============ 4. 読み取りの照合の結果を記録する（外部には書かない。管理システムの正本も変えない） ============
--   p_checked: 今回照合した従業員（null＝その種類・範囲を全員ぶん照合した。人数は p_checked_count）／p_found: 不一致が見つかった人 [{"user_id": "...", "detail": {...}}]
--   見つかった人は「不一致（未解消）」として 1 人 1 件。照合したが不一致が無かった人の未解消分は「一致を確認」として閉じる
create or replace function hr_sync_mismatch_report(p_kind text, p_scope text, p_checked uuid[], p_found jsonb, p_source text, p_actor uuid default null, p_checked_count integer default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_actor uuid; f jsonb; v_new int := 0; v_seen int := 0; v_closed int := 0; v_ids uuid[] := '{}'; v_uid uuid;
begin
  v_actor := public.onboarding_resolve_actor(p_actor);
  if p_kind not in ('wage', 'store', 'commute', 'tax', 'name', 'address', 'active', 'info_copy') then raise exception '種類が不正です'; end if;
  for f in select * from jsonb_array_elements(coalesce(p_found, '[]'::jsonb)) loop
    v_uid := (f ->> 'user_id')::uuid;
    if not exists (select 1 from users where id = v_uid) then continue; end if;
    v_ids := v_ids || v_uid;
    if exists (select 1 from employee_sync_mismatches where user_id = v_uid and kind = p_kind and scope = coalesce(p_scope, '') and resolved_at is null) then
      update employee_sync_mismatches set last_seen_at = now(), detail = coalesce(f -> 'detail', detail), source = coalesce(p_source, source) where user_id = v_uid and kind = p_kind and scope = coalesce(p_scope, '') and resolved_at is null;
      v_seen := v_seen + 1;
    else
      insert into employee_sync_mismatches(user_id, kind, scope, source, detail) values (v_uid, p_kind, coalesce(p_scope, ''), coalesce(p_source, 'manual'), f -> 'detail');
      v_new := v_new + 1;
    end if;
  end loop;
  update employee_sync_mismatches set resolved_at = now(), resolved_by = v_actor, resolve_note = '照合で一致を確認'
   where kind = p_kind and scope = coalesce(p_scope, '') and resolved_at is null and (p_checked is null or user_id = any(p_checked)) and not (user_id = any(v_ids));
  get diagnostics v_closed = row_count;
  insert into employee_sync_checks(kind, scope, checked_at, checked_by, checked_count, found_count) values (p_kind, coalesce(p_scope, ''), now(), v_actor, coalesce(p_checked_count, array_length(p_checked, 1), 0), coalesce(array_length(v_ids, 1), 0))
  on conflict (kind, scope) do update set checked_at = excluded.checked_at, checked_by = excluded.checked_by, checked_count = excluded.checked_count, found_count = excluded.found_count;
  return jsonb_build_object('ok', true, 'new', v_new, 'still', v_seen, 'resolved', v_closed);
end $$;
-- 不一致を人が解消済みにする（理由つき。例: スマレジ側を直した／管理システムを直した）
create or replace function hr_sync_mismatch_resolve(p_id uuid, p_note text, p_actor uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_actor uuid;
begin
  v_actor := public.onboarding_resolve_actor(p_actor);
  if nullif(trim(coalesce(p_note, '')), '') is null then raise exception 'どう解消したかを入れてください'; end if;
  update employee_sync_mismatches set resolved_at = now(), resolved_by = v_actor, resolve_note = trim(p_note) where id = p_id and resolved_at is null;
  if not found then raise exception '対象が見つからないか、解消済みです'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- ============ 5. 本部タスクへの連動（対応が必要なものだけ。1 件のタスクのチェック項目にまとめる） ============
--   ・専用のタスクがあるもの（口座・賃金の変更申請、振込データからの除外）は重ねて載せない
--   ・新しい要対応 → チェック項目を足す（同じものは二重に足さない）／解消したもの → 自動でチェック／全部解消 → タスク完了
--   ・要対応が無ければタスクは作らない（正常な従業員には何も発生しない）
create or replace function hr_sync_status_task_sync(p_actor uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_actor uuid; v_task uuid; v_step uuid; v_assignee uuid; i record; v_item uuid; v_added int := 0; v_closed int := 0; v_open int;
begin
  v_actor := public.onboarding_resolve_actor(p_actor);
  -- 解消したものにチェック
  for i in select t.* from employee_sync_task_items t where t.closed_at is null and not exists (select 1 from hr_sync_status_issues() s where s.key = t.key and not s.has_task) loop
    update hq_step_checklist_items set checked_at = coalesce(checked_at, now()), checked_by = coalesce(checked_by, v_actor) where id = i.checklist_item_id;
    update employee_sync_task_items set closed_at = now() where key = i.key;
    v_closed := v_closed + 1;
  end loop;
  -- いま開いているまとめのタスク（未完了・未削除）
  select t.task_id into v_task from employee_sync_task_items t join hq_tasks k on k.id = t.task_id where t.closed_at is null and k.status <> 'done' and k.deleted_at is null limit 1;
  for i in select s.*, (select name from users u where u.id = s.user_id) user_name from hr_sync_status_issues() s
            where not s.has_task and not exists (select 1 from employee_sync_task_items t where t.key = s.key and t.closed_at is null) order by s.since loop
    if v_task is null then
      select u.id into v_assignee from users u where u.name in ('青山純', '原　美香', '齋藤　隆治') and u.is_active order by array_position(array['青山純', '原　美香', '齋藤　隆治'], u.name) limit 1;
      insert into hq_tasks(title, corp, freq, target_date, due_date, notes, description, visibility, created_by)
      values ('従業員情報の同期・承認: 要対応の確認', 'トーホー', 'once', current_date, current_date + 7, '',
              '従業員情報の「承認待ち・未同期・同期エラー・情報不一致・交通費の再確認待ち」のうち、対応が必要なものの一覧です。' || E'\n' || '管理システム（nippo）の従業員一覧の上にある「同期・承認の状況」から、それぞれの従業員ページを開いて対応してください。'
              || E'\n' || 'https://mirai-oss.github.io/nippo/?page=admin' || E'\n' || '解消すると、チェックは自動で付きます（全部付くとタスクは完了になります）。住所・口座番号・金額などはここには表示しません。', 'all', v_actor)
      returning id into v_task;
      insert into hq_task_steps(task_id, title, assignee_id, sort_order, kind, due_date) values (v_task, '一覧の要対応を解消する', v_assignee, 10, 'step', current_date + 7);
      insert into hq_task_activity(task_id, actor_id, kind, detail) values (v_task, v_actor, 'create', '同期・承認の状況に要対応があるため自動作成');
    end if;
    if v_step is null then select id into v_step from hq_task_steps where task_id = v_task order by sort_order limit 1; end if;
    insert into hq_step_checklist_items(step_id, title, sort_order) values (v_step, coalesce(i.user_name, '—') || 'さん: ' || i.label, 10) returning id into v_item;
    insert into employee_sync_task_items(key, user_id, cat, label, task_id, checklist_item_id) values (i.key, i.user_id, i.cat, i.label, v_task, v_item)
    on conflict (key) do update set user_id = excluded.user_id, cat = excluded.cat, label = excluded.label, task_id = excluded.task_id, checklist_item_id = excluded.checklist_item_id, opened_at = now(), closed_at = null;
    v_added := v_added + 1;
  end loop;
  -- 全部解消したタスクは完了にする
  for i in select distinct t.task_id from employee_sync_task_items t join hq_tasks k on k.id = t.task_id where k.status <> 'done' and k.deleted_at is null
            and not exists (select 1 from employee_sync_task_items o where o.task_id = t.task_id and o.closed_at is null) loop
    update hq_task_steps set completed_at = now(), completed_by = v_actor where task_id = i.task_id and completed_at is null;
  end loop;
  select count(*) into v_open from employee_sync_task_items where closed_at is null;
  return jsonb_build_object('ok', true, 'task_id', v_task, 'added', v_added, 'closed', v_closed, 'open', v_open);
end $$;

revoke all on function hr_sync_status_issues() from public, anon, authenticated;
revoke all on function hr_sync_status_overview() from public, anon;
revoke all on function hr_sync_mismatch_report(text, text, uuid[], jsonb, text, uuid, integer) from public, anon;
revoke all on function hr_sync_mismatch_resolve(uuid, text, uuid) from public, anon;
revoke all on function hr_sync_status_task_sync(uuid) from public, anon;
grant execute on function hr_sync_status_overview() to authenticated, service_role;
grant execute on function hr_sync_mismatch_report(text, text, uuid[], jsonb, text, uuid, integer) to authenticated, service_role;
grant execute on function hr_sync_mismatch_resolve(uuid, text, uuid) to authenticated, service_role;
grant execute on function hr_sync_status_task_sync(uuid) to authenticated, service_role;
