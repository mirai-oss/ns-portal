// 請求書メール自動処理 Phase5: 仕訳下書き（担当C・2026-10-13）
//
// 請求書の明細行（Phase3）・店舗の解決結果（Phase4）・取引先×明細の行ルール（vendor_line_rules・設計書§9-1）から、
// MFに登録する前の仕訳の下書き（invoices.journal_draft）を作る。仕訳辞書(mf_journal_templates)は使わない（設計書§9-2）。
//  ・借方: 明細行ごとに 勘定科目／補助科目／部門（その行の店舗のMF部門）／税区分（行の税率）／金額（税込）。出どころのルールid・版・source付き
//  ・貸方: ルールの貸方（仕入=買掛金／経費=未払金）・補助=取引先名・金額=請求の税込合計
//  ・税の1円調整: 行ごとに税抜×税率を切り捨てて税込にし、請求書の税込合計との差（小さい端数）を最大金額の行で調整（請求額と完全一致を優先）
//  ・要確認(needs_review)の条件: ルール無し／ルール不安定（直近90日に2回以上修正）／店舗・法人・取引先が未解決／税率が想定外・不明／
//    金額が合わない（調整できない差）／明細なし。ここで要確認でも下書きは作る（理由つき）
//  ・証憑の警告（例: プレコフーズは納品書がインボイス）は warnings に入れる
// MFのID（科目ID・税区分IDなど）は承認時(Phase8)に名前から解決する。このFunctionはMFに何も登録しない。
// 認証: 共有シークレット（app_secrets.invoice_intake_secret）またはユーザーJWT（invoice_can_access）
// 入力(JSON): { secret?, invoice_id }
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

const MF_TENANT_BY_CORP: Record<string, string> = { nstyle: "nstyle", toho: "default" };

function monthEnd(ym: string): string { // 'YYYY-MM' or 'YYYY-MM-DD' → その月の末日
  const [y, m] = ym.slice(0, 7).split("-").map(Number);
  const d = new Date(Date.UTC(y, m, 0));
  return d.toISOString().slice(0, 10);
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return json({ error: "POSTのみ対応" }, 405);
  let body: any;
  try { body = await req.json(); } catch { return json({ error: "JSONの読み取りに失敗しました" }, 400); }
  if (!body?.invoice_id) return json({ error: "invoice_idが必要です" }, 400);
  const db = svc();
  if (body?.secret) {
    const { data: sr } = await db.from("app_secrets").select("value").eq("key", "invoice_intake_secret").maybeSingle();
    if (!sr?.value || body.secret !== sr.value) return json({ error: "認証エラー" }, 401);
  } else {
    const { data: ok, error } = await userClient(req).rpc("invoice_can_access");
    if (error || ok !== true) return json({ error: "権限がありません" }, 403);
  }

  const { data: inv } = await db.from("invoices").select("*").eq("id", body.invoice_id).maybeSingle();
  if (!inv) return json({ error: "請求書が見つかりません" }, 404);
  if (inv.mf_journal_id) return json({ success: true, skipped: true, reason: "既にMF仕訳が登録済みです" });

  const problems: string[] = []; const warnings: string[] = [];
  const { data: lines } = await db.from("invoice_lines").select("*").eq("invoice_id", inv.id).order("line_no");
  if (!lines?.length) problems.push("明細行がありません（読み取り待ち、または読み取れませんでした）");

  // 取引先・法人・MF事業者
  const { data: vendor } = inv.vendor_id ? await db.from("vendors").select("id, name, default_corporation_id, default_store_id").eq("id", inv.vendor_id).maybeSingle() : { data: null };
  if (!vendor) problems.push("取引先が未確定です（取引先マスタに結びついていません）");
  const corporationId = inv.corporation_id ?? vendor?.default_corporation_id ?? null;
  let tenantId = "default", corpCode: string | null = null;
  if (corporationId) {
    const { data: c } = await db.from("corporations").select("corp_code").eq("id", corporationId).maybeSingle();
    corpCode = c?.corp_code ?? null;
    tenantId = (corpCode && MF_TENANT_BY_CORP[corpCode]) || "default";
  } else problems.push("宛先の法人が未確定です");

  // 行ルール（有効な最新版。直近90日の修正回数つきのビュー）と取引先の決まり
  const { data: rulesAll } = vendor
    ? await db.from("v_vendor_line_rule_status").select("*").eq("vendor_id", vendor.id).eq("tenant_id", tenantId)
    : { data: [] as any[] };
  const rules = rulesAll ?? [];
  const { data: policy } = vendor ? await db.from("vendor_invoice_policies").select("*").eq("vendor_id", vendor.id).eq("tenant_id", tenantId).maybeSingle() : { data: null };
  if (vendor && !rules.length) problems.push(`この取引先の行ルールがありません（「今後この内容で処理する」で登録すると次回から自動で作れます）`);
  if (policy?.evidence_warning) warnings.push(policy.evidence_warning);

  const pickRule = (l: any) => {
    const text = `${l.description ?? ""} ${l.item ?? ""}`;
    const specific = rules.filter((r: any) => r.line_pattern !== "*" && text.includes(r.line_pattern));
    return specific[0] ?? rules.find((r: any) => r.line_pattern === "*") ?? null;
  };

  // 取引先名（補助科目=取引先名のルール用）
  const vendorSub = vendor?.name ?? inv.vendor_name ?? "";
  const lc = inv.lines_check ?? {};
  const inclTax = lc.line_amounts_include_tax === true;
  const breakdown: any[] = Array.isArray(lc.tax_breakdown) ? lc.tax_breakdown.filter((b: any) => b?.subtotal) : [];
  const stores = new Map<string, any>();
  const storeIds = [...new Set((lines ?? []).map((l: any) => l.resolved_store_id).filter(Boolean))];
  if (storeIds.length) {
    const { data: ss } = await db.from("stores").select("id, name, mf_department_name").in("id", storeIds as string[]);
    for (const s of ss ?? []) stores.set(s.id, s);
  }
  const ym = inv.target_year_month ? String(inv.target_year_month).slice(0, 7) : null;
  const monthLabel = ym ? `${Number(ym.slice(5, 7))}月分` : "";

  const debitLines: any[] = [];
  let unstable = false;
  for (const l of lines ?? []) {
    const rule = pickRule(l);
    if (!rule) { if (rules.length) problems.push(`行${l.line_no}: この明細に合う行ルールがありません`); continue; }
    if (rule.unstable) unstable = true;
    // 税率: 行の税率→請求書の内訳が1つだけならそれ→ルールの想定が1つだけならそれ
    let rate: number | null = l.tax_rate != null ? Number(l.tax_rate) : null;
    if (rate == null && breakdown.length === 1) rate = Number(breakdown[0].rate);
    if (rate == null && Array.isArray(rule.expected_tax_rates) && rule.expected_tax_rates.length === 1) rate = Number(rule.expected_tax_rates[0]);
    if (rate == null) problems.push(`行${l.line_no}: 税率が読み取れず、特定できません`);
    else if (Array.isArray(rule.expected_tax_rates) && rule.expected_tax_rates.length && !rule.expected_tax_rates.includes(rate)) problems.push(`行${l.line_no}: 税率${rate}%はこの取引先の想定（${rule.expected_tax_rates.join("・")}%）と違います`);

    const amount = l.amount != null ? Number(l.amount) : null;
    if (amount == null) { problems.push(`行${l.line_no}: 金額が読み取れていません`); continue; }
    // 税込: 税込表記の請求書はそのまま／行に税額が書かれていれば（インフォマートのCSV等）その税額を使う／無ければ税抜×税率の切捨て
    const gross = inclTax || rate == null ? amount : (l.tax_amount != null ? amount + Math.round(Number(l.tax_amount)) : amount + Math.floor(amount * rate / 100));

    // 部門
    let deptName: string | null = null; let storeName: string | null = null;
    if (rule.dept_mode === "line_store") {
      const st = l.resolved_store_id ? stores.get(l.resolved_store_id) : null;
      if (!st) problems.push(`行${l.line_no}: 店舗が未確定です（${l.store_text ?? l.store_code ?? "店舗の記載なし"}）`);
      else { storeName = st.name; deptName = st.mf_department_name ?? null; if (!deptName) problems.push(`行${l.line_no}: 店舗「${st.name}」にMF部門名が登録されていません`); }
    } else if (rule.dept_mode === "primary_store") {
      const sid = inv.store_id ?? vendor?.default_store_id ?? null;
      if (!sid) problems.push(`行${l.line_no}: 取引先の主な店舗が未設定です`);
      else {
        const { data: st } = await db.from("stores").select("id, name, mf_department_name").eq("id", sid).maybeSingle();
        storeName = st?.name ?? null; deptName = st?.mf_department_name ?? null;
        if (!deptName) problems.push(`行${l.line_no}: 主な店舗にMF部門名がありません`);
      }
    } else { deptName = "本部"; }

    const sub = rule.sub_account_mode === "fixed" ? rule.sub_account_name : rule.sub_account_mode === "vendor" ? vendorSub : null;
    debitLines.push({
      line_no: l.line_no, source_line_id: l.id, store_id: l.resolved_store_id ?? null, store_name: storeName,
      debit: { account: rule.account_name, sub_account: sub, department: deptName, tax: rate == null ? null : { kind: "purchase", rate }, amount: gross, net_amount: inclTax ? null : amount },
      remark: [monthLabel, vendorSub, l.item ?? l.description ?? "", storeName ?? ""].filter(Boolean).join("　"),
      rule: { id: rule.id, version: rule.version, source: rule.source },
    });
  }
  if (unstable) problems.push("ルール不安定（直近90日に2回以上修正された取引先×明細があります）。毎回確認してください");

  // 貸方と1円調整
  const total = inv.amount != null ? Number(inv.amount) : null;
  const sumGross = debitLines.reduce((t, d) => t + d.debit.amount, 0);
  const adjustments: any[] = [];
  if (total == null) problems.push("請求書の税込金額が未確定です");
  else if (debitLines.length) {
    let diff = total - sumGross;
    if (diff !== 0) {
      const policyAdj = (policy?.tax_adjust_policy ?? "largest_line_1yen") === "largest_line_1yen";
      if (policyAdj && Math.abs(diff) <= 3) {
        const big = debitLines.reduce((a, b) => (b.debit.amount > a.debit.amount ? b : a));
        big.debit.amount += diff;
        adjustments.push({ type: "tax_rounding", line_no: big.line_no, amount: diff, note: "請求額と一致させるため最大金額の行で調整" });
        diff = 0;
      } else problems.push(`明細合計（税込${sumGross}）と請求額（${total}）が合いません（差${diff}）`);
    }
  }
  const creditRule = rules.find((r: any) => r.credit_account) ?? null;
  if (!creditRule && rules.length) problems.push("貸方の科目がルールにありません");
  const credit = creditRule ? {
    account: creditRule.credit_account,
    sub_account: creditRule.credit_sub_mode === "fixed" ? creditRule.credit_sub_name : creditRule.credit_sub_mode === "vendor" ? vendorSub : null,
    amount: total ?? sumGross,
  } : null;

  const transactionDate = ym ? monthEnd(ym) : monthEnd(String(inv.received_at ?? inv.created_at ?? new Date().toISOString()));
  if (!ym) warnings.push("対象年月が読み取れていないため、計上日は受信月の月末にしています（要確認）");
  const draft = {
    version: 1, status: problems.length ? "needs_review" : "ok",
    tenant_id: tenantId, corporation_id: corporationId, corp_code: corpCode,
    transaction_date: transactionDate, remark: [monthLabel, vendorSub].filter(Boolean).join("　"),
    debit_lines: debitLines, credit, totals: { debit: debitLines.reduce((t, d) => t + d.debit.amount, 0), credit: credit?.amount ?? null, invoice_total: total },
    adjustments, problems, warnings, created_at: new Date().toISOString(),
  };
  await db.from("invoices").update({ journal_draft: draft, journal_draft_at: new Date().toISOString(), updated_at: new Date().toISOString() }).eq("id", inv.id);
  if (inv.email_id) {
    await db.from("invoice_audit_logs").insert({
      entity_type: "invoice_email", entity_id: inv.email_id, action: "journal_draft", actor_type: "ai",
      note: `仕訳下書きを作成（${draft.status === "ok" ? "要確認なし" : "要確認: " + problems.join("／")}）`, new_value: { invoice_id: inv.id, status: draft.status },
    });
  }
  // Phase6: 下書きができたので検算・異常判定・処理の段階を更新する（待たずに別Functionへ依頼。secret経由のときだけ）
  if (body?.secret) {
    const kick = fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/invoice-check`, {
      method: "POST",
      headers: { "Content-Type": "application/json", apikey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, Authorization: `Bearer ${Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")}` },
      body: JSON.stringify({ secret: body.secret, invoice_id: inv.id }),
    }).catch((e) => console.error("検算の依頼に失敗: " + e));
    const er = (globalThis as any).EdgeRuntime;
    if (er?.waitUntil) er.waitUntil(kick);
  }
  return json({ success: true, status: draft.status, lines: debitLines.length, problems, warnings, adjustments, totals: draft.totals });
});
