# 調査: 担当D管轄の Lark／Chatwork 通知の一覧（変更はしていない・2026-11-11）

依頼: 司令塔（ユーザー指示「Slack にも通知しているものは Lark と Chatwork の通知を解除してよい」）。範囲＝勤怠・給与・監視・dash-sync／import_runs の失敗通知・LINE 関連の管理者通知。従業員向けLINE（U-22）は対象外。
調べ方: ns-portal（Edge Function・_shared・GitHub Actions・DB関数）、tori-dashboard（Actions・GAS）、ns-daily-import（Mac mini）のコードと本番DBの読み取り。**氏名・値は扱わず、名前と件数のみ**。Mac miniの`.env`の実際の値は私の手元から見えないため「未確認」と記載。

## 結論（先に）
- **「Slackにも出している＝Lark側を止めてよい」に当たる、D管轄の通知は6件**（Lark＋Slackの並行送信中）。すべてSlackの`#本部-開発システム`（hq.dev_system）に並行で出ている。
- **Larkだけで、Slackが無いものが4件**（止めると通知が無くなる）: 所属同期（smaregi-affiliation-sync）／週次バックアップ失敗（weekly-drive-backup）／Mac miniの取込失敗・一部失敗・月次未取得アラート・未登録店舗（メール/Larkの切替）／Mac miniのLarkリスナー（入力側）。
- **Chatworkに直接送っているD管轄の通知は無し**。ただし `smaregi-sync` の `notify_chatwork`（と `notify-chatwork`）は、**DB関数（申請・経費・本部タスク通知など＝B/C管轄）がChatworkへ送るための中継**として使われている。
- **勤怠・給与の管理者通知は、すでに Slack のみ**（Lark/Chatwork/LINEは出していない）: 勤怠異常（#勤怠確認）・勤怠のスマレジ側修正（#勤怠確認）・給与の差異確認（#本部-人事）・退職申請（#本部-人事）。解除の作業は不要。

## A. Lark と Slack の両方へ送信中（Lark側を止めてよい候補）
| # | 通知名 | 送信先 | 送信元 | 止め方 | 受信者（チャンネル） |
|---|---|---|---|---|---|
| A1 | Anthropic API費用レポート（毎月1日・毎週月曜・しきい値超過） | Lark＋Slack(hq.dev_system) | EF `api-cost-report-notify`（起動は Actions `api-cost-report-sync`） | EFの`sendLark`のLark送信部分を外す／または共通の`app_secrets.lark_webhook_url`を空にする | LarkのWebhookの先（開発・監視グループ）／Slack #本部-開発システム |
| A2 | 経営API起動時間レポート（毎日・遅い/失敗actionトップ10） | Lark＋Slack(hq.dev_system) | EF `keiei-api-perflog`（起動は Actions `keiei-perflog-daily`） | 同上（`sendLark`のLark部分／`lark_webhook_url`） | 同上 |
| A3 | kd_サマリ更新失敗・店舗名未解決の日次通知 | Lark＋Slack(hq.dev_system) | EF `keiei-kd-refresh`（`sendLark`・unresolved_notify。起動は Actions `keiei-perflog-daily` ほか） | 同上 | 同上 |
| A4 | 朝の見張り番（売上・勤怠の取込確認。異常時のみ） | Lark＋Slack(hq.dev_system) | GitHub Actions（tori-dashboard）`morning-watchdog.yml` | Larkの送信ステップを削除／Lark用のGitHub secretを削除 | 同上 |
| A5 | LINE上限の見張り（LINE配信数がしきい値超過のとき） | Lark＋Slack(hq.dev_system) | GitHub Actions（tori-dashboard）`line-quota-watchdog.yml`（EF `line-quota-check`を参照） | 同上（Larkの送信ステップ／secret） | 同上 |
| A6 | （参考）経営ダッシュボードの日次/月次レポート配信 | Lark＋Chatwork＋Slack | GitHub Actions（tori-dashboard）`lark-report.yml`（GAS `reportDataBQ`） | **担当A管轄**（D管轄外。確認のため記載） | 担当Aが確認 |
- A1〜A3 は**同じ `app_secrets.lark_webhook_url`** を使っている。この1つを空にすれば3件のLark送信が一括で止まる（Slackは変わらない・各EFは「lark_webhook_url未設定」を返して終了するだけ）。戻すときは値を戻す。**値は削除せず控えてから空にする**。

## B. Lark だけで、Slack の並行送信が無いもの（止めるなら先にSlack化が必要）
| # | 通知名 | 送信先 | 送信元 | 止め方 | 受信者 |
|---|---|---|---|---|---|
| B1 | 所属同期の通知（スマレジ側の変更の取込・上書き・新事業所・本部タスク作成・失敗） | Larkのみ | EF `smaregi-affiliation-sync`（`larkPost`・`app_secrets.cockpit_lark_webhook`） | コード側でLark送信を外す（＋先にSlack送信を足す） | Lark（経理チャンネル。コックピットと同じWebhook） |
| B2 | 週次バックアップ失敗（失敗時のみ） | Larkのみ | GitHub Actions（ns-portal）`weekly-drive-backup.yml`（`secrets.LARK_WEBHOOK_URL`） | 失敗通知ステップを削除／secret削除（＋Slack化） | Lark |
| B3 | Mac miniの取込ジョブの失敗・一部失敗・ポータル再実行の成功・月次未取得アラート・未登録店舗（店舗名ゲートウェイ） | **メール／Lark（`NOTIFY_CHANNEL`＝email／lark／both）**。Slackなし | ns-daily-import（Mac mini）`run.js`／`dispatch.js`／`lib/gas.js`・`lib/store-gateway.js` | Mac miniの`.env`の`NOTIFY_CHANNEL`を`email`にする（Lark停止）。**実際の現在値は未確認**（Mac mini側で確認）。止めると Lark の「取込失敗」「未登録店舗」が無くなる→先にSlack化が必要 | メール／Lark |
| B4 | Larkからの手動再実行（受信側。通知ではなく操作） | Lark（入力） | ns-daily-import `lark-listener.js` | リスナーを止めるとLarkからの再実行ができなくなる（ポータルの「▶再実行」は別経路） | 操作者（Lark） |
- B3 は**Slackの並行送信が実装されていない**ため、今回の解除条件（Slackにも出している）に当たらない。Slack化するなら、Mac miniから `notify-slack` Edge Function（合言葉つき）を呼ぶ形が既存の方式に合う。

## C. すでに Slack のみ（解除の作業は不要）
| # | 通知名 | 送信先 | 送信元 | 受信者 |
|---|---|---|---|---|
| C1 | 勤怠異常の確認（○合っている／×修正する ボタン付き） | Slack #勤怠確認（kintai.check）。LINEは11/8に停止済み | EF `smaregi-attendance-anomaly-check` | 店長・TEAM・本部 |
| C2 | スマレジ側で勤怠が直接修正された通知 | Slack #勤怠確認 | EF `smaregi-attendance-sync` | 同上 |
| C3 | 給与の見積もりと確定給与の差異アラート | Slack #本部-人事（hq.jinji）。LINEから変更済み（11/8） | EF `smaregi-payroll-reconcile` | 本部・社長 |
| C4 | 退職申請の通知 | Slack #本部-人事。LINEから変更済み（11/8） | EF `hr-retire-notify` | 本部 |
| C5 | 賃金設定の入社通知 | Slack（入社ワークフロー） | EF `hr-wage-notify`／`onboarding-notify` | 本部 |

## D. 参考（D管轄外だが、同じ仕組みのため記載）
| # | 通知名 | 送信先 | 送信元 | 備考 |
|---|---|---|---|---|
| D1 | 本部タスク・申請・経費・現金手渡し・給与タスク・入社完了などの通知（DB関数 `hq_notify_*`・`notify_lark`・`notify_route_send`・`apply_submit`・`expense_*`・`cash_handoff_*`・`hq_create_payroll_tasks`・`payroll_consistency_check`・`notify_join_*`・`trg_lark_notify`） | **Chatwork／Lark／Slack（ルート設定で選択）** | Supabase DB関数（`pg_net`）。Chatworkは `smaregi-sync` の `notify_chatwork`・EF `notify-chatwork` が中継 | B／C管轄。ルート表（`hq_notify_channels`・`hq_user_notify_routes`）で個人別に切替。**止め方はDB側のルート設定**（コードの変更なしで切替可能な設計） |
| D2 | AI開発コックピットの進捗・承認依頼 | Lark（`cockpit_lark_webhook`） | EF `cockpit-notify`／`cockpit-ingest`（担当H） | H管轄。Slack並行は未実装 |
| D3 | 請求書の支払い検知 | Lark | EF `invoice-payment-scan` | C管轄 |
| D4 | 日報（report_channels） | Lark(3)／Slack(2) | `notify_report_lark` ほか | A／B管轄。チャンネル表（`report_channels`）で設定 |

## 停止の順番（提案・ユーザー確認用）
1. **A1〜A3（Lark側を一括）**: `app_secrets.lark_webhook_url` を空にする1手で停止。戻せる。影響=Slack #本部-開発システム は従来どおり。
2. **A4・A5（tori-dashboardのActions）**: Larkの送信ステップを外すPR。Slackは並行で出ている。
3. **B1（所属同期）**: 先にSlackへ送信を足す（`notify-slack`）→ Lark停止。私が担当。
4. **B2（週次バックアップ失敗）**: 先にSlack送信を足す→ Lark停止。
5. **B3（Mac mini）**: 先に Mac mini→`notify-slack` の送信を足し、`NOTIFY_CHANNEL`を整理（Mac mini側の作業・ユーザー承認）。
6. D1（DBルート）は B/C 管轄のため、各担当の判断。
- **注意**: Larkの通知が全部止まると、`lark-listener`（B4）の入力側と、コックピット（D2）の進捗通知だけが残る。

## 確認事項
- Mac mini の `NOTIFY_CHANNEL` の現在値（email／lark／both）。
- 一覧の「受信者」は、コード上のチャンネル名・Webhookの種類までで、**Lark側の実際のグループ名・参加者は私からは見えない**（ユーザーが確認）。
