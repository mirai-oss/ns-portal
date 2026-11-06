# 設計書: Google口コミ取得の Supabase 直結化（2026-11-06）

対象: 鳥一代グループ 8 店（12 Google掲載）。N-Style 4 店は今回対象外（マスタに行を足せば翌日から取得される構造にしてある）。
ユーザー決定（2026-11-06）: ②並行期間は比較専用テーブルで分離 ④スケジュールは Supabase Cron ⑧N-Style は対象外 ＋ 掲載名をキーにせず自社発行 `listing_id` → `place_id` を固定キーにする。

## 1. 現状と最終形

```
現状: Places API → 売上DB GAS(fetchGoogleReviews) → 口コミ推移ログ → ミラー → keiei-kd-refresh → kd_google_review_* → 日報/ダッシュボード
最終: Places API → Edge Function google-reviews-fetch（毎朝 08:00 JST・pg_cron）→ google_review_snapshots → 集計関数/View → 日報画像・経営ダッシュボード・AI窓口
```

現行 GAS（売上DB `コード.gs` 1980 行〜）の事実: `口コミPlaceID` の B 列が `ChIJ…` なら Place Details、URL なら店名で Text Search し **1 件目を無条件採用**、その他の文字列はその語で Text Search。取得は毎月 1/8/15/22/29 の 9 時台。Place ID はどこにも保存されていない。

## 2. テーブル（`supabase/2026-11-06_google_reviews_direct.sql`）

| もの | 役割 | キー |
|---|---|---|
| `google_place_listings`（新） | Google掲載マスタ。店舗 1:N。`status` = pending / active / needs_review / inactive / invalid | `id`(listing_id) / `place_id` unique / (store_id, listing_name) unique |
| `google_review_snapshots`（新） | 毎日の生の履歴（累計件数・平均星）。増加数は保存しない | (listing_id, fetched_on) unique。`as_of_date` = fetched_on − 1 |
| `google_review_fetch_runs`（新） | 実行記録（対象数・成功/失敗・API 呼出・Text Search 回数・Place Details 回数） | id |
| `kd_google_review_listings`（既存） | **比較専用**に降格。旧シート取込（keiei-kd-refresh op=reviews）は引き続きここにだけ書く | (store_id, listing_name, fetched_on) |
| `kd_google_review_snapshots`（既存） | 旧の店舗合計。参照しなくなる（削除は別タスク） | (store_id, fetched_on) |

- RLS: 3 表とも `authenticated` は select のみ。書き込みは service_role（Edge Function）だけ。
- seed: 既存 `kd_google_review_listings` の（店舗×掲載名）12 件をマスタへ（`status='pending'`・`display_name` は `store_aliases.display_name`・主看板＝店舗名と同じ掲載）。住所照合の手がかり `address_hint`（新横浜→横浜市／川崎→川崎市／恵比寿→渋谷区／新橋・芝→港区。本店・はなれは不明＝省略）。
- 履歴の一回限りの引き継ぎ: 旧鏡 240 行 → `google_review_snapshots`（`source='legacy_sheet'`）。これで月初の起点（11/1 取得＝10/31 時点）がそろい、移行初日から今月増加が出る。以後、旧系統は新正本に一切書かない。

## 3. 集計の定義（`google_review_store_kpi(店舗, 日付)`）

- **基準日 = 取得日 − 1**（朝 8 時の取得は「前日までの実績」。経営ダッシュボード app.js と同じ扱い）。
- 店舗合計 = 各看板の「基準日以前の最新」累計の合算。星は件数加重平均。
- 今月増加 = 合計(基準日以前の最新) − 合計(月初より前の最新)。**11/1 取得分は 10 月末の起点**になり当月に加算しない（指示書 §19）。起点が無い看板は除外、1 つも無ければ null（画像は「—」）。
- 今週増加 = 週は週報と同じ「火曜〜翌月曜」。起点は週開始日より前の最新。
- 今日増加 = 基準日の値 − 前日の値（両方そろう看板だけ）。日報画像には出さない（データとして持つだけ）。
- **マイナスはそのまま**（`greatest(0,…)` 廃止。削除で減った事実を保持）。表示側で丸めたい場合は画像側で判断。
- 旧テーブルにしか無い店舗は `kd_google_review_listings` を同じ式で扱う（フォールバック）。
- View: `google_review_store_daily_v`（店舗×基準日の合計）／`google_review_kpi_v`（今日時点の店舗別 KPI。ダッシュボード・AI窓口向け）／`google_review_legacy_compare_v`（旧新比較。同じ掲載・同じ取得日の件数差・星差・Google名称）。
- `daily_report_card_vm` v5: 口コミ部分だけ上の関数に置換。既存キーはそのまま（`google_review_total` / `avg_star` / `updated_at` / `month_increase` / `listings[]` / `listing_count` / `mtd_review_count`）＋ `week_increase` / `day_increase` / `as_of_date` を追加。**画像スクリプト（tori-dashboard `daily-report-card.mjs`）は変更不要**。

検算（本番データ・ロールバック付きで実行、2026-11-05 基準）: 黒霧屋 新横浜 = 黒霧屋 274 + うお蔵 649 + 彩 41 = 964・★4.60、鶏武者 新横浜 = 1147 + 1254 = 2,401、本店 2,352。今月増加は全店 0（11/1 取得が 10 月末の起点になるため。次の取得で動き出す）。v4 では 10/29→11/1 の増分（黒霧屋 +13）が 11 月に乗っていた。これは定義変更による差で、新定義が指示書どおり。

## 4. Edge Function `google-reviews-fetch`

| op | 用途 | Google API |
|---|---|---|
| `fetch`（既定） | 毎日。`status='active'` かつ place_id ありの掲載を Place Details（FieldMask `id,displayName,rating,userRatingCount`）で取得 → snapshots upsert | Details × 掲載数。Text Search 0 |
| `resolve` | 初期移行・新規追加時だけ。pending / needs_review の掲載を Text Search（`places.id,displayName,formattedAddress`・最大 5 件）→ 照合 → Details で件数確認 | Search 1 + Details 1 /掲載 |
| `confirm` | 人間が候補から選んだ place_id を確定（Details で実在確認してから保存） | Details 1 |
| `health` | status 別件数・直近の実行・最終取得日・キー設定有無 | なし |

- 認証: `x-notify-secret`（NOTIFY_SLACK_SECRET）か `Bearer <service_role>`。それ以外は 401。デプロイは `--no-verify-jwt`。
- `resolve` の自動確定条件（全部満たすときだけ active）: 候補のうち「名前に看板の語（display_name か掲載名の先頭語）を含み、住所に address_hint を含む」ものが **1 件だけ** → その Place Details の件数が旧履歴の最新と ±max(5, 3%) 以内・星 ±0.3 以内 → 同じ place_id が他の掲載で未使用。1 つでも外れたら `needs_review`（候補を `candidates` に保存、理由を `review_note`）。1 件目の無条件採用はしない。
- 失敗: 429/5xx/通信エラーは 1s→3s→9s で最大 3 回。404 は `status='invalid'`（再試行しない）。1 件でも失敗したら `#本部-開発システム` へ通知。前回値は残る（日報は「最終取得 M/D」表示。VM は最新の取得日を返す）。名称変更は取得正常のまま通知のみ。
- API キー: secrets `GOOGLE_PLACES_API_KEY`。レスポンス・ログ・DB・SQL・GitHub に出さない（エラー本文は 300 字で切り `key=` を伏せる）。
- コスト: 正常時 1 日 = Place Details 12 回・Text Search 0 回。`google_review_fetch_runs` で日次確認。Text Search が連日 > 0 なら設定異常。

## 5. スケジュール（`supabase/2026-11-06_google_reviews_cron.sql`）

- pg_cron ジョブ `google-reviews-daily`: `0 23 * * *`（UTC）= **毎朝 08:00 JST**。`google_reviews_fetch_trigger()`（security definer）が pg_net で EF を呼ぶ。合言葉は既存 `app_secrets.notify_slack_secret`。
- 依存関係: 経営ダッシュボード朝反映 08:45・日報画像 12:00・keiei-kd-refresh 12:00 より前。12 掲載で約 10 秒。
- Mac mini・GitHub Actions に依存しない。止めるときは `select cron.unschedule('google-reviews-daily')`。

## 6. 並行稼働と停止条件

- 14 日間（2026-11-07〜11-20 目安）: 新 EF は毎日、旧 GAS は 11/8・11/15 に取得。`google_review_legacy_compare_v` で同じ取得日の **Google名称・累計・星・店舗合計** を比較（2〜3 点）。
- 停止条件: 7 日以上安定・取得漏れ 0・Place ID 誤紐付け 0・日報とダッシュボードの表示正常・複数掲載店舗の合計一致。
- 停止作業（別途ユーザー承認）: 売上DB GAS で `removeReviewTrigger` を実行（口コミ取得トリガだけ解除。コードは残す）。keiei-kd-refresh の op=reviews はダイニー取込を兼ねるので残す（Google 部分は新規行が来なくなるだけ）。シート 3 枚は読み取り専用で残す。

## 7. 経営ダッシュボード（Step 13・別コミット）

ダッシュボードは全データを GAS 経由で読み、口コミタブはシート `口コミ`（推移ログのミラー）を `ingestReview` で取り込んでいる。移行は「GAS の data(review) が Supabase の `google_review_snapshots` を同じ 8 列の形で返す」方式（店舗マスタ `storeDirectory` と同じ経路）。app.js 側は無変更で済む見込み。日報直読（§3）が安定してから着手。

## 8. テスト計画（指示書 §45）

| ケース | 方法 |
|---|---|
| A 1 掲載店舗 / B 複数掲載 | 本店・黒霧屋 新横浜・鶏武者 新横浜で `fetch` → VM v5 → 画像を `#本部-開発システム` へ |
| C Place ID 未登録 | pending の掲載は fetch 対象外（health で件数確認） |
| D 無効 Place ID | 使い捨ての掲載行に偽 ID を入れて fetch → invalid＋通知 → 行を削除して 0 件確認 |
| E 一時エラー | 再試行ロジックは単体で確認（429/5xx を retryable と判定） |
| F 同日再実行 | 2 回 fetch → snapshots の行数が増えないこと |
| G/H 月跨ぎ・週跨ぎ | `google_review_store_kpi` を 10/31・11/1・11/3(月)・11/4(火) で呼び起点が切り替わること |
| I/J 増減 | legacy 行を使った検算で増加／減少（マイナス保持）を確認 |

## 9. ユーザー作業（この順番で）

1. **API キーを Supabase の secrets へ**（Apps Script → プロジェクトの設定 → スクリプト プロパティ → `PLACES_API_KEY` の値）。履歴に残さないためファイル経由で:
   ```bash
   printf 'GOOGLE_PLACES_API_KEY=ここに貼る\n' > ~/.config/ns-portal/google_places.env && chmod 600 ~/.config/ns-portal/google_places.env
   ```
   ```bash
   npx supabase secrets set --env-file ~/.config/ns-portal/google_places.env --project-ref uuvsxzhpxtghojoubjcc
   ```
2. **キーの制限を確認**（Google Cloud コンソール → APIとサービス → 認証情報 → そのキー → 「API の制限」が「Places API (New)」だけになっているか。なっていなければ「キーを制限」→ Places API (New) のみ）。結果を一言教えてください。
3. **SQL ①を適用**: `python3 scripts/apply_sql.py supabase/2026-11-06_google_reviews_direct.sql`
4. **EF をデプロイ**: `npx supabase functions deploy google-reviews-fetch --project-ref uuvsxzhpxtghojoubjcc --no-verify-jwt --yes`
5. → 私が `resolve --dry-run` → `resolve` を実行し、自動確定できた掲載と人間確認が必要な掲載の一覧を出します。確認が必要なものは候補（名前・住所）を見て選んでもらい `confirm` で確定。
6. → 私が初回 `fetch` → 日報画像 3 店をテスト送信 → OK なら **SQL ②（Cron）を適用**: `python3 scripts/apply_sql.py supabase/2026-11-06_google_reviews_cron.sql`（pg_cron の有効化もこの SQL が行う。管理画面での操作は不要。ジョブは Supabase 管理画面 → Integrations → Cron で見える）
7. 14 日並行 → 比較結果を報告 → 旧 GAS トリガ停止を判断。
