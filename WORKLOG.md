# WORKLOG

## 2026-08-05
- プロジェクト開始。要件定義ヒアリング（統合レベル=A案、ハブ=日報Supabase、役割7種、店舗番号06〜12採番、委託先は精算専用のまま）
- docs/要件定義書.md 作成
- supabase/2026-08-05_unify.sql 作成（stores.store_no/signs追加、09〜12店舗追加、store_aliases新設、users.is_master追加。冪等）
- index.html ポータル初版（Supabase Authログイン、役割別タイル、パスワード変更）
- GitHub公開 + GitHub Pages有効化
- フェーズ1b実行: ユーザーのSupabase PATでManagement API経由SQL実行。stores 01〜12反映（09〜12はis_active=false）、store_aliases 34件、users.is_master追加、中山俊士（CEO）にis_master=true付与。確認クエリで検証済み
- フェーズ1c実装: tori-dashboardにSSO追加（GAS action=supalogin / アカウントシートK列メール / ログイン画面に統合ログインUI）。一時Supabaseユーザーで実機E2E（認証成功→旧GAS検知→案内表示）を確認後ユーザー削除。app.js v91公開済み。**GAS再デプロイ（sso-v46）待ち**
- 認証情報の置き場: ~/.config/ns-portal/supabase_pat と hub_service_role（chmod 600・リポジトリ外）
