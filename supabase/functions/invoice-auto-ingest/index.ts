// 請求書メール自動処理: 取込口 invoice-auto-ingest（担当C・2026-10-13）
//
// 外部から「取引先1社×1か月」の請求書を受け取り、下書きinvoice＋明細行＋PDF証憑を作る。最初の送り手は担当Dの
// インフォマート請求書自動取得ジョブ（Mac mini・infomart-invoice）。メール・アップロードと同じ後続処理（店舗の突合→仕訳下書き→検算→承認待ち）に流す。
//   ・PDF必須（証憑としてMFに添付するため）。PDFが無い送信は受け付けない
//   ・二重処理防止（設計書§10）: ①PDFのSHA-256（既存の添付と同じなら作らない）②取引先（同名の重複登録も含む）×請求番号 ③取引先×対象月×税込合計
//   ・CSV行（取引先×店舗(部門)×税区分）は明細行(invoice_lines)にする。金額=税抜(税込−税額)、税額・税率・店舗コード(インフォマートの部門コード)を保持。
//     店舗コードは必ず resolve_store('infomart', code) で解決する（ハブのstore_noとは06/08が逆）＝invoice-resolve-lines が行う
//   ・合計の検算（送信側と二重）: CSV行の税込合計＝totals.gross（±1円）／税額合計＝totals.tax（±1円）。合わなければ422で受け付けない
// MFには何も登録しない（人が承認画面で承認して初めてMF登録）。
// 認証: 共有シークレット（app_secrets.invoice_intake_secret）。入力(JSON):
// {
//   secret, source:"infomart", vendor_hint:"有限会社染谷商店", target_ym:"2026-09", infomart_invoice_no:"...",
//   due_date?:"2026-10-31", corporation_hint?:"有限会社トーホーエージェンシー",
//   pdf:{ file_name, base64, sha256 },
//   lines:[{ dept_code:"01", tax_category:"課税仕入10%"|"課税仕入8%（軽減）"|"対象外", gross:942060, tax:69782, sub_account?:"㈲染谷商店", vendor_name?:"…" }],
//   totals:{ gross:2486046, tax:184151 }
// }
import { createClient } from "npm:@supabase/supabase-js@2";

const cors: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });
const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const norm = (s: unknown) => String(s ?? "").normalize("NFKC").replace(/\s+/g, "").toLowerCase();
const normCompany = (s: unknown) =>
  norm(s).replace(/株式会社|有限会社|合同会社|合資会社|合名会社|\(株\)|\(有\)|\(合\)|\(同\)|㈱|㈲|㈳|\(株式\)/g, "").replace(/[()（）・\-ー]/g, "");
const sha256Hex = async (bytes: Uint8Array) => Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))).map((b) => b.toString(16).padStart(2, "0")).join("");
const b64ToBytes = (b64: string) => { const bin = atob(b64); const u = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i); return u; };
const rateOf = (cat: string): number | null => {
  const c = norm(cat);
  if (/対象外|非課税|不課税/.test(c)) return 0;
  const m = c.match(/(\d+)%?/);
  return m ? Number(m[1]) : null;
};
const lastDay = (ym: string) => { const [y, m] = ym.split("-").map(Number); return new Date(Date.UTC(y, m, 0)).toISOString().slice(0, 10); };

async function resolveVendor(db: any, name: string) {
  const n = normCompany(name);
  if (!n) return null;
  const [{ data: vendors }, { data: aliases }] = await Promise.all([
    db.from("vendors").select("id, name, name_aliases, default_corporation_id, is_active, created_at").eq("is_active", true),
    db.from("vendor_aliases").select("vendor_id, alias").eq("is_active", true),
  ]);
  const byId = new Map((vendors ?? []).map((v: any) => [v.id, v]));
  const hit = new Set<string>();
  for (const v of vendors ?? []) if (normCompany(v.name) === n || (v.name_aliases ?? []).some((a: string) => normCompany(a) === n)) hit.add(v.id);
  for (const a of aliases ?? []) if (normCompany(a.alias) === n && byId.has(a.vendor_id)) hit.add(a.vendor_id);
  if (!hit.size) return null;
  const cands = [...hit].map((id) => byId.get(id) as any);
  if (new Set(cands.map((c) => normCompany(c.name))).size !== 1) return null; // 名前の違う複数候補＝曖昧
  cands.sort((a, b) => (b.default_corporation_id ? 1 : 0) - (a.default_corporation_id ? 1 : 0) || String(a.created_at).localeCompare(String(b.created_at)));
  const sameNameIds = (vendors ?? []).filter((v: any) => normCompany(v.name) === normCompany(cands[0].name)).map((v: any) => v.id);
  return { id: cands[0].id as string, name: cands[0].name as string, corp: (cands[0].default_corporation_id ?? null) as string | null, sameNameIds: sameNameIds as string[] };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return json({ error: "POSTのみ対応" }, 405);
  let body: any;
  try { body = await req.json(); } catch { return json({ error: "JSONの読み取りに失敗しました" }, 400); }
  const db = svc();
  const { data: sr } = await db.from("app_secrets").select("value").eq("key", "invoice_intake_secret").maybeSingle();
  if (!sr?.value || body?.secret !== sr.value) return json({ error: "認証エラー" }, 401);

  // ---- 入力の検証 ----
  if (body.source !== "infomart") return json({ error: "sourceは'infomart'のみ対応です" }, 400);
  const vendorHint = String(body.vendor_hint ?? "").trim();
  const ym = String(body.target_ym ?? "");
  const invNo = String(body.infomart_invoice_no ?? "").trim();
  if (!vendorHint || !/^\d{4}-\d{2}$/.test(ym) || !invNo) return json({ error: "vendor_hint・target_ym(YYYY-MM)・infomart_invoice_noは必須です" }, 400);
  if (!body.pdf?.base64 || !body.pdf?.file_name) return json({ error: "PDFは必須です（証憑としてMFに添付するため）", code: "pdf_required" }, 422);
  const lines: any[] = Array.isArray(body.lines) ? body.lines : [];
  if (!lines.length) return json({ error: "linesが空です" }, 400);
  const bad = lines.findIndex((l) => !l.dept_code || !Number.isFinite(Number(l.gross)) || !Number.isFinite(Number(l.tax)) || rateOf(l.tax_category) == null);
  if (bad >= 0) return json({ error: `lines[${bad}]の dept_code / gross / tax / tax_category が不正です` }, 400);
  const sumGross = lines.reduce((t, l) => t + Math.round(Number(l.gross)), 0);
  const sumTax = lines.reduce((t, l) => t + Math.round(Number(l.tax)), 0);
  const tGross = Number(body.totals?.gross), tTax = Number(body.totals?.tax);
  if (!Number.isFinite(tGross) || Math.abs(sumGross - tGross) > 1) return json({ error: `明細の税込合計（${sumGross}）がtotals.gross（${body.totals?.gross}）と合いません`, code: "totals_mismatch" }, 422);
  if (Number.isFinite(tTax) && Math.abs(sumTax - tTax) > 1) return json({ error: `明細の税額合計（${sumTax}）がtotals.tax（${body.totals?.tax}）と合いません`, code: "totals_mismatch" }, 422);

  // ---- PDFとハッシュ ----
  const pdfBytes = b64ToBytes(body.pdf.base64);
  const hash = await sha256Hex(pdfBytes);
  if (body.pdf.sha256 && String(body.pdf.sha256).toLowerCase() !== hash) return json({ error: "PDFのSHA-256が一致しません（送信中に壊れた可能性）", code: "hash_mismatch" }, 422);
  if (pdfBytes.length > 15 * 1024 * 1024) return json({ error: "PDFが大きすぎます（15MBまで）" }, 413);

  // ---- 二重処理の防止 ----
  const { data: dupAtt } = await db.from("invoice_attachments").select("id, invoice_id, email_id").eq("file_hash", hash).limit(1);
  if (dupAtt?.length) {
    let invId = dupAtt[0].invoice_id as string | null;
    if (!invId && dupAtt[0].email_id) { const { data: i } = await db.from("invoices").select("id").eq("email_id", dupAtt[0].email_id).limit(1); invId = i?.[0]?.id ?? null; }
    return json({ success: true, duplicate: true, reason: "同じPDF（SHA-256一致）を既に受け取っています", invoice_id: invId });
  }
  const vendor = await resolveVendor(db, vendorHint);
  const vendorName = vendor?.name ?? vendorHint;
  const vids = vendor?.sameNameIds ?? [];
  {
    let q = db.from("invoices").select("id, invoice_status").neq("invoice_status", "cancelled").eq("invoice_number", invNo);
    if (vids.length) q = q.in("vendor_id", vids);
    const { data: d1 } = await q.limit(1);
    if (d1?.length) return json({ success: true, duplicate: true, reason: "同じ取引先・同じ請求番号の請求書が既にあります", invoice_id: d1[0].id });
    if (vids.length) {
      const { data: d2 } = await db.from("invoices").select("id").in("vendor_id", vids).neq("invoice_status", "cancelled").eq("target_year_month", `${ym}-01`).eq("amount", sumGross).limit(1);
      if (d2?.length) return json({ success: true, duplicate: true, reason: "同じ取引先・同じ対象月・同じ金額の請求書が既にあります", invoice_id: d2[0].id });
    }
  }

  // ---- 請求書（下書き）の作成 ----
  const subtotal = sumGross - sumTax;
  const { data: ins, error: insErr } = await db.from("invoices").insert({
    vendor_id: vendor?.id ?? null, vendor_name: vendorName, invoice_number: invNo, amount: sumGross,
    subtotal_amount: subtotal, tax_amount: sumTax, target_year_month: `${ym}-01`,
    due_date: /^\d{4}-\d{2}-\d{2}$/.test(String(body.due_date ?? "")) ? body.due_date : null,
    corporation_id: vendor?.corp ?? null, invoice_status: "draft", intake_source: "infomart",
    source_message_id: `infomart:${invNo}`, received_at: new Date().toISOString(),
    auto_ocr: { source: "infomart_csv", vendor_hint: vendorHint, totals: body.totals ?? null, corporation_hint: body.corporation_hint ?? null },
    lines_check: { ok: true, source: "infomart_csv", sum_lines: subtotal, subtotal, line_count: lines.length, problems: [], line_amounts_include_tax: false },
    lines_extracted_at: new Date().toISOString(),
  }).select("id").maybeSingle();
  if (insErr || !ins) return json({ error: "請求書の作成に失敗しました: " + (insErr?.message ?? "") }, 500);
  const invoiceId = ins.id as string;

  // PDF証憑
  const path = `${invoiceId}/1.pdf`;
  const { error: upErr } = await db.storage.from("invoice-files").upload(path, pdfBytes, { contentType: "application/pdf", upsert: true });
  if (upErr) { await db.from("invoices").delete().eq("id", invoiceId); return json({ error: "PDFの保存に失敗しました: " + upErr.message }, 500); }
  const { data: att, error: attErr } = await db.from("invoice_attachments").insert({
    invoice_id: invoiceId, file_name: String(body.pdf.file_name).slice(0, 200), mime_type: "application/pdf", storage_path: path,
    file_hash: hash, size_bytes: pdfBytes.length, ocr_done_at: new Date().toISOString(),
  }).select("id").maybeSingle();
  if (attErr || !att) { await db.from("invoices").delete().eq("id", invoiceId); return json({ error: "PDFの記録に失敗しました: " + (attErr?.message ?? "") }, 500); }
  await db.from("invoices").update({ attachment_id: att.id, source_attachment_id: att.id }).eq("id", invoiceId);

  // 明細行（CSV行＝取引先×店舗(部門)×税区分）。金額=税抜（税込−税額）
  const rows = lines.map((l, i) => {
    const gross = Math.round(Number(l.gross)), tax = Math.round(Number(l.tax));
    return {
      invoice_id: invoiceId, line_no: i + 1, description: `${ym}分 ${l.tax_category ?? ""}`.trim(), item: l.sub_account ?? vendorName,
      store_code: String(l.dept_code).trim(), amount: gross - tax, tax_rate: rateOf(l.tax_category), tax_amount: tax, source: "infomart_csv",
    };
  });
  const { error: lErr } = await db.from("invoice_lines").insert(rows);
  if (lErr) return json({ error: "明細の保存に失敗しました: " + lErr.message, invoice_id: invoiceId }, 500);
  await db.from("invoice_audit_logs").insert({
    entity_type: "invoice_email", entity_id: invoiceId, action: "auto_invoice_created", actor_type: "ai",
    note: `インフォマートから受け取り（${vendorName}・${ym}・請求No ${invNo}・${lines.length}行・税込${sumGross}）${vendor ? "" : "※取引先が未確定"}`,
    new_value: { invoice_id: invoiceId, source: "infomart" },
  });

  // 後続（店舗の突合→仕訳下書き→検算）を非同期で起動
  const kick = fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/invoice-resolve-lines`, {
    method: "POST",
    headers: { "Content-Type": "application/json", apikey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, Authorization: `Bearer ${Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")}` },
    body: JSON.stringify({ secret: body.secret, invoice_id: invoiceId }),
  }).catch((e) => console.error("店舗の突合の依頼に失敗: " + e));
  const er = (globalThis as any).EdgeRuntime;
  if (er?.waitUntil) er.waitUntil(kick);

  return json({ success: true, invoice_id: invoiceId, vendor_resolved: !!vendor, lines: rows.length, total_gross: sumGross, total_tax: sumTax });
});
