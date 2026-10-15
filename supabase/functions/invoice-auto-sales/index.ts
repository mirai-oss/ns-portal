// 売上入金メール（不動産の送金明細書）の自動処理（担当C・2026-10-14）
//
// 自動分類で auto_category='sales_deposit'（売上入金）と判定され、PDFが添付されたメールを読み取り、
// 「仕訳の下書き」まで作って承認待ち（invoices.current_stage='ready_for_approval'）に並べる。MFには、人が承認するまで何も登録しない。
//
// 流れ: ①添付のPDF（送金明細書）をAIで読み取り（物件名・対象月・送金日・収入の明細（入居者×税区分）・支出（管理委託料）・送金額）
//       ②物件ごとの仕訳の型（receivable_property_rules）を探す
//       ③仕訳の下書き: 借方=売掛金（送金額）＋支払手数料（管理委託料）／貸方=売上高（入居者×税区分ごと）。部門=物件、税区分=課税売上10%／対象外
//       ④検算（収入−支出=送金額・貸借一致・取引先・法人・重複・PDF）→ 通れば承認待ち、通らなければ理由つきで止める（要対応）
// 売上は毎日の売上でPLに反映済みのため、PLへの反映は行わない（承認画面の「PLにも反映」は店舗が無いので何も起きない）。
//
// 認証: invoice-intake と同じ共有シークレット（app_secrets.invoice_intake_secret）。
// 入力(JSON): { secret, email_id } … 1通を処理（invoice-intakeが分類直後に呼ぶ）
//             { secret, action:"scan", since?:ISO, limit?:number } … sales_deposit かつ未処理のメールをまとめて処理（既定=直近7日）
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
  norm(s).replace(/株式会社|有限会社|合同会社|合資会社|合名会社|\(株\)|\(有\)|\(合\)|\(同\)|㈱|㈲|㈳/g, "").replace(/[()（）・\-ー]/g, "");

function bytesToBase64(bytes: Uint8Array): string {
  let binary = ""; const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  return btoa(binary);
}

const num = { type: ["number", "null"] };
const str = { type: ["string", "null"] };
const money = { type: "object", properties: { net: num, tax: num, gross: num }, description: "税抜・消費税・税込（円・整数。書かれていない欄はnull）" };
const TOOL = {
  name: "extract_remittance_statement",
  description: "「送金明細書」（不動産の管理会社から送られる、賃料などの収入と管理委託料などの支出、送金額の明細）または「業務委託精算書」（施設の運営会社から送られる、入金項目・経費項目・業務委託費支払金額の精算書）を読み取って返す。複数ページあるPDFでは、最初の送金明細書／業務委託精算書だけを読む（同じPDFの中の御請求書・立替経費の請求書・立替経費の明細書は読まない）。書かれていない項目はnull。推測で埋めない。",
  input_schema: {
    type: "object",
    properties: {
      property_name: { ...str, description: "物件名または対象施設（「物件名 マンタビル」→マンタビル／「対象施設：龍馬池袋」→龍馬池袋）" },
      target_month: { ...str, description: "対象月 YYYY-MM（「対象月 2026年09月度」→2026-09。「08月集金分」などの括弧書きは無視）" },
      remit_date: { ...str, description: "送金予定日（精算書なら精算日）YYYY-MM-DD（無ければ作成日）" },
      sender: { ...str, description: "送金者（管理業者）／精算書の発行元の会社名" },
      income_items: {
        type: "array",
        description: "収入の明細（精算書なら入金項目）。入居者（賃借人）／入金元ごとの行だけを入れる（「収入内訳」「小計」の合計欄は入れない）。金額が「—」「0」の行は入れない。同じ入居者の賃貸料・管理費・水道料などは行ごとに別々に入れる。精算書で税抜金額しか書かれていない行は net だけ入れる。",
        items: {
          type: "object",
          properties: {
            tenant: { ...str, description: "入金元（賃借人）。部屋番号・階があれば含める 例: 1号室 合同会社グレースペック" },
            item: { ...str, description: "項目 例: 賃貸料／管理費／水道料" },
            period_month: { ...str, description: "該当月 YYYY-MM（未入金分なら前月になる）" },
            tax_class: { type: ["string", "null"], enum: ["taxable_10", "taxable_8", "exempt", null], description: "10%課税=taxable_10／8%=taxable_8／非課税=exempt" },
            net: num, tax: num, gross: num,
            note: { ...str, description: "備考（未入金分 等）" },
          },
        },
      },
      income_total: { ...money, description: "収入合計" },
      expense_items: {
        type: "array", description: "支出の明細（管理委託料など）。金額が「—」の行は入れない",
        items: { type: "object", properties: { payee: str, item: str, tax_class: { type: ["string", "null"], enum: ["taxable_10", "taxable_8", "exempt", null] }, net: num, tax: num, gross: num, note: str } },
      },
      expense_total: { ...money, description: "支出合計" },
      remit_total: { ...money, description: "送金額（収入合計−支出合計）／精算書なら「業務委託費支払金額」" },
    },
    required: ["income_items", "income_total", "expense_items", "expense_total", "remit_total"],
  },
};

const SEISAN_TOOL = {
  name: "extract_seisan_statement",
  description: "「業務委託精算書」（精算ダッシュボードが自動発行する、店舗ごとの月次の精算書。発行元=株式会社N-style、宛先=有限会社トーホーエージェンシー）の見出しの数字を読み取って返す。書かれていない項目はnull。推測で埋めない。",
  input_schema: {
    type: "object",
    properties: {
      store_name: { ...str, description: "店舗名（タイトル下の「新横浜　黒霧屋　2026年8月分」→新横浜　黒霧屋）" },
      target_month: { ...str, description: "対象月 YYYY-MM（「2026年8月分」→2026-08）" },
      issue_date: { ...str, description: "発行日 YYYY-MM-DD" },
      addressee: { ...str, description: "宛先（御中の前）" },
      issuer: { ...str, description: "発行元の会社名" },
      fee_net: { ...num, description: "業務委託費（税抜）（円）" },
      tax: { ...num, description: "消費税（円）" },
      total_gross: { ...num, description: "振込金額（税込）（円）" },
    },
    required: ["store_name", "target_month", "fee_net", "tax", "total_gross"],
  },
};

async function resolveVendor(db: any, name: string): Promise<{ id: string; name: string; corp: string | null } | null> {
  const n = normCompany(name); if (!n) return null;
  const { data: vendors } = await db.from("vendors").select("id, name, name_aliases, default_corporation_id").eq("is_active", true);
  const hit = (vendors ?? []).filter((v: any) => normCompany(v.name) === n || (v.name_aliases ?? []).some((a: string) => normCompany(a) === n));
  if (!hit.length) return null;
  return { id: hit[0].id, name: hit[0].name, corp: hit[0].default_corporation_id ?? null };
}

async function logAudit(db: any, emailId: string, action: string, note: string, newValue?: unknown) {
  await db.from("invoice_audit_logs").insert({ entity_type: "invoice_email", entity_id: emailId, action, actor_type: "ai", note, new_value: newValue ?? null });
}
async function markSkipped(db: any, emailId: string, reason: string) {
  await db.from("invoice_emails").update({ auto_invoice_at: new Date().toISOString(), auto_invoice_note: "作成なし: " + reason }).eq("id", emailId);
  return { email_id: emailId, status: "skipped", reason };
}

const TAX_RATE: Record<string, number> = { taxable_10: 10, taxable_8: 8, exempt: 0 };
const fillTpl = (tpl: string | null | undefined, def: string, vars: Record<string, string>) => String(tpl || def).replace(/\{(\w+)\}/g, (_m, k) => vars[k] ?? "").replace(/\s+$/g, "");
const toInt = (v: unknown) => (v != null && Number.isFinite(Number(v)) ? Math.round(Number(v)) : null);
const monthEnd = (ym: string) => { const [y, m] = ym.split("-").map(Number); return `${ym}-${String(new Date(y, m, 0).getDate()).padStart(2, "0")}`; };


// ---- 業務委託精算書（N-Style→トーホー）: 1通から2つの仕訳の下書き（トーホー=売上／N-Style=支払）を作る（2026-10-15）----
async function buildSeisan(db: any, email: any, att: any, ex: any, firstEmailRow: boolean): Promise<{ ids: string[]; note: string }> {
  const total = toInt(ex.total_gross), feeNet = toInt(ex.fee_net), tax = toInt(ex.tax);
  const ym = /^\d{4}-\d{2}$/.test(String(ex.target_month ?? "")) ? String(ex.target_month) : null;
  const store = norm(ex.store_name);
  const { data: rules } = await db.from("seisan_statement_rules").select("*").eq("is_active", true);
  const rule = (rules ?? []).find((r: any) => (r.store_patterns ?? []).some((p: string) => store.includes(norm(p))));
  const mo = ym ? `${Number(ym.slice(5, 7))}月` : "";
  const date = ym ? monthEnd(ym) : String(email.received_at ?? "").slice(0, 10);
  const nowIso = new Date().toISOString();

  const baseChecks = (checks: any[], problems: string[]) => {
    const ck = (key: string, label: string, status: "ok" | "warn" | "ng" | "na", detail?: string) => { checks.push({ key, label, status, ...(detail ? { detail } : {}) }); if (status === "ng") problems.push(detail ? `${label}（${detail}）` : label); };
    ck("read", "精算書の読み取り", total != null && feeNet != null && tax != null && ym ? "ok" : "ng", total != null && feeNet != null && tax != null && ym ? undefined : "金額または対象月を読み取れませんでした");
    if (total != null && feeNet != null && tax != null) ck("sum", "業務委託費（税抜）＋消費税＝振込金額", feeNet + tax === total ? "ok" : "ng", feeNet + tax === total ? undefined : `${feeNet}+${tax}≠${total}`);
    ck("rule", "店舗の仕訳の型がある", rule ? "ok" : "ng", rule ? String(rule.store_label ?? "") : `店舗「${ex.store_name ?? "不明"}」の仕訳の型が未登録です`);
    ck("pdf", "精算書のPDFが添付されている", "ok");
    return ck;
  };

  const ids: string[] = [];
  const specs = rule && total != null ? [
    { side: "sales", tenant: rule.sales_tenant, corp: rule.sales_corporation_id, vendor: rule.sales_customer_vendor },
    { side: "expense", tenant: rule.exp_tenant, corp: rule.exp_corporation_id, vendor: rule.exp_payee_vendor },
  ] : [{ side: "sales", tenant: "default", corp: null, vendor: "株式会社N-Style" }, { side: "expense", tenant: "nstyle", corp: null, vendor: "有限会社トーホーエージェンシー" }];
  const notes: string[] = [];
  let emailRowUsed = !firstEmailRow;
  for (const sp of specs) {
    const problems: string[] = []; const checks: any[] = []; const warnings: string[] = [];
    const ck = baseChecks(checks, problems);
    const v = await resolveVendor(db, sp.vendor);
    ck("vendor", "取引先が確定", v ? "ok" : "ng", v ? undefined : `「${sp.vendor}」が取引先マスタにありません`);
    ck("corporation", "法人が確定", sp.corp ? "ok" : "ng");
    const debitLines: any[] = []; const creditLines: any[] = []; let credit: any = null;
    if (rule && total != null) {
      if (sp.side === "sales") {
        debitLines.push({ line_no: 1, store_id: null, store_name: null, remark: fillTpl(rule.sales_remark_tpl, "{mo}分", { mo }),
          debit: { account: rule.sales_receivable_account, sub_account: rule.sales_receivable_sub, department: null, tax: { kind: "purchase", rate: 0 }, amount: total, net_amount: total }, rule: { source: "ledger", version: 1 } });
        creditLines.push({ line_no: 1, account: rule.sales_revenue_account, sub_account: rule.sales_revenue_sub, department: rule.sales_department,
          tax: { kind: "sales", rate: 10, name: "課税売上 10%" }, amount: total, remark: fillTpl(rule.sales_remark_tpl, "{mo}分", { mo }) });
      } else {
        debitLines.push({ line_no: 1, store_id: null, store_name: null, remark: fillTpl(rule.exp_remark_tpl, "{mo}", { mo }),
          debit: { account: rule.exp_account, sub_account: rule.exp_sub, department: rule.exp_department, tax: { kind: "purchase", rate: 10 }, amount: total, net_amount: feeNet ?? total }, rule: { source: "ledger", version: 1 } });
        credit = { account: rule.exp_payable_account, sub_account: rule.exp_payable_sub, amount: total };
      }
    }
    // 重複（同じ店舗×対象月×側）。同額なら作らない（再送信）。金額が違えば要確認として作る
    const bizKey = v && rule && ym ? `${v.id}|seisan:${norm(rule.store_label)}|${ym}|${sp.side}` : null;
    let skipSame = false;
    if (bizKey) {
      const { data: dup } = await db.from("invoices").select("id, amount").eq("biz_key", bizKey).neq("invoice_status", "cancelled").limit(1);
      if (dup?.length) {
        if (Number(dup[0].amount) === total) skipSame = true;
        else ck("duplicate", "重複なし", "ng", `同じ対象月の精算書が既にあり、金額が違います（既存${dup[0].amount}円→今回${total}円。再送信で修正された可能性）`);
      } else ck("duplicate", "重複なし", "ok");
    } else ck("duplicate", "重複なし", "na");
    if (skipSame) { notes.push(`${sp.side === "sales" ? "トーホー売上" : "N-Style支払"}: 同額の精算書が既にあるため作成せず（再送信）`); continue; }

    const debitTotal = debitLines.reduce((t, d) => t + d.debit.amount, 0), creditTotal = creditLines.reduce((t, c) => t + c.amount, 0) + (credit?.amount ?? 0);
    ck("balance", "仕訳の借方＝貸方", debitLines.length && debitTotal === creditTotal ? "ok" : "ng", debitLines.length ? (debitTotal === creditTotal ? undefined : `借方${debitTotal}／貸方${creditTotal}`) : "仕訳を作れませんでした");
    const draft = {
      version: 1, kind: sp.side === "sales" ? "sales_deposit" : "seisan_expense", status: problems.length ? "needs_review" : "ok", tenant_id: sp.tenant, corporation_id: sp.corp,
      transaction_date: date, remark: debitLines[0]?.remark ?? "", debit_lines: debitLines, credit, credit_lines: creditLines,
      totals: { debit: debitTotal, credit: creditTotal, invoice_total: total }, adjustments: [], problems, warnings, created_at: nowIso,
    };
    const stage = problems.length ? "journal_draft" : "ready_for_approval";
    const row: Record<string, unknown> = {
      email_id: emailRowUsed ? null : email.id, attachment_id: att.id, source_attachment_id: att.id, source_message_id: email.gmail_message_id ?? null, received_at: email.received_at ?? null,
      vendor_name: v?.name ?? sp.vendor, vendor_id: v?.id ?? null, corporation_id: sp.corp, amount: total, due_date: date,
      target_year_month: ym ? `${ym}-01` : null, invoice_status: "draft", intake_source: "email_auto", biz_key: problems.some((p) => p.startsWith("重複")) ? null : bizKey,
      journal_draft: draft, journal_draft_at: nowIso, current_stage: stage, blocked_reason: problems.length ? problems.join("／") : null,
      stage_updated_at: nowIso, checks: { checks, routes: [], checked_at: nowIso }, auto_ocr: ex, auto_mode: "auto",
    };
    const { data: ins, error } = await db.from("invoices").insert(row).select("id").maybeSingle();
    if (error) { notes.push(`${sp.side}: 作成に失敗（${error.message.slice(0, 80)}）`); continue; }
    emailRowUsed = true; ids.push(ins!.id as string);
    await logAudit(db, email.id, "auto_invoice_created", `業務委託精算書を自動で下書き作成（${sp.side === "sales" ? "トーホー=売上" : "N-Style=支払"}／店舗=${ex.store_name ?? "不明"}／対象月=${ym ?? "不明"}／${total ?? "不明"}円）→ ${stage === "ready_for_approval" ? "承認待ち" : "要確認: " + problems.join("／")}`, { invoice_id: ins!.id, stage });
    notes.push(`${sp.side === "sales" ? "トーホー売上" : "N-Style支払"}: ${stage === "ready_for_approval" ? "承認待ち" : "要確認で止めた"}`);
  }
  return { ids, note: notes.join("／") || "作成なし" };
}

async function processEmail(db: any, emailId: string, secret: string) {
  const { data: email } = await db.from("invoice_emails").select("id, gmail_message_id, subject, received_at, mail_kind, auto_category, from_address").eq("id", emailId).maybeSingle();
  if (!email) return { email_id: emailId, status: "skipped", reason: "メールが見つかりません" };
  if (email.auto_category !== "sales_deposit" && email.mail_kind !== "sales") return { email_id: emailId, status: "skipped", reason: `売上入金のメールではありません（${email.auto_category ?? "未分類"}）` };
  const { data: existing } = await db.from("invoices").select("id").eq("email_id", emailId).limit(1);
  if (existing?.length) return markSkipped(db, emailId, "このメールには既に請求書（売上入金）があります");

  const { data: atts } = await db.from("invoice_attachments").select("id, file_name, mime_type, storage_path, size_bytes, ocr_done_at").eq("email_id", emailId).order("created_at");
  const isSeisan = /業務委託料精算書/.test(String(email.subject ?? ""));
  // 精算書メールには NTT・電気料金・カード売上などの添付も付くため、「精算書」で始まる名前のPDFだけを読む
  const pdfs = (atts ?? []).filter((a: any) => String(a.mime_type ?? "") === "application/pdf" && (a.size_bytes ?? 0) <= 15 * 1024 * 1024 && (!isSeisan || /^精算書/.test(String(a.file_name ?? ""))));
  if (!pdfs.length) return markSkipped(db, emailId, isSeisan ? "精算書のPDFの添付がありません" : "送金明細のPDFの添付がありません");

  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) return { email_id: emailId, status: "error", reason: "ANTHROPIC_API_KEY が未設定です" };

  const created: string[] = []; const notes: string[] = [];
  for (const att of pdfs) {
    const { data: blob, error: dlErr } = await db.storage.from("invoice-files").download(att.storage_path);
    if (dlErr || !blob) { notes.push(`${att.file_name}: ファイルを取得できませんでした`); continue; }
    const b64 = bytesToBase64(new Uint8Array(await blob.arrayBuffer()));
    const tool = isSeisan ? SEISAN_TOOL : TOOL;
    const call = (toolChoice: unknown) => fetch("https://api.anthropic.com/v1/messages", {
      method: "POST", headers: { "content-type": "application/json", "x-api-key": apiKey, "anthropic-version": "2023-06-01" },
      body: JSON.stringify({
        model: "claude-sonnet-5-5", max_tokens: 4000,
        system: "あなたは不動産の送金明細書を読み取る経理アシスタントです。表の数字は一桁ずつ正確に読み、書かれていない項目はnullにします。収入の明細は入居者（賃借人）ごとの行だけを入れ、「収入内訳」という合計欄は入れません。必ず extract_remittance_statement ツールで答えてください。",
        tools: [tool], tool_choice: toolChoice,
        messages: [{ role: "user", content: [{ type: "text", text: `メール件名: ${email.subject ?? ""}\n添付ファイル: ${att.file_name}\nこの送金明細書を読み取ってください。` }, { type: "document", source: { type: "base64", media_type: "application/pdf", data: b64 } }] }],
      }),
    });
    let res = await call({ type: "tool", name: tool.name });
    if (res.status === 400 && (await res.clone().text().catch(() => "")).includes("tool_choice")) res = await call({ type: "auto" });
    if (!res.ok) { notes.push(`${att.file_name}: AI読み取りに失敗（${res.status}）`); continue; }
    const j = await res.json();
    const ex = (j.content ?? []).find((c: any) => c.type === "tool_use")?.input;
    if (!ex) { notes.push(`${att.file_name}: 読み取り結果が得られませんでした`); continue; }

    if (isSeisan) {
      const rs = await buildSeisan(db, email, att, ex, created.length === 0);
      created.push(...rs.ids); notes.push(`${att.file_name}: ${rs.note}`);
    } else {
      const r = await buildAndSave(db, email, att, ex);
      if (r.invoice_id) created.push(r.invoice_id);
      notes.push(`${att.file_name}: ${r.note}`);
    }
    await db.from("invoice_attachments").update({ ocr_done_at: new Date().toISOString() }).eq("id", att.id);
  }
  await db.from("invoice_emails").update({ auto_invoice_at: new Date().toISOString(), auto_invoice_note: `売上入金: 下書き${created.length}件／${notes.join("／")}`.slice(0, 500) }).eq("id", emailId);
  return { email_id: emailId, status: created.length ? "created" : "none", created, notes };
}

async function buildAndSave(db: any, email: any, att: any, ex: any): Promise<{ invoice_id?: string; note: string }> {
  const problems: string[] = []; const warnings: string[] = [];
  const checks: any[] = [];
  const ck = (key: string, label: string, status: "ok" | "warn" | "ng" | "na", detail?: string) => { checks.push({ key, label, status, ...(detail ? { detail } : {}) }); if (status === "ng") problems.push(detail ? `${label}（${detail}）` : label); };

  // 送金者→取引先・法人
  const senderName = String(ex.sender ?? "株式会社ゼン・ランド");
  const v = await resolveVendor(db, senderName);
  ck("vendor", "取引先（送金者）が確定", v ? "ok" : "ng", v ? undefined : `「${senderName}」が取引先マスタにありません`);

  // 物件の仕訳の型
  const prop = norm(ex.property_name);
  const { data: rules } = await db.from("receivable_property_rules").select("*").eq("is_active", true);
  const rule = (rules ?? []).find((r: any) => prop && prop.includes(norm(r.property_pattern)) && (!v || normCompany(r.vendor_key) === normCompany(v.name)));
  ck("property", "物件の仕訳の型がある", rule ? "ok" : "ng", rule ? `${rule.property_label ?? rule.property_pattern}` : `物件「${ex.property_name ?? "不明"}」の仕訳の型が未登録です`);
  const corporationId = rule?.corporation_id ?? v?.corp ?? null;
  ck("corporation", "宛先の法人が確定", corporationId ? "ok" : "ng");

  // 金額の読み取りと検算
  const layout: string = rule?.layout ?? "by_tenant";   // by_tenant=入居者×税区分ごとに貸方（ゼン・ランド）／total=収入合計・支出合計の1行ずつ（Thumzの業務委託精算書）
  const incomeItems: any[] = (Array.isArray(ex.income_items) ? ex.income_items : []).filter((x: any) => toInt(x?.gross) || toInt(x?.net));
  const expenseItems: any[] = (Array.isArray(ex.expense_items) ? ex.expense_items : []).filter((x: any) => toInt(x?.gross) || toInt(x?.net));
  const grossOf = (x: any) => toInt(x?.gross) ?? ((toInt(x?.net) ?? 0) + (toInt(x?.tax) ?? 0));
  const netOf = (x: any) => toInt(x?.net) ?? ((toInt(x?.gross) ?? 0) - (toInt(x?.tax) ?? 0));
  const incomeSum = incomeItems.reduce((t, x) => t + grossOf(x), 0);
  const expenseSum = expenseItems.reduce((t, x) => t + grossOf(x), 0);
  const incomeTotal = toInt(ex.income_total?.gross), expenseTotal = toInt(ex.expense_total?.gross) ?? 0, remit = toInt(ex.remit_total?.gross);
  if (!incomeItems.length || remit == null) ck("read", "明細書の読み取り", "ng", "収入の明細または送金額（支払金額）を読み取れませんでした");
  else ck("read", "明細書の読み取り", "ok");
  if (layout === "total") {
    // 精算書は明細が税抜で書かれているため、税抜の明細合計＝税抜の小計で確認する
    const inNet = toInt(ex.income_total?.net), exNet = toInt(ex.expense_total?.net);
    const inSumNet = incomeItems.reduce((t, x) => t + netOf(x), 0), exSumNet = expenseItems.reduce((t, x) => t + netOf(x), 0);
    if (inNet != null) ck("income_sum", "収入（入金）の明細合計＝小計（税抜）", inSumNet === inNet ? "ok" : "ng", inSumNet === inNet ? undefined : `明細合計${inSumNet}／小計${inNet}`);
    if (exNet != null && expenseItems.length) ck("expense_sum", "経費の明細合計＝小計（税抜）", exSumNet === exNet ? "ok" : "ng", exSumNet === exNet ? undefined : `明細合計${exSumNet}／小計${exNet}`);
    const classes = new Set([...incomeItems, ...expenseItems].map((x) => String(x.tax_class ?? "taxable_10")));
    ck("tax_class", "税区分が10%課税のみ", classes.size === 1 && classes.has("taxable_10") ? "ok" : "ng", classes.size === 1 && classes.has("taxable_10") ? undefined : "10%課税以外の行があります（この形式は未対応のため、人が確認してください）");
  } else {
    if (incomeTotal != null) ck("income_sum", "収入の明細合計＝収入合計", incomeSum === incomeTotal ? "ok" : "ng", incomeSum === incomeTotal ? undefined : `明細合計${incomeSum}／収入合計${incomeTotal}`);
    if (expenseItems.length) ck("expense_sum", "支出の明細合計＝支出合計", expenseSum === expenseTotal ? "ok" : "ng", expenseSum === expenseTotal ? undefined : `明細合計${expenseSum}／支出合計${expenseTotal}`);
  }
  if (remit != null && incomeTotal != null) ck("remit", "収入合計−支出合計＝送金額（支払金額）", incomeTotal - expenseTotal === remit ? "ok" : "ng", incomeTotal - expenseTotal === remit ? undefined : `${incomeTotal}−${expenseTotal}≠${remit}`);

  const ym = /^\d{4}-\d{2}$/.test(String(ex.target_month ?? "")) ? String(ex.target_month) : null;
  if (!ym) warnings.push("対象月を読み取れませんでした（計上日は送金日にしています）");
  const remitDate0 = /^\d{4}-\d{2}-\d{2}$/.test(String(ex.remit_date ?? "")) ? String(ex.remit_date) : (ym ? monthEnd(ym) : String(email.received_at ?? "").slice(0, 10));
  const remitDate = rule?.date_basis === "month_end" && ym ? monthEnd(ym) : remitDate0;   // 計上日: 送金日（ゼン・ランド）／対象月の末日（Thumz）
  const month = ym ? Number(ym.slice(5, 7)) : null;
  const label = String(rule?.remark_label ?? ex.property_name ?? "");
  const mm = month ? `${month}月分` : "";
  const remarkBase = [label, mm].filter(Boolean).join("　");
  const remarkRecv = fillTpl(rule?.remark_recv_tpl, "{label}　{m}", { label, m: mm });
  const remarkFee = fillTpl(rule?.remark_fee_tpl, "{label}　{m}", { label, m: mm });

  // 仕訳の下書き
  const debitLines: any[] = []; const creditLines: any[] = [];
  if (rule && remit != null && incomeItems.length) {
    let ln = 1;
    debitLines.push({ line_no: ln++, store_id: null, store_name: null, remark: remarkRecv,
      debit: { account: rule.receivable_account, sub_account: rule.receivable_sub, department: null, tax: { kind: "purchase", rate: 0 }, amount: remit, net_amount: remit }, rule: { source: "ledger", version: 1 } });
    if (layout === "total") {
      if (expenseTotal > 0) debitLines.push({ line_no: ln++, store_id: null, store_name: null, remark: remarkFee,
        debit: { account: rule.fee_account, sub_account: rule.fee_sub, department: rule.department_name, tax: { kind: "purchase", rate: 10 }, amount: expenseTotal, net_amount: toInt(ex.expense_total?.net) ?? expenseTotal }, rule: { source: "ledger", version: 1 } });
      if (incomeTotal != null) creditLines.push({ line_no: 1, account: rule.revenue_account, sub_account: rule.revenue_sub, department: rule.department_name,
        tax: { kind: "sales", rate: 10, name: "課税売上 10%" }, amount: incomeTotal, remark: fillTpl(rule?.remark_rev_tpl, "{label}　{m}", { label, m: mm }) });
    } else {
      for (const x of expenseItems) {
        const rate = TAX_RATE[String(x.tax_class ?? "taxable_10")] ?? 10; const g = grossOf(x);
        debitLines.push({ line_no: ln++, store_id: null, store_name: null, remark: remarkFee,
          debit: { account: rule.fee_account, sub_account: rule.fee_sub, department: rule.department_name, tax: { kind: "purchase", rate }, amount: g, net_amount: toInt(x.net) ?? g }, rule: { source: "ledger", version: 1 } });
      }
      // 貸方: 入居者×税区分ごとに売上高
      const groups = new Map<string, { tenant: string; rate: number; gross: number }>();
      for (const x of incomeItems) {
        const rate = TAX_RATE[String(x.tax_class ?? "taxable_10")] ?? 10;
        const key = `${x.tenant ?? ""}|${rate}`; const g = groups.get(key) ?? { tenant: String(x.tenant ?? ""), rate, gross: 0 };
        g.gross += grossOf(x); groups.set(key, g);
      }
      let cn = 1;
      for (const g of groups.values()) {
        creditLines.push({ line_no: cn++, account: rule.revenue_account, sub_account: rule.revenue_sub, department: rule.department_name,
          tax: { kind: "sales", rate: g.rate, name: g.rate ? `課税売上 ${g.rate}%` : "対象外" }, amount: g.gross,
          remark: [remarkBase, g.tenant].filter(Boolean).join("　").slice(0, 100) }); // 摘要=「◯◯　9月分　入居者名」（ユーザー指示: 入居者名も入れる）
      }
    }
  }
  const debitTotal = debitLines.reduce((t, d) => t + d.debit.amount, 0), creditTotal = creditLines.reduce((t, c) => t + c.amount, 0);
  ck("balance", "仕訳の借方＝貸方", debitLines.length && debitTotal === creditTotal ? "ok" : "ng", debitLines.length ? (debitTotal === creditTotal ? undefined : `借方${debitTotal}／貸方${creditTotal}`) : "仕訳を作れませんでした");
  ck("pdf", "送金明細のPDFが添付されている", "ok");

  // 重複（同じ管理会社×物件×対象月）
  const bizKey = v && rule && ym ? `${v.id}|sales:${norm(rule.property_pattern)}|${ym}` : null;
  if (bizKey) {
    const { data: dup } = await db.from("invoices").select("id").eq("biz_key", bizKey).neq("invoice_status", "cancelled").limit(1);
    ck("duplicate", "重複なし", dup?.length ? "ng" : "ok", dup?.length ? "同じ物件・同じ対象月の送金明細が既にあります" : undefined);
  } else ck("duplicate", "重複なし", "na");

  const status = problems.length ? "needs_review" : "ok";
  const draft = {
    version: 1, kind: "sales_deposit", status, tenant_id: rule?.tenant_id ?? "nstyle", corporation_id: corporationId,
    transaction_date: remitDate, remark: remarkBase, debit_lines: debitLines, credit: null, credit_lines: creditLines,
    totals: { debit: debitTotal, credit: creditTotal, invoice_total: remit }, adjustments: [], problems, warnings, created_at: new Date().toISOString(),
  };
  const stage = problems.length ? "journal_draft" : "ready_for_approval";
  const blocked = problems.length ? problems.join("／") : null;

  const row: Record<string, unknown> = {
    email_id: email.id, attachment_id: att.id, source_attachment_id: att.id, source_message_id: email.gmail_message_id ?? null, received_at: email.received_at ?? null,
    vendor_name: v?.name ?? senderName, vendor_id: v?.id ?? null, corporation_id: corporationId, amount: remit, due_date: remitDate,
    target_year_month: ym ? `${ym}-01` : null, invoice_status: "draft", intake_source: "email_auto", biz_key: problems.some((p) => p.startsWith("重複")) ? null : bizKey,
    invoice_number: null, journal_draft: draft, journal_draft_at: new Date().toISOString(), current_stage: stage, blocked_reason: blocked,
    stage_updated_at: new Date().toISOString(), checks: { checks, routes: [], checked_at: new Date().toISOString() },
    auto_ocr: ex, auto_mode: "auto",
  };
  const { data: ins, error } = await db.from("invoices").insert(row).select("id").maybeSingle();
  if (error) {
    if (String(error.code) === "23505") return { note: "同じ物件・同じ対象月の送金明細が既にあるため、作成しませんでした" };
    return { note: "下書きの作成に失敗: " + error.message.slice(0, 150) };
  }
  await logAudit(db, email.id, "auto_invoice_created",
    `売上入金（送金明細）を自動で下書き作成（物件=${ex.property_name ?? "不明"}／対象月=${ym ?? "不明"}／送金額=${remit ?? "不明"}）→ ${stage === "ready_for_approval" ? "承認待ち" : "要確認: " + (blocked ?? "")}`, { invoice_id: ins!.id, stage });
  return { invoice_id: ins!.id as string, note: stage === "ready_for_approval" ? "承認待ちに並べました" : "要確認で止めました: " + (blocked ?? "") };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return json({ error: "POSTのみ対応" }, 405);
  let body: any;
  try { body = await req.json(); } catch { return json({ error: "JSONの読み取りに失敗しました" }, 400); }
  const db = svc();
  const { data: sr, error: se } = await db.from("app_secrets").select("value").eq("key", "invoice_intake_secret").maybeSingle();
  if (se) return json({ error: "シークレット確認に失敗しました: " + se.message }, 500);
  if (!sr?.value || body?.secret !== sr.value) return json({ error: "認証エラー" }, 401);
  try {
    if (body?.action === "scan") {
      const since = body.since ? new Date(body.since).toISOString() : new Date(Date.now() - 7 * 86400e3).toISOString();
      const limit = Math.min(Number(body.limit) || 10, 30);
      const { data: mails } = await db.from("invoice_emails").select("id").eq("auto_category", "sales_deposit").is("auto_invoice_at", null).gte("received_at", since).order("received_at", { ascending: true }).limit(limit);
      const results = [];
      for (const m of mails ?? []) results.push(await processEmail(db, m.id as string, body.secret));
      return json({ success: true, processed: results.length, results });
    }
    if (!body?.email_id) return json({ error: "email_id が必要です" }, 400);
    return json({ success: true, result: await processEmail(db, body.email_id, body.secret) });
  } catch (e) {
    return json({ error: "処理中にエラー: " + String((e as Error)?.message ?? e) }, 500);
  }
});
