# フェーズC 本番切替手順（社内情報管理システム → Vercel Pro）

作成: 2026-08-18 ／ 実装指示書_第3期実装フェーズ §C-3〜C-4 に基づく実施ガイド。
**課金・カード登録・Vercel操作はすべてユーザー自身が行ってください。Claudeは代行しません。**

対象リポジトリ: `ns-info-system`（GitHub: `mirai-oss/ns-info-system`）
切替先データベース: ハブSupabase `uuvsxzhpxtghojoubjcc`（`info`スキーマ。データ移行済み・194行移送確認済み）

---

## STEP 1: Vercelを「Pro」プランにする（課金操作）

1. ブラウザで https://vercel.com/dashboard を開く（`ns-info-system`をデプロイした時と同じアカウントでログイン）
2. 左上のアカウント名（またはチーム名）をクリック → 「**Settings**」を開く
3. 左メニューの「**Billing**」（請求）をクリック
4. 「**Upgrade to Pro**」ボタンを押す
5. クレジットカード情報を入力して確定（$20/月＝概ね3,000円前後/月、為替で変動）

→ ここまで完了したら教えてください。

---

## STEP 2: 環境変数を設定する（ハブSupabaseに向ける）

1. https://vercel.com/dashboard を開く
2. プロジェクト一覧から「**ns-info-system**」をクリック
3. 上部タブの「**Settings**」→ 左メニューの「**Environment Variables**」を開く
4. 既存の3つの変数を、下の表の通りに**書き換える**（無ければ新規追加）

| 変数名（Key） | 値（Value） |
|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | `https://uuvsxzhpxtghojoubjcc.supabase.co` |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | `sb_publishable_MrwPJAx_Ws_fdRutprKCiQ_dg3wCiTr` |
| `NEXT_PUBLIC_SUPABASE_SCHEMA` | `info` |

※ `ANON_KEY`は「公開用キー」で秘密情報ではありません（ns-portal側のログイン画面にも同じものがそのまま埋め込まれています）。

5. Environment（適用範囲）は「**Production**」にチェックが入っていることを確認して保存

---

## STEP 3: 再デプロイする

1. 同じプロジェクト画面の上部タブ「**Deployments**」を開く
2. 一番上（最新）のデプロイの右端「**⋯**」（3点メニュー）をクリック
3. 「**Redeploy**」を選ぶ
4. 確認画面が出たらそのまま「**Redeploy**」を押す
5. 1〜2分待つと「Ready」になります

---

## STEP 4: 動作確認（切替後に必ず確認）

- [ ] 日報のメールアドレス・パスワードでログインできる
- [ ] 法人・カテゴリの一覧が全部表示される
- [ ] 書類を1件、実際に開ける
- [ ] アルバイト権限のアカウントでログインし、機密情報（口座・パスワード等）が見えないことを確認

すべて✅になったら、Claude側でも簡単な確認を行います。

---

## 完了後（すぐにはやらないこと）

- 旧・社内情報管理プロジェクト（Supabase `wciefkpooncglahqdtmu`）は、**切替後2週間は削除しない**（実装指示書§C-5の方針どおり）。問題が出ないことを確認してから削除するかどうか判断してください
