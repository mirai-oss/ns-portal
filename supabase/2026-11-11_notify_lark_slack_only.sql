-- ============================================================
-- 2026-11-11 担当B（設計の指示・ユーザー方針）— notify_lark の Lark 送信を停止し、Slack(#本部-経理監視) だけに送る
-- 【状態】事前報告（未適用・ユーザーの実行承認待ち）
-- 【理由】ユーザー「Slack にも通知しているものは Lark と Chatwork の通知を解除してよい」。notify_lark は 11/4 から Slack へ並行送信済み。
--   呼び出し元（現金手渡し完了・本部タスク完了・給料確定の結果・手渡し取消・整合チェック・未完了アラート 等）は関数を呼ぶだけなので、ここ1か所の変更で全て Slack のみになる
-- 【変更】notify_lark の本文から Lark webhook への送信（app_secrets.lark_webhook ＋ lark_log記録）を外し、notify_route_send('slack','hq.keiri_kanshi', 本文) だけにする。
--   関数名・引数・戻り値は同じ（呼び出し元は変更不要）。app_secrets.lark_webhook は削除しない（全停止の確認後に別途）
-- 【安全ガード】本番の現在の定義が 2026-11-04 版（md5 ef15391b54afe0f3052e19907bbbc28d）と一致しなければ停止（何も変更しない）
-- 【権限】実行は authenticated（ログイン済み）と service_role のみに絞る（PUBLIC/anon は外す。呼び出し元は SECURITY DEFINER 関数と pg_cron で、これで影響なし）
-- 【rollback】supabase/2026-11-04_notify_lark_slack.sql の notify_lark を再適用（Lark 送信が復活）
-- ============================================================

do $$
declare n int; r record;
begin
  select count(*) into n from pg_proc where proname = 'notify_lark' and pronamespace = 'public'::regnamespace;
  if n <> 1 then raise exception '停止: notify_lark が % 本あります（1本のはず）', n; end if;
  select p.prosrc, pg_get_function_identity_arguments(p.oid) as args, p.prosecdef into r from pg_proc p where p.proname = 'notify_lark' and p.pronamespace = 'public'::regnamespace;
  if r.args <> 'p_text text' or not r.prosecdef then raise exception '停止: 引数/SECURITY DEFINER が想定と違います（%）', r.args; end if;
  if md5(r.prosrc) <> 'ef15391b54afe0f3052e19907bbbc28d' then
    raise exception '停止: 本番の本文の指紋が11-04版と一致しません（本番=%・長さ=%）。何も変更していません', md5(r.prosrc), length(r.prosrc);
  end if;
end $$;

create or replace function public.notify_lark(p_text text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'net', 'extensions'
as $function$
begin
  -- 2026-11-11 ユーザー方針: Lark への送信は停止。Slack #本部-経理監視 のみ（呼び出し元はこれまでどおり notify_lark を呼べばよい）
  perform notify_route_send('slack', 'hq.keiri_kanshi', p_text);
end $function$;

revoke all on function public.notify_lark(text) from public, anon;
grant execute on function public.notify_lark(text) to authenticated, service_role;

-- ===== 適用後の確認（無害）=====
select count(*) as 本数, bool_and(p.prosecdef) as security_definer, md5(max(p.prosrc)) as 本文の指紋,
       bool_or(p.prosrc like '%notify_route_send(''slack''%') as Slack送信が残っている,
       bool_or(p.prosrc like '%net.http_post%' or p.prosrc like '%lark_webhook%') as Lark送信が残っている
  from pg_proc p where p.proname = 'notify_lark' and p.pronamespace = 'public'::regnamespace;
select a.grantee::regrole::text as grantee, a.privilege_type
  from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
 where p.proname = 'notify_lark' and p.pronamespace = 'public'::regnamespace order by 1;
