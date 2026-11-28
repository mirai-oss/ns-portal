// 求人広告の請求書（広告費＝税込で届く／固定費）を、内訳シートの店舗ごとの明細（税抜＋税）に分ける計算。
import type { CostRow } from "./recruit-cost-sheet.ts";

export type Kind = "ad" | "fee"; // ad=広告費の請求書 / fee=毎月の固定費の請求書
export type StoreRef = { id: string; name: string };
export type SplitLine = { store_id: string; store_name: string; amount: number; tax_amount: number };
/** 会計上の按分ルール: この エリア×区分 の金額は、1店舗に入れず、重みの割合で複数の店舗に分ける。 */
export type ShareRule = { area: string; form_key: "al" | "shain"; shares: { store: StoreRef; weight: number }[] };
export type Split = { ok: true; lines: SplitLine[]; subtotal: number; tax: number } | { ok: false; reason: string };

/** 端数は余りの大きい順に 1 円ずつ配り、合計を必ず total にする。 */
function prorate(weights: number[], total: number): number[] {
  const sum = weights.reduce((a, b) => a + b, 0);
  const base = weights.map((w) => Math.floor((total * w) / sum));
  let rest = total - base.reduce((a, b) => a + b, 0);
  for (const i of weights.map((w, i) => i).sort((i, j) => ((total * weights[j]) % sum) - ((total * weights[i]) % sum) || i - j)) {
    if (rest <= 0) break;
    base[i]++; rest--;
  }
  return base;
}

/** rows は allocate(シート, 固定費) の結果。invoiceAmount は請求書の税込金額。合わなければ分けない。
 *  rules に当たる行は重みで分け（端数は余りの大きい順。同じなら先に書いた店舗）、当たらない行はエリアの店舗へ。 */
export function splitInvoice(kind: Kind, rows: CostRow[], invoiceAmount: number, areaStores: Record<string, StoreRef>, rules: ShareRule[] = []): Split {
  const byStore = new Map<string, { store: StoreRef; amount: number }>();
  const add = (store: StoreRef, amount: number) => {
    const v = byStore.get(store.id) ?? { store, amount: 0 };
    v.amount += amount;
    byStore.set(store.id, v);
  };
  for (const r of rows) {
    const value = kind === "ad" ? r.ad : r.amount - r.ad;
    const rule = rules.find((x) => x.area === r.area && x.form_key === r.form_key);
    if (rule) {
      if (!rule.shares.length || rule.shares.some((s) => !(s.weight > 0))) return { ok: false, reason: `エリア「${r.area}」の按分の設定が正しくありません` };
      prorate(rule.shares.map((s) => s.weight), value).forEach((a, i) => add(rule.shares[i].store, a));
      continue;
    }
    const store = areaStores[r.area];
    if (!store) return { ok: false, reason: `エリア「${r.area}」の店舗が設定されていません` };
    add(store, value);
  }
  const list = [...byStore.values()].filter((v) => v.amount > 0).sort((a, b) => b.amount - a.amount || a.store.name.localeCompare(b.store.name));
  const subtotal = list.reduce((s, v) => s + v.amount, 0);
  const expected = Math.round(subtotal * 1.1);
  if (!list.length || Math.abs(invoiceAmount - expected) > 2) {
    return { ok: false, reason: `請求額（税込 ${invoiceAmount.toLocaleString("ja-JP")}円）が、内訳シートの税込（${expected.toLocaleString("ja-JP")}円）と合いません` };
  }
  const tax = invoiceAmount - subtotal;
  const taxes = prorate(list.map((v) => v.amount), tax);
  return { ok: true, subtotal, tax, lines: list.map((v, i) => ({ store_id: v.store.id, store_name: v.store.name, amount: v.amount, tax_amount: taxes[i] })) };
}

/** 請求の対象月（YYYY-MM）。読み取れていなければ、受け取った日（日本時間）の前の月。 */
export function invoiceMonth(targetYearMonth: string | null, createdAt: string): string {
  if (targetYearMonth && /^\d{4}-\d{2}/.test(targetYearMonth)) return targetYearMonth.slice(0, 7);
  const j = new Date(new Date(createdAt).getTime() + 9 * 3600e3);
  const d = new Date(Date.UTC(j.getUTCFullYear(), j.getUTCMonth() - 1, 1));
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}`;
}
