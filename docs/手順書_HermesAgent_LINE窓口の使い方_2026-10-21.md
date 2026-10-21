# 手順書: Hermes Agent（AI窓口）の現状と使い方

作成: 2026-10-21 ／ 対象: 社長・本部 ／ 実機確認済み（Mac mini `mirainoMac-mini`）
前提資料: [手順書_D-8_HermesAgent試用_2026-08-31.md](手順書_D-8_HermesAgent試用_2026-08-31.md)（セットアップ手順）、要件定義書 §18（AIエージェント方針）

---

## 1. 今どうなっているか（2026-10-21 実機確認）

| 項目 | 状態 |
|---|---|
| 連携 | **接続済み・稼働中**。LINE公式アカウント「NStyle AI窓口」に話しかけると Mac mini 上の Hermes Agent が答える |
| 常駐 | Mac mini の launchd（`com.nstyle.hermes-line`）で常時起動。落ちても30秒で自動再起動 |
| 外部公開 | Cloudflare の無料トンネル。URLは再起動のたびに変わるが、起動スクリプトが LINE 側の Webhook URL を自動で更新する（今日 09:53 の再起動でも試行2回目で成功を確認） |
| 話せる人 | LINE_ALLOWED_USERS に登録した **1名（社長）のみ**。他の人が話しかけても無視される |
| AIモデル | Anthropic Claude Sonnet 5（API キー「hermes-line」・月上限 $30 の専用ワークスペース） |
| 社内データ接続 | Phase C-1 完了。読み取り専用の API（`ai-gateway`）経由で 7 種類の照会ができる（§3）。書き込みは一切できない |
| 監査ログ | 社内データへの照会はすべて `ai_audit_logs` に記録（8月11回・10月1回、失敗0件） |
| 利用実績 | 8月31日の試用以降ほぼ使われていない（10月は接続確認の1回のみ） |
| バージョン | v0.20.6（2026-08-27版）。本家は大幅に先へ進んでいるが、**安易に更新しない**（§7） |

接続テスト（本日）: CLIから「接続テスト成功」の応答あり。LINE Webhook は署名なしPOSTを 401 で拒否（正常）。

---

## 2. 日常の使い方（LINE）

1. LINE で「NStyle AI窓口」のトークを開く。
2. 聞きたいことを普通の日本語で送る。社内データが要る質問は自動で API を叩いて実データで答える。

**聞き方の例**

| 聞きたいこと | 送る文の例 |
|---|---|
| 今月の売上と前年比 | 「今月の売上は？」「前年比は？」 |
| 店舗別 | 「恵比寿の今月の売上」「店舗別に今月の売上を出して」 |
| 月次推移 | 「直近1年の月別売上を教えて」 |
| 日報 | 「今日の日報の未提出者は？」「10/20 の日報提出状況」 |
| チェックシート | 「今日のチェックシートの実施状況」「未解決のアラートある？」 |
| 本部タスク | 「本部タスクの期限超過は？」「今日期限のタスク」 |
| お知らせ | 「最新のお知らせを教えて」 |
| 経費申請 | 「承認待ちの経費申請は？」「今月の経費承認額」 |
| 店舗一覧 | 「店舗番号と店舗名の一覧」 |

**便利なコマンド（メッセージとして送る）**

| コマンド | 意味 |
|---|---|
| `/new` または `/reset` | 会話をリセットして新しい話題を始める（前の文脈を引きずるときに） |
| `/stop` | 実行中の処理を止める |
| `/help` | コマンド一覧 |

**答えられないもの（仕様）**: 給与・口座・契約書・ID/PW など機密情報、データの登録・変更・削除、API に無い数字。「その情報へのアクセス権はありません」と返るのが正常です。

---

## 3. 取得できる社内データ（読み取り専用 API のカタログ）

| 照会キー | 内容 |
|---|---|
| `sales_summary` | 今月累計・前年同期間比・24ヶ月の月次推移・店舗別今月（店舗指定可） |
| `nippo_status` | 日報の提出者／未提出者（日付指定可） |
| `checklist_status` | 店舗チェックシートの実施状況・未解決アラート |
| `tasks_status` | 本部タスク: 未完了件数・期限超過・今日期限（公開タスクのみ） |
| `posts_latest` | 社内お知らせ 最新5件 |
| `expenses_status` | 経費申請: 承認待ち一覧・今月の承認済み合計 |
| `store_directory` | 店舗マスタ（店舗番号・名前・看板） |

実体: Supabase Edge Function `ai-gateway`（トークン認証・service_role は渡していない・RPC `ai_sales_summary` で集計）。Hermes 側はスキル `~/.hermes/skills/nstyle/nstyle-data/`（`SKILL.md` ＋ `scripts/query.sh`）。

**手元で直接叩いて確認したいとき**（Mac mini のターミナル）

```bash
~/.hermes/skills/nstyle/nstyle-data/scripts/query.sh sales_summary '{"store":"恵比寿"}'
```

---

## 4. 動いているか確認する・止まったときの対処（Mac mini）

**生存確認（3行）**

```bash
launchctl list | grep hermes-line          # 2列目が 0 以外なら異常終了中
tail -5 ~/.hermes/logs/line-stack.log       # 最新の起動で「LINE webhook更新: HTTP 200」が出ていればOK
~/.local/bin/hermes -z "接続テストと返して"  # AIモデルへの疎通
```

**症状別**

| 症状 | 原因の目安 | 対処 |
|---|---|---|
| LINE で返事が来ない | トンネル or ゲートウェイ停止 | `launchctl kickstart -k gui/$(id -u)/com.nstyle.hermes-line` で再起動（30〜60秒で復帰・Webhook も自動更新） |
| 「Provider authentication failed」 | API キー切れ／上限超過 | Anthropic Console のワークスペース「NStyle-AI-Madoguchi」で利用額と鍵を確認。差し替えは `~/.hermes/.env` の `ANTHROPIC_API_KEY` |
| 返事はあるが数字が「取れません」 | ai-gateway 側 | `query.sh store_directory` で API 単体を確認。`ai_audit_logs` の `ok=false` 行にエラー内容が入る |
| 「次の配信までお待ちください」が一緒に届く | LINE 公式アカウントの自動応答が ON | LINE Official Account Manager → 応答設定 → 応答メッセージ OFF |
| 同じ質問に前の文脈で変な答え | 会話が長い | `/new` を送る |

**ログの場所**: `~/.hermes/logs/line-stack.log`（起動・Webhook登録）／`~/.hermes/logs/cloudflared.log`（トンネル）／`~/.hermes/logs/gui.log`（デスクトップアプリ）

---

## 5. 使える人を増やす

1. 追加したい人に LINE 公式アカウントへ何か1通送ってもらう。
2. Mac mini で `~/.hermes/logs/` のゲートウェイログ、または LINE Developers の Webhook ログから `U` で始まるユーザーIDを確認。
3. `~/.hermes/.env` の `LINE_ALLOWED_USERS=` にカンマ区切りで追記。
4. `launchctl kickstart -k gui/$(id -u)/com.nstyle.hermes-line` で再起動。

※ 全員が同じ権限（マスター相当の読み取り）になる点に注意。役職ごとに見せる範囲を変える仕組みは未実装（Phase 2 以降）。本部以外に開放する前に要検討。

---

## 6. 照会の種類を増やす（開発者向け）

1. `ns-portal/supabase/functions/ai-gateway/index.ts` の `CATALOG` に関数を追加（1,000行上限の罠があるので集計は RPC 側で行う）。
2. 必要なら `ns-portal/supabase/` に日付入り SQL で RPC を追加（`security definer`・anon/authenticated から revoke）。
3. ユーザー確認のうえデプロイ。
4. `~/.hermes/skills/nstyle/nstyle-data/SKILL.md` の表に照会キーと使い方を追記（Hermes はこの表を読んで使い方を判断する）。
5. LINE から実際に聞いて動作確認。`ai_audit_logs` に記録されることを確認。

書き込み系（タスク作成・承認など）は要件定義 §18 の Phase 2 以降。**現時点では追加しない**。

---

## 7. 触るときの注意

- **`hermes update` を安易に実行しない**。本家は数万コミット先に進んでおり、設定ファイル・LINE アダプタ・スキルの互換性が切れる可能性が高い。更新するなら別途検証日を設けて、`~/.hermes/` をまるごとバックアップしてから。
- **Hermes デスクトップアプリを開くと `config.yaml` のモデル設定が上書きされることがある**（過去に `claude-fable-5` / `opus-4.6` に変わった実績）。開いたあとは `model.default` が `claude-sonnet-5` のままか確認。今日時点は正常。
- デスクトップアプリの起動で LINE 窓口が再起動されることがある（今日 09:53 に発生）。自動復帰するので放置でよいが、1〜2分は LINE が無応答になる。
- `.env` と API キーはリポジトリに入れない（Mac mini ローカルのみ）。
- Cloudflare の無料トンネルは URL が毎回変わる前提の作り。固定 URL が必要になったら Cloudflare Tunnel の名前付きトンネル（無料・要 Cloudflare アカウント）へ移行する。

---

## 8. これからの判断材料

- **利用実績がほぼ無い**（8/31 以降で実質1回）。「LINE で数字を聞く」用途が定着するか、ポータルのホームで足りているかを見て、継続か停止かを決める時期。
- 継続するなら候補: ①本部メンバーへの開放（§5・権限の線引きが先）②Chatwork 窓口の追加（通知は Chatwork に寄せる方針のため）③Phase 2（下書き作成・タスク起票などの実行系。要件定義 §18 の承認フローが前提）。
- 停止するなら: `launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.nstyle.hermes-line.plist` で止め、Anthropic の API キー「hermes-line」を無効化。データ側（ai-gateway・RPC・監査ログ）はそのまま残して問題ない。
