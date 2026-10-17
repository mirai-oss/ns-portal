// 請求書メール自動処理 Phase6: 検算・異常判定・処理の段階（担当C・2026-10-13）
//
// 自動で作った請求書（明細・店舗・仕訳の下書きまで進んだもの）を判定し、invoices.checks（判定結果）・current_stage（処理の段階）・
// blocked_reason（止まっている理由）を更新する。MFには何も登録しない。
// 判定: ①明細合計=税抜合計(±1円)・数量×単価 ②税の整合（税抜＋税＝税込・税率別） ③取引先・法人・店舗の未解決ゼロ ④仕訳の下書きが要確認なし
//       ⑤重複（既存の重複疑い・同じ取引先の請求番号/金額×期限・定期取引先は月1枚で2枚目）⑥前月同取引先との乖離±30%
//       ⑦振込先が取引先の登録口座と一致（登録口座が無ければ「未登録」扱いで警告）⑧ルート振り分け（行の店舗が業務委託精算対象なら精算書／それ以外はPL。1行は1ルート）
// 段階: received→parsed→mapping→journal_draft→ready_for_approval（承認待ち）。止まったら blocked_reason に理由。error=明細が読めない等。
// 人のロック: auto_mode='manual'（人が手動に切り替えた）の請求書、または approved 以降の段階には自動で書かない。
// 例外タスク: automation_rule_settings.invoice_exception_tasks が ON のときだけ、止まった理由を hq_create_exception_task（べき等）で発行／解消で自動完了。
// 認証: 共有シークレットまたはユーザーJWT（invoice_can_access）。入力: { secret?, invoice_id }
import { createClient } from "npm:@supabase/supabase-js@2";
import { operatorCorpMap } from "../_shared/store-operator.ts";

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

type Check = { key: string; label: string; status: "ok" | "warn" | "ng" | "na"; detail?: string; reason?: string };
const LOCKED_STAGES = ["approved", "payment_waiting", "paid", "completed"];
const digits = (s: unknown) => String(s ?? "").normalize("NFKC").replace(/\D/g, "");
const CORP_TASK_NAME: Record<string, string> = { toho: "トーホー", nstyle: "N-Style" };

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
  if (inv.auto_mode === "manual") return json({ success: true, skipped: true, reason: "人が手動に切り替えた請求書のため、自動では更新しません" });
  if (inv.current_stage && LOCKED_STAGES.includes(inv.current_stage)) return json({ success: true, skipped: true, reason: "承認済み以降の請求書です" });
  if (inv.mf_journal_id) return json({ success: true, skipped: true, reason: "既にMF仕訳が登録済みです" });

  const { data: lines } = await db.from("invoice_lines").select("*").eq("invoice_id", inv.id).order("line_no");
  const draft = inv.journal_draft as any;
  const lc = (inv.lines_check ?? {}) as any;
  const checks: Check[] = [];

  // ①② 明細の検算・税の整合（Phase3の結果を判定へ）
  if (!lines?.length) {
    checks.push({ key: "lines_total", label: "明細合計＝請求合計", status: inv.lines_extracted_at ? "ng" : "na", detail: inv.lines_extracted_at ? "明細行を読み取れませんでした" : "明細の読み取り待ち", reason: "ocr_failed" });
  } else {
    const probs: string[] = Array.isArray(lc.problems) ? lc.problems : [];
    const totalProbs = probs.filter((p) => /合いません|違います|行が/.test(p) && !/税抜.*税.*税込/.test(p));
    const taxProbs = probs.filter((p) => /税抜.*税.*税込|税率.*内訳/.test(p));
    checks.push({ key: "lines_total", label: "明細合計＝請求合計（±1円）", status: totalProbs.length ? "ng" : "ok", detail: totalProbs.join("／") || `明細合計 ${lc.sum_lines ?? ""}`, reason: "amount_mismatch" });
    checks.push({ key: "tax", label: "税の整合", status: taxProbs.length ? "ng" : "ok", detail: taxProbs.join("／") || undefined, reason: "amount_mismatch" });
  }

  // ③ 取引先・法人・店舗の解決
  const unresolvedLines = (lines ?? []).filter((l: any) => !l.resolved_store_id).length;
  checks.push({ key: "vendor", label: "取引先が確定", status: inv.vendor_id ? "ok" : "ng", detail: inv.vendor_id ? undefined : "取引先マスタに結びついていません", reason: "vendor_unknown" });
  checks.push({ key: "corporation", label: "宛先の法人が確定", status: inv.corporation_id ? "ok" : "ng", reason: "corp_unresolved" });
  checks.push({ key: "stores", label: "明細の店舗が全て確定", status: !lines?.length ? "na" : unresolvedLines ? "ng" : "ok", detail: unresolvedLines ? `${unresolvedLines}行が未確定` : undefined, reason: "store_unresolved" });

  // PDF必須（証憑としてMFに添付する）。メール自動作成・インフォマート取込は、この請求書自身のPDFが無ければ承認に進めない
  if (["email_auto", "infomart", "upload_auto"].includes(inv.intake_source)) {
    const { count: attCount } = await db.from("invoice_attachments").select("id", { count: "exact", head: true }).eq("id", inv.source_attachment_id ?? "00000000-0000-0000-0000-000000000000");
    checks.push({ key: "pdf", label: "請求書のPDFが添付されている", status: attCount ? "ok" : "ng", detail: attCount ? undefined : "PDFが添付されていません（MFの証憑に付けられません）", reason: "ocr_failed" });
  }

  // ③-2 必要な証憑（TK-216④）: 取引先の方針(vendor_invoice_policies.required_evidence)に「納品書」などがあれば、その種類の添付があるか確認する（例: プレコフーズ＝納品書がインボイス）
  if (inv.vendor_id) {
    const { data: pol } = await db.from("vendor_invoice_policies").select("required_evidence, evidence_warning").eq("vendor_id", inv.vendor_id).eq("tenant_id", (draft?.tenant_id as string) || "default").maybeSingle();
    const need: string[] = Array.isArray(pol?.required_evidence) ? pol!.required_evidence : [];
    if (need.length) {
      const { data: haveRows } = await db.from("invoice_attachments").select("attachment_kind").eq("invoice_id", inv.id);
      const have = new Set((haveRows ?? []).map((r: any) => r.attachment_kind));
      const missing = need.filter((k) => !have.has(k));
      const KIND_LABEL: Record<string, string> = { delivery_note: "納品書", invoice: "請求書" };
      checks.push({ key: "evidence", label: `必要な証憑（${need.map((k) => KIND_LABEL[k] ?? k).join("・")}）が添付されている`, status: missing.length ? "ng" : "ok",
        detail: missing.length ? `${missing.map((k) => KIND_LABEL[k] ?? k).join("・")}が添付されていません。${pol?.evidence_warning ?? ""}`.trim() : undefined, reason: "evidence_missing" });
    }
  }

  // ④ 仕訳の下書き
  checks.push({ key: "journal_draft", label: "仕訳の下書き", status: !draft ? "na" : draft.status === "ok" ? "ok" : draft.status === "proposed" ? "warn" : "ng", detail: draft && draft.status === "proposed" ? "初回の提案です。内容を確認して承認すると、次回から自動になります" : draft && draft.status !== "ok" ? (draft.problems ?? []).slice(0, 3).join("／") : undefined, reason: "line_unknown" });

  // ⑤ 重複
  const dupNotes: string[] = [];
  if (inv.duplicate_suspected) dupNotes.push("メール添付が既存と同じファイル（重複疑い）");
  let dupNg = false;
  if (inv.vendor_id) {
    // 取引先マスタに同名の取引先が重複登録されていても見逃さない（同名の取引先IDを全部対象にする）
    const normC = (x: unknown) => String(x ?? "").normalize("NFKC").replace(/\s+/g, "").toLowerCase().replace(/株式会社|有限会社|合同会社|\(株\)|\(有\)|㈱|㈲/g, "");
    const { data: allV } = await db.from("vendors").select("id, name");
    const meV = (allV ?? []).find((v: any) => v.id === inv.vendor_id);
    const vids = meV ? (allV ?? []).filter((v: any) => normC(v.name) === normC(meV.name)).map((v: any) => v.id) : [inv.vendor_id];
    const { data: others } = await db.from("invoices").select("id, invoice_number, amount, due_date, target_year_month, created_at, invoice_status")
      .in("vendor_id", vids).neq("id", inv.id).neq("invoice_status", "cancelled");
    for (const o of others ?? []) {
      if (inv.invoice_number && o.invoice_number && o.invoice_number === inv.invoice_number) { dupNg = true; dupNotes.push(`同じ請求番号の請求書があります（${o.id}）`); }
      else if (inv.amount != null && o.amount != null && Number(o.amount) === Number(inv.amount) && o.due_date && inv.due_date && o.due_date === inv.due_date) { dupNg = true; dupNotes.push(`同じ金額・期限の請求書があります（${o.id}）`); }
    }
    // 定期取引先（行ルールあり）は月1枚が既定。同じ対象年月に先に作られた請求書があれば2枚目
    const { count: ruleCount } = await db.from("vendor_line_rules").select("id", { count: "exact", head: true }).eq("vendor_id", inv.vendor_id).eq("is_active", true);
    if (ruleCount && inv.target_year_month) {
      const same = (others ?? []).filter((o: any) => o.target_year_month === inv.target_year_month && String(o.created_at) < String(inv.created_at));
      if (same.length) { dupNg = true; dupNotes.push("定期請求書の取引先は月1枚が既定です（同じ対象月の請求書が先にあります＝2枚目）"); }
    }
  }
  checks.push({ key: "duplicate", label: "重複なし", status: dupNg ? "ng" : dupNotes.length ? "warn" : "ok", detail: dupNotes.join("／") || undefined, reason: "duplicate_suspected" });
  if (dupNg && !inv.duplicate_suspected) await db.from("invoices").update({ duplicate_suspected: true }).eq("id", inv.id);

  // ⑥ 前月比（同じ取引先の直近の請求書との乖離±30%）
  if (inv.vendor_id && inv.amount != null) {
    const { data: prevs } = await db.from("invoices").select("amount, target_year_month, created_at").eq("vendor_id", inv.vendor_id).neq("id", inv.id).neq("invoice_status", "cancelled").not("amount", "is", null).lt("created_at", inv.created_at).order("created_at", { ascending: false }).limit(1);
    const prev = prevs?.[0];
    if (prev && Number(prev.amount) > 0) {
      const ratio = (Number(inv.amount) - Number(prev.amount)) / Number(prev.amount);
      checks.push({ key: "mom", label: "前回比 ±30%以内", status: Math.abs(ratio) > 0.3 ? "warn" : "ok", detail: `前回 ${prev.amount} → 今回 ${inv.amount}（${(ratio * 100).toFixed(0)}%）` });
    } else checks.push({ key: "mom", label: "前回比 ±30%以内", status: "na", detail: "比較できる前回の請求書がありません" });
  }

  // ⑦ 振込先
  const bank = inv.auto_ocr ?? {};
  const hasInvBank = !!(bank.bank_account_number);
  if (inv.vendor_id) {
    // 取引先の登録口座（現在有効＋過去口座）。野村不動産コマースのように、店舗（物件）ごとに別の口座へ請求が来る取引先がある。
    const { data: accts } = await db.from("vendor_bank_accounts").select("bank_name, account_number, is_current, store_id").eq("vendor_id", inv.vendor_id);
    const invStoreIds = new Set<string>([...(inv.store_id ? [inv.store_id] : []), ...((lines ?? []).map((l: any) => l.resolved_store_id).filter(Boolean))]);
    if (!hasInvBank) checks.push({ key: "bank", label: "振込先が登録口座と一致", status: "na", detail: "請求書から振込先を読み取れていません" });
    else if (!accts?.length) checks.push({ key: "bank", label: "振込先が登録口座と一致", status: "warn", detail: "取引先に登録口座がありません（未登録扱い）" });
    else {
      const hit = accts.find((a: any) => digits(a.account_number) === digits(bank.bank_account_number));
      if (hit && hit.is_current && (!hit.store_id || invStoreIds.size === 0 || invStoreIds.has(hit.store_id))) checks.push({ key: "bank", label: "振込先が登録口座と一致", status: "ok" });
      else if (hit && hit.is_current) checks.push({ key: "bank", label: "振込先が登録口座と一致", status: "warn", detail: "請求書の口座は、この取引先の別の店舗用の口座と一致しています。店舗と口座の組み合わせを確認してください" });
      else if (hit) checks.push({ key: "bank", label: "振込先が登録口座と一致", status: "warn", detail: "請求書の口座は、この取引先の過去口座（別の店舗用など）と一致しています。現在有効な口座と違うので、振込先を確認してください" });
      else checks.push({ key: "bank", label: "振込先が登録口座と一致", status: "ng", detail: "請求書の口座が登録口座と異なります（口座変更の疑い）", reason: "bank_changed" });
    }
  }

  // ⑦-2 法人移行期間の検算（設計メモ_スマレジ複数契約対応 §10・黒霧屋 新横浜の運営変更 2026-11-01）
  // 対象: 設定(automation_rule_settings.corp_transition)の店舗の明細を含み、対象年月が期間内の請求書。宛先法人（請求書の宛先）と、その月の運営関係から期待される法人を比べる。
  // 一致しても不一致でも「法人移行期間」として必ず人が確認（一括承認の対象外にする）。不一致は理由を明示して要対応にする。仕訳の法人は宛先法人に従う（invoice-journal-draft）。
  try {
    const { data: tr } = await db.from("automation_rule_settings").select("enabled, params").eq("key", "corp_transition").maybeSingle();
    const ymT = String(inv.target_year_month ?? "").slice(0, 7);
    const tp: any = tr?.params ?? {};
    if (tr?.enabled && ymT && tp.from && tp.to && ymT >= tp.from && ymT <= tp.to && lines?.length) {
      const { data: tstores } = await db.from("stores").select("id, name").in("name", tp.store_names ?? []);
      const tIds = new Set((tstores ?? []).map((s: any) => s.id));
      const hit = (tstores ?? []).filter((s: any) => (lines ?? []).some((l: any) => l.resolved_store_id === s.id));
      if (tIds.size && hit.length) {
        const [yy, mm] = ymT.split("-").map(Number); const mEnd = new Date(Date.UTC(yy, mm, 0)).toISOString().slice(0, 10);
        const { data: rel } = await db.from("store_operation_relations").select("store_id, operator_entity_type, operator_entity_id, effective_from, effective_to")
          .in("store_id", hit.map((s: any) => s.id)).lte("effective_from", mEnd).order("effective_from", { ascending: false });
        const { data: corpsAll } = await db.from("corporations").select("id, name");
        const nm = (id: string | null) => (corpsAll ?? []).find((c: any) => c.id === id)?.name ?? (id ? "不明" : "未確定");
        const notes: string[] = []; let mismatch = false;
        for (const s of hit) {
          const r = (rel ?? []).find((x: any) => x.store_id === s.id && (!x.effective_to || x.effective_to >= mEnd.slice(0, 8) + "01"));
          const expected = r && r.operator_entity_type === "corporation" ? r.operator_entity_id : null;
          if (!expected) { mismatch = true; notes.push(`${s.name}: ${ymT}の運営会社が店舗マスタに未登録（期待法人を判定できません）`); continue; }
          if (expected !== inv.corporation_id) { mismatch = true; notes.push(`${s.name}: 宛先=${nm(inv.corporation_id)}・期待=${nm(expected)}（${ymT}の運営会社）`); }
          else notes.push(`${s.name}: 宛先=${nm(inv.corporation_id)}・期待=${nm(expected)}（一致）`);
        }
        checks.push({ key: "corp_transition", label: "法人移行期間（宛先法人を確認）", status: mismatch ? "ng" : "warn",
          detail: `${notes.join("／")}。移行期間のため、宛先法人を確認して承認してください（仕訳は宛先法人のMF事業者に作ります）`, reason: "corp_transition" });
      }
    }
  } catch (e) { console.error("法人移行期間の検算に失敗: " + e); }

  // ⑧ ルート振り分け（1行は1ルート。業務委託精算対象の店舗は精算書、それ以外はPL）
  const routes: any[] = [];
  const sids = [...new Set((lines ?? []).map((l: any) => l.resolved_store_id).filter(Boolean))] as string[];
  if (sids.length) {
    const { data: ss } = await db.from("stores").select("id, name, corporation_id, seisan_target, seisan_pl_categories_target").in("id", sids);
    const opMap = await operatorCorpMap(db, sids, inv.target_year_month);   // 運営会社が時期で変わる店舗（黒霧屋 新横浜）は、その月の運営会社で判定
    for (const s of ss ?? []) {
      let route = "pl";
      if (s.seisan_target) route = "seisan";
      else if (s.seisan_pl_categories_target) route = inv.corporation_id && inv.corporation_id === (opMap.get(s.id) ?? s.corporation_id) ? "pl" : "seisan";
      routes.push({ store_id: s.id, store_name: s.name, route });
    }
  }
  checks.push({ key: "routes", label: "反映先（PL／精算書）", status: routes.length ? "ok" : "na", detail: routes.length ? routes.map((r) => `${r.store_name}→${r.route === "seisan" ? "精算書" : "PL"}`).join("、") : undefined });

  // 段階の決定
  const ng = checks.filter((c) => c.status === "ng");
  let stage: string; let blocked: string | null = null;
  if (!lines?.length) {
    stage = inv.lines_extracted_at ? "error" : (inv.auto_ocr ? "parsed" : "received");
    blocked = inv.lines_extracted_at ? "明細行を読み取れませんでした" : "明細の読み取り待ち";
  } else if (ng.some((c) => ["vendor", "corporation", "stores"].includes(c.key))) {
    stage = "mapping"; blocked = ng.filter((c) => ["vendor", "corporation", "stores"].includes(c.key)).map((c) => `${c.label}: ${c.detail ?? "未確定"}`).join("／");
  } else if (!draft) {
    stage = "mapping"; blocked = "仕訳の下書き待ち";
  } else if (ng.length) {
    stage = "journal_draft"; blocked = ng.map((c) => `${c.label}${c.detail ? "（" + c.detail + "）" : ""}`).join("／");
  } else {
    stage = "ready_for_approval"; blocked = null;
  }

  const result = { checks, routes, stage, blocked_reason: blocked, checked_at: new Date().toISOString() };
  await db.from("invoices").update({ checks: result, current_stage: stage, blocked_reason: blocked, corp_transition: checks.some((c) => c.key === "corp_transition"), stage_updated_at: new Date().toISOString(), updated_at: new Date().toISOString() }).eq("id", inv.id);
  if (inv.email_id) {
    await db.from("invoice_audit_logs").insert({
      entity_type: "invoice_email", entity_id: inv.email_id, action: "auto_checked", actor_type: "ai",
      note: stage === "ready_for_approval" ? "検算・判定を通過（承認待ち）" : `段階=${stage}／${blocked}`, new_value: { invoice_id: inv.id, stage },
    });
  }

  // 例外タスク（設定がONのときだけ。理由別・べき等。解消したら自動完了）
  const { data: setting } = await db.from("automation_rule_settings").select("enabled").eq("key", "invoice_exception_tasks").maybeSingle();
  if (setting?.enabled) {
    let corpName = "トーホー";
    if (inv.corporation_id) { const { data: c } = await db.from("corporations").select("corp_code").eq("id", inv.corporation_id).maybeSingle(); if (c?.corp_code && CORP_TASK_NAME[c.corp_code]) corpName = CORP_TASK_NAME[c.corp_code]; }
    const reasons = new Set(ng.map((c) => c.reason).filter(Boolean) as string[]);
    for (const reason of ["vendor_unknown", "corp_unresolved", "store_unresolved", "line_unknown", "amount_mismatch", "duplicate_suspected", "bank_changed", "ocr_failed"]) {
      if (reasons.has(reason)) {
        const detail = ng.filter((c) => c.reason === reason).map((c) => c.detail ?? c.label).join("／");
        await db.rpc("hq_create_exception_task", { p_title: `請求書の確認（${inv.vendor_name ?? "取引先不明"}）: ${detail}`.slice(0, 120), p_reason: reason, p_corp: corpName, p_invoice_id: inv.id });
      } else {
        await db.rpc("hq_resolve_exception_task", { p_invoice_id: inv.id, p_reason: reason });
      }
    }
  }
  return json({ success: true, stage, blocked_reason: blocked, checks: checks.map((c) => `${c.status}:${c.key}`) });
});
