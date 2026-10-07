# resolve_store の使い方（各担当向け1ページ）（2026-10-07・担当F）

店舗名・店舗ID・店舗コードから「どの店舗か」を判定する**唯一の共通ゲートウェイ**。各システムが独自に店舗名を照合する実装を新しく書かないこと（Phase2以降で順次これへ置換）。
**状態**: Phase1（土台）。本番適用はユーザー確認後。**適用されるまで呼べない**。Phase1ではどのシステムの読み取り先も切り替えない。

## 1. 呼び出し
```
resolve_store(
  p_source      text,            -- どのシステムの名前か（下の一覧）
  p_external_id text default null,-- 外部システム上の店舗ID（スマレジ店舗ID等）
  p_code        text default null,-- 外部システム上の店舗コード
  p_name        text default null,-- 外部システム上に書かれた店舗名（請求書の店舗名・部門名・事業所名など）
  p_corp_hint   text default null,-- 法人の手がかり（corp_code / 正式名 / 表示名 / 別名。例 'toho'・'有限会社トーホーエージェンシー'）
  p_log         boolean default true -- false にすると未解決を隔離表に記録しない（検証・比較用）
) returns table (store_id uuid, brand_id uuid, corporation_id uuid, confidence text, matched_by text)
```
- **source_system の値**: `smaregi` / `smaregi_timecard` / `invoice` / `payroll`（MF部門）/ `settlement`（精算書）/ `ad` / `delivery` / `reservation` / `tabelog` / `hotpepper` / `gurunavi` / `gbp` / `dashboard` / `legacy_alias`（種別不明の旧別名）
- 呼べる権限: ログイン済みユーザー・`service_role`（Edge Function / GAS）。匿名は不可。

## 2. 戻り値
- **0行 = 未解決**。`kd_unresolved_names` に1行記録される（`source_table='resolve_store:<source>'`・既存の隔離の仕組み・Lark通知は既存の `kd-unresolved-check` に乗る）。呼び出し側は「その行は未確定」として扱う（勝手に店舗を当てない）。
- `confidence`:
  | 値 | 意味 | 使い方 |
  |---|---|---|
  | `exact` | 外部ID／コード／外部名の完全一致（登録済みマッピング） | 自動確定してよい |
  | `high` | stores.name の正規化一致／store_aliases（表記ゆれ） | 自動確定してよい |
  | `low` | 正規化後の部分一致（候補がちょうど1店舗） | **自動確定に使わない**。人の確認に回す |
- `matched_by`: `mapping:external_id` / `mapping:code` / `mapping:name` / `store_name` / `store_alias` / `partial`
- `corporation_id`: `stores.corporation_id`。**空の拠点（「本部」）はマッピングの法人ヒント（toho）から補う**
- `brand_id`: 一致したマッピングのブランド。無ければその店舗の現在の主ブランド（2枚看板の店舗は主ブランドのみ。広告のブランド別判定はPhase5）

## 3. 解決の順序（固定・変更しない）
①(source, 外部ID) → ②(source, コード) → ③(source, 外部名)完全一致 → ④`stores.name`（空白・全角半角・括弧・小書き仮名・末尾「店」を正規化）→ ⑤`store_aliases` → ⑥正規化後の部分一致（`low`）→ ⑦未解決（0行＋隔離記録）。
同名の店舗が複数ある時は `p_corp_hint` で絞る。絞れない／候補が複数なら未解決（誤って当てない）。

## 4. 呼び出し例
**JS（Supabase REST・ブラウザ／Edge Function）**
```js
const r = await fetch(`${SUPA_URL}/rest/v1/rpc/resolve_store`, {
  method: "POST",
  headers: { apikey: KEY, Authorization: "Bearer " + token, "Content-Type": "application/json" },
  body: JSON.stringify({ p_source: "invoice", p_name: "じんべえ 川崎店", p_corp_hint: "nstyle" })
});
const rows = await r.json();           // [] なら未解決（隔離に記録済み）
const hit = rows[0];                   // { store_id, brand_id, corporation_id, confidence, matched_by }
if (hit && hit.confidence !== "low") { /* 自動確定 */ } else { /* 人の確認へ */ }
```
**SQL**
```sql
select * from resolve_store('smaregi_timecard', '7');                         -- スマレジ事業所ID=7 → 本部（トーホー本社）
select * from resolve_store('settlement', null, null, '新横浜　黒霧屋');       -- 精算書の店舗名 → 黒霧屋 新横浜
select * from resolve_store('invoice', null, null, '鳥一代', null, false);     -- 曖昧（複数店舗）→ 0行・記録しない
```

## 5. 人が確定した時の登録（次回から自動）
```sql
select register_store_mapping(
  p_source := 'payroll', p_external_id := null, p_code := null,
  p_name := '08新横浜・匠味/鶏武者', p_store_id := '<stores.id>', p_brand_id := null);
```
- 本部/社長/マスターのみ。同じ外部名/IDが既に**別の店舗**へ有効登録されている場合は拒否（先に管理画面で無効化）。
- 登録すると、同じ名前の `kd_unresolved_names`（全取込元）が自動で解決済みになる。
- 管理画面: ポータル「管理・権限」→「法人・店舗マスタ（正本）」→「④外部マッピング」。**`store_aliases` への新規登録はしない**（`alias`が主キー＝全システム共通で一意のため、同じ名前が別の意味になる外部名を表せない）。

## 6. 運営関係（名義・運営・入金先）を引く
```sql
select * from v_store_current_relations;           -- 今日時点。店舗×名義/運営/入金先/契約満了予定/精算（入金先→運営主体）
```
過去月の関係が必要な処理（PL・精算書の再計算）は `store_operation_relations`（effective_from/to）を直接引く（Phase6で設計）。

## 7. 担当別の注意（司令塔指示の要約）
- **担当C**: Sync8 §2「タイムカード事業所名の登録先」は `store_aliases` ではなく `register_store_mapping('smaregi_timecard', …)`。「この店舗として登録」ボタンはこのRPCへ接続。
- **担当A/D/G**: 新しい店舗名照合を書かない。Phase2以降で順次 `resolve_store` に置換（別途指示）。
