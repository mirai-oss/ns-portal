// 請求書メール自動処理 Phase3: 明細OCR（担当C・2026-10-13）
//
// 請求書1枚（invoices）の添付PDF/画像から、ヘッダー（税抜合計・税額・税込合計・対象年月・税率別の内訳）と
// 明細行（明細名・品目・店舗表記・店舗コード・ブランド・数量・単価・金額・税率・備考）を読み取り、invoice_lines に保存する。
// 取れない項目はnull（推測で埋めない）。「表→検算」の作法: 明細合計とヘッダー税抜合計を突き合わせ、結果を invoices.lines_check に残す。
// 1枚のPDFに複数の請求書が入っている場合は、請求番号・金額をヒントに対象の1件だけを読む。
// 1枚に複数店舗が混ざる請求書と、1店舗だけの請求書の両方に対応（店舗表記が無い行はstore_textがnull）。
// このFunctionは店舗の解決（Phase4）・仕訳（Phase5）はしない。MFには何も登録しない。
//
// 認証: ①共有シークレット（app_secrets.invoice_intake_secret）＝invoice-auto-createなどサーバー間／②ユーザーJWT（invoice_can_access）
// 入力(JSON): { secret?, invoice_id, force?: boolean }   force=true でも、人が確定した行(resolved_by='human')がある請求書は上書きしない
// 出力(JSON): { success, lines, check:{ ok, sum_lines, subtotal, diff, ... } }
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

const BUCKET = "invoice-files";
const MAX_BYTES = 15 * 1024 * 1024;

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  return btoa(binary);
}

const num = { type: ["number", "null"] };
const str = { type: ["string", "null"] };
const TOOL = {
  name: "extract_invoice_lines",
  description: "請求書の明細行とヘッダーの金額情報を読み取って返す。書かれていない項目はnull。推測で埋めない。",
  input_schema: {
    type: "object",
    properties: {
      header: {
        type: "object",
        properties: {
          subtotal_amount: { ...num, description: "税抜合計（円・整数）" },
          tax_amount: { ...num, description: "消費税額の合計（円・整数）" },
          total_amount: { ...num, description: "税込の請求合計（円・整数）" },
          line_amounts_include_tax: { type: ["boolean", "null"], description: "明細行の「金額」欄が税込で書かれている請求書なら true、税抜なら false、判断できなければ null" },
          target_year_month: { ...str, description: "請求の対象年月。YYYY-MM（「2026年09月分」→2026-09）。無ければnull" },
          tax_breakdown: {
            type: "array", description: "税率別の内訳があれば（8%・10%など）",
            items: { type: "object", properties: { rate: { type: "number", description: "8 または 10 または 0" }, subtotal: num, tax: num } },
          },
        },
      },
      lines: {
        type: "array",
        description: "明細行（請求書に書かれている順）。店舗別の合計行・商品の行など、請求書が行として持っているものをそのまま1行ずつ。小計・合計・税の行は含めない。",
        items: {
          type: "object",
          properties: {
            description: { ...str, description: "明細名・摘要" },
            item: { ...str, description: "品目・商品名（あれば）" },
            store_text: { ...str, description: "店舗の表記（請求書に書かれたまま。例: 鳥一代 本店）。店舗の記載が無ければnull" },
            store_code: { ...str, description: "店舗コード・自社コード（あれば。例: 01）" },
            brand_text: { ...str, description: "ブランド名の表記（あれば）" },
            quantity: num,
            unit_price: num,
            amount: { ...num, description: "その行の金額（円・整数。請求書に書かれている額のまま＝税抜の請求書では税抜）" },
            tax_rate: { type: ["number", "null"], description: "その行の税率。8/10/0。行に書かれていなければnull" },
            tax_amount: { ...num, description: "その行の税額（書かれていれば）" },
            note: { ...str, description: "備考・不確実な点があれば短く" },
          },
        },
      },
      truncated: { type: "boolean", description: "行が多すぎて読み切れなかった場合 true" },
    },
    required: ["header", "lines"],
  },
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return json({ error: "POSTのみ対応" }, 405);
  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) return json({ error: "AI読み取りの設定が未完了です（ANTHROPIC_API_KEY未設定）" }, 500);
  let body: any;
  try { body = await req.json(); } catch { return json({ error: "JSONの読み取りに失敗しました" }, 400); }
  const invoiceId = body?.invoice_id;
  if (!invoiceId) return json({ error: "invoice_idが必要です" }, 400);

  const db = svc();
  // 認証
  if (body?.secret) {
    const { data: sr } = await db.from("app_secrets").select("value").eq("key", "invoice_intake_secret").maybeSingle();
    if (!sr?.value || body.secret !== sr.value) return json({ error: "認証エラー" }, 401);
  } else {
    const uc = userClient(req);
    const { data: ok, error } = await uc.rpc("invoice_can_access");
    if (error || ok !== true) return json({ error: "権限がありません" }, 403);
  }

  const { data: inv, error: invErr } = await db.from("invoices")
    .select("id, vendor_name, invoice_number, amount, attachment_id, email_id").eq("id", invoiceId).maybeSingle();
  if (invErr) return json({ error: "請求書の取得に失敗しました: " + invErr.message }, 500);
  if (!inv) return json({ error: "請求書が見つかりません" }, 404);

  // 人が確定した行があれば上書きしない
  const { count: humanCount } = await db.from("invoice_lines").select("id", { count: "exact", head: true }).eq("invoice_id", invoiceId).eq("resolved_by", "human");
  if (humanCount) return json({ success: true, skipped: true, reason: "人が確定した明細行があるため上書きしません" });

  // 対象の添付（この請求書のattachment_id→無ければメールの最初のPDF/画像）
  let att: any = null;
  if (inv.attachment_id) {
    const { data } = await db.from("invoice_attachments").select("id, file_name, mime_type, storage_path, size_bytes").eq("id", inv.attachment_id).maybeSingle();
    att = data;
  }
  if (!att && inv.email_id) {
    const { data } = await db.from("invoice_attachments").select("id, file_name, mime_type, storage_path, size_bytes").eq("email_id", inv.email_id).order("created_at");
    att = (data ?? []).find((a: any) => String(a.mime_type) === "application/pdf" || String(a.mime_type ?? "").startsWith("image/")) ?? null;
  }
  if (!att) return json({ error: "読み取れる添付（PDF・画像）が見つかりません" }, 404);
  if ((att.size_bytes ?? 0) > MAX_BYTES) return json({ error: "添付が大きすぎます" }, 413);
  const { data: file, error: dlErr } = await db.storage.from(BUCKET).download(att.storage_path);
  if (dlErr || !file) return json({ error: "添付のダウンロードに失敗しました" }, 500);
  const b64 = bytesToBase64(new Uint8Array(await file.arrayBuffer()));
  const mt = String(att.mime_type);

  const { data: setting } = await db.from("automation_rule_settings").select("params").eq("key", "invoice_lines_ai").maybeSingle();
  const model = String((setting?.params as any)?.model ?? "claude-sonnet-5-5");

  const hint = `この請求書の手がかり: 請求元=${inv.vendor_name ?? "不明"}／請求番号=${inv.invoice_number ?? "不明"}／税込請求額=${inv.amount ?? "不明"}。` +
    `添付に複数の請求書が含まれる場合は、この手がかりに合う1件だけを読んでください。`;
  const content: any[] = [
    { type: "text", text: `添付ファイル名: ${att.file_name}\n${hint}\n請求書のヘッダー（税抜合計・税額・税込合計・対象年月・税率別の内訳）と、明細行を1行ずつ読み取ってください。書かれていない項目はnull。小計・合計・税の行は明細に含めないでください。店舗が複数混ざる請求書では行ごとの店舗表記・店舗コードを、1店舗だけの請求書では店舗表記が無ければnullのままにしてください。` },
    mt === "application/pdf"
      ? { type: "document", source: { type: "base64", media_type: "application/pdf", data: b64 } }
      : { type: "image", source: { type: "base64", media_type: mt, data: b64 } },
  ];
  const call = (toolChoice: unknown) => fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "content-type": "application/json", "x-api-key": apiKey, "anthropic-version": "2023-06-01" },
    body: JSON.stringify({
      model, max_tokens: 8000,
      system: "あなたは日本企業の経理担当者向けに、請求書の明細表を正確に書き写すアシスタントです。見えない値を推測で補わず、書かれていない項目はnullにしてください。金額はカンマ・円記号を除いた整数で。必ず extract_invoice_lines ツールで答えてください。",
      tools: [TOOL], tool_choice: toolChoice, messages: [{ role: "user", content }],
    }),
  });
  let aiRes: Response;
  try {
    aiRes = await call({ type: "tool", name: "extract_invoice_lines" });
    if (aiRes.status === 400 && (await aiRes.clone().text().catch(() => "")).includes("tool_choice")) aiRes = await call({ type: "auto" });
  } catch (e) { return json({ error: "AI読み取りサービスへの接続に失敗しました: " + String(e) }, 502); }
  if (!aiRes.ok) return json({ error: `AI読み取りに失敗しました（${aiRes.status}）: ${(await aiRes.text().catch(() => "")).slice(0, 300)}` }, 502);
  const aiJson: any = await aiRes.json();
  const tb = (aiJson.content ?? []).find((c: any) => c.type === "tool_use" && c.name === "extract_invoice_lines");
  if (!tb) return json({ error: "AIの応答を解釈できませんでした" }, 502);
  const result = tb.input ?? {};
  const header = result.header ?? {};
  const lines: any[] = Array.isArray(result.lines) ? result.lines : [];
  const toNum = (v: unknown) => (v != null && Number.isFinite(Number(v)) ? Number(v) : null);

  // 検算: 明細合計=税抜合計（±1円）。税の内訳があれば税率別にも見る
  const sumLines = lines.reduce((t, l) => t + (toNum(l.amount) ?? 0), 0);
  const subtotal = toNum(header.subtotal_amount);
  const tax = toNum(header.tax_amount);
  const total = toNum(header.total_amount);
  const checks: Record<string, unknown> = { sum_lines: sumLines, line_count: lines.length, truncated: !!result.truncated };
  const problems: string[] = [];
  if (!lines.length) problems.push("明細行を読み取れませんでした");
  if (result.truncated) problems.push("行が多く、読み切れていない可能性があります");
  const inclTax = header.line_amounts_include_tax === true;
  checks.line_amounts_include_tax = header.line_amounts_include_tax ?? null;
  if (inclTax) {
    // 明細の金額が税込の請求書: 税込合計と突き合わせる
    if (total != null) {
      checks.total = total; checks.diff = sumLines - total;
      if (Math.abs(sumLines - total) > 1) problems.push(`明細合計（${sumLines}・税込表記）と税込合計（${total}）が合いません`);
    } else problems.push("税込合計が読み取れず、明細合計の検算ができません");
  } else if (subtotal != null) {
    checks.subtotal = subtotal; checks.diff = sumLines - subtotal;
    if (Math.abs(sumLines - subtotal) > 1) problems.push(`明細合計（${sumLines}）と税抜合計（${subtotal}）が合いません`);
  } else problems.push("税抜合計が読み取れず、明細合計の検算ができません");
  if (!inclTax) {
    const bad = lines.filter((l) => toNum(l.quantity) != null && toNum(l.unit_price) != null && toNum(l.amount) != null && Math.abs(Number(l.quantity) * Number(l.unit_price) - Number(l.amount)) > 1).length;
    if (bad) problems.push(`数量×単価と金額が合わない行が${bad}行あります`);
  }
  if (subtotal != null && tax != null && total != null && Math.abs(subtotal + tax - total) > 1) problems.push(`税抜${subtotal}＋税${tax}が税込${total}と合いません`);
  if (total != null && inv.amount != null && Math.abs(Number(inv.amount) - total) > 1) problems.push(`請求書の金額（${inv.amount}）と読み取った税込合計（${total}）が違います`);
  if (!inclTax && Array.isArray(header.tax_breakdown) && header.tax_breakdown.length) {
    for (const b of header.tax_breakdown) {
      const rate = toNum(b.rate), sub = toNum(b.subtotal);
      if (rate == null || sub == null) continue;
      const rl = lines.filter((l) => toNum(l.tax_rate) === rate);
      if (rl.length) {
        const s = rl.reduce((t, l) => t + (toNum(l.amount) ?? 0), 0);
        if (Math.abs(s - sub) > 1) problems.push(`税率${rate}%の明細合計（${s}）と内訳（${sub}）が合いません`);
      }
    }
  }
  checks.ok = problems.length === 0; checks.problems = problems;

  // 保存（入れ替え）
  await db.from("invoice_lines").delete().eq("invoice_id", invoiceId);
  if (lines.length) {
    const rows = lines.map((l, i) => ({
      invoice_id: invoiceId, line_no: i + 1,
      description: l.description ?? null, item: l.item ?? null, store_text: l.store_text ?? null, store_code: l.store_code ?? null,
      brand_text: l.brand_text ?? null, quantity: toNum(l.quantity), unit_price: toNum(l.unit_price), amount: toNum(l.amount),
      tax_rate: toNum(l.tax_rate), tax_amount: toNum(l.tax_amount), note: l.note ?? null, source: "ocr",
    }));
    const { error: insErr } = await db.from("invoice_lines").insert(rows);
    if (insErr) return json({ error: "明細の保存に失敗しました: " + insErr.message }, 500);
  }
  const ym = /^\d{4}-\d{2}$/.test(String(header.target_year_month ?? "")) ? `${header.target_year_month}-01` : null;
  await db.from("invoices").update({
    subtotal_amount: subtotal, tax_amount: tax, target_year_month: ym, lines_check: { ...checks, tax_breakdown: header.tax_breakdown ?? null, model },
    lines_extracted_at: new Date().toISOString(), updated_at: new Date().toISOString(),
  }).eq("id", invoiceId);
  if (inv.email_id) {
    await db.from("invoice_audit_logs").insert({
      entity_type: "invoice_email", entity_id: inv.email_id, action: "lines_extracted", actor_type: "ai",
      note: `明細OCR: ${lines.length}行・検算${checks.ok ? "OK" : "要確認（" + problems.join("／") + "）"}`, new_value: { invoice_id: invoiceId, check: checks },
    });
  }
  return json({ success: true, lines: lines.length, check: checks });
});
