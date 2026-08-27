# I-1 予約データ取込基盤: Mac miniセットアップ手順書（初回のみ）

作成: 2026-08-27（担当D）／ 対象: `ns-daily-import`（Mac mini実機）
前提: コードは`ns-daily-import`リポジトリにpush済み（`tasks/tabelog-note-reservation.js`／`tasks/dinii-reservation.js`）。ここではMac mini側で行う設定・実機テストのみを扱う。

## これから行うこと

1. Mac miniで`ns-daily-import`を最新化
2. `.env`に4つの値を追記
3. 1店舗だけHEADLESS=0（画面表示）で試し、見つからない画面要素があれば直す
4. 通しで動くようになったら`launchd`のスケジュール（毎朝10:00台）で自動化

---

## 手順1: コードを最新化

```bash
cd ~/ns-daily-import   # パスはMac miniの実際の場所に合わせる
git pull
npm install   # 新しい依存は追加していないので不要な可能性が高いが念のため
```

## 手順2: `.env`に4つの値を追記

`.env`（無ければ`.env.example`をコピーして作成）に以下を追記する。

```
SUPABASE_URL=https://uuvsxzhpxtghojoubjcc.supabase.co
SUPABASE_SERVICE_KEY=（下記②で取得）
TABELOG_NOTE_ID=（下記①で取得）
TABELOG_NOTE_PASSWORD=（下記①で取得）
DINII_RESERVATION_ID=（下記①で取得）
DINII_RESERVATION_PASSWORD=（下記①で取得）
```

**①食べログノート・ダイニー予約台帳のID/PW**: `app_secrets`テーブルに保存済み（`tabelog_note_login_id`/`_pw`・`dinii_reservation_login_id`/`_pw`）。Supabaseダッシュボード → Table Editor → `app_secrets`から値を控える。

**②`SUPABASE_SERVICE_KEY`**: 他のジョブでは使っていない新しい鍵（GASを経由せずNodeから直接Supabaseに書き込むため）。Supabaseダッシュボード → 該当プロジェクト → Settings → API → `service_role`鍵（**秘密。他の`.env`値と同じ扱いで厳重管理**）。

## 手順3: 1店舗だけ実機テスト

まず食べログノートから（1店舗だけ・画面を見ながら）:

```bash
HEADLESS=0 node run.js tabelog-note-reservation
```

うまく行けばダイニー予約台帳も:

```bash
HEADLESS=0 node run.js dinii-reservation
```

### つまずいたら

- エラーメッセージに「見つからない要素」が出るので、`tasks/tabelog-note-reservation.js`（または`dinii-reservation.js`）の該当行を実際の画面に合わせて直す（既存の他ジョブと同じ直し方）
- ダイニー予約台帳は、店舗によって上部ナビに「予約台帳」が直接出ず、先に「集客」をクリックする必要がある（実装済みだが動作未確認）
- ログイン画面のID/PW欄のセレクタは未確認（現状は`input[type="text"]`等の一般的な候補で当てている）

### 成功の確認方法

Supabaseダッシュボード → Table Editor → `rsv_reservations` に行が入っていればOK。件数がゼロ、または極端に少ない場合は日付範囲・店舗切替がうまくいっていない可能性が高い。

## 手順4: 安定したらスケジュール登録

`config.js`の`DAILY_INDEPENDENT`に既に追記済み（毎朝10:00・10:05）。`install-launchd.sh`は既存タスクと共通なので、再実行は不要（`dispatch.js`が`config.js`を都度読むため）。

---

## この後（Mac mini作業が終わったら担当Dへ）

- 成功件数・失敗店舗があればその内容をWORKLOG（`ns-portal/WORKLOG.md`）に追記してください（担当Dが引き継いで対応します）
- 安定して数日分のデータが貯まったら、BigQuery`stg_reservation`側の実装（ダッシュボードGASへの新アクション追加）に進みます
- 黒霧屋 新横浜（食べログノート）とうお蔵 新横浜（ダイニー台帳）で同じ予約が重複していないかの初回突合は、データが揃ってからユーザーに確認します（設計書§8.8）
