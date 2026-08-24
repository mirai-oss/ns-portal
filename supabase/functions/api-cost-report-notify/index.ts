// D-4: Anthropic API費用の自動レポート（Lark配信）Edge Function
// docs/実装指示書_担当D_勤怠給与監視_2026-08-24.md D-4
//
// api_cost_dailyを読んで、JST基準の「今日」に応じて以下を判定・送信する（該当しない日は無送信）:
//   ①毎月1日: 先月のAI利用料合計（円主・ドル併記・平均レート）
//   ②毎週月曜: 今月の累計
//   ③しきい値超過: 今月の累計が閾値を「今日はじめて」超えた時だけ（前日までの累計と比較して判定。
//     毎日同じ閾値超過を繰り返し通知しない）。閾値はbody.thresholdUsdで都度指定（未指定ならスキップ。
//     金額はユーザー確認が必要な設定値のため、コード側にデフォルト値は持たせない）
// Lark送信先: app_secrets.lark_webhook_url（D-3見張り番と同じ想定のWebhook。ユーザーがLarkの
//   ボット管理画面から確認して登録したもの）
// 呼び出し方: { thresholdUsd?: number, force?: ('monthly'|'weekly'|'threshold')[] }
//   forceは動作確認用（本来の曜日/日付条件を無視して強制送信させる）
//   認可: CEO/HQ/マスターのユーザーJWT、またはservice_role直呼び（他のD担当関数と同じ方針）
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

function yen(n: number): string {
  return "¥" + Math.round(n).toLocaleString("ja-JP");
}
function usd(n: number): string {
  return "$" + n.toFixed(2);
}

async function sendLark(sb: ReturnType<typeof createClient>, text: string) {
  const { data: sec } = await sb.from("app_secrets").select("value").eq("key", "lark_webhook_url").maybeSingle();
  const url = (sec?.value ?? "").trim();
  if (!url) return { ok: false, reason: "app_secretsにlark_webhook_url未設定" };
  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ msg_type: "text", content: { text } }),
  });
  const body = await res.json().catch(() => ({}));
  return { ok: res.ok, status: res.status, body };
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

    const force: string[] = Array.isArray(body.force) ? body.force : [];
    const nowJst = new Date(Date.now() + 9 * 3600 * 1000);
    const jstDay = nowJst.getUTCDate();
    const jstWeekday = nowJst.getUTCDay(); // 0=日,1=月,...
    const jstYear = nowJst.getUTCFullYear();
    const jstMonth = nowJst.getUTCMonth(); // 0-indexed

    const sent: Record<string, any> = {};

    // ① 毎月1日: 先月合計
    if (jstDay === 1 || force.includes("monthly")) {
      const prevMonthDate = new Date(Date.UTC(jstYear, jstMonth - 1, 1));
      const prevYm = `${prevMonthDate.getUTCFullYear()}-${String(prevMonthDate.getUTCMonth() + 1).padStart(2, "0")}`;
      const monthStart = `${prevYm}-01`;
      const nextMonthDate = new Date(Date.UTC(prevMonthDate.getUTCFullYear(), prevMonthDate.getUTCMonth() + 1, 1));
      const monthEnd = nextMonthDate.toISOString().slice(0, 10);
      const { data: rows } = await sb.from("api_cost_daily").select("amount_cents,amount_jpy,jpy_rate")
        .gte("date", monthStart).lt("date", monthEnd);
      const totalCents = (rows ?? []).reduce((s, r: any) => s + Number(r.amount_cents ?? 0), 0);
      const totalJpy = (rows ?? []).reduce((s, r: any) => s + Number(r.amount_jpy ?? 0), 0);
      const rates = (rows ?? []).map((r: any) => Number(r.jpy_rate)).filter((n: number) => !isNaN(n) && n > 0);
      const avgRate = rates.length ? rates.reduce((s, n) => s + n, 0) / rates.length : null;
      const totalUsd = totalCents / 100;
      const text = `📊 ${prevYm}のAI利用料: ${yen(totalJpy)}（${usd(totalUsd)}${avgRate ? `・平均レート${avgRate.toFixed(1)}` : ""}）`;
      sent.monthly = { text, result: await sendLark(sb, text) };
    }

    // ② 毎週月曜: 今月の累計
    if (jstWeekday === 1 || force.includes("weekly")) {
      const ym = `${jstYear}-${String(jstMonth + 1).padStart(2, "0")}`;
      const monthStart = `${ym}-01`;
      const { data: rows } = await sb.from("api_cost_daily").select("amount_cents,amount_jpy")
        .gte("date", monthStart);
      const totalCents = (rows ?? []).reduce((s, r: any) => s + Number(r.amount_cents ?? 0), 0);
      const totalJpy = (rows ?? []).reduce((s, r: any) => s + Number(r.amount_jpy ?? 0), 0);
      const text = `📊 ${ym}のAI利用料（今月の累計）: ${yen(totalJpy)}（${usd(totalCents / 100)}）`;
      sent.weekly = { text, result: await sendLark(sb, text) };
    }

    // ③ しきい値超過（今日はじめて超えた時だけ）
    const thresholdUsd = Number(body.thresholdUsd);
    if ((thresholdUsd > 0) || force.includes("threshold")) {
      const ym = `${jstYear}-${String(jstMonth + 1).padStart(2, "0")}`;
      const monthStart = `${ym}-01`;
      const { data: rows } = await sb.from("api_cost_daily").select("date,amount_cents")
        .gte("date", monthStart).order("date", { ascending: true });
      const all = rows ?? [];
      const totalCentsAll = all.reduce((s, r: any) => s + Number(r.amount_cents ?? 0), 0);
      const lastRow = all[all.length - 1];
      const totalCentsBeforeLast = lastRow
        ? totalCentsAll - Number(lastRow.amount_cents ?? 0)
        : totalCentsAll;
      const thresholdCents = thresholdUsd * 100;
      const crossedToday = totalCentsBeforeLast < thresholdCents && totalCentsAll >= thresholdCents;
      if (crossedToday || force.includes("threshold")) {
        const text = `⚠️ 今月のAI利用料が閾値（$${thresholdUsd || "?"}）を超えました: ${usd(totalCentsAll / 100)}`;
        sent.threshold = { text, result: await sendLark(sb, text) };
      } else {
        sent.threshold = { skipped: true, totalUsd: totalCentsAll / 100, thresholdUsd };
      }
    }

    return json({ ok: true, jstDay, jstWeekday, sent });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
