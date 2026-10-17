// スマレジ給与明細API(budgets/monthly)の月次確定給与を sf_payroll_sync へ保存するEdge Function
// 2026-08-29 担当B（nippo）新規作成
//
// 位置づけ: 既存のsmaregi-payroll-reconcileは「見積もりと確定給与の差額チェック→LINEアラート」
//   目的の使い捨て取得だった（保存先が無かった）。この関数は同じAPIを使いつつ、
//   結果をsf_payroll_syncへ保存することに専念する（アラートは行わない・reconcileは無変更のまま）。
//   保存した値は①nippoのシフト調整画面の社員人件費見積もり②将来的な経営ダッシュボードの
//   社員人件費（現状スプレッドシート手入力）の置き換え検討、で使う想定。
//
// 呼び出し方: { year?: number, month?: number }  省略時は「今月」（reconcileは前月確定分を見るが、
//   こちらは計画用の参考値なので今月分もリアルタイムに欲しいという要望のため今月をデフォルトにする）
// 認可: CEO/HQ/マスターのユーザーJWT、またはservice_role直呼び（smaregi-payroll-reconcileと同じ方針）
//
// 2026-08-29追記（ユーザー確認・再訂正）: regularWage（基本給のみ）だけでは固定残業代等が漏れる
//   （青山純さんの実例: regularWage=22万円だが実際は固定残業代6万円が別についていた）。
//   人件費として使う主要な値は「支給額合計（totalAllowance・切上げ）から通勤手当を差し引いた額」
//   ＝本来の固定給（fixed_salary_amount）にする。当初totalTaxable（課税対象額）にしていたが、
//   これは所得税計算用の額（社会保険料控除後）でありユーザーの意図と異なると判明したため修正。
//   実データ検証済み: 青山純さん totalAllowance(293984)-transportation(13480)-交通費allowance(504)
//   =280,000円=regularWage(220,000)+fixedOvertimeWage(60,000)と完全一致
import { createClient } from "npm:@supabase/supabase-js@2";
import { loadContracts, getContractToken, loadLinks, API_BASE } from "../_shared/smaregi-contracts.ts";

// 2026-10-17 担当D: 複数契約対応。契約ごと（smaregi_contracts）にループし、従業員×契約リンク（employee_smaregi_links）の
// スタッフIDで給与明細を取得して、契約ごとに1行（sf_payroll_sync.contract_id）で保存する。兼務の人は契約ごとに2行になる。
const SCOPES = "timecard.salaries:read";

const cors: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });

const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

function jwtUid(req: Request): string {
  try {
    const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    return JSON.parse(atob(jwt.split(".")[1].replace(/-/g, "+").replace(/_/g, "/"))).sub ?? "";
  } catch (_) { return ""; }
}

// store_id=0 = 「総合給与」（全店舗合算）。店舗別の振り分けはsf_payroll_allocations（マスター手動入力）で行う
async function fetchMonthlyBudget(token: string, contract: string, staffId: string, year: number, month: number) {
  const url = `${API_BASE}/${contract}/timecard/budgets/monthly/0/${staffId}?year=${year}&month=${String(month).padStart(2, "0")}`;
  const res = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
  if (res.status === 404) return null; // その月の給与明細が無い（未確定 or 対象外）
  if (!res.ok) {
    const t = await res.text();
    throw new Error(`給与明細API error (staff ${staffId} ${year}-${month}): ${res.status} ${t}`);
  }
  const bodyJson = await res.json();
  const totalAllowance = Math.ceil(Number(bodyJson?.totalAllowance ?? 0));
  const commuteAllowance = Number(bodyJson?.allowanceWage?.transportation ?? 0);
  // 支給額合計から「交通費」「通勤」を含む名前の手当（allowance[]内）もあわせて差し引く
  // （transportation列だけでは拾えない、別建ての通勤関連手当が入っているケースがあるため）
  const allowanceListCommute = (bodyJson?.allowanceWage?.allowance ?? [])
    .filter((a: any) => /交通|通勤/.test(String(a?.label ?? "")))
    .reduce((s: number, a: any) => s + Number(a?.resultAmount ?? 0), 0);
  const fixedSalaryAmount = totalAllowance - commuteAllowance - allowanceListCommute;
  // 2026-08-31追加（B-16調査）: 控除内訳・差引支給額・有給関連もあわせて取り出す
  const deductions = bodyJson?.deductionWage ?? [];
  const deductionTotal = deductions.reduce((s: number, d: any) => s + Number(d?.resultAmount ?? 0), 0);
  return {
    regularWage: Number(bodyJson?.allowanceWage?.regularWage ?? 0),
    workingDayCount: Number(bodyJson?.shiftTime?.workingDayCount ?? 0),
    totalWorkingTime: Number(bodyJson?.shiftTime?.totalWorkingTime ?? 0),
    // 2026-08-29追加・訂正: 支給額合計(切上げ)−通勤手当＝本来の固定給を人件費の主要な値として使う。
    // 課税対象額(taxableAmount)は参考値として残すのみ（社会保険料控除後の額で意図と異なるため）
    taxableAmount: Math.ceil(Number(bodyJson?.totalTaxable ?? 0)),
    totalAllowance,
    fixedSalaryAmount,
    fixedOvertimeWage: Number(bodyJson?.allowanceWage?.fixedOvertimeWage ?? 0),
    commuteAllowance,
    deductions,
    deductionTotal,
    netPay: Number(bodyJson?.netPay ?? 0),
    paidHolidayUsedDays: Number(bodyJson?.shiftTime?.paidHolidayCount ?? 0),
    remainingPaidHolidayDays: Number(bodyJson?.shiftTime?.remainingPaidHoliday ?? 0),
    raw: bodyJson,
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const sb = svc();
    let body: any = {};
    try { body = await req.json(); } catch { /* GET等ボディなし */ }

    const authHeader = req.headers.get("Authorization") ?? "";
    const isServiceRole = authHeader.includes(Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? " ");
    if (!isServiceRole) {
      const uid = jwtUid(req);
      const { data: u } = await sb.from("users").select("role,is_master,is_active").eq("id", uid).maybeSingle();
      if (!u?.is_active || !(u.is_master || ["CEO", "HQ"].includes(u.role))) {
        return json({ ok: false, error: "権限がありません（CEO/HQ/マスターのみ）" }, 403);
      }
    }

    const nowJst = new Date(Date.now() + 9 * 3600 * 1000);
    const year = Number(body.year) || nowJst.getUTCFullYear();
    const month = Number(body.month) || nowJst.getUTCMonth() + 1;
    const yearMonth = `${year}-${String(month).padStart(2, "0")}`;

    // 対象月の期間（移籍で旧契約のリンクが月途中に閉じる場合も、その月の分は旧契約から取得する）
    const lastDay = new Date(Date.UTC(year, month, 0)).getUTCDate();
    const monthFrom = `${yearMonth}-01`, monthTo = `${yearMonth}-${String(lastDay).padStart(2, "0")}`;
    const contracts = await loadContracts(sb, body.contract_id ? String(body.contract_id) : undefined);
    if (!contracts.length) return json({ ok: false, error: "有効なスマレジ契約がありません（smaregi_contracts または環境変数）" }, 500);

    const synced: any[] = [];
    const skipped: any[] = [];
    const errors: string[] = [];
    const byContract: any[] = [];
    let contractsFailed = 0; // 認証・リンク取得そのものに失敗した契約の数

    for (const c of contracts) {
      const tag = `…${c.contract_id.slice(-3)}`;
      const sum = { contract: tag, label: c.label, synced: 0, skipped: 0, errors: 0 };
      byContract.push(sum);
      let token: string;
      let links: any[];
      try {
        token = await getContractToken(c.contract_id, SCOPES);
        links = await loadLinks(sb, c.contract_id, monthFrom, monthTo);
      } catch (e) { errors.push(`契約${tag}: ${String(e)}`); sum.errors++; contractsFailed++; continue; } // 契約単位で失敗を記録し、他の契約は続行
      for (const p of links) {
        const staffId = p.smaregi_staff_id as string;
        const name = p.users?.name ?? `smaregi_staff_id=${staffId}`;
        if (!p.users?.is_active) { skipped.push({ name, contract: tag, reason: "非アクティブ" }); sum.skipped++; continue; }
        try {
          const budget = await fetchMonthlyBudget(token, c.contract_id, staffId, year, month);
          if (!budget) { skipped.push({ name, contract: tag, reason: "その月の給与明細なし（404）" }); sum.skipped++; continue; }
          const { error } = await sb.from("sf_payroll_sync").upsert({
            user_id: p.user_id,
            year_month: yearMonth,
            contract_id: c.contract_id,
            regular_wage: budget.regularWage,
            working_day_count: budget.workingDayCount,
            total_working_minutes: budget.totalWorkingTime,
            taxable_amount: budget.taxableAmount,
            total_allowance: budget.totalAllowance,
            fixed_salary_amount: budget.fixedSalaryAmount,
            fixed_overtime_wage: budget.fixedOvertimeWage,
            commute_allowance: budget.commuteAllowance,
            deduction_total: budget.deductionTotal,
            deductions: budget.deductions,
            net_pay: budget.netPay,
            paid_holiday_used_days: budget.paidHolidayUsedDays,
            remaining_paid_holiday_days: budget.remainingPaidHolidayDays,
            raw: budget.raw,
            synced_at: new Date().toISOString(),
          }, { onConflict: "user_id,year_month,contract_id" });
          if (error) { errors.push(`${name}: 保存エラー ${error.message}`); sum.errors++; continue; }
          synced.push({ name, contract: tag, staffId, fixedSalaryAmount: budget.fixedSalaryAmount, totalAllowance: budget.totalAllowance });
          sum.synced++;
        } catch (e) {
          errors.push(`${name} (契約${tag} staff ${staffId}): ${String(e)}`); sum.errors++;
        }
      }
    }

    return json({ ok: contractsFailed < contracts.length, year, month, contracts: byContract, syncedCount: synced.length, synced, skippedCount: skipped.length, skipped, errorCount: errors.length, errors });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
