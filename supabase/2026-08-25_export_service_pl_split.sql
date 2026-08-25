-- ============================================================
-- 担当G: データ出力センター Phase 1 追補
-- ユーザーフィードバック（2026-08-25）を受けた月次PL／年間推移PLの分離。
-- 既存の2026-08-25_export_service.sqlは編集せず、新規ファイルで追補する（プロジェクト規約）。
--
-- 変更点:
--   ①「売上・仕入が入っていない」への対応はコード側（export-run/export-preview）のみで完結
--     （fact_daily_store由来の売上高・原価・人件費（自動）をstg_pl（手入力）と合成する）。
--     DBスキーマの変更は不要。
--   ②「月次PLと年間推移PLを分ける」ため、tpl_templatesに新規テンプレート行を追加する
--     （template_code='pl_annual_trend'）。レンダラー・テンプレートファイルはpl_monthlyと共有
--     （見た目のスタイルは同一で、期間の粒度（1ヶ月 or 複数ヶ月）と用途の違いのみ）。
-- 冪等。
-- ============================================================

insert into tpl_templates (template_code, template_name, category, description, renderer_key, layout, is_active)
values (
  'pl_annual_trend',
  '年間推移PL',
  '経営・売上',
  '対象期間（複数月）・対象店舗（複数選択可）を指定し、月別の推移がわかる形で店舗別PLと合算PLをExcel/CSVで出力する。月次PLと同じデータ・同じテンプレートを使うが、複数月の推移比較を主目的とする。',
  'pl_monthly_v1',
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

-- pl_monthlyのfile_path（テンプレートファイル）をpl_annual_trendにも共有させる
-- （テンプレートファイルは1つだけ登録済み・見た目のスタイルは両者で同一のため）
update tpl_templates t2
set file_path = t1.file_path, version = t1.version
from tpl_templates t1
where t1.template_code = 'pl_monthly' and t2.template_code = 'pl_annual_trend' and t1.file_path is not null;

-- pl_monthlyの説明文も更新（当初は「手入力の販管費のみ」の想定だったが、売上・原価・人件費（自動）を
-- 合成する設計に変更したため、説明を実態に合わせる）
update tpl_templates
set description = '対象期間（通常は1ヶ月）・対象店舗（複数選択可）を指定し、売上高・原価・粗利・人件費・広告費・家賃・その他経費・営業利益までの完全なPLを店舗別＋合算でExcel/CSVで出力する。売上高・原価（自動）・人件費（自動）はBigQuery fact_daily_store、その他の販管費はstg_pl（PL管理システムの手入力）から取得し合成する。',
    updated_at = now()
where template_code = 'pl_monthly';

-- 確認用（実行はしない・手動確認時のコメント）:
-- select template_code, template_name, file_path, version from tpl_templates where template_code in ('pl_monthly','pl_annual_trend');
