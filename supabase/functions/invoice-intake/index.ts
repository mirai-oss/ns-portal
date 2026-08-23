// 請求書メール取込 Edge Function
// docs/実装指示書_請求書メール管理Phase1_2026-08-23.md §3 に基づき新規作成（2026-08-23）
//
// 呼び出し元: 新規独立GASプロジェクト invoice-intake（shunji.nakayama@ns0314.comアカウント・5分トリガー）。
//   indeed-intake.gsと同じUrlFetchApp+共有シークレット方式。GAS側もこのEdge Functionもservice_role/anon鍵は
//   使わず、app_secretsの invoice_intake_secret のみで認証する（2026-08-21のR6=シークレット平文露出事故の
//   再発防止。値はコード上に一切書かず、GAS側はPropertiesServiceに保存）。
//
// 処理: 共有シークレット検証 → gmail_message_idで重複スキップ（再実行しても増えない）→
//   添付をbase64受信しSHA-256計算 → invoice-filesバケット(非公開)へ保存 → 同hash既存なら
//   invoice_emails.duplicate_suspected を立てる → invoice_emails/invoice_attachments へservice roleでinsert。
//
// 入力(JSON):
//   { secret, gmail_message_id, gmail_thread_id?, from_address?, to_address?, delivered_to?, cc_address?,
//     subject?, received_at?(ISO8601), body_text?, body_html?,
//     attachments?: [{ file_name, mime_type?, size_bytes?, base64 }] }
import { createClient } from "npm:@supabase/supabase-js@2";

const cors: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });

const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const BUCKET = "invoice-files";

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function base64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

// 2026-08-24: Supabase Storage(S3互換)のオブジェクトキーは全角括弧・絵文字・スペース等の
// 一部の文字を受け付けず、日本語のファイル名をそのまま使うと「Invalid key」で保存自体が
// 静かに失敗することが実機で判明。保存パスは拡張子だけを引き継いだ連番に変換し、元のファイル
// 名は invoice_attachments.file_name（表示用）に別途そのまま保存する
function safeStorageFileName(originalName: string, index: number): string {
  const m = /\.[A-Za-z0-9]{1,10}$/.exec(originalName || "");
  const ext = m ? m[0].toLowerCase() : "";
  return `${index}${ext}`;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return json({ error: "POSTのみ対応" }, 405);

  let body: any;
  try {
    body = await req.json();
  } catch (_) {
    return json({ error: "JSONの読み取りに失敗しました" }, 400);
  }

  const db = svc();

  // 共有シークレット検証（app_secretsのみが正。コード直書き禁止）
  const { data: secretRow, error: secretErr } = await db
    .from("app_secrets").select("value").eq("key", "invoice_intake_secret").maybeSingle();
  if (secretErr) return json({ error: "シークレット確認に失敗しました: " + secretErr.message }, 500);
  if (!secretRow?.value || body?.secret !== secretRow.value) {
    return json({ error: "認証エラー" }, 401);
  }

  const gmailMessageId: string = body.gmail_message_id;
  if (!gmailMessageId) return json({ error: "gmail_message_idは必須です" }, 400);

  // 重複スキップ（再実行しても件数不変）。select→insertの2手順だとその間に同じメッセージが
  // 別リクエストで先に登録された場合にunique制約違反(500)になり得るため、upsert(ON CONFLICT DO
  // NOTHING)で一発に行う。ignoreDuplicatesで無視された行はreturning結果に出ないため、その場合は
  // 既存行を読み直す（2026-08-24: 実機のバックフィル再実行で実際にこの競合を確認して修正）
  const { data: upserted, error: upErr } = await db
    .from("invoice_emails")
    .upsert({
      gmail_message_id: gmailMessageId,
      gmail_thread_id: body.gmail_thread_id ?? null,
      from_address: body.from_address ?? null,
      to_address: body.to_address ?? null,
      delivered_to: body.delivered_to ?? null,
      cc_address: body.cc_address ?? null,
      subject: body.subject ?? null,
      body_text: body.body_text ?? null,
      body_html: body.body_html ?? null,
      received_at: body.received_at ?? null,
    }, { onConflict: "gmail_message_id", ignoreDuplicates: true })
    .select("id")
    .maybeSingle();
  if (upErr) return json({ error: "メール登録に失敗しました: " + upErr.message }, 500);

  let emailId: string;
  if (upserted) {
    emailId = upserted.id as string;
  } else {
    const { data: existing, error: existErr } = await db
      .from("invoice_emails").select("id").eq("gmail_message_id", gmailMessageId).single();
    if (existErr || !existing) return json({ error: "重複確認に失敗しました: " + (existErr?.message ?? "not found") }, 500);
    emailId = existing.id as string;

    // 2026-08-24: メールは既に登録済みでも、添付が0件のまま・かつ今回のペイロードに
    // 添付があるなら補完する（自己修復）。原因は取込側のバグ（Outlook等がPDFに
    // Content-Disposition:inlineを付け、includeInlineImages:falseの設定で取りこぼしていた）。
    // GAS側の一括再スキャン（resyncAllLabeledAttachments_oneOff）から呼ばれたときに機能する。
    const attachmentsIn: any[] = Array.isArray(body.attachments) ? body.attachments : [];
    if (attachmentsIn.length) {
      const { count } = await db.from("invoice_attachments").select("id", { count: "exact", head: true }).eq("email_id", emailId);
      if (!count) {
        const saved = await saveAttachments(db, emailId, attachmentsIn);
        if (saved.duplicateSuspected) await db.from("invoice_emails").update({ duplicate_suspected: true }).eq("id", emailId);
        if (saved.failed.length) {
          await db.from("invoice_audit_logs").insert({
            entity_type: "invoice_email", entity_id: emailId, action: "intake", actor_type: "human",
            note: "添付の一部が保存できませんでした: " + saved.failed.map((f) => f.file_name + "(" + f.reason + ")").join(", "),
          });
        }
        return json({
          success: true, duplicate_message: true, email_id: emailId,
          attachments_saved: saved.savedCount, attachments_backfilled: true, attachments_failed: saved.failed,
        });
      }
    }
    return json({ success: true, duplicate_message: true, email_id: emailId });
  }
  const attachments: any[] = Array.isArray(body.attachments) ? body.attachments : [];
  const { duplicateSuspected, savedCount, failed } = await saveAttachments(db, emailId, attachments);

  if (duplicateSuspected) {
    await db.from("invoice_emails").update({ duplicate_suspected: true }).eq("id", emailId);
  }

  await db.from("invoice_audit_logs").insert({
    entity_type: "invoice_email", entity_id: emailId, action: "intake", actor_type: "human",
    new_value: { attachments: savedCount, duplicate_suspected: duplicateSuspected, attachments_failed: failed },
    note: failed.length ? "添付の一部が保存できませんでした: " + failed.map((f) => f.file_name + "(" + f.reason + ")").join(", ") : null,
  });

  return json({ success: true, email_id: emailId, attachments_saved: savedCount, duplicate_suspected: duplicateSuspected, attachments_failed: failed });
});

async function saveAttachments(db: ReturnType<typeof createClient>, emailId: string, attachments: any[]) {
  let duplicateSuspected = false;
  let savedCount = 0;
  const failed: { file_name: string; reason: string }[] = [];

  for (let i = 0; i < attachments.length; i++) {
    const att = attachments[i];
    if (!att?.base64 || !att?.file_name) continue;
    try {
      const bytes = base64ToBytes(att.base64);
      const hash = await sha256Hex(bytes);
      const storagePath = `${emailId}/${safeStorageFileName(att.file_name, i + 1)}`;

      // upsert:true＝再実行（自己修復の再送信等）で同じパスに前回の残骸があっても失敗しない
      const { error: storeErr } = await db.storage.from(BUCKET).upload(storagePath, bytes, {
        contentType: att.mime_type || "application/octet-stream",
        upsert: true,
      });
      if (storeErr) {
        console.error("添付アップロード失敗: " + att.file_name + " " + storeErr.message);
        failed.push({ file_name: att.file_name, reason: storeErr.message });
        continue;
      }

      const { data: dupHash } = await db
        .from("invoice_attachments").select("id").eq("file_hash", hash).limit(1).maybeSingle();
      if (dupHash) duplicateSuspected = true;

      const { error: attErr } = await db.from("invoice_attachments").insert({
        email_id: emailId,
        file_name: att.file_name,
        mime_type: att.mime_type ?? null,
        storage_path: storagePath,
        file_hash: hash,
        size_bytes: att.size_bytes ?? bytes.length,
      });
      if (attErr) {
        console.error("添付レコード登録失敗: " + att.file_name + " " + attErr.message);
        failed.push({ file_name: att.file_name, reason: attErr.message });
        continue;
      }
      savedCount++;
    } catch (e) {
      console.error("添付処理エラー: " + att.file_name + " " + e);
      failed.push({ file_name: att.file_name, reason: String(e) });
    }
  }

  return { duplicateSuspected, savedCount, failed };
}
