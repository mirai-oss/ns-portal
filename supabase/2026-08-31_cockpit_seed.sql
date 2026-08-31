-- =============================================================
-- AI開発コックピット 初期データ（2026-08-31時点の実タスクを投入）
-- 出典: WORKLOG.md「📍現在の状況」＋「📋 全体バックログ・統合版」＋実装指示書_ラウンド5
-- 冪等: ck_tasksが空のときだけ投入（2回実行しても重複しない）
-- 実行方法: 2026-08-31_cockpit.sql のあとにSQL Editorへ貼り付けてRun
-- =============================================================

insert into ck_tasks
  (title, description, priority, project, category, assignee_type, assignee_name, repository, status, progress_percent, completed_at)
select * from (values
  -- ラウンド5・AIレーン
  ('PL人件費のAPI切替（2026年8月分〜）', 'ダッシュボードPL人件費をスプレッドシートからAPI連携値へ切替（8月分から・それ以前はシートのまま）。A優先順①', 'highest', 'tori-dashboard', '実装', 'ai', '担当A', 'tori-dashboard', 'ready', 0, null::timestamptz),
  ('A-7: 精算ダッシュボードUI刷新', '確定モック: docs/mockups/NStyle_統合ポータル_精算ダッシュボード_UI_v3_プレビューPDFメール対応.html。A優先順②', 'high', 'tori-dashboard', '実装', 'ai', '担当A', 'tori-dashboard', 'ready', 0, null),
  ('A-6 Phase2: 予約タブ続き', '予約データ基盤の表示側フェーズ2。A優先順③', 'mid', 'tori-dashboard', '実装', 'ai', '担当A', 'tori-dashboard', 'backlog', 0, null),
  ('E-4: 工程名の変更＋タスク削除', '本部タスクの工程名変更・タスク論理削除（hq_task_activityへ記録）。ラウンド5§1', 'high', 'ns-portal', '実装', 'ai', '担当E', 'ns-portal', 'ready', 0, null),
  ('E-5: 現在工程の期日ベース表示', '一覧・絞り込みの期日を「いま止まっている工程の期日」に（全体期日と2段表示推奨）。ラウンド5§1', 'mid', 'ns-portal', '実装', 'ai', '担当E', 'ns-portal', 'ready', 0, null),
  ('F-9: ID/PW変更申請・承認・履歴', '変更申請フォーム・承認フロー・履歴。承認者は着手時にユーザーへ1問確認。ラウンド5§1', 'high', 'ns-portal', '実装', 'ai', '担当F', 'ns-portal', 'ready', 0, null),
  ('D-7: dinii調査', '前ラウンド持ち越し・着手可。ラウンド5§4', 'mid', '横断', '調査', 'ai', '担当D', '', 'ready', 0, null),
  ('D-8: Hermes Agent比較', '前ラウンド持ち越し・着手可。ラウンド5§4', 'low', '横断', '調査', 'ai', '担当D', '', 'ready', 0, null),
  -- 中山さんの確認待ち（設計ゲート・ユーザー作業）
  ('cron-job.orgへジョブ2本追加', 'smaregi-payroll-sync=毎日08:30 JST・smaregi-attendance-backfill=毎日08:45 JST。手順は各ymlファイル冒頭のコメント参照', 'high', 'ns-portal', 'ユーザー作業', 'human', '中山', '', 'waiting_human', 0, null),
  ('設計ゲート: 会計自動化の質問回答（会計Q1〜Q6）', '給与明細→MF仕訳＋明細添付／インフォマート発注明細→BQ・MF証憑・振込CSV。回答→確定でC・D・B・Fが着手可能（Sync5）。設計書_会計自動化_給与明細とインフォマート支払_2026-08-31.md', 'high', '横断', '設計ゲート', 'human', '中山', '', 'waiting_human', 0, null),
  ('設計ゲート: 広告費連携・精算書PL科目の質問回答（広告Q1〜Q4）', '請求書→広告費自動反映／精算書の勘定科目→PL連携。設計書_広告費自動連携と精算書PL科目連携_2026-08-31.md', 'mid', '横断', '設計ゲート', 'human', '中山', '', 'waiting_human', 0, null),
  ('設計ゲート: 有給申請の質問回答（有給Q1〜Q2）', 'ラウンド5§2.1参照', 'mid', 'nippo', '設計ゲート', 'human', '中山', '', 'waiting_human', 0, null),
  -- AI開発コックピット本体
  ('コックピット: 監査・担当別指示書の発行', '調査レポート_AI開発コックピット_2026-08-31.md／実装指示書_AI開発コックピット_担当別_2026-08-31.md', 'highest', 'ns-portal', '実装', 'ai', '司令塔', 'ns-portal', 'done', 100, now()),
  ('コックピット: Phase1-2実装（DB・画面・導線・ingest・CLI）', 'cockpit.html／ck_系SQL／portal.htmlメニュー1行／cockpit-ingest／tools/ai-cockpit。ユーザー指示により司令塔スレッドが一括実装', 'highest', 'ns-portal', '実装', 'ai', '担当H', 'ns-portal', 'in_progress', 90, null),
  ('コックピット: SQL実行（このタスクが見えていれば完了済み）', '2026-08-31_cockpit.sql→cockpit_seed.sql→トークンSQLの3本をSQL Editorで実行。手順書_コックピット_セットアップ_2026-08-31.md', 'highest', 'ns-portal', 'ユーザー作業', 'human', '中山', '', 'waiting_human', 0, null),
  ('コックピット: 実機確認（Mac mini/MacBook両方で開く）', 'ポータル→管理→🛠️AI開発コックピット。2台で同じ内容が見えること・マスター以外のアカウントでメニューに出ないこと', 'high', 'ns-portal', 'ユーザー作業', 'human', '中山', '', 'waiting_human', 0, null)
) as v(title, description, priority, project, category, assignee_type, assignee_name, repository, status, progress_percent, completed_at)
where not exists (select 1 from ck_tasks);
