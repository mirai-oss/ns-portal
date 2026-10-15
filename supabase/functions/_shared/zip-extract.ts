// ZIP添付の展開（共通部品・2026-10-15）。invoice-zip-extract（画面の「ZIPを展開する」）と invoice-auto-sales（売上入金メールの自動処理）が使う。
// 2026-10-15: ZIP内のファイル名が日本語（Shift_JIS/CP932）のとき、従来は文字化けして保存されていた（�の連続）。UTF-8でなければCP932として読み直す。
import JSZip from "npm:jszip@3.10.1";

const BUCKET = "invoice-files";
const MAX_ENTRIES = 20;            // ZIP内から取り出すファイル数の上限（暴走防止）
const MAX_ENTRY_BYTES = 15 * 1024 * 1024;

const extOf = (name: string) => (name.split(".").pop() || "").toLowerCase();
const mimeOf = (ext: string): string | undefined => ext === "pdf" ? "application/pdf" : ext === "png" ? "image/png" : (ext === "jpg" || ext === "jpeg") ? "image/jpeg" : undefined;

// UTF-8として正しく読めればそのまま、読めなければShift_JIS(CP932)として読む
export function decodeZipName(bytes: any): string {
  const u: Uint8Array = bytes instanceof Uint8Array ? bytes : Uint8Array.from(bytes as ArrayLike<number>);
  try { return new TextDecoder("utf-8", { fatal: true }).decode(u); } catch { /* CP932へ */ }
  try { return new TextDecoder("shift_jis").decode(u); } catch { return new TextDecoder("utf-8").decode(u); }
}

export async function extractZipAttachment(db: any, att: { id: string; email_id: string | null; invoice_id: string | null; storage_path: string }):
  Promise<{ ok: true; extracted: { id: string; file_name: string }[]; skipped: { file_name: string; reason: string }[] } | { ok: false; error: string; status: number }> {
  const { data: blob, error: dlErr } = await db.storage.from(BUCKET).download(att.storage_path);
  if (dlErr || !blob) return { ok: false, error: "ZIPファイルの取得に失敗しました: " + (dlErr?.message ?? ""), status: 500 };
  let zip: JSZip;
  try {
    zip = await JSZip.loadAsync(await blob.arrayBuffer(), { decodeFileName: decodeZipName as any });
  } catch (e) {
    return { ok: false, error: "ZIPの読み取りに失敗しました（壊れているか非対応の形式です）: " + String(e), status: 400 };
  }
  const extracted: { id: string; file_name: string }[] = [];
  const skipped: { file_name: string; reason: string }[] = [];
  let count = 0;
  for (const entryName of Object.keys(zip.files)) {
    if (count >= MAX_ENTRIES) { skipped.push({ file_name: entryName, reason: `上限（${MAX_ENTRIES}件）に達したためスキップ` }); continue; }
    const entry = zip.files[entryName];
    if (entry.dir) continue;
    const baseName = entryName.split("/").pop() || entryName;
    if (!baseName || baseName.startsWith(".") || entryName.includes("__MACOSX")) continue;
    const ext = extOf(baseName); const mimeType = mimeOf(ext);
    if (!mimeType) { skipped.push({ file_name: baseName, reason: "PDF・画像以外のファイルのためスキップ" }); continue; }
    let bytes: Uint8Array;
    try { bytes = await entry.async("uint8array"); } catch (e) { skipped.push({ file_name: baseName, reason: "展開に失敗: " + String(e) }); continue; }
    if (bytes.length === 0) { skipped.push({ file_name: baseName, reason: "空のファイルのためスキップ" }); continue; }
    if (bytes.length > MAX_ENTRY_BYTES) { skipped.push({ file_name: baseName, reason: "サイズが大きすぎるためスキップ" }); continue; }
    try {
      const hashBuf = await crypto.subtle.digest("SHA-256", bytes);
      const fileHash = Array.from(new Uint8Array(hashBuf)).map((b) => b.toString(16).padStart(2, "0")).join("");
      // 保存キーは英数字のみ（日本語のファイル名はInvalid key）。元のファイル名は invoice_attachments.file_name に残る
      const storagePath = `${att.email_id ? att.email_id : "standalone/" + att.invoice_id}/zip_${crypto.randomUUID()}${(/\.[A-Za-z0-9]{1,10}$/.exec(baseName || "") || [""])[0].toLowerCase()}`;
      const { error: upErr } = await db.storage.from(BUCKET).upload(storagePath, bytes, { contentType: mimeType });
      if (upErr) { skipped.push({ file_name: baseName, reason: "保存に失敗: " + upErr.message }); continue; }
      const { data: newAtt, error: insErr } = await db.from("invoice_attachments").insert({
        email_id: att.email_id, invoice_id: att.invoice_id, file_name: baseName, mime_type: mimeType,
        storage_path: storagePath, file_hash: fileHash, size_bytes: bytes.length, extracted_from_zip_id: att.id,
      }).select("id").single();
      if (insErr) { skipped.push({ file_name: baseName, reason: "登録に失敗: " + insErr.message }); continue; }
      extracted.push({ id: newAtt.id, file_name: baseName });
      count++;
    } catch (e) {
      skipped.push({ file_name: baseName, reason: "予期しないエラー: " + String(e) });
    }
  }
  await db.from("invoice_attachments").update({ zip_extracted_at: new Date().toISOString() }).eq("id", att.id);
  return { ok: true, extracted, skipped };
}
