// =============================================================
// recruit-invoice-split — 求人広告の請求書を、内訳シートの店舗ごとの明細に分けて、仕訳の下書きを作り直す（担当D・2026-11-28・社長依頼）
//
// 呼び出し: pg_cron → public.recruit_invoice_split_trigger()（7:05〜23:35 JST の30分ごと）
//   body: { dry_run?: boolean, invoice_id?: string（試し実行だけ: 条件に関係なくこの請求書の分け方を返す） }
// 対象: 設定した取引先の請求書で、対象月が from_month 以降・MF 未登録・取り消しでない・人が明細や下書きを直していない・受け取りから10分以上。
// やること: DB 関数 recruit_invoice_apply_split で明細を入れ替え → 既存の invoice-journal-draft を呼ぶ（MF には何も登録しない。承認は今までどおり人）。
//   請求額がシートと合わないときは分けず、要確認の理由を付ける。シートに対象月がまだ無いときは、次の回にもう一度見る。
// 設定: app_settings.recruit_invoice_split = { enabled, from_month, vendors: { <vendor_id>: "ad"|"fee" }, area_stores: { <エリア>: <store_id> } }
//       シートと固定費は recruit-cost-sync と同じ（app_secrets.recruit_cost_sheet_id / app_settings.recruit_cost_sheet）。
// 認証: service_role（Bearer）か x-notify-secret。
// デプロイ: supabase functions deploy recruit-invoice-split --no-verify-jwt --project-ref uuvsxzhpxtghojoubjcc --yes
// =============================================================
import { createClient } from "npm:@supabase/supabase-js@2";
import { allocate, type CostRow, parseSheet } from "../_shared/recruit-cost-sheet.ts";
import { loadMonth } from "../_shared/recruit-cost-load.ts";
import { invoiceMonth, type Kind, splitInvoice, type StoreRef } from "../_shared/recruit-invoice-split.ts";

const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json" } });
const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const LOCKED = ["approved", "payment_waiting", "paid", "completed"];

function timingSafeEqual(a: string, b: string) {
  if (a.length !== b.length) return false;
  let r = 0; for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}
function authorized(req: Request): boolean {
  const key = (Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "").trim();
  const auth = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (key && auth && timingSafeEqual(auth, key)) return true;
  const secret = (Deno.env.get("NOTIFY_SLACK_SECRET") ?? "").trim();
  const hdr = (req.headers.get("x-notify-secret") ?? "").trim();
  return !!(secret && hdr && timingSafeEqual(secret, hdr));
}

Deno.serve(async (req) => {
  if (!authorized(req)) return json({ ok: false, error: "認証がありません" }, 401);
  const body = await req.json().catch(() => ({}));
  const dry = body.dry_run === true;
  const sb = svc();
  try {
    const [{ data: st }, { data: sheetSt }, { data: fileId }] = await Promise.all([
      sb.from("app_settings").select("value").eq("key", "recruit_invoice_split").maybeSingle(),
      sb.from("app_settings").select("value").eq("key", "recruit_cost_sheet").maybeSingle(),
      sb.from("app_secrets").select("value").eq("key", "recruit_cost_sheet_id").maybeSingle(),
    ]);
    const cfg = (st?.value ?? {}) as { enabled?: boolean; from_month?: string; vendors?: Record<string, Kind>; area_stores?: Record<string, string> };
    const fee = Number((sheetSt?.value as { monthly_fee?: number })?.monthly_fee);
    if (cfg.enabled !== true) return json({ ok: true, skipped: "disabled" });
    const vendorIds = Object.keys(cfg.vendors ?? {});
    if (!vendorIds.length || !cfg.from_month || !fileId?.value || !Number.isInteger(fee)) throw new Error("設定が足りません");

    const { data: ss, error: sErr } = await sb.from("stores").select("id, name").in("id", Object.values(cfg.area_stores ?? {}));
    if (sErr) throw new Error(sErr.message);
    const areaStores: Record<string, StoreRef> = {};
    for (const [area, id] of Object.entries(cfg.area_stores ?? {})) { const s = (ss ?? []).find((x: any) => x.id === id); if (s) areaStores[area] = s as StoreRef; }

    const sel = "id, vendor_id, amount, target_year_month, created_at, mf_journal_id, invoice_status, current_stage, lines_check, journal_draft";
    const one = dry && typeof body.invoice_id === "string";
    let q = sb.from("invoices").select(sel).in("vendor_id", vendorIds);
    q = one ? q.eq("id", body.invoice_id) : q.is("mf_journal_id", null).neq("invoice_status", "cancelled").lt("created_at", new Date(Date.now() - 10 * 60e3).toISOString());
    const { data: invs, error } = await q.order("created_at").limit(50);
    if (error) throw new Error(error.message);

    const sheetCache = new Map<string, CostRow[] | null>();
    const rowsOf = async (month: string) => {
      if (!sheetCache.has(month)) {
        const found = await loadMonth(String(fileId.value).trim(), month);
        if (found.length > 1) throw new Error(`${month} のシートが ${found.length} 枚あります`);
        sheetCache.set(month, found.length ? allocate(parseSheet(found[0]), fee) : null);
      }
      return sheetCache.get(month)!;
    };

    const results: Record<string, unknown>[] = [];
    for (const inv of invs ?? []) {
      const month = invoiceMonth(inv.target_year_month, inv.created_at);
      const kind = cfg.vendors![inv.vendor_id as string];
      const done = (inv.lines_check as any)?.recruit_split;
      if (!one) {
        if (month < cfg.from_month || inv.amount == null || LOCKED.includes(inv.current_stage ?? "")) continue;
        if (done?.status === "split" || (inv.journal_draft as any)?.edited_by_human) continue;
      }
      try {
        const rows = await rowsOf(month);
        if (!rows) { results.push({ id: inv.id, month, result: "sheet_missing" }); continue; }
        const s = splitInvoice(kind, rows, Number(inv.amount), areaStores);
        if (dry) { results.push({ id: inv.id, month, kind, result: s.ok ? "split" : "mismatch", ...s }); continue; }
        if (!s.ok) {
          if (done?.status === "mismatch" && done?.note === s.reason) continue;
          const { error: e } = await sb.rpc("recruit_invoice_mark_mismatch", { p_invoice: inv.id, p_month: `${month}-01`, p_note: s.reason });
          if (e) throw new Error(e.message);
          results.push({ id: inv.id, month, result: "mismatch" }); continue;
        }
        const { data: applied, error: e } = await sb.rpc("recruit_invoice_apply_split", { p_invoice: inv.id, p_month: `${month}-01`, p_lines: s.lines });
        if (e) throw new Error(e.message);
        if (applied !== "split") { results.push({ id: inv.id, month, result: applied }); continue; }
        const { data: secret } = await sb.from("app_secrets").select("value").eq("key", "invoice_intake_secret").maybeSingle();
        const r = await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/invoice-journal-draft`, {
          method: "POST",
          headers: { "Content-Type": "application/json", apikey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, Authorization: `Bearer ${Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")}` },
          body: JSON.stringify({ secret: secret?.value, invoice_id: inv.id }),
        });
        results.push({ id: inv.id, month, result: "split", draft_status: r.status });
      } catch (e) {
        console.error("recruit-invoice-split", inv.id, e);
        results.push({ id: inv.id, month, result: "error", error: e instanceof Error ? e.message : String(e) });
      }
    }
    return json({ ok: true, dry_run: dry, results });
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error("recruit-invoice-split", msg);
    return json({ ok: false, error: msg }, 500);
  }
});
