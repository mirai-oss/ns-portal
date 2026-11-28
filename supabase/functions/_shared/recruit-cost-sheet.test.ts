import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import { allocate, areaOf, parseSheet, previousMonthJst, sheetMonth, type Sheet } from "./recruit-cost-sheet.ts";

// 金額は試験用の作り物
const sheet = (rows: Sheet["rows"], total: number | string): Sheet => ({
  name: "20301",
  rows: [["内訳　20300101_20300131"], [], ["求人", "都道府県", "市区町村", "企業名", "作成日", "費用", "雇用形態"], ...rows, [null, null, null, "合計", null, total]],
});
const row = (company: string, city: string, cost: number | string, form: string) => ["求人A", "東京都", city, company, "2030年1月1日", cost, form];

Deno.test("月: 見出しの期間を優先し、無ければシート名", () => {
  assertEquals(sheetMonth(sheet([], 0)), "2030-01");
  assertEquals(sheetMonth({ name: "20309", rows: [["見出し"]] }), "2030-09");
  assertEquals(sheetMonth({ name: "203012", rows: [] }), "2030-12");
  assertEquals(sheetMonth({ name: "メモ", rows: [] }), null);
});

Deno.test("エリア: 店舗名 → 市区町村の順。分からなければ null", () => {
  assertEquals(areaOf("会社　匠味　新横浜店", "横浜市, 港北区"), "新横浜");
  assertEquals(areaOf("会社　匠味", "川崎市, 川崎区"), "川崎");
  assertEquals(areaOf("会社 鳥一代芝店", "東京, 港区"), "芝");
  assertEquals(areaOf("会社 本店", "東京, 港区"), "本店");
  assertEquals(areaOf("会社 別の店", "札幌市"), null);
});

Deno.test("読み取り: 同じエリア・区分はまとめ、固定費を割合で按分して合計が合う", () => {
  const ads = parseSheet(sheet([
    row("会社 鳥一代 恵比寿店", "東京, 渋谷区", "¥1,000", "アルバイト・パート"),
    row("会社 鳥一代 恵比寿店", "東京, 渋谷区", 1000, "アルバイト・パート"),
    row("会社 鳥一代 恵比寿店", "東京, 渋谷区", 1000, "正社員"),
  ], "¥3,000"));
  const out = allocate(ads, 100);
  assertEquals(out.map((o) => [o.area, o.form_key, o.ad, o.amount]), [["恵比寿", "al", 2000, 2067], ["恵比寿", "shain", 1000, 1033]]);
  assertEquals(out.reduce((s, o) => s + o.amount, 0), 3100);
});

Deno.test("合計が合わない・分からない店舗・合計の行が無いときは、例外", () => {
  assertThrows(() => parseSheet(sheet([row("会社 本店", "東京, 港区", 10, "正社員")], 11)), Error, "合いません");
  assertThrows(() => parseSheet(sheet([row("会社 別の店", "札幌市", 10, "正社員")], 10)), Error, "分かりません");
  assertThrows(() => parseSheet({ name: "x", rows: [["求人", "市区町村", "企業名", "費用", "雇用形態"]] }), Error, "合計");
});

Deno.test("前の月（日本時間）", () => {
  assertEquals(previousMonthJst(new Date("2030-01-10T00:00:00Z")), "2029-12");
  assertEquals(previousMonthJst(new Date("2030-02-28T16:00:00Z")), "2030-02"); // 日本時間では 3/1
});
