// 2026-09-23新設：ユーザー報告「請求書を削除しようとすると削除に失敗しました」への根本対応。
// 従来のdeleteInvoiceRecord（invoices.html）はクライアントの自分のJWTのまま複数テーブルへ
// 直接DELETE/PATCHを送っていたが、invoice_attachments・invoice_comments（証憑・コメント）は
// RLSがSELECTしか許可しておらず（invoice_can_access()での閲覧のみ・書き込みはEdge Function/
// RPC経由という設計。invoice_commentsも実際はinvoice_add_commentというSECURITY DEFINER RPC
// 経由でしか投稿できない）、クライアント直接のDELETEは常にRLSで弾かれて0件のまま無言で
// 失敗していた（呼び出し側が`.catch(()=>{})`で握りつぶしていたため気づけなかった）。
// 結果、後続のinvoices本体のDELETEが「invoice_attachmentsがまだ参照している」という
// 一見矛盾したエラーになっていた。
// ここでservice_role（RLSを完全にバイパスできる）を使い、削除前クリーンアップ（外部キー
// 解消）から本体削除までを1つの権限で確実に行う。invoices.attachment_idの循環参照解消も
// あわせて含む。
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

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return json({ error: "POSTのみ対応" }, 405);

  let body: any;
  try { body = await req.json(); } catch { return json({ error: "JSONの読み取りに失敗しました" }, 400); }
  const invoiceId = body?.invoice_id;
  if (!invoiceId) return json({ error: "invoice_idは必須です" }, 400);

  const uc = userClient(req);
  const { data: canAccess, error: accessErr } = await uc.rpc("invoice_can_access");
  if (accessErr || canAccess !== true) return json({ error: "権限がありません" }, 403);

  const { data: inv, error: invErr } = await uc.from("invoices").select("id").eq("id", invoiceId).maybeSingle();
  if (invErr) return json({ error: "確認に失敗しました: " + invErr.message }, 500);
  if (!inv) return json({ error: "対象が見つからないか権限がありません" }, 403);

  const db = svc();
  try {
    // ①invoices.attachment_id（代表添付を指す循環参照の列）を先にnullへ戻す
    await db.from("invoices").update({ attachment_id: null }).eq("id", invoiceId);
    // ②他テーブルからの参照を外す（本部タスク・売上入金の記録自体は残す）
    await db.from("hq_tasks").update({ exception_invoice_id: null }).eq("exception_invoice_id", invoiceId);
    await db.from("ar_receivables").update({
      linked_invoice_id: null, mf_journal_id: null, mf_journal_number: null, mf_journal_created_at: null,
    }).eq("linked_invoice_id", invoiceId);
    // ③この請求書に紐づく記録を削除
    await db.from("invoice_pl_reflections").delete().eq("invoice_id", invoiceId);
    await db.from("vendor_bank_account_change_requests").delete().eq("invoice_id", invoiceId);
    await db.from("invoice_attachments").delete().eq("invoice_id", invoiceId);
    await db.from("invoice_comments").delete().eq("invoice_id", invoiceId);
    await db.from("payroll_journal_records").delete().eq("invoice_id", invoiceId);
    // ④本体を削除
    const { error: delErr } = await db.from("invoices").delete().eq("id", invoiceId);
    if (delErr) return json({ error: "削除に失敗しました: " + delErr.message }, 500);
    return json({ success: true });
  } catch (e) {
    return json({ error: "予期しないエラー: " + String((e as Error)?.message ?? e) }, 500);
  }
});
