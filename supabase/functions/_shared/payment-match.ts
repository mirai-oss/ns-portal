// 引き落とし・他行振込の照合ロジック（mf-journal の手動照合と、invoice-payment-scan の定期実行で共通に使う）
// MFには何も書かない（読み取りのみ）。
import { mfFetch } from "./mf.ts";

export type PayItem = { invoice_id: string; vendor_id?: string | null; vendor_name: string; amount: number; due_date?: string | null; method?: string };
export type Rule = { vendor_id: string; pattern: string };
export type Outflow = { journal_id: string; transaction_date: string; amount: number; account: string; sub: string; partner: string; remark: string; summary: string };

const DAY = 86400e3;
export const norm = (t: unknown) => String(t ?? "").normalize("NFKC").replace(/株式会社|有限会社|合同会社|[(（]?(株|有|カ|ユ|合)[)）]/g, "").replace(/\s+/g, "").toLowerCase();
// 覚えさせるときの名前：数字・日付・記号を除いた摘要の核
export const rulePatternOf = (remark: string) => norm(remark).replace(/[0-9０-９]+(年|月|日|分)?/g, "").replace(/[\/\-・,、.。:：]/g, "").slice(0, 40);
const isDeposit = (n: string) => /預金|当座/.test(n ?? "");

export async function fetchOutflows(accessToken: string, startD: string, endD: string): Promise<{ outflows: Outflow[]; searched: number } | { error: string; detail?: unknown }> {
  const journals: any[] = [];
  for (let page = 1; page <= 10; page++) {
    const r = await mfFetch(`/api/v3/journals?start_date=${startD}&end_date=${endD}&per_page=500&page=${page}`, accessToken);
    const dj = await r.json();
    if (!r.ok) return { error: "仕訳履歴の取得に失敗しました", detail: dj };
    const list = dj.journals ?? [];
    journals.push(...list);
    if (list.length < 500) break;
  }
  const outflows: Outflow[] = [];
  for (const j of journals) for (const br of j.branches ?? []) {
    const d = br.debitor, c = br.creditor;
    if (!c || !isDeposit(c.account_name) || !(Number(c.value) > 0)) continue;
    const side = (s: any) => s ? `${s.account_name ?? "?"}${s.sub_account_name ? "/" + s.sub_account_name : ""} ${(s.value ?? 0).toLocaleString()}円` : "—";
    outflows.push({
      journal_id: String(j.id), transaction_date: j.transaction_date, amount: Number(c.value),
      account: d?.account_name ?? "", sub: d?.sub_account_name ?? "", partner: d?.trade_partner_name ?? "", remark: br.remark ?? "",
      summary: `${side(d)} ／ ${side(c)}`,
    });
  }
  return { outflows, searched: journals.length };
}

// 引き落とし以外（他行口座から振込）は、期日より前の同じ月のうちに振り込まれることがあるため、期日の月の1日から探す
const monthStartMs = (due: string) => { const t = Date.parse(due); if (isNaN(t)) return NaN; const d = new Date(t); return Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), 1); };
const isTransfer = (it: PayItem) => it.method !== "direct_debit";
export function dateRange(items: PayItem[], before: number, after: number) {
  const starts = items.map((i) => { const t = Date.parse(i.due_date ?? ""); if (isNaN(t)) return NaN; return isTransfer(i) ? Math.min(monthStartMs(i.due_date!), t - before * DAY) : t - before * DAY; }).filter((t) => !isNaN(t));
  const dues = items.map((i) => Date.parse(i.due_date ?? "")).filter((t) => !isNaN(t));
  const base = dues.length ? dues : [Date.now()];
  return {
    start: new Date((starts.length ? Math.min(...starts) : Math.min(...base)) - 3 * DAY).toISOString().slice(0, 10),
    end: new Date(Math.min(Math.max(...base) + after * DAY + 5 * DAY, Date.now() + DAY)).toISOString().slice(0, 10),
  };
}

export type Candidate = { kind: "single" | "bundle" | "mismatch"; invoice_ids: string[]; journal_id: string; transaction_date: string; outflow_amount: number; invoice_total: number; diff: number; score: number; reasons: string[]; summary: string; remark: string };

// 出金と請求先の結びつき: 借方の補助科目/取引先 → 摘要 → 覚えさせた名前 の順に強い
function vendorEvidence(o: Outflow, it: PayItem, rules: Rule[]): { pts: number; why: string } | null {
  const vn = norm(it.vendor_name);
  const sub = norm(o.sub), par = norm(o.partner), rem = norm(o.remark);
  if (vn && ((sub && (sub.includes(vn) || vn.includes(sub))) || (par && (par.includes(vn) || vn.includes(par))))) return { pts: 25, why: "借方の補助科目/取引先が請求先と一致" };
  for (const r of rules) if (it.vendor_id && r.vendor_id === it.vendor_id && r.pattern && (rem.includes(r.pattern) || sub.includes(r.pattern))) return { pts: 30, why: "覚えさせた名前に一致" };
  if (vn && rem.includes(vn)) return { pts: 15, why: "摘要に請求先名を含む" };
  return null;
}

export function matchPayments(items: PayItem[], outflows: Outflow[], rules: Rule[], before = 5, after = 14): Candidate[] {
  const out: Candidate[] = [];
  const dateOk = (o: Outflow, it: PayItem) => {
    const due = Date.parse(it.due_date ?? ""), t = Date.parse(o.transaction_date); if (isNaN(due) || isNaN(t)) return { ok: true, near: false };
    const diff = Math.round((t - due) / DAY);
    // 他行口座から振込: 期日の月の1日〜期日（＋after日）に出金されていればよい。同じ月内なら「近い」扱い（金額違いのエラー対象）
    if (isTransfer(it)) { const ms = monthStartMs(it.due_date!); const inMonth = t >= ms && diff <= after; return { ok: inMonth || (diff >= -before && diff <= after), near: inMonth }; }
    return { ok: diff >= -before && diff <= after, near: Math.abs(diff) <= 3 };
  };
  const singleUsed = new Set<string>();   // 1件の請求書にぴったり合った出金
  // ① 単独一致
  for (const it of items) for (const o of outflows) {
    if (o.amount !== it.amount) continue;
    const dt = dateOk(o, it); if (!dt.ok) continue;
    let score = 50; const reasons = ["金額が一致（預金からの出金）"];
    const ev = vendorEvidence(o, it, rules); if (ev) { score += ev.pts; reasons.push(ev.why); }
    if (/買掛金|未払金|未払費用/.test(o.account)) { score += 10; reasons.push(`借方が${o.account}`); }
    if (dt.near) { score += 15; reasons.push("日付が期日に近い"); } else score += 5;
    out.push({ kind: "single", invoice_ids: [it.invoice_id], journal_id: o.journal_id, transaction_date: o.transaction_date, outflow_amount: o.amount, invoice_total: it.amount, diff: 0, score, reasons, summary: o.summary, remark: o.remark });
    if (ev) singleUsed.add(o.journal_id);
  }
  // ② まとめ払い・③ 金額違い: 請求先が結びついた出金だけ対象
  for (const o of outflows) {
    if (singleUsed.has(o.journal_id)) continue;
    const byVendor = new Map<string, { it: PayItem; pts: number; why: string }[]>();
    for (const it of items) { const ev = vendorEvidence(o, it, rules); if (!ev || !dateOk(o, it).ok) continue; const k = it.vendor_id ?? norm(it.vendor_name); const l = byVendor.get(k) ?? []; l.push({ it, pts: ev.pts, why: ev.why }); byVendor.set(k, l); }
    for (const [, list] of byVendor) {
      if (list.some((x) => x.it.amount === o.amount)) continue;
      // 合計が出金額に一致する組み合わせ（12件まで）
      const arr = list.slice(0, 12); let found: typeof arr[] = [];
      for (let m = 3; m < (1 << arr.length) && found.length < 3; m++) {
        if ((m & (m - 1)) === 0) continue;   // 1件だけの組み合わせは①で見る
        let sum = 0; for (let b = 0; b < arr.length; b++) if (m & (1 << b)) sum += arr[b].it.amount;
        if (sum === o.amount) found.push(arr.filter((_, b) => m & (1 << b)));
      }
      if (found.length) {
        for (const combo of found) {
          const ev = combo[0];
          out.push({ kind: "bundle", invoice_ids: combo.map((x) => x.it.invoice_id), journal_id: o.journal_id, transaction_date: o.transaction_date, outflow_amount: o.amount, invoice_total: o.amount, diff: 0, score: 60 + ev.pts - (found.length > 1 ? 10 : 0), reasons: [`${combo.length}件の請求書の合計が出金額に一致（まとめ払い）`, ev.why, ...(found.length > 1 ? ["同じ金額になる組み合わせが複数あります。内容を確認してください"] : [])], summary: o.summary, remark: o.remark });
        }
      } else {
        // 振込先は合っているのに金額が合わない → エラー候補（一番近い請求書を示す）
        const near = [...list].sort((a, b) => Math.abs(a.it.amount - o.amount) - Math.abs(b.it.amount - o.amount))[0];
        if (!dateOk(o, near.it).near) continue;   // 誤警報を減らすため、期日に近い出金だけを「金額違い」として扱う
        const total = list.reduce((s, x) => s + x.it.amount, 0);
        const useTotal = list.length > 1 && Math.abs(total - o.amount) < Math.abs(near.it.amount - o.amount);
        const ids = useTotal ? list.map((x) => x.it.invoice_id) : [near.it.invoice_id];
        const inv = useTotal ? total : near.it.amount;
        out.push({ kind: "mismatch", invoice_ids: ids, journal_id: o.journal_id, transaction_date: o.transaction_date, outflow_amount: o.amount, invoice_total: inv, diff: o.amount - inv, score: 40 + near.pts, reasons: [`振込先は一致（${near.why}）ですが、金額が合いません`], summary: o.summary, remark: o.remark });
      }
    }
  }
  return out.sort((a, b) => b.score - a.score);
}
