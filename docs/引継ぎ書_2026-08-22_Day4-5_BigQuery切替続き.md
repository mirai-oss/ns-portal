# 引継ぎ書: データ基盤 Day4-5（BigQuery切替）続き

作成: 2026-08-22 ／ このMacBookでの作業をここで区切り、別PC（Mac mini等）で続ける可能性があるため作成。
次のスレッドはこれを読んでから着手すること。根拠: `docs/データ基盤統合ロードマップ.md` Day4-5（Phase 4「切替」）。

---

## 0. 開始前の必須手順（省略禁止）

1. `ns-portal/WORKLOG.md` 冒頭「📍現在の状況」を読む
2. 今回は**4つのリポジトリ**を横断して触っている。それぞれで `git fetch origin` → ローカルが古ければ `git pull --rebase origin main`
   - `ns-portal`（このリポジトリ。WORKLOGが正）
   - `NStyle-AI`（非公開。GASバックアップ＋台帳）
   - `ns-daily-import`（日次CSV自動取込・Mac mini常駐）
   - `tori-dashboard`（経営ダッシュボード。**独自のCLAUDE.md/HANDOFF.mdを持つ。作業前に必ずそちらも読むこと**）
3. 接続情報はこのMac（MacBook）の `~/.config/ns-portal/` に保存済み（`supabase_pat`＝Management API PAT、`hub_service_role`＝service_roleキー、どちらもchmod 600）。**別マシンの場合は新規発行すること**
4. `tori-dashboard`のGAS（【サーバー】ダッシュボード、スクリプトID`1s8wY21hbVrWSazUfXzZWzDU1dmtX7hFpsE6yRl4u2wT2pR_tH1QzagNn`）を操作するには**Google側の`clasp login`が必要**（このMacBookでは`shunji.nakayama@ns0314.com`で認証済み。別マシンでは新規に`clasp login`する必要がある）
5. `BQ_LOAD_TOKEN`（GASのスクリプトプロパティに保存済みの合言葉）は、Apps Scriptエディタ（`script.google.com/home/all`→「【サーバー】ダッシュボード」→歯車アイコン→スクリプトプロパティ）で本人が確認すること。**チャットにトークンを貼らない**（今回のセッションで誤って貼られた事故があった）

---

## 1. これまでの到達点（Day1〜4完了・Day5進行中）

- **Day 1〜3（保全・マスタ・勤怠API基盤）**: 完了。詳細はWORKLOG参照
- **Day 4（BigQuery売上基盤構築）**: 完了
  - `tori-analytics.sales`データセット新設。`分析_日別店舗`・支払い/媒体別/仕入れ/人件費DBの5テーブルをミラー
  - 直近35日の突合で純売上・仕入れ・人件費合計・行数すべて完全一致を確認済み
  - `ns-daily-import`に日次タスク`bq-sales-reconcile`（毎日11:00、差額があればメール通知）を追加**（⚠️Node側の実機動作確認は未実施。§3参照）**
- **Day 5（タブ単位のデータソース切替）進行中**:
  - ✅ 「推移分析」タブ: `bqDailyStore`アクション新設。社長/本部限定のトグルボタンを設置。**ユーザーが実機でログインして確認済み（数値一致）**
  - ✅ 「ダッシュボード」「目標管理」タブ: 推移分析と同じ`stat()`関数（`D.daily`共有）を使っていたため、**新しいコード無しで自動的に切替対象になっていた**ことが判明。表示だけ追加
  - ✅ 「PL（損益）」タブ: 売上/原価/人件費/現金部分は上記と同じ理由で対応済み。**手入力経費（`DB_PL`）も`bqSyncPL`/`bqGetPL`で新規対応**。合計・件数の完全一致（596件・157,998,380円）を確認済み
  - ⏳ 未対応: PLの広告費部分（管理シート💾広告費DB）、入金管理タブ（入金DB＝実際の銀行入金額。全く別データソース）

**現在のバージョン**（次回セッション開始時、これと一致するか必ず確認すること）:
- GAS `ping`の`ver`: **`fix-v50`**（`curl -sL '<GAS_URL>?action=ping'`で確認）
- `app.js`: **`v=96`**（`index.html`参照）
- GAS本番URL: `https://script.google.com/macros/s/AKfycbz9rd37EZa6X8WRMVEBrXobN8DbYWkHRlhFNYU5rd1UZ0V8j0-6shMQjEeoi4HDWZ0B/exec`

**各リポジトリの最新コミット（2026-08-22時点。必ず`git fetch`で照合すること）**:
- `ns-portal`: `3f6867a`
- `NStyle-AI`: `94db5a0`
- `ns-daily-import`: `0139ff3`
- `tori-dashboard`: `2b42a2b`

---

## 2. Day4-5で分かった重要な注意点（必読・再発防止）

### 2-1. GASの新バージョン反映は`updateContent`だけでは効かない
Apps Script APIの`projects.updateContent`は「スクリプトの保存内容」を更新するだけで、**既にバージョン固定された本番Webアプリのデプロイには反映されない**。新機能を本番URLで使うには:
1. `projects.versions.create`で新バージョンを作る
2. `projects.deployments.update`で既存デプロイ（上記の本番URL、deploymentId=`AKfycbz9rd37EZa6X8WRMVEBrXobN8DbYWkHRlhFNYU5rd1UZ0V8j0-6shMQjEeoi4HDWZ0B`）をそのバージョンに向け直す

（`tori-dashboard/CLAUDE.md`の「デプロイを管理→編集→新バージョン→デプロイ」と同じ操作を、Apps Script API経由で手動再現している）

### 2-2. 新バージョンデプロイ後、BigQuery権限の再承認が必要になることがある
`executeAs: USER_DEPLOYING`のため、デプロイのタイミングで実行ユーザーの認可状態が変わることがある。`bigquery.jobs.insert を呼び出す権限がありません`のようなエラーが出たら、**Apps Scriptエディタで既存の関数（`testBQ`等）を1回手動実行**し、認可ダイアログで許可すれば解消する（ユーザー作業が必要）。

### 2-3. `clasp`のアクセストークンは頻繁に切れる（1時間程度）
`invalid_rapt`や`401 UNAUTHENTICATED`が出たら、`clasp deployments`のような軽いclaspコマンドを一度実行してトークンをリフレッシュしてから、Apps Script APIの直接呼び出しをやり直す。

### 2-4. `DB_`系シートは構造がバラバラ（毎回確認すること）
- `分析_日別店舗`: 1行目がヘッダー（開始行=2）
- `支払いDB`/`媒体別DB`/`仕入れDB`/`人件費DB`: 1行目がシート説明の見出し・2行目が本当のヘッダー（開始行=3）
- `DB_PL`: 1行目がヘッダー（開始行=2、`分析_日別店舗`と同じ）
BigQueryへのロード前に、実際に`getRange`で数行覗いて構造を確認してから開始行を決めること（今回、2行プリアンブル構造に気づかず「ヘッダー行が数値として読めない」エラーで発覚した）。

### 2-5. NUMERIC型・日付比較の落とし穴
- GAS側の割り算結果（比率列）が0除算で`NaN`/`Infinity`になっていることがある→`isFinite`チェックでNULL化
- BigQueryのNUMERIC型は小数点以下9桁までの制約→6桁程度に丸めておく（`dinii-orders.js`の`normNum`と同じ対策）
- 日付の比較は「時刻付きDateオブジェクト」ではなく「日付文字列(`yyyy-MM-dd`)」同士で行うこと（時刻付きだと境界の1日分がズレる）

### 2-6. cron-job.orgの設定が壊れやすい
今回、GitHub PATの控えを紛失していて`Authorization`ヘッダーが空になり、毎朝の自動発火が失敗し続けていた（GitHub Actions側には記録すら残らないので気づきにくい）。cron-job.orgの「History」タブで`Failed (HTTP error)`が出ていないか、たまに確認すること。

---

## 3. 次にやること（優先順）

1. **`bq-sales-reconcile`タスクの実機動作確認**（Mac mini側。このMacBookには`ns-daily-import/.env`が無く未確認）。毎日11:00の自動実行結果を見るか、Larkから「実行 BQ突合」で手動実行して確認する
2. **`smaregi-payroll-reconcile`用のcron-job.orgジョブ追加**（毎月5日08:00 JST。要ユーザー作業）
3. **入金管理タブの切替検討**（入金DB＝実際の銀行入金額を新規にBigQueryミラーする必要がある。今回のDB_PLと同じ手順を踏襲できる）
4. **PLの広告費部分の切替検討**（管理シート💾広告費DBが対象）
5. LINE公式アカウントの月間送信上限問題（保留中）
6. Chatwork連携（保留中。`tori-dashboard`の`SeisanDashboard.gs`に既存実装`sd_notifyChatwork_`あり、参考にできる）
7. 人件費列をスマレジタイムカードAPI由来のデータに置き換える構想（ユーザー指摘、将来対応）
8. Day5残り: 日報`dash-sync`のSupabase直読み化・Lark配信の新経路移行

---

## ⛔ 絶対禁止事項（継続）

- 既存の`smaregi-sync`・`smaregi-shift-sync`・`smaregi-attendance-sync`（ns-portal）の本番ロジックを不用意に書き換えない
- `tori-dashboard`の`appsscript.json`を**全文置き換えしない**（BigQueryサービス設定が消えて過去に事故発生済み。足りない項目だけ追記）
- `tori-dashboard`でGASの「新しいデプロイ」を作らない（URLが変わり`app.js`の`DEFAULT_API_URL`が旧版を指したまま事故る。既存デプロイを新バージョンに向け直すこと）
- Googleスプレッドシートの直接編集は原則禁止。やむを得ず開く場合、検索は必ずメニューの「編集→検索と置換」を使う
- 既存のマイグレーションSQLファイルは編集しない（新しい変更は日付入りの新規ファイルを追加）
- 本番SupabaseへのSQL実行で既存データを壊す操作は必ずユーザー確認を得てから
- トークン・パスワード等の秘密情報はチャットに貼らない・貼られた場合は速やかに指摘し使用しない

---

## 終了時（省略禁止・CLAUDE.mdの4ステップ）

①コミット・push ②`ns-portal/WORKLOG.md`に時系列追記 ③冒頭「📍現在の状況」を書き換え ④再コミット・push
（`tori-dashboard`を触った場合は、同リポジトリの`HANDOFF.md`にも同様に記録すること）
