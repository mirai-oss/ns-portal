# Lark・Chatwork 通知の解除計画（棚卸し・2026-11-11）

**ユーザー指示（11/11・設計スレッド）**: 「Slack にも通知しているものは、Lark と Chatwork の通知を解除してよい」。
**原則**: ①Slack と並行しているものは Lark/Chatwork 側だけ止める ②Slack に送っていないものは先に Slack 化してから止める（止めてどこにも届かない状態を作らない）③Lark webhook・Chatwork トークン自体の失効は全部終わってから ④値は控えてから空にする（戻せるように）。
担当別の元調査: 担当D `docs/調査_Lark_Chatwork通知の一覧_担当D管轄_2026-11-11.md`、担当B・C は設計スレッド報告（11/11）。担当A 分（lark-report.yml・report_channels の Lark 3 グループと Slack 2 行の対応）は確認中。

## ① Slack 並行あり → Lark/Chatwork 側を止めてよい

| # | 通知 | 今 | 送信元 | 止め方 | 担当 |
|---|---|---|---|---|---|
| 1 | 現金手渡し 全員完了 | L+S | DB notify_lark ← cash_handoff_complete | notify_lark の Lark 送信部を外す（1か所で 1〜7 全部） | B |
| 2 | 本部タスク完了（給与振込・現金手渡し） | L+S | notify_lark ← hq_check_payroll_task_item | 同上 | B |
| 3 | 給料確定の結果 | L+S | notify_lark ← hq_create_payroll_tasks | 同上 | B |
| 4 | 現金手渡し取消・チェック連携失敗 | L+S | notify_lark ← cash_handoff_cancel/complete | 同上 | B |
| 5 | 給与の整合チェック（毎朝 09:50） | L+S | notify_lark ← payroll_consistency_check | 同上 | B |
| 6 | 現金手渡し未完了アラート（毎朝 09:55） | L+S | notify_lark ← cash_handoff_incomplete_alert | 同上 | B |
| 7 | 給料確定の取消（U-27・未適用） | L+S | notify_lark ← hq_cancel_payroll_tasks | 同上 | B |
| 8 | 引き落とし・他行振込の自動照合（新規候補） | L+S(#本部-経理監視) | EF invoice-payment-scan → _shared/cockpit.ts larkPost | larkPost の Lark 部を外す or app_secrets cockpit_lark_webhook を空に（8・9 共通） | C |
| 9 | コックピット通知（完了/ブロック/エラー/承認依頼） | L+S(#本部-開発システム) | _shared/cockpit.ts larkPost（cockpit-notify/ingest ほか） | 同上 | 全担当共通（C/D） |
| 10 | API 費用レポート | L+S(#本部-開発システム) | EF api-cost-report-notify | app_secrets lark_webhook_url を空に（10〜12 一括・値は控える） | D |
| 11 | 経営 API 起動時間 | L+S | EF keiei-api-perflog | 同上 | D |
| 12 | kd サマリ更新失敗・店舗名未解決 | L+S | EF keiei-kd-refresh | 同上 | D |
| 13 | 朝の見張り番 | L+S | tori-dashboard Actions morning-watchdog | ワークフローの Lark 送信ステップ削除 | D |
| 14 | LINE 上限の見張り | L+S | tori-dashboard Actions line-quota-watchdog | 同上 | D |

## ② Slack に送っていない → 先に Slack 化、その後に止める

| # | 通知 | 今 | 送信元 | 先にやること | 担当 |
|---|---|---|---|---|---|
| 15 | 入社通知 | C（S 行あり・無効） | nippo lark_routes join_registered | Slack 行（hq.jinji）を有効化 → Chatwork 行を無効化 | B |
| 16 | 求人応募通知 | C（S 行あり・無効） | lark_routes applicant_new | 同上 | B |
| 17 | 求人メッセージ通知 | C（S 行あり・無効） | lark_routes applicant_message | 同上 | B |
| 18 | 役員チームの日報 | L（S 行あり・無効・**Slack チャンネル未作成**） | lark_routes report_daily(TEAM) | Slack チャンネル作成＋ID 設定（keiei.team_report）→ 有効化 → Lark 行を無効化 | B（チャンネル作成はユーザー） |
| 19 | 精算書: 全店舗の振込完了報告 | L のみ | GAS seisan-dashboard sd_notifyLarkComplete_ | Slack 送信を追加 → シート設定「Lark完了報告Webhook」を空に | C |
| 20 | 精算書: 振込期限リマインド（20日・3日前） | C のみ | GAS seisan-dashboard sd_notifyChatwork_ | Slack 送信を追加 → トリガー停止 | C |
| 21 | 所属同期の結果 | L のみ | EF smaregi-affiliation-sync | Slack 送信を追加 → Lark 停止 | D |
| 22 | 週次バックアップ失敗 | L のみ | ns-portal Actions weekly-drive-backup | Slack 送信に切替 | D |
| 23 | Mac mini 取込の失敗・一部失敗・月次未取得・未登録店舗 | email/lark/both（現在値未確認） | Mac mini NOTIFY_CHANNEL | Slack 化＋NOTIFY_CHANNEL 整理（承認要） | D |

## ③ 個人宛（Slack 代替なし・方針をユーザーに確認）

| # | 通知 | 今 | 送信元 | 論点 |
|---|---|---|---|---|
| 24 | 中山個人宛: タスク割当・日報コメント・いいね・チャット | L のみ | nippo lark_routes（中山通知専用） | Slack DM か専用チャンネルへ移すか、Lark のまま残すか |
| 25 | 個人 Chatwork（3 人）: 本部タスク通知・経費申請（提出/承認/却下） | C のみ | hq_user_chatwork → EF notify-chatwork / smaregi-sync notify_chatwork | 3 人分の Slack 宛先（ユーザーID）が必要。移す先を決めてから |
| 26 | expenses.html の通知先設定（chatwork / lark_webhook） | ユーザー設定の宛先 | EF notify-chatwork | 25 と同じ扱い（経費担当） |

## 対象外（今回は触らない）
- 店舗日報画像（lark-report.yml・group1〜3）: 第3段階（店舗別 Slack 配信）未承認。配信開始 → 3 日連続成功 → ユーザー承認後に Lark/Chatwork 日報を停止（設計書 §12.2）。
- 従業員向け LINE 通知: U-22 で別途検討。
- 勤怠・給与の管理者通知: すでに Slack のみ。

## 実施順（案）
1. ①の 1〜7（notify_lark 1か所・B）→ 8・9（cockpit larkPost・C）→ 10〜12（lark_webhook_url 空・D）→ 13・14（Actions・D）
2. ②の 15〜17（Slack 行有効化→Chatwork 停止・B）→ 18（チャンネル作成後）→ 19・20（C）→ 21・22（D）→ 23（承認後）
3. ③はユーザー回答後
4. 最後に Lark webhook・Chatwork トークンの失効（全停止の確認後）

## ユーザー回答（2026-11-11・設計スレッド）
- ①の 14 件: **OK**（Lark/Chatwork 側を止める。Slack はそのまま・値は控えてから空にする）
- 入社通知（15）: Slack #人事 の流れができたら Chatwork を止めてよい → Slack 行（hq.jinji）有効化 → Slack 到着確認 → Chatwork 停止
- 求人応募（16）・求人メッセージ（17）: **別で作成するので一旦止めない**（現状維持）
- その他②（18〜23）: Slack チャンネル・通知の流れができたら止める（Slack 化 → 到着確認 → 承認 → 停止）
- ③個人宛（24〜26）: **それぞれの個人の Slack DM へ変更**（タスク割当・個人 Chatwork の通知先）。ID は docs/チャットに書かず、ユーザーが直接登録

## 実施方法の決定（2026-11-11・設計）
- 10〜12（lark_webhook_url）: 空にせず **キー名を `lark_webhook_url__disabled_20261111` に付け替えて無効化**（値は誰も見ず DB に残る・戻すときはキー名を戻す・全停止後の失効時に行を削除）。読むのは EF 3 本のみ（DB 関数は別キー lark_webhook）。
- 13・14（tori-dashboard Actions・公開リポ）: Lark 送信削除＋**Slack 送信を必須化**（未設定・非200 で exit 1）。Lark だけ削ると Slack 失敗が素通りするため。差分に値・チャンネル ID を含めない。
- 8・9（cockpit larkPost）: 共有ファイルの Lark 部を削除（C）。再デプロイ: C=cockpit-ingest・cockpit-notify・invoice-payment-scan、D=smaregi-affiliation-sync（21 の Slack 化と同時）。keiei-kd-refresh・api-cost-report-notify・keiei-api-perflog は cockpit.ts 不使用（10〜12 で停止）。
- 19・20（精算書 GAS）: 宛先 #本部-経理監視。GAS→既存 EF notify-slack（x-notify-secret・dedupe_key 例 seisan_complete:YYYY-MM / seisan_remind:YYYY-MM-DD）。GAS プロパティはユーザーが画面で直接登録。テスト関数で到着確認→承認→Lark webhook 設定・Chatwork ルームを空に。
- 21（所属同期）: #本部-人事（失敗・見送りは #本部-開発システム）。EF から notify-slack を service_role で呼ぶ（設定追加なし）。
- 22（週次バックアップ）・23（Mac mini）: **新しい秘密は作らない**。既に持っている service_role 資格情報で notify-slack を呼ぶ（案 c）。「処理ごとに別 Secret」原則の例外は「元から service_role を保持している呼び出し元」に限る。条件: ログに鍵・URL を出さない／dedupe_key／失敗を握りつぶさない（22 は job 失敗、23 はメール経路併存）／23 は NOTIFY_CHANNEL 現在値を確認してから。
- 24〜26（個人宛 Slack DM）: 宛先は既存 user_slack（user_id↔slack_user_id・自動紐づけ）を使い新保管場所なし。経費申請の提出者→承認者通知は RPC 内から notify_route_send('slack','user:<承認者id>') で DB 側送信（画面から送らない）。本部タスク通知（hq_notify_*）と合わせて 1 本の設計を B・C が提示→承認後に実装。
- 各担当の本番変更は、設計スレッドの承認に加えて **各担当セッションでユーザー本人の承認** を取ってから実行する。

## 担当B 設計案（2026-11-11・設計了承・実行はユーザー意向確認後）
- 15 入社通知: nippo「Lark通知設定」で Slack 行（hq.jinji）を ON → 同画面の「テスト送信」で #本部-人事 到着確認 → Chatwork 行 OFF。
- 24 中山個人宛: notify-slack は channel_key='user:<users.id>' で user_slack から Slack ID を引き DM 送信できる（実装済み・14 人紐づけ済み）。lark_routes に Slack DM 行（同 4 イベント・is_active=false）追加 → ON → テスト送信 → Lark 行 OFF。ID は docs に書かない。
- 25 個人 Chatwork 3 人（全員 user_slack 紐づけ済み）: 各通知関数（hq_notify_comment/step_event/task_urgent・hq_check_alerts・expense_submit/approve/reject）に notify_route_send('slack','user:'||user_id,…) を並行送信として追加 → DM 到着確認 → Chatwork 送信を外す。hq_user_notify_routes の拡張は不要。まず 1 人・1 イベントで確認してから全員へ。
- 1〜7 notify_lark の Slack 一本化: **11/11 適用済み**（ユーザー実行・司令塔読み取り: md5 c0c94565…・本文に lark_webhook なし・slack あり・PUBLIC/anon 不可・authenticated 可・1本）。現金手渡し・給料確定・毎朝チェックの通知は Slack #本部-経理監視 のみに。ユーザー報告「現金手渡しの通知が求人応募のところに来る」は Lark 側グループの話で、本件で解消。
- 15 入社通知: ユーザー回答（B セッション）「入社処理を Slack で対応する別タスクを作っているので通知は不要」→ Slack 行は有効化せず、Chatwork『入社通知』行を無効化（ユーザーが画面で操作）。
- 24 中山個人宛: lark_routes に Slack DM 行（is_active=false）追加済み（ユーザー適用）。次: テスト送信→DM 到着→有効化→Lark 行 OFF。
- 運用注意（11/11 事故）: 共有の ~/ns-portal 作業ツリーで `git pull --rebase --autostash` を使い、他担当の未コミット編集が stash に退避された（C が v171 で復旧・実害なし）。**各担当は自分の worktree で作業し、共有作業ツリーで pull/rebase/autostash をしない。**

## 進捗
- 11/11 午後〜夜 **日報の Lark/Chatwork 停止・#経営-レポート停止（A セッションでユーザー前倒し指示）**: 店舗別 Slack 配信 8 店が本番稼働（11/10 分 8/8 送信）。Lark group1〜3 無効化・lark-report.yml の Lark 直送ジョブ停止（5820896）・Chatwork は有効な送り先なし・slack_tori/slack_nstyle も無効化（週報・月報を含め #経営-レポート への配信はすべて停止）。nippo 側日報は未変更。→ 解除計画の「対象外（日報）」は解消。27 番は結果として「Slack 側も停止」となった（週報・月報はどこにも配信されない状態＝再開するなら slack_tori/slack_nstyle を有効化）。
- 11/11 ①の 8・9 **完了**（C セッションでユーザー承認）: _shared/cockpit.ts larkPost の Lark 送信削除（d87f62d）。再デプロイ cockpit-ingest v24→v25 / cockpit-notify v12→v13 / invoice-payment-scan v25→v26（--no-verify-jwt）。smaregi-affiliation-sync（v24）は D が B1 と同時に再デプロイ予定。app_secrets の cockpit_lark_* は未削除（失効は全停止後）。戻し方: cockpit.ts を d87f62d の 1 つ前に戻して再デプロイ。
- 27（追加・担当A）: 経営レポート 週報・月報（tori-dashboard Actions lark-report.yml report ジョブ＋group1〜3）: L＋S(#経営-レポート・#経営-レポート-nstyle) 並行済み → ①相当。止め方=report_channels group1〜3 の report_kinds を {daily} に／report ジョブに weekly/monthly を送らない条件（約5行）。次回週報 11/15・月報 12/1 → 11/14 までに反映が望ましい。戻し方=report_kinds を戻す・条件を外す。**日報は対象外**。**11/11 承認・適用済み**（report_channels group1〜3 → {daily}・lark-report.yml report ジョブに weekly/monthly 除外・tori-dashboard 65432fb）。事後確認=11/15 の週報が Slack のみに届くこと（A が当日確認）。
- 19・20（精算 GAS）の Slack 送信は C のローカル未コミット（本番 GAS 未反映・プロパティ未登録・到着確認 0 件）。手順書（GAS 差分のみ）→プロパティ登録→sd_testSlack 1 回→到着確認→承認→設定シート 3 セル（Lark完了報告Webhook・ChatWork APIトークン・ルームID）を空に。
- 2026-11-11: 棚卸し完了（A 分も受領）。ユーザー回答済み。①の実行を B（1〜7 notify_lark）・C（8・9 cockpit larkPost）・D（10〜14）へ指示。②③は設計案待ち。
