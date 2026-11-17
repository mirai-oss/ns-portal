-- 自分が Slack から付けたタスクが完了したら、作成者へ個人 DM（2026-11-17・社長依頼）
--   対象: hq_slack_task_log にあるタスク（Slack のフォームから作ったもの）で、status='done' になったもの。画面・Slack のどちらで完了しても同じ。
--   作成者本人がすべての工程を完了した場合は送らない（自分の操作の通知は要らない）。同じタスクは 1 回だけ（ログ）。
--   このファイルを流した時刻より前に完了していたものは送らない（app_settings.hq_task_slack.complete_since）。
-- 戻し方: drop function public.hq_slack_complete_candidates(); drop function public.hq_slack_complete_claim(uuid); drop function public.hq_slack_complete_release(uuid); drop table public.hq_slack_complete_log; cron.unschedule('hq-task-completions')
update app_settings set value = value || jsonb_build_object('complete_since', to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SS"Z"')) where key = 'hq_task_slack' and not (value ? 'complete_since');
create table if not exists public.hq_slack_complete_log (task_id uuid primary key, created_at timestamptz not null default now());
alter table public.hq_slack_complete_log enable row level security;
revoke all on public.hq_slack_complete_log from public, anon, authenticated;

create or replace function public.hq_slack_complete_candidates()
returns table(creator_id uuid, slack_user_id text, task_id uuid, task_title text, completed_at timestamptz, completer_names text, step_count integer, url text)
language plpgsql security definer set search_path to 'public' as $$
declare v_since timestamptz := coalesce((select (s.value ->> 'complete_since')::timestamptz from app_settings s where s.key = 'hq_task_slack'), now());
begin
  if not public.hq_slack_is_service() then raise exception '権限がありません'; end if;
  return query
  select l.created_by, us.slack_user_id, t.id, t.title, t.completed_at,
         (select string_agg(distinct u.name, '・') from hq_task_steps s join users u on u.id = s.completed_by where s.task_id = t.id),
         (select count(*)::integer from hq_task_steps s where s.task_id = t.id),
         'https://mirai-oss.github.io/ns-portal/tasks.html?task=' || t.id
    from hq_slack_task_log l
    join hq_tasks t on t.id = l.task_id and t.status = 'done' and t.deleted_at is null and coalesce(t.completed_at, t.updated_at) >= v_since
    join users cu on cu.id = l.created_by and cu.is_active
    join user_slack us on us.user_id = l.created_by
   where not exists (select 1 from hq_slack_complete_log c where c.task_id = t.id)
     and exists (select 1 from hq_task_steps s where s.task_id = t.id and s.completed_by is distinct from l.created_by);
end $$;
create or replace function public.hq_slack_complete_claim(p_task uuid) returns boolean language plpgsql security definer set search_path to 'public' as $$
declare v_n integer;
begin
  if not public.hq_slack_is_service() then raise exception '権限がありません'; end if;
  insert into hq_slack_complete_log(task_id) values (p_task) on conflict do nothing; get diagnostics v_n = row_count; return v_n = 1;
end $$;
create or replace function public.hq_slack_complete_release(p_task uuid) returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.hq_slack_is_service() then raise exception '権限がありません'; end if;
  delete from hq_slack_complete_log where task_id = p_task;
end $$;
revoke all on function public.hq_slack_complete_candidates() from public, anon, authenticated;
revoke all on function public.hq_slack_complete_claim(uuid) from public, anon, authenticated;
revoke all on function public.hq_slack_complete_release(uuid) from public, anon, authenticated;
grant execute on function public.hq_slack_complete_candidates() to service_role;
grant execute on function public.hq_slack_complete_claim(uuid) to service_role;
grant execute on function public.hq_slack_complete_release(uuid) to service_role;

-- 定期実行: 7:00〜23:55（日本時間）の 5 分ごと = UTC 22:00〜14:55
create or replace function public.hq_task_completions_trigger() returns void language plpgsql security definer set search_path to 'public', 'net', 'extensions' as $$
declare
  c_fn   constant text := 'https://uuvsxzhpxtghojoubjcc.supabase.co/functions/v1/hq-task-reminders';
  c_anon constant text := 'sb_publishable_MrwPJAx_Ws_fdRutprKCiQ_dg3wCiTr';
  v_secret text; v_req bigint;
begin
  select value into v_secret from app_secrets where key = 'notify_slack_secret';
  if v_secret is null or length(trim(v_secret)) = 0 then raise warning 'hq_task_completions_trigger: app_secrets.notify_slack_secret が未設定'; return; end if;
  select net.http_post(url := c_fn,
    headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', c_anon, 'Authorization', 'Bearer ' || c_anon, 'x-notify-secret', trim(v_secret)),
    body := jsonb_build_object('op', 'completions', 'trigger', 'pg_cron'), timeout_milliseconds := 60000) into v_req;
end $$;
revoke all on function public.hq_task_completions_trigger() from public, anon, authenticated;
select cron.schedule('hq-task-completions', '*/5 22-23,0-14 * * *', 'select public.hq_task_completions_trigger()');
