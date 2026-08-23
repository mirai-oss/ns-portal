# ロールバック手順書

作成: 2026-08-23／データ基盤統合ロードマップ Day7 成果物
対象読者: 何か新しい仕組み（BigQuery切替・店舗マスタ直読み・新レポート方式等）に問題が起きたとき、**元の仕組みに素早く戻す**ための手順。基本方針は「新しい経路を止めれば自動的に元の経路に戻る」設計にしてあります（旧経路のコード自体は消していません）。

---

## 1. ダッシュボードの各タブ（BigQuery⇔スプレッドシート切替）

**症状**: 推移分析・ダッシュボード・目標管理・入金管理・PLタブの数字がおかしい／表示されない

**戻し方**: 各タブの右上にある「🧪 データ元: BigQuery / シート」ボタンを押して「シート」側に切り替える。ボタン1つ・即時反映・データの削除は発生しない。

（社長/本部権限のアカウントにのみ表示されるボタンです）

---

## 2. 経営D GAS・nippoの店舗マスタ直読み（店舗名・別名・天気地点等）

**症状**: 店舗名の表示がおかしい／天気が出ない／口コミの親子店舗の対応がおかしい

**設計上、これは特別な操作をしなくても自動的に安全側に倒れます**: `fetchStoreDirectory_()`（GAS側）・`D.storeDirectory`（nippo/tori-dashboard クライアント側）は、Supabaseから取得できない場合は必ず`null`を返し、呼び出し側は自動的に旧来のコード内定数（`CANON_STORES`・`WX_LOCS`・`REVIEW_CHILDREN`・スプレッドシート「DB_店舗名対応」「DB_店舗親子」）にフォールバックする作りになっています。

**それでも直らない場合**（Supabase側の`store_directory_v`ビューが壊れた等）: 下記コマンドで本番の状態を直接確認できます。
```bash
curl -s "https://uuvsxzhpxtghojoubjcc.supabase.co/rest/v1/store_directory_v?select=*" \
  -H "apikey: sb_publishable_MrwPJAx_Ws_fdRutprKCiQ_dg3wCiTr" \
  -H "Authorization: Bearer sb_publishable_MrwPJAx_Ws_fdRutprKCiQ_dg3wCiTr"
```
何も返らない／エラーになる場合は、Supabase側で`2026-08-22_store_directory.sql`の再適用（`store_directory_v`・`report_channel_matrix_v`ビューの再作成）を検討する。

---

## 3. Lark/Chatwork自動配信の動的matrix生成

**症状**: 配信が想定と違うグループ・店舗に届く／届かない

**確認**: 配信の割り当ては`nippo`の「📮 配信グループ管理」（店舗管理画面の下部）で管理されています。まずここの設定を確認・修正するのが最速です（コード変更不要・即時反映）。

**それでもダメな場合のロールバック**: `.github/workflows/lark-report.yml`の`prepare`ジョブ（Supabaseから`report_channel_matrix_v`を取得して配信先を決める部分）を、動的生成前の静的3グループ直書きバージョンに戻す。
```bash
cd tori-dashboard
git log --oneline -- .github/workflows/lark-report.yml   # 該当コミットを探す
git revert <動的matrix導入コミットのハッシュ>              # または該当コミット以前のファイルをcheckoutして上書き
git push
```
（動的matrix化のコミットはWORKLOG.md 2026-08-22付「Day6②③実装」エントリに記載）

---

## 4. レポート配信の方式（capture-bq ⇔ 旧ブラウザ方式）

**症状**: `capture-bq`（BigQuery直読み・2026-08-23導入）で数字がおかしい、または動かない

**旧方式（ブラウザでログイン→スクリーンショット）に戻す方法**: `.github/workflows/lark-report.yml`内の3箇所の`node scripts/lark-report.mjs capture-bq`を`node scripts/lark-report.mjs capture`に戻し、`env`を`DASH_ID`/`DASH_PW`（+ `REPORT_USE_BQ: '1'`）に戻す。旧コードは`scripts/lark-report.mjs`にそのまま残っています（削除していません）。
```bash
cd tori-dashboard
git log --oneline -- .github/workflows/lark-report.yml scripts/lark-report.mjs
# commit 2989f4f が capture-bq への切替コミット。その直前の状態に戻す場合:
git revert 2989f4f 9f8c326
git push
```
**注意**: 旧方式は「媒体別日次シートの肥大化により毎回タイムアウトする」既知の不具合があります（2026-08-22発覚）。ロールバックは一時しのぎとして使い、根本解決（BigQueryミラー化）を優先すること。

**GAS側（`reportDataBQ`アクション）だけを止めたい場合**: GitHub Secret `BQ_LOAD_TOKEN`を無効な値に変更する、またはSecrets画面から削除する。呼び出し元は`unauthorized`エラーで即座に失敗するため、意図しない挙動にはならない（自動配信自体は失敗として扱われ、Larkに投稿されない）。

---

## 5. 勤怠・給与突合系Edge Functions（smaregi-payroll-reconcile / smaregi-attendance-anomaly-check）

**症状**: 誤った差額アラート・誤った異常勤務アラートがLINEに届く

**止め方**: cron-job.org側の該当ジョブを一時停止（実行間隔をOFFまたは大きくする）。Edge Function自体を消す必要はない。

---

## 6. 売上BigQuery基盤（Day4）全体

**症状**: `tori-analytics.sales`データセットの数字がおかしい・突合が合わない

**旧経路は無変更で動き続けている**ため、実害は「BigQuery側の数字だけが信用できない」状態にとどまる（スプレッドシート「分析_日別店舗」が正本のまま）。ダッシュボード各タブのBigQueryトグルを全てOFF（本項の1参照）にすれば、実質的に旧経路のみで運用を継続できる。

---

## 困ったときの一次切り分け（共通）

1. GAS本体が生きているか: `?action=ping`をブラウザで開き`{"ok":true,...}`が返るか確認
2. Supabase側が生きているか: 上記2のcurlコマンドで`store_directory_v`が読めるか確認
3. GitHub Actionsの実行履歴を見る: `https://github.com/mirai-oss/tori-dashboard/actions`
4. 上記いずれも正常なのに症状が続く場合は、該当する上記1〜6の手順に従う
