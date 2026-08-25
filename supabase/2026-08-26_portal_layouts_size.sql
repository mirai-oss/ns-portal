-- F-7: ホーム画面のウィジェット編集にサイズ選択を追加
-- 実装指示書_ラウンド3_2026-08-26.md F-7
-- 既存の portal_layouts（2026-08-12_portal_layouts.sql・index.htmlの「画面のカスタマイズ」が
-- 使用中）に size 列を追加するだけ。既存行（area in kpi/main/side/wide）は size='medium'の
-- 既定値が入るだけで、index.html側はこの列を読まないため挙動に影響しない。
-- 新シェル（portal.html）は area='home' の行だけを使い、既存のarea値とは衝突しない。

alter table portal_layouts
  add column if not exists size text not null default 'medium';

do $$ begin
  alter table portal_layouts
    add constraint portal_layouts_size_check check (size in ('small','medium','large'));
exception when duplicate_object then null;
end $$;
