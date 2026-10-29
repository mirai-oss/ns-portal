# 通知一覧（Chatwork・Lark・LINE）— 管理システム全体の棚卸し

作成: 2026-10-29 ／ 調査対象: ns-portal（Edge Function・DB関数・画面）、nippo、tori-dashboard（GAS・GitHub Actions）、ns-daily-import（Mac mini日次取込）、ns-info-system、Hermes（AI窓口）
確認方法: 各リポジトリのコードを読み、本番DBの設定テーブル（`lark_routes`・`hq_notify_channels`・`hq_notify_rules`・`report_channels`・`hq_user_chatwork`）の実データと突き合わせた。
凡例: **目的** 何のための通知か／**いつ** トリガーと時刻／**宛先** 実際の送り先／**内容** 本文の要点／**実装** 送信コードの場所

---

## 0. 全体像（チャネルの使い分け）

| チャネル | 主な役割 | 送り先の種類 | 件数 |
|---|---|---|---|
| **Chatwork** | 本部メンバー個人への「あなた宛て」の業務通知（本部タスク・承認依頼・申請）＋採用・入社の共有ルーム | 個人ルーム（`hq_user_chatwork`）、共有ルーム（`hq_notify_channels`・`lark_routes`の chatwork 行） | 12種 |
| **Lark** | 経営者・経理向けの「レポートと監視」（売上日報・取込結果・異常・AI利用料・コックピット） | 固定Webhook数本（経理チャンネル／監視用／レポート用group1〜3／中山通知専用） | 24種 |
| **LINE** | 従業員・応募者本人への連絡（シフト・入社・面接・退職）＋本部の承認者への即時アラート＋AI窓口 | 個人（`users.line_user_id`・`applicants.line_user_id`）、発注グループ、AI窓口 | 22種 |
| メール | 補助（LINE未連携者への合言葉・招待リンク。日次取込のメール通知は現在OFF） | — | 2種 |

**宛先の設定場所（正本）**

| 設定 | 場所 | 今の中身 |
|---|---|---|
| nippo系イベントの配信先 | `lark_routes`（nippo「🔔通知を設定する」） | 有効5件: 役員チームの日報(Lark・report_daily)／中山通知専用(Lark・入社登録/タスク割当/日報コメント/いいね/チャット呼びかけ)／入社通知(Chatwork 382748319)／求人応募通知(Chatwork 444371121)／求人メッセージ通知(Chatwork 444830575)。無効1件: 応募の通知(旧Lark) |
| 本部タスクの共有ルーム | `hq_notify_channels` ＋ `hq_notify_rules`（tasks.html 通知設定） | チャンネル3件（中山通知 45746089／タスク齋藤 448992342／青山コメント通知 448997945・すべてChatwork）。ルール4件: mention→中山、mention→青山、due_alert→齋藤、**mention→存在しないチャンネル（削除済みIDを参照・効いていない）** |
| 本部メンバーの個人ルーム | `hq_user_chatwork`（4人登録）／`hq_user_notify_routes`（イベント別振り分け・**0件＝未使用**） | 1人は room_id に URL が入っている（`https://www.chatwork.com/g/...`）→ ルームIDではないため届いていない可能性 |
| 経営Dの日報・週報・月報 | `report_channels`（nippo 店舗管理→配信グループ管理） | group1〜3（すべてLark・GitHub Secret `LARK_WEBHOOK_GROUP1〜3`・日報/週報/月報すべて） |
| 固定Webhook・トークン | `app_secrets`（lark_webhook / lark_webhook_url / cockpit_lark_webhook / chatwork_token / line_channel_token / line_order_group_id）、GitHub Secrets（LARK_WEBHOOK / LARK_WEBHOOK2 / LARK_WEBHOOK_URL / CHATWORK_API_TOKEN）、Mac mini `.env`（LARK_WEBHOOK・NOTIFY_CHANNEL=lark） | — |

---

## 1. Chatwork（12種）

| # | 目的 | いつ | 宛先 | 内容 | 実装 |
|---|---|---|---|---|---|
| C1 | 本部タスク: 自分宛てメンション | コメントで @メンションした時 | 本人の個人ルーム＋ルール（中山・青山の通知ルーム） | 「メンションされました: タスク名」＋[To:id]本文＋タスクURL | tasks.html → RPC `hq_notify_comment` → EF `notify-chatwork` |
| C2 | 本部タスク: 期限アラート | **誰かが tasks.html を開いた時**に判定（cronではない）。同じタスク・同じ種類は1日1回 | 現工程の担当者（いなければ作成者）の個人ルーム＋ルール（齋藤の通知ルーム） | 「期限超過／本日期限／明日期限／期限3日前: タスク名」＋工程＋URL | tasks.html → RPC `hq_check_alerts` |
| C3 | 本部タスク: 停滞 | 同上（3日以上停止） | 同上 | 「停滞: タスク名 N日停止」＋URL | 同上 |
| C4 | 本部タスク: 工程完了・次の人へ | 工程を完了にした時 | 次工程の担当者の個人ルーム | 「あなたの番です: タスク名」「次工程をお願いします」 | tasks.html → RPC `hq_notify_step_event` |
| C5 | 本部タスク: 異常あり | 工程で「異常あり」を選んだ時 | 作成者の個人ルーム | 「異常あり: タスク名」「工程 — 内容」 | 同上 |
| C6 | 本部タスク: 最重要 | 🔥最重要にした時 | 担当者＋作成者の個人ルーム | 「🔥最重要: タスク名」「いま: 工程」 | tasks.html → RPC `hq_notify_task_urgent` |
| C7 | 経費申請の承認依頼 | 申請を提出した時 | 承認者の個人ルーム（`hq_user_chatwork`のみ） | 「経費申請の承認をお願いします」申請者・目的・金額 | expenses.html → RPC `expense_submit` |
| C8 | 経費申請の結果 | 承認／差戻し時 | 申請者の個人ルーム | 「承認されました」／「差し戻されました…理由」 | RPC `expense_approve` / `expense_reject` |
| C9 | 個人情報の変更申請 | 従業員が住所等の変更を申請した時 | マスター・本部全員の個人ルーム | 「🔁 変更申請: ○○さんが『項目』を申請」＋承認パネルの場所 | requests.html → `hq_user_chatwork` |
| C10 | ID/PW の新規・変更申請 | 社内情報のID/PW申請時 | 承認者（マスター・本部）の個人ルーム | 「🔁 変更申請: …『サービス』の項目変更」 | requests.html → RPC `info.get_approver_chatwork_rooms` |
| C11 | 入社登録の完了 | 入社登録が完了しスマレジ登録が済んだ時（再送ボタンもあり） | **共有ルーム「入社通知」(382748319)** | 「○○さんが入社登録しました」＋スマレジ従業員ページのリンク（時給・店舗設定の依頼） | nippo → RPC `notify_join_complete` → `notify_route_send` → EF `smaregi-sync` の中継 |
| C12 | 求人の応募／応募者からのメッセージ | 応募フォーム送信時／応募者がLINEでメッセージを送った時 | **共有ルーム「求人応募通知」(444371121)／「求人メッセージ通知」(444830575)** | 応募者名・希望店舗・希望日時 等／メッセージ本文 | `applicants`/`notifications` INSERT → トリガー `trg_lark_notify` → `lark_routes` |

補足: Chatwork への実送信は2経路。画面からは EF `notify-chatwork`（Secret `CHATWORK_API_TOKEN`）、DBトリガーからは `notify_route_send` → EF `smaregi-sync` の `notify_chatwork`（`app_secrets.chatwork_token`）。

---

## 2. Lark（24種）

### 2-A. 経営レポート（Webhook: GitHub Secret `LARK_WEBHOOK` ／ `LARK_WEBHOOK2` ／ `LARK_WEBHOOK_GROUP1〜3`）

| # | 目的 | いつ | 宛先 | 内容 | 実装 |
|---|---|---|---|---|---|
| L1 | 全店の売上日報 | 毎日 12:00 JST（GAS LarkCron が15分おきに時刻判定→GitHub Actions 起動） | LARK_WEBHOOK のグループ | 前日の売上・前年比・客数・客単価・F率・L率・ダイニー再来店・月間累計・前年超え/割れ店数・店舗別トップ3・ダッシュボードURL | tori-dashboard `lark-report.yml` → `scripts/lark-report.mjs` |
| L2 | 週報 | 1・8・15・22・29日 12:15 | 同上 | 週の集計版 | 同上 |
| L3 | 月報 | 毎月1日 12:30 | 同上 | 月の集計版 | 同上 |
| L4 | 鳥一代8店舗に絞った日報 | L1と同時 | LARK_WEBHOOK2 | 8店舗分 | 同上（第2レポート） |
| L5 | 配信グループ別・1店舗ごとの日報 | L1と同時 | `report_channels` group1〜3（Secret LARK_WEBHOOK_GROUP1〜3） | 店舗ごとの売上・前年比・ランチ/ディナー・媒体別トップ3・累計F/L | 同上（group-report ジョブ。設定は nippo 配信グループ管理） |
| L6 | 役員チームの日報（nippo の日報本文） | 役員チーム(TEAM)の人が日報を新規提出した時 | `lark_routes`「役員チームの日報」 | 日報本文そのまま | nippo → RPC `notify_report_lark` |
| L7 | Larkからの再送コマンド返信 | Larkグループで「日報」「週報」「再送」「ヘルプ」と発言 | 発言したグループ | 「了解しました。○報を再生成…」等 | tori-dashboard `gas/LarkBot.gs` |

### 2-B. 経理・運用の監視（Webhook: Mac mini `.env` LARK_WEBHOOK ＝ 経理チャンネル）

| # | 目的 | いつ | 内容 | 実装 |
|---|---|---|---|---|
| L8 | 日次取込のまとめ | 毎朝、全タスク完了後に1通（08:30以降） | 「日次取込 ✅全件成功／⚠️n件失敗」＋タスク別の所要時間・試行回数・失敗理由 | ns-daily-import `dispatch.js` |
| L9 | 取込タスクの失敗／一部失敗 | 月次・独立タスクの失敗時、ポータルからの再実行時、一部失敗時 | 「[タスク名] 失敗」＋エラー | `run.js` |
| L10 | 月次会計取込の未取得アラート | 予定日の期限（+24h）を過ぎても成功していない間、1日1回・10日間 | 予定日時・超過日数・前回結果・再実行コマンド | `lib/monthly-overdue-alert.js` |
| L11 | 現金売上の照合結果 | 毎月3日 08:00 | 「現金売上照合 YYYY-MM」全店一致／差異のある店舗の表 | `tasks/cash-sales-monthly-check.js` |
| L12 | 現金修正依頼の結果 | ポータルの「レジに合わせて修正」実行後 | 修正件数・残差・仕訳候補 | `lib/cash-fix.js` |
| L13 | SMBCカード売上の取込結果 | 12日・28日 07:50（N-Style）、2日・17日 08:10（トーホー） | 明細ごとの売上・手数料・PDF照合結果（金額差があれば❌） | `lib/smbc-card-common.js` |
| L14 | シートとBigQueryの突合差額 | 毎日 08:45 と 11:00、差額がある時だけ | 純売上・仕入・人件費の差額 | `tasks/morning-refresh.js`／`bq-sales-reconcile.js` |
| L15 | 未知の店舗名・店舗ID | 取込中に未登録の店舗名を見つけた時 | 保留した行と `store_aliases`/`delivery_store_map` への登録方法 | `lib/store-gateway.js`／`tasks/delivery-sales.js` |
| L16 | 取引先が確定できない請求書 | 毎日 10:30 のインフォマート請求書取込 | 未確定の一覧と承認依頼 | `tasks/infomart-invoice.js` |
| L17 | Larkコマンドの受付・結果返信 | Larkグループで「実行 スマレジ」等と発言（15秒ごとに監視） | メニュー／▶実行します／✅完了・❌失敗 | `lark-listener.js` |

### 2-C. 経理チャンネル（`app_secrets.cockpit_lark_webhook`）

| # | 目的 | いつ | 内容 | 実装 |
|---|---|---|---|---|
| L18 | AI開発コックピットのタスク状態 | タスクの完了・ブロック・エラー・承認依頼・承認・却下（画面操作またはCLI） | 「【AI開発コックピット】✅完了 TK-n…」担当・次にやること・URL | EF `cockpit-notify` / `cockpit-ingest` |
| L19 | 定期ジョブの失敗 | ai-cockpit watch が約10分ごとに Mac mini・GitHub Actions の結果を確認し失敗があった時 | 「🚨 定期ジョブ失敗: ジョブ名」＋メッセージ | EF `cockpit-ingest` |
| L20 | スマレジ所属同期の結果 | 毎日 08:00 JST目安の勤怠取込の後 | 所属の反映・衝突・未対応事業所・エラー（最大40行） | EF `smaregi-affiliation-sync` |
| L21 | 引き落とし・他行振込の自動照合 | 1日1回（9時以降・GAS 5分トリガー経由） | 照合OK候補／金額違い／売上入金の自動入金／期日超過の未払い | EF `invoice-payment-scan` |

### 2-D. 開発・インフラ監視（`app_secrets.lark_webhook_url` ／ GitHub Secret）

| # | 目的 | いつ | 内容 | 実装 |
|---|---|---|---|---|
| L22 | AI利用料レポート | 毎日 09:00 判定: 毎月1日（前月合計）・毎週月曜（今月累計）・閾値を初めて超えた日 | 「📊 前月のAI利用料 ¥…」等 | EF `api-cost-report-notify`（cron-job.org→Actions） |
| L23 | 経営D/精算Dの計測レポート | 毎日 09:10 | 遅い処理・失敗した処理トップ10・起動時間 | EF `keiei-api-perflog` |
| L24 | kd_集計の更新失敗／未解決の店舗名・媒体名 | 毎時0分（8〜23時）の失敗時／毎日 09:10 | 「⚠️ kd_サマリ更新に失敗」／「🏷️ 未解決の店舗名/媒体名 上位20件」 | EF `keiei-kd-refresh` |
| L25 | 朝の見張り番（売上・勤怠の取込漏れ） | 毎日 09:30（cron-job.org）。欠損がある時だけ | 「⚠️ 日付の取込が確認できません（売上・勤怠）」＋店舗名ゲートウェイの保留件数 | tori-dashboard `morning-watchdog.yml`（Secret LARK_WEBHOOK） |
| L26 | LINE送信数の見張り番 | 毎日 09:30 目安。80%で注意・95%で警告 | 「LINE公式アカウントの今月の送信数 使用/上限」 | `line-quota-watchdog.yml` |
| L27 | 週次Driveバックアップの失敗 | 毎週日曜 15:00 目安、失敗時のみ | 「❌ 週次Driveバックアップ 失敗」＋ログ | ns-portal `weekly-drive-backup.yml`（Secret LARK_WEBHOOK_URL） |

### 2-E. nippo の個人向け Lark（`lark_routes`「中山通知専用」＝社長専用Webhook／`app_secrets.lark_webhook`）

| # | 目的 | いつ | 内容 | 実装 |
|---|---|---|---|---|
| L28 | 入社登録・タスク割当・日報コメント・いいね・チャットの呼びかけ | 各イベント発生時（`notifications` INSERT） | 通知本文（日本語）＋リンク | トリガー `trg_lark_notify` → `lark_routes` |
| L29 | 当日の面接予定 | 応募者管理を開いた時（1日1回） | 「📅本日の面接予定（n件）」時刻・氏名 | nippo → `notifications` → 同上 |
| L30 | チェックシートの期限切れ | GASが5分ごとに判定（期限切れ未チェックがある時） | 「⏰ 期限切れ未完了: 店舗『項目』」 | RPC `checklist_overdue_check` → `notifications` → 同上 |
| L31 | 給与タスク完了・現金手渡し完了 | 振込完了操作時／その月の手渡し対象が全員完了した時 | 「✅ タスク名 が完了しました」／「💴 現金手渡し完了：YYYY-MM分 全N名」 | RPC `hq_check_payroll_task_item`／`cash_handoff_complete` → `notify_lark`（既定Webhook） |

---

## 3. LINE（22種・すべて公式アカウント1本 `app_secrets.line_channel_token`）

### 3-A. 従業員本人へ（nippo）

| # | 目的 | いつ | 宛先 | 内容 |
|---|---|---|---|---|
| N1 | シフト提出の締切リマインド | 店長以上がシフト画面を開いた日（締切当日の対象者に1回） | 対象従業員 | 氏名・締切・期間名 |
| N2 | 未提出者への催促 | 「未提出者に通知」ボタン | その期間に1日も提出していない人 | 提出依頼 |
| N3 | 確定シフト未確認者への再通知 | 「未確認者へ再通知」ボタン | 公開済みシフトを未確認の人 | 「『期間』の確定シフトをまだ確認していません」 |
| N4 | 出勤強化日のお知らせ | 出勤強化日を保存した時 | その店舗の在籍者全員 | 「🔥出勤強化日」日付・インセンティブ |
| N5 | 急募のお知らせ・再通知・採用決定 | 急募作成／再通知ボタン／応募者を採用した時 | 店舗の在籍者全員／採用された本人 | 「🚨急募」日時・役割／「採用が決まりました」 |
| N6 | 入社登録完了の案内 | 入社登録フォーム送信成功時 | 本人 | このあとの流れ・マニュアル・所属店舗 |
| N7 | スマレジ登録の案内 | 本部タスク「📱LINEで案内を送る」ボタン | 本人 | スマレジ・タイムカード登録URL |
| N8 | 源泉徴収票が届いた案内 | 源泉徴収票をアップロードしOKした時 | 本人 | 「ポータルの『自分の書類』から確認を」 |
| N9 | LINE連携の合言葉への返信・連携完了の入社案内 | 本人が合言葉を送った時 | 本人（返信） | 連携結果／入社案内 |

### 3-B. 応募者へ（nippo 採用管理）

| # | 目的 | いつ | 宛先 | 内容 |
|---|---|---|---|---|
| N10 | 面接の候補日時・面接案内・面接確定 | 各ボタン／面接日時を確定した時（自動） | 応募者 | 日時・URLまたは場所 |
| N11 | 面接前日リマインド・入社登録の催促 | 毎日（GASから `action=daily`・時刻は未確認） | 当日対象の応募者 | 面接日時／入社登録URL |
| N12 | 採用・招待・入社案内・自由文 | 採用（招待発行）／「入社案内を送る」／自由文送信 | 応募者 | 入社登録URL付き招待文／入社案内／任意の文 |

### 3-C. 本部・承認者へ（即時アラート）

| # | 目的 | いつ | 宛先 | 内容 | 実装 |
|---|---|---|---|---|---|
| N13 | 退職申請が出た | 申請直後（nippo・公開フォーム） | LINE連携済みのマスター・社長・本部全員＋該当店舗のチーム長 | 「【退職申請】店舗 ○○さん（退職日）」申請者・備考・一覧URL | EF `hr-retire-notify` |
| N14 | 入社した人の賃金を決めてほしい | 入社登録完了時 | LINE連携済みのマスター・社長・本部 | 「【入社登録】○○さん（区分／店舗）」賃金の返信依頼（「時給 1200」で返信→登録・スマレジ反映） | EF `hr-wage-notify`＋返信処理 |
| N15 | 給与突合アラート | 毎月5日 08:00、差額1,000円以上の人がいる時 | 社長・本部（LINE連携済み） | 人ごとの勤怠実績合計／給与明細／差額 | EF `smaregi-payroll-reconcile` |
| N16 | 勤怠の異常値 | 毎日 08:00、異常がある時 | 同上 | 1時間以内／13時間超／24時間超の勤務 | EF `smaregi-attendance-anomaly-check` |

### 3-D. グループ・その他

| # | 目的 | いつ | 宛先 | 内容 | 実装 |
|---|---|---|---|---|---|
| N17 | 仕入れ移動の申請 | 公開フォーム送信時 | 発注グループ（`line_order_group_id`） | 「🔀 移動元→移動先」品目・数量・合計・申請者 | EF `cost-transfer-submit` |
| N18 | 発注グループの登録確認 | BotをLINEグループに招待した時 | そのグループ | 「発注グループとして登録しました」 | EF `line-webhook` |
| N19 | AI窓口の回答 | LINEで質問した時 | 質問した本人（許可ユーザー1名） | 売上・日報・タスク等の実データ回答／機密はリンク案内 | Hermes Agent（Mac mini） |
| N20 | AI窓口の再起動通知 | LINE窓口（ゲートウェイ）が停止・再起動した時 | ホームチャンネル（社長） | 停止通知 | Hermes gateway |
| N21 | 任意の個別送信 | アプリから `push_user`（本部タスクの案内等） | 従業員1人 | 呼び出し側の本文 | EF `line-webhook` |
| N22 | 応募者への個別送信 | 採用画面（recruit権限） | 応募者 | 担当者の入力文 | EF `line-webhook` |

---

## 4. メール（2種）

| # | 目的 | いつ | 宛先 | 実装 |
|---|---|---|---|---|
| M1 | LINE未連携者へ連携用の合言葉を一斉送信 | nippo「LINE未連携者へ一斉メール」ボタン | 未連携者の登録メール（Resend） | EF `line-code-bulk-email` |
| M2 | 社内情報管理システムへの招待 | 設定画面で招待 | 入力したメール（Supabase Auth） | ns-info-system |
| 参考 | 日次取込のメール通知 | Mac mini `.env` の NOTIFY_CHANNEL が `lark` のため**現在OFF** | — | ns-daily-import |

---

## 5. 気づいた点（整理の候補）

1. **効いていない設定が2つ**: `hq_notify_rules` に削除済みチャンネルを指す「中山メンション」ルールが残っている（もう1本の同名ルールが生きているので実害なし・消してよい）。`hq_user_chatwork` の1人は room_id にURLが入っておりルームIDになっていない（この人宛ての本部タスク通知は届いていない可能性）。
2. **本部タスクの期限アラート（C2・C3）は cron ではなく「誰かが tasks.html を開いた時」に飛ぶ**。誰も開かない日は出ない。定時に出したいなら cron 化が必要。
3. **Lark の Webhook が用途別に6本以上**（経営レポート×5、経理チャンネル、監視用、社長専用）に分かれており、どのグループに何が届くかは Secret 名でしか追えない。一覧表の宛先列を Lark グループ名に置き換えるには、各Webhookがどのグループかをご確認いただく必要がある。
4. **Chatwork に寄せる方針との関係**: 経営者・本部向けの業務通知はすでに Chatwork（本部タスク・承認・申請・入社・応募）。Lark に残っているのは「売上日報・取込の監視・AI利用料・コックピット」の経理/開発系と、社長専用の nippo 通知。Chatwork へ移すなら、`lark_routes` と `report_channels` は kind を chatwork に切り替えるだけで移せる（コード対応済み）。Mac mini の日次取込（L8〜L17）と GitHub Actions の監視（L22〜L27）は Chatwork 送信コードが未実装。
5. **同じ内容が2経路で届くもの**: 入社登録は Chatwork「入社通知」（C11）と社長専用Lark（L28）の両方、取込失敗は日次まとめ（L8）とコックピットの定期ジョブ失敗（L19）の両方に出る。
6. **送信先がコードに無く本番だけにある部品**: EF `notify-chatwork`（ソース未管理）、DB関数 `notify_lark`・`trg_lark_notify`・`notify_route_send`（SQLファイルが一部リポジトリに無い）。復旧できるようリポジトリへの保存を推奨。
7. **時刻が「目安」のもの**: cron-job.org 発火（09:00／09:10／09:30 など）は登録画面でしか確認できない。
