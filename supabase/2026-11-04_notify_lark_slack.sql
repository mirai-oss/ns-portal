-- =============================================================
-- Slack通知基盤 Phase 2（TK-248）: notify_lark（社長専用 Lark: 現金手渡し完了・給与タスク完了）を Slack にも並行送信（2026-11-04）
-- 呼び出し元: cash_handoff_complete / hq_check_payroll_task_item（snapshot 2026-10-29 参照）
-- 変更点は本番スナップショットとの差分 1 行（notify_route_send('slack','hq.keiri_kanshi', p_text)）だけ。Lark 側は従来どおり。
-- 適用: python3 scripts/apply_sql.py supabase/2026-11-04_notify_lark_slack.sql
-- 戻し方: supabase/restored/2026-10-29_notify_functions_prod_snapshot.sql の notify_lark を再適用
-- =============================================================
CREATE OR REPLACE FUNCTION public.notify_lark(p_text text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net', 'extensions'
AS $function$
declare v_url text; v_req bigint;
begin
  perform notify_route_send('slack', 'hq.keiri_kanshi', p_text); -- 2026-11-04 Slack #本部-経理監視 にも並行送信（台帳に残る）
  select value into v_url from app_secrets where key = 'lark_webhook';
  if v_url is null or length(trim(v_url)) = 0 then
    insert into lark_log(ok, message, detail) values (false, left(p_text,300), 'Webhook URLが未設定');
    return;
  end if;
  begin
    select net.http_post(
      url := trim(v_url),
      headers := '{"Content-Type":"application/json"}'::jsonb,
      body := jsonb_build_object('msg_type','text','content',jsonb_build_object('text',p_text))
    ) into v_req;
    insert into lark_log(ok, message, detail) values (true, left(p_text,300), 'request_id=' || coalesce(v_req::text,'?'));
  exception when others then
    insert into lark_log(ok, message, detail) values (false, left(p_text,300), SQLERRM);
  end;
end $function$;
