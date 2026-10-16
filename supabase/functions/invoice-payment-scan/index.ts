// 引き落とし・他行振込の自動照合（定期実行）— 担当C・2026-10-16
//
// 振込待ち（会計登録済み・支払方法が「引き落とし」「他行口座から振込」）の請求書を、MFの仕訳（預金からの出金）と照合し、
//   ・金額一致／まとめ払い → 「照合OK（要確認）」候補
//   ・振込先は合うのに金額が合わない → 「金額違い」エラー候補
// を payment_match_candidates に保存し、新しい候補だけ Lark（経理チャンネル）へ通知する。
// 振込済みにするのは人が確認してから（画面の「🔎 引き落とし・他行振込を照合」）。MFには何も書かない。
//
// 認証: invoice_intake_secret。入力: { secret, force?: boolean, dry_run?: boolean }
//   force なし＝「1日1回（日本時間9時以降・前回から20時間以上）」のときだけ実行（invoice-intake のメール取込から毎回呼ばれても二重に動かない）
import { createClient } from "npm:@supabase/supabase-js@2";
import { getValidAccessToken } from "../_shared/mf.ts";
import { larkPost } from "../_shared/cockpit.ts";
import { dateRange, fetchOutflows, matchPayments, type PayItem, type Rule } from "../_shared/payment-match.ts";

const cors: Record<string, string> = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info" };
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });
const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const yen = (n: number) => "¥" + Math.round(n).toLocaleString();
const PORTAL = "https://mirai-oss.github.io/ns-portal/invoices.html";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return json({ error: "POSTのみ対応" }, 405);
  let body: any; try { body = await req.json(); } catch { return json({ error: "JSONの読み取りに失敗しました" }, 400); }
  const db = svc();
  const { data: sr } = await db.from("app_secrets").select("value").eq("key", "invoice_intake_secret").maybeSingle();
  if (!sr?.value || body?.secret !== sr.value) return json({ error: "認証エラー" }, 401);

  // 1日1回の判定（force/dry_run のときは無視）
  if (!body?.force && !body?.dry_run) {
    const jstHour = (new Date().getUTCHours() + 9) % 24;
    if (jstHour < 9 || jstHour >= 22) return json({ success: true, skipped: "実行時間帯ではありません（日本時間9〜22時）" });
    const { data: last } = await db.from("payment_scan_runs").select("started_at").eq("ok", true).order("started_at", { ascending: false }).limit(1);
    if (last?.length && Date.now() - Date.parse(last[0].started_at) < 20 * 3600e3) return json({ success: true, skipped: "本日は実行済みです" });
  }
  const { data: run } = await db.from("payment_scan_runs").insert({ trigger: body?.force ? "force" : (body?.dry_run ? "dry_run" : "auto") }).select("id").single();

  try {
    // 対象の請求書
    const { data: invs, error: ie } = await db.from("invoices")
      .select("id, vendor_id, store_id, amount, due_date, journal_draft, vendor:vendors(name)")
      .not("mf_journal_id", "is", null).in("payment_status", ["wait", "csv", "processing"]).limit(500);
    if (ie) throw new Error("請求書の取得に失敗: " + ie.message);
    const vendorIds = [...new Set((invs ?? []).map((i: any) => i.vendor_id).filter(Boolean))];
    const accByVendor = new Map<string, any[]>();
    if (vendorIds.length) {
      const { data: accs } = await db.from("vendor_bank_accounts").select("vendor_id, store_id, payment_method").in("vendor_id", vendorIds).eq("is_current", true);
      for (const a of accs ?? []) { const l = accByVendor.get(a.vendor_id) ?? []; l.push(a); accByVendor.set(a.vendor_id, l); }
    }
    const methodOf = (r: any) => { const cur = accByVendor.get(r.vendor_id) ?? []; const a = cur.find((x) => r.store_id && x.store_id === r.store_id) || cur.find((x) => !x.store_id) || (cur.length === 1 ? cur[0] : null); return a ? (a.payment_method || "bank_transfer") : null; };
    const targets = (invs ?? []).filter((r: any) => ["direct_debit", "other_bank_transfer"].includes(methodOf(r) ?? ""));
    const byTenant = new Map<string, any[]>();
    for (const r of targets) { const t = r.journal_draft?.tenant_id || "default"; const l = byTenant.get(t) ?? []; l.push(r); byTenant.set(t, l); }
    const nameOf = new Map<string, string>(targets.map((r: any) => [r.id, r.vendor?.name ?? "（不明）"]));

    const { data: conf } = await db.from("payment_match_candidates").select("journal_id").eq("status", "confirmed");
    const usedJ = new Set((conf ?? []).map((x: any) => x.journal_id));
    const created: any[] = []; const errors: string[] = [];
    for (const [tenant, rs] of byTenant) {
      try {
        const items: PayItem[] = rs.map((r: any) => ({ invoice_id: r.id, vendor_id: r.vendor_id, vendor_name: r.vendor?.name ?? "", amount: Number(r.amount) || 0, due_date: r.due_date, method: methodOf(r) ?? undefined }));
        const range = dateRange(items, 5, 14);
        const { accessToken } = await getValidAccessToken(tenant);
        const fo = await fetchOutflows(accessToken, range.start, range.end);
        if ("error" in fo) { errors.push(`${tenant}: ${fo.error}`); continue; }
        const { data: rl } = await db.from("payment_match_rules").select("vendor_id, pattern").eq("tenant_id", tenant);
        const cands = matchPayments(items, fo.outflows.filter((o) => !usedJ.has(o.journal_id)), (rl ?? []) as Rule[]);
        for (const c of cands) {
          const key = [c.kind, tenant, c.journal_id, [...c.invoice_ids].sort().join(",")].join("|");
          if (body?.dry_run) { created.push({ ...c, tenant, cand_key: key }); continue; }
          const { data: ex } = await db.from("payment_match_candidates").select("id").eq("cand_key", key).maybeSingle();
          if (ex) continue;   // 既に出した候補（確認済み・却下済み・通知済み）は繰り返さない
          const { error: insErr } = await db.from("payment_match_candidates").insert({ cand_key: key, kind: c.kind, tenant_id: tenant, invoice_ids: c.invoice_ids, journal_id: c.journal_id, transaction_date: c.transaction_date, outflow_amount: c.outflow_amount, invoice_total: c.invoice_total, diff: c.diff, score: c.score, reasons: c.reasons, summary: c.summary, remark: c.remark });
          if (!insErr) created.push({ ...c, tenant, cand_key: key });
        }
      } catch (e) { errors.push(`${tenant}: ${String((e as Error)?.message ?? e)}`); }
    }

    // もう振込待ちではない請求書だけの古い候補は片付ける
    if (!body?.dry_run) {
      const pendingIds = new Set(targets.map((r: any) => r.id));
      const { data: oldPend } = await db.from("payment_match_candidates").select("id, invoice_ids").eq("status", "pending");
      const stale = (oldPend ?? []).filter((c: any) => !(c.invoice_ids ?? []).some((i: string) => pendingIds.has(i))).map((c: any) => c.id);
      if (stale.length) await db.from("payment_match_candidates").update({ status: "dismissed", decided_at: new Date().toISOString() }).in("id", stale);
    }

    // Lark通知（新しい候補だけ）
    const label = (c: any) => c.invoice_ids.map((i: string) => nameOf.get(i) ?? "").filter(Boolean).filter((v: string, i: number, a: string[]) => a.indexOf(v) === i).join("・");
    const ok = created.filter((c) => c.kind !== "mismatch");
    const bad = created.filter((c) => c.kind === "mismatch");
    const lines: string[] = [];
    if (ok.length) {
      lines.push(`✅ 照合OK候補 ${ok.length}件（確認して「振込済み」にしてください）`);
      for (const c of ok.slice(0, 15)) lines.push(`・${label(c)} ${yen(c.outflow_amount)}（MF ${c.transaction_date}）${c.kind === "bundle" ? " ※まとめ払い" : ""}${c.score < 75 ? " ※要確認" : ""}`);
    }
    if (bad.length) {
      lines.push(`⚠️ 金額が合わない出金 ${bad.length}件（振込先は一致）`);
      for (const c of bad.slice(0, 15)) lines.push(`・${label(c)} 請求 ${yen(c.invoice_total)} ／ 出金 ${yen(c.outflow_amount)}（差 ${c.diff > 0 ? "+" : ""}${yen(c.diff)}・MF ${c.transaction_date}）`);
    }
    if (errors.length) lines.push(`❗ 一部のMFを確認できませんでした: ${errors.join(" / ")}`);
    let notified = false;
    if (lines.length && !body?.dry_run) {
      notified = await larkPost(db, `【引き落とし・他行振込の自動照合】\n${lines.join("\n")}\n${PORTAL}`);
      if (notified && created.length) await db.from("payment_match_candidates").update({ notified_at: new Date().toISOString() }).in("cand_key", created.map((c) => c.cand_key));
    }
    const summary = { targets: targets.length, tenants: [...byTenant.keys()], ok: ok.length, mismatch: bad.length, errors, notified };
    if (run?.id) await db.from("payment_scan_runs").update({ finished_at: new Date().toISOString(), ok: errors.length === 0, summary }).eq("id", run.id);
    return json({ success: true, ...summary, ...(body?.dry_run ? { preview: created.map((c) => ({ kind: c.kind, vendor: label(c), invoice_total: c.invoice_total, outflow: c.outflow_amount, diff: c.diff, date: c.transaction_date, score: c.score })), message: lines.join("\n") } : {}) });
  } catch (e) {
    if (run?.id) await db.from("payment_scan_runs").update({ finished_at: new Date().toISOString(), ok: false, summary: { error: String((e as Error)?.message ?? e) } }).eq("id", run.id);
    return json({ error: "照合中にエラー: " + String((e as Error)?.message ?? e) }, 500);
  }
});
