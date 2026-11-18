-- ============================================================
-- 2026-11-18 担当B（社長の依頼・司令塔了承）— 本部タスクのコメントでメンションされた人に、個人の Slack DM でも通知する（hq_notify_comment への追記だけ）
-- 【状態】事前報告（未適用・社長の承認待ち）
-- 【背景】メンション通知は個人の Chatwork ルームにしか出ず、本部メンバーの大半が未登録で届いていなかった。Slack への経路が未実装（2026-10-29_slack_notify_phase1.sql §7 の宿題）
-- 【変更】①hq_notify_comment に、メンションされた人（Slack 紐づけ済み・自分自身は除く）への Slack DM を1通足す（本文: 誰が・タスク名・コメント冒頭200字・そのタスクの直近5件のコメントの履歴・タスクを開くリンク）。Chatwork 送信・アプリ内通知（hq_notifications）は今のまま・順番も変えない。
--   ②スイッチ app_settings.hqtask_comment_slack_dm（社長の承認どおり、最初は社長1人だけ enabled=true・only_user_ids=[社長]）。ほかの人には何も送られない。全員に広げるのは別の SQL（承認後）
--   ③二重送信防止の小さな表 hqtask_comment_slack_sent（同じコメント×同じ相手は1回）。Slack 側が失敗しても関数全体は失敗させない（例外を握る）
-- 【安全ガード】本番の現在の定義が 2026-10-29 のスナップショット版（md5 0e9bcdc204e6bed7618e1352e47f9a0b）と一致しなければ停止（何も変更しない）
-- 【影響】hq_notify_comment の戻り値・Chatwork 経路は不変。社長1人だけが対象のため、ほかの人の挙動は変わらない。hqtask_*（EF）の DM とは別の種類（コメントのメンション）で二重にならない
-- 【rollback】スイッチを false に戻す／関数をスナップショット版（restored/2026-10-29_notify_functions_prod_snapshot.sql の hq_notify_comment）で create or replace し直す（表は残して無害）
-- ============================================================
do $$
declare n int; r record;
begin
  select count(*) into n from pg_proc where proname = 'hq_notify_comment' and pronamespace = 'public'::regnamespace;
  if n <> 1 then raise exception '停止: hq_notify_comment が % 本あります（1本のはず）', n; end if;
  select p.prosrc, pg_get_function_identity_arguments(p.oid) as args, p.prosecdef into r from pg_proc p where p.proname = 'hq_notify_comment' and p.pronamespace = 'public'::regnamespace;
  if r.args <> 'p_comment_id uuid' or not r.prosecdef then raise exception '停止: 引数/SECURITY DEFINER が想定と違います（%）', r.args; end if;
  if md5(r.prosrc) <> '0e9bcdc204e6bed7618e1352e47f9a0b' then
    raise exception '停止: 本番の本文の指紋が想定と一致しません（本番=%・長さ=%）。何も変更していません', md5(r.prosrc), length(r.prosrc);
  end if;
end $$;

create table if not exists hqtask_comment_slack_sent (
  comment_id uuid not null,
  user_id uuid not null,
  sent_at timestamptz not null default now(),
  primary key (comment_id, user_id)
);
alter table hqtask_comment_slack_sent enable row level security;
revoke all on hqtask_comment_slack_sent from public, anon, authenticated;
comment on table hqtask_comment_slack_sent is '本部タスクのコメントのメンションを Slack DM に出した記録（二重送信防止）。担当B・2026-11-18';

-- 最初は社長1人だけ ON（到着確認用）。全員にするときは only_user_ids を [] にする（別の SQL・社長の承認のあと）
insert into app_settings (key, value)
select 'hqtask_comment_slack_dm', jsonb_build_object('enabled', true, 'only_user_ids', jsonb_build_array(c.id::text),
         'note', '本部タスクのコメントのメンションを Slack DM にも出す。enabled=true で有効。only_user_ids が空でなければその人だけ（到着確認用）')
  from (select id from users where role = 'CEO' and is_active) c
 where (select count(*) from users where role = 'CEO' and is_active) = 1
on conflict (key) do nothing;

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

      -- 2026-11-18 追記: メンションされた人が Slack 紐づけ済みなら、個人の Slack DM にも 1 通（Chatwork の送信は下のまま・順番も変えない）。
      --   スイッチ app_settings.hqtask_comment_slack_dm（enabled=false が既定・only_user_ids が空でなければその人だけ）。同じコメント×同じ相手は 1 回だけ。失敗しても関数全体は失敗させない
      begin
        select value into v_dm from app_settings where key = 'hqtask_comment_slack_dm';
        if coalesce((v_dm ->> 'enabled')::boolean, false)
           and (coalesce(jsonb_array_length(v_dm -> 'only_user_ids'), 0) = 0 or (v_dm -> 'only_user_ids') ? v_uid::text)
           and exists (select 1 from user_slack where user_id = v_uid) then
          insert into hqtask_comment_slack_sent(comment_id, user_id) values (p_comment_id, v_uid) on conflict do nothing;
          get diagnostics v_ins = row_count;
          if v_ins = 1 then
            select name into v_from from users where id = v_com.created_by;
            -- コメントの履歴: このタスクの直近5件（今回のコメントは除く）を、古い順に 1 行ずつ（名前・日時・冒頭60字）
            select string_agg('・' || h.nm || '（' || to_char(h.cat at time zone 'Asia/Tokyo', 'MM/DD HH24:MI') || '）' || h.bd, E'\n' order by h.cat) into v_hist
              from (select c.created_at as cat, coalesce(u.name, '不明') as nm, left(replace(c.body, E'\n', ' '), 60) as bd
                      from hq_task_comments c left join users u on u.id = c.created_by
                     where c.task_id = v_task.id and c.id <> p_comment_id order by c.created_at desc limit 5) h;
            perform set_config('ns.notify_event', 'hqtask_comment_mention', true);
            perform notify_route_send('slack', 'user:' || v_uid::text,
              '💬 ' || coalesce(v_from, '誰か') || 'さんが、あなたをメンションしました' || E'\n' || '【' || v_task.title || '】' || E'\n' || left(replace(v_com.body, E'\n', ' '), 200)
              || case when v_hist is not null then E'\n\n—— これまでのコメント（古い順・直近5件）——\n' || v_hist else '' end
              || E'\n\n▶ タスクを開く: ' || v_url);
          end if;
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
select count(*) as 本数, bool_and(p.prosecdef) as security_definer, bool_or(p.prosrc like '%hqtask_comment_slack_dm%') as Slack_DMの追記あり,
       bool_or(p.prosrc like '%hq_user_chatwork%') as Chatworkの経路は残っている from pg_proc p where p.proname = 'hq_notify_comment' and p.pronamespace = 'public'::regnamespace;
select value ->> 'enabled' as enabled, value -> 'only_user_ids' as only_user_ids from app_settings where key = 'hqtask_comment_slack_dm';
select a.grantee::regrole::text as grantee, a.privilege_type from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
 where p.proname = 'hq_notify_comment' and p.pronamespace = 'public'::regnamespace order by 1;
