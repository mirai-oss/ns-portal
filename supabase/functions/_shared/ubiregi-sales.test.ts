import { assertEquals } from "jsr:@std/assert@1";
import { checkRows, lastClosedDate } from "./ubiregi-sales.ts";

// 金額は試験用の作り物
const allowed = { 試験店: "2030-01-01" };
const row = (date: string, values = [2, 1, 0, 0, 100, 110, 60, 0, 50, 0, 0, 0, 0, 0, 0, 0], store = "試験店") => ({ store, date, values });
const now = new Date("2030-01-10T03:00:00Z"); // 日本時間 1/10 12:00

Deno.test("営業が終わっている最後の日: 朝6時より前はもう1日前", () => {
  assertEquals(lastClosedDate(new Date("2030-01-09T20:59:00Z")), "2030-01-08"); // 日本時間 1/10 05:59
  assertEquals(lastClosedDate(new Date("2030-01-09T21:00:00Z")), "2030-01-09"); // 06:00
});

Deno.test("正しい行は問題なし", () => assertEquals(checkRows([row("2030-01-08"), row("2030-01-09")], allowed, now), []));

Deno.test("対象外の店舗・営業中の日・開始前・重複・内訳の不一致・余分な項目・負の数", () => {
  const bad = (r: unknown) => checkRows([r], allowed, now).length > 0;
  assertEquals([
    bad(row("2030-01-08", undefined, "ほかの店")), bad(row("2030-01-10")), bad(row("2029-12-31")), bad(row("2030-02-30")),
    bad(row("2030-01-08", [2, 1, 0, 0, 100, 111, 60, 0, 50, 0, 0, 0, 0, 0, 0, 0])), bad({ ...row("2030-01-08"), matchStore: "ほかの店" }),
    bad(row("2030-01-08", [2, 1, 0, 0, 100, 110, 160, 0, -50, 0, 0, 0, 0, 0, 0, 0])), bad(row("2030-01-08", [1, 2])),
  ], Array(8).fill(true));
  assertEquals(checkRows([row("2030-01-08"), row("2030-01-08")], allowed, now).length, 1);
  assertEquals(checkRows([], allowed, now), ["行がありません"]);
});
