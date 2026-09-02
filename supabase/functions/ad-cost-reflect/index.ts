// 請求書 → 広告費の自動反映（C-7②・2026-08-31）
//
// invoices.htmlの「📢 広告費として反映」パネルから呼ばれる。actionは1つ:
//   - "confirm": 媒体・対象年月・店舗×金額の割り振りを確定する。
//     body: {invoice_id, media, year_month(YYYY-MM-01), allocations:[{store_id,store_name,amount,source}]}
//     呼び出し前にinvoice_can_access()で権限確認。
//     ①媒体名をtpl_media_alias（担当G・export系のraw_media→canonical_media正規化表）で正規化
//     ②invoicesのad_cost_*列へ確定内容を保存（ad_cost_reflected_atがすでにあれば重複反映として拒否）
//     ③経営ダッシュボードGAS（tori-dashboard・DASH_API_URL）の書き込みaction「writeAdCost」を呼び、
//       広告費用対効果_管理シートの💾広告費DB＋BigQuery stg_ad_costへの二重書きを依頼する
//
// 【2026-08-31時点の既知の制約】③のGAS側action「writeAdCost」はまだ存在しない（担当A・A-8が実装予定。
// WORKLOGに依頼済み）。存在しない間はGAS呼び出しが失敗し、ad_cost_sheet_sync_errorにその旨を記録するが、
// ①②（Supabase側の確定記録）自体は正常に完了する＝「反映済みだがシートへの反映は未完了」という
// 正直な状態をユーザーに見せる（実際にはシートに反映されていないのに反映済みと偽らないため）。
// A-8が完了したら、sheet_synced_atがnullのままの行を拾って再送するバックフィル処理を別途用意する想定。
import { createClient } from "npm:@supabase/supabase-js@2";

const cors: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });

const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const userClient = (req: Request) =>
  createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });

// tori-dashboardのGAS Web App URL（dash-sync/index.tsと同じ値。公開リポジトリのapp.jsにも同じ値がある＝秘密情報ではない）
const DASH_API_URL = "https://script.google.com/macros/s/AKfycbwW0qhyEr0-uQWTaLg7MkQhurHq6wMoaOKL7uCCnI_bgnAsGB5-auqG_dm_Q9uJc3Kc/exec";

async function normalizeMedia(db: any, raw: string): Promise<string> {
  const trimmed = (raw || "").trim();
  if (!trimmed) return trimmed;
  const { data } = await db.from("tpl_media_alias").select("canonical_media").eq("raw_media", trimmed).maybeSingle();
  return data?.canonical_media || trimmed;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return json({ error: "POSTのみ対応" }, 405);

  let body: any;
  try { body = await req.json(); } catch { return json({ error: "JSONの読み取りに失敗しました" }, 400); }
  const action = body?.action;

  const uc = userClient(req);
  const { data: canAccess, error: accessErr } = await uc.rpc("invoice_can_access");
  if (accessErr || canAccess !== true) return json({ error: "権限がありません" }, 403);

  try {
    if (action === "confirm") {
      const invoiceId = body?.invoice_id;
      const rawMedia: string = (body?.media ?? "").trim();
      const yearMonth: string = body?.year_month || "";
      const allocations: any[] = Array.isArray(body?.allocations) ? body.allocations : [];
      if (!invoiceId || !rawMedia || !/^\d{4}-\d{2}-01$/.test(yearMonth)) {
        return json({ error: "媒体・対象年月（YYYY-MM-01）・請求書IDは必須です" }, 400);
      }
      if (!allocations.length) return json({ error: "店舗×金額の割り振りが0件です" }, 400);
      let total = 0;
      for (const a of allocations) {
        const amt = Number(a.amount);
        if (!a.store_id || !a.store_name || !Number.isFinite(amt) || amt <= 0) {
          return json({ error: "各行に店舗と金額（0円より大きい）を入力してください" }, 400);
        }
        total += amt;
      }

      // 呼び出し元が本当にこの請求書を見れるか（RLS経由で）確認してから二重反映を防ぐ
      const { data: inv, error: invErr } = await uc.from("invoices")
        .select("id, email_id, vendor_name, ad_cost_reflected_at").eq("id", invoiceId).maybeSingle();
      if (invErr) return json({ error: "確認に失敗しました: " + invErr.message }, 500);
      if (!inv) return json({ error: "対象が見つからないか権限がありません" }, 403);
      if (inv.ad_cost_reflected_at) return json({ error: "この請求書は既に広告費へ反映済みです（重複反映防止）" }, 409);

      const db = svc();
      const media = await normalizeMedia(db, rawMedia);
      const nowIso = new Date().toISOString();

      // ①②: Supabase側の確定記録（呼び出しユーザー自身のJWTで更新＝更新者が正しく記録される）
      const { error: updErr } = await uc.from("invoices").update({
        ad_cost_media: media,
        ad_cost_year_month: yearMonth,
        ad_cost_allocations: allocations,
        ad_cost_reflected_at: nowIso,
        updated_at: nowIso,
      }).eq("id", invoiceId);
      if (updErr) return json({ error: "反映内容の保存に失敗しました: " + updErr.message }, 500);
      await db.from("invoice_audit_logs").insert({
        entity_type: "invoice_email", entity_id: inv.email_id, action: "ad_cost_reflected", actor_type: "human",
        note: `広告費へ反映（媒体: ${media}／対象: ${yearMonth.slice(0, 7)}／合計: ${total.toLocaleString()}円／${allocations.length}店舗）`,
      });

      // ③: GAS側の書き込みaction（未実装の間は失敗するのが正常。エラーを記録して正直に返す）
      let sheetSynced = false, sheetError: string | null = null;
      try {
        const tk = Deno.env.get("AD_COST_WRITE_TOKEN");
        if (!tk) throw new Error("AD_COST_WRITE_TOKEN が未設定です（担当AのA-8実装後にSupabase秘密変数へ登録予定）");
        const res = await fetch(DASH_API_URL, {
          method: "POST",
          headers: { "Content-Type": "text/plain;charset=utf-8" },
          body: JSON.stringify({
            action: "writeAdCost", token: tk,
            year_month: yearMonth.slice(0, 7), media,
            allocations: allocations.map((a) => ({ store_name: a.store_name, amount: Number(a.amount) })),
            source_invoice_id: invoiceId, vendor_name: inv.vendor_name,
          }),
        });
        const text = await res.text();
        let j: any;
        try { j = JSON.parse(text); } catch { throw new Error("GASの応答を読めませんでした: " + text.slice(0, 200)); }
        if (!j.ok) throw new Error(j.error || "GAS側で失敗しました");
        sheetSynced = true;
      } catch (e) {
        sheetError = String((e as Error)?.message ?? e);
      }

      if (sheetSynced) {
        await db.from("invoices").update({ ad_cost_sheet_synced_at: new Date().toISOString(), ad_cost_sheet_sync_error: null }).eq("id", invoiceId);
      } else {
        await db.from("invoices").update({ ad_cost_sheet_sync_error: sheetError }).eq("id", invoiceId);
      }

      return json({
        success: true, media, year_month: yearMonth, total,
        sheet_synced: sheetSynced, sheet_error: sheetError,
      });
    }

    return json({ error: "不明なactionです" }, 400);
  } catch (e) {
    return json({ error: "予期しないエラー: " + String(e) }, 500);
  }
});
