// P-0c: 経営ダッシュボードのホーム初期表示用・軽量API（2026-09-05新設）
//
// 目的: 初期表示でGASの action:data / bqDailyStore を待たずに、最初の1画面に必要な
// 売上・目標・前年差分だけをSupabaseの集計済みテーブルから返す。
// 読み取り元は既存の kd_home_kpi_snapshot / kd_dashboard_daily_summary を優先し、
// スナップショット未作成日のみ dash_sales_daily / dash_sales_target_daily へフォールバックする。
// Google Sheets / GAS / BigQuery は画面表示時に一切呼ばない。
//
// 呼び出し: POST { as_of?: 'YYYY-MM-DD' }
// 返り値: { ok:true, asOf, monthStart, latestBizDate, totals, stores, scope, source }
import { createClient } from "npm:@supabase/supabase-js@2";

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

function jstToday(): string {
  return new Date(Date.now() + 9 * 3600 * 1000).toISOString().slice(0, 10);
}
function isDateStr(s: unknown): s is string {
  return typeof s === "string" && /^\d{4}-\d{2}-\d{2}$/.test(s);
}
function addYears(dateStr: string, years: number): string {
  const d = new Date(`${dateStr}T00:00:00Z`);
  d.setUTCFullYear(d.getUTCFullYear() + years);
  return d.toISOString().slice(0, 10);
}
function monthStart(dateStr: string): string {
  return `${dateStr.slice(0, 7)}-01`;
}
function monthKey(dateStr: string): string {
  return `${dateStr.slice(0, 7)}-01`;
}
function n(v: unknown): number {
  const x = Number(v ?? 0);
  return Number.isFinite(x) ? x : 0;
}
function div(num: number, den: number): number | null {
  return den ? num / den : null;
}

async function resolveScope(sb: ReturnType<typeof createClient>, uid: string) {
  const { data: u } = await sb.from("users").select("id,role,is_master,is_active").eq("id", uid).maybeSingle();
  if (!u || !u.is_active) return { allowed: false as const, error: "ログインが必要です（アカウントが無効です）" };
  if (u.is_master || ["CEO", "HQ", "TEAM"].includes(u.role)) {
    return { allowed: true as const, role: u.role, restrictedStoreIds: null as string[] | null };
  }
  if (u.role === "TENCHO") {
    const { data: us } = await sb.from("user_stores").select("store_id").eq("user_id", uid);
    const ids = (us ?? []).map((r: any) => r.store_id);
    return { allowed: true as const, role: u.role, restrictedStoreIds: ids };
  }
  return { allowed: false as const, error: "権限がありません（社長・本部・チーム長・店長のみ。経営Dと同じ判定）" };
}

type StoreRow = { id: string; name: string; dash_store_name?: string | null; sort_order?: number | null; is_active: boolean };
type DailyRow = { store_id: string; biz_date: string; sales: number; cost: number; labor: number };
type TargetRow = { store_id: string; biz_date: string; sales_target: number };
type HomeRow = {
  store_id: string; period_date: string; today_sales: number | null; today_guests: number | null; today_parties: number | null;
  mtd_sales: number | null; budget_achievement_rate: number | null; daily_report_submission_rate: number | null;
  checklist_completion_rate: number | null; hq_task_overdue_count: number | null; source_updated_at: string | null; computed_at: string;
};
type DashRow = {
  store_id: string; period_date: string; net_sales: number | null; guests: number | null; parties: number | null;
  avg_check: number | null; prior_year_same_weekday_sales: number | null; prior_year_same_weekday_ratio: number | null;
};
type RsvRow = { store_id: string; reservation_count: number; party_size_sum: number; expected_sales: number | null };

function sumDaily(rows: DailyRow[]) {
  return rows.reduce((a, r) => {
    a.sales += n(r.sales);
    a.cost += n(r.cost);
    a.labor += n(r.labor);
    if (!a.latest || r.biz_date > a.latest) a.latest = r.biz_date;
    return a;
  }, { sales: 0, cost: 0, labor: 0, latest: "" });
}
function sumTargets(rows: TargetRow[]) {
  return rows.reduce((a, r) => a + n(r.sales_target), 0);
}
function makeKpis(cur: ReturnType<typeof sumDaily>, target: number, lySales: number) {
  const gross = cur.sales - cur.cost;
  const fl = cur.cost + cur.labor;
  return {
    sales: cur.sales,
    target,
    targetDiff: cur.sales - target,
    targetRate: div(cur.sales, target),
    lastYearSales: lySales,
    yoyRate: div(cur.sales, lySales),
    cost: cur.cost,
    labor: cur.labor,
    gross,
    grossRate: div(gross, cur.sales),
    fl,
    flRate: div(fl, cur.sales),
  };
}
function avgPresent(rows: Array<number | null | undefined>): number | null {
  const xs = rows.map((v) => v == null ? null : Number(v)).filter((v): v is number => v != null && Number.isFinite(v));
  return xs.length ? xs.reduce((a, v) => a + v, 0) / xs.length : null;
}
function budgetTargetFrom(rows: HomeRow[]): number {
  return rows.reduce((a, r) => {
    const sales = n(r.mtd_sales);
    const rate = Number(r.budget_achievement_rate ?? 0);
    return a + (rate > 0 ? sales / rate : 0);
  }, 0);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const sb = svc();
    let body: any = {};
    try { body = await req.json(); } catch (_) { /* bodyなしは既定値で動かす */ }

    const authHeader = req.headers.get("Authorization") ?? "";
    const isServiceRole = authHeader.includes(Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? " ");
    let restrictedStoreIds: string[] | null = null;
    let role = "service_role";
    if (!isServiceRole) {
      const uid = jwtUid(req);
      if (!uid) return json({ ok: false, error: "ログインが必要です" }, 401);
      const scope = await resolveScope(sb, uid);
      if (!scope.allowed) return json({ ok: false, error: scope.error }, 403);
      role = scope.role;
      restrictedStoreIds = scope.restrictedStoreIds;
      if (restrictedStoreIds && restrictedStoreIds.length === 0) {
        return json({ ok: true, asOf: body.as_of ?? jstToday(), stores: [], totals: makeKpis(sumDaily([]), 0, 0), scope: { role, restrictedStoreIds } });
      }
    }

    const asOf = isDateStr(body.as_of) ? body.as_of : jstToday();
    const start = monthStart(asOf);
    const lyStart = addYears(start, -1);
    const lyAsOf = addYears(asOf, -1);

    let storesQ = sb.from("stores").select("id,name,dash_store_name,sort_order,is_active").eq("is_active", true).order("sort_order");
    if (restrictedStoreIds) storesQ = storesQ.in("id", restrictedStoreIds);
    const { data: storesData, error: storesError } = await storesQ;
    if (storesError) return json({ ok: false, error: "店舗一覧の取得に失敗しました: " + storesError.message }, 500);
    const stores = (storesData ?? []) as StoreRow[];
    const storeIds = stores.map((s) => s.id);
    if (!storeIds.length) {
      return json({ ok: true, asOf, monthStart: start, latestBizDate: null, stores: [], totals: makeKpis(sumDaily([]), 0, 0), scope: { role, restrictedStoreIds } });
    }

    const [homeRes, dashRes, rsvRes] = await Promise.all([
      sb.from("kd_home_kpi_snapshot").select(
        "store_id,period_date,today_sales,today_guests,today_parties,mtd_sales,budget_achievement_rate,daily_report_submission_rate,checklist_completion_rate,hq_task_overdue_count,source_updated_at,computed_at",
      ).in("store_id", storeIds).eq("period_date", asOf),
      sb.from("kd_dashboard_daily_summary").select(
        "store_id,period_date,net_sales,guests,parties,avg_check,prior_year_same_weekday_sales,prior_year_same_weekday_ratio",
      ).in("store_id", storeIds).eq("period_date", asOf),
      sb.from("kd_reservation_daily_summary").select("store_id,reservation_count,party_size_sum,expected_sales")
        .in("store_id", storeIds).eq("period_date", asOf),
    ]);
    for (const r of [homeRes, dashRes, rsvRes]) {
      if (r.error) return json({ ok: false, error: "ホームスナップショットの取得に失敗しました: " + r.error.message }, 500);
    }

    const homeRows = (homeRes.data ?? []) as HomeRow[];
    if (homeRows.length) {
      const homeByStore = new Map(homeRows.map((r) => [r.store_id, r]));
      const dashByStore = new Map(((dashRes.data ?? []) as DashRow[]).map((r) => [r.store_id, r]));
      const rsvByStore = new Map(((rsvRes.data ?? []) as RsvRow[]).map((r) => [r.store_id, r]));
      const targetTotal = budgetTargetFrom(homeRows);
      const salesTotal = homeRows.reduce((a, r) => a + n(r.mtd_sales), 0);
      const todaySalesTotal = homeRows.reduce((a, r) => a + n(r.today_sales), 0);
      const todayGuestsTotal = homeRows.reduce((a, r) => a + n(r.today_guests), 0);
      const todayPartiesTotal = homeRows.reduce((a, r) => a + n(r.today_parties), 0);
      const lastYearTodaySales = [...dashByStore.values()].reduce((a, r) => a + n(r.prior_year_same_weekday_sales), 0);
      const sourceComputedAt = homeRows.reduce((m, r) => !m || r.computed_at > m ? r.computed_at : m, "");
      const sourceUpdatedAt = homeRows.reduce((m, r) => r.source_updated_at && (!m || r.source_updated_at > m) ? r.source_updated_at : m, "");
      const storeSummaries = stores.map((s) => {
        const h = homeByStore.get(s.id);
        const d = dashByStore.get(s.id);
        const rv = rsvByStore.get(s.id);
        const mtdSales = n(h?.mtd_sales);
        const budgetRate = h?.budget_achievement_rate ?? null;
        const target = budgetRate && budgetRate > 0 ? mtdSales / budgetRate : 0;
        return {
          storeId: s.id,
          storeName: s.dash_store_name || s.name,
          periodDate: asOf,
          todaySales: n(h?.today_sales),
          todayGuests: n(h?.today_guests),
          todayParties: n(h?.today_parties),
          todayAvgCheck: div(n(h?.today_sales), n(h?.today_guests)),
          mtdSales,
          target,
          targetRate: budgetRate,
          targetDiff: target ? mtdSales - target : null,
          priorYearSameWeekdaySales: d?.prior_year_same_weekday_sales ?? null,
          priorYearSameWeekdayRatio: d?.prior_year_same_weekday_ratio ?? null,
          dailyReportSubmissionRate: h?.daily_report_submission_rate ?? null,
          checklistCompletionRate: h?.checklist_completion_rate ?? null,
          hqTaskOverdueCount: h?.hq_task_overdue_count ?? null,
          reservationCount: rv?.reservation_count ?? 0,
          reservationPartySize: rv?.party_size_sum ?? 0,
          reservationExpectedSales: rv?.expected_sales ?? null,
        };
      });
      return json({
        ok: true,
        asOf,
        monthStart: start,
        latestBizDate: asOf,
        source: "kd_home_kpi_snapshot + kd_dashboard_daily_summary + kd_reservation_daily_summary（Supabase集計済みテーブル。GAS/Sheets非経由）",
        sourceComputedAt: sourceComputedAt || null,
        sourceUpdatedAt: sourceUpdatedAt || null,
        totals: {
          todaySales: todaySalesTotal,
          todayGuests: todayGuestsTotal,
          todayParties: todayPartiesTotal,
          todayAvgCheck: div(todaySalesTotal, todayGuestsTotal),
          mtdSales: salesTotal,
          target: targetTotal,
          targetDiff: targetTotal ? salesTotal - targetTotal : null,
          targetRate: div(salesTotal, targetTotal),
          priorYearSameWeekdaySales: lastYearTodaySales,
          priorYearSameWeekdayRatio: div(todaySalesTotal, lastYearTodaySales),
          dailyReportSubmissionRate: avgPresent(homeRows.map((r) => r.daily_report_submission_rate)),
          checklistCompletionRate: avgPresent(homeRows.map((r) => r.checklist_completion_rate)),
          hqTaskOverdueCount: homeRows.reduce((a, r) => a + n(r.hq_task_overdue_count), 0),
          reservationCount: [...rsvByStore.values()].reduce((a, r) => a + n(r.reservation_count), 0),
          reservationPartySize: [...rsvByStore.values()].reduce((a, r) => a + n(r.party_size_sum), 0),
          reservationExpectedSales: [...rsvByStore.values()].reduce((a, r) => a + n(r.expected_sales), 0),
        },
        stores: storeSummaries,
        scope: { role, restrictedStoreIds },
      });
    }

    const [curRes, lyRes, targetRes, monthlyTargetRes] = await Promise.all([
      sb.from("dash_sales_daily").select("store_id,biz_date,sales,cost,labor")
        .in("store_id", storeIds).gte("biz_date", start).lte("biz_date", asOf),
      sb.from("dash_sales_daily").select("store_id,biz_date,sales,cost,labor")
        .in("store_id", storeIds).gte("biz_date", lyStart).lte("biz_date", lyAsOf),
      sb.from("dash_sales_target_daily").select("store_id,biz_date,sales_target")
        .in("store_id", storeIds).gte("biz_date", start).lte("biz_date", asOf),
      sb.from("dash_target_monthly").select("store_id,ym,pa_rate,emp_rate,cost_rate,dinii_target,review_target")
        .in("store_id", storeIds).eq("ym", monthKey(asOf)),
    ]);
    for (const r of [curRes, lyRes, targetRes, monthlyTargetRes]) {
      if (r.error) return json({ ok: false, error: "ホーム集計の取得に失敗しました: " + r.error.message }, 500);
    }

    const curRows = (curRes.data ?? []) as DailyRow[];
    const lyRows = (lyRes.data ?? []) as DailyRow[];
    const targetRows = (targetRes.data ?? []) as TargetRow[];
    const monthlyTargets = new Map((monthlyTargetRes.data ?? []).map((r: any) => [r.store_id, {
      paRateTarget: r.pa_rate, empRateTarget: r.emp_rate, costRateTarget: r.cost_rate,
      diniiTarget: r.dinii_target, reviewTarget: r.review_target,
    }]));

    const curByStore = new Map<string, DailyRow[]>();
    const lyByStore = new Map<string, DailyRow[]>();
    const targetByStore = new Map<string, TargetRow[]>();
    for (const r of curRows) (curByStore.get(r.store_id) ?? curByStore.set(r.store_id, []).get(r.store_id)!).push(r);
    for (const r of lyRows) (lyByStore.get(r.store_id) ?? lyByStore.set(r.store_id, []).get(r.store_id)!).push(r);
    for (const r of targetRows) (targetByStore.get(r.store_id) ?? targetByStore.set(r.store_id, []).get(r.store_id)!).push(r);

    const storeSummaries = stores.map((s) => {
      const cur = sumDaily(curByStore.get(s.id) ?? []);
      const ly = sumDaily(lyByStore.get(s.id) ?? []);
      const target = sumTargets(targetByStore.get(s.id) ?? []);
      return {
        storeId: s.id,
        storeName: s.dash_store_name || s.name,
        latestBizDate: cur.latest || null,
        ...makeKpis(cur, target, ly.sales),
        monthlyTargets: monthlyTargets.get(s.id) ?? null,
      };
    });

    const curTotal = sumDaily(curRows);
    const lyTotal = sumDaily(lyRows);
    const targetTotal = sumTargets(targetRows);
    return json({
      ok: true,
      asOf,
      monthStart: start,
      lastYearFrom: lyStart,
      lastYearTo: lyAsOf,
      latestBizDate: curTotal.latest || null,
      source: "dash_sales_daily + dash_sales_target_daily + dash_target_monthly（Supabase集計済みテーブル。GAS/Sheets非経由）",
      totals: makeKpis(curTotal, targetTotal, lyTotal.sales),
      stores: storeSummaries,
      scope: { role, restrictedStoreIds },
    });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
