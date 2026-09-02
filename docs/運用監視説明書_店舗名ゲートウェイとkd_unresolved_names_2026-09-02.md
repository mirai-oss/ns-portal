# 運用監視説明書: 店舗名ゲートウェイと kd_unresolved_names のゼロ運用

作成: 2026-09-02（担当D） ／ `設計書_表示集計層kdと高速化実行計画_2026-09-02.md` §5・§10.2-5 対応

## この仕組みが何のためにあるか

過去に何度も「表記ゆれ（例: `じんべえ 新横浜店` と `じんべぇ 新横浜`）が原因で、特定店舗のデータだけが静かに集計から漏れる」「別店舗と誤認識され金額が二重計上される」という実害が起きた（PL画面・入金管理・明細分析など）。

**店舗名ゲートウェイ原則**は、この種の事故を構造的に防ぐためのルール。

> どの取込ジョブも、店舗名をDB・シートへ書き込む前に、必ず正式名マスタ（Supabase `store_aliases` / `store_directory_v`）を通す。マスタに無い（＝未登録の）表記が出てきたら、**間違った店舗として書き込むのではなく、その行だけ保留してLarkへ通知する**。

## 全体の流れ（正常系）

```
取込ジョブ（ns-daily-import等） 
  → 店舗名を store_directory_v と突き合わせ
  → 一致すれば正式名に変換して書き込み（通常どおり）
```

## 全体の流れ（未知の店舗名を検知した場合）

```
取込ジョブが未知の店舗名を検知
  → その行だけ書き込みを保留（他の行・他の店舗は通常どおり処理継続）
  → kd_unresolved_names へ記録（source_table・raw_name・occurrences・status='open'）
  → Larkへ即通知（「未知の店舗名: ◯◯」）
  → 【人の作業】store_aliases へ正しい対応を登録する
  → 次回の取込から自動的に正しく処理される（コード変更不要）
  → kd_unresolved_names の該当行を resolved に変更する（下記手順参照）
```

## 毎朝の見張り番（自動チェック）

`tori-dashboard`の`.github/workflows/morning-watchdog.yml`（毎朝09:30 JST自動実行・cron-job.org経由）に、**売上・勤怠の取込確認に加えて`kd_unresolved_names`の未解決件数チェックを追加済み**（2026-09-02）。

- 未解決件数が0件のまま：何も通知しない（正常）
- 未解決件数が1件以上：Larkへ「店舗名ゲートウェイで保留中のデータが◯件あります」と通知
- 呼び出し先: `ns-portal`の新規Edge Function `kd-unresolved-check`（`BQ_LOAD_TOKEN`で認証・読み取り専用。既存の`attendance-freshness-check`と全く同じ設計）

**運用のゴール**: この件数を常に0件に保つこと（＝「ゼロ運用」）。1件でも出たら、その日のうちにstore_aliasesへ登録して解消するのが理想。

## 未解決の店舗名を見つけたときにやること（人の作業）

1. Larkに届いた通知、または以下のSQLで未解決一覧を確認する:
   ```sql
   select source_table, raw_name, occurrences, first_seen, last_seen
   from kd_unresolved_names
   where status = 'open'
   order by last_seen desc;
   ```
2. その表記が「本当はどの店舗のことか」を確認する（`source_table`＝どのジョブで見つかったか、`raw_name`＝実際に出てきた表記）
3. Supabaseの`store_aliases`テーブルに、正しい対応を1行追加する（`kind='name'`、`store_id`＝該当店舗、`alias`＝`raw_name`と同じ文字列）
4. 次回のジョブ実行を待つ（または手動で該当ジョブを再実行する）と、その表記は正しく解決されるようになる
5. `kd_unresolved_names`の該当行を解決済みにする:
   ```sql
   update kd_unresolved_names
   set status = 'resolved', resolved_at = now()
   where id = '<該当id>';
   ```
   （resolved_byを記録したい場合は、実施した本人のuser_idも併せて設定する）

## 現在ゲートウェイが適用されているジョブ（2026-09-02時点）

`ns-daily-import`の以下のジョブに`lib/store-gateway.js`（`resolveStoreName()`）を適用済み:

- `paypay-bank.js` / `paypay-bank-b.js`（入金取込。表記ゆれによる二重計上インシデントの直接原因箇所だったため最優先で対応）
- `dinii-payment-ns.js` / `dinii-payment-nstyle.js`（支払い取込）

**未適用（次の対応候補）**: `infomart-siire.js`／`smaregi-payroll.js`／`dinii-questionnaire.js`——複数店舗混在の1枚CSVをそのままGAS側へ送る設計のため、適用にはCSVを行ごとにNode側で解析する作り替えが必要。実際のCSVサンプルで列構成を確認しながら安全に進める必要があるため、Mac mini（実サイトへのログイン手段があるマシン）での対応を推奨（`ns-daily-import/README.md`「2026-09-02追記」にも同内容を記載済み）。

`tori-dashboard`（GAS）側は`bqStoreNameIndex_()`/`bqResolveStoreName_()`が同じ役割を既に担っている（BQミラー8テーブルに適用済み）。こちらは`kd_unresolved_names`への記録はまだ無く、従来どおり「未登録の表記はトリムのみで通す（無理な推測はしない）」設計のまま。GAS側もkd_unresolved_namesへ記録するようにするかは、担当A・レーンPの判断で追加を検討してよい。

## 関連ファイル

- `ns-daily-import/lib/store-gateway.js` — ゲートウェイ本体（`resolveStoreName`/`alertUnknownStore`）
- `ns-portal/supabase/functions/kd-unresolved-check/index.ts` — 見張り番用の件数チェックEdge Function
- `tori-dashboard/.github/workflows/morning-watchdog.yml` — 毎朝の自動チェック本体
- `設計書_表示集計層kdと高速化実行計画_2026-09-02.md` §5・§10.2 — 全体設計
