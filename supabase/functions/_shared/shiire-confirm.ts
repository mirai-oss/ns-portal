// 仕入高の月次確定の判定ロジック（純粋関数・DBに触らない。shiire-confirm-check から使う）— TK-222 担当C・2026-10-17
export const APPROVED_STAGES = ["approved", "payment_waiting", "paid", "completed"];
export type Inv = { id: string; vendor_id: string | null; vendor_name: string | null; target_year_month: string | null; current_stage: string | null; mf_journal_id: string | null; journal_draft: any; checks: any };
export type StoreInfo = { id: string; name: string; seisan_target?: boolean };
export function evaluateShiire(invs: Inv[], stores: StoreInfo[], curYm: string) {
  type Cell = { approved: Map<string, { name: string; net: number; inv: string[] }>; pending: Map<string, { name: string; inv: string[] }>; received: Set<string> };
  const cells = new Map<string, Cell>();
  const cell = (sid: string, ym: string) => { const k = `${sid}|${ym}`; let c = cells.get(k); if (!c) { c = { approved: new Map(), pending: new Map(), received: new Set() }; cells.set(k, c); } return c; };
  for (const inv of invs) {
    const d: any = inv.journal_draft; const lines: any[] = Array.isArray(d?.debit_lines) ? d.debit_lines : [];
    const ym = inv.target_year_month ? String(inv.target_year_month).slice(0, 7) : (/^\d{4}-\d{2}/.test(String(d?.transaction_date ?? "")) ? String(d.transaction_date).slice(0, 7) : null);
    if (!ym) continue;
    const routes: any[] = Array.isArray(inv.checks?.routes) ? inv.checks.routes : [];
    const isApproved = APPROVED_STAGES.includes(inv.current_stage ?? "") && !!inv.mf_journal_id;
    for (const l of lines) {
      if (l?.debit?.account !== "仕入高" || !l.store_id) continue;
      if (routes.find((r) => r.store_id === l.store_id)?.route === "seisan") continue;   // 精算書ルートの行は対象外（精算書→PLで入る）
      const c = cell(l.store_id, ym); const vkey = inv.vendor_id ?? inv.vendor_name ?? inv.id; const net = Number(l.debit.net_amount ?? l.debit.amount) || 0;
      c.received.add(vkey);
      if (isApproved) { const v = c.approved.get(vkey) ?? { name: inv.vendor_name ?? "", net: 0, inv: [] }; v.net += net; if (!v.inv.includes(inv.id)) v.inv.push(inv.id); c.approved.set(vkey, v); }
      else { const v = c.pending.get(vkey) ?? { name: inv.vendor_name ?? "", inv: [] }; if (!v.inv.includes(inv.id)) v.inv.push(inv.id); c.pending.set(vkey, v); }
    }
  }
  const storeMap = new Map(stores.map((s) => [s.id, s]));
  const prevYm = (ym: string) => { const [y, m] = ym.split("-").map(Number); return new Date(Date.UTC(y, m - 2, 1)).toISOString().slice(0, 7); };
  const results: any[] = [];
  for (const [k, c] of cells) {
    const [sid, ym] = k.split("|");
    const st = storeMap.get(sid); if (!st || st.seisan_target) continue;
    const prev = cells.get(`${sid}|${prevYm(ym)}`);
    const expected = new Set<string>([...c.received, ...(prev ? [...prev.approved.keys()] : [])]);
    const missing = [...expected].filter((v) => !c.approved.has(v));
    const monthOver = ym < curYm;
    const confirmed = monthOver && c.approved.size > 0 && c.pending.size === 0 && missing.length === 0;
    const reasons: string[] = [];
    if (!monthOver) reasons.push("月がまだ終わっていません");
    if (!c.approved.size) reasons.push("承認済みの仕入高がありません");
    if (c.pending.size) reasons.push(`未承認の請求書あり（${[...c.pending.values()].map((v) => v.name).join("・")}）`);
    const nameOf = (v: string) => c.approved.get(v)?.name ?? c.pending.get(v)?.name ?? prev?.approved.get(v)?.name ?? v;
    if (missing.length) reasons.push(`承認済みになっていない取引先: ${missing.map(nameOf).join("・")}`);
    const net = [...c.approved.values()].reduce((t, v) => t + v.net, 0);
    results.push({ store: st.name, store_id: sid, ym, confirmed, approved: c.approved.size, total: expected.size, net, reasons });
  }
  return results;
}
