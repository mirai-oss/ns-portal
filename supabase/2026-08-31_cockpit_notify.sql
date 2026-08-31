-- =============================================================
-- AI開発コックピット: 「完了→次の担当が動く」連携と通知の列追加（2026-08-31・冪等）
-- ck_tasks に2列追加:
--   on_done_note … 完了したら次に何が起きるか（Lark通知に載せるメモ）
--   unblocks     … 完了時に自動で「着手可(ready)」へ動かすタスク（TK番号カンマ区切り）
-- Lark通知先は app_secrets の cockpit_lark_webhook（別途登録・URLはリポジトリに書かない）
-- =============================================================

alter table ck_tasks add column if not exists on_done_note text not null default '';
alter table ck_tasks add column if not exists unblocks text not null default '';

-- 既存タスクへ「完了したら誰がどう動くか」を設定（タイトル一致・上書きしない冪等条件付き）
update ck_tasks set on_done_note = '会計自動化（給与明細→MF仕訳・インフォマート）の実装が担当C・D・B・Fで着手可能になります（Sync5）。司令塔へ次ラウンド指示書の発行を依頼してください'
  where title like '設計ゲート: 会計自動化%' and on_done_note = '';
update ck_tasks set on_done_note = '広告費自動連携・精算書PL科目連携の実装割当が可能になります（担当A/G）'
  where title like '設計ゲート: 広告費連携%' and on_done_note = '';
update ck_tasks set on_done_note = '有給申請機能の実装が担当Bで着手可能になります'
  where title like '設計ゲート: 有給申請%' and on_done_note = '';
update ck_tasks set on_done_note = '給与明細・勤怠バックフィルの自動同期が毎朝動き出します（追加作業なし）'
  where title like 'cron-job.orgへジョブ2本追加%' and on_done_note = '';
update ck_tasks set on_done_note = 'コックピット本稼働。以後はタスクの完了・ブロック・エラー・承認依頼がLark（経理）にも通知されます'
  where title like 'コックピット: 実機確認%' and on_done_note = '';
