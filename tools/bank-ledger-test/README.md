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

注意: PGlite は Supabase 本体ではありません（Storage の API・PostgREST・認証は土台の代用品）。本番適用前には、実際の Supabase での事前検証（下の `real_env_verify.py`）を必ず行います。


## 実環境（本物の Supabase）での事前検証: `real_env_verify.py`

```bash
python3 tools/bank-ledger-test/real_env_verify.py          # 流して確かめて、必ず巻き戻す（何も残らない）
python3 tools/bank-ledger-test/real_env_verify.py --print  # 送る SQL を表示するだけ
```

- 全体を 1 つの DO 文（＝1 つのトランザクション）にして、最後に必ず例外を投げて巻き戻す。結果は最後の例外メッセージで受け取る。
- 本物のユーザー全員のログインを模して、見える店舗を期待値（社長・本部・マスター=全店／チーム長=担当チーム＋所属／店長=所属）と突き合わせる。ユーザー・店舗・チームは変更しない。
- 使うもの: `~/.config/ns-portal/supabase_pat`（値は表示しない）。
- PGlite で出なかった実環境だけの問題（例: storage の直接 delete 禁止）を拾うためのもの。段階 2 以降の SQL でも、同じ形で使い回す。
