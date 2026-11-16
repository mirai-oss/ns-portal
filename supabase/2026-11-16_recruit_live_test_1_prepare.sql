-- 2026-11-16 担当B — 採用 STEP 4 テスト（1/2）: テスト応募者の作成 ＋ 「自動で dry に戻る仕組み」の予行（recruit_actions には触れない）
-- 【応募者へは送らない】LINE も カレンダーも呼ばない。テスト応募者は社長（担当＝社長・answers._test=true＝真偽値）。予行は別名の一時行だけを使う
-- 【社内の Slack に1枚出る】応募者の追加で、求人の Slack 通知（recruit_notice_ins）が社内の求人チャンネルに『テスト応募者（社長）』のカードを1枚出す（スタッフが本物と間違えないよう、社長が先にひとこと伝える）
-- 【予行】1分ごとの cron が、絶対時刻（実行から2分後）を過ぎたら 一時行を dry にして 結果の行を残し、その後にだけ自分を unschedule する。何度走っても同じ結果
-- 【後始末】一時行 2 つは、2/2 の SQL が（予行の成功を確かめたあと）消す
do $$
declare v_id uuid := gen_random_uuid(); v_ceo uuid; n int; v_dl timestamptz := now() + interval '2 minutes';
begin
  select count(*) into n from applicants where name = 'テスト応募者（社長）';
  if n > 0 then raise exception '停止: テスト応募者が既にあります'; end if;
  select count(*), min(id::text)::uuid into n, v_ceo from users where role = 'CEO' and is_active;
  if n <> 1 then raise exception '停止: 社長ユーザーが % 名です（1名のはず）', n; end if;
  insert into applicants (id, form_key, name, source, answers, assignee_id)
  values (v_id, 'al', 'テスト応募者（社長）', 'form', '{"_test": true}'::jsonb, v_ceo);

  insert into app_settings (key, value) values ('recruit_revert_selftest', '{"line_mode":"live","calendar_mode":"live"}'::jsonb)
  on conflict (key) do update set value = excluded.value, updated_at = now();
  delete from app_settings where key = 'recruit_revert_selftest_result';
  perform cron.unschedule('recruit-revert-selftest') where exists (select 1 from cron.job where jobname = 'recruit-revert-selftest');
  perform cron.schedule('recruit-revert-selftest', '* * * * *', format($c$
    update public.app_settings set value = value || '{"line_mode":"dry","calendar_mode":"dry"}'::jsonb, updated_at = now()
     where key = 'recruit_revert_selftest' and now() >= %1$L::timestamptz;
    insert into public.app_settings (key, value)
      select 'recruit_revert_selftest_result', jsonb_build_object('reverted_at', now())
       where now() >= %1$L::timestamptz and exists (select 1 from public.app_settings where key = 'recruit_revert_selftest' and value ->> 'line_mode' = 'dry' and value ->> 'calendar_mode' = 'dry')
      on conflict (key) do nothing;
    select cron.unschedule('recruit-revert-selftest')
     where now() >= %1$L::timestamptz and exists (select 1 from public.app_settings where key = 'recruit_revert_selftest_result');
  $c$, v_dl));
end $$;

-- 社長の LINE をつなぐリンク（社長だけに渡す。画面に出た値は、どこにも書き写さない）
select (r ->> 'code') as 連携コード_LINEに手で打つ用, 'https://line.me/R/oaMessage/' || replace(r ->> 'oa', '@', '%40') || '/?' || (r ->> 'code') as 連携リンク_スマホで開く用
  from (select public.apply_line_code(id) as r from applicants where name = 'テスト応募者（社長）') x;
