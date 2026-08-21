# 実装指示書: データ基盤ロードマップ Day 2（Mac mini側・勤怠API取込）

作成: 2026-08-21 ／ 対象: Mac mini側の実行スレッド
根拠: `docs/データ基盤統合ロードマップ.md` Day 2（Phase 2着手）
前提: Day 1（保全）完了済み・Day 2 MacBook側（勘定科目マスタ・ブランド正本宣言・LINEシークレットローテーション・report-photos非公開化）完了済み

---

## 0. 開始前の必須手順（省略禁止）

1. `ns-portal/WORKLOG.md` 冒頭「📍現在の状況」を読む
2. `ns-portal` で `git fetch origin` → ローカルが古ければ `git pull --rebase origin main`（MacBook側でDay1・Day2の複数コミットをpush済みのため、確実に取り込むこと）
3. 接続情報（このMac mini固有のものを使う。MacBook側の`~/.config/ns-portal/`はコピーしない）

## ⚠️ 最重要の前提: 「スマレジが従業員情報の正本」（2026-08-21 ユーザー決定）

Day1タスクDの実施中に発覚した重要な方針決定（詳細は`WORKLOG.md`の2026-08-21「info.employeesのデータ誤り発覚」の項を参照）:

> **基本的にスマレジタイムカードの従業員情報が正本**。`info.employees`（社内情報管理システムの手入力・スプレッドシート由来データ）は実態とズレていることが確認済み。

この方針を本タスクの設計に反映すること:
- 勤怠実績・人件費データを**誰の記録か**特定するときは、**`employee_profiles.smaregi_staff_id`** を正のキーとして使う（`info.employees`の氏名突合には依存しない）
- `employee_profiles.smaregi_staff_id`は現在13/13件（在籍者ベース）が入力済みで機能している（`smaregi-shift-sync`が既に本番でこの列を使ってシフト書込先を特定している。実装パターンはそのまま踏襲すればよい）
- ⚠️ 紛らわしい点: `public.users`テーブルにも`smaregi_staff_id`という同名の列があるが、**こちらは0/17件で未使用（レガシー？）**。正しいのは`employee_profiles.smaregi_staff_id`の方。混同しないこと（気になれば`users.smaregi_staff_id`をどうするかユーザーに確認してもよいが、今回のタスクでは触らない）

## ⚠️ 追加の発見: `smaregi-sync` Edge Functionがリポジトリに存在しない

`smaregi-sync`（従業員同期用、v2.6.14・本番ACTIVE）は`ns-portal/supabase/functions/`配下に**存在しない**（`smaregi-shift-sync`はある）。Management APIで本番デプロイ済みのバンドルは取得できたが、eszip形式（圧縮バンドル）でそのままでは読みにくい。**着手前に、可能であればこの関数のソースをきれいな形でリポジトリへバックアップすること**（Mac mini側にオリジナルの開発履歴が残っている可能性が高い。無ければ`supabase functions download`等で復元を試みる）。データ基盤監査レポートのR1（GASバックアップ不在）と同種のリスクなので、後回しにしないこと。

## ⛔ 絶対禁止事項

- 既存の`smaregi-sync`・`smaregi-shift-sync`の**本番ロジックを書き換えない**（読み取り専用の新規Edge Function `smaregi-attendance-sync` を追加する形で進める。既存2つはシフト機能④で稼働中の本番なので触らない）
- 本番Supabaseへの**破壊的なSQL**（DROP・既存列のTRUNCATE等）は禁止。新規テーブル追加・列追加のみ
- 新しいスマレジAPIスコープの追加（スマレジ・デベロッパーズ管理画面での操作）は**ユーザー作業**。実行スレッドはスコープ不足で403が出た場合、何のスコープが必要かを明記してユーザーに依頼する（このMac miniでスコープ追加はできない）
- 既存のマイグレーションSQLファイルは編集しない（新しい変更は日付入りの新規ファイルを追加。`NStyle-AI`のCLAUDE.mdおよびns-portalの慣例どおり）

---

## タスクA: スマレジ勤怠実績APIの疎通確認

1. 既存の`smaregi-sync`のOAuth2クライアントクレデンシャル（`SMAREGI_CONTRACT_ID`/`CLIENT_ID`/`CLIENT_SECRET`、契約ID`sez093z1`）がEdge Function シークレットとして既に設定済み。まずこれで`GET /shifts/results`（勤怠実績取得API）を**使い捨てのテスト用Edge Function**（本番`smaregi-sync`/`smaregi-shift-sync`には一切触れない別名の関数）で1日分だけ試験取得する
2. 403 Insufficient Scopeが出た場合: 必要なスコープ名（おそらく`timecard.shifts:read`系）を明記してユーザーに追加を依頼し、追加後に再テスト
3. 疎通確認できたら、テスト用Edge Functionは削除する

## タスクB: DBスキーマ準備

新規マイグレーションファイル `supabase/2026-08-2X_labor_cost_daily.sql` を作成:

- `labor_cost_daily` テーブル新設（列イメージ: `store_id`・`work_date`・`user_id`・`smaregi_staff_id`・`worked_minutes`・`late_night_minutes`・`overtime_minutes`・`hourly_wage`・`transportation_cost`・`estimated_cost`・`source`(スマレジAPI取得なら'smaregi'）・`created_at`。要件定義書§19の責任分界どおり給与計算そのものはスマレジに任せる前提で、あくまで「日次の人件費見積もり」を保存する設計とする）
- 既存の`attendance_records`テーブル（`user_id`/`store_id`/`work_date`/`shift_start`/`shift_end`/`clock_in`/`clock_out`/`source`列を持つ。現在0件）に実績を保存する形でもよい。`labor_cost_daily`との役割分担（生ログ=attendance_records・集計=labor_cost_daily）を設計して進めること
- RLSは他の勤怠系テーブル（`sf_shifts`等）に準拠

## タスクC: `smaregi-attendance-sync` Edge Function実装

- 毎日の日次バッチとして、前日分の勤怠実績を`GET /shifts/results`で取得
- **従業員の特定は`employee_profiles.smaregi_staff_id`をキーに`user_id`へ変換**（前述の「スマレジが正本」方針）。突合できない`smaregi_staff_id`（`employee_profiles`に未登録）があれば、エラーにせずログに記録し処理は続行（後日ユーザーに一覧で報告できるようにする）
- 時給・交通費設定・割増率もAPI取得し、日次人件費を自前計算（監査レポート§12の調査結果どおり。概算API=`totalPersonnelExpenses`は使わない）
- 取得結果を`attendance_records`・`labor_cost_daily`へ保存
- 旧経路（CSV手動ダウンロード→シート）は**止めない**（ロードマップの方針どおり、追加のみで並走）

## タスクD: 過去90日バックフィル + 突合（Day 3の前倒しでここまでやってもよい・時間があれば）

- 過去90日分を`smaregi-attendance-sync`と同じロジックで一括取得
- シートの人件費列（`分析_日別店舗`）と3日分スポット突合
- 直近1ヶ月は給与明細API（確定値）とも突合

## 完了条件（Day 2 Mac mini側）

- [ ] `smaregi-sync`のソースをリポジトリへバックアップ済み
- [ ] 勤怠実績APIの疎通確認済み（スコープ不足なら依頼済み）
- [ ] `labor_cost_daily`（または同等の設計）がDBに存在
- [ ] `smaregi-attendance-sync`が本番稼働し、前日分の実績を自動取得できる
- [ ] 従業員特定は`employee_profiles.smaregi_staff_id`ベースで実装されている（`info.employees`の氏名突合に依存していない）
- [ ] 旧経路（CSV→シート）は引き続き動いている

## 終了時（省略禁止・CLAUDE.mdの4ステップ）

①コミット・push ②`ns-portal/WORKLOG.md`に時系列追記 ③冒頭「📍現在の状況」を書き換え ④再コミット・push

**報告フォーマット**: 完了条件のチェック結果／スコープ追加が必要だった場合はその内容／突合できなかった`smaregi_staff_id`の一覧／つまずいた点
