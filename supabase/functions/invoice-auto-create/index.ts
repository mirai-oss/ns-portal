// 請求書メール自動処理 Phase2: invoice自動生成（担当C・2026-10-13）
//
// 自動分類(Phase1)で auto_category='invoice_attachment'（請求書が添付されたメール）と判定されたメールの添付を
// 既存の invoice-ocr（複数請求書の検出に対応）で読み取り、下書きinvoice（invoice_status='draft'・intake_source='email_auto'）を作る。
// ・人が内容を確認して承認するまでMFには何も登録しない（AI=下書き・人=承認）。このFunctionはinvoicesへ下書きを書くだけ。
// ・二重処理の防止（設計書§10）: ①同じ添付は再処理しない（invoice_attachments.ocr_done_at）②同じファイル(ハッシュ)は読まない
//   ③業務キー（取引先×請求番号／無ければ取引先×支払期限×税込合計）が同じ請求書が既にあれば作らず、到着の記録だけ残す
//   ④人が既にこのメールに請求書を作っていれば何もしない ⑤部分ユニーク索引(biz_key)で同時実行でも1件に集約
// ・人の手動分類(mail_kind)が invoice 以外のメールは対象外。
//
// 認証: invoice-intake と同じ共有シークレット（app_secrets.invoice_intake_secret）。
// 入力(JSON):
//   { secret, email_id }                                  … 1通を処理（invoice-intakeが分類直後に呼ぶ）
//   { secret, action:"scan", since?:ISO, limit?:number, dry_run?:boolean }
//                                                         … auto_category='invoice_attachment' かつ未処理のメールをまとめて処理（既定=直近48時間）
import { createClient } from "npm:@supabase/supabase-js@2";

const cors: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });
const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const norm = (s: unknown) => String(s ?? "").normalize("NFKC").replace(/\s+/g, "").toLowerCase();
// 会社名の揺れ（株式会社／(株)／㈱／有限会社 …）を落として比較する
const normCompany = (s: unknown) =>
  norm(s).replace(/株式会社|有限会社|合同会社|合資会社|合名会社|\(株\)|\(有\)|\(合\)|\(同\)|㈱|㈲|㈳|\(株式\)/g, "").replace(/[()（）・\-ー]/g, "");

async function resolveVendor(db: any, name: string | null): Promise<{ id: string; corp: string | null } | null> {
  const n = normCompany(name);
  if (!n) return null;
  const [{ data: vendors }, { data: aliases }] = await Promise.all([
    db.from("vendors").select("id, name, name_aliases, default_corporation_id, is_active, created_at").eq("is_active", true),
    db.from("vendor_aliases").select("vendor_id, alias").eq("is_active", true),
  ]);
  const hit = new Map<string, string | null>();
  for (const v of vendors ?? []) {
    if (normCompany(v.name) === n || (v.name_aliases ?? []).some((a: string) => normCompany(a) === n)) hit.set(v.id, v.default_corporation_id ?? null);
  }
  const byId = new Map((vendors ?? []).map((v: any) => [v.id, v]));
  for (const a of aliases ?? []) {
    if (normCompany(a.alias) === n && byId.has(a.vendor_id)) hit.set(a.vendor_id, (byId.get(a.vendor_id) as any).default_corporation_id ?? null);
  }
  if (hit.size === 0) return null; // 未登録 → 取引先は未確定のまま（人が確認）
  if (hit.size > 1) {
    // 全く同じ名前の取引先が重複登録されている場合（例: 株式会社カカクコムが複数）は、同一取引先とみなして
    // 「既定の法人が設定済み→最も古い登録」を採用する。名前が違う複数候補（本当に曖昧）は確定しない
    const cands = [...hit.keys()].map((id) => byId.get(id) as any);
    const names = new Set(cands.map((c) => normCompany(c.name)));
    if (names.size !== 1) return null;
    cands.sort((a, b) => (b.default_corporation_id ? 1 : 0) - (a.default_corporation_id ? 1 : 0) || String(a.created_at).localeCompare(String(b.created_at)));
    return { id: cands[0].id, corp: cands[0].default_corporation_id ?? null };
  }
  const [id, corp] = [...hit.entries()][0];
  return { id, corp };
}

async function resolveCorporation(db: any, addressee: string | null): Promise<string | null> {
  const n = normCompany(addressee);
  if (!n) return null;
  const [{ data: corps }, { data: aliases }] = await Promise.all([
    db.from("corporations").select("id, name"),
    db.from("corporation_aliases").select("corporation_id, alias").eq("is_active", true),
  ]);
  const hit = new Set<string>();
  for (const c of corps ?? []) if (normCompany(c.name) === n) hit.add(c.id);
  for (const a of aliases ?? []) if (normCompany(a.alias) === n) hit.add(a.corporation_id);
  return hit.size === 1 ? [...hit][0] : null;
}

function bizKeyOf(vendorId: string | null, invoiceNumber: string | null, dueDate: string | null, amount: number | null): string | null {
  if (!vendorId) return null;
  if (invoiceNumber && norm(invoiceNumber)) return `${vendorId}|no:${norm(invoiceNumber)}`;
  if (dueDate && amount != null) return `${vendorId}|due:${dueDate}|amt:${Math.round(amount)}`;
  return null;
}

async function logAudit(db: any, emailId: string, action: string, note: string, newValue?: unknown) {
  await db.from("invoice_audit_logs").insert({ entity_type: "invoice_email", entity_id: emailId, action, actor_type: "ai", note, new_value: newValue ?? null });
}

// 恒久的にスキップするメールは、スキャンで何度も拾わないよう「処理済み」の印とメモを残す
async function markSkipped(db: any, emailId: string, reason: string, dryRun?: boolean) {
  if (!dryRun) await db.from("invoice_emails").update({ auto_invoice_at: new Date().toISOString(), auto_invoice_note: "作成なし: " + reason }).eq("id", emailId);
  return { email_id: emailId, status: "skipped", reason };
}

async function processEmail(db: any, emailId: string, secret: string, opts: { dryRun?: boolean } = {}) {
  const { data: email } = await db.from("invoice_emails")
    .select("id, gmail_message_id, subject, received_at, mail_kind, auto_category").eq("id", emailId).maybeSingle();
  if (!email) return { email_id: emailId, status: "skipped", reason: "メールが見つかりません" };
  if (email.auto_category !== "invoice_attachment") return { email_id: emailId, status: "skipped", reason: `自動分類が請求書（添付あり）ではありません（${email.auto_category ?? "未分類"}）` };
  if (email.mail_kind && email.mail_kind !== "invoice") return markSkipped(db, emailId, `人が「${email.mail_kind}」に分類済みです`, opts.dryRun);

  const { data: existing } = await db.from("invoices").select("id").eq("email_id", emailId).limit(1);
  if (existing?.length) return markSkipped(db, emailId, "このメールには既に請求書があります（人が作成済み・処理済み）", opts.dryRun);

  const { data: atts } = await db.from("invoice_attachments")
    .select("id, file_name, mime_type, file_hash, ocr_done_at, size_bytes").eq("email_id", emailId).order("created_at");
  const readable = (atts ?? []).filter((a: any) => {
    const mt = String(a.mime_type ?? "");
    return (mt === "application/pdf" || mt.startsWith("image/")) && !a.ocr_done_at;
  });
  if (!readable.length) return markSkipped(db, emailId, "未処理のPDF・画像の添付がありません", opts.dryRun);

  // 同じファイル（ハッシュ）を既に読み取り済みなら読まない（別メールで届いた同じ請求書）
  const fresh: any[] = [];
  for (const a of readable) {
    if (a.file_hash) {
      const { data: dup } = await db.from("invoice_attachments").select("id").eq("file_hash", a.file_hash).neq("id", a.id).not("ocr_done_at", "is", null).limit(1);
      if (dup?.length) {
        if (!opts.dryRun) await db.from("invoice_attachments").update({ ocr_done_at: new Date().toISOString() }).eq("id", a.id);
        continue;
      }
    }
    fresh.push(a);
  }
  if (!fresh.length) {
    if (!opts.dryRun) {
      await db.from("invoice_emails").update({ auto_invoice_at: new Date().toISOString(), auto_invoice_note: "同じファイルを既に処理済みのため作成なし" }).eq("id", emailId);
      await logAudit(db, emailId, "auto_duplicate_skipped", "同じ添付ファイル（ハッシュ一致）を既に処理済みのため、請求書は作成しませんでした");
    }
    return { email_id: emailId, status: "skipped", reason: "同じファイルを既に処理済み" };
  }
  if (opts.dryRun) return { email_id: emailId, status: "would_process", subject: String(email.subject ?? "").slice(0, 50), files: fresh.map((a: any) => a.file_name) };

  // 既存のinvoice-ocrで読み取り（service role。複数請求書の検出に対応済み）
  const ocrRes = await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/invoice-ocr`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
      Authorization: `Bearer ${Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")}`,
    },
    body: JSON.stringify({ email_id: emailId, mail_kind: "invoice", internal_secret: secret }),
  });
  const ocr = await ocrRes.json().catch(() => ({}));
  if (!ocrRes.ok || !ocr.success) {
    // 読み取り失敗は ocr_done_at を付けない（次回再試行できる）
    await db.from("invoice_emails").update({ auto_invoice_note: "読み取りに失敗: " + String(ocr.error ?? ocrRes.status).slice(0, 200) }).eq("id", emailId);
    return { email_id: emailId, status: "error", reason: "AI読み取りに失敗: " + String(ocr.error ?? ocrRes.status).slice(0, 120) };
  }
  const nowIso = new Date().toISOString();
  await db.from("invoice_attachments").update({ ocr_done_at: nowIso }).in("id", fresh.map((a: any) => a.id));

  const found: any[] = Array.isArray(ocr.invoices) ? ocr.invoices : [];
  if (!found.length) {
    await db.from("invoice_emails").update({ auto_invoice_at: nowIso, auto_invoice_note: "添付から請求書を検出できませんでした（要確認）" }).eq("id", emailId);
    await logAudit(db, emailId, "auto_invoice_none", "AI読み取りで請求書が検出できませんでした。人が確認してください");
    return { email_id: emailId, status: "none_found" };
  }

  const created: string[] = []; const skipped: string[] = [];
  let first = true;
  for (const f of found) {
    const vendorName: string | null = f.vendor_name ?? null;
    const amount = f.amount != null && Number.isFinite(Number(f.amount)) ? Math.round(Number(f.amount)) : null;
    const dueDate: string | null = /^\d{4}-\d{2}-\d{2}$/.test(String(f.due_date ?? "")) ? f.due_date : null;
    const invoiceNumber: string | null = f.invoice_number ? String(f.invoice_number).trim() : null;
    const v = await resolveVendor(db, vendorName);
    const corporationId = v?.corp ?? await resolveCorporation(db, f.addressee_company ?? null);
    const bizKey = bizKeyOf(v?.id ?? null, invoiceNumber, dueDate, amount);

    // ③同じ業務キーの請求書が既にあれば作らず、到着の記録だけ残す（入口がメール・アップロード・自動取得のどれでも1件に集約）
    if (v) {
      let q = db.from("invoices").select("id, intake_source").eq("vendor_id", v.id).neq("invoice_status", "cancelled");
      if (invoiceNumber) q = q.eq("invoice_number", invoiceNumber);
      else if (dueDate && amount != null) q = q.eq("due_date", dueDate).eq("amount", amount);
      else q = q.eq("id", "00000000-0000-0000-0000-000000000000");
      const { data: dupInv } = await q.limit(1);
      if (dupInv?.length) {
        await logAudit(db, emailId, "auto_duplicate_skipped", `同じ請求書が既にあるため作成しませんでした（既存invoice=${dupInv[0].id}・取引先=${vendorName}・請求番号=${invoiceNumber ?? "なし"}・金額=${amount ?? "不明"}）。到着経路: メール(${email.gmail_message_id})`);
        skipped.push(dupInv[0].id);
        continue;
      }
    }

    const src = (atts ?? []).find((a: any) => f.source_hint && String(a.file_name).includes(String(f.source_hint))) ?? fresh[0];
    const row: Record<string, unknown> = {
      email_id: first ? emailId : null,   // invoices.email_id は1メール1件のunique。2件目以降はNULL（元メールは source_message_id で辿れる）
      attachment_id: src?.id ?? null, source_attachment_id: src?.id ?? null,
      source_message_id: email.gmail_message_id ?? null, received_at: email.received_at ?? null,
      vendor_name: vendorName, invoice_number: invoiceNumber, amount, due_date: dueDate,
      vendor_id: v?.id ?? null, corporation_id: corporationId,
      invoice_status: "draft", intake_source: "email_auto", biz_key: bizKey,
      auto_ocr: f,   // 読み取り結果（振込先など）。Phase6の検算・口座照合で使う
    };
    const { data: ins, error: insErr } = await db.from("invoices").insert(row).select("id").maybeSingle();
    if (insErr) {
      if (String(insErr.code) === "23505") { skipped.push("(同時実行で既に作成済み)"); continue; }
      await logAudit(db, emailId, "auto_invoice_error", "下書きの作成に失敗: " + insErr.message.slice(0, 200));
      continue;
    }
    first = false;
    created.push(ins!.id as string);
    // Phase3: 作成した下書きの明細行を読み取る（時間がかかるため待たずに別Functionへ依頼。失敗しても下書きは残る）
    const kick = fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/invoice-lines-ocr`, {
      method: "POST",
      headers: { "Content-Type": "application/json", apikey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, Authorization: `Bearer ${Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")}` },
      body: JSON.stringify({ secret, invoice_id: ins!.id }),
    }).catch((e) => console.error("明細OCRの依頼に失敗: " + e));
    const er = (globalThis as any).EdgeRuntime;
    if (er?.waitUntil) er.waitUntil(kick);
    await logAudit(db, emailId, "auto_invoice_created",
      `自動で下書きを作成（取引先=${vendorName ?? "不明"}${v ? "・登録済み" : "・未登録/未確定"}／請求番号=${invoiceNumber ?? "なし"}／金額=${amount ?? "不明"}／期限=${dueDate ?? "不明"}）`,
      { invoice_id: ins!.id, vendor_id: v?.id ?? null, corporation_id: corporationId });
  }
  await db.from("invoice_emails").update({
    auto_invoice_at: nowIso,
    auto_invoice_note: `下書き${created.length}件作成／重複スキップ${skipped.length}件`,
  }).eq("id", emailId);
  return { email_id: emailId, status: "created", created, skipped_duplicates: skipped.length };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return json({ error: "POSTのみ対応" }, 405);
  let body: any;
  try { body = await req.json(); } catch { return json({ error: "JSONの読み取りに失敗しました" }, 400); }

  const db = svc();
  const { data: secretRow, error: secretErr } = await db.from("app_secrets").select("value").eq("key", "invoice_intake_secret").maybeSingle();
  if (secretErr) return json({ error: "シークレット確認に失敗しました: " + secretErr.message }, 500);
  if (!secretRow?.value || body?.secret !== secretRow.value) return json({ error: "認証エラー" }, 401);

  try {
    if (body?.action === "scan") {
      const since = body.since ? new Date(body.since).toISOString() : new Date(Date.now() - 48 * 3600e3).toISOString();
      const limit = Math.min(Number(body.limit) || 10, 30);
      const { data: mails, error } = await db.from("invoice_emails").select("id")
        .eq("auto_category", "invoice_attachment").is("auto_invoice_at", null).gte("received_at", since)
        .order("received_at", { ascending: true }).limit(limit);
      if (error) return json({ error: "取得に失敗しました: " + error.message }, 500);
      const results = [];
      for (const m of mails ?? []) results.push(await processEmail(db, m.id as string, body.secret, { dryRun: !!body.dry_run }));
      return json({ success: true, dry_run: !!body.dry_run, processed: results.length, results });
    }
    if (!body?.email_id) return json({ error: "email_id が必要です" }, 400);
    return json({ success: true, result: await processEmail(db, body.email_id, body.secret) });
  } catch (e) {
    return json({ error: "処理中にエラー: " + String((e as Error)?.message ?? e) }, 500);
  }
});
