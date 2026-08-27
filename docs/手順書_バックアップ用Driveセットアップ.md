# バックアップ用Google Driveセットアップ手順書（D-5b・初回のみ）

作成: 2026-08-27（担当D）／ 元: `docs/設計書_全社バックアップと復旧_2026-08-27.md`§6
対象読者: 非エンジニアでも実施できるように書いています。ここだけはGoogle管理画面での作業のため、Claudeが代行できません（アカウント作成・権限付与はユーザー本人の作業が必要）。

## これから作るものの全体像

1. バックアップ専用の「共有ドライブ」を1つ新しく作る（例: `NStyle-バックアップ`）
2. その共有ドライブに**書き込み専用**の“ロボットアカウント”（サービスアカウント）を招待する
3. GitHub Actions（週次バックアップの実行役）が、**鍵ファイルを持たずに**そのロボットアカウントになりすませるよう、Google Cloud側で信頼関係だけを設定する（Workload Identity連携）
4. 以降は毎週日曜深夜、自動でこの共有ドライブにバックアップが届くようになる

個人のGoogleアカウントのパスワードやトークンを直接使わない設計です（ロボットアカウントが書き込み専用のため、万一何かが漏れても既存データの閲覧・削除はできません）。

**2026-08-27追記**: 当初は「鍵（JSONファイル）を作ってダウンロードする」設計でしたが、手順2でこの組織のセキュリティポリシー（`iam.disableServiceAccountKeyCreation`）によりブロックされました。これは**Googleが推奨している「鍵を持たない」より安全な方式（Workload Identity連携）へ切り替えるべき、というサイン**なので、以下は鍵を作らない手順に更新しています（GitHub ActionsからGoogle Cloudに直接「私はこのリポジトリの実行です」と一時的に証明してもらう方式。漏洩しうる長期の鍵が最初から存在しません）。

---

## 手順1: 共有ドライブを作る

1. ブラウザでGoogle Drive（会社のWorkspaceアカウントでログイン）を開く: https://drive.google.com
2. 左メニューの「共有ドライブ」→「新規」
3. 名前を `NStyle-バックアップ` にして作成
4. できあがった共有ドライブのURL（`https://drive.google.com/drive/folders/〇〇〇〇`の〇〇〇〇部分）を控えておく（後で担当Dに伝える）

## 手順2: Google Cloudでロボットアカウント（サービスアカウント）を作る（鍵は作らない）

1. https://console.cloud.google.com/ を開く（会社のWorkspaceアカウントでログイン）
2. 上部のプロジェクト選択から「新しいプロジェクト」を作成（例: `nstyle-backup`）
3. 左メニュー「APIとサービス」→「ライブラリ」で **Google Drive API** を検索し「有効にする」
4. 同じく「ライブラリ」で **IAM Service Account Credentials API** を検索し「有効にする」（Workload Identity連携に必要）
5. 左メニュー「APIとサービス」→「認証情報」→「認証情報を作成」→「サービスアカウント」
   - 名前: 例 `nstyle-backup-writer`
   - 役割（ロール）: 指定しなくてOK（権限は共有ドライブ側の招待で絞るため）
   - 作成完了（**「キー」タブでの鍵作成はスキップ**。ここが今回変わった点）
6. サービスアカウントのメールアドレス（`〇〇〇@nstyle-backup.iam.gserviceaccount.com`のような形式）を控えておく
7. 画面上部（プロジェクト名の右あたり）に出ている**「プロジェクト番号」**（数字のみ・プロジェクトIDとは別物）も控えておく

## 手順3: Workload Identity連携を設定する（鍵の代わりの信頼関係）

GitHub Actionsが「私はmirai-oss/ns-portalリポジトリの実行です」と一時的に証明し、それと引き換えにロボットアカウントとして働けるようにする設定です。

1. Google Cloudコンソールの検索窓で「Workload Identity 連携」と入力して開く（左メニュー: IAMと管理 → Workload Identity 連携）
2. 「プールを作成」
   - 名前: `github-actions-pool`
   - 作成
3. そのままプロバイダの追加に進む（出ない場合はプール作成後の画面で「プロバイダを追加」）
   - プロバイダの形式: **OpenID Connect (OIDC)**
   - プロバイダ名: `github-actions`
   - 発行元（Issuer URL）: `https://token.actions.githubusercontent.com`
   - 属性マッピング（2行追加）:
     - `google.subject` = `assertion.sub`
     - `attribute.repository` = `assertion.repository`
   - **属性条件（Attribute Condition）** ← ここは必ず入力（空だと誰でも使えてしまうため）:
     ```
     assertion.repository == 'mirai-oss/ns-portal'
     ```
   - 保存
4. サービスアカウントに権限を付与（プロバイダ作成直後の画面に「アクセス権を許可」的なボタンがあればそこから。無ければ以下を手動で）
   - 左メニュー「IAMと管理」→「サービスアカウント」→ 手順2で作った `nstyle-backup-writer` をクリック
   - 「アクセス権限」タブ →「プリンシパルを追加」
   - 新しいプリンシパル: 次の1行をそのまま貼り付け（`PROJECT_NUMBER`だけ手順2⑦で控えた数字に置き換える）:
     ```
     principalSet://iam.googleapis.com/projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/github-actions-pool/attribute.repository/mirai-oss/ns-portal
     ```
   - ロール: **「Workload Identity ユーザー」**（`roles/iam.workloadIdentityUser`）を選択
   - 保存

## 手順4: 共有ドライブにロボットアカウントを招待する

1. 手順1で作った共有ドライブ `NStyle-バックアップ` を開く
2. 右上の「共有ドライブの管理」または人型アイコン →「メンバーを追加」
3. 手順2⑥で控えたサービスアカウントのメールアドレスを入力
4. 権限は **「コンテンツ管理者」**（ファイルの追加・整理はできるが、共有ドライブ自体の削除やメンバー変更はできない役割）を選択
5. 招待を確定

## 手順5: 控えた値を担当Dに伝える

チャットに貼り付けてOKです（これらは秘密情報ではなく、GitHubの正しいリポジトリから実行しない限り何もできない値のため）:

- 共有ドライブのURL（手順1④）
- サービスアカウントのメールアドレス（手順2⑥）
- プロジェクト番号（手順2⑦）

## 手順6（担当Dが実施）

上記3点を受け取ったら、担当D側で以下を行います:
- GitHub Actionsのワークフローファイルを作成（`workload_identity_provider`にプロジェクト番号を組み込む・鍵は一切使わない）
- 使い捨てのテスト用フォルダで書き込みテストを実施してから本番の共有ドライブに切り替え（既存ルールどおり）

---

## 参考: 現時点のバックアップ対象データ量（2026-08-27・担当D実測）

Google Driveの容量が足りるかの判断材料です。

| 対象 | サイズ |
|---|---|
| ハブSupabase DB本体（`info`スキーマ含む） | 約42 MB |
| Storage `report-photos`（日報写真） | 約71 MB（59ファイル） |
| Storage `invoice-files`（請求書添付） | 約60 MB（166ファイル） |
| Storage `documents`（社内秘密情報の書類） | 約12 MB（12ファイル） |
| Storage `manual-files` | 約1.5 MB |
| Storage `export-outputs`/`export-templates` | 約53 KB |
| **合計** | **約186 MB** |

**現時点では非常に小さく、Google Workspaceの共有ドライブ容量（通常は組織で共有の大容量プール）であれば全く問題ありません。** 週次・直近8週保持でも、増加ペースを考慮して数GB程度に収まる見込みです。容量不足の心配は現状ありません。
