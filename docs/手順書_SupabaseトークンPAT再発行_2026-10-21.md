# かんたん手順: Supabaseの「アクセストークン」を作って保存する（所要5分）

これをやってもらえると、AI窓口（Hermes）の新しい照会（昨日の店舗別売上・ID/PWのリンク案内など）を私（Claude）が本番に反映できます。
古いトークンは期限切れです。**トークンの発行はあなたのSupabaseアカウントでしかできません。** それ以外は全部こちらでやります。

---

## 画面1: トークンの一覧ページを開く

1. パソコンのブラウザで **https://supabase.com/dashboard/account/tokens** を開く
   （ログイン画面が出たら、いつものSupabaseのアカウントでログイン）
2. 緑のボタン **「Generate new token」** を押す → 「Generate token」という入力画面が出ます（画面2へ）

---

## 画面2: 「Generate token」の入力（上から順に全部で6か所）

| 項目（画面の左側の文字） | 入れる・選ぶもの |
|---|---|
| **Name** | `claude-ns-portal` と入力 |
| **Expires in** | プルダウンを開いて **「30 days」** を選ぶ（無ければ「7 days」のままでOK。期限が切れたらまた作るだけ） |
| **Resource access** | **「Project」**（上の丸・RECOMMENDED）を選んだまま |
| **Select an organization** | プルダウンを開いて、出てきた組織を選ぶ（1つしか無いはず。複数あれば「N-Style」や「ns0314」の名前のもの） |
| **Select a project**（組織を選ぶと出る） | プルダウンを開いて、**ID が `uuvsxzhpxtghojoubjcc` のプロジェクト**を選ぶ（名前は「nippo」など。迷ったら、プロジェクト一覧で https://supabase.com/dashboard/project/uuvsxzhpxtghojoubjcc を開いたときに左上に出る名前と同じもの） |
| **Permissions** | 下の「権限の付け方」のとおり |

### 権限の付け方（Permissions）

**まず右側の「Preset · No access」のプルダウンを開いてください。**

- 一覧に **「Full access」** や **「Admin」** のような全部入りがあれば → それを選んで終わり（次へ進む）
- 無い・分からない場合 → プリセットはそのままにして、下の3つのカテゴリ（灰色の帯）を1つずつ **右端の「∨」を押して開き**、次のように設定します

| カテゴリ | 設定 |
|---|---|
| **Project**（Core project visibility…） | 中の項目を全部 **Read**（読み取り）にする |
| **Database**（SQL access, migrations…） | 「SQL」「Query」「Migrations」という名前の項目を **Write**（書き込み）にする。他は Read でも None でもOK |
| **Application services**（Auth, storage, realtime, edge functions…） | 「Edge Functions」「Functions」という名前の項目を **Write** にする。他は None でOK |
| Infrastructure and delivery／Account and organization | 触らない（None のまま） |

※ 「Read」「Write」「None」の選び方: 各行の右側にあるプルダウンや丸ボタンで選びます。
※ 迷ったら、Database と Application services の中を**全部 Write** にしてもかまいません（私が使うのはSQL実行とEdge Functionの更新だけです）。

---

## 画面3: 確認して発行

1. 右下の緑のボタン **「Review access」** を押す
2. 設定の一覧が出るので、右下の **「Generate token」**（または「Create token」）を押す
3. **`sbp_` で始まる長い文字列**が1回だけ表示されます。右の **コピー** ボタン（四角が2つ重なったマーク）を押してコピー
   （この画面を閉じると二度と見られません。閉じてしまったら画面1の2からやり直し）

---

## 画面4: Mac mini に保存する

1. Mac mini で **「ターミナル」** を開く（Launchpad → その他 → ターミナル、または Spotlight で「ターミナル」）
2. 下の1行を**まるごと**コピーして、ターミナルに貼り付ける。**貼り付けたあと、`ここに貼る` の5文字を消して、さっきコピーした `sbp_…` に置き換える**（前後の `'` は残す）
3. Enter を押す

```bash
printf '%s' 'ここに貼る' > ~/.config/ns-portal/supabase_pat && chmod 600 ~/.config/ns-portal/supabase_pat && echo 保存できました
```

「保存できました」と出たら完了です。このチャットで **「保存した」** と教えてください。あとは私が全部やります。

---

## うまくいかないとき

| 症状 | 対処 |
|---|---|
| 「Generate new token」が無い | ページ左のメニューで「Access Tokens」を押す |
| プロジェクトの選択肢が出ない | 先に「Select an organization」で組織を選ぶ |
| ターミナルで `No such file or directory` | 先に `mkdir -p ~/.config/ns-portal` を実行してから、もう一度画面4の2〜3 |
| 貼り付けで `'` が全角になった | 半角の `'`（Shift+7）で囲み直す |
| 私が「401」「権限が無い」と言ってきた | 権限（Permissions）が足りません。画面1からもう一度作り、Database と Application services を全部 Write にする |

## このトークンについて

- 私がこのトークンで行うのは **SQLの適用と Edge Function のデプロイ**だけ。作業内容は毎回先に伝えます。
- 作業が終わったら、画面1のページの **「Revoke」** で無効化してかまいません。
- トークンは Mac mini のそのファイルにだけ置き、リポジトリやチャットには貼りません。
