// keiei-api-* の「本物のハンドラー」を、にせの Supabase（メモリ上）で動かして、法人の限定を確かめる結合テスト。
// 実行（import map で npm:@supabase/supabase-js@2 をにせものに差し替える。ファイル名を itest にして、普通の deno test に混ざらないようにしてある）:
//   deno test --allow-env --allow-read --import-map=supabase/functions/_shared/fixtures/keiei-test-import-map.json supabase/functions/_shared/keiei-corp-scope.itest.ts
// deno-lint-ignore-file no-explicit-any
import { assert, assertEquals, assertNotEquals } from "jsr:@std/assert@1";
import { A1, A2, B1, CORP_A, CORP_B, makeTables, SERVICE_KEY, TOKENS, Z1 } from "./fixtures/keiei-world.ts";

Deno.env.set("SUPABASE_URL", "http://fake.invalid");
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", SERVICE_KEY);

type Handler = (req: Request) => Promise<Response> | Response;
let chain: Promise<unknown> = Promise.resolve();   // Deno.serve の差し替えは同時に 1 つだけ
// KEIEI_FN_BASE: 別の場所の関数（例: 修正前の本番ソース）に同じテストをあてるときだけ指定する（file:// で終わりが / の URL）
function load(slug: string, base = Deno.env.get("KEIEI_FN_BASE") ?? new URL("../", import.meta.url).href): Promise<Handler> {
  const p = chain.then(async () => {
    let h: Handler | null = null;
    const orig = (Deno as any).serve;
    (Deno as any).serve = (fn: Handler) => { h = fn; return {}; };
    try { await import(`${base}${slug}/index.ts`); } finally { (Deno as any).serve = orig; }
    if (!h) throw new Error("handler が取れませんでした: " + slug);
    return h as Handler;
  });
  chain = p.catch(() => {});
  return p;
}
function setWorld(opts: { failTables?: string[]; rpcs?: Record<string, (a: any) => any[]> } = {}) {
  const log: string[] = [];
  (globalThis as any).__fakeDb = { tables: makeTables(), rpcs: opts.rpcs ?? {}, auth: TOKENS, failTables: opts.failTables ?? [], log };
  return log;
}
const call = async (h: Handler, token: string | null, body: unknown) => {
  const r = await h(new Request("http://x/fn", { method: "POST", headers: token ? { Authorization: `Bearer ${token}` } : {}, body: JSON.stringify(body) }));
  return { status: r.status, json: await r.json() };
};
const SVC = `${SERVICE_KEY}`;
const sum = load("keiei-api-dashboard-summary");
const home = load("keiei-api-home");
const rsv = load("keiei-api-reservation");

const UNRESTRICTED = ["t.master.sig", "t.ceo.sig", "t.hqfree.sig", "t.teaminactive.sig"];
const ALL_STORES = [A1, A2, B1, Z1];
const storesOf = (rows: any[]) => [...new Set(rows.map((r) => r.store_id))].sort();
const P = { year_month: "2026-11" };

// ---------- ① 制限なしユーザーは従来どおり ----------
Deno.test("①制限なし: 全種別が全法人の行を返し、scope に corporationIds を足さない／サービス呼び出しと同じ中身", async () => {
  const h = await sum; setWorld();
  for (const kind of ["pl", "media", "deposit", "store", "daily", "deposit_daily", "deposit_carry", "ad", "target", "target_daily", "delivery_daily", "media_daily", "pl_entries", "spot", "loan"]) {
    const svc = await call(h, SVC, { kind, ...P });
    assertEquals(svc.status, 200, kind);
    assert(svc.json.rows.length > 0, kind);
    for (const t of UNRESTRICTED) {
      const r = await call(h, t, { kind, ...P });
      assertEquals(r.status, 200, `${kind}/${t}`);
      assertEquals(r.json.rows, svc.json.rows, `${kind}/${t}: 行（順序・列を含む）がサービス呼び出しと同じ`);
      assertEquals(Object.keys(r.json.scope).sort(), ["restrictedStoreIds", "role"], `${kind}/${t}: scope の形が従来のまま`);
      assertEquals(r.json.scope.restrictedStoreIds, null);
    }
    assertEquals(svc.json.scope, { role: "service_role", restrictedStoreIds: null });
  }
  // 共通経費行（store_id null）も、制限なしの人には見える
  const pl = await call(h, "t.hqfree.sig", { kind: "pl", ...P });
  assert(pl.json.rows.some((r: any) => r.store_id === null));
  assertEquals(storesOf(pl.json.rows.filter((r: any) => r.store_id)), ALL_STORES);
});

// ---------- ② 法人限定ユーザーは自法人の行だけ ----------
Deno.test("②法人限定（個人の許可 A）: どの種別も法人 A の店舗の行だけ・共通行は出ない", async () => {
  const h = await sum; setWorld();
  for (const kind of ["pl", "media", "deposit", "store", "daily", "deposit_daily", "deposit_carry", "ad", "target", "target_daily", "delivery_daily", "media_daily", "pl_entries", "spot", "loan"]) {
    const r = await call(h, "t.hqA.sig", { kind, ...P });
    assertEquals(r.status, 200, kind);
    assert(r.json.rows.length > 0, kind + ": 自法人の行は見える");
    assertEquals(storesOf(r.json.rows), [A1, A2], kind);
    assertEquals(r.json.scope.corporationIds, [CORP_A]);
    assertEquals(r.json.scope.restrictedStoreIds, null);   // 役職ベースの値は従来どおり
  }
  // 役職の許可（B）のチーム長
  const r2 = await call(h, "t.teamroleB.sig", { kind: "pl", ...P });
  assertEquals(storesOf(r2.json.rows), [B1]);
  // 個人の許可が優先
  const r3 = await call(h, "t.teamucOverRole.sig", { kind: "deposit", ...P });
  assertEquals(storesOf(r3.json.rows), [A1, A2]);
});
Deno.test("②法人限定: kinds（複数種別）と months でも自法人だけ", async () => {
  const h = await sum; setWorld();
  const r = await call(h, "t.hqA.sig", { kinds: ["pl", "media", "deposit", "daily"], from: "2026-10", to: "2026-11" });
  for (const k of ["pl", "media", "deposit", "daily"]) assertEquals(storesOf(r.json.results[k].rows), [A1, A2], k);
});

// ---------- ③ 改ざん ----------
Deno.test("③改ざん: 他法人の store_id・corporation_id・media_name を入れても自法人の行しか返らない", async () => {
  const h = await sum; setWorld();
  for (const kind of ["pl", "media", "deposit", "daily", "deposit_daily", "target_daily"]) {
    const other = await call(h, "t.hqA.sig", { kind, ...P, store_id: B1 });
    assertEquals(other.json.rows, [], `${kind}: 他法人の store_id は空`);
    const mine = await call(h, "t.hqA.sig", { kind, ...P, store_id: A1 });
    assertEquals(storesOf(mine.json.rows), [A1], kind);
  }
  // クライアントが corporation_id / store_ids を送っても、使われない（無視される）
  const r = await call(h, "t.hqA.sig", { kind: "pl", ...P, corporation_id: CORP_B, corporationIds: [CORP_B], corporation_ids: [CORP_B] });
  assertEquals(storesOf(r.json.rows), [A1, A2]);
  const m = await call(h, "t.hqA.sig", { kind: "media", ...P, media_name: "食べログ", store_id: Z1 });
  assertEquals(m.json.rows, []);
  const m2 = await call(h, "t.hqA.sig", { kind: "media", ...P, media_name: "食べログ" });
  assert(m2.json.rows.length > 0 && m2.json.rows.every((x: any) => x.media_name === "食べログ" && [A1, A2].includes(x.store_id)));
  // 明細分析（detail）: 他法人を含めて指定しても、RPC に渡る店舗は自法人だけ
  const seen: string[][] = [];
  setWorld({ rpcs: { kd_detail_items: (a) => { seen.push(a.p_stores); return []; }, kd_detail_hours: (a) => { seen.push(a.p_stores); return []; }, kd_detail_stores: (a) => { seen.push(a.p_stores); return []; }, kd_detail_coverage: (a) => { seen.push(a.p_stores); return []; } } });
  const d = await call(h, "t.hqA.sig", { kind: "detail", from: "2026-11-01", to: "2026-11-30", store_ids: [B1, A1, Z1] });
  assertEquals(d.status, 200);
  assert(seen.length >= 3);
  for (const s of seen) assertEquals(s, [A1]);
  const d2 = await call(h, "t.hqA.sig", { kind: "detail", from: "2026-11-01", to: "2026-11-30", store_ids: [B1] });
  assertEquals(d2.json.items, []); assertEquals(d2.json.delivery, { by_store: [] });
  // 指定なし: 有効な自法人の店舗だけ（閉店済み A2 は、制限なしの人の既定と同じく入らない）
  seen.length = 0;
  await call(h, "t.hqA.sig", { kind: "detail_items", from: "2026-11-01", to: "2026-11-30" });
  assertEquals(seen[0], [A1]);
  seen.length = 0;
  await call(h, "t.ceo.sig", { kind: "detail_items", from: "2026-11-01", to: "2026-11-30" });
  assertEquals([...seen[0]].sort(), [A1, B1, Z1]);          // 制限なしは従来どおり（有効な全店）
  seen.length = 0;
  await call(h, "t.ceo.sig", { kind: "detail_items", from: "2026-11-01", to: "2026-11-30", store_ids: [B1] });
  assertEquals(seen[0], [B1]);                                // 制限なしは指定どおり（従来どおり）
});

// ---------- ④ 許可ゼロ ----------
Deno.test("④許可ゼロ（許可の法人が public に無い）: 空（形は従来の空応答と同じ）", async () => {
  setWorld();
  const s = await sum, hm = await home, rv = await rsv;
  const a = await call(s, "t.teamghost.sig", { kind: "pl", ...P });
  assertEquals(a.status, 200); assertEquals(a.json.rows, []); assertEquals(a.json.kind, "pl");
  const b = await call(s, "t.teamghost.sig", { kinds: ["pl", "media"], ...P });
  assertEquals(b.json.results.pl.rows, []); assertEquals(b.json.results.media.rows, []);
  const c = await call(s, "t.teamghost.sig", { kind: "detail", from: "2026-11-01", to: "2026-11-30" });
  assertEquals(c.json.items, []);
  const d = await call(hm, "t.teamghost.sig", { as_of: "2026-11-28" });
  assertEquals(d.json.stores, []);
  for (const mode of ["list", "cancel_summary", "monthly_summary"]) {
    const e = await call(rv, "t.teamghost.sig", { mode, from: "2026-11-01", to: "2026-11-30", year_month: "2026-11", limit: 100 });
    assertEquals(e.status, 200, mode); assertEquals(e.json.rows, [], mode);
  }
});
Deno.test("④許可の設定を読めない: 500（全法人を返さない）", async () => {
  const s = await sum, hm = await home, rv = await rsv;
  for (const t of ["info.user_corporations", "info.profiles"]) {
    setWorld({ failTables: [t] });
    const a = await call(s, "t.hqfree.sig", { kind: "pl", ...P });
    assertEquals(a.status, 500); assertEquals(a.json.ok, false); assert(!("rows" in a.json));
    const b = await call(hm, "t.hqfree.sig", {}); assertEquals(b.status, 500);
    const c = await call(rv, "t.hqfree.sig", { mode: "monthly_summary", year_month: "2026-11" }); assertEquals(c.status, 500);
    // マスター・サービス呼び出しは info を読まない
    assertEquals((await call(s, "t.master.sig", { kind: "pl", ...P })).status, 200);
    assertEquals((await call(s, SVC, { kind: "pl", ...P })).status, 200);
  }
});

// ---------- ⑤ 店長（担当店）と法人の併用 ----------
Deno.test("⑤店長: 担当店と法人の共通部分（A1,B1 の担当 × 法人 A → A1 だけ）。許可なしの店長は従来どおり担当店", async () => {
  const h = await sum; setWorld();
  const a = await call(h, "t.tenchoA.sig", { kind: "pl", ...P });
  assertEquals(storesOf(a.json.rows), [A1]);
  assertEquals(a.json.scope.restrictedStoreIds, [A1, B1]); assertEquals(a.json.scope.corporationIds, [CORP_A]);
  assertEquals((await call(h, "t.tenchoA.sig", { kind: "pl", ...P, store_id: B1 })).json.rows, []);
  const p = await call(h, "t.tenchoplain.sig", { kind: "pl", ...P });
  assertEquals(storesOf(p.json.rows), [A1]); assertEquals(Object.keys(p.json.scope).sort(), ["restrictedStoreIds", "role"]);
  // 店長の全社共通行（commonVisible）: 許可なしの店長には従来どおり見える／法人を限定された店長には出ない
  const pe = await call(h, "t.tenchoplain.sig", { kind: "pl_entries", ...P });
  assert(pe.json.rows.some((r: any) => r.id === "pe-common"));
  const pe2 = await call(h, "t.tenchoA.sig", { kind: "pl_entries", ...P });
  assert(!pe2.json.rows.some((r: any) => r.id === "pe-common")); assertEquals(storesOf(pe2.json.rows), [A1]);
  const ln = await call(h, "t.tenchoplain.sig", { kind: "loan", ...P });
  assert(ln.json.rows.some((r: any) => r.id === "ln-common"));
  // 権限なし
  assertEquals((await call(h, "t.staff.sig", { kind: "pl", ...P })).status, 403);
  assertEquals((await call(h, null, { kind: "pl", ...P })).status, 401);
  assertEquals((await call(h, "t.forged.sig", { kind: "pl", ...P })).status, 401);
});

// ---------- keiei-api-home ----------
Deno.test("home: 制限なしは従来どおり全店／法人限定は自法人の店舗と合計だけ／改ざんの余地なし", async () => {
  const h = await home; setWorld();
  const svc = await call(h, SVC, { as_of: "2026-11-28" });
  assertEquals(svc.json.stores.length, 3);   // 有効な店舗（A1, B1, Z1）
  for (const t of UNRESTRICTED) {
    const r = await call(h, t, { as_of: "2026-11-28" });
    assertEquals(r.json, { ...svc.json, scope: { role: r.json.scope.role, restrictedStoreIds: null } }, t);
    assertEquals(Object.keys(r.json.scope).sort(), ["restrictedStoreIds", "role"]);
  }
  const a = await call(h, "t.hqA.sig", { as_of: "2026-11-28", store_id: B1, store_ids: [B1], corporation_id: CORP_B });
  assertEquals(a.json.stores.map((s: any) => s.storeId), [A1]);
  assertEquals(a.json.totals.mtdSales, 2000);       // A1 のぶんだけ（全店なら 6000）
  assertEquals(a.json.scope.corporationIds, [CORP_A]);
  assertEquals((await call(h, "t.teamroleB.sig", { as_of: "2026-11-28" })).json.stores.map((s: any) => s.storeId), [B1]);
  assertEquals((await call(h, "t.tenchoA.sig", { as_of: "2026-11-28" })).json.stores.map((s: any) => s.storeId), [A1]);
  assertEquals((await call(h, "t.tenchoplain.sig", { as_of: "2026-11-28" })).json.stores.map((s: any) => s.storeId), [A1]);
  assertEquals((await call(h, "t.staff.sig", {})).status, 403);
});

// ---------- keiei-api-reservation ----------
Deno.test("reservation: 制限なしは従来どおり／法人限定は自法人の店舗だけ／他法人の store_id は空", async () => {
  const h = await rsv; setWorld();
  const q = { limit: 100, from: "2026-11-01", to: "2026-11-30", year_month: "2026-11" };
  for (const mode of ["list", "cancel_summary", "monthly_summary"]) {
    const svc = await call(h, SVC, { mode, ...q });
    assertEquals(storesOf(svc.json.rows), ALL_STORES, mode);
    for (const t of UNRESTRICTED) {
      const r = await call(h, t, { mode, ...q });
      assertEquals(r.json.rows, svc.json.rows, `${mode}/${t}`);
      assertEquals(Object.keys(r.json.scope).sort(), ["restrictedStoreIds", "role"]);
    }
    const a = await call(h, "t.hqA.sig", { mode, ...q });
    assertEquals(storesOf(a.json.rows), [A1, A2], mode);
    assertEquals(a.json.scope.corporationIds, [CORP_A]);
    const tamper = await call(h, "t.hqA.sig", { mode, ...q, store_id: B1 });
    assertEquals(tamper.status, 200); assertEquals(tamper.json.rows, [], mode);
    const mine = await call(h, "t.hqA.sig", { mode, ...q, store_id: A1 });
    assertEquals(storesOf(mine.json.rows), [A1], mode);
    // 店名での指定（store）でも、他法人なら空
    const byName = await call(h, "t.hqA.sig", { mode, ...q, store: "B一号店" });
    assertEquals(byName.json.rows, [], mode);
    // 担当店 × 法人
    const t = await call(h, "t.tenchoA.sig", { mode, ...q });
    assertEquals(storesOf(t.json.rows), [A1], mode);
    const tPlain = await call(h, "t.tenchoplain.sig", { mode, ...q });
    assertEquals(storesOf(tPlain.json.rows), [A1], mode);
  }
  // 従来どおりの 403（担当外の店舗を、法人の限定が無い店長が指定）
  const forb = await call(h, "t.tenchoplain.sig", { mode: "list", ...q, store_id: B1 });
  assertEquals(forb.status, 403);
  // 予約の明細は、他法人の予約を含まない（totalCount も自法人のぶん）
  const l = await call(h, "t.hqA.sig", { mode: "list", ...q });
  assertEquals(l.json.totalCount, 4); assertNotEquals(l.json.totalCount, 8);
  assertEquals((await call(h, "t.staff.sig", { mode: "list", ...q })).status, 403);
});
