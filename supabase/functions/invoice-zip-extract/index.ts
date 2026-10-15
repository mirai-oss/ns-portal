// ZIP添付の展開 Edge Function（2026-09-04新規・「共通請求書�フロー全面整理」指示書§5-8対応）
//
// 目的は「ZIPを便利に閲覧すること」ではなく、【ZIPの中にある実際の請求書PDFをinvoiceの
// 証憑として正しく紐付けること】。invoices.html「📦 ZIPを展開する」ボタンから呼ばれる。
//
// 処理内容：
//   1. 指定されたinvoice_attachments行（ZIPファイル）をStorageからダウンロード
//   2. ZIP内のファイル一覧を取得し、PDF・画像だけを対象に抽出
//   3. 抽出した各ファイルをStorageへ個別に保存し、invoice_attachments行として新規登録
//      （email_id/invoice_idは元のZIP添付と同じものを引き継ぐ）
//   4. 元のZIP添付行はそのまま残す（監査のため）。展開済みかどうかはzip_extracted_atで判定
//
// これ以降の「どれが本当の請求書か」の判定・確定は、既存のOCR自動入力（invoice-ocr）と
// C-8複数請求書機能（「➕他の請求書」で人が確認して追加）がそのまま使う＝ここでは
// 会計処理・請求書としての確定は一切行わない（あくまで取込前処理）。
// AIが確実に判定できない場合に「勝手に決めない」（指示書§7）のは、抽出後の個別ファイルを
// 人が既存のC-8フロー（AIが複数候補を提示→人が確認して「＋追加」した分だけ確定）で
// 選ぶという、既存の仕組みでそのまま担保される（新規のUIを増やさずに安全性を満たす設計）
//
// 入力(JSON): { attachment_id }  ※対象はmime_typeがzip系、またはファイル名が.zipのもの
// 出力(JSON): { success:true, extracted:[{id,file_name}], skipped:[{file_name,reason}] }
import { createClient } from "npm:@supabase/supabase-js@2";
import { extractZipAttachment } from "../_shared/zip-extract.ts";

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

const BUCKET = "invoice-files";
const MAX_ENTRIES = 20; // ZIP内から取り出すファイル数の上限（暴走防止）
const MAX_ENTRY_BYTES = 15 * 1024 * 1024;

function extOf(name: string): string {
  return (name.split(".").pop() || "").toLowerCase();
}
function mimeOf(ext: string): string | undefined {
  if (ext === "pdf") return "application/pdf";
  if (ext === "png") return "image/png";
  if (ext === "jpg" || ext === "jpeg") return "image/jpeg";
  return undefined;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return json({ error: "POSTのみ対応" }, 405);

  let body: any;
  try { body = await req.json(); } catch { return json({ error: "JSONの読み取りに失敗しました" }, 400); }
  const attachmentId = body?.attachment_id;
  if (!attachmentId) return json({ error: "attachment_idは必須です" }, 400);

  const uc = userClient(req);
  const { data: canAccess, error: accessErr } = await uc.rpc("invoice_can_access");
  if (accessErr || canAccess !== true) return json({ error: "権限がありません" }, 403);

  const db = svc();
  const { data: att, error: attErr } = await db
    .from("invoice_attachments")
    .select("id, email_id, invoice_id, file_name, mime_type, storage_path, zip_extracted_at")
    .eq("id", attachmentId).maybeSingle();
  if (attErr) return json({ error: "取得に失敗しました: " + attErr.message }, 500);
  if (!att) return json({ error: "対象が見つかりません" }, 404);

  const looksZip = extOf(att.file_name) === "zip" || (att.mime_type ?? "").includes("zip");
  if (!looksZip) return json({ error: "この添付はZIPファイルではありません" }, 400);
  if (att.zip_extracted_at) return json({ error: "このZIPは展開済みです" }, 409);

  const r = await extractZipAttachment(db, att);
  if (!r.ok) return json({ error: r.error }, r.status);
  const { extracted, skipped } = r;
  await db.from("mf_sync_logs").insert({
    action: "zip_extract", actor_type: "human",
    detail: { attachment_id: att.id, email_id: att.email_id, invoice_id: att.invoice_id, extracted: extracted.length, skipped: skipped.length },
  });

  return json({ success: true, extracted, skipped });
});
