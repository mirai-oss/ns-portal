# 社内情報管理システム → ハブ移設キット

社内情報管理システム（Supabase `wciefkpooncglahqdtmu` / Next.js on Vercel）を、
ハブ（日報Supabase `uuvsxzhpxtghojoubjcc`）の **`info` スキーマ**へ移す一式。

**現状: 構造の移送は検証済み（未実行）。** ハブ上に一時スキーマを作って
28テーブル / 239列 / 外部キー43本が完全に再現できることを確認し、検証用スキーマは削除済み。
本番の切り替えはVercelの環境変数変更を伴うため未実施。

## なぜ `info` スキーマに分けるのか

ハブの `public` には既に `users` / `stores` / `documents` などがあり、
社内情報側にも同名テーブルがある。スキーマを分ければ衝突せず、
かつ**同じデータベース内なので日報・評価・売上と直接JOINできる**（横断利用の要）。

## 移設後のアイデンティティ設計

| 対象 | 移設前 | 移設後 |
|---|---|---|
| ログイン | 別プロジェクトのSupabase Auth | **ハブのSupabase Auth（＝ポータル・日報と同一）** |
| 人 | `public.profiles` | `public.users`（ハブ）に一本化。`info.profiles`は移行期のみ残す |
| マスター判定 | `profiles.is_master` | `users.is_master`（ハブ） |
| 店舗 | `info.stores.store_code` 00〜05 | `public.stores.store_no` 01〜12 を正とし、`info.stores`は廃止（本社=00は要追加） |
| 役職 | `info.roles` 4種（本部/部長/店長/一般スタッフ） | ハブの6種（CEO/HQ/TEAM/TENCHO/SHAIN/AL）へマッピング |

## 手順

```bash
# 1. 元DBの構造を抽出（info_schema.json ができる）
python3 1_dump_schema.py

# 2. DDLを生成（info_ddl.generated.sql を上書き）
python3 2_gen_ddl.py

# 3. ハブに適用（Supabase SQL Editor に貼るか Management API で実行）
```

その後に必要な作業（未実装・切り替え時にまとめて行う）:

1. **データ移送** — 28テーブル・約12MB。`profiles.id` はハブ `users.id`（メール一致）へ付け替える
2. **RLS/関数の書き換え** — 53ポリシー・8関数。`is_master()` / `has_perm()` / `can_access_corp()` が
   `info.profiles` ではなくハブ `public.users` を見るように変更
3. **ストレージ** — `documents` バケットのファイル1件をハブへコピー（`photos` は0件）
4. **アプリ側のコード** — `src/lib/supabase/*.ts` の `createClient` に `db: { schema: 'info' }` を追加
5. **Vercel環境変数** — `NEXT_PUBLIC_SUPABASE_URL` / `NEXT_PUBLIC_SUPABASE_ANON_KEY` をハブのものへ
6. **2段階認証** — 現在この system は MFA(aal2) を要求している。ハブでも同じ人がTOTPを登録すれば
   同水準を維持できる（Supabaseのaal要求はアプリ側で判定するため、日報や売上には波及しない）

## ロールバック

元プロジェクトは一切変更しないので、**Vercelの環境変数を元に戻すだけ**で復帰できる。
