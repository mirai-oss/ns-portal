-- ============================================================
-- 担当G: データ出力センター Phase 1 追補②
-- ユーザー要望（2026-08-25）: 広告媒体ごとの費用・売上（ROAS）を出力できるようにする。
-- 既存のexport_service.sql / export_service_pl_split.sqlは編集せず、新規ファイルで追補する。
--
-- 設計方針（ユーザー指示どおり）: 「テンプレートは後から作って、その内容に連動して入るように
-- 先に設計しておく」。tpl_templatesの行だけ先に登録し、file_pathはnullのまま
-- （export-run/index.tsのloadStyleProfile()はfile_path未設定なら既定書式にフォールバックする
-- 設計に既になっている＝月次PLと同じ仕組みで、後日テンプレート.xlsxをアップロードするだけで
-- 自動的にそのデザインが使われるようになる。コード変更は不要）。
-- 冪等。
-- ============================================================

insert into tpl_templates (template_code, template_name, category, description, renderer_key, layout, is_active)
values (
  'ad_media',
  '媒体別広告実績',
  'マーケティング',
  '対象期間・対象店舗（複数選択可）を指定し、広告媒体ごとの広告費・売上・客数・客組数・ROAS（売上÷広告費）を店舗別＋合算で出力する。広告費は広告DBシート（GAS経由）、売上・客数はBigQuery stg_media（bqGetMedia）から取得し、媒体名の表記ゆれはtori-dashboardのcanonMedia()と同じロジックで正規化して突合する。テンプレートファイルは未登録（後日アップロードするとそのデザインが自動的に使われる）。',
  'ad_media_v1',
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
-- select template_code, template_name, category, file_path from tpl_templates order by category, template_code;
