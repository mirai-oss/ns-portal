# 銀行入金の正本（段階1）のテスト

本番には**接続しません**。メモリ上の Postgres（PGlite・PostgreSQL 16）に、Supabase 相当の土台（auth / storage / ロール / 既存の表）を用意して、
`supabase/2026-11-27_bank_ledger_stage1.sql` と `…_ROLLBACK.sql` を流し、権限・守り・再実行・ロールバックを確かめます。

```bash
cd tools/bank-ledger-test
npm install
npm test
```

確かめること: ①社長・本部・マスター・チーム長・店長・一般社員・アルバイト・他法人の店長・無効ユーザー・未ログイン・サービスロールの権限（表・関数・Storage）
②原本の事実が変えられないこと／訂正値の履歴／確定済みの保護／追記専用 ③集計に入れる明細の条件 ④同じ原本を複数の取得履歴が指せること
⑤SQL を 2 回流しても、データ・設定・既存の物が変わらないこと ⑥ロールバックが（データ・同期状態・原本ファイルがあれば）何も消さずに止まること。

注意: PGlite は Supabase 本体ではありません（Storage の API・PostgREST・認証は土台の代用品）。本番適用前の `--dry-run` は別に行います。
