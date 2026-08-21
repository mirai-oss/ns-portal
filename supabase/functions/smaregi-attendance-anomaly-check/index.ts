// 勤怠実績の異常値チェック Edge Function
// 2026-08-22 ユーザー要望により新規作成:
//   「1時間以内の勤務」「13時間超え」「24時間超え」は打刻ミスの可能性が高いため、
//   見つけたらLINEでアラートする。
//
// smaregi-attendance-sync（毎日の勤怠実績取込）が labor_cost_daily に書き込んだ直後の
// データを対象にチェックする想定（同じGitHub Actionsワークフローの後段ステップとして呼ぶ）。
// smaregi-attendance-syncの本体ロジックは一切変更していない（新規Edge Functionを追加しただけ）。
//
// 呼び出し方:
//   { date_from?: "YYYY-MM-DD", date_to?: "YYYY-MM-DD" } 省略時は「昨日」（日次バッチ想定）
//   認可: CEO/HQ/マスターのユーザーJWT、またはservice_role直呼び（他のsmaregi-*関数と同じ方針）
//
// しきい値（2026-08-22 ユーザー確認済み）:
//   ・60分以下（1時間以内） → 短すぎる勤務
//   ・780分超（13時間超え） → 長すぎる勤務
//   ・1440分超（24時間超え） → 明らかにおかしい勤務（要確認・上の780分超にも該当するため二重に出さない）
//   ※まだ退勤打刻（clock_out）が無い「勤務中」のレコードは対象外（誤検知防止）
import { createClient } from "npm:@supabase/supabase-js@2";

const SHORT_MINUTES = 60;
const LONG_MINUTES = 13 * 60; // 780
const EXTREME_MINUTES = 24 * 60; // 1440

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

function fmtHM(mins: number) {
  const h = Math.floor(mins / 60);
  const m = mins % 60;
  return `${h}時間${m}分`;
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

    // 対象期間: デフォルトは「昨日」（smaregi-attendance-syncと同じ日次バッチ想定）
    const today = new Date();
    const yesterday = new Date(today.getTime() - 86400000);
    const dateFrom = body.date_from || yesterday.toISOString().slice(0, 10);
    const dateTo = body.date_to || yesterday.toISOString().slice(0, 10);

    const { data: rows } = await sb.from("labor_cost_daily")
      .select("work_date,clock_in,clock_out,worked_minutes,users(name),stores(name)")
      .gte("work_date", dateFrom)
      .lte("work_date", dateTo)
      .not("clock_out", "is", null); // 退勤前(勤務中)のレコードは誤検知防止のため対象外

    const anomalies: any[] = [];
    for (const r of rows ?? []) {
      const mins = Number((r as any).worked_minutes ?? 0);
      const name = (r as any).users?.name ?? "(不明)";
      const store = (r as any).stores?.name ?? "(不明)";
      if (mins <= SHORT_MINUTES) {
        anomalies.push({ name, store, work_date: r.work_date, worked_minutes: mins, kind: "短すぎる勤務（1時間以内）" });
      } else if (mins > EXTREME_MINUTES) {
        anomalies.push({ name, store, work_date: r.work_date, worked_minutes: mins, kind: "24時間超え（要確認）" });
      } else if (mins > LONG_MINUTES) {
        anomalies.push({ name, store, work_date: r.work_date, worked_minutes: mins, kind: "長すぎる勤務（13時間超え）" });
      }
    }

    let notified = null;
    if (anomalies.length) {
      const lines = anomalies.map((a) =>
        `${a.work_date} ${a.name}（${a.store}）: ${a.kind} ${fmtHM(a.worked_minutes)}`
      );
      const text = `⚠️ 勤怠の異常値アラート（${dateFrom}〜${dateTo}）\n${anomalies.length}件見つかりました。打刻ミスの可能性があります。\n\n${lines.join("\n")}`;
      notified = await linePush(sb, text);
    }

    return json({
      ok: true,
      dateFrom, dateTo,
      checked: (rows ?? []).length,
      anomalyCount: anomalies.length,
      anomalies,
      notified,
    });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
