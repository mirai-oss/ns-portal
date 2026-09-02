// D-2: 社員固定給の勤務日ベース按分・比較レポート Edge Function
// docs/実装指示書_担当D_勤怠給与監視_2026-08-24.md D-2
//
// 目的: 「社員人件費DB」由来の現行値（店舗×月の暦日割り。BigQuery fact_daily_storeに反映済み）と、
//   スマレジ勤怠実績（labor_cost_daily）ベースの「勤務日ベース按分」を店舗×日で比較し、
//   Postgres（labor_allocation_compare_report）へ保存する。切替は行わない（比較のみ）。
//
// 按分方式（2026-08-24ユーザー確認済み・詳細は同日付WORKLOG参照）:
//   「社員人件費DB」に従業員別の内訳が無い（店舗×月の合計額のみ）ため、店舗単位の再配分を行う。
//   店舗の月合計（現行値）を、その店舗のSHAIN/TENCHO（users.role）の日別労働時間の合計比率で
//   日別に再配分する。月合計は常に現行と一致し、日別の形だけが変わる。
//   その月にSHAIN/TENCHOの勤務実績が1件も無い店舗は暦日割りにフォールバック。
//
// 現行値の取得: tori-dashboardの既存GASアクション`bqDailyStore`（ログイン必須・変更なし。
//   dash-sync（ns-portal既存機能）が使っている`dash_id`/`dash_pw`（app_secrets）をそのまま流用）。
//   employee_salary_bonus/statutory_welfare/commute_allowanceの3列を含む唯一の既存読み取り経路。
//   GAS側のコードは一切変更しない（担当A専任のため）。
//
// 呼び出し方: { months?: number }  省略時は2（今月＋先月をカバーする範囲。実際に比較するのは
//   「完了済みの月」のみ＝当月は除外する。当月分は月半ばでも動くため比較対象にすると誤解を招くため）
//   認可: CEO/HQ/マスターのユーザーJWT、またはservice_role直呼び（他のD担当関数と同じ方針）
import { createClient } from "npm:@supabase/supabase-js@2";

const DASH_API_URL = "https://script.google.com/macros/s/AKfycbwW0qhyEr0-uQWTaLg7MkQhurHq6wMoaOKL7uCCnI_bgnAsGB5-auqG_dm_Q9uJc3Kc/exec";

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

async function dashCall(body: unknown) {
  const res = await fetch(DASH_API_URL, {
    method: "POST",
    headers: { "Content-Type": "text/plain;charset=utf-8" },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  try { return JSON.parse(text); }
  catch (_) { return { ok: false, error: "ダッシュボードの応答を読めませんでした: " + text.slice(0, 200) }; }
}

// 'YYYY/MM/DD' -> 'YYYY-MM-DD'
function toIsoDate(v: unknown): string | null {
  const m = String(v ?? "").trim().match(/(\d{4})[\/\-](\d{1,2})[\/\-](\d{1,2})/);
  if (!m) return null;
  return `${m[1]}-${m[2].padStart(2, "0")}-${m[3].padStart(2, "0")}`;
}
function ymOf(dateIso: string): string {
  return dateIso.slice(0, 7) + "-01";
}
function daysInMonth(ymIso: string): number {
  const [y, m] = ymIso.split("-").map(Number);
  return new Date(y, m, 0).getDate();
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

    // 対象月: 「完了済みの月」のみ（当月は除外）。months=2なら先月・先々月の2ヶ月分。
    const months = Math.max(1, Number(body.months) || 2);
    const nowJst = new Date(Date.now() + 9 * 3600 * 1000);
    const curYm = `${nowJst.getUTCFullYear()}-${String(nowJst.getUTCMonth() + 1).padStart(2, "0")}-01`;
    const targetYms = new Set<string>();
    for (let i = 1; i <= months; i++) {
      const d = new Date(nowJst.getUTCFullYear(), nowJst.getUTCMonth() - i, 1);
      targetYms.add(`${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-01`);
    }

    // --- ① ダッシュボードへログインし、現行値(BigQuery fact_daily_store)をbqDailyStore経由で取得 ---
    const { data: sec } = await sb.from("app_secrets").select("key,value").in("key", ["dash_id", "dash_pw"]);
    const secMap: Record<string, string> = {};
    (sec ?? []).forEach((r: any) => { secMap[r.key] = (r.value ?? "").trim(); });
    if (!secMap.dash_id || !secMap.dash_pw) {
      return json({ ok: false, error: "app_secretsにdash_id/dash_pwが未設定です" }, 500);
    }
    const login = await dashCall({ action: "login", id: secMap.dash_id, pw: secMap.dash_pw });
    if (!login.ok) return json({ ok: false, error: "ダッシュボードへのログインに失敗: " + (login.error ?? "") }, 500);

    const bqRes = await dashCall({ action: "bqDailyStore", token: login.token, months: months + 1 });
    if (!bqRes.ok) return json({ ok: false, error: "bqDailyStore取得に失敗: " + (bqRes.error ?? "") }, 500);
    const rows: any[] = (bqRes.sheets?.daily ?? []).slice(1); // ヘッダー行を除く
    // header: date, store_name, net_sales, guests_total, parttime_labor_cost, fulltime_labor_cost,
    //         labor_cost_total, cogs, cash, employee_salary_bonus, statutory_welfare, commute_allowance, parties_total

    type LegacyRow = { storeName: string; workDate: string; ym: string; salaryBonus: number; welfare: number; commute: number };
    const legacyRows: LegacyRow[] = [];
    for (const r of rows) {
      const workDate = toIsoDate(r[0]);
      const storeName = String(r[1] ?? "").trim();
      if (!workDate || !storeName) continue;
      const ym = ymOf(workDate);
      if (!targetYms.has(ym)) continue;
      legacyRows.push({
        storeName, workDate, ym,
        salaryBonus: Number(r[9] ?? 0),
        welfare: Number(r[10] ?? 0),
        commute: Number(r[11] ?? 0),
      });
    }
    if (!legacyRows.length) {
      return json({ ok: true, note: "対象月の現行データが無く比較できません（BQミラー未反映の可能性）", targetYms: [...targetYms] });
    }

    // --- ② 店舗名解決（dash-syncと同じ考え方: dash_store_name優先、無ければname） ---
    const { data: storeRows } = await sb.from("stores").select("id,name,dash_store_name");
    const nameMap = new Map<string, string>();
    (storeRows ?? []).forEach((s: any) => {
      if (s.dash_store_name) nameMap.set(String(s.dash_store_name).trim(), s.id);
      if (!nameMap.has(String(s.name).trim())) nameMap.set(String(s.name).trim(), s.id);
    });
    const unmatchedStores = new Set<string>();

    // --- ③ 重み（SHAIN/TENCHOの日別勤務分数）を取得 ---
    const minYm = [...targetYms].sort()[0];
    const { data: weightRows } = await sb
      .from("labor_salary_daily_weight")
      .select("store_id,store_name,work_date,ym,daily_minutes")
      .gte("ym", minYm);
    const weightByStoreYm = new Map<string, Map<string, number>>(); // key: `${storeId}__${ym}` -> Map<workDate, minutes>
    const monthTotalWeight = new Map<string, number>(); // key: `${storeId}__${ym}` -> total minutes
    for (const w of weightRows ?? []) {
      if (!targetYms.has(w.ym)) continue;
      const key = `${w.store_id}__${w.ym}`;
      if (!weightByStoreYm.has(key)) weightByStoreYm.set(key, new Map());
      weightByStoreYm.get(key)!.set(w.work_date, Number(w.daily_minutes));
      monthTotalWeight.set(key, (monthTotalWeight.get(key) ?? 0) + Number(w.daily_minutes));
    }

    // --- ④ 店舗×月の現行合計を集計（BQは既に暦日割り済みなので、月内の日別値を足し戻すだけで月合計が復元できる） ---
    type MonthKey = string; // `${storeName}__${ym}`
    const monthlyLegacyTotal = new Map<MonthKey, { salaryBonus: number; welfare: number; commute: number }>();
    for (const r of legacyRows) {
      const key = `${r.storeName}__${r.ym}`;
      const cur = monthlyLegacyTotal.get(key) ?? { salaryBonus: 0, welfare: 0, commute: 0 };
      cur.salaryBonus += r.salaryBonus; cur.welfare += r.welfare; cur.commute += r.commute;
      monthlyLegacyTotal.set(key, cur);
    }

    // --- ⑤ 新方式（勤務日ベース）を店舗×日で計算 ---
    const compareRows: any[] = [];
    const basisByMonthKey = new Map<MonthKey, "worked_minutes" | "calendar_fallback">();
    for (const r of legacyRows) {
      const storeId = nameMap.get(r.storeName);
      if (!storeId) unmatchedStores.add(r.storeName);
      const monthKey = `${r.storeName}__${r.ym}`;
      const total = monthlyLegacyTotal.get(monthKey)!;
      const wKey = storeId ? `${storeId}__${r.ym}` : "";
      const monthWeight = storeId ? (monthTotalWeight.get(wKey) ?? 0) : 0;
      const basis: "worked_minutes" | "calendar_fallback" = monthWeight > 0 ? "worked_minutes" : "calendar_fallback";
      basisByMonthKey.set(monthKey, basis);

      let ratio: number;
      if (basis === "worked_minutes") {
        const dayWeight = weightByStoreYm.get(wKey)?.get(r.workDate) ?? 0;
        ratio = dayWeight / monthWeight;
      } else {
        ratio = 1 / daysInMonth(r.ym);
      }

      compareRows.push({
        ym: r.ym,
        store_id: storeId ?? null,
        store_name: r.storeName,
        work_date: r.workDate,
        legacy_salary_bonus: r.salaryBonus,
        legacy_welfare: r.welfare,
        legacy_commute: r.commute,
        new_salary_bonus: Math.round(total.salaryBonus * ratio),
        new_welfare: Math.round(total.welfare * ratio),
        new_commute: Math.round(total.commute * ratio),
        weight_basis: basis,
        updated_at: new Date().toISOString(),
      });
    }

    // --- ⑥ 保存（onConflict: ym,store_name,work_date） ---
    for (let i = 0; i < compareRows.length; i += 500) {
      const { error } = await sb.from("labor_allocation_compare_report")
        .upsert(compareRows.slice(i, i + 500), { onConflict: "ym,store_name,work_date" });
      if (error) return json({ ok: false, error: "保存に失敗: " + error.message }, 500);
    }

    // --- ⑦ サマリー（月合計が一致すること＝按分ロジックの健全性チェック／日別の最大乖離） ---
    const summaryByMonth: any[] = [];
    for (const [monthKey, total] of monthlyLegacyTotal) {
      const [storeName, ym] = monthKey.split("__");
      const rowsInMonth = compareRows.filter((r) => r.store_name === storeName && r.ym === ym);
      const newTotal = rowsInMonth.reduce((s, r) => s + r.new_salary_bonus, 0);
      const maxDelta = rowsInMonth.reduce((mx, r) => Math.max(mx, Math.abs(r.new_salary_bonus - r.legacy_salary_bonus)), 0);
      summaryByMonth.push({
        storeName, ym,
        legacyTotal: Math.round(total.salaryBonus),
        newTotal,
        totalMatches: Math.abs(Math.round(total.salaryBonus) - newTotal) <= rowsInMonth.length, // 丸め誤差の範囲内か
        weightBasis: basisByMonthKey.get(monthKey),
        maxDailyDelta: maxDelta,
      });
    }

    return json({
      ok: true,
      targetYms: [...targetYms].sort(),
      rowsSaved: compareRows.length,
      unmatchedStores: [...unmatchedStores],
      summaryByMonth,
    });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
