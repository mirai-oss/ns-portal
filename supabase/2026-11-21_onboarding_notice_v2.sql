-- =============================================================
-- 入社登録の Slack 通知「新しい形」（親は 1 行＋スレッドの先頭に状況カード）: 入社登録ごとの控えの列（2026-11-21・下書き ★本番未適用）
--   いま: 親メッセージに 10 項目の一覧とボタンを全部のせ、成功・失敗・途中経過をどれもスレッドに足している。
--   これから（設定で切り替え・既定は今までの形）: 親＝1 行／スレッドの先頭に「状況カード」1 件（変化のたびに書き換え）／
--     スレッドに足すのは、人の対応が要るものと、人の操作の記録だけ。
--   この SQL がやること: onboarding_workflows に列を 3 つ足すだけ。既存の行は変えない（3 列とも null のまま＝今までの形）。
--     slack_notice_format         どの形で親メッセージを作ったか（null・'v1'＝今までの形／'v2'＝新しい形）。作ったあとは変えない
--     slack_card_notification_id  状況カード（スレッドの 1 通目）の台帳の番号（notification_deliveries.id）
--     slack_parent_permalink      親の［詳細を確認］が開くリンク（状況カードへのリンク。取れなければ null）
--   ★ この SQL は設定を変えない（app_settings.onboarding_slack に format を足さない）。適用しただけでは、通知は今までと同じ。
--     新しい形にするのは、Edge Function onboarding-notify を入れ替えたあとに、下の「切り替え」を別に流したとき（別途承認）。
--   ビュー onboarding_workflow_v は作り直さない（新しい列はビューに出ない。Edge Function は表から直接読む）。
--   既存の表・関数・トリガーは変えない。2026-11-20_onboarding_account_auto_check.sql のあとに適用する。
--   戻し方: 2026-11-21_onboarding_notice_v2_rollback.sql
-- =============================================================

alter table public.onboarding_workflows
  add column if not exists slack_notice_format        text,
  add column if not exists slack_card_notification_id uuid,
  add column if not exists slack_parent_permalink     text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'onboarding_workflows_slack_notice_format_check' and conrelid = 'public.onboarding_workflows'::regclass) then
    alter table public.onboarding_workflows add constraint onboarding_workflows_slack_notice_format_check
      check (slack_notice_format is null or slack_notice_format in ('v1', 'v2'));
  end if;
end $$;

comment on column public.onboarding_workflows.slack_notice_format is 'Slack 通知の形。null・v1＝今までの形（親に一覧とボタン）／v2＝新しい形（親 1 行＋スレッドの先頭に状況カード）。親メッセージを作ったときに決まり、あとから変えない';
comment on column public.onboarding_workflows.slack_card_notification_id is '新しい形の状況カード（スレッドの 1 通目）の台帳の番号（notification_deliveries.id）';
comment on column public.onboarding_workflows.slack_parent_permalink is '新しい形の親の［詳細を確認］が開くリンク（状況カードへのリンク）';

-- API（PostgREST）に新しい列を見せる
notify pgrst, 'reload schema';

-- 確認（適用のあとに見る。3 つとも 0 のはず＝既存の行は今までの形のまま）
select count(*) filter (where slack_notice_format is not null)        as format_set,
       count(*) filter (where slack_card_notification_id is not null) as card_set,
       count(*) filter (where slack_parent_permalink is not null)     as permalink_set,
       count(*)                                                       as workflows
  from public.onboarding_workflows;

-- -------------------------------------------------------------
-- 切り替え（★ここでは流さない。Edge Function の入れ替えと、テスト用の入社登録での通し確認のあとに、別途承認をもらってから）
--   これから親メッセージを作る入社登録だけが新しい形になる。すでに親メッセージがある入社登録は、今までの形のまま最後まで動く。
-- update public.app_settings set value = value || '{"format": "v2"}'::jsonb, updated_at = now() where key = 'onboarding_slack';
-- select value ->> 'format' as format from public.app_settings where key = 'onboarding_slack';
--   戻す（これから作る入社登録を今までの形に。新しい形で作った進行中のものは、新しい形のまま最後まで動く）:
-- update public.app_settings set value = value - 'format', updated_at = now() where key = 'onboarding_slack';
-- -------------------------------------------------------------
