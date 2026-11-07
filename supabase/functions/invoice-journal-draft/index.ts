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

const MF_TENANT_BY_CORP: Record<string, string> = { nstyle: "nstyle", toho: "default", livegate: "livegate", sk: "sk" };   // 2026-10-17: LiveGate事業者を追加（黒霧屋 新横浜の運営変更 2026-11-01）

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
    // 2026-10-19: MF未連携の法人（SKなど）をトーホーのMFへ誤って登録しないよう、無言のdefault落ちをやめて要対応にする
    if (corpCode && !MF_TENANT_BY_CORP[corpCode]) problems.push(`この法人（${corpCode}）はマネーフォワードに未連携です。連携するまで仕訳登録に進めません（トーホーのMFには登録しません）`);
  } else problems.push("宛先の法人が未確定です");

  // 行ルール（有効な最新版。直近90日の修正回数つきのビュー）と取引先の決まり
  const { data: rulesAll } = vendor
    ? await db.from("v_vendor_line_rule_status").select("*").eq("vendor_id", vendor.id).eq("tenant_id", tenantId)
    : { data: [] as any[] };
  let rules = rulesAll ?? [];
  // インフォマート（CSV）由来で行ルールが無い取引先: CSVの既定（仕入高／補助科目=取引先名／貸方=買掛金）を「提案」として下書きに出す。
  // 提案は常に要確認（自動OKにしない）。人が確認して「今後この内容で処理する」を保存するとルールになり、次回から自動で作れる。
  let proposed = false;
  // 2026-10-17 法人移行（黒霧屋 運営変更）: このMF事業者（例: LiveGate）に取引先の行ルールがまだ無いときは、トーホーの行ルールの科目・補助科目を「提案」として流用する
  // （部門は店舗のMF部門名で宛先法人のMF事業者に対して解決されるため、同じ部門名をLiveGate側に作れば同じ形で組める）。人が内容を確認して承認すると、その事業者の行ルールとして保存される
  let tenantCopy = false;
  if (!rules.length && vendor && tenantId !== "default") {
    const { data: base } = await db.from("v_vendor_line_rule_status").select("*").eq("vendor_id", vendor.id).eq("tenant_id", "default");
    if (base?.length) { rules = base.map((r: any) => ({ ...r, id: null, version: 0, source: "proposed", unstable: false })); proposed = true; tenantCopy = true; }
  }
  if (!rules.length && vendor && inv.intake_source === "infomart") {
    proposed = true;
    rules = [{ id: null, version: 0, source: "proposed", line_pattern: "*", account_name: "仕入高", sub_account_mode: "vendor", sub_account_name: null,
      tax_mode: "by_line", expected_tax_rates: null, credit_account: "買掛金", credit_sub_mode: "vendor", credit_sub_name: null, dept_mode: "line_store", unstable: false }];
  }
  // 2026-10-14: 行ルールが無い取引先（インフォマート以外：メール・アップロード）は、過去にMFへ登録した同じ取引先の仕訳（借方の科目・補助科目）を
  // 「提案」として下書きに出す。貸方は科目で推定（仕入高→買掛金／それ以外→未払金・補助科目=取引先名）。提案は status='proposed'（承認待ちには進むが、
  // 人が必ず内容を確認して承認する。承認すると行ルールとして保存され、次回から自動）。過去の仕訳が無ければ従来どおり要確認。
  let proposedKind: "csv" | "history" | "tenant_copy" | null = tenantCopy ? "tenant_copy" : proposed ? "csv" : null;
  if (!rules.length && vendor && !proposed) {
    const { data: vs } = await db.from("vendors").select("id, name");
    const nn = (s: unknown) => String(s ?? "").normalize("NFKC").replace(/\s+/g, "").replace(/株式会社|有限会社|合同会社|㈱|㈲|\(株\)|\(有\)/g, "").toLowerCase();
    const ids = (vs ?? []).filter((x: any) => nn(x.name) === nn(vendor.name)).map((x: any) => x.id);
    const { data: past } = await db.from("invoices").select("mf_debit_accounts, mf_journal_created_at").in("vendor_id", ids.length ? ids : [vendor.id])
      .not("mf_journal_id", "is", null).not("mf_debit_accounts", "is", null).order("mf_journal_created_at", { ascending: false }).limit(5);
    const label = (past ?? []).map((r: any) => (Array.isArray(r.mf_debit_accounts) ? r.mf_debit_accounts[0] : null)).find((x: any) => typeof x === "string" && x.length);
    if (label) {
      const i = String(label).indexOf("/"); const acc = i < 0 ? String(label) : String(label).slice(0, i); const sub = i < 0 ? "" : String(label).slice(i + 1);
      const vn = nn(vendor.name);
      rules = [{ id: null, version: 0, source: "proposed", line_pattern: "*", account_name: acc,
        sub_account_mode: sub ? (nn(sub) === vn || vn.includes(nn(sub)) || nn(sub).includes(vn) ? "vendor" : "fixed") : "none", sub_account_name: sub || null,
        tax_mode: "by_line", expected_tax_rates: null, credit_account: acc === "仕入高" ? "買掛金" : "未払金", credit_sub_mode: "vendor", credit_sub_name: null, dept_mode: "line_store", unstable: false }];
      proposed = true; proposedKind = "history";
    }
  }
  const { data: policy } = vendor ? await db.from("vendor_invoice_policies").select("*").eq("vendor_id", vendor.id).eq("tenant_id", tenantId).maybeSingle() : { data: null };
  if (vendor && !rules.length) problems.push(`この取引先の行ルールがありません（「今後この内容で処理する」で登録すると次回から自動で作れます）`);
  if (proposed && proposedKind === "tenant_copy") warnings.push("法人が変わった（またはこのMF事業者では初めての）取引先です。トーホーの行ルール（科目・補助科目）を流用して提案しています。宛先法人のMF事業者に同じ補助科目・部門があるか確認して承認してください（承認すると、この事業者の行ルールとして保存されます）。");
  else if (proposed && proposedKind === "history") warnings.push("初回の提案です（過去にMFへ登録した同じ取引先の仕訳から、科目・補助科目を提案しています。貸方は科目から推定）。内容を確認して承認すると、次回から自動で作られます。");
  else if (proposed) warnings.push("初回の提案です（CSVの既定：仕入高／補助科目=取引先名／貸方=買掛金）。内容を確認して承認すると、次回から自動で作られます。");
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
    // 店舗×MF事業者ごとの部門名（黒霧屋 新横浜の運営変更: LiveGateのMFでは部門名が違う）。無ければ従来どおり店舗マスタの部門名
    if (tenantId !== "default") {
      const { data: td } = await db.from("store_tenant_departments").select("store_id, department_name").eq("tenant_id", tenantId).in("store_id", storeIds as string[]);
      for (const t of td ?? []) { const st = stores.get(t.store_id); if (st) stores.set(t.store_id, { ...st, mf_department_name: t.department_name }); }
    }
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
      if (!st) { if (!l.resolve_info?.no_store_needed) problems.push(`行${l.line_no}: 店舗が未確定です（${l.store_text ?? l.store_code ?? "店舗の記載なし"}）`); }   // 2026-10-19: 人が「店舗は不要」とした行（精算書・経費へ入力済み等）は止めない
      else { storeName = st.name; deptName = st.mf_department_name ?? null; if (!deptName) problems.push(`行${l.line_no}: 店舗「${st.name}」にMF部門名が登録されていません`); }
    } else if (rule.dept_mode === "primary_store") {
      const sid = inv.store_id ?? vendor?.default_store_id ?? null;
      if (!sid) problems.push(`行${l.line_no}: 取引先の主な店舗が未設定です`);
      else {
        const { data: st } = await db.from("stores").select("id, name, mf_department_name").eq("id", sid).maybeSingle();
        let tdn: string | null = null;
        if (tenantId !== "default") { const { data: td1 } = await db.from("store_tenant_departments").select("department_name").eq("tenant_id", tenantId).eq("store_id", sid).maybeSingle(); tdn = td1?.department_name ?? null; }
        storeName = st?.name ?? null; deptName = tdn ?? st?.mf_department_name ?? null;
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
    version: 1, status: problems.length ? "needs_review" : proposed ? "proposed" : "ok", proposed_kind: proposedKind,
    tenant_id: tenantId, corporation_id: corporationId, corp_code: corpCode,
    transaction_date: transactionDate, remark: [monthLabel, vendorSub].filter(Boolean).join("　"),
    debit_lines: debitLines, credit, totals: { debit: debitLines.reduce((t, d) => t + d.debit.amount, 0), credit: credit?.amount ?? null, invoice_total: total },
    adjustments, problems, warnings, created_at: new Date().toISOString(),
  };
  await db.from("invoices").update({ journal_draft: draft, journal_draft_at: new Date().toISOString(), rule_unstable: unstable, updated_at: new Date().toISOString() }).eq("id", inv.id);
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
