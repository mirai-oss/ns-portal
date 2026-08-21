# 実装指示書: データ基盤ロードマップ Day 1（保全・足場固め）

作成: 2026-08-21 ／ 対象: 実行スレッド（モデル指定なし。Sonnet 5想定）
根拠: `docs/データ基盤統合ロードマップ.md` Part 1 の Day 1（Phase 0＋Phase 1前半）
前提: Day 0完了済み（**スマレジタイムカード=プレミアムプラン確認済み**・Supabase Pro化済み）

---

## 0. 開始前の必須手順（省略禁止）

1. `ns-portal/WORKLOG.md` 冒頭「📍現在の状況」を読む（このファイルの存在もそこに載っている）
2. `ns-portal`・`nippo`・`NStyle-AI`（非公開）・`tori-dashboard`・`ns-info-system` で `git fetch origin` → ローカルが古ければ `git pull --rebase origin main`
3. ブラウザ操作（タスクA）は **claude-in-chrome（Chrome連携）** を使う。ChromeでGoogleアカウントにログイン済みであることをスクリーンショットで確認してから始める（未ログインならユーザーに依頼）

## ⛔ 絶対禁止事項

- **Apps Script（GAS）の編集・保存・デプロイ・実行は一切禁止。閲覧とコピーのみ。**（過去に「別用途のdoPost追加で取込全滅」事故あり。Ctrl+S/⌘Sを押さない）
- スプレッドシートのセル値・シート構成を変更しない
- 本番SupabaseへのSQL実行は**タスクDのみ・ユーザー確認を得てから**（WORKLOGの鉄則どおり）
- バックアップは**非公開リポ `NStyle-AI`** に保存する。公開リポ（ns-portal / tori-dashboard）には置かない

---

## タスクA: GASコードの全量バックアップ（最重要）

**目的**: スプレッドシート内にしか存在しないGASプログラムをGitHub（非公開）に保存し、消失リスクをなくす。

**保存先**: `NStyle-AI/gas-backup/<プロジェクト名>/`（新規フォルダ。フォルダ名は英語）

**共通手順**（各スプレッドシートに対して）:
1. `https://docs.google.com/spreadsheets/d/<ID>/edit` を開く
2. メニュー「拡張機能」→「Apps Script」でスクリプトエディタを開く
3. エディタの歯車（プロジェクトの設定）で「`appsscript.json`マニフェストファイルをエディタで表示する」をON（**設定変更はこのチェック1つだけ可**）
4. 左のファイル一覧を**1つずつ全部**開き、全文をコピーして同名のローカルファイルに保存（`.gs`→`.gs`、`.html`→`.html`、`appsscript.json`含む）
5. 各フォルダに `README.md` を作り記録: 取得日時／バインド先シートID・シート名／プロジェクト名／デプロイ一覧（「デプロイ」→「デプロイを管理」に表示されるバージョン・ID。**見るだけ**）

**対象（6件）**:

| # | スプレッドシート | ID | 保存先フォルダ | 注意 |
|---|---|---|---|---|
| A-1 | 売上DB | `1z_22yVxPRo7cpL9A4nluYzXbQ9FH_zFk9Mb5gHiOF3E` | `gas-backup/sales-db/` | **最重要**。`取込WebApp.gs`（人件費成形 importJinkenCSV）を含む全ファイル |
| A-2 | ダッシュボード データ元 | `1iIQX6LqbM6rUrygfQZVGRVYtwEhO0O-5a_dvn06pWdA` | `gas-backup/dashboard/` | 取得後 `tori-dashboard/gas/Code.gs` と diff し差分を報告（本番が ver いくつか= `ver:` 定数も確認） |
| A-3 | 【サーバー】ダッシュボード | `1OuaAQBeXHxJZtDXEbQx-V7w56fCWW5jpDmZvBpkfIbQ` | `gas-backup/dashboard-server/`（GASがあれば） | **二重ID疑惑の解消を兼ねる**: A-2とA-3のどちらに本体GASが付いているか・両者の関係（IMPORTRANGE等）を報告 |
| A-4 | PL管理システム | `1ZJ5a3ZgsRGfJHVhIXo2b-OK-2gZMvUAHl7J9WFms7dQ` | `gas-backup/pl-system/` | リポ版に無い `syncAd()`・`自動｜法定福利費`(L04)・`自動｜通勤手当`(L05)・`O21 運営委託費` が本番にあるはず→diff結果を報告 |
| A-5 | 広告費用対効果_管理シート | `1y-Lb5ynzJ-5tRDKgQAapoxmpqkfO1o5gNWcPR2WLxCI` | `gas-backup/ad-mgmt/`（GASがあれば） | GASが無ければ「無し」と記録 |
| A-6 | 精算書 入力シート | `1GlJRMjKTMjqr22xo52xI3AdWJB2UZ_VlRDORqYOnXv4` | `gas-backup/seisan/` | 精算ダッシュボード本体 |

**追加（見つかれば）**: `https://script.google.com/home` のプロジェクト一覧を開き、①口コミ評価DB用GAS（「口コミ」「ダイニー」等の名前で検索）②`LarkCron` ③`LarkBot` の独立プロジェクトがあれば同様に `gas-backup/<名前>/` へ保存。見つからなければ「確認できず」と報告（探し回って時間を使いすぎない。15分で打ち切り）。

**コミット前のチェック**: `grep -rniE "token|secret|password|api[_-]?key" gas-backup/` を実行し、ヒットした箇所を報告に列挙する（NStyle-AIは非公開リポなので値はそのまま保存してよい。ただし何が入っているかは報告で見えるように）。

## タスクB: 取込タスク台帳の現行化

`NStyle-AI/ai-agent-team/import_task_board.md` を実装の実態（`ns-daily-import/config.js` 基準・12本）に合わせて更新:

- ジョブ一覧を12本に: smaregi-payroll 07:00／zeroregi-akihabara 06:30／infomart-siire 06:45／dinii-media 07:30／dinii-orders 07:35／dinii-questionnaire 07:45／dinii-payment-ns 08:00／dinii-payment-nstyle 08:30／paypay-bank 13:00／paypay-bank-b 13:15／arena-events 毎月1・15日 08:40／nissan-stadium-events 毎月1・15日 08:45
- 実行方式の記述を修正: Mac mini上の launchd＋dispatch.js（3分ポーリング）。手動起動はLarkの「実行 ○○」発言または tori-dashboard/tasks.html
- 「前回」列は確認できないため「Mac mini側ログ参照」と記載（このMacからは見えない）

## タスクC: ns-info-system ローカル環境の整備

1. `cd ~/ns-info-system && git fetch origin && git pull --rebase origin main`（本番相当まで進める。コンフリクトしたら中断してユーザーへ）
2. `.env.local` を**ハブ向けに書き換え**（git管理外ファイル）:
   - `NEXT_PUBLIC_SUPABASE_URL` = `https://uuvsxzhpxtghojoubjcc.supabase.co`
   - `NEXT_PUBLIC_SUPABASE_ANON_KEY` = ハブのpublishableキー（`nippo/index.html` 130行目付近の `SUPA_KEY` 定数と同じ値をコピー。公開前提のキーなのでコピー可）
   - `NEXT_PUBLIC_SUPABASE_SCHEMA` = `info`
   - 旧値は `.env.local.old-wciefkpooncglahqdtmu` にリネームして残す
3. `npm run build` が通ることだけ確認（devサーバーの起動・本番アクセスはしない）

## タスクD: 従業員ID一本化の準備（Phase 1前半・⚠️ユーザー確認ゲートあり）

1. 次のSQL案をユーザーに提示し、**OKをもらってから**Management API経由で実行（接続情報の所在はWORKLOG「🔑接続情報」参照。Mac miniの鍵はコピーせず、このPCで必要ならユーザーに新PAT発行を依頼）:
   - `alter table info.employees add column if not exists user_id uuid references public.users(id);`
2. 突合リストを生成（読み取りのみ・実行に確認不要）: `info.employees` と `public.users` を氏名（空白・全半角を除去して比較）でLEFT JOINし、「自動で一致した組」「一致しなかったemployees」「一致しなかったusers」の3表を作る
3. 3表を**ユーザーに提示して目視確認を待つ**。確定のUPDATE文は確認後のみ実行。同姓同名・旧姓は自動確定しない
4. 完了後の検証: `select count(*) from info.employees where user_id is null and status = '在籍';` が0（または理由説明付き）

## 完了条件（Day 1）

- [ ] gas-backup/ に対象GASの全ファイルが保存され、NStyle-AIにpush済み
- [ ] A-2/A-3のシートID二重疑惑の答えが報告に書かれている
- [ ] A-2・A-4のリポ版との差分が報告に書かれている
- [ ] 台帳が12本・現行の実行方式に更新済み
- [ ] ns-info-systemが本番相当＋ハブ向け.env.localでビルド成功
- [ ] info.employees.user_id が追加され、突合リストがユーザー提示済み（確定は目視確認後）

## 終了時（省略禁止・CLAUDE.mdの4ステップ）

①各リポをコミット・push（NStyle-AIでは**既存の `automation/playwright` 削除13ファイルの未コミット変更に触れない**こと。自分の変更だけ `git add <パス>` で個別に追加）
②`ns-portal/WORKLOG.md` に作業ログを時系列追記 ③冒頭「📍現在の状況」を書き換え ④再コミット・push

**報告フォーマット**: 完了条件のチェック結果／A-2・A-4のdiff要約／シークレットスキャン結果／突合リスト（ユーザー確認待ちの一覧）／つまずいた点・確認できなかった項目
