// スマレジ・タイムカード 勤怠実績の日次取込 Edge Function
// docs/実装指示書_データ基盤Day2_勤怠API取込.md タスクC
// 2026-08-21 新規作成。
//
// 目的: 「CSV手動ダウンロード→シート貼り付け」を止めずに（旧経路は並走）、
//   スマレジの打刻実績(division=result)をAPIで取得し、attendance_records・
//   labor_cost_daily へ保存する。
//
// 従業員の特定は employee_profiles.smaregi_staff_id をキーにする
//   （「スマレジが従業員情報の正本」という2026-08-21のユーザー方針決定に基づく。
//    public.users.smaregi_staff_id という同名の別列があるが未使用＝混同しないこと）。
//
// スマレジAPIの応答は shiftDaily が「日付 → 店舗ID → 連番」のネストしたオブジェクト
// （配列ではない）。2026-08-21に使い捨てEdge Functionで実データを確認して判明。
//
// 呼び出し方:
//   { action: "sync", date_from?: "YYYY-MM-DD", date_to?: "YYYY-MM-DD" }
//     省略時は「昨日1日分」を対象にする（日次バッチ想定）。
//   認可: CEO/HQ/マスターのユーザーJWT、または内部の合言葉(p_secret)。
//     現状はservice_role権限での呼び出し（launchd/cron等の内部呼び出し）を主眼に、
//     人が確認のため叩く場合は認証済みCEO/HQ/マスターのJWTを必須にする。
import { createClient } from "npm:@supabase/supabase-js@2";

const IS_PROD = Deno.env.get("SMAREGI_ENV") === "prod";
const ID_BASE = IS_PROD ? "https://id.smaregi.jp" : "https://id.smaregi.dev";
const API_BASE = IS_PROD ? "https://api.smaregi.jp" : "https://api.smaregi.dev";
const CONTRACT = Deno.env.get("SMAREGI_CONTRACT_ID") ?? "";
const CID = Deno.env.get("SMAREGI_CLIENT_ID") ?? "";
const SECRET = Deno.env.get("SMAREGI_CLIENT_SECRET") ?? "";
const SCOPES = "timecard.shifts:read timecard.shifts:write";

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

// {y}-{m} の月ごとにdaily(division=result)を取得。年月をまたぐ範囲指定はこの関数の外でループする
async function fetchMonthResults(token: string, staffId: string, year: number, month: number) {
  const url = `${API_BASE}/${CONTRACT}/timecard/shifts/staffs/${staffId}/daily?division=result&year=${year}&month=${String(month).padStart(2, "0")}`;
  const res = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
  if (!res.ok) {
    const t = await res.text();
    throw new Error(`smaregi API error (staff ${staffId} ${year}-${month}): ${res.status} ${t}`);
  }
  const body = await res.json();
  // shiftDaily: { "YYYY-MM-DD": { [storeId]: { "0": {...record}, personnelExpenses: "..." } } }
  const daily = body?.shiftDaily ?? {};
  const out: any[] = [];
  for (const [dateStr, byStore] of Object.entries<any>(daily)) {
    for (const [storeId, entry] of Object.entries<any>(byStore ?? {})) {
      const rec = entry?.["0"];
      if (!rec) continue;
      out.push({
        date: dateStr,
        storeIdSmaregi: storeId,
        shiftResultId: String(rec.shiftResultId ?? ""),
        attendance: rec.attendance || null,
        leaving: rec.leaving || null,
        tardy: rec.tardyFlag === "1",
        earlyLeaving: rec.earlyLeavingFlag === "1",
        dutyMinute: rec.dutyMinute ?? null,
        personnelExpenses: entry?.personnelExpenses ? Number(entry.personnelExpenses) : null,
      });
    }
  }
  return out;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const sb = svc();
    let body: any = {};
    try { body = await req.json(); } catch { /* GET等ボディなし */ }

    // 認可: CEO/HQ/マスターのJWT、またはservice_roleキー直呼び（内部バッチ用）を許可
    const authHeader = req.headers.get("Authorization") ?? "";
    const isServiceRole = authHeader.includes(Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? " ");
    if (!isServiceRole) {
      const uid = jwtUid(req);
      const { data: u } = await sb.from("users").select("role,is_master,is_active").eq("id", uid).maybeSingle();
      if (!u?.is_active || !(u.is_master || ["CEO", "HQ"].includes(u.role))) {
        return json({ ok: false, error: "権限がありません（CEO/HQ/マスターのみ）" }, 403);
      }
    }

    // 対象期間: デフォルトは「昨日」（日次バッチ想定）
    // 2026-08-24修正: 旧実装には2つのバグが複合していた（D-3実装中に8/22・8/23の欠落で発覚）。
    //   ①new Date()がUTC基準のため、08:00 JST（=前日23:00 UTC）に実行されるcronでは
    //     「JSTの本当の昨日」ではなく2日前を指してしまう
    //   ②日付文字列(body.date_from等)からはnew Date("YYYY-MM-DD")で常に0時0分になるのに対し、
    //     デフォルトの「昨日」はnew Date()由来で時刻成分が残ったままだったため、下のフィルタ
    //     `d < dateFrom`（dは0時0分）が単一日指定時に常にtrueとなり、実際にはinserted:0のまま
    //     何日も自動同期が空振りし続けていた（実行ログの"inserted":0の連続で確認）
    // 対策: JST基準で計算した「昨日」を一度'YYYY-MM-DD'文字列にしてから、body.date_from等と
    //   同じnew Date(文字列)経路に通す（＝常に0時0分になる・時刻成分を持ち込まない）。
    const nowJst = new Date(Date.now() + 9 * 3600 * 1000);
    const yesterdayStr = new Date(nowJst.getTime() - 86400000).toISOString().slice(0, 10);
    const dateFrom = new Date(body.date_from || yesterdayStr);
    const dateTo = new Date(body.date_to || yesterdayStr);

    const { data: profs } = await sb.from("employee_profiles").select("user_id,smaregi_staff_id").not("smaregi_staff_id", "is", null);
    const { data: stores } = await sb.from("stores").select("id,smaregi_store_id").not("smaregi_store_id", "is", null);
    const storeMap: Record<string, string> = {};
    (stores ?? []).forEach((s: any) => { storeMap[s.smaregi_store_id] = s.id; });

    const token = await getToken();
    const monthsSeen = new Set<string>();
    let cur = new Date(dateFrom);
    const months: Array<{ y: number; m: number }> = [];
    while (cur <= dateTo) {
      const key = `${cur.getFullYear()}-${cur.getMonth() + 1}`;
      if (!monthsSeen.has(key)) { monthsSeen.add(key); months.push({ y: cur.getFullYear(), m: cur.getMonth() + 1 }); }
      cur = new Date(cur.getFullYear(), cur.getMonth() + 1, 1);
    }

    let inserted = 0, skipped = 0;
    const errors: string[] = [];

    for (const p of profs ?? []) {
      for (const { y, m } of months) {
        try {
          const recs = await fetchMonthResults(token, p.smaregi_staff_id, y, m);
          for (const r of recs) {
            const d = new Date(r.date);
            if (d < dateFrom || d > dateTo) continue; // 月単位取得なので範囲外は捨てる
            const storeId = storeMap[r.storeIdSmaregi];
            if (!storeId) { errors.push(`store未対応: smaregi_store_id=${r.storeIdSmaregi}`); continue; }
            if (!r.shiftResultId) { skipped++; continue; }

            // attendance_records（生ログ）。source列は既存のcheck制約で'api'/'csv'のみ許可
            // （2026-08-21に判明。'smaregi'は通らないため'api'を使う＝API経由取込という制約の意図と合致）
            const { error: arErr } = await sb.from("attendance_records").upsert({
              user_id: p.user_id,
              store_id: storeId,
              work_date: r.date,
              clock_in: r.attendance,
              clock_out: r.leaving,
              source: "api",
              smaregi_shift_result_id: r.shiftResultId,
            }, { onConflict: "smaregi_shift_result_id" });
            if (arErr) { errors.push(`attendance_records upsert失敗 (${r.shiftResultId}): ${arErr.message}`); }

            // labor_cost_daily（集計・見積もり。computed_costの自前計算は次フェーズ）
            const { error: lcErr } = await sb.from("labor_cost_daily").upsert({
              user_id: p.user_id,
              store_id: storeId,
              work_date: r.date,
              clock_in: r.attendance,
              clock_out: r.leaving,
              worked_minutes: r.dutyMinute,
              tardy: r.tardy,
              early_leaving: r.earlyLeaving,
              smaregi_estimate_cost: r.personnelExpenses,
              smaregi_shift_result_id: r.shiftResultId,
              smaregi_staff_id: p.smaregi_staff_id,
              source: "smaregi",
              updated_at: new Date().toISOString(),
            }, { onConflict: "smaregi_shift_result_id" });
            if (lcErr) { errors.push(`labor_cost_daily upsert失敗 (${r.shiftResultId}): ${lcErr.message}`); continue; }

            inserted++;
          }
        } catch (e) {
          errors.push(`staff ${p.smaregi_staff_id} ${y}-${m}: ${String(e)}`);
        }
      }
    }

    return json({
      ok: true,
      dateFrom: dateFrom.toISOString().slice(0, 10),
      dateTo: dateTo.toISOString().slice(0, 10),
      staffCount: (profs ?? []).length,
      inserted,
      skipped,
      errorCount: errors.length,
      errors: errors.slice(0, 20),
    });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
