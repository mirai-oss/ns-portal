import { assertEquals } from "jsr:@std/assert@1";
import { planFixedWage, verifyFixedWage, ALL_RULES } from "./wage-fixed.ts";
const all1 = ["1", "1", "1", "1", "1", "1"], all0 = ["0", "0", "0", "0", "0", "0"];
Deno.test("applied: 今のスマレジが適用中なら区分を引き継ぐ", () => {
  const p = planFixedWage({ fixed_ot_state: "applied", fixed_ot_amount: 50000 }, { flag: "1", amount: "30000", flags: ["1", "1", "0", "0", "0", "0"] });
  assertEquals(p.kind, "send"); if (p.kind === "send") assertEquals(p.fixedWage.rules.map((r) => r.ruleType), ["statutoryOvertime", "midnight"]);
});
Deno.test("applied: スマレジに無ければ 6 つ全部", () => {
  const p = planFixedWage({ fixed_ot_state: "applied", fixed_ot_amount: 50000 }, null);
  if (p.kind === "send") assertEquals(p.fixedWage.rules.length, ALL_RULES.length); else throw new Error("send のはず");
});
Deno.test("applied: 金額が無い・不正なら送らない", () => { assertEquals(planFixedWage({ fixed_ot_state: "applied", fixed_ot_amount: null }, null).kind, "refuse"); });
Deno.test("none は付けずに送る", () => { assertEquals(planFixedWage({ fixed_ot_state: "none" }, { flag: "1", amount: "1", flags: all1 }).kind, "plain"); });
Deno.test("unknown: スマレジに固定残業代があれば送らない／無ければこれまでどおり", () => {
  assertEquals(planFixedWage({ fixed_ot_state: "unknown" }, { flag: "1", amount: "30000", flags: all1 }).kind, "refuse");
  assertEquals(planFixedWage({ fixed_ot_state: "unknown" }, { flag: "0", amount: "0", flags: all0 }).kind, "plain");
  assertEquals(planFixedWage({ fixed_ot_state: "unknown" }, null).kind, "plain");
});
Deno.test("照合: 全部一致なら空、違えば項目名", () => {
  const plan = planFixedWage({ fixed_ot_state: "applied", fixed_ot_amount: 50000 }, null);
  assertEquals(verifyFixedWage({ wage: 200000, effective_date: "2027-02-01" }, plan, { wage: 200000, flag: "1", amount: "50000", flags: all1 }), []);
  assertEquals(verifyFixedWage({ wage: 200000, effective_date: "2027-02-01" }, plan, { wage: 200000, flag: "0", amount: "0", flags: all0 }).length > 0, true);
  assertEquals(verifyFixedWage({ wage: 200000, effective_date: "x" }, { kind: "plain" }, { wage: 200000, flag: "1", amount: "30000", flags: all1 }).length > 0, true);
});
