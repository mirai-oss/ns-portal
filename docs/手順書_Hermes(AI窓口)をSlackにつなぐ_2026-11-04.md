# 手順書：Hermes（NStyle AI窓口）を Slack につなぐ（2026-11-04）

> LINE で動いている AI 窓口（Hermes）を、Slack でも使えるようにします。
> 通知用の「N-Style 通知Bot」とは**別のアプリ**を 1 つ作ります（会話を受け取るには別の仕組みが要るため）。
> かかる時間：10 分。カギ（トークン）は画面で見なくてよい作りです。

---

## できあがりの姿

- Slack の DM で `nstyle-ai` に話しかける → LINE と同じように答える（売上・日報・タスクなど）。
- チャンネルでは `@nstyle-ai 昨日の売上は？` のように **@ を付けたときだけ**反応。返事はそのスレッドに来る。
- 話せる人は最初は **4 人（今のワークスペースの全員）**。増やす・減らすは私に言えば OK。

---

## ① アプリを作る（3 分）

1. https://api.slack.com/apps を開く → 右上 **「Create New App」**。
2. **「From a manifest」** → **Continue**。
3. ワークスペース **NSグループ** を選んで **Next**。
4. タブを **JSON** にする（今回は YAML ではなく JSON）。
5. 箱の中を全部消して（⌘A → delete）、ターミナルで下を実行してコピーし、⌘V で貼る。

```bash
pbcopy < ~/.hermes/slack-manifest.json && echo "コピーOK"
```

6. 1 行目が `{` で、少し下に `"name": "NStyle AI窓口"` があれば OK → **Next** → **Create**。

> ❌ が出たら、その画面のスクリーンショットを送ってください。

## ② Socket Mode 用のカギ（App-Level Token）を作って保存（3 分）

1. 左メニュー **Basic Information** → 下のほうの **「App-Level Tokens」** → **Generate Token and Scopes**。
2. Token Name に `hermes` と入れる。
3. **Add Scope** → `connections:write` を選ぶ。
4. **Generate** → `xapp-` で始まるカギが出る。**Copy** を押す。
5. ターミナルで下を実行（カギは画面に出ません）。

```bash
printf 'SLACK_APP_TOKEN=%s\n' "$(pbpaste)" >> ~/.hermes/.env && pbcopy < /dev/null && echo "保存OK: $(grep -c '^SLACK_APP_TOKEN=xapp-' ~/.hermes/.env) 件"
```

→ `保存OK: 1 件` なら成功。**Done** でダイアログを閉じる。

## ③ アプリをワークスペースに入れて、Bot のカギを保存（3 分）

1. 左メニュー **Install App**（または OAuth & Permissions）→ **Install to NSグループ** → **許可する**。
2. 同じページの **Bot User OAuth Token**（`xoxb-` で始まる）の **Copy** を押す。
3. ターミナルで下を実行。

```bash
printf 'SLACK_BOT_TOKEN=%s\nSLACK_ALLOWED_USERS=U0C751GDZDG,U0C7ENECTDZ,U0C7GP7TXEH,U0C7L49ELHL\n' "$(pbpaste)" >> ~/.hermes/.env && pbcopy < /dev/null && echo "保存OK: $(grep -c '^SLACK_BOT_TOKEN=xoxb-' ~/.hermes/.env) 件"
```

→ `保存OK: 1 件` なら成功。（2 行目の `SLACK_ALLOWED_USERS` は「話せる人」。今の 4 人の Slack ID です）

## ④ チャットで「保存した」と教える

→ 私が Hermes を再起動して、Slack で `nstyle-ai` が「オンライン」になること、DM で返事が来ることを確認します。

---

## 使い方（できたあと）

| したいこと | やり方 |
|---|---|
| 質問する | `nstyle-ai` に DM。例「昨日の店舗別売上」「今月の累計は？」 |
| チャンネルで聞く | `@nstyle-ai 本店の先週の売上` のように @ を付ける。返事はスレッド |
| 会話をリセット | DM で `/new` |
| 話せる人を変える | 私に「○○さんも話せるようにして」と言う |

## 困ったとき

| 症状 | 対処 |
|---|---|
| ① で ❌ が出る | スクリーンショットを送る |
| ②③ で `保存OK: 0 件` | Copy が押せていないか、先にコマンドをコピーして上書きされています。Slack で Copy → すぐターミナルで return の順でやり直す |
| 返事が来ない | 私に「Slack の Hermes が返事しない」と言う（ログを見ます） |
| カギをどこかに貼ってしまった | 私に言う → Slack の「Revoke」と作り直しを案内します |
