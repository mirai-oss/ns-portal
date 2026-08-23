// 請求書メール返信送信 Edge Function（即時ルート）
// docs/実装指示書_請求書メール管理Phase1_2026-08-23.md §4.5 に基づき新規作成（2026-08-23）
//
// 呼び出し元: invoices.html（確認画面で「送信する」を押した直後、invoice_queue_reply RPC成功の
//   レスポンスで受け取った outbox_id を渡して即座に呼ぶ）。
// 認可: 呼び出し元ユーザーのJWTをそのまま転送し、RLS(invoice_can_access())でoutbox行を読めるかを
//   確認する（=処理権限者のみ。他人のoutboxは読めない）。
//
// 処理: outbox行(queued)を読む → GAS invoice-intake プロジェクトのトークン認証付きWebAppへPOST
//   （GmailAppが元スレッドへ差出人=info@ns0314.comで返信）→ 成功ならoutboxをsent・監査ログに
//   action='reply_sent'で本文込み記録 → 失敗時はoutboxを触らずエラーを返す（statusはqueuedのまま
//   ＝GAS側の5分トリガー保険ルートがinvoice_outbox_pull_queued経由で拾って再送する二段構え）
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
  try { body = await req.json(); } catch (_) { return json({ error: "JSONの読み取りに失敗しました" }, 400); }
  const outboxId = body?.outbox_id;
  if (!outboxId) return json({ error: "outbox_idは必須です" }, 400);

  // 呼び出し元ユーザーの権限でoutbox行を読む（RLS=invoice_can_access()を経由。他人の・権限外なら0件）
  const uc = userClient(req);
  const { data: ob, error: obErr } = await uc
    .from("invoice_email_outbox")
    .select("id, email_id, body_text, status, queued_by, invoice_emails(from_address, subject, gmail_thread_id, gmail_message_id)")
    .eq("id", outboxId)
    .maybeSingle();
  if (obErr) return json({ error: "確認に失敗しました: " + obErr.message }, 500);
  if (!ob) return json({ error: "対象が見つからないか権限がありません" }, 403);
  if (ob.status !== "queued") return json({ error: "この返信はすでに処理済みです" }, 400);

  const email: any = ob.invoice_emails;
  const gasUrl = Deno.env.get("INVOICE_GAS_WEBAPP_URL");
  const secret = Deno.env.get("INVOICE_INTAKE_SECRET");
  if (!gasUrl || !secret) return json({ error: "送信設定が未完了です（INVOICE_GAS_WEBAPP_URL/INVOICE_INTAKE_SECRET）" }, 500);

  let gasRes: Response;
  try {
    gasRes = await fetch(gasUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        token: secret,
        thread_id: email?.gmail_thread_id ?? "",
        message_id: email?.gmail_message_id ?? "",
        to: email?.from_address ?? "",
        subject: email?.subject ?? "",
        body: ob.body_text,
      }),
    });
  } catch (e) {
    return json({ error: "GASへの送信要求が失敗しました（自動で再送されます）: " + e }, 502);
  }

  const gasJson = await gasRes.json().catch(() => ({} as any));
  if (!gasRes.ok || !gasJson?.success) {
    // outboxはqueuedのまま触らない＝5分トリガーの保険ルートに委ねる
    return json({ error: gasJson?.error || "送信に失敗しました（自動で再送されます）" }, 502);
  }

  const db = svc();
  await db.from("invoice_email_outbox").update({
    status: "sent", sent_at: new Date().toISOString(),
    gmail_sent_message_id: gasJson.sent_message_id ?? null,
  }).eq("id", ob.id);

  await db.from("invoice_audit_logs").insert({
    entity_type: "invoice_email", entity_id: ob.email_id, action: "reply_sent",
    user_id: ob.queued_by, actor_type: "human", note: ob.body_text,
  });

  return json({ success: true });
});
