-- 2026-11-21_onboarding_notice_v2.sql の戻し（下書き ★本番未適用）
--   ふだんの戻し方は「設定だけ」で足りる（下の 1）。列まで消すのは、列そのものが邪魔になったときだけ（下の 2・3）。
--   列を消すと、Edge Function はどの入社登録も「今までの形」として動く（新しい形で作った進行中の入社登録は、次の更新で
--   親メッセージが今までの大きなカードに書き換わり、スレッドの状況カードは最後の表示のまま残る。操作は今までどおりできる）。

-- 1) これから作る入社登録を、今までの形に戻す（設定から format を外す）
update public.app_settings set value = value - 'format', updated_at = now() where key = 'onboarding_slack' and value ? 'format';

-- 2) 列を消す前の確認: 新しい形で進行中の入社登録が残っていたら止める（消してよいと決めたときは、この do ブロックを外して流す）
do $$
declare n int;
begin
  select count(*) into n from public.onboarding_workflows where slack_notice_format = 'v2' and status not in ('completed', 'cancelled');
  if n > 0 then
    raise exception '新しい形（v2）で進行中の入社登録が % 件あります。完了・中止を待つか、消してよいと決めてから流してください', n;
  end if;
end $$;

-- 3) 列を消す（ほかの表・関数・ビューは、この列を使っていない）
alter table public.onboarding_workflows drop constraint if exists onboarding_workflows_slack_notice_format_check;
alter table public.onboarding_workflows
  drop column if exists slack_notice_format,
  drop column if exists slack_card_notification_id,
  drop column if exists slack_parent_permalink;

notify pgrst, 'reload schema';

-- 確認（0 行のはず）
select column_name from information_schema.columns
 where table_schema = 'public' and table_name = 'onboarding_workflows'
   and column_name in ('slack_notice_format', 'slack_card_notification_id', 'slack_parent_permalink');
