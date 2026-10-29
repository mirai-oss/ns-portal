# 設計書: Slack 通知基盤 Phase 1（2026-10-29）

**状態**: 設計・復元・準備まで完了（本番の通知先は未切替）。実装着手は WORKLOG 📋バックログ (1c) TK-240〜TK-251 の順。
**関連**: [通知一覧_Chatwork_Lark_LINE_2026-10-29.md](通知一覧_Chatwork_Lark_LINE_2026-10-29.md)（移行対象の全件）／[手順書_Slackアプリ作成とトークン保存_2026-10-29.md](手順書_Slackアプリ作成とトークン保存_2026-10-29.md)（ユーザー作業）／[slack/app-manifest.yaml](slack/app-manifest.yaml)／SQLドラフト `supabase/2026-10-29_slack_notify_phase1.sql`／Edge Function ドラフト `supabase/functions/notify-slack/`・`supabase/functions/slack-interact/`／本番スナップショット `supabase/restored/2026-10-29_notify_functions_prod_snapshot.sql`・`supabase/functions/notify-chatwork/`

---

## 0. 確定方針（ユーザー・2026-10-29）

| # | 方針 |
|---|---|
| 1 | Socket Mode / App Token は使わない。Supabase Edge Function の Request URL ＋ Slack 署名検証方式 |
| 2 | Slack App / Bot は 1 つ |
| 3 | Bot Token は Slack 送信専用 Edge Function `notify-slack` だけが保持する |
| 4 | 各送信元は `notify-slack` へ「channel_key ＋ payload」を渡す（直接 Slack API を叩かない） |
| 5 | 経営レポートは現在の閲覧対象に合わせて 3 チャンネルに分ける |
| 6 | Phase 1〜3 を先行。アルバイト全員への Slack 展開は結果と費用を見て Phase 4 で判断 |
| 7 | `notify_route_send`・`notify-chatwork` は本番から完全復元し、差分確認後に変更する（復元済み・§14） |
| 8 | Slack user ID は `users:read.email` でメール自動照合（users は ALTER 禁止のため別表 `user_slack`） |
| 9 | 新旧通知は 2 週間並行し、欠落ゼロを確認してから旧通知を停止 |
| 10 | Hermes / Mirai 連携は後から同じ Slack 基盤へ載せられる構造にする |
| 11 | **Slack 通知 1 件ごとに `notification_id` を必ず持つ**（notification_id → channel_key → slack_channel_id → slack_ts → delivery_status） |
| 12 | **アクション付き通知を基盤に含める**（勤怠アラートの「合っている／修正する／詳細」を筆頭に）。Slack から DB を直接更新する実装は禁止。Slack interaction → Edge Function → 権限確認 → 既存 RPC/API → DB 更新の順。操作できる人は既存 RBAC に従う |
| 13 | Slack は通知と簡易操作の入口。タスク・勤怠・申請・会計の正式な状態は管理システムが正本 |
| 14 | 入社前（応募者）は LINE 継続。入社後の業務連絡は最終的に Slack。従業員向け LINE は Phase 4 まで止めない |

---

## 1. 現状の送信元と経路（移行前・事実）

| 送信元 | 実装 | 今の宛先 | Phase |
|---|---|---|---|
| **DB 関数**（nippo イベント） | `trg_lark_notify`（`notifications` の AFTER INSERT）→ `lark_routes` → `notify_route_send(kind, webhook_url, text)`。`notify_report_lark`／`notify_join_complete`／`notify_join_resend` も同じ `notify_route_send` 経由 | Lark Webhook（直接 pg_net）／Chatwork（`smaregi-sync` の `notify_chatwork` アクションに中継） | 1-a |
| **DB 関数**（本部タスク） | `hq_notify_step_event`／`hq_notify_comment`／`hq_notify_task_urgent`／`hq_check_alerts`／`expense_*` は **送らずに宛先一覧を返す**（`channel_kind, target, keyword, title, body`）。ブラウザ（ns-portal `tasks.html`・`expenses.html`・`requests.html`）が Edge Function `notify-chatwork`（JWT 必須）を呼んで送る | Chatwork 共有ルーム（`hq_notify_channels`）／個人ルーム（`hq_user_chatwork`・`hq_user_notify_routes`）／Lark Webhook | 1-c（共有）／3（個人） |
| **DB 関数**（経理） | `cash_handoff_complete`・`hq_check_payroll_task_item` → `notify_lark(text)`（`app_secrets.lark_webhook`） | Lark（社長専用） | 2 |
| **Edge Function** | `_shared/cockpit.ts` の `larkPost`（`app_secrets.cockpit_lark_webhook`）・`notifyTaskEvent`／`api-cost-report-notify`／`hr-wage-notify`・`hr-retire-notify`（LINE） | Lark 経理／LINE | 2（Lark）・4（LINE） |
| **GitHub Actions**（tori-dashboard） | `lark-report.yml` → `report_channel_matrix_v` でグループ×店舗の matrix → `scripts/lark-report.mjs`（`CHANNEL_KIND`＝lark/chatwork）／`morning-watchdog.yml`・`line-quota-watchdog.yml` | Lark group1〜3（Secrets `LARK_WEBHOOK_GROUP1〜3`）／監視 Webhook | 1-b（レポート）・2（監視） |
| **Mac mini**（ns-daily-import） | `lib/gas.js` の `notify()`（`NOTIFY_CHANNEL`＝email/lark/both）→ `sendLark()`（`.env` `LARK_WEBHOOK`） | Lark 経理 | 2 |
| **LINE**（nippo・EF） | `line-webhook`・`hr-*`・シフト催促など 22 種（通知一覧 §3） | 従業員・応募者・承認者 | 4（従業員）／対象外（応募者） |

---

## 2. 全体構成（移行後）

```
[送信元]                                   [唯一の出口]                       [Slack]
DB関数 notify_route_send(kind='slack') ─┐
他のEdge Function（cockpit等）        ─┤  x-notify-secret / service_role
Mac mini ns-daily-import notify()      ─┼──▶ notify-slack ──chat.postMessage──▶ #チャンネル / DM
GitHub Actions lark-report.mjs        ─┤       │  ▲
ポータル画面 tasks.html（ユーザーJWT）  ─┘       │  │ chat.update（✅修正済み 等）
                                               ▼  │
                               notification_deliveries（台帳: notification_id→channel_key→slack_channel_id→slack_ts→status）
                                                  ▲
[Slack のボタン/モーダル] ──署名付きPOST──▶ slack-interact ──署名検証→操作者特定(user_slack)→権限確認(既存RBAC)
                                                  └──▶ 既存 RPC / Edge Function（管理システムの正規の入口）──▶ DB更新＋監査ログ
```

- **秘密の置き場は 3 つだけ**: `notify-slack` の secret（Bot Token）／`slack-interact` の secret（Signing Secret）／内部合言葉 `NOTIFY_SLACK_SECRET`（送信元が `notify-slack` を呼ぶため。DB は `app_secrets.notify_slack_secret`、Mac mini は `.env`、GitHub は Secrets）。
- Hermes/Mirai の Slack 窓口は **別の Slack アプリ**（Hermes 同梱の Slack アダプタ）で載せる。通知 Bot と権限を分ける（通知 Bot は受信スコープを持たない）。

---

## 3. App Manifest と OAuth Scope

Manifest: [slack/app-manifest.yaml](slack/app-manifest.yaml)（貼り付けるだけで作れる）。

| Scope | 用途 | 使う Phase |
|---|---|---|
| `chat:write` | チャンネル・DM への送信、自分の送信の更新（`chat.update`） | 1 |
| `chat:write.public` | Bot 未参加の公開チャンネルにも送れる（招待し忘れで落ちない） | 1 |
| `chat:write.customize` | 送信ごとに表示名・アイコンを変える（「経営日報」「取込監視」の見分け） | 1 |
| `channels:read` / `groups:read` | 公開／非公開チャンネルの ID 確認（`slack_channels` 登録の補助） | 1 |
| `im:write` | 個人 DM を開く（`conversations.open`） | 3 |
| `users:read` / `users:read.email` | ワークスペースのユーザー一覧とメール → 従業員マスタと自動照合 | 3（Phase 1 で付けておく） |

- **Socket Mode: OFF**／**Event Subscriptions: なし**／**Interactivity: ON**（Request URL ＝ `https://uuvsxzhpxtghojoubjcc.supabase.co/functions/v1/slack-interact`）。Phase 1 の通知にはボタンを付けないため、`slack-interact` 未デプロイでも通知は動く。
- 発行されるのは **Bot User OAuth Token（xoxb-）1 本と Signing Secret 1 本**だけ。App Token（xapp-）は作らない。
- トークンの保存先: ユーザーの MacBook `~/.config/ns-portal/slack_bot_token`・`slack_signing_secret`（600）→ 司令塔が `supabase secrets set` で Edge Function へ投入。リポジトリ・設計書・チャットには書かない。

---

## 4. `notify-slack`（Slack 送信専用 Edge Function）仕様

ドラフト: `supabase/functions/notify-slack/index.ts`（未デプロイ）。

**認証**（いずれか）: A) `Authorization: Bearer <service_role>`　B) `x-notify-secret: <NOTIFY_SLACK_SECRET>`　C) ログインユーザー JWT（`users.role` が CEO/HQ か `is_master` のみ）。
**デプロイ**: `--no-verify-jwt`（B のため。JWT 検証は関数内）。

| action | 入力 | 動き | 返り |
|---|---|---|---|
| `send`（既定） | `channel_key`（必須）, `text` または `blocks`, `event`, `source`, `notification_id`（DB 由来は事前採番）, `dedupe_key`, `thread_ts`, `ref{table,id}`, `legacy{kind,sent}`, `username`, `icon_emoji` | ①`dedupe_key` が sent 済みなら再送しない ②台帳行を確保（queued）③`channel_key` → `slack_channels`／`user:<id>` → `user_slack`＋`conversations.open` ④`chat.postMessage`（`metadata.event_payload.notification_id` を埋める）⑤台帳を sent/failed に更新。本文 3,900 字超は先頭を本文・続きをスレッド返信。429 は Retry-After に従い最大 3 回 | `{ok, notification_id, slack_channel_id, ts, status}` |
| `update` | `notification_id`, `text`/`blocks` | 台帳の `slack_channel_id`＋`slack_ts` で `chat.update`。台帳を updated に | `{ok}` |
| `users_sync` | `dry_run` | `users.list` → メール（小文字）で `users.email` と照合 → `user_slack` upsert。未照合は両側の一覧（Slack 側メールはマスク）を返す。secret 認証では呼べない | 照合数・未照合 |
| `channels` | — | `slack_channels` 一覧（ID は set/未設定のみ） | 一覧 |
| `health` | — | Token 設定有無 | — |

**失敗時の扱い**: 宛先未登録・ID 未設定・Slack エラーはすべて台帳 `failed`＋`error` に残し、呼び出し元には 4xx/5xx を返す（呼び出し元は従来どおり自分のログに残す。DB 由来は pg_net 非同期のため台帳だけが結果の正）。
**再送**: 台帳の `failed` 行を `send` に `notification_id` 付きで投げ直せば同じ行で再試行（attempts 加算）。Phase 2 で「失敗 30 分後に 1 回だけ自動再送」の cron を検討。

---

## 5. channel_key 設計

- 形式: `^[a-z0-9][a-z0-9._-]{1,63}$`。`<領域>.<用途>[.<区分>]`。Slack のチャンネル名を変えてもキーは不変（Slack 側は channel_id で追従）。
- 個人 DM: `user:<users.id>`（Phase 3）。送信時に `user_slack` で Slack ID に解決。
- 解決順: `slack_channels.channel_key` → 無ければ `failed(unknown channel_key)`（黙って別チャンネルへ送らない）。

| channel_key | Slack チャンネル（表示名は変更可） | 置き換える旧宛先 | 流すもの |
|---|---|---|---|
| `keiei.report.g1` | `#経営-レポート-g1` | Lark group1（本店・はなれ・芝・新橋） | 経営D 日報/週報/月報 |
| `keiei.report.g2` | `#経営-レポート-g2` | Lark group2（恵比寿・鶏武者川崎・黒霧屋新横浜） | 同上 |
| `keiei.report.g3` | `#経営-レポート-g3` | Lark group3（鶏武者新横浜・鶏武者川崎・黒霧屋新横浜） | 同上 |
| `hq.keiri_kanshi` | `#本部-経理・監視` | Lark 経理（Mac mini `LARK_WEBHOOK`／`cockpit_lark_webhook`）・社長専用 `lark_webhook` の経理分 | 日次取込まとめ/失敗・売上突合差額・請求書/入金・AI 利用料・現金差異 |
| `hq.dev_system` | `#本部-開発・システム` | Lark 監視（`lark_webhook_url`／GitHub `LARK_WEBHOOK_URL`） | GitHub Actions/EF 失敗・コックピット・watchdog |
| `hq.jinji` | `#本部-人事・入社`（**4 つ目・要判断**） | Chatwork「入社通知」・`lark_routes` の入社/応募系 | 入社登録・応募・退職申請 |

> 入社・応募は経理監視と性質が違うため 4 つ目を推奨。3 つに収めるなら `hq.keiri_kanshi` に寄せる（`slack_channels` の 1 行を変えるだけ）。

---

## 6. 台帳 `notification_deliveries`（notification_id と message ts の保存）

SQL: `supabase/2026-10-29_slack_notify_phase1.sql` §2。

| 列 | 意味 |
|---|---|
| `id` = **notification_id** | 送信前に採番。Slack の `metadata.event_payload`、ボタンの `value`、モーダルの `private_metadata` に埋める → ボタン押下から元の通知と元レコードへ必ず戻れる |
| `source` / `event` | 送信元と種別（通知一覧の種別名を使う: `report_daily`・`join_registered`・`import_failed`・`attendance_alert`…） |
| `channel_key` → `slack_channel_id` → `slack_ts`（＋`thread_ts`） | 宛先の解決結果と送信結果。`chat.update`・スレッド返信・再送の鍵 |
| `delivery_status` | `queued`→`sent`／`failed`→（再送）／`updated`（ボタン操作後の差し替え）／`skipped` |
| `dedupe_key` | 二重送信防止（例 `report_daily:2026-10-29:keiei.report.g1`、`attendance_alert:<alert_id>`） |
| `ref_table` / `ref_id` | 元レコード（`hq_tasks`・`sf_attendance_*`・`invoices`…） |
| `legacy_kind` / `legacy_sent` | 並行運用の照合（同じ通知が Lark/Chatwork でも出たか） |
| `action_state` | ボタン操作の結果（誰が・いつ・何を） |

状態遷移: `queued → sent → updated*`／`queued → failed → (再送) sent`。台帳は削除しない（90 日経過分のアーカイブは Phase 2 以降で検討）。
DB 由来の通知は `notify_route_send` が先に `queued` 行を作って `notification_id` を渡す（pg_net は結果を返さないため）。

---

## 7. `kind=slack` 追加設計（設定テーブルと各送信元）

**Phase 1 の原則**: kind='slack' の行は **既存の「宛先列」に channel_key を入れる**。呼び出し側の関数を変えずに済み、旧行と新行を同じ表に並べて並行運用できる。

| 設定テーブル | kind='slack' のときの宛先列 | 変更 | 画面 |
|---|---|---|---|
| `lark_routes`（nippo イベント） | `webhook_url` ← channel_key | check 制約で形式だけ検証（`lark_routes_slack_target_chk`） | nippo「🔔通知を設定する」の種別に Slack を追加・ラベルを「チャンネルキー」に（担当 B） |
| `hq_notify_channels`（本部タスク共有） | `room_id` ← channel_key | kind 制約に `slack` を追加 | ns-portal tasks.html 通知設定に Slack 種別（ポータル担当） |
| `report_channels`（経営レポート） | `secret_name` ← channel_key | check 制約／`report_channel_matrix_v` に `channel_key` 列 | nippo 店舗管理→配信グループに Slack 種別（担当 A/B） |

| 送信元 | 変更内容 |
|---|---|
| `notify_route_send` | `p_kind='slack'` 分岐を追加（台帳 queued → pg_net で `notify-slack` を `x-notify-secret` 付きで呼ぶ）。lark/chatwork 分岐は現行と同一（スナップショットと diff で確認） |
| `hq_notify_step_event`／`hq_notify_comment`／`hq_notify_task_urgent`／`hq_check_alerts` | `c.kind in ('lark_webhook','chatwork')` → `+'slack'`。返り値の `channel_kind='slack'` を `tasks.html` 等が `notify-slack`（ユーザー JWT）へ送る |
| tori-dashboard `scripts/lark-report.mjs`＋`lark-report.yml` | `CHANNEL_KIND='slack'` のとき Webhook でなく `notify-slack` へ POST（Secrets `NOTIFY_SLACK_SECRET`、`channel_key`＝matrix の `channel_key`、`dedupe_key`＝`report_<kind>:<日付>:<channel_key>`） |
| ns-daily-import `lib/gas.js notify()` | `NOTIFY_CHANNEL` に `slack` を追加（`sendSlack()`: `.env` `NOTIFY_SLACK_SECRET`・`SLACK_CHANNEL_KEY`=hq.keiri_kanshi）。`both` は email+lark のまま、新たに `all`=email+lark+slack（並行期間用） |
| `_shared/cockpit.ts larkPost` | `slackPost(sb, channel_key, text)` を追加し、並行期間は両方呼ぶ |

---

## 8. DM 送信設計（Phase 3）

- 宛先 `user:<users.id>`。`notify-slack` が `user_slack` → `conversations.open` → DM チャンネル ID（D…）を解決し、台帳に `slack_user_id` も残す。
- 既存の個人ルーム設定（`hq_user_chatwork`・`hq_user_notify_routes`）は **そのまま**。`hq_personal_chatwork_room_for_event` の返り値に対応する Slack 側は「`user_slack` に紐付けがあれば DM」とし、関数の返り方を `(kind, target)` の組に拡張する（Phase 3 の SQL）。
- 未紐付けの人は従来の Chatwork 個人ルームへ（欠落させない）。紐付け完了者から順に Slack DM に切替え、2 週間並行。
- 本人宛て（Phase 4）は LINE のまま。将来 Slack へ移す場合も同じ `user:<id>` キーで送れる。

---

## 9. ユーザー自動照合設計（`user_slack`）

1. `notify-slack users_sync dry_run=true` で照合結果を確認（照合数・未照合の管理システム側の名前・未照合の Slack 側メール（マスク））。
2. 問題なければ `dry_run=false` で `user_slack` に書く（`matched_by='email'`）。
3. メールが違う人（Slack 招待を別メールで受けた等）は、nippo 従業員編集に「Slack ユーザー ID」欄を Phase 3 で追加し手入力（`matched_by='manual'`）。
4. 退職時: `users.is_active=false` になった人は DM 送信対象から外れる（`notify-slack` が `is_active` を見る）。Slack 側のアカウント停止はユーザー運用。
5. 週 1 回の `users_sync` を GitHub Actions で回し、新規入社者（Slack 招待後）を自動で拾う。

---

## 10. アクション付き通知（Interactivity）設計

### 10-1. 鉄則
- Slack から DB を直接更新しない。**Slack interaction → `slack-interact` → 署名検証 → 操作者特定（`user_slack`）→ 権限確認（既存 RBAC）→ 既存 RPC / Edge Function → DB 更新 → 監査ログ → 元メッセージ更新（`notify-slack update`）**。
- `slack-interact` は受付と振り分けだけ。業務ロジックと権限判定は既存の RPC（`security definer`）側に置く＝画面から操作したときと同じ入口・同じ監査。
- 3 秒以内に 200 を返す。モーダルは `trigger_id` の失効前（3 秒）に先に開く。重い処理は RPC 側で行い、結果はメッセージ更新で知らせる。

### 10-2. 署名検証
- ヘッダ `X-Slack-Request-Timestamp`・`X-Slack-Signature`。`v0=` + HMAC-SHA256(Signing Secret, `v0:<timestamp>:<rawBody>`)。タイムスタンプ 5 分超は拒否（リプレイ防止）。定数時間比較。
- `slack-interact` は `--no-verify-jwt`（Slack は JWT を付けない）。署名検証がこの関数の唯一の認証。Signing Secret は関数 secret `SLACK_SIGNING_SECRET`。
- 実装済み（骨組み）: `supabase/functions/slack-interact/index.ts` `verifySlackSignature`。

### 10-3. action_id / callback_id の規約
`<領域>.<対象>.<操作>`（英小文字・ドット区切り）。ボタンの `value` は JSON 文字列 `{"notification_id":…, "<対象>_id":…, 表示用の最小情報}`（2,000 字以内・秘密情報なし）。

| action_id / callback_id | 種類 | 動き |
|---|---|---|
| `attendance.alert.confirm` | button | 勤怠アラート「合っている」→ RPC `sf_attendance_alert_confirm` |
| `attendance.alert.fix` | button | 「修正する」→ モーダル `attendance.fix.modal` |
| `attendance.alert.open` | button(url) | 「詳細を見る」→ 管理システムの勤怠詳細 URL（サーバー処理なし） |
| `attendance.fix.modal` | view_submission | 修正の送信 → 既存の勤怠修正入口 |
| `invoice.approval.approve` / `.fix` / `.hold` | button | 請求書（将来）→ 既存の承認 RPC |
| `cash.diff.confirm` / `.fix` | button | 現金差異（将来） |
| `shift.missing.remind` / `.extend` | button | シフト未提出（将来） |
| `hqtask.item.done` / `.extend` | button | 本部タスク（将来）→ `hq_*` RPC |

### 10-4. Block Kit テンプレ（勤怠アラート）
```
⚠️ 勤怠アラート
Aさん（<店舗名>）  2026-10-28
予定 17:00〜23:00　実績 17:00〜17:05　勤務 5分
[合っている] [修正する] [詳細を見る]
```
- `blocks`: `header`（⚠️ 勤怠アラート）／`section`（mrkdwn: 名前・店舗・日付・予定/実績/勤務）／`actions`（3 ボタン。`confirm` は style=primary、`fix` は既定、`open` は url）／`context`（notification_id の短縮・送信時刻）。
- 送信側（Phase 4 の勤怠アラート EF）は `notify-slack send` に `event='attendance_alert'`・`dedupe_key='attendance_alert:<alert_id>'`・`ref={sf_attendance_alerts, <alert_id>}`・`blocks` を渡す。宛先は Phase 3 までは `hq.keiri_kanshi`／店長 DM（`user:<店長 id>`）、Phase 4 で本人 DM。

### 10-5. 勤怠アラートのフロー
**「合っている」**
1. `slack-interact` が署名検証 → `user_slack` で操作者を特定（未紐付けは ephemeral で案内）。
2. RPC `sf_attendance_alert_confirm(p_alert_id, p_actor, p_via='slack')`（新設・Phase 3）: 権限確認（本人／`sf_can_manage(store_id)`／本部）→ アラートを `confirmed`・`confirmed_by`・`confirmed_at` に更新 → 監査ログ。
3. `notify-slack update` で元メッセージを「✅ 確認済み（氏名・時刻）」に差し替え（ボタンを消す）。台帳 `action_state` に記録。

**「修正する」**
1. 先にモーダル `attendance.fix.modal`（`views.open`）: 入力＝正しい出勤時刻（timepicker）・正しい退勤時刻（timepicker）・修正理由（必須・300 字）。`private_metadata`＝`{alert_id, notification_id}`。
2. 送信 → RPC `sf_attendance_fix_from_slack(p_alert_id, p_actor, p_start, p_end, p_reason)`（新設・Phase 3。中身は **既存の勤怠修正入口を呼ぶだけ**: 本人は `sf_attendance_correction_requests` に申請を積む／店長・本部は修正を確定し `smaregi-attendance-sync` へ同期依頼）。
3. RPC が返す `applied`（確定したか／申請止まりか）で元メッセージを「✅ 修正済み（氏名・新時刻）」または「📝 修正申請を受け付けました」に更新。
4. 監査ログ: 修正者・修正前・修正後・理由・修正日時・同期結果（既存の監査テーブルがあればそこへ、無ければ `sf_attendance_audit` を Phase 3 で新設）。
5. 入力エラーは `response_action: errors` でモーダル内に表示（DB には何も書かない）。

**「詳細を見る」**: URL ボタン。`https://mirai-oss.github.io/nippo/#attendance?alert=<alert_id>`（実 URL は Phase 3 で確定。ログイン必須のページなので未ログインでも情報は漏れない）。

### 10-6. RBAC（既存に従う）
| 操作者 | 合っている | 修正する | 備考 |
|---|---|---|---|
| 本人（SHAIN/AL） | 可（自分の分のみ） | **修正申請のみ**（`sf_attendance_correction_requests` pending） | 既存の申請フローと同じ |
| 店長（TENCHO）・チーム（TEAM） | 自店舗スタッフ | 自店舗スタッフを修正可 | `sf_can_manage(store_id)` |
| 本部（HQ/CEO/master） | 全店舗 | 全店舗修正可 | |
| 未紐付け・退職者 | 不可 | 不可 | ephemeral で案内 |
判定は RPC 内で `auth.uid()` の代わりに `p_actor` を使う（`security definer`・service_role からの呼び出し）。`slack-interact` 側では判定しない（二重管理にしない）。

### 10-7. メッセージ更新とスレッド
- 操作後は `chat.update` で**同じメッセージ**を差し替え（ボタン除去・結果表示）。履歴が必要なら同スレッドに「誰が・いつ」を返信。
- 同じ通知を複数人が同時に操作 → RPC 側で状態チェック（既に confirmed なら「◯◯さんが先に確認済みです」を ephemeral で返し、メッセージは更新しない）。

---

## 11. 既存 Chatwork / Lark との並行運用と停止基準

1. **追加で送る**: 各設定表に kind='slack' の行を**追加**（既存行は触らない）。Mac mini は `NOTIFY_CHANNEL=all`、cockpit は両方呼ぶ。
2. **突合**: 毎日、台帳 `notification_deliveries`（event × 日 × channel_key の件数・failed 件数）と旧側（`lark_log`／GitHub Actions 実行履歴／Mac mini `logs/`）を比べる。確認クエリ（例）:
   ```sql
   select event, channel_key, delivery_status, count(*) from notification_deliveries
    where created_at >= now() - interval '14 days' group by 1,2,3 order by 1,2,3;
   select date_trunc('day', created_at) d, count(*) from lark_log where ok and created_at >= now() - interval '14 days' group by 1 order by 1;
   ```
3. **停止基準**: 通知ごとに **連続 14 日間、Slack 側 failed=0 かつ旧側と件数一致**を確認してから、その通知の旧行を `is_active=false`（削除しない・30 日は戻せる）。Mac mini は `NOTIFY_CHANNEL=slack`、cockpit は `larkPost` 呼び出しを外す。
4. 従業員向け LINE・応募者向け LINE は Phase 4 の判断まで一切変更しない。

---

## 12. 秘密情報の置き場（書いてよい場所・いけない場所）

| 値 | 置き場 | 入れ方 |
|---|---|---|
| Bot Token（xoxb-） | Edge Function secret `SLACK_BOT_TOKEN`（`notify-slack`・`slack-interact` の `views.open` 用） | ユーザーが `~/.config/ns-portal/slack_bot_token` に保存 → 司令塔が `supabase secrets set` |
| Signing Secret | Edge Function secret `SLACK_SIGNING_SECRET` | 同上（`slack_signing_secret`） |
| 内部合言葉 `NOTIFY_SLACK_SECRET` | Edge Function secret／`app_secrets.notify_slack_secret`／Mac mini `.env`／GitHub Secrets（tori-dashboard） | 司令塔が `openssl rand -hex 32` で生成し 4 か所に同じ値 |
| チャンネル ID（C…） | `slack_channels.slack_channel_id` | 秘密ではない（チャットで共有可） |
| **禁止** | リポジトリ（public）・設計書・WORKLOG・チャット本文・Hermes の config | — |

---

## 13. 要件定義の方針書き換え

要件定義書 §28（2026-10-29 追記）:
- 旧「通知は Chatwork に寄せる」は**廃止**。新方針「**入社後の業務通知・業務連絡は Slack へ統一する。入社前（応募者）は LINE。**」
- 通知の正本は管理システム（Slack は入口）。Slack 送信は `notify-slack` 1 本・Bot 1 つ・`notification_id` 必須。
- 移行期間中は Chatwork / Lark / LINE を即時停止せず、通知ごとに移行完了確認（§11）後に停止。

---

## 14. 本番復元（完了）と変更時の手順

| 対象 | 復元結果 | 変更時 |
|---|---|---|
| DB 関数 `notify_route_send` ほか通知関連 22 関数 | `supabase/restored/2026-10-29_notify_functions_prod_snapshot.sql`（`pg_get_functiondef` で取得・無改変。適用用ではない） | 新規 SQL（`2026-10-29_slack_notify_phase1.sql` §6）の lark/chatwork 分岐をスナップショットと `diff` し同一を確認 → ユーザー承認 → SQL Editor で適用 → `pg_get_functiondef` で再確認 |
| Edge Function `notify-chatwork` | `supabase/functions/notify-chatwork/index.ts`（本番 v13 を `supabase functions download` で取得・ヘッダ注記のみ追加） | Slack 移行では変更しない。並行運用が終わるまで残す。万一変更するときは同ファイルを基点に diff → `--no-verify-jwt を付けずに` デプロイ（現行 verify_jwt=true） |
| `smaregi-sync` の `notify_chatwork` アクション | リポジトリ管理済み（`supabase/functions/smaregi-sync/index.ts`） | 変更不要 |

復元コマンド（再現用）:
```bash
SUPABASE_ACCESS_TOKEN=$(cat ~/.config/ns-portal/supabase_pat) npx -y supabase@latest functions download notify-chatwork --project-ref uuvsxzhpxtghojoubjcc
```
```sql
select pg_get_functiondef('public.notify_route_send(text,text,text)'::regprocedure);
```

---

## 15. フェーズ計画と TK（WORKLOG 📋 (1c)）

| Phase | 内容 | TK |
|---|---|---|
| 0 準備 | Slack アプリ作成・Token 保存・チャンネル作成（ユーザー）／secrets 投入・`slack_channels` 登録・SQL 適用・`notify-slack` デプロイ・疎通 | TK-240〜243 |
| 1 設定で移せる通知 | 1-a nippo 系（`lark_routes`）／1-b 経営レポート（`report_channels`＋GitHub Actions）／1-c 本部タスク共有（`hq_*`＋tasks.html） | TK-244〜246 |
| 1 並行確認 | 14 日並行・突合・旧停止 | TK-247 |
| 2 監視系 | Mac mini `notify()`・cockpit `larkPost`・GitHub watchdog・API/会計エラー | TK-248 |
| 3 個人 DM＋アクション | `user_slack` 自動照合・DM・`slack-interact` 本実装・勤怠アラート 3 ボタン・RPC 新設 | TK-249・250 |
| 4 従業員向け | 勤怠・シフト・急募・店舗業務の LINE→Slack（費用と Phase 1〜3 の結果で判断） | TK-251 |

---

## 16. ユーザーに決めてもらうこと・やってもらうこと

1. **Slack ワークスペース**の有無（無ければ作成）とプラン（無料は履歴 90 日・有料は人数課金。Phase 4 の判断材料）。
2. **アプリ作成とトークン保存**: [手順書](手順書_Slackアプリ作成とトークン保存_2026-10-29.md) のとおり。
3. **チャンネル作成**: `#経営-レポート-g1/g2/g3`・`#本部-経理・監視`・`#本部-開発・システム`（＋推奨 `#本部-人事・入社`）。各チャンネルに Bot を招待し、チャンネル ID をチャットで送る（秘密ではない）。
4. 判断: 入社・応募通知の行き先（4 つ目のチャンネルを作るか、経理・監視に寄せるか）。
5. 判断: 経営レポート 3 チャンネルの参加者（閲覧対象が違う前提なので、それぞれ誰を入れるか）。
