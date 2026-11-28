import { assert, assertEquals } from "jsr:@std/assert@1";
import { invoiceMonth, splitInvoice } from "./recruit-invoice-split.ts";
import { allocate } from "./recruit-cost-sheet.ts";

// 金額は試験用の作り物
const rows = allocate([{ area: "恵比寿", form_key: "al", ad: 1000 }, { area: "恵比寿", form_key: "shain", ad: 2005 }, { area: "新横浜", form_key: "al", ad: 7 }], 900);
const stores = { 恵比寿: { id: "s1", name: "甲店" }, 新横浜: { id: "s2", name: "乙店" } };

Deno.test("広告費: 店舗ごとの税抜と税。税込の合計は請求額と一致する", () => {
  const s = splitInvoice("ad", rows, Math.round(3012 * 1.1), stores);
  assert(s.ok);
  assertEquals(s.lines.map((l) => [l.store_id, l.amount]), [["s1", 3005], ["s2", 7]]);
  assertEquals(s.lines.reduce((t, l) => t + l.amount + l.tax_amount, 0), 3313);
});

Deno.test("固定費: 広告費の割合で分けた分だけが明細になる", () => {
  const s = splitInvoice("fee", rows, 990, stores);
  assert(s.ok);
  assertEquals(s.lines.reduce((t, l) => t + l.amount, 0), 900);
  assertEquals(s.lines.reduce((t, l) => t + l.amount + l.tax_amount, 0), 990);
});

Deno.test("請求額が合わない・店舗の設定が無いときは分けない（1〜2円の端数は許す）", () => {
  assert(!splitInvoice("ad", rows, 3012, stores).ok);
  assert(!splitInvoice("fee", rows, 1100, stores).ok);
  assert(!splitInvoice("ad", rows, 3313, { 恵比寿: stores.恵比寿 }).ok);
  assert(splitInvoice("ad", rows, 3315, stores).ok);
});

Deno.test("対象月: 読み取れた月を優先し、無ければ受け取った日の前の月（日本時間）", () => {
  assertEquals(invoiceMonth("2030-10-01", "2030-12-05T00:00:00Z"), "2030-10");
  assertEquals(invoiceMonth(null, "2030-12-05T00:00:00Z"), "2030-11");
  assertEquals(invoiceMonth(null, "2029-12-31T16:00:00Z"), "2029-12"); // 日本時間では 1/1
});
