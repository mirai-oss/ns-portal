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

## 進捗
- 2026-11-11: 棚卸し完了（A 分は確認中）。ユーザー回答済み。①の実行を B（1〜7 notify_lark）・C（8・9 cockpit larkPost）・D（10〜14）へ指示。②③は設計案待ち。
