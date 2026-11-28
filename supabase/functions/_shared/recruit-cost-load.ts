// 求人広告費の内訳シートのファイルを取り、対象の月のシートを返す（recruit-cost-sync / recruit-invoice-split で共用）。
import { type Sheet, sheetMonth } from "./recruit-cost-sheet.ts";
import { readSheets } from "./xlsx-lite.ts";

/** 名前（YYYYM / YYYYMM）で探し、無ければ全シートの見出しの期間で探す。 */
export async function loadMonth(fileId: string, month: string): Promise<Sheet[]> {
  const res = await fetch(`https://drive.google.com/uc?export=download&id=${encodeURIComponent(fileId)}`, { redirect: "follow" });
  const buf = new Uint8Array(await res.arrayBuffer());
  if (!res.ok || buf[0] !== 0x50 || buf[1] !== 0x4b) throw new Error(`シートのファイルを読めません（HTTP ${res.status}。共有の設定が変わった可能性があります）`);
  if (buf.length > 10 * 1024 * 1024) throw new Error("シートのファイルが大きすぎます");
  const byName = (n: string) => sheetMonth({ name: n, rows: [] }) === month;
  const named = readSheets(buf, byName).filter((s) => sheetMonth(s) === month);
  return named.length ? named : readSheets(buf, (n) => !byName(n)).filter((s) => sheetMonth(s) === month);
}
