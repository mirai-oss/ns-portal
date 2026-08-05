# 切り替え手順（社内情報管理システム → ハブ）

移設先の準備は**完了済み**（2026-08-05）。あとはVercelの環境変数を変えるだけ。

## 済んでいること

- ハブ `uuvsxzhpxtghojoubjcc` に `info` スキーマを作成（28テーブル / 239列 / FK43本）
- データ194行を移送（件数は全テーブル一致を確認）
- 中山さんのIDをハブのアカウント（shunji.nakayama@ns0314.com）に付け替え済み
- 関数7件・RLSポリシー53件・トリガー1件を移設
- `info` スキーマをAPIに公開（PostgRESTの db_schema に追加）
- アプリのコードを環境変数駆動に変更（`NEXT_PUBLIC_SUPABASE_SCHEMA`、既定 public）
- 日報のアルバイトアカウントで機密テーブルが**全件0件**（読めない）ことを実機確認

## セキュリティ上の変更点（重要）

移設元にあった `handle_new_user`（新規ログインユーザーに自動で社内情報の権限を渡す処理）は
**意図的に移植していない**。ハブでは日報の全従業員が新規ユーザーになるため、
自動付与すると口座・給与・ID/PW金庫まで見えてしまうから。

→ **社内情報管理システムを使う人は `info.profiles` に明示的に追加する**運用になる。

```sql
-- 例: 原さんに社内情報システムの利用権を与える（役職は info.roles から選ぶ）
insert into info.profiles (id, name, role_id, is_active, email)
select u.id, u.name, (select id from info.roles where name='本部'), true, u.email
from public.users u where u.email = 'mika.hara@ns0314.com'
on conflict (id) do nothing;
```

## 切り替え手順

1. Vercel → ns-info-system → Settings → Environment Variables で3つを設定

   | 変数名 | 値 |
   |---|---|
   | `NEXT_PUBLIC_SUPABASE_URL` | `https://uuvsxzhpxtghojoubjcc.supabase.co` |
   | `NEXT_PUBLIC_SUPABASE_ANON_KEY` | `sb_publishable_MrwPJAx_Ws_fdRutprKCiQ_dg3wCiTr` |
   | `NEXT_PUBLIC_SUPABASE_SCHEMA` | `info` |

2. Deployments → 最新のデプロイの「…」→ **Redeploy**
   （`NEXT_PUBLIC_` はビルド時に埋め込まれるので、環境変数を変えたら必ず再デプロイが必要）

3. https://ns-info-system.vercel.app に、**日報と同じメール・パスワード**でログインできることを確認

## 切り戻し

環境変数3つを元の値（元プロジェクトのURL/キー、SCHEMAは削除）に戻して再デプロイするだけ。
**移設元のプロジェクトは一切変更していない**のでデータもそのまま残っている。

## 切り替え直前にやること

移設元を使い続けている間にデータが増えるので、**切り替える直前にもう一度**データを流し直す:

```bash
python3 3_copy_data.py   # info側を空にしてから入れ直すので何度でも実行できる
```

## 残っている作業

- ストレージ: `documents` バケットのファイル1件をハブへコピー（`photos` は0件）
- 2段階認証: 現在は元プロジェクト側で設定されている。ハブでも同じ人がTOTPを登録すれば同水準
