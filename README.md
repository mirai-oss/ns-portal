# ns-portal — N-Styleグループ ポータル

グループ4システム（経営ダッシュボード / 精算ダッシュボード / 社内情報管理 / 日報・週報）の統合入口。
統合アカウント（= 日報SupabaseのAuth、メール+パスワード）でログインし、役割に応じたシステムのタイルを表示する。

- 公開URL: https://mirai-oss.github.io/ns-portal/
- 認証ハブ: Supabase `uuvsxzhpxtghojoubjcc`（日報プロジェクト）。このリポジトリに置いてあるのは公開用publishableキーのみ
- 要件定義: [docs/要件定義書.md](docs/要件定義書.md)
- DBマイグレーション: [supabase/](supabase/) — Supabase SQL Editorに貼って実行（冪等）

## 役割と表示

| 役割 | 経営D | 精算D | 社内情報 | 日報 |
|---|---|---|---|---|
| マスター/社長/本部 | ○ | ○ | ○ | ○ |
| チーム長 | ○ | − | ○ | ○ |
| 店長 | ○ | − | − | ○ |
| 社員/アルバイト | − | − | − | ○ |

業務委託先はポータル対象外（精算ダッシュボード専用ID/PWのまま）。

## 更新手順

index.html を編集 → commit → push（GitHub Pagesが1〜2分で自動反映）。
秘密情報（service_roleキー・PAT・個人情報）は絶対にコミットしない。
