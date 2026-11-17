-- 本部タスクを Slack から付ける・本人の Slack DM へ通知する（2026-11-17・社長依頼・第 1 段階）
--   決定: 作れる人＝本部・社長・店長（マスター含む）／Chatwork は Slack DM と 1〜2 週間並行してから止める／AI は第 2 段階以降
--   足すもの: 設定 app_settings.hq_task_slack（既定は全部 false）・表 2 つ・関数 6 本。既存の表の列・関数・トリガーは変えない。
--   ・hq_slack_task_create: Slack のフォームの送信 → タスク 1 件＋工程 1 つ（service_role だけ・同じ送信の二重登録なし）
--   ・hq_slack_reminder_candidates: サーバー側の定期実行用。今日 DM すべき人×工程×種類の一覧（画面を開かなくても動く）
--   ・hq_slack_step_complete: DM の「完了」ボタン（担当者だけ。写真・判定・名簿つきの工程は画面で完了）
--   ・hq_slack_step_ack: DM の「対応中」ボタン（午後の追い通知だけ止める。翌日はまた通知）
-- 戻し方: 2026-12-13_hq_slack_task_rollback.sql

insert into app_settings(key, value) values ('hq_task_slack', '{"create_enabled": false, "dm_enabled": false, "escalate_days": 3}'::jsonb) on conflict (key) do nothing;

create table if not exists public.hq_slack_task_log (
  id          uuid primary key default gen_random_uuid(),
  dedupe_key  text not null unique,          -- Slack の送信の識別（同じ送信を二重に登録しない）
  task_id     uuid not null,
  created_by  uuid not null,
  source      jsonb,
  created_at  timestamptz not null default now()
);
create table if not exists public.hq_slack_reminder_log (
  id            uuid primary key default gen_random_uuid(),
  step_id       uuid not null,
  recipient_id  uuid not null,
  kind          text not null,               -- before3 / before1 / today / overdue / today_pm / overdue_pm / escalate / ack
  sent_on       date not null,               -- 日本時間の日付
  created_at    timestamptz not null default now(),
  unique (step_id, recipient_id, kind, sent_on)
);
alter table public.hq_slack_task_log enable row level security;
alter table public.hq_slack_reminder_log enable row level security;
revoke all on public.hq_slack_task_log from public, anon, authenticated;
revoke all on public.hq_slack_reminder_log from public, anon, authenticated;

create or replace function public.hq_slack_is_service() returns boolean language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '') = 'service_role'
$$;
revoke all on function public.hq_slack_is_service() from public, anon, authenticated;
create or replace function public.hq_slack_flag(p_name text) returns boolean language sql stable security definer set search_path to 'public' as $$
  select coalesce((select (s.value ->> p_name) = 'true' from app_settings s where s.key = 'hq_task_slack'), false)
$$;
revoke all on function public.hq_slack_flag(text) from public, anon, authenticated;

-- ===== Slack のフォーム → 本部タスク =====
create or replace function public.hq_slack_task_create(p_slack_user_id text, p_title text, p_corp text, p_assignee_ids uuid[], p_due date, p_memo text,
                                                       p_urgent boolean, p_dedupe text, p_source jsonb default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_u users%rowtype; v_task uuid; v_step uuid; v_ids uuid[]; v_title text := btrim(coalesce(p_title, '')); v_prev uuid; v_n integer;
  v_today date := (now() at time zone 'Asia/Tokyo')::date;
begin
  if not public.hq_slack_is_service() then raise exception '権限がありません'; end if;
  if not public.hq_slack_flag('create_enabled') then return jsonb_build_object('ok', false, 'reason', 'switch_off', 'message', 'Slack からのタスク作成は、まだ有効になっていません'); end if;
  select u.* into v_u from user_slack s join users u on u.id = s.user_id where s.slack_user_id = p_slack_user_id and u.is_active;
  if v_u.id is null then return jsonb_build_object('ok', false, 'reason', 'not_linked', 'message', 'あなたの Slack は管理システムに紐づいていません'); end if;
  if not (v_u.is_master or v_u.role in ('CEO', 'HQ', 'TENCHO')) then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', 'タスクを作れるのは、本部・社長・店長だけです');
  end if;
  if p_dedupe is null or btrim(p_dedupe) = '' then raise exception '送信の識別が必要です'; end if;
  select l.task_id into v_prev from hq_slack_task_log l where l.dedupe_key = p_dedupe;
  if v_prev is not null then return jsonb_build_object('ok', true, 'task_id', v_prev, 'duplicate', true); end if;
  if v_title = '' or char_length(v_title) > 120 then return jsonb_build_object('ok', false, 'reason', 'title', 'message', 'タスク名は 1〜120 文字で入れてください'); end if;
  if p_corp is null or p_corp not in ('トーホー', 'N-Style', 'SK', 'LiveGate') then return jsonb_build_object('ok', false, 'reason', 'corp', 'message', '法人を選んでください'); end if;
  if p_due is null or p_due < v_today then return jsonb_build_object('ok', false, 'reason', 'due', 'message', '期限は今日以降の日付を選んでください'); end if;
  v_ids := coalesce(p_assignee_ids, array[]::uuid[]);
  select count(*) into v_n from users u where u.id = any(v_ids) and u.is_active;
  if coalesce(array_length(v_ids, 1), 0) = 0 or v_n <> array_length(v_ids, 1) then
    return jsonb_build_object('ok', false, 'reason', 'assignee', 'message', '担当者を選んでください（Slack と紐づいていない人は選べません）');
  end if;
  insert into hq_tasks(title, corp, freq, target_date, due_date, notes, description, visibility, created_by, is_urgent, urgent_marked_by, urgent_marked_at)
  values (v_title, p_corp, 'once', v_today, p_due, '', nullif(btrim(coalesce(p_memo, '')), ''), 'all', v_u.id, coalesce(p_urgent, false),
          case when coalesce(p_urgent, false) then v_u.id end, case when coalesce(p_urgent, false) then now() end)
  returning id into v_task;
  insert into hq_task_steps(task_id, title, assignee_ids, due_date, sort_order, kind) values (v_task, '対応する', v_ids, p_due, 10, 'step') returning id into v_step;
  insert into hq_task_activity(task_id, actor_id, kind, detail) values (v_task, v_u.id, 'create', 'Slack のフォームから作成');
  insert into hq_slack_task_log(dedupe_key, task_id, created_by, source) values (p_dedupe, v_task, v_u.id, p_source);
  return jsonb_build_object('ok', true, 'task_id', v_task, 'step_id', v_step, 'creator_id', v_u.id, 'creator_name', v_u.name, 'duplicate', false);
end $$;
revoke all on function public.hq_slack_task_create(text, text, text, uuid[], date, text, boolean, text, jsonb) from public, anon, authenticated;
grant execute on function public.hq_slack_task_create(text, text, text, uuid[], date, text, boolean, text, jsonb) to service_role;

-- ===== 定期実行: 今日 DM すべき一覧 =====
--   対象: 未完了（削除していない）タスクの「いまの工程」（最初の未完了）。担当者＝工程の担当（無ければ作成者）。Slack と紐づいている人だけ（無い人は今までの Chatwork のまま）。
--   種類: 期限の 3 日前・前日・当日・超過（毎日）。15 時以降は、期限当日・超過で「対応中」を押していない工程に追い通知（_pm）。
--   超過が escalate_days 日以上の工程は、作成者へも 1 日 1 回（escalate）。同じ（工程・人・種類・日）は 1 回だけ（ログで管理）。
create or replace function public.hq_slack_reminder_candidates()
returns table(recipient_id uuid, slack_user_id text, task_id uuid, step_id uuid, task_title text, step_title text, due_date date, kind text, days_over integer,
              creator_id uuid, can_complete boolean, url text)
language plpgsql security definer set search_path to 'public' as $$
declare v_today date := (now() at time zone 'Asia/Tokyo')::date; v_hour integer := extract(hour from (now() at time zone 'Asia/Tokyo'))::integer;
        v_esc integer := coalesce((select (s.value ->> 'escalate_days')::integer from app_settings s where s.key = 'hq_task_slack'), 3);
begin
  if not public.hq_slack_is_service() then raise exception '権限がありません'; end if;
  return query
  with cur as (
    select t.id as tid, t.title as ttitle, t.created_by, t.template_id, s.id as sid, s.title as stitle, coalesce(s.due_date, t.due_date) as due,
           coalesce(s.assignee_ids, case when s.assignee_id is not null then array[s.assignee_id] end, array[t.created_by]) as rcpt,
           (s.kind = 'step' and not s.is_binary and not s.requires_photo and not exists (select 1 from hq_step_checklist_items i where i.step_id = s.id)) as plain,
           a.before3 as a3, a.before1 as a1, a.due as ad, a.overdue_daily as ao,
           tp.alert_before3 as t3, tp.alert_before1 as t1, tp.alert_due as td, tp.alert_overdue_daily as tod
      from hq_tasks t
      join lateral (select s2.* from hq_task_steps s2 where s2.task_id = t.id and s2.completed_at is null order by s2.sort_order limit 1) s on true
      left join hq_task_alerts a on a.task_id = t.id
      left join hq_task_templates tp on tp.id = t.template_id
     where t.status <> 'done' and t.deleted_at is null and coalesce(s.due_date, t.due_date) is not null
  ), kinds as (
    select c.*, (c.due - v_today) as d,
           case when c.due < v_today and coalesce(c.ao, c.tod, true) then 'overdue'
                when c.due = v_today and coalesce(c.ad, c.td, true) then 'today'
                when c.due = v_today + 1 and coalesce(c.a1, c.t1, true) then 'before1'
                when c.due = v_today + 3 and coalesce(c.a3, c.t3, true) then 'before3' end as k
      from cur c
  ), expanded as (
    select k.tid, k.ttitle, k.created_by, k.sid, k.stitle, k.due, k.plain, k.k as kind, (v_today - k.due) as over, r as rid, false as esc from kinds k, unnest(k.rcpt) r where k.k is not null
    union all
    select k.tid, k.ttitle, k.created_by, k.sid, k.stitle, k.due, k.plain, k.k || '_pm', (v_today - k.due), r, false from kinds k, unnest(k.rcpt) r
     where k.k in ('today', 'overdue') and v_hour >= 15
       and not exists (select 1 from hq_slack_reminder_log l where l.step_id = k.sid and l.recipient_id = r and l.kind = 'ack' and l.sent_on = v_today)
    union all
    select k.tid, k.ttitle, k.created_by, k.sid, k.stitle, k.due, k.plain, 'escalate', (v_today - k.due), k.created_by, true from kinds k
     where k.k = 'overdue' and (v_today - k.due) >= v_esc and k.created_by is not null and not (k.created_by = any(k.rcpt))
  )
  select e.rid, us.slack_user_id, e.tid, e.sid, e.ttitle, e.stitle, e.due, e.kind, greatest(e.over, 0), e.created_by, e.plain,
         'https://mirai-oss.github.io/ns-portal/tasks.html?task=' || e.tid
    from expanded e
    join users u on u.id = e.rid and u.is_active
    join user_slack us on us.user_id = e.rid
   where not exists (select 1 from hq_slack_reminder_log l where l.step_id = e.sid and l.recipient_id = e.rid and l.kind = e.kind and l.sent_on = v_today)
   order by e.due, e.tid;
end $$;
revoke all on function public.hq_slack_reminder_candidates() from public, anon, authenticated;
grant execute on function public.hq_slack_reminder_candidates() to service_role;

-- 1 件ぶんの送信の予約（同じ組み合わせは 1 日 1 回だけ。取れなかったら送らない）。送信に失敗したら release で戻す
create or replace function public.hq_slack_reminder_claim(p_step uuid, p_recipient uuid, p_kind text) returns boolean language plpgsql security definer set search_path to 'public' as $$
declare v_n integer;
begin
  if not public.hq_slack_is_service() then raise exception '権限がありません'; end if;
  insert into hq_slack_reminder_log(step_id, recipient_id, kind, sent_on) values (p_step, p_recipient, p_kind, (now() at time zone 'Asia/Tokyo')::date) on conflict do nothing;
  get diagnostics v_n = row_count;
  return v_n = 1;
end $$;
create or replace function public.hq_slack_reminder_release(p_step uuid, p_recipient uuid, p_kind text) returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.hq_slack_is_service() then raise exception '権限がありません'; end if;
  delete from hq_slack_reminder_log where step_id = p_step and recipient_id = p_recipient and kind = p_kind and sent_on = (now() at time zone 'Asia/Tokyo')::date;
end $$;
revoke all on function public.hq_slack_reminder_claim(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.hq_slack_reminder_release(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.hq_slack_reminder_claim(uuid, uuid, text) to service_role;
grant execute on function public.hq_slack_reminder_release(uuid, uuid, text) to service_role;

-- ===== DM のボタン =====
create or replace function public.hq_slack_step_complete(p_slack_user_id text, p_step uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_u users%rowtype; v_s hq_task_steps%rowtype; v_first uuid; v_status text;
begin
  if not public.hq_slack_is_service() then raise exception '権限がありません'; end if;
  select u.* into v_u from user_slack s join users u on u.id = s.user_id where s.slack_user_id = p_slack_user_id and u.is_active;
  if v_u.id is null then return jsonb_build_object('ok', false, 'message', 'Slack が管理システムに紐づいていません'); end if;
  select * into v_s from hq_task_steps where id = p_step for update;
  if v_s.id is null then return jsonb_build_object('ok', false, 'message', '工程が見つかりません'); end if;
  if v_s.completed_at is not null then return jsonb_build_object('ok', true, 'already', true, 'message', 'すでに完了しています'); end if;
  if not (v_u.id = any(coalesce(v_s.assignee_ids, array[v_s.assignee_id])) or v_u.is_master or v_u.role in ('CEO', 'HQ')) then
    return jsonb_build_object('ok', false, 'message', 'この工程の担当者だけが完了にできます');
  end if;
  select s2.id into v_first from hq_task_steps s2 where s2.task_id = v_s.task_id and s2.completed_at is null order by s2.sort_order limit 1;
  if v_first is distinct from v_s.id then return jsonb_build_object('ok', false, 'message', '前の工程が終わっていません。管理システムで確認してください'); end if;
  if v_s.kind <> 'step' or v_s.is_binary or v_s.requires_photo or exists (select 1 from hq_step_checklist_items i where i.step_id = v_s.id) then
    return jsonb_build_object('ok', false, 'need_screen', true, 'message', '写真・判定・名簿のある工程は、管理システムの画面で完了にしてください');
  end if;
  update hq_task_steps set completed_at = now(), completed_by = v_u.id where id = v_s.id;
  insert into hq_task_activity(task_id, step_id, actor_id, kind, detail) values (v_s.task_id, v_s.id, v_u.id, 'step_complete', 'Slack の DM から完了');
  select t.status into v_status from hq_tasks t where t.id = v_s.task_id;
  return jsonb_build_object('ok', true, 'task_status', v_status, 'task_id', v_s.task_id);
end $$;
revoke all on function public.hq_slack_step_complete(text, uuid) from public, anon, authenticated;
grant execute on function public.hq_slack_step_complete(text, uuid) to service_role;

create or replace function public.hq_slack_step_ack(p_slack_user_id text, p_step uuid) returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid;
begin
  if not public.hq_slack_is_service() then raise exception '権限がありません'; end if;
  select s.user_id into v_uid from user_slack s where s.slack_user_id = p_slack_user_id;
  if v_uid is null or not exists (select 1 from hq_task_steps st where st.id = p_step and v_uid = any(coalesce(st.assignee_ids, array[st.assignee_id]))) then
    return jsonb_build_object('ok', false, 'message', 'この工程の担当者だけが押せます');
  end if;
  insert into hq_slack_reminder_log(step_id, recipient_id, kind, sent_on) values (p_step, v_uid, 'ack', (now() at time zone 'Asia/Tokyo')::date) on conflict do nothing;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.hq_slack_step_ack(text, uuid) from public, anon, authenticated;
grant execute on function public.hq_slack_step_ack(text, uuid) to service_role;
