// 請求書の自動判定 Edge Function（会計・請求書処理の全面刷新 フェーズB-3・2026-09-03）
//
// invoices.htmlが請求書を保存した直後（メール「請求書として登録」／アップロード保存）に呼ぶ。
// 取引先マスタ・仕訳辞書（拡張済みmf_journal_templates）・自動処理ルール（automation_rule_settings）
// を突き合わせ、「自動処理候補にしてよいか（ai_match_status=auto）」「人間確認が必要か（review）」
// 「何かおかしいか（error）」を判定し、理由（ai_match_reasons）・信頼度（ai_confidence）・
// マッチした仕訳辞書（ai_matched_rule_id）・取引先/法人/店舗の推定結果をinvoicesへ書き込む。
//
// 【最重要の安全設計】このFunctionは判定結果をinvoicesへ書き込むだけで、マネーフォワードへの
// 仕訳登録は一切行わない。「自動処理候補」はあくまで一覧画面での一括処理チェックボックスの
// 事前ON状態・詳細モーダルでの仕訳テンプレート事前選択に使われるだけで、実際の登録は必ず
// 人間がボタンを押す既存のmf-journal（create/create_standalone）からのみ行われる。
//
// 入力(JSON): {
//   invoice_id,
//   bank_name?, bank_branch_name?, bank_account_type?, bank_account_number?, bank_account_holder?
//     // 請求書から読み取った（invoice-ocrのbank_*フィールド）振込先口座。渡された場合のみ
//     // 取引先の登録済み口座と比較し、異なれば変更申請(vendor_bank_account_change_requests)を作る
// }
// 出力(JSON): { success:true, ai_match_status, ai_match_reasons, ai_confidence, vendor_id, corporation_id,
//   store_id, matched_rule_id, bank_account_change_detected }
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

function normalizeName(s: string): string {
  return String(s ?? "").replace(/\s+/g, "").toLowerCase();
}
function matchVendor(vendors: any[], name: string): { id: string; confidence: number } | null {
  const n = normalizeName(name);
  if (!n) return null;
  const exact = vendors.find((v) => normalizeName(v.name) === n || (v.name_aliases ?? []).some((a: string) => normalizeName(a) === n));
  if (exact) return { id: exact.id, confidence: 99 };
  const partial = vendors.filter((v) => {
    const vn = normalizeName(v.name);
    return vn && (n.includes(vn) || vn.includes(n));
  });
  if (partial.length === 1) return { id: partial[0].id, confidence: 75 };
  return null;
}
// 仕訳辞書（拡張済みmf_journal_templates）のマッチング。優先度(priority昇順)で最初に条件を満たすものを採用
function matchRule(templates: any[], ctx: { vendorId: string | null; text: string; fromAddress: string; amount: number; source: string | null }): any | null {
  const candidates = templates.filter((t) => {
    if (t.vendor_id && t.vendor_id !== ctx.vendorId) return false;
    if (Array.isArray(t.match_keywords) && t.match_keywords.length) {
      const hit = t.match_keywords.some((kw: string) => kw && ctx.text.toLowerCase().includes(String(kw).toLowerCase()));
      if (!hit && !t.vendor_id) return false; // vendor_idも無くキーワードにも当たらなければ対象外
    }
    if (Array.isArray(t.match_from_addresses) && t.match_from_addresses.length) {
      const hit = t.match_from_addresses.some((a: string) => a && ctx.fromAddress.toLowerCase().includes(String(a).toLowerCase()));
      if (!hit && !t.vendor_id && !(Array.isArray(t.match_keywords) && t.match_keywords.length)) return false;
    }
    if (t.amount_min != null && ctx.amount < Number(t.amount_min)) return false;
    if (t.amount_max != null && ctx.amount > Number(t.amount_max)) return false;
    if (Array.isArray(t.source_filter) && t.source_filter.length && ctx.source && !t.source_filter.includes(ctx.source)) return false;
    // 判定条件を何も持たない汎用プリセットは自動照合の対象にしない（既存の「よく使う仕訳」を誤って自動適用しないため）
    if (!t.vendor_id && !(t.match_keywords?.length) && !(t.match_from_addresses?.length)) return false;
    return true;
  });
  if (!candidates.length) return null;
  candidates.sort((a, b) => (a.priority ?? 100) - (b.priority ?? 100));
  return candidates[0];
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return json({ error: "POSTのみ対応" }, 405);

  let body: any;
  try { body = await req.json(); } catch { return json({ error: "JSONの読み取りに失敗しました" }, 400); }
  const invoiceId = body?.invoice_id;
  if (!invoiceId) return json({ error: "invoice_idは必須です" }, 400);

  const uc = userClient(req);
  const { data: canAccess, error: accessErr } = await uc.rpc("invoice_can_access");
  if (accessErr || canAccess !== true) return json({ error: "権限がありません" }, 403);

  try {
    const { data: inv, error: invErr } = await uc.from("invoices")
      .select("id, vendor_name, invoice_number, due_date, amount, intake_source, vendor_id, corporation_id, store_id, duplicate_suspected, email:invoice_emails(subject, from_address)")
      .eq("id", invoiceId).maybeSingle();
    if (invErr) return json({ error: "請求書の取得に失敗しました: " + invErr.message }, 500);
    if (!inv) return json({ error: "対象が見つからないか権限がありません" }, 403);

    const db = svc();
    const [{ data: vendors }, { data: templates }, { data: rules }] = await Promise.all([
      uc.from("vendors").select("id, name, name_aliases, default_corporation_id, default_store_id").eq("is_active", true),
      uc.from("mf_journal_templates").select("id, vendor_id, match_keywords, match_from_addresses, amount_min, amount_max, source_filter, priority, auto_apply, require_human_review"),
      uc.from("automation_rule_settings").select("*"),
    ]);
    const ruleByKey = new Map((rules ?? []).map((r: any) => [r.key, r]));

    // ①取引先マッチ（既に手動でvendor_idが設定済みならそれを尊重し、上書きしない）
    let vendorId: string | null = inv.vendor_id ?? null;
    let vendorConfidence = vendorId ? 100 : 0;
    if (!vendorId) {
      const m = matchVendor(vendors ?? [], inv.vendor_name ?? "");
      if (m) { vendorId = m.id; vendorConfidence = m.confidence; }
    }
    const vendor = (vendors ?? []).find((v: any) => v.id === vendorId) ?? null;

    // ②仕訳辞書ルールのマッチ
    const emailObj: any = Array.isArray(inv.email) ? inv.email[0] : inv.email;
    const matchText = `${inv.vendor_name ?? ""} ${emailObj?.subject ?? ""}`;
    const matchedRule = matchRule(templates ?? [], {
      vendorId, text: matchText, fromAddress: emailObj?.from_address ?? "",
      amount: Number(inv.amount) || 0, source: inv.intake_source ?? null,
    });

    // ③法人・店舗の推定（ルール指定 > 取引先の既定値 > 既存invoice値）
    const corporationId = matchedRule?.target_corporation_id ?? vendor?.default_corporation_id ?? inv.corporation_id ?? null;
    const storeId = matchedRule?.target_store_id ?? vendor?.default_store_id ?? inv.store_id ?? null;

    // ④重複請求の検知（2026-09-04・指示書STEP10。従来は外部で立てられたduplicate_suspected
    // フラグの表示のみだったが、ここで実際にビジネスキー（取引先＋金額＋（請求書番号 or 支払期限の
    // 年月））による重複判定を行う。添付ファイルのハッシュ一致とは別の観点＝請求書番号や日付を
    // 変えて再送されたような「見た目は違うが実質同じ請求」も拾える）
    let businessKeyDuplicate = false;
    {
      let q = uc.from("invoices").select("id, invoice_number, due_date")
        .neq("id", invoiceId)
        .eq("amount", inv.amount)
        .limit(20);
      if (vendorId) q = q.eq("vendor_id", vendorId);
      else if (inv.vendor_name) q = q.eq("vendor_name", inv.vendor_name);
      else q = q.eq("id", invoiceId); // 取引先も金額の手がかりも無ければ照合しない（0件になる）
      const { data: candidates } = await q;
      const dueYm = inv.due_date ? String(inv.due_date).slice(0, 7) : null;
      const invNumber = String(inv.invoice_number ?? "").trim();
      for (const c of candidates ?? []) {
        const cNumber = String(c.invoice_number ?? "").trim();
        const cYm = c.due_date ? String(c.due_date).slice(0, 7) : null;
        if (invNumber && cNumber && invNumber === cNumber) { businessKeyDuplicate = true; break; }
        if (dueYm && cYm && dueYm === cYm) { businessKeyDuplicate = true; break; }
      }
    }
    const duplicateSuspected = !!inv.duplicate_suspected || businessKeyDuplicate;

    // ⑤振込先口座変更検知
    let bankChangeDetected = false;
    const bankFields = {
      bank_name: body?.bank_name || null, branch_name: body?.bank_branch_name || null,
      account_type: body?.bank_account_type || null, account_number: body?.bank_account_number || null,
      account_holder: body?.bank_account_holder || null,
    };
    if (vendorId && (bankFields.account_number || bankFields.bank_name)) {
      const { data: currentAccount } = await uc.from("vendor_bank_accounts").select("*").eq("vendor_id", vendorId).eq("is_current", true).maybeSingle();
      if (currentAccount) {
        const differs = (bankFields.account_number && bankFields.account_number !== currentAccount.account_number)
          || (bankFields.bank_name && currentAccount.bank_name && bankFields.bank_name !== currentAccount.bank_name);
        if (differs) {
          bankChangeDetected = true;
          await db.from("vendor_bank_account_change_requests").insert({
            vendor_id: vendorId, invoice_id: invoiceId,
            proposed_bank_name: bankFields.bank_name, proposed_branch_name: bankFields.branch_name,
            proposed_account_type: bankFields.account_type, proposed_account_number: bankFields.account_number,
            proposed_account_holder_kana: bankFields.account_holder,
          });
        }
      }
      // currentAccountが無い（初めての取引先）場合は「変更」ではないため検知しない
    }

    // ⑥金額異常（同じ取引先の直近5件の平均と比べる。履歴が無ければ判定しない）
    let amountAnomaly = false;
    if (vendorId) {
      const { data: history } = await uc.from("invoices").select("amount").eq("vendor_id", vendorId).neq("id", invoiceId).order("created_at", { ascending: false }).limit(5);
      const amounts = (history ?? []).map((r: any) => Number(r.amount)).filter((n: number) => Number.isFinite(n) && n > 0);
      if (amounts.length >= 2) {
        const avg = amounts.reduce((s, n) => s + n, 0) / amounts.length;
        const thresholdPct = Number(ruleByKey.get("amount_anomaly")?.params?.threshold_pct ?? 150);
        if (avg > 0 && Number(inv.amount) > avg * (thresholdPct / 100)) amountAnomaly = true;
      }
    }

    // ⑦自動処理ルールの評価（自然文の理由付きで判定。block優先→review→auto）
    const reasons: string[] = [];
    let hasBlock = false, hasReview = false;
    const checkGate = (key: string, triggered: boolean) => {
      const rule = ruleByKey.get(key);
      if (!rule || !rule.enabled || !triggered) return;
      reasons.push(rule.label);
      if (rule.action === "block") hasBlock = true;
      else if (rule.action === "require_review") hasReview = true;
    };
    checkGate("duplicate_suspected", duplicateSuspected);
    checkGate("corporation_unknown", !corporationId);
    checkGate("store_unknown", !storeId);
    checkGate("new_vendor", !vendorId);
    checkGate("bank_account_change", bankChangeDetected);
    checkGate("amount_anomaly", amountAnomaly);
    const exactMatchRule = ruleByKey.get("journal_rule_exact_match");
    const hasAutoCandidate = !!(matchedRule?.auto_apply && !matchedRule?.require_human_review && exactMatchRule?.enabled);

    let aiMatchStatus: "auto" | "review" | "error";
    if (hasBlock || hasReview) aiMatchStatus = "review";
    else if (hasAutoCandidate) aiMatchStatus = "auto";
    else aiMatchStatus = "review"; // ルール不一致・判定材料不足はデフォルトで人間確認へ（安全側）

    const confidence = {
      vendor: vendorConfidence,
      corporation: corporationId ? 90 : 0,
      store: storeId ? 90 : 0,
      account: matchedRule ? 90 : 0,
    };

    const updatePatch: Record<string, unknown> = {
      ai_match_status: aiMatchStatus,
      ai_match_reasons: reasons,
      ai_confidence: confidence,
      ai_matched_rule_id: matchedRule?.id ?? null,
      bank_account_change_detected: bankChangeDetected,
    };
    if (!inv.vendor_id && vendorId) updatePatch.vendor_id = vendorId;
    if (!inv.corporation_id && corporationId) updatePatch.corporation_id = corporationId;
    if (!inv.store_id && storeId) updatePatch.store_id = storeId;
    // 新たにビジネスキー重複を検知した場合のみ書き込む（既存フラグがtrueなのにここでfalseの
    // 場合は上書きしない＝他の仕組みが立てたduplicate_suspectedを消さない）
    if (businessKeyDuplicate && !inv.duplicate_suspected) updatePatch.duplicate_suspected = true;

    const { error: updErr } = await uc.from("invoices").update(updatePatch).eq("id", invoiceId);
    if (updErr) return json({ error: "判定結果の保存に失敗しました: " + updErr.message }, 500);

    return json({
      success: true, ai_match_status: aiMatchStatus, ai_match_reasons: reasons, ai_confidence: confidence,
      vendor_id: vendorId, corporation_id: corporationId, store_id: storeId,
      matched_rule_id: matchedRule?.id ?? null, bank_account_change_detected: bankChangeDetected,
      duplicate_suspected: duplicateSuspected,
    });
  } catch (e) {
    return json({ error: "予期しないエラー: " + String(e) }, 500);
  }
});
