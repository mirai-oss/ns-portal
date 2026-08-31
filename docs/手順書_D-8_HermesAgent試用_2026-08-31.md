# 手順書: Hermes Agent（候補A）をMac miniで試す — LINE窓口セットアップ

作成: 2026-08-31 ／ 担当D ／ 対象: ユーザー（Mac mini・LINE Developersでの作業）

## 前提・注意点（`調査レポート_D-8_Hermes比較_2026-08-31.md`より）

- **参照するのは必ず公式ドメイン`hermes-agent.nousresearch.com`**。`hermes-agent.org`は非公式サイトなので使わない
- LINE連携は**Webhook必須**。Mac miniは公開URLを持たないため、**Cloudflare Tunnel等でMac miniを外部公開する必要がある**（これがHermes Agent採用時の一番大きな運用変更点）
- 既存の応募者・シフトリマインド用LINE公式アカウントとは**別の新規アカウント**を作ることを推奨（会話が混ざらないように）

## 手順

### ①LINE Developersで新規Messaging APIチャンネルを作成

1. [LINE Developers Console](https://developers.line.biz/console/)にログイン（無ければLINEアカウントで新規登録）
2. 新しい「プロバイダー」を作成（例: 「NStyleグループ」など）
3. そのプロバイダー配下に「Messaging APIチャンネル」を新規作成（例: チャンネル名「NStyle AIエージェント」）
4. チャンネルの「チャンネル基本設定」タブで**Channel secret**をコピーして控えておく
5. 「Messaging API」タブで**Channel access token（長期）**を発行して控えておく
6. 同タブの「応答メッセージ」「あいさつメッセージ」を**無効化**しておく（Hermes Agentが自前で応答するため。有効のままだとLINE標準の自動応答と二重になる）

### ②Mac miniにHermes Agentをインストール

Mac miniのターミナルで:

```bash
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
```

sudo不要。インストール後、モデルをClaude（Anthropic API）に設定:

```bash
hermes model
```

対話形式でAnthropicを選択し、既存のAnthropic APIキー（`ANTHROPIC_API_KEY`）を入力。または直接:

```bash
hermes config set model anthropic/claude-sonnet-4
hermes config set ANTHROPIC_API_KEY sk-ant-...
```

### ③Mac miniを外部公開する（Cloudflare Tunnel）

Hermes AgentのLINE Webhookは既定でポート`8646`で待ち受けます。これをHTTPSで外部公開する必要があります。

```bash
# cloudflaredをインストール（Homebrewの場合）
brew install cloudflared
```

- **お試し（一時利用）**: `cloudflared tunnel --url http://localhost:8646` で即座にトンネルが張れますが、**起動のたびにURLが変わる**ため、LINE側のWebhook URL登録をやり直す必要があり本運用には不向きです（動作確認だけしたい場合はこれでOK）
- **継続利用したい場合**: 無料のCloudflareアカウントで「名前付きTunnel」を作ると、再起動してもURLが変わらない状態にできます。具体的な作成手順は[Cloudflare公式ドキュメント](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/)を参照してください（ドメインを持っていなくても作成できる場合があります。この部分は実際に試しながら進めるのが確実です）

### ④Hermes AgentにLINEの接続情報を設定

`~/.hermes/.env`に追記:

```
LINE_CHANNEL_ACCESS_TOKEN=（①で控えたChannel access token）
LINE_CHANNEL_SECRET=（①で控えたChannel secret）
LINE_ALLOWED_USERS=（許可するLINEユーザーIDをカンマ区切り。社長・本部のIDのみを登録）
LINE_PUBLIC_URL=（③で取得したhttps://から始まるトンネルURL）
```

`~/.hermes/config.yaml`で`gateway.platforms.line`を`enabled: true`に変更。

**`LINE_ALLOWED_USERS`について**: 自分のLINEユーザーID（`U`で始まる文字列）は、LINE公式アカウントを友だち追加した状態でHermes Agentにメッセージを送ると、起動ログに表示される見込みです（未確認の場合はテスト運用しながら確認）。

### ⑤LINE ConsoleにWebhook URLを登録

LINE Developers Consoleの「Messaging API」タブで、Webhook URLに以下を設定:

```
（③のトンネルURL）/line/webhook
```

「検証」ボタンで疎通確認 → 「Webhookの利用」をオンにする。

### ⑥起動してテスト

```bash
hermes gateway
```

ログに「webhook listening on」のような表示が出れば起動成功。①で作ったLINE公式アカウントを友だち追加し、メッセージを送って応答が返るか確認してください。

## テスト後にやってほしいこと

- 実際に試してみた感触（応答速度・精度・使い勝手）を教えてください
- 問題なく動くようであれば、常駐化（Macの起動時に自動でHermesが立ち上がるようにする）・本番運用への移行を次のステップとして進めます
- うまくいかない・思っていたのと違う場合は、いつでも候補B（自作LINE bot）に切り替えられます

## 参考リンク

- [Hermes Agent 公式ドキュメント](https://hermes-agent.nousresearch.com/docs/)
- [LINE Setup（公式）](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/line)
- [Configuration（モデル設定・公式）](https://hermes-agent.nousresearch.com/docs/user-guide/configuration)
- [LINE Developers Console](https://developers.line.biz/console/)
- [Cloudflare Tunnel 公式ドキュメント](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/)
