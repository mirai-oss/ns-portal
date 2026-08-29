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
// 2026-08-29追記（ユーザー確認済み）: regularWage（基本給のみ）だけでは固定残業代等が漏れる
//   （青山純さんの実例で確認: regularWage=22万円だが実際は固定残業代6万円が別についていた）。
//   人件費として使う主要な値は totalTaxable（課税対象額・切上げ）にする。
//   通勤手当は allowanceWage.transportation を自動取得（手入力の上乗せはsf_payroll_allocations側）。
import { createClient } from "npm:@supabase/supabase-js@2";

const IS_PROD = Deno.env.get("SMAREGI_ENV") === "prod";
const ID_BASE = IS_PROD ? "https://id.smaregi.jp" : "https://id.smaregi.dev";
const API_BASE = IS_PROD ? "https://api.smaregi.jp" : "https://api.smaregi.dev";
const CONTRACT = Deno.env.get("SMAREGI_CONTRACT_ID") ?? "";
const CID = Deno.env.get("SMAREGI_CLIENT_ID") ?? "";
const SECRET = Deno.env.get("SMAREGI_CLIENT_SECRET") ?? "";
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

async function getToken(): Promise<string> {
  const res = await fetch(`${ID_BASE}/app/${CONTRACT}/token`, {
    method: "POST",
    headers: {
      Authorization: "Basic " + btoa(`${CID}:${SECRET}`),
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: "grant_type=client_credentials&scope=" + encodeURIComponent(SCOPES),
  });
  const j = await res.json();
  if (!res.ok || !j.access_token) throw new Error("スマレジ認証に失敗しました: " + JSON.stringify(j));
  return j.access_token;
}

// store_id=0 = 「総合給与」（全店舗合算）。店舗別の振り分けはsf_payroll_allocations（マスター手動入力）で行う
async function fetchMonthlyBudget(token: string, staffId: string, year: number, month: number) {
  const url = `${API_BASE}/${CONTRACT}/timecard/budgets/monthly/0/${staffId}?year=${year}&month=${String(month).padStart(2, "0")}`;
  const res = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
  if (res.status === 404) return null; // その月の給与明細が無い（未確定 or 対象外）
  if (!res.ok) {
    const t = await res.text();
    throw new Error(`給与明細API error (staff ${staffId} ${year}-${month}): ${res.status} ${t}`);
  }
  const bodyJson = await res.json();
  return {
    regularWage: Number(bodyJson?.allowanceWage?.regularWage ?? 0),
    workingDayCount: Number(bodyJson?.shiftTime?.workingDayCount ?? 0),
    totalWorkingTime: Number(bodyJson?.shiftTime?.totalWorkingTime ?? 0),
    // 2026-08-29追加: 課税対象額（切上げ）を人件費の主要な値として使う。通勤手当・固定残業代は参考値として別保存
    taxableAmount: Math.ceil(Number(bodyJson?.totalTaxable ?? 0)),
    fixedOvertimeWage: Number(bodyJson?.allowanceWage?.fixedOvertimeWage ?? 0),
    commuteAllowance: Number(bodyJson?.allowanceWage?.transportation ?? 0),
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

    const { data: profs } = await sb.from("employee_profiles")
      .select("user_id,smaregi_staff_id,users(name,is_active)")
      .not("smaregi_staff_id", "is", null);

    const token = await getToken();
    const synced: any[] = [];
    const skipped: any[] = [];
    const errors: string[] = [];

    for (const p of profs ?? []) {
      const staffId = p.smaregi_staff_id as string;
      const name = (p as any).users?.name ?? `smaregi_staff_id=${staffId}`;
      if (!(p as any).users?.is_active) { skipped.push({ name, reason: "非アクティブ" }); continue; }
      try {
        const budget = await fetchMonthlyBudget(token, staffId, year, month);
        if (!budget) { skipped.push({ name, reason: "その月の給与明細なし（404）" }); continue; }
        const { error } = await sb.from("sf_payroll_sync").upsert({
          user_id: p.user_id,
          year_month: yearMonth,
          regular_wage: budget.regularWage,
          working_day_count: budget.workingDayCount,
          total_working_minutes: budget.totalWorkingTime,
          taxable_amount: budget.taxableAmount,
          fixed_overtime_wage: budget.fixedOvertimeWage,
          commute_allowance: budget.commuteAllowance,
          raw: budget.raw,
          synced_at: new Date().toISOString(),
        }, { onConflict: "user_id,year_month" });
        if (error) { errors.push(`${name}: 保存エラー ${error.message}`); continue; }
        synced.push({ name, staffId, taxableAmount: budget.taxableAmount, regularWage: budget.regularWage, fixedOvertimeWage: budget.fixedOvertimeWage, commuteAllowance: budget.commuteAllowance, workingDayCount: budget.workingDayCount });
      } catch (e) {
        errors.push(`${name} (staff ${staffId}): ${String(e)}`);
      }
    }

    return json({ ok: true, year, month, syncedCount: synced.length, synced, skippedCount: skipped.length, skipped, errorCount: errors.length, errors });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
