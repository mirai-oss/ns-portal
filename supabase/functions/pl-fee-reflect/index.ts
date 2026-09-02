// MF仕訳 → PL自動反映（C-7拡張・ラウンド5指示書§6.1／設計書_広告費自動連携_§5・2026-09-01）
//
// ad-cost-reflect（請求書→広告費）と同じ骨組みの科目汎用版。invoices.htmlの
// 「📊 PLへ反映」パネル（仕訳登録済みで、借方に mf_pl_fee_accounts 掲載の勘定科目が
// 含まれる請求書に表示）から呼ばれる。actionは1つ:
//   - "confirm": 勘定科目・対象年月・店舗×金額の割り振りを確定する。
//     body: {invoice_id, account_name, year_month(YYYY-MM-01), allocations:[{store_id,store_name,amount,source}]}
//     呼び出し前にinvoice_can_access()で権限確認。
//     ①invoicesのpl_fee_*列へ確定内容を保存（pl_fee_reflected_atがすでにあれば重複反映として拒否）
//     ②経営ダッシュボードGAS（tori-dashboard・DASH_API_URL）の書き込みaction「writePlFee」を呼び、
//       DB_PL（＋BigQuery）への計上を依頼する。精算対象店舗（stores.seisan_target）の分は
//       GAS側で精算書の明細にも自動追加する想定（A-9の科目機構と同じ入れ物・担当A側の実装）
//
// 【2026-09-01時点の既知の制約】②のGAS側action「writePlFee」はまだ存在しない（担当A・A-8の
// 科目汎用化で実装予定。ラウンド5指示書§6.1の担当A貼り付け文で依頼済み・WORKLOGにも記録）。
// 存在しない間はGAS呼び出しが失敗し、pl_fee_sheet_sync_errorにその旨を記録するが、
// ①（Supabase側の確定記録）自体は正常に完了する＝ad-cost-reflectと同じ「正直な状態」の設計を踏襲する。
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

// tori-dashboardのGAS Web App URL（ad-cost-reflect/dash-sync/index.tsと同じ値。公開リポジトリのapp.jsにも
// 同じ値がある＝秘密情報ではない）
const DASH_API_URL = "https://script.google.com/macros/s/AKfycbwW0qhyEr0-uQWTaLg7MkQhurHq6wMoaOKL7uCCnI_bgnAsGB5-auqG_dm_Q9uJc3Kc/exec";

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
    if (action === "list_target_accounts") {
      const db = svc();
      const { data, error } = await db.from("mf_pl_fee_accounts").select("*").order("account_name");
      if (error) return json({ error: error.message }, 500);
      return json({ success: true, accounts: data ?? [] });
    }

    if (action === "add_target_account") {
      const accountName: string = (body?.account_name ?? "").trim();
      if (!accountName) return json({ error: "勘定科目名は必須です" }, 400);
      const db = svc();
      const { error } = await db.from("mf_pl_fee_accounts").insert({
        account_name: accountName, pl_label: (body?.pl_label ?? "").trim() || accountName,
      });
      if (error) return json({ error: error.message.includes("duplicate") ? "既に登録されています" : error.message }, 500);
      return json({ success: true });
    }

    if (action === "remove_target_account") {
      const id = body?.id;
      if (!id) return json({ error: "idは必須です" }, 400);
      const db = svc();
      const { error } = await db.from("mf_pl_fee_accounts").delete().eq("id", id);
      if (error) return json({ error: error.message }, 500);
      return json({ success: true });
    }

    if (action === "confirm") {
      const invoiceId = body?.invoice_id;
      const accountName: string = (body?.account_name ?? "").trim();
      const yearMonth: string = body?.year_month || "";
      const allocations: any[] = Array.isArray(body?.allocations) ? body.allocations : [];
      if (!invoiceId || !accountName || !/^\d{4}-\d{2}-01$/.test(yearMonth)) {
        return json({ error: "勘定科目・対象年月（YYYY-MM-01）・請求書IDは必須です" }, 400);
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

      const { data: inv, error: invErr } = await uc.from("invoices")
        .select("id, email_id, vendor_name, pl_fee_reflected_at").eq("id", invoiceId).maybeSingle();
      if (invErr) return json({ error: "確認に失敗しました: " + invErr.message }, 500);
      if (!inv) return json({ error: "対象が見つからないか権限がありません" }, 403);
      if (inv.pl_fee_reflected_at) return json({ error: "この請求書は既にPLへ反映済みです（重複反映防止）" }, 409);

      const db = svc();
      const nowIso = new Date().toISOString();
      const rawToken = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
      const { data: userData } = rawToken ? await uc.auth.getUser(rawToken) : { data: { user: null } } as any;

      const { error: updErr } = await uc.from("invoices").update({
        pl_fee_account: accountName,
        pl_fee_year_month: yearMonth,
        pl_fee_allocations: allocations,
        pl_fee_reflected_at: nowIso,
        pl_fee_reflected_by: userData?.user?.id ?? null,
        updated_at: nowIso,
      }).eq("id", invoiceId);
      if (updErr) return json({ error: "反映内容の保存に失敗しました: " + updErr.message }, 500);
      await db.from("invoice_audit_logs").insert({
        entity_type: "invoice_email", entity_id: inv.email_id, action: "pl_fee_reflected", actor_type: "human",
        note: `PLへ反映（科目: ${accountName}／対象: ${yearMonth.slice(0, 7)}／合計: ${total.toLocaleString()}円／${allocations.length}店舗）`,
      });

      let sheetSynced = false, sheetError: string | null = null;
      try {
        const tk = Deno.env.get("AD_COST_WRITE_TOKEN"); // writeAdCostと同じ共有トークン（担当A・A-8の科目汎用action用に流用予定）
        if (!tk) throw new Error("AD_COST_WRITE_TOKEN が未設定です");
        const res = await fetch(DASH_API_URL, {
          method: "POST",
          headers: { "Content-Type": "text/plain;charset=utf-8" },
          body: JSON.stringify({
            action: "writePlFee", token: tk,
            year_month: yearMonth.slice(0, 7), account_name: accountName,
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
        await db.from("invoices").update({ pl_fee_sheet_synced_at: new Date().toISOString(), pl_fee_sheet_sync_error: null }).eq("id", invoiceId);
      } else {
        await db.from("invoices").update({ pl_fee_sheet_sync_error: sheetError }).eq("id", invoiceId);
      }

      return json({ success: true, account_name: accountName, year_month: yearMonth, total, sheet_synced: sheetSynced, sheet_error: sheetError });
    }

    return json({ error: "不明なactionです" }, 400);
  } catch (e) {
    return json({ error: "予期しないエラー: " + String(e) }, 500);
  }
});
