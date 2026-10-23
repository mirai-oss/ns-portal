# 指示書（Mac miniセッション用）: Node.js を修正版へ更新する（重大な脆弱性・期限 2026-10-26 11:00）

作成: 担当D（2026-10-23）／依頼元: 司令塔（スマレジ・デベロッパーズからの通知）。
根拠（公式）: Node.js 2026-10-21 セキュリティリリース https://nodejs.org/en/blog/vulnerability/october-2026-security-releases
修正版: **22.x → 22.23.4／24.x → 24.22.1／26.x → 26.12.1**（それ以降でも可）。
主な内容: **CVE-2026-111497（High・Brotliデコーダの範囲外書き込みでリモートコード実行）**、TLSホスト名検証の迂回（CVE-2026-105483／CVE-2026-106069・High）ほか。Mac miniのジョブ（infomart-siire／infomart-invoice／ロケットナウ／smaregi-payroll／Dinii等）は、外部サイトへHTTPS接続してファイルをダウンロードするため、**Brotli圧縮された応答を受け取る側**にあたる。待ち受けサーバーは無いが、更新が必要。
対象外: スマレジAPIを直接呼ぶ本体＝Supabase Edge Functions（Deno）は対象外。PHPは使っていない。
注意: **Node.jsを更新しても、Playwrightのブラウザ（Chromium等）は更新されない**。Playwrightとブラウザも最新に近づける（下のステップ5）。

## やること（Mac miniで・順番に。途中で想定外が出たら止めて報告）

### 0. 事前確認（読むだけ・変更なし）
```bash
node -v ; which node ; npm -v
# どう入れたか（どれか1つが当たる）
brew list --versions node node@22 node@24 2>/dev/null
ls ~/.nvm 2>/dev/null | head -3 ; command -v nvm
ls /usr/local/bin/node 2>/dev/null   # 公式インストーラ(.pkg)の場合
# launchd（毎朝のジョブ）が使っているnodeのパス
grep -A2 "ProgramArguments" ~/Library/LaunchAgents/*.plist 2>/dev/null | grep -i node
cd ~/ns-daily-import && npx playwright --version
```
- 結果（`node -v`・入れ方・launchdのnodeパス）を、まず**チャットとWORKLOG📍に書く**。
- すでに修正版以上（22.23.4／24.22.1／26.12.1以上）なら、更新不要。ここで終了して報告。

### 1. 更新方法（入れ方に合わせる。1つだけ実施）
- **Homebrew**（`/opt/homebrew/bin/node`）: `brew update && brew upgrade node`（22系なら `node@22`・24系なら `node@24`）。**他のパッケージは一緒に上げない**（`brew upgrade` に名前を付ける）。`brew info node` で版を確認し、修正版未満なら公式配布を待つ（その旨を報告）。
- **nvm**: `nvm install <修正版>` → `nvm alias default <修正版>`。**launchdのplistがnvmの版つきパス（~/.nvm/versions/node/vX.Y.Z/bin/node）を直接指している場合、古い版のまま動き続ける**ので、ステップ2で必ずplistを直す。
- **公式インストーラ（.pkg）**: nodejs.org から該当系列の最新版を取得してインストール。
- いずれも、更新前に**現在の版を控える**（戻せるように）。

### 2. 毎朝のジョブ（launchd）が新しいNodeを使うことを確認・修正
- `~/ns-daily-import/install-launchd.sh` は **インストール時の `command -v node` のパス**をplistに埋め込む。
  - Homebrewの `/opt/homebrew/bin/node`（シンボリックリンク）なら、更新後も同じパスで新版が使われる＝**修正不要**。
  - nvmの版つきパスや、削除された古いパスなら、**plistを新しいnodeのパスに直して再読込**（`install-launchd.sh` を再実行するか、plistのパスを書き換えて `launchctl unload` → `load`）。**ジョブの実行時刻・内容は変えない**。
- 確認: `launchctl list | grep -i ns` で登録を確認、plistの `$NODE` が修正版を指すことを確認。

### 3. 依存の再インストール（必要な場合だけ）
- Node のメジャー系列を変えた場合のみ、`cd ~/ns-daily-import && npm ci`（ネイティブモジュールの再ビルド）。同じ系列内の更新なら不要。

### 4. 動作確認（本番データを壊さない範囲で）
- `node -v`（修正版以上か）／`cd ~/ns-daily-import && node -e "require('playwright'); console.log('playwright ok')"`
- **ジョブの実機実行は、翌朝の定時実行で確認**する（infomart-siire 06:45 など）。急ぐ場合のみ `HEADLESS=1 node run.js <軽いジョブ>` を1本だけ実行（外部サイトにログインする＝通常の毎朝と同じ操作）。重い・書き込みの大きいジョブ（infomart-invoice 送信 など）は手動で走らせない。
- 翌朝、`import_runs`（Supabase）で全ジョブ `success` を確認（失敗があれば更新前の版へ戻すか、原因を報告）。

### 5. Playwrightとブラウザ（Node更新とは別に）
- `cd ~/ns-daily-import && npm outdated playwright`／`npx playwright install chromium`（最新に近いブラウザへ）。`package.json` の範囲（^1.45）内の更新だけにとどめ、大きな上げ（メジャー）は別途相談。

### 6. 報告（このチャネルとWORKLOG📍。ユーザーに見える形で）
次の4点を、箇条書きで:
1. 更新**前**の `node -v` と入れ方
2. 更新**後**の `node -v`（修正版以上であること）
3. launchdのnodeパスの確認結果（修正の有無）
4. 翌朝のジョブ結果（`import_runs` の成功/失敗）

## ユーザーの承認について
- Mac miniのNode.jsの更新は**ユーザー承認が要る作業**。このセッションがこの指示書を受け取ったら、**まずステップ0だけ**実行して結果を報告し、ユーザーから「更新してよい」と言われてからステップ1以降を実施する。
- 期限は**2026-10-26（月）11:00**。10/25（日）までに更新できれば、10/26朝のジョブ結果を確認できる。
