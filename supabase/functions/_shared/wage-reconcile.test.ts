import { assertEquals, assert } from "jsr:@std/assert@1";
import { holdFor, reconcileWages, type SmaregiWage, type SystemWage } from "./wage-reconcile.ts";

const T = "2026-11-12";
const sm = (id: string, division: number, effectiveDate: string, wage: number, o: Partial<SmaregiWage> = {}): SmaregiWage => ({ id, division, storeId: null, effectiveDate, wage, holidayWage: null, ...o });
const sys = (id: string, division: number, effective_date: string, wage: number, o: Partial<SystemWage> = {}): SystemWage => ({ id, division, store_id: null, effective_date, wage, holiday_wage: null, sync_status: "synced", smaregi_wage_apply_id: "a-" + id, ...o });
const base = { today: T, storeMap: { "10": "store-uuid-10" }, scope: "current_future" as const };

// これまでの wage_pull_all の動き（保留なし）を、そのまま書き写した参照実装。保留が無効のとき、新しい部品が同じ結果になることを確かめる
function legacy(list: SmaregiWage[], mine: SystemWage[], today: string, storeMap: Record<string, string>) {
  let imported = 0, drift = 0, matched = 0, conflicts = 0, skippedStore = 0, unsupported = 0; const ins: string[] = [], links: string[] = [], driftRows: string[] = [];
  const supported = (w: SmaregiWage) => w.division === 0 || w.division === 2 || (w.division === 1 && !w.storeId && w.holidayWage == null);
  const cur: Record<string, SmaregiWage> = {}; const keep: SmaregiWage[] = [];
  for (const w of list) { if (!supported(w)) { unsupported++; continue; } if (w.effectiveDate > today) { keep.push(w); continue; } const k = `${w.division}|${w.storeId ?? ""}`; if (!cur[k] || cur[k].effectiveDate < w.effectiveDate) cur[k] = w; }
  keep.push(...Object.values(cur));
  const have: Record<string, SystemWage> = {}; for (const m of mine) have[`${m.division}|${m.store_id ?? ""}|${m.effective_date}`] = m;
  for (const w of keep) {
    const storeUuid = w.storeId ? (storeMap[w.storeId] ?? null) : null;
    if (w.storeId && !storeUuid) { skippedStore++; continue; }
    const ex = have[`${w.division}|${storeUuid ?? ""}|${w.effectiveDate}`]; const hol = w.division === 0 ? w.holidayWage : null;
    if (!ex) { ins.push(w.id); imported++; }
    else if (ex.wage !== w.wage || (ex.holiday_wage ?? null) !== (hol ?? null)) { if (ex.sync_status === "synced") { drift++; driftRows.push(ex.id); } else conflicts++; }
    else { if (!ex.smaregi_wage_apply_id) links.push(ex.id); matched++; }
  }
  return { imported, drift, matched, conflicts, skippedStore, unsupported, ins: ins.sort(), links: links.sort(), driftRows: driftRows.sort() };
}

const smList: SmaregiWage[] = [
  sm("s1", 0, "2026-04-01", 1200), sm("s2", 0, "2026-10-01", 1250), sm("s3", 0, "2027-01-01", 1300),           // 履歴・いま有効・これから
  sm("s4", 0, "2026-09-01", 1400, { storeId: "10", holidayWage: 1500 }), sm("s5", 0, "2026-09-01", 1400, { storeId: "99" }), // 店舗あり・対応なしの店舗
  sm("s6", 2, "2026-11-01", 250000), sm("s7", 3, "2026-01-01", 1000), sm("s8", 1, "2026-11-01", 9000), sm("s9", 1, "2026-11-01", 9000, { storeId: "10" }),
];
const sysList: SystemWage[] = [
  sys("m2", 0, "2026-10-01", 1250, { smaregi_wage_apply_id: null }),                 // 一致（番号の結び付け）
  sys("m4", 0, "2026-09-01", 1380, { store_id: "store-uuid-10", holiday_wage: 1500 }), // 金額の違い
  sys("m6", 2, "2026-11-01", 240000, { sync_status: "pending" }),                    // 未反映の入力
];

Deno.test("保留が無効のとき: これまでの取り込みとまったく同じ結果（追加・一致・ズレ・未反映・対象外・店舗なし）", () => {
  for (const [l, m] of [[smList, sysList], [smList, []], [[], sysList], [smList.slice(0, 3), sysList.slice(0, 1)]] as [SmaregiWage[], SystemWage[]][]) {
    const a = legacy(l, m, T, base.storeMap); const r = reconcileWages(l, m, { ...base, holdEnabled: false, initialAllowed: false });
    assertEquals({ imported: r.counts.imported, drift: r.counts.drift, matched: r.counts.matched, conflicts: r.counts.conflicts, skippedStore: r.counts.skipped_store, unsupported: r.counts.unsupported,
      ins: r.inserts.map((x) => x.smaregi_wage_apply_id).sort(), links: r.links.map((x) => x.row_id).sort(), driftRows: r.drift.map((x) => x.row_id).sort() }, a);
    assertEquals(r.external.length, 0, "保留が無効なら、外部変更は 1 つも返さない"); assertEquals(r.counts.held, 0);
  }
});

Deno.test("保留が有効: スマレジにだけある新しい行は取り込まず、未承認の変更（new_row）として返す。承認済みの行はそのまま", () => {
  const r = reconcileWages(smList, sysList, { ...base, holdEnabled: true, initialAllowed: false });
  assertEquals(r.inserts.length, 0, "正式な賃金には 1 行も追加しない");
  assertEquals(r.external.filter((x) => x.kind === "new_row").map((x) => x.smaregi_wage_apply_id).sort(), ["s3", "s8"]);  // これから適用の時給・日給（s6 は未反映の入力があるので conflict）
  assertEquals(r.external.filter((x) => x.kind === "amount_changed").map((x) => [x.wage_setting_id, x.smaregi_value?.wage, x.system_value?.wage]), [["m4", 1400, 1380]]);
  assertEquals(r.counts, { imported: 0, held: 2, drift: 1, conflicts: 1, matched: 1, unsupported: 2, skipped_store: 1, history: 0, deleted: 0, with_wage: true });
  assertEquals(r.links, [{ row_id: "m2", smaregi_wage_apply_id: "s2" }], "一致した行の番号の結び付けはこれまでどおり");
});

Deno.test("保留が有効でも、初期投入（入社時・新しい契約の直後）はこれまでどおり取り込む", () => {
  const r = reconcileWages(smList, [], { ...base, holdEnabled: true, initialAllowed: true });
  assertEquals(r.inserts.map((x) => x.smaregi_wage_apply_id).sort(), ["s2", "s3", "s4", "s6", "s8"]);
  assertEquals(r.external.length, 0); assertEquals(r.counts.held, 0);
  const none = reconcileWages(smList, [], { ...base, holdEnabled: true, initialAllowed: false });
  assertEquals(none.inserts.length, 0); assertEquals(none.counts.held, 5, "初期投入の条件を満たさない人は、賃金が 1 件も無くても保留");
});

Deno.test("行の削除: 同期済みの「いま有効・これから適用」の行がスマレジに無い → deleted。履歴・未同期・作り直された行は対象外", () => {
  const mine = [sys("old", 0, "2026-04-01", 1200), sys("cur", 0, "2026-10-01", 1250), sys("fut", 0, "2027-01-01", 1300), sys("pend", 2, "2026-12-01", 250000, { sync_status: "pending", smaregi_wage_apply_id: null }),
    sys("re", 2, "2026-11-01", 240000)];
  const list = [sm("a-old", 0, "2026-04-01", 1200), sm("NEWID", 2, "2026-11-01", 240000)];   // cur と fut が消えた。re は別の番号で同じ内容がある（作り直し）
  const r = reconcileWages(list, mine, { ...base, holdEnabled: true, initialAllowed: false });
  assertEquals(r.external.filter((x) => x.kind === "deleted").map((x) => x.wage_setting_id).sort(), ["cur", "fut"]);
  assertEquals(r.counts.deleted, 2);
  assertEquals(reconcileWages(list, mine, { ...base, holdEnabled: false, initialAllowed: false }).counts.deleted, 0);
});

Deno.test("1 人ぶんの取り込み（全部の行を見る）: 保留が有効なら、過去の履歴は取り込まず・未承認にもしない", () => {
  const mine = [sys("m2", 0, "2026-10-01", 1250, { smaregi_wage_apply_id: "s2" })];
  const r = reconcileWages(smList.slice(0, 3), mine, { ...base, scope: "all", holdEnabled: true, initialAllowed: false });
  assertEquals(r.rows.map((x) => [x.w.id, x.outcome]), [["s1", "history"], ["s2", "matched"], ["s3", "held"]]);
  const off = reconcileWages(smList.slice(0, 3), mine, { ...base, scope: "all", holdEnabled: false, initialAllowed: false });
  assertEquals(off.rows.map((x) => [x.w.id, x.outcome]), [["s1", "insert"], ["s2", "matched"], ["s3", "insert"]], "無効ならこれまでどおり全部取り込む");
  assert(off.external.length === 0);
});

Deno.test("スイッチを false に戻したとき: 保留中（未解決の控えがある）の人は保留のまま。ほかの人はこれまでどおり", () => {
  assertEquals(holdFor(false, false, false), { holdEnabled: false, initialAllowed: false });   // これまでどおり（全部取り込む）
  assertEquals(holdFor(false, true, true), { holdEnabled: true, initialAllowed: false });      // 保留を続ける
  assertEquals(holdFor(true, false, true), { holdEnabled: true, initialAllowed: true });       // 初期投入
  assertEquals(holdFor(true, true, true), { holdEnabled: true, initialAllowed: false });       // 控えがある人は初期投入にしない
  assertEquals(holdFor(true, false, false), { holdEnabled: true, initialAllowed: false });
  // スイッチ false・控えあり: 保留中の行（s3）も、そのあとスマレジに足された行（s8）も、正式な賃金には入らない。控えは「まだある」と返り続ける＝勝手に閉じない
  const mine = [sys("m2", 0, "2026-10-01", 1250, { smaregi_wage_apply_id: "s2" })];
  const list = [sm("s2", 0, "2026-10-01", 1250), sm("s3", 0, "2027-01-01", 1300), sm("s8", 1, "2026-11-01", 9000)];
  const carry = reconcileWages(list, mine, { ...base, ...holdFor(false, true, false) });
  assertEquals(carry.inserts.length, 0);
  assertEquals(carry.external.map((x) => [x.kind, x.smaregi_wage_apply_id]), [["new_row", "s3"], ["new_row", "s8"]]);
  // 同じ状況で、控えの無い人はこれまでどおり取り込まれる
  const plain = reconcileWages(list, mine, { ...base, ...holdFor(false, false, false) });
  assertEquals(plain.inserts.map((x) => x.smaregi_wage_apply_id).sort(), ["s3", "s8"]); assertEquals(plain.external.length, 0);
  // 本部が同じ内容を正式に登録したあと（管理システムに行ができた）: 違いが無くなる → 外部変更は 0 件（呼び出し側が控えを「一致」で閉じる）
  const after = reconcileWages(list, [...mine, sys("m3", 0, "2027-01-01", 1300, { smaregi_wage_apply_id: null }), sys("m8", 1, "2026-11-01", 9000, { smaregi_wage_apply_id: null })], { ...base, ...holdFor(false, true, false) });
  assertEquals(after.external.length, 0); assertEquals(after.inserts.length, 0); assertEquals(after.links.length, 2);
});
