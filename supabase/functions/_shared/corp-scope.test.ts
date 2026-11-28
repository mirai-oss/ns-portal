// corp-scope.ts の単体テスト。実行: deno test --allow-env supabase/functions/_shared/corp-scope.test.ts
// deno-lint-ignore-file no-explicit-any
import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { applyCorpFilter, corpScopeEcho, NO_CORP_RESTRICTION, resolveCorpScope } from "./corp-scope.ts";
import { createClient } from "./fixtures/fake-supabase.ts";
import { A1, A2, B1, CORP_A, CORP_B, makeTables } from "./fixtures/keiei-world.ts";

function world(failTables: string[] = []) {
  (globalThis as any).__fakeDb = { tables: makeTables(), rpcs: {}, auth: {}, failTables };
  return createClient("http://x", "k") as any;
}

Deno.test("マスターは DB を読まずに制限なし（個人の許可があっても）", async () => {
  const sb = world(["info.user_corporations", "info.profiles"]); // 読もうとしたら失敗する設定
  assertEquals(await resolveCorpScope(sb, "u-master", { isMaster: true }), NO_CORP_RESTRICTION);
});
Deno.test("許可の設定が無い人は制限なし（従来どおり全法人）", async () => {
  const sb = world();
  for (const uid of ["u-ceo", "u-hq-free", "u-tencho-plain", "u-staff", "no-such-user"]) {
    assertEquals(await resolveCorpScope(sb, uid), { corporationIds: null, storeIds: null }, uid);
  }
});
Deno.test("個人の許可 → その法人（public の id に読み替え、法人に属する店舗は閉店済みも含む）", async () => {
  const sb = world();
  const s = await resolveCorpScope(sb, "u-hq-A");
  assertEquals(s.corporationIds, [CORP_A]);
  assertEquals([...s.storeIds!].sort(), [A1, A2]);
});
Deno.test("個人の許可が無く、役職の許可がある → 役職の法人", async () => {
  const sb = world();
  const s = await resolveCorpScope(sb, "u-team-roleB");
  assertEquals(s.corporationIds, [CORP_B]);
  assertEquals(s.storeIds, [B1]);
});
Deno.test("個人の許可と役職の許可の両方 → 個人が優先（役職の許可は見ない）", async () => {
  const sb = world();
  assertEquals((await resolveCorpScope(sb, "u-team-ucOverRole")).corporationIds, [CORP_A]);
});
Deno.test("役職の許可があっても profile が無効なら制限なし（DB の dep_unrestricted と同じ）", async () => {
  const sb = world();
  assertEquals(await resolveCorpScope(sb, "u-team-inactive"), { corporationIds: null, storeIds: null });
});
Deno.test("許可の法人が public に無い → 何も見せない（制限なしへ倒れない）", async () => {
  const sb = world();
  assertEquals(await resolveCorpScope(sb, "u-team-ghost"), { corporationIds: [], storeIds: [] });
});
Deno.test("uid が空 → 何も見せない", async () => {
  assertEquals(await resolveCorpScope(world(), ""), { corporationIds: [], storeIds: [] });
});
Deno.test("許可の設定を読めないときは例外（制限なしへ倒れない）", async () => {
  for (const t of ["info.user_corporations", "info.profiles", "info.role_corporations", "corporations", "stores"]) {
    const sb = world([t]);
    // role_corporations は、役職の許可の経路（u-team-roleB）でだけ読む／stores と corporations は限定された人だけが読む
    const uid = t === "info.role_corporations" ? "u-team-roleB" : "u-hq-A";
    await assertRejects(() => resolveCorpScope(sb, uid), Error, "法人の許可設定を読めませんでした");
  }
});
Deno.test("applyCorpFilter: 制限なしならクエリに触らない／法人の列が有れば法人で、無ければ店舗で絞る", () => {
  const calls: any[] = [];
  const q: any = { in(c: string, v: string[]) { calls.push([c, v]); return q; } };
  applyCorpFilter(q, NO_CORP_RESTRICTION, { storeCol: "store_id", corpCol: "corporation_id" });
  assertEquals(calls, []);
  const corp = { corporationIds: [CORP_A], storeIds: [A1, A2] };
  applyCorpFilter(q, corp, { storeCol: "store_id", corpCol: "corporation_id" });
  assertEquals(calls, [["corporation_id", [CORP_A]]]);
  calls.length = 0;
  applyCorpFilter(q, corp, { storeCol: "store_id" });
  assertEquals(calls, [["store_id", [A1, A2]]]);
  calls.length = 0;
  applyCorpFilter(q, { corporationIds: [], storeIds: [] }, { storeCol: "store_id" });
  assertEquals(calls, [["store_id", []]]);
});
Deno.test("corpScopeEcho: 制限なしは何も足さない", () => {
  assertEquals(corpScopeEcho(NO_CORP_RESTRICTION), {});
  assertEquals(corpScopeEcho({ corporationIds: [CORP_A], storeIds: [] }), { corporationIds: [CORP_A] });
  assert(Object.isFrozen(NO_CORP_RESTRICTION));
});
