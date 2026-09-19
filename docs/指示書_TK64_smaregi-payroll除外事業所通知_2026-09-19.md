# 指示書: TK-64残タスク — smaregi-payroll.jsの「除外事業所」をLark通知＋隔離台帳へ橋渡し

**対象セッション**: Mac mini（本番運用機。`.env`にSMAREGI_ID/PASSWORD等の実credentialsがあり、実データでのライブテストができる）
**発行**: 担当D（勤怠・給与・監視）2026-09-19セッション
**関連**: [docs/引継ぎ書_担当D_2026-09-19.md](引継ぎ書_担当D_2026-09-19.md) TK-64（kd_unresolved隔離の全ジョブ適用・残り2ジョブのうち1つ）

---

## 背景（なぜ必要か）

`ns-daily-import`の勤怠取込ジョブ`smaregi-payroll.js`は、スマレジから取得した勤務明細CSVをGAS
（`gas-backup/sales-db/コード.gs` の `importJinkenCSV`）へ送って人件費DBへ取込む。GAS側は
静的辞書`JIGYOSHO_MAP`（167行目〜）に登録の無い「事業所名」の行を**書き込まずに除外**する設計
（誤った店舗への計上より安全側）。除外があると`ui.alert()`のメッセージに

```
除外事業所:
・XXX
```

というブロックが追加されるが、これは`runImportHeadless_()`経由で`messages`配列に捕捉されるだけで、
**無人実行（Playwright自動化）では誰にも見えず埋もれている**。既に同じ問題が`infomart-siire.js`
（`STORE_NAME_MAP`・「未登録店舗」ブロック）で見つかり2026-09-18に修正済み（コミット
[`92ca8de`](https://github.com/mirai-oss/ns-daily-import/commit/92ca8de)）。今回はその横展開。

### infomart-siire.jsの修正とそのまま同じにできない点

`infomart-siire.js`は`lib/store-gateway.js`の`reportGasUnknownStores(jobName, messages, label)`を
呼ぶだけで済んだが、その内部の`alertUnknownStore()`が送るLark通知文言は

> Supabase store_aliasesに正しい対応を登録すれば、次回の実行から自動的に反映されます

と**固定文字列**になっている。`store_aliases`は「店舗“名”の表記ゆれ」を吸収するテーブルで、
`smaregi-payroll.js`の除外原因である`JIGYOSHO_MAP`（事業所名→店舗名の静的コード辞書。
`store_aliases`とは無関係）とは全く別物なので、この文言のまま使うと「store_aliasesに登録すれば
直る」という**誤った案内**になってしまう。そのため`store-gateway.js`に案内文を差し替えられる
オプション引数を追加してから使う。

### もう1つの論点（コードでは解決しない・実データを見て判断すること）

`kd_unresolved_names`（隔離台帳）は「解決済みでも再出現したらstatusを'open'に自動で戻す」設計
のため、**恒久的に除外され続ける事業所名**（例: 本部スタッフがスマレジに打刻していて、そもそも
店舗別人件費DBに入れる意図が無い場合）があると、実行のたびに毎回Lark通知が飛び続けてノイズになる
可能性がある。これは今回のコード変更では対処しない。**まず実データで「実際に何が除外されるか」
を確認し、恒久除外なのか単なる店舗未登録（JIGYOSHO_MAP追加漏れ）なのかをユーザーと確認してから、
必要であれば抑制の仕組みを別途検討すること**（先回りして複雑な仕組みを作らない）。

---

## 変更するファイル（2つ）

### 1. `ns-daily-import/lib/store-gateway.js`

`alertUnknownStore`と`reportGasUnknownStores`に、任意の第3/第4引数で案内文（guidance）を差し込める
ようにする。省略時は既存の文言のまま＝`infomart-siire.js`側の呼び出しは無改造で動作が変わらない。

```diff
-async function alertUnknownStore(jobName, rawName) {
+async function alertUnknownStore(jobName, rawName, guidance) {
   const key = `${jobName}::${rawName}`;
   if (_alerted.has(key)) return;
   _alerted.add(key);
   await recordUnresolvedName(jobName, rawName);
   try {
     await sendLark({
       taskName: `${jobName}（店舗名ゲートウェイ）`,
       status: '要確認',
       duration: '-',
-      detail: `未知の店舗名「${rawName}」を検出したため、この行の取込を保留しました（誤った店舗として書き込むより安全側に倒す設計）。\nSupabase store_aliasesに正しい対応を登録すれば、次回の実行から自動的に反映されます（kd_unresolved_namesにも記録済み）。`,
+      detail: `未知の店舗名「${rawName}」を検出したため、この行の取込を保留しました（誤った店舗として書き込むより安全側に倒す設計）。\n${guidance || 'Supabase store_aliasesに正しい対応を登録すれば、次回の実行から自動的に反映されます（kd_unresolved_namesにも記録済み）。'}`,
     });
   } catch (e) { /* Lark通知自体の失敗でジョブ本体は止めない */ }
 }
```

```diff
-async function reportGasUnknownStores(jobName, messages, label) {
+async function reportGasUnknownStores(jobName, messages, label, guidance) {
   const names = extractGasAlertList(messages, label);
-  for (const n of names) await alertUnknownStore(jobName, n);
+  for (const n of names) await alertUnknownStore(jobName, n, guidance);
   return names;
 }
```

### 2. `ns-daily-import/tasks/smaregi-payroll.js`

先頭のrequire群に追加:

```diff
 const { decodeSmart } = require('../lib/encoding');
 const { thisMonth, prevMonth, dayOfMonth } = require('../lib/dates');
+const { reportGasUnknownStores } = require('../lib/store-gateway');
```

`importMonth()`内、GAS応答チェック群の直後・`return msg;`の直前に追加（`all`/`msg`/`log`は
既存のローカル変数のまま使う。infomart-siire.jsの呼び出し位置と同じ考え方）:

```diff
   const nums = [...all.matchAll(/(新規追加|スキップ\(完全一致\)|上書き反映[^:]*): *(\d+)件/g)].map(m => Number(m[2]));
   if (nums.length && nums.every(n => n === 0)) {
     throw new Error(`取込結果が全て0件（事業所名マッピング不一致の疑い）。応答: ${msg.slice(0, 400)}`);
   }
+  // TK-64（2026-09-19）: GAS側importJinkenCSVはJIGYOSHO_MAP（コード.gs 167行目〜。店舗名の
+  // 表記ゆれ吸収であるstore_aliasesとは無関係の静的辞書）に無い事業所名の行を書き込まず
+  // 除外する。従来はui.alert()止まりで無人実行では誰にも気づかれなかったため、
+  // kd_unresolved_names＋Larkへ橋渡しする（store_aliasesではなくJIGYOSHO_MAPを直すよう案内）。
+  const excluded = await reportGasUnknownStores(
+    'smaregi-payroll', res.import?.messages, '除外事業所',
+    'この「事業所名」はgas-backup/sales-db/コード.gsのJIGYOSHO_MAP（store_aliasesとは別の静的辞書）に'
+    + '登録が無いため、この事業所の人件費行は一切取込まれていません。新しい店舗であればJIGYOSHO_MAPに'
+    + '追加してください。本部等、意図的に人件費DBへ取込まない事業所であれば対応不要です（このメッセージは'
+    + '事業所名が変わらない限り実行のたびに再通知されます）。',
+  );
+  if (excluded.length) log(`除外事業所を店舗名ゲートウェイへ通知: ${excluded.join(', ')}`);
   return msg;
 }
```

---

## 実施手順

1. `cd ~/ns-daily-import && git status --short`（このマシン固有の未コミット変更が無いか確認してから編集）
2. 上記2ファイルを編集（Editツールで該当箇所をそのまま置換すればよい）
3. `node --check lib/store-gateway.js && node --check tasks/smaregi-payroll.js`
4. **実データでのライブテスト**（このMacBookには`SMAREGI_ID`/`SMAREGI_PASSWORD`が無いため未実施。
   Mac miniでのみ可能）: 直近の実行で除外が起きていそうな月（無ければ当月でよい）を指定して
   手動実行し、ログに`除外事業所を店舗名ゲートウェイへ通知: ...`が出るか、Larkに通知が届くかを確認する。
   ```bash
   cd ~/ns-daily-import
   TARGET_STORES=  # 不要。以下のように直接実行
   node run.js smaregi-payroll
   ```
   除外が1件も無ければ`除外事業所を店舗名ゲートウェイへ通知`のログ自体が出ない（それも正常。
   スキップとして扱ってよい）。
5. **除外が実際に検出された場合**: 出てきた事業所名をユーザーへ報告し、
   - JIGYOSHO_MAPへの追加漏れ（新店舗・表記ゆれ）なら`gas-backup/sales-db/コード.gs`の
     `JIGYOSHO_MAP`に追加してGASへ再デプロイ（`clasp push`。sales-db GASなのでMac miniの
     既存clasp設定で対応可能なはず）。
   - 本部等の恒久的な除外であれば、今回はそのままでよい（Lark通知が繰り返し届く点だけユーザーに
     一言伝えておく。頻度が問題になるようなら別途抑制の仕組みを検討）。
6. 完了後、**必ず**`ns-portal/WORKLOG.md`（このリポジトリのCLAUDE.mdルールどおり、複数マシン共有の
   単一の正）に実施結果を追記し、冒頭「📍現在の状況」も更新してpush。`ns-daily-import`側の変更も
   コミット・pushすること。

---

## 確認済み事項（このセッションで調査済み・再調査不要）

- `res.import?.messages`は、GAS `importJinkenCSV`が`ui.alert(msg)`へ渡した1本の複数行文字列を
  そのまま1要素の配列として持つ（`取込WebApp.gs`の`runImportHeadless_`/`makeFakeUi_`で確認済み）。
  `extractGasAlertList`は配列を`\n`結合してから`ラベル:\n(...)`のブロックを正規表現で抜き出す
  実装なので、そのまま使える（`infomart-siire.js`と同じ経路）。
- 除外ブロックのラベル文言は`除外事業所`（コード.gs 642行目 `msg+=\n\n除外事業所:\n...`）で
  `未登録店舗`（infomart-siire.js側）とは異なる。上記コード例のとおり`'除外事業所'`を渡すこと。
