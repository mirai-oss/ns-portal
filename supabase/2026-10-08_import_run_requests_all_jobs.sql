-- システム利用状況「⚙️自動取込ジョブ一覧（全システム横断）」からの「▶ 再実行」ボタン用（2026-10-08・ユーザー要望
-- 「失敗したタスクを管理システムから再実行できるように」）。
--
-- 背景: 2026-09-25_import_run_requests.sql の INSERT ポリシーは「月次・有効・kind∈deposit/purchase/sales」のジョブ
-- だけを再実行依頼できる条件だった（会計・請求WS「自動取込＞未取得」用）。全ジョブ（毎日のDinii/インフォマート/
-- ロケットナウ/PayPay銀行等）も再実行できるよう、対象を「import_schedule に登録された有効なジョブ全て」へ広げる。
-- それ以外の安全策（有効なマスター／CEO／HQのみ・同一ジョブの重複依頼禁止・Mac mini側の再チェック）は変更しない。
--
-- 【影響】INSERTポリシー1本の差し替えのみ。テーブル・既存データ・ジョブのロジックは変更しない。
-- 【rollback】 2026-09-25_import_run_requests.sql の insert_hq ポリシー定義を再実行すれば元（月次・会計系のみ）に戻る。

drop policy if exists import_run_requests_insert_hq on public.import_run_requests;
create policy import_run_requests_insert_hq on public.import_run_requests
  for insert to authenticated
  with check (
    status = 'pending'
    and requested_by = auth.uid()
    and exists (
      select 1 from public.users u
      where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO', 'HQ'))
    )
    and job in (select s.job from public.import_schedule s where s.active)
  );
