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
import { evaluateShiire } from "../_shared/shiire-confirm.ts";

const cors: Record<string, string> = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info" };
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });

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
    const { data: stores } = await db.from("stores").select("id, name, seisan_target, seisan_pl_categories_target");
    let results = evaluateShiire((invs ?? []) as any, (stores ?? []) as any, curYm);
    results = results.filter((r) => (!body?.store_id || r.store_id === body.store_id) && (!body?.year_month || r.ym === body.year_month));
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
