# 実装指示書: Day6 店舗マスタ1箇所化 ②経営D GASのSupabase直読み ③配信matrix自動生成（＋Chatwork対応）

作成: 2026-08-22 ／ 元資料: `docs/引継ぎ書_2026-08-22_Day6店舗マスタ1箇所化続き.md`（論点5つ）／仕様の正: `docs/要件定義書.md` v3.2（凍結）・`docs/データ基盤統合ロードマップ.md` Day6・`docs/正本宣言_ブランド.md`
**この文書で5論点に結論を出した。実装者はまず全部読み、§2の未決質問の回答状況をユーザーに確認してから着手。**

## 0. 鉄則（毎回同じ）

- 作業開始時と push 直前に `git fetch` → 先行していたら `git pull --rebase`。force push厳禁
- 接続情報・SQL実行（curl必須）・テストの流儀・WORKLOG追記は `WORKLOG.md` 冒頭の🔑🔒と `docs/実装指示書_本部タスクボード.md` §2・§6 のとおり
- 既存列の削除・改名禁止（追加のみ）。**`stores.lark_enabled` は今回「参照しない」ことにするが列は残す**
- **`.github/workflows/` はCLIのghトークンにworkflowスコープが無くpushできない**（過去に実証）。ワークフローを変更するときは `tori-dashboard/scripts/lark-report.workflow.yml`（コピー用）を更新し、**ユーザーにGitHub Web UIで差し替えてもらう**
- 課金・Secrets登録・Chatwork APIトークン発行はユーザー操作。案内して完了を待つ
- 入金CSV取込の表記ゆれ辞書 `STORE_CANONICAL_BY_NOSPACE_` は**今回触らない**（ユーザーが過去に明示的にスコープ外とした）

## 1. 設計決定（引継ぎ書§3の5論点への結論）

### 決定1: GAS→Supabaseの認証は「匿名読み取り専用VIEW」方式
- `store_directory_v`（店舗ディレクトリ）と `report_channel_matrix_v`（配信matrix）の**2つのVIEWを新設し、列をホワイトリストで絞って `anon` にSELECTだけGRANT**する。Edge Functionは作らない
- 根拠: ①公開する列（店舗番号・名称・看板・別名・法人名・表示順・有効フラグ・天気地点・精算対象・配信グループ）は**既にPublicリポジトリ（tori-dashboardの`CANON_STORES`等）に載っている情報と同等**で新たな露出にならない ②追加インフラ不要でGAS・GitHub Actions・ブラウザの全部から同じ方法で読める ③将来「書き込み」が必要になった時点で初めてEdge Functionを検討する
- **VIEWに含めてはいけない列**: `smaregi_store_id`・スマレジ系ID・内部メモ類・`stores`の他の管理用列。VIEW定義で明示列挙し、`select *` は禁止
- GAS側: `UrlFetchApp.fetch(SUPA_URL+'/rest/v1/store_directory_v', {headers:{apikey:公開キー}})` → `CacheService` に**10分キャッシュ** → **取得失敗時は現行のハードコード値（CANON_STORES相当）にフォールバックして処理を止めない**（配信・ダッシュボードが店舗マスタ障害で落ちないこと）

### 決定2: 「親子ブランド」は新しい階層テーブルを作らない
- 実態確認: `REVIEW_CHILDREN` と `DB_店舗親子` の中身は「**口コミ・広告媒体上の別掲載名 → 実店舗**」の対応（例: 「カラオケ 彩-irodori 新横浜アリーナ通り店」→黒霧屋 新横浜）。これは**別名（alias）の一種**であり、店舗の階層ではない
- ブランド（看板）の正本は `stores.signs`（正本宣言どおり）。別掲載名は `store_aliases` で表現する
- 実装: `store_aliases` に `kind text not null default 'name'` を**追加**（`name`=表記ゆれ／`listing`=口コミ・広告媒体上の別掲載名）。`REVIEW_CHILDREN`と`DB_店舗親子`の全行を `kind='listing', source='Google口コミ'` 等としてseed
- tori側: 口コミ集約の子リストを `store_aliases(kind='listing')` から組み立てる。移行期間中は `DB_店舗親子` シートも従来どおりマージして読む（差分が出たらログ）→ Day7で廃止判断
- `corporation_id` は法人であって親店舗ではないので、親子の代わりに流用しない

### 決定3: 天気地点は「店舗ごとの緯度経度」を正とし、未設定時だけ地域フォールバック
- `stores.weather_lat/lon` が入っている店舗はそれを使う。nullの店舗は現行 `WX_LOCS` の正規表現で地域既定（横浜/本厚木/東京）にフォールバックし、GASログに「未設定店舗」を出す
- **実装者が先にSQLで12店舗を現行WX_LOCSと同じ判定でバックフィル**する（ユーザー入力待ちにしない）。その後ユーザーがnippo店舗管理画面で確認・微調整
- 全店舗が埋まった後もフォールバックは残す（新店舗追加直後の空白期間対策）

### 決定4: 配信は「チャネル非依存」に作り直し、matrixはGitHub Actionsの動的生成にする（Chatwork統一に備える）
- **グループ割り当てをテーブル化**:
  - `report_channels`（id・name[例: group1 鳥一代系]・`kind`['lark'|'chatwork']・`secret_name`[GitHub Secretの**名前だけ**。URL/トークンは絶対にDBに置かない]・`chatwork_room_id`[kind=chatworkのとき]・`keyword`[Larkのカスタムキーワード]・`report_kinds text[]`[daily/weekly/monthly]・`is_active`・`sort_order`）
  - `report_channel_stores`（channel_id・store_id・sort_order）＝**店舗は複数グループに属せる**（現行group2/3の重複をそのまま表現）
  - `stores.lark_enabled` は今後参照しない（所属テーブルが真）
- **matrixはコミット不要の動的生成**: ワークフローに `prepare` ジョブを追加し、`curl` で `report_channel_matrix_v` を読んで `matrix` JSONを `outputs` に出す → `group-report` ジョブは `strategy.matrix: ${{ fromJSON(needs.prepare.outputs.matrix) }}`。`secrets[matrix.secret]` による動的参照はそのまま使える（GitHub Actionsの標準パターン。引継ぎ書の「静的定義が基本」は誤解で、動的matrixは公式機能）
- VIEW `report_channel_matrix_v` は「group, kind, secret_name, chatwork_room_id, keyword, stores（'店舗名|ファイルキー'のカンマ連結）, report_kinds」を返す。ファイルキー（`honten`等）は新列 `stores.file_key` を追加して持つ（現行matrixの値でseed）
- **Chatwork送信**: `scripts/lark-report.mjs` の `send` にチャネル種別を追加。Chatworkは `POST https://api.chatwork.com/v2/rooms/{room_id}/messages`（ヘッダ `X-ChatWorkToken`、Secret名 `CHATWORK_API_TOKEN`）。**画像は `POST /v2/rooms/{room_id}/files` でそのまま添付できる**（GitHub Release経由の画像リンクが不要になる＝Larkより単純）。LarkとChatworkは**グループ単位で混在可能**にし、移行は `kind` を切り替えるだけにする
- 現行3グループ（group1=本店/はなれ/芝/新橋、group2=恵比寿/黒霧屋新横浜/鶏武者川崎店、group3=黒霧屋新横浜/鶏武者川崎店/鶏武者新横浜、Secret=LARK_WEBHOOK_GROUP1〜3）をそのままseedし、**切替後の初回配信が現行と同一の宛先・同一の店舗になること**を受入条件にする

### 決定5: 既存12店舗の値は実装者がseedし、ユーザーは画面で確認する
- `seisan_target`: store_no 09〜12 = true（要件定義書§4の委託4店舗）
- `weather_lat/lon`: 決定3のとおりWX_LOCS相当でバックフィル
- 配信グループ所属: 現行matrixからseed
- `store_aliases(kind='listing')`: `REVIEW_CHILDREN`＋`DB_店舗親子`シートの全行
- seed後、**ユーザーにnippo店舗管理画面で12店舗を確認してもらう**（特に天気地点と配信グループ）

## 2. Chatwork統一について（2026-08-22 ユーザー回答済み・確定）

| 論点 | 回答・決定 |
|---|---|
| 現状の配信先 | **本部タスク通知・経費通知・期限アラートは既にChatworkへ流れている**（他スレッドが実装済み）。日報・週報・月報の自動配信は現在Lark、**今後Chatworkへ移す可能性あり** |
| 現場アルバイト | Chatwork未加入。**アルバイト向け（シフト期限アラート等）はLINE公式アカウントで継続**（LINEは有料化済みで送信上限の問題は解消→過去に上限で失敗したテストは再実行可能。ただしDay6の対象外・別タスク） |
| Chatwork APIトークン | **ユーザー自身が登録する**（手順を案内すれば実施。下記2-2） |

### 2-1. 実装方針（決定4の具体化）
- 配信設計はLark/Chatwork両対応のまま。**初期seedは現行Lark3グループ**。Chatworkへの切替はユーザーがnippoの配信グループ管理画面で `kind` を変えるだけにする（切替時期はユーザー判断）
- **最初にやること: 既存のChatwork送信経路を調査して再利用する**。候補=①本部タスク/経費で使っている経路（`hq_notify_channels` kind=chatwork → Edge Function経由か、どのSecretにトークンがあるか）②精算GASの `sd_notifyChatwork_`。**同じトークンをあちこちに複製しない**ことを優先し、可能なら「GitHub Actions → 既存の通知Edge Function（共有シークレット認証・BQミラーで確立したGET+トークン方式）→ Chatwork」の経路にして、**GitHub側に新しいSecretを増やさない**。Edge Function経由が不可（画像添付APIが未対応等）の場合のみ `CHATWORK_API_TOKEN` をGitHub Secretに登録してもらう
- 日報・週報・月報をChatworkへ流す際のルーム構成は「社員向け」が前提（アルバイト不在）。現行Lark3グループに対応するルームを使うか再編するかは切替時にユーザーが決める→**配信グループ管理画面で店舗の所属を自由に組み替えられること**が要件

### 2-2. ユーザーへの案内文（トークンが必要と判明した場合に、実装者がそのまま提示する）
1. Chatworkにログイン → 右上の自分の名前 → **サービス連携** → **API Token** → 表示（組織の管理者承認が必要な設定の場合は管理者が有効化）
2. 送信者名はそのアカウント名になるため、**配信専用アカウント（例: 「N-Style配信Bot」）で発行するのを推奨**（個人アカウントのトークンは退職・権限変更で止まる）
3. GitHub → `mirai-oss/tori-dashboard` → Settings → Secrets and variables → Actions → **New repository secret** → Name: `CHATWORK_API_TOKEN` → Value: トークン → Add
4. Chatworkのルーム ID は、ルームを開いたときのURL `https://www.chatwork.com/#!rid123456789` の `rid` の後ろの数字。配信グループ管理画面の「Chatworkルーム」欄にこの数字を入れる
5. トークンはチャットに貼らない（登録画面に直接入力）。登録後、実装者がテストルームへ1通送って疎通確認する

## 3. 実装手順（この順で。項目ごとにE2E→コミット）

1. **SQL** `ns-portal/supabase/2026-08-XX_store_directory.sql`（冪等）: `store_aliases.kind`追加／`stores.file_key`追加／`report_channels`・`report_channel_stores`新設＋RLS（読み=ログイン全員・書き=`checklist_can_manage()`相当の管理関数）／VIEW 2本（列ホワイトリスト・`grant select on ... to anon`）／seed（決定5）。適用後、`anon`キーでVIEWが読めること・`stores`本体は読めないことをcurlで確認
2. **tori GAS** `gas/Code.gs`: `fetchStoreDirectory_()`（VIEW取得＋10分キャッシュ＋フォールバック）を新設。`resolveAdStore_()` を `store_aliases` ベースに（`DB_店舗名対応`はフォールバックとして残す）。`data`レスポンスに `stores`（表示順・看板・別名・天気地点）を含める。ping verを上げる（**GAS再デプロイはユーザー作業・「デプロイを管理→編集→新バージョン」**）
3. **tori app.js**: `CANON_STORES`・`WX_LOCS`・`REVIEW_CHILDREN` を「`data.stores`があればそれを使い、無ければ現行定数」に変更（定数は削除しない）。`index.html`の`?v=`を上げる
4. **nippo 店舗管理画面** `adminStoresView()`: 「Lark配信」トグルを「配信グループ所属（チェック複数可）」に置換。配信グループ自体の管理（名前・種別・Secret名・Chatworkルーム・対象レポート種別）は同画面内の小さな管理ブロックでよい（マスター/社長/本部のみ）
5. **ワークフロー**（コピー用 `scripts/lark-report.workflow.yml` を更新→ユーザーがWeb UIで差し替え）: `prepare`ジョブ＋動的matrix。**Lark現行3グループで、ダミーWebhookサーバー方式（既存の検証テクニック）により「宛先・店舗が現行と同一」を確認**してから本番差し替え
6. **Chatwork送信**: まず§2-1の既存経路調査→再利用できる経路で `lark-report.mjs` に kind=chatwork の送信（メッセージ＋画像添付）を実装。ダミーHTTPサーバーで検証→テストルームで実送信1回→本番。新Secretが必要なら§2-2をユーザーに提示して登録を待つ
7. **Day7準備**: `DB_店舗名対応`・`DB_店舗親子`・`CANON_STORES`が「フォールバック専用」になったことをWORKLOGに記録（廃止判断はDay7）

## 4. 受入チェックリスト

```
[ ] anonキーで store_directory_v / report_channel_matrix_v が読める／stores本体・smaregi系列は読めない
[ ] GAS: VIEW障害を模擬（URLを壊す）しても現行定数にフォールバックして data が返る
[ ] tori: 店舗表示順・口コミ子リスト・天気地点がSupabaseの値で動く（未設定店舗は地域フォールバック＋ログ）
[ ] nippo: 店舗の配信グループ所属を変更→VIEWに即反映
[ ] Actions: 動的matrixで現行3グループ×店舗が同一（ダミーWebhookで検証）→ユーザーがWeb UIで差し替え→本番配信1回成功
[ ] Chatwork: 既存送信経路の調査結果を報告（トークンの所在・再利用可否）→テストルームへ画像付き配信成功・Larkとの混在動作
[ ] 新店舗をnippoで追加→GAS（10分後）・配信matrix・toriに反映（ロードマップDay6完了条件）
[ ] seed後の12店舗をユーザーが画面で確認済み
[ ] テストデータ削除／WORKLOG追記／引継ぎ書に「設計確定・実装済み」を追記し「📄ドキュメント一覧」に本書を追加
```
