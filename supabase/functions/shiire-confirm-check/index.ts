// 仕入高の月次確定の判定（TK-222・設計書_請求書メール自動処理 §12・Sync13）— 担当C・2026-10-17
//
// 経営PLの原価(cost_auto)は infomart-siire の速報。承認済み請求書の仕入高を請求書単位でPLへ入れると二重になるため、
// 「店舗×月の仕入の請求書が全取引先分そろい、すべて承認済み」になった月だけ、レーンPが kd_pl_monthly_summary.cost_auto を請求書合計に置き換える。
// このFunctionはその「確定」を shiire_month_confirmations に書く（置換するのは app_secrets.shiire_confirm_enabled=1 のときだけ・レーンP側）。
//
// 確定の条件（店舗×月）:
//   ① 月が終わっている（対象月 < 今月）
//   ② 承認済みの仕入高の請求書が1件以上ある
//   ③ その店舗×月の仕入高を含む請求書で、承認済みでない（未承認・要対応）ものが無い（取消は除く）
//   ④ 想定の取引先がそろっている: 「その月に請求書が届いている取引先」＋「前月に承認済みの取引先」の全部が、今月承認済み
// 除外: 業務委託精算の店舗(stores.seisan_target)、および精算書ルート(invoices.checks.routes の route='seisan')の行（精算書→PLで入るため二重計上になる。
//       黒霧屋 新横浜のように運営会社と宛先法人が違う「使い分け」店舗の立替分もここに含まれる）。
// 条件が崩れた月（確定後に未承認の請求書が届いた等）は confirmed=false に戻す。
//
// 入力(JSON): { secret, store_id?, year_month?, dry_run? }  認証: invoice_intake_secret（サーバー間）または ログインユーザー(invoice_can_access)
import { createClient } from "npm:@supabase/supabase-js@2";

const cors: Record<string, string> = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info" };
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });
const APPROVED = ["approved", "payment_waiting", "paid", "completed"];

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return json({ error: "POSTのみ対応" }, 405);
  let body: any = {}; try { body = await req.json(); } catch { /* 空でよい */ }
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  let ok = false;
  if (body?.secret) { const { data: sr } = await db.from("app_secrets").select("value").eq("key", "invoice_intake_secret").maybeSingle(); ok = !!sr?.value && body.secret === sr.value; }
  if (!ok) {
    const uc = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } });
    const { data: can, error } = await uc.rpc("invoice_can_access"); if (error || can !== true) return json({ error: "権限がありません" }, 403);
  }
  try {
    const jstNow = new Date(Date.now() + 9 * 3600e3);
    const curYm = jstNow.toISOString().slice(0, 7);
    const sinceDate = new Date(Date.UTC(jstNow.getUTCFullYear(), jstNow.getUTCMonth() - 4, 1)).toISOString().slice(0, 10);   // 直近約4か月
    // 仕入高を含む請求書（取消でない）。承認済み/未承認の両方を見る
    const { data: invs, error: ie } = await db.from("invoices")
      .select("id, vendor_id, vendor_name, target_year_month, current_stage, invoice_status, mf_journal_id, journal_draft, checks, created_at")
      .neq("invoice_status", "cancelled").not("journal_draft", "is", null).gte("created_at", sinceDate).limit(2000);
    if (ie) return json({ error: "請求書の取得に失敗: " + ie.message }, 500);
    // 店舗×月ごとに集計
    type Cell = { approved: Map<string, { name: string; net: number; inv: string[] }>; pending: Map<string, { name: string; inv: string[] }>; received: Set<string> };
    const cells = new Map<string, Cell>();
    const cell = (sid: string, ym: string) => { const k = `${sid}|${ym}`; let c = cells.get(k); if (!c) { c = { approved: new Map(), pending: new Map(), received: new Set() }; cells.set(k, c); } return c; };
    for (const inv of invs ?? []) {
      const d: any = inv.journal_draft; const lines: any[] = Array.isArray(d?.debit_lines) ? d.debit_lines : [];
      const ym = inv.target_year_month ? String(inv.target_year_month).slice(0, 7) : (/^\d{4}-\d{2}/.test(String(d?.transaction_date ?? "")) ? String(d.transaction_date).slice(0, 7) : null);
      if (!ym) continue;
      const routes: any[] = Array.isArray(inv.checks?.routes) ? inv.checks.routes : [];
      const isApproved = APPROVED.includes(inv.current_stage) && !!inv.mf_journal_id;
      for (const l of lines) {
        if (l?.debit?.account !== "仕入高" || !l.store_id) continue;
        if (routes.find((r) => r.store_id === l.store_id)?.route === "seisan") continue;   // 精算書ルートの行は対象外（精算書→PLで入る）
        const c = cell(l.store_id, ym); const vkey = inv.vendor_id ?? inv.vendor_name ?? inv.id; const net = Number(l.debit.net_amount ?? l.debit.amount) || 0;
        c.received.add(vkey);
        if (isApproved) { const v = c.approved.get(vkey) ?? { name: inv.vendor_name ?? "", net: 0, inv: [] }; v.net += net; if (!v.inv.includes(inv.id)) v.inv.push(inv.id); c.approved.set(vkey, v); }
        else { const v = c.pending.get(vkey) ?? { name: inv.vendor_name ?? "", inv: [] }; if (!v.inv.includes(inv.id)) v.inv.push(inv.id); c.pending.set(vkey, v); }
      }
    }
    // 業務委託精算の店舗は除外
    const { data: stores } = await db.from("stores").select("id, name, seisan_target");
    const storeMap = new Map((stores ?? []).map((s: any) => [s.id, s]));
    const prevYm = (ym: string) => { const [y, m] = ym.split("-").map(Number); return new Date(Date.UTC(y, m - 2, 1)).toISOString().slice(0, 7); };
    const results: any[] = [];
    for (const [k, c] of cells) {
      const [sid, ym] = k.split("|");
      if (body?.store_id && body.store_id !== sid) continue; if (body?.year_month && body.year_month !== ym) continue;
      const st: any = storeMap.get(sid); if (!st || st.seisan_target) continue;
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
    if (!body?.dry_run) {
      for (const r of results) {
        const { data: ex } = await db.from("shiire_month_confirmations").select("id, confirmed").eq("store_id", r.store_id).eq("year_month", r.ym).maybeSingle();
        const note = r.confirmed ? `自動判定: 全${r.total}社の請求書が承認済み（税抜合計 ¥${Math.round(r.net).toLocaleString()}）` : `未確定: ${r.reasons.join(" ／ ")}`;
        if (!ex && !r.confirmed && !r.approved) continue;   // 承認済みが無いまま未確定なら記録しない
        const row: any = { store_id: r.store_id, year_month: r.ym, confirmed: r.confirmed, vendor_total: r.total, note, updated_at: new Date().toISOString(), updated_by: "shiire-confirm-check" };
        if (r.confirmed && !(ex && ex.confirmed)) { row.confirmed_at = new Date().toISOString(); row.confirmed_by = "shiire-confirm-check"; }
        await db.from("shiire_month_confirmations").upsert(row, { onConflict: "store_id,year_month" });
      }
    }
    results.sort((a, b) => (a.ym < b.ym ? 1 : -1) || a.store.localeCompare(b.store));
    return json({ success: true, dry_run: !!body?.dry_run, checked: results.length, confirmed: results.filter((r) => r.confirmed).length, results });
  } catch (e) {
    return json({ error: "判定中にエラー: " + String((e as Error)?.message ?? e) }, 500);
  }
});
