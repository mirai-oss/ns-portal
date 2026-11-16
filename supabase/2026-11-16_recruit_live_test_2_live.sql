-- 2026-11-16 担当B — 採用 STEP 4 テスト（2/2）: line_mode・calendar_mode を live にする ＋ 20分後に dry へ戻す予約（DB 側）
-- 【触るのは line_mode と calendar_mode だけ】send_enabled と recruit_actions のほかのキーは変えない（value || で2キーだけ上書き）。send_enabled=false のまま＝テスト印の無い応募者は全て断られる
-- 【戻し】1分ごとの cron が、絶対時刻（実行から20分後）を過ぎたら 2キーを dry に戻し、戻ったことを確かめたあとにだけ自分を unschedule する（何度走っても同じ結果）
-- 【順序】先に戻しの予約を作り、そのあとで live にする（途中で止まっても live のまま残らない）
-- 【停止の条件】予行が成功していない／send_enabled が false でない／既に live／テスト応募者が LINE 未連携、のどれかなら何も変えずに止まる
do $$
declare v_dl timestamptz := now() + interval '20 minutes'; v_cfg jsonb;
begin
  if not exists (select 1 from app_settings where key = 'recruit_revert_selftest_result') then raise exception '停止: 戻しの予行が成功していません（1/2 を実行して3分待ってください）'; end if;
  if exists (select 1 from cron.job where jobname = 'recruit-revert-selftest') then raise exception '停止: 予行がまだ動いています（もう少し待ってください）'; end if;
  select value into v_cfg from app_settings where key = 'recruit_actions';
  if coalesce(v_cfg ->> 'send_enabled', 'false') <> 'false' then raise exception '停止: send_enabled が false ではありません'; end if;
  if coalesce(v_cfg ->> 'line_mode', 'dry') <> 'dry' or coalesce(v_cfg ->> 'calendar_mode', 'dry') <> 'dry' then raise exception '停止: すでに live になっています'; end if;
  if not exists (select 1 from applicants where name = 'テスト応募者（社長）' and answers ->> '_test' = 'true' and line_user_id is not null) then raise exception '停止: テスト応募者の LINE 連携がまだです'; end if;

  perform cron.unschedule('recruit-live-test-revert') where exists (select 1 from cron.job where jobname = 'recruit-live-test-revert');
  perform cron.schedule('recruit-live-test-revert', '* * * * *', format($c$
    update public.app_settings set value = value || '{"line_mode":"dry","calendar_mode":"dry"}'::jsonb, updated_at = now()
     where key = 'recruit_actions' and now() >= %1$L::timestamptz;
    select cron.unschedule('recruit-live-test-revert')
     where now() >= %1$L::timestamptz and exists (select 1 from public.app_settings where key = 'recruit_actions' and value ->> 'line_mode' = 'dry' and value ->> 'calendar_mode' = 'dry');
  $c$, v_dl));

  update app_settings set value = value || '{"line_mode":"live","calendar_mode":"live"}'::jsonb, updated_at = now() where key = 'recruit_actions';
  delete from app_settings where key in ('recruit_revert_selftest', 'recruit_revert_selftest_result');
  raise notice 'live にしました。戻りは % 以降（約20分後）に自動です', v_dl;
end $$;

select value ->> 'line_mode' as line_mode, value ->> 'calendar_mode' as calendar_mode, value ->> 'send_enabled' as send_enabled from app_settings where key = 'recruit_actions';
