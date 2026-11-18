-- ============================================================
-- 2026-11-18 担当B（社長の依頼）— 本部タスクのメンション DM を「親投稿はシンプル・コメントの流れはスレッド」に変える
-- 【状態】事前報告（未適用・社長の承認待ち）。前提: 2026-11-18_hq_notify_comment_slack_dm.sql 適用済み・Edge Function hqtask-comment-dm デプロイ済み
-- 【変更】①DM 本文の組み立てと送信を Edge Function hqtask-comment-dm に移す（親＝「○○さんが、あなたをメンションしました／【タスク名】／▶ タスクを開く」・スレッド＝そのタスクの直近のコメント〈古い順・今回が最後〉）
--   ②DM の投稿 ts を対応表 hqtask_comment_slack_sent に保存する列を足す（task_id・slack_channel・slack_ts＝スレッドへの返信を取り込む第2段階の土台）
--   ③hq_notify_comment は、スイッチ・Slack 紐づけを確かめて EF を呼ぶだけに（Chatwork・アプリ内通知は不変・失敗は握る）
-- 【安全ガード】本番の hq_notify_comment が前回適用した版（md5 00d24ef625e4ce7042e2c260e76e9e6a）と一致しなければ停止
-- 【影響】メンション DM の見え方だけ変わる（スイッチは社長1人のまま）。DB 側のコメント本文の組み立ては無くなる
-- 【rollback】2026-11-18_hq_notify_comment_slack_dm.sql の関数で create or replace し直す（EF が呼ばれなくなる）
-- ============================================================
do $$
declare n int; r record;
begin
  select count(*) into n from pg_proc where proname = 'hq_notify_comment' and pronamespace = 'public'::regnamespace;
  if n <> 1 then raise exception '停止: hq_notify_comment が % 本あります（1本のはず）', n; end if;
  select p.prosrc into r from pg_proc p where p.proname = 'hq_notify_comment' and p.pronamespace = 'public'::regnamespace;
  if md5(r.prosrc) <> '00d24ef625e4ce7042e2c260e76e9e6a' then
    raise exception '停止: 本番の本文の指紋が前回適用した版と一致しません（本番=%）。何も変更していません', md5(r.prosrc);
  end if;
end $$;

alter table hqtask_comment_slack_sent add column if not exists task_id uuid;
alter table hqtask_comment_slack_sent add column if not exists slack_channel text;
alter table hqtask_comment_slack_sent add column if not exists slack_ts text;

create or replace function public.hqtask_comment_dm_call(p_comment uuid, p_user uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'net', 'extensions'
as $f$
declare
  c_fn   constant text := 'https://uuvsxzhpxtghojoubjcc.supabase.co/functions/v1/hqtask-comment-dm';
  c_anon constant text := 'sb_publishable_MrwPJAx_Ws_fdRutprKCiQ_dg3wCiTr';
  v_secret text; v_req bigint;
begin
  select value into v_secret from app_secrets where key = 'notify_slack_secret';
  if v_secret is null or length(trim(v_secret)) = 0 then raise warning 'hqtask_comment_dm_call: notify_slack_secret 未設定'; return; end if;
  select net.http_post(
    url := c_fn,
    headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', c_anon, 'Authorization', 'Bearer ' || c_anon, 'x-notify-secret', trim(v_secret)),
    body := jsonb_build_object('comment_id', p_comment, 'recipient_id', p_user),
    timeout_milliseconds := 20000
  ) into v_req;
end $f$;
revoke all on function public.hqtask_comment_dm_call(uuid, uuid) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.hq_notify_comment(p_comment_id uuid)
 RETURNS TABLE(channel_kind text, target text, keyword text, title text, body text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_com record; v_task record; v_uid uuid;
  v_kinds text[] := '{}'; v_targets text[] := '{}'; v_kws text[] := '{}'; v_titles text[] := '{}'; v_bodies text[] := '{}';
  v_ch record; v_cw text; v_title text; v_body text; v_uname text; v_personal text;
  v_url text;
  v_dm jsonb; v_from text; v_ins int; v_hist text; -- 2026-11-18 追記（Slack DM）
begin
  select * into v_com from hq_task_comments where id = p_comment_id;
  if v_com is null then return; end if;
  select * into v_task from hq_tasks where id = v_com.task_id;
  if v_task is null then return; end if;
  v_url := 'https://mirai-oss.github.io/ns-portal/tasks.html?task=' || v_task.id;
  v_title := 'メンションされました: ' || v_task.title;

  foreach v_uid in array coalesce(v_com.mentions, '{}') loop
    if v_uid <> v_com.created_by then
      insert into hq_notifications(recipient_id, task_id, kind, title, body)
      values (v_uid, v_task.id, 'mention', v_title, v_com.body);

      -- 2026-11-18 追記（改訂）: メンションされた人が Slack 紐づけ済みなら、個人の Slack DM を「親（短い）＋スレッド（コメントの流れ）」で送る。
      --   実際の送信と重複防止は Edge Function hqtask-comment-dm が行う（DM の投稿 ts も保存＝スレッド返信の土台）。ここではスイッチ・紐づけだけ確かめて呼ぶ（Chatwork の送信は下のまま・順番も変えない）。失敗しても関数全体は失敗させない
      begin
        select value into v_dm from app_settings where key = 'hqtask_comment_slack_dm';
        if coalesce((v_dm ->> 'enabled')::boolean, false)
           and (coalesce(jsonb_array_length(v_dm -> 'only_user_ids'), 0) = 0 or (v_dm -> 'only_user_ids') ? v_uid::text)
           and exists (select 1 from user_slack where user_id = v_uid) then
          perform hqtask_comment_dm_call(p_comment_id, v_uid);
        end if;
      exception when others then null;
      end;

      select account_id into v_cw from hq_user_chatwork where user_id = v_uid;
      select name into v_uname from users where id = v_uid;
      v_body := (case when v_cw is not null then '[To:'||v_cw||']' else coalesce(v_uname,'') end) || ' ' || v_com.body || E'\n' || v_url;

      v_personal := hq_personal_chatwork_room_for_event(v_uid, 'mention');
      if v_personal is not null then
        v_kinds := v_kinds || 'chatwork'::text; v_targets := v_targets || v_personal; v_kws := v_kws || ''::text;
        v_titles := v_titles || v_title; v_bodies := v_bodies || v_body;
      end if;

      for v_ch in
        select distinct c.kind as ckind, coalesce(c.webhook_url, c.room_id) as ctarget, c.keyword from hq_notify_rules r
        join hq_notify_channels c on c.id = any(r.channel_ids)
        where r.is_active and c.is_active and c.kind in ('lark_webhook','chatwork') and r.event='mention'
          and (r.target_corp is null or r.target_corp=v_task.corp)
          and (r.target_freq is null or r.target_freq=v_task.freq)
          and (r.target_template_id is null or r.target_template_id=v_task.template_id)
      loop
        v_kinds := v_kinds || v_ch.ckind; v_targets := v_targets || v_ch.ctarget; v_kws := v_kws || coalesce(v_ch.keyword,'');
        v_titles := v_titles || v_title; v_bodies := v_bodies || v_body;
      end loop;
    end if;
  end loop;

  return query select k,t,kw,ti,bo from unnest(v_kinds,v_targets,v_kws,v_titles,v_bodies) as x(k,t,kw,ti,bo);
end;
$function$;

-- ===== 適用後の確認（無害）=====
select (select count(*) from pg_proc where proname = 'hq_notify_comment' and pronamespace = 'public'::regnamespace) as 関数の本数,
       (select bool_or(prosrc like '%hqtask_comment_dm_call%') from pg_proc where proname = 'hq_notify_comment' and pronamespace = 'public'::regnamespace) as EFを呼ぶ形になっている,
       (select count(*) from information_schema.columns where table_name = 'hqtask_comment_slack_sent' and column_name in ('task_id', 'slack_channel', 'slack_ts')) as 追加した列の数;
select a.grantee::regrole::text as grantee, a.privilege_type from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
 where p.proname = 'hqtask_comment_dm_call' and p.pronamespace = 'public'::regnamespace order by 1;
