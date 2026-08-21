// スマレジ給与明細API(budgets/monthly)による月次自動突合 Edge Function
// docs/引継ぎ書_2026-08-22_データ基盤Day3続き.md §3-2 に基づき新規作成（2026-08-22）
//
// 目的: labor_cost_daily の smaregi_estimate_cost（勤怠実績APIのオマケ見積もり値）の
//   月次合計を、給与明細API（timecard.salaries:read、確定済みの本物の給与額）と突合する。
//   2026-08-22の検証で「月単位では両者は基本一致する」ことを確認済みだが、
//   今後ズレが出た場合に気づけるよう、閾値以上の差額があればLINEでアラートする。
//
// 既存のsmaregi-sync・smaregi-shift-sync・smaregi-attendance-syncは一切変更しない（新規追加のみ）。
//
// 呼び出し方:
//   { year?: number, month?: number }  省略時は「先月」（毎月5日朝の自動実行を想定。
//     前月分の勤務実績が変更される余地を見込んで5日まで待つ運用にしている）
//   認可: CEO/HQ/マスターのユーザーJWT、またはservice_role直呼び（smaregi-attendance-syncと同じ方針）
//
// 除外1: smaregi_staff_id=347（中山＝CEO本人）は本部打刻の対象外につき突合しない
//   （2026-08-22 ユーザー確認済み。普段打刻しないため、スマレジ側も事業所未割当でエラーになる）
// 除外2: 打刻（worked_minutes）はあるのに見積もり(smaregi_estimate_cost)が常に0円の人は、
//   月給制（固定残業等が別についていて単純な金額一致確認になじまない）と推定し、突合対象から自動除外する
//   （2026-08-22 青山純さんのケースでユーザー確認済み。給与明細APIの呼び出し自体を省略できる副次効果もある）
//
// LINE通知: 既存のline-webhookは呼ばずに、app_secrets（line_channel_token）を直接読んで
//   LINE Push APIを叩く（line-webhookのpush_userはアプリの利用者JWTを前提にした権限チェックのため、
//   バッチ処理からの呼び出しには向かない。テーブルは共有するが関数としては独立させる）。
//   宛先は users.role が CEO/HQ かつ line_user_id 連携済みの人全員（2026-08-22時点はCEO本人のみ想定）。
import { createClient } from "npm:@supabase/supabase-js@2";

const IS_PROD = Deno.env.get("SMAREGI_ENV") === "prod";
const ID_BASE = IS_PROD ? "https://id.smaregi.jp" : "https://id.smaregi.dev";
const API_BASE = IS_PROD ? "https://api.smaregi.jp" : "https://api.smaregi.dev";
const CONTRACT = Deno.env.get("SMAREGI_CONTRACT_ID") ?? "";
const CID = Deno.env.get("SMAREGI_CLIENT_ID") ?? "";
const SECRET = Deno.env.get("SMAREGI_CLIENT_SECRET") ?? "";
const SCOPES = "timecard.salaries:read";

const ALERT_THRESHOLD_YEN = 1000; // 2026-08-22 ユーザー確認済み（これ未満のブレは実務上許容）
const EXCLUDE_STAFF_IDS = new Set(["347"]); // 中山（CEO本人）。本部打刻の取込対象外（2026-08-22確認済み）

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

// store_id=0 を指定すると「総合給与」（全店舗合算）が取れる（2026-08-22 使い捨てEdge Functionで確認済み）
async function fetchMonthlyBudget(token: string, staffId: string, year: number, month: number) {
  const url = `${API_BASE}/${CONTRACT}/timecard/budgets/monthly/0/${staffId}?year=${year}&month=${String(month).padStart(2, "0")}`;
  const res = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
  if (!res.ok) {
    const t = await res.text();
    throw new Error(`給与明細API error (staff ${staffId} ${year}-${month}): ${res.status} ${t}`);
  }
  const body = await res.json();
  return {
    regularWage: Number(body?.allowanceWage?.regularWage ?? 0),
    workingDayCount: Number(body?.shiftTime?.workingDayCount ?? 0),
    totalWorkingTime: Number(body?.shiftTime?.totalWorkingTime ?? 0),
  };
}

async function linePush(sb: ReturnType<typeof createClient>, text: string) {
  const { data: sec } = await sb.from("app_secrets").select("key,value").eq("key", "line_channel_token").maybeSingle();
  const token = (sec?.value ?? "").trim();
  if (!token) return { ok: false, reason: "line_channel_token未設定" };

  const { data: recipients } = await sb.from("users")
    .select("id,name,line_user_id,role")
    .in("role", ["CEO", "HQ"])
    .eq("is_active", true)
    .not("line_user_id", "is", null);

  if (!recipients?.length) return { ok: false, reason: "LINE連携済みのCEO/HQがいません" };

  const results = [];
  for (const r of recipients) {
    const res = await fetch("https://api.line.me/v2/bot/message/push", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
      body: JSON.stringify({ to: r.line_user_id, messages: [{ type: "text", text: text.slice(0, 4900) }] }),
    });
    const bodyText = res.ok ? "" : (await res.text()).slice(0, 300);
    results.push({ name: r.name, ok: res.ok, status: res.status, body: bodyText });
  }
  return { ok: results.some((r) => r.ok), results };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const sb = svc();
    let body: any = {};
    try { body = await req.json(); } catch { /* GET等ボディなし */ }

    // 認可: smaregi-attendance-syncと同じ方針（CEO/HQ/マスターのJWT、またはservice_role直呼び）
    const authHeader = req.headers.get("Authorization") ?? "";
    const isServiceRole = authHeader.includes(Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? " ");
    if (!isServiceRole) {
      const uid = jwtUid(req);
      const { data: u } = await sb.from("users").select("role,is_master,is_active").eq("id", uid).maybeSingle();
      if (!u?.is_active || !(u.is_master || ["CEO", "HQ"].includes(u.role))) {
        return json({ ok: false, error: "権限がありません（CEO/HQ/マスターのみ）" }, 403);
      }
    }

    // 対象月: デフォルトは「先月」（毎月5日朝の自動実行を想定。当月分は締め前のため対象にしない）
    const nowJst = new Date(Date.now() + 9 * 3600 * 1000);
    let year = Number(body.year) || nowJst.getUTCFullYear();
    let month = Number(body.month) || nowJst.getUTCMonth() + 1;
    if (!body.year && !body.month) {
      month -= 1;
      if (month < 1) { month = 12; year -= 1; }
    }
    const monthStart = `${year}-${String(month).padStart(2, "0")}-01`;
    const nextMonth = month === 12 ? { y: year + 1, m: 1 } : { y: year, m: month + 1 };
    const monthEnd = `${nextMonth.y}-${String(nextMonth.m).padStart(2, "0")}-01`;

    const { data: profs } = await sb.from("employee_profiles")
      .select("user_id,smaregi_staff_id,users(name)")
      .not("smaregi_staff_id", "is", null);

    const token = await getToken();
    const mismatches: any[] = [];
    const checked: any[] = [];
    const excluded: any[] = [];
    const errors: string[] = [];

    for (const p of profs ?? []) {
      const staffId = p.smaregi_staff_id as string;
      const name = (p as any).users?.name ?? `smaregi_staff_id=${staffId}`;
      if (EXCLUDE_STAFF_IDS.has(staffId)) continue;
      try {
        const { data: rows } = await sb.from("labor_cost_daily")
          .select("smaregi_estimate_cost,worked_minutes")
          .eq("user_id", p.user_id)
          .gte("work_date", monthStart)
          .lt("work_date", monthEnd);
        if (!rows?.length) { continue; } // その月に勤務実績が無い人は突合対象外

        const estimateSum = rows.reduce((s, r: any) => s + Number(r.smaregi_estimate_cost ?? 0), 0);
        const workedMinutes = rows.reduce((s, r: any) => s + Number(r.worked_minutes ?? 0), 0);

        // 2026-08-22 ユーザー確認: 打刻はあるが見積もり(smaregi_estimate_cost)が常に0円の人は
        // 月給制（固定残業等が別付きで、単純な金額一致確認になじまない）と推定し、突合対象から除外する。
        // 給与明細API呼び出し自体を省略できるので、判定はlabor_cost_dailyの情報だけで完結させている。
        if (workedMinutes > 0 && estimateSum === 0) {
          excluded.push({ name, staffId, reason: "打刻はあるが見積もりが常に0円（月給制と推定）" });
          continue;
        }

        const budget = await fetchMonthlyBudget(token, staffId, year, month);
        const diff = Math.round(estimateSum) - Math.round(budget.regularWage);
        checked.push({ name, staffId, estimateSum, regularWage: budget.regularWage, diff });
        if (Math.abs(diff) >= ALERT_THRESHOLD_YEN) {
          mismatches.push({ name, staffId, estimateSum, regularWage: budget.regularWage, diff });
        }
      } catch (e) {
        errors.push(`staff ${staffId}: ${String(e)}`);
      }
    }

    let notified = null;
    if (mismatches.length) {
      const lines = mismatches.map((m) =>
        `${m.name}: 実績合計${m.estimateSum}円 / 給与明細${m.regularWage}円（差額${m.diff > 0 ? "+" : ""}${m.diff}円）`
      );
      const text = `⚠️ 給与突合アラート（${year}年${month}月分）\n1,000円以上の差額が${mismatches.length}件見つかりました。\n\n${lines.join("\n")}\n\n※スマレジ勤怠実績の見積もりと給与明細API(確定値)の比較です。実際の支給額は給与明細APIの値をご確認ください。`;
      notified = await linePush(sb, text);
    }

    return json({
      ok: true,
      year, month,
      staffChecked: checked.length,
      checked,
      excludedCount: excluded.length,
      excluded,
      mismatchCount: mismatches.length,
      mismatches,
      errorCount: errors.length,
      errors: errors.slice(0, 20),
      notified,
    });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
