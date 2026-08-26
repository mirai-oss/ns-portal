-- ============================================================
-- 担当G: データ出力センター G-2（実装指示書_ラウンド3_2026-08-26.md）
-- 銀行返済予定表の出力テンプレート追加。データ源=F-8（ns-info-system /api/loan-repayment-feed）。
-- Sync3宣言済み（F-8完了）につき着手。既存ファイルは編集せず新規ファイルで追補する。冪等。
-- ============================================================

insert into tpl_templates (template_code, template_name, category, description, renderer_key, layout, is_active)
values (
  'loan_repayment',
  '銀行返済予定表',
  '経理',
  '対象期間を指定し、法人×店舗×年月の支払利息・返済元金の予定表と法人サマリーをExcel/CSVで出力する。データ源はns-info-systemの/api/loan-repayment-feed（F-8・借入ごとの店舗按分済み集計）。財務データのため出力可能ロールはマスター/CEO/HQのみに限定する。テンプレートファイルは未登録（後日アップロードするとそのデザインが自動適用される）。',
  'loan_repayment_v1',
  '{"header_row": 3, "data_start_row": 4, "label_col": 1, "value_start_col": 2}'::jsonb,
  true
)
on conflict (template_code) do update set
  template_name = excluded.template_name,
  category = excluded.category,
  description = excluded.description,
  renderer_key = excluded.renderer_key,
  layout = excluded.layout,
  updated_at = now();

-- 確認用（実行はしない・手動確認時のコメント）:
-- select template_code, template_name, category from tpl_templates where template_code='loan_repayment';
