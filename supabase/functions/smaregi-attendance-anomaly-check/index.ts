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
//
// 2026-11-07 追記（Slack 勤怠確認ボタン・ユーザー決定）: 異常値を sf_attendance_alerts に積み、勤怠確認チャンネル
//   （slack_channels 'kintai.check'＝C0CFQLYUM1Q・店長が参加）へ「○ 合っている / × 修正する」を送る。
//   ボタンの先は slack-interact → RPC（設計書 §10-5・SQL 2026-11-07_sf_attendance_alerts.sql）。押せる人は RPC が判定（店長=自店舗・TEAM/HQ/CEO）。
//   既存の LINE 通知と判定ロジックは無変更。body の { slack: false } で Slack を、{ line: false } で LINE を止められる（テスト用）。
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

// ---- 2026-11-07 Slack 勤怠確認ボタン ----------------------------------------
const JST = "Asia/Tokyo";
const WD = ["日", "月", "火", "水", "木", "金", "土"];
function jstParts(iso: string | null) {
  if (!iso) return null;
  const d = new Date(iso);
  const f = new Intl.DateTimeFormat("ja-JP", { timeZone: JST, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hour12: false });
  const o: Record<string, string> = {};
  for (const p of f.formatToParts(d)) o[p.type] = p.value;
  return { date: `${o.year}-${o.month}-${o.day}`, hm: `${o.hour === "24" ? "00" : o.hour}:${o.minute}`, unix: Math.floor(d.getTime() / 1000) };
}
function alertText(a: any) {
  const [y, m, d] = String(a.work_date).split("-").map(Number);
  const wd = WD[new Date(Date.UTC(y, m - 1, d)).getUTCDay()];
  const ci = jstParts(a.clock_in), co = jstParts(a.clock_out);
  const outTxt = co ? ((co.date > a.work_date ? "翌" : "") + co.hm) : "-";
  const title = `${m}/${d}（${wd}）　${a.store}`;
  const line = `*${a.name}*　${ci?.hm ?? "-"}−${outTxt}（${fmtHM(a.worked_minutes)}）`;
  return { title, line, ci, co };
}
// 勤怠確認の宛先: slack_channels の 'kintai.check'（ユーザー指定 2026-11-07・C0CFQLYUM1Q）。ID の変更は slack_channels を直すだけ
const ATTENDANCE_CHANNEL_KEY = "kintai.check";
async function notifySlack(body: Record<string, unknown>) {
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const res = await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/notify-slack`, {
    method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}`, apikey: key },
    body: JSON.stringify(body),
  });
  return await res.json();
}
async function slackAlert(sb: any, a: any) {
  // アラート行を確保（同じ勤怠実績には 1 行。既に通知済みなら送らない）
  await sb.from("sf_attendance_alerts").upsert({
    labor_cost_daily_id: a.id, user_id: a.user_id, store_id: a.store_id, work_date: a.work_date,
    clock_in: a.clock_in, clock_out: a.clock_out, worked_minutes: a.worked_minutes, kind: a.kind_code,
  }, { onConflict: "labor_cost_daily_id", ignoreDuplicates: true });
  const { data: alert } = await sb.from("sf_attendance_alerts").select("id,status,notification_ids").eq("labor_cost_daily_id", a.id).maybeSingle();
  if (!alert) return { labor_cost_daily_id: a.id, error: "alert row not found" };
  if (alert.status !== "open" || (alert.notification_ids ?? []).length) return { alert_id: alert.id, skipped: alert.status };

  const { title, line, ci, co } = alertText(a);
  const channels = [ATTENDANCE_CHANNEL_KEY];
  const sent: { channel_key: string; ok: boolean; notification_id?: string; error?: string }[] = [];
  const ids: string[] = [];
  for (const ch of channels) {
    const nid = crypto.randomUUID();
    const v = (extra: Record<string, unknown> = {}) => JSON.stringify({ alert_id: alert.id, notification_id: nid, ...extra });
    const blocks = [
      { type: "section", text: { type: "mrkdwn", text: `⚠️ *勤怠確認*\n${title}\n${line}\n${a.kind}。打刻は合っていますか？` } },
      { type: "actions", block_id: "attendance", elements: [
        { type: "button", style: "primary", text: { type: "plain_text", text: "○ 合っている", emoji: true }, action_id: "attendance.alert.confirm", value: v() },
        { type: "button", text: { type: "plain_text", text: "× 修正する", emoji: true }, action_id: "attendance.alert.fix",
          value: v({ in: ci?.unix ?? null, out: co?.unix ?? null, title: `${title}　${a.name}` }) },
      ] },
      { type: "context", elements: [{ type: "mrkdwn", text: `確認 \`${alert.id.slice(0, 8)}\`・修正はマスターの承認後に管理システムへ反映（スマレジ側の打刻は別途修正）` }] },
    ];
    const r = await notifySlack({
      action: "send", notification_id: nid, channel_key: ch, text: `⚠️ 勤怠確認 ${title} ${a.name} ${fmtHM(a.worked_minutes)}`, blocks,
      event: "attendance_alert", source: "ef:smaregi-attendance-anomaly-check", dedupe_key: `attendance_alert:${alert.id}:${ch}`,
      ref: { table: "sf_attendance_alerts", id: alert.id }, username: "勤怠確認", icon_emoji: ":alarm_clock:",
    });
    sent.push({ channel_key: ch, ok: !!r?.ok, notification_id: r?.notification_id, error: r?.error });
    if (r?.ok && r.notification_id) ids.push(r.notification_id);
  }
  if (ids.length) await sb.from("sf_attendance_alerts").update({ notification_ids: ids, updated_at: new Date().toISOString() }).eq("id", alert.id);
  return { alert_id: alert.id, sent };
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
    // 2026-08-24修正: new Date()がUTC基準のため、08:00 JST（=前日23:00 UTC）に実行される
    // cronでは「JSTの本当の昨日」ではなく2日前を指してしまうバグを修正
    // （smaregi-attendance-syncと同じ原因。D-3実装中に発覚。詳細はそちらのコメント参照）
    const nowJst = new Date(Date.now() + 9 * 3600 * 1000);
    const yesterday = new Date(nowJst.getTime() - 86400000);
    const dateFrom = body.date_from || yesterday.toISOString().slice(0, 10);
    const dateTo = body.date_to || yesterday.toISOString().slice(0, 10);

    const { data: rows } = await sb.from("labor_cost_daily")
      .select("id,user_id,store_id,work_date,clock_in,clock_out,worked_minutes,users(name),stores(name)")
      .gte("work_date", dateFrom)
      .lte("work_date", dateTo)
      .not("clock_out", "is", null); // 退勤前(勤務中)のレコードは誤検知防止のため対象外

    const anomalies: any[] = [];
    for (const r of rows ?? []) {
      const mins = Number((r as any).worked_minutes ?? 0);
      const name = (r as any).users?.name ?? "(不明)";
      const store = (r as any).stores?.name ?? "(不明)";
      const base = { name, store, work_date: r.work_date, worked_minutes: mins,
        id: (r as any).id, user_id: (r as any).user_id, store_id: (r as any).store_id, clock_in: (r as any).clock_in, clock_out: (r as any).clock_out };
      if (mins <= SHORT_MINUTES) {
        anomalies.push({ ...base, kind: "短すぎる勤務（1時間以内）", kind_code: "short" });
      } else if (mins > EXTREME_MINUTES) {
        anomalies.push({ ...base, kind: "24時間超え（要確認）", kind_code: "extreme" });
      } else if (mins > LONG_MINUTES) {
        anomalies.push({ ...base, kind: "長すぎる勤務（13時間超え）", kind_code: "long" });
      }
    }

    let notified = null;
    if (anomalies.length && body.line !== false) {
      const lines = anomalies.map((a) =>
        `${a.work_date} ${a.name}（${a.store}）: ${a.kind} ${fmtHM(a.worked_minutes)}`
      );
      const text = `⚠️ 勤怠の異常値アラート（${dateFrom}〜${dateTo}）\n${anomalies.length}件見つかりました。打刻ミスの可能性があります。\n\n${lines.join("\n")}`;
      notified = await linePush(sb, text);
    }

    // 2026-11-07: Slack の勤怠確認ボタン（店長へ個人DM）。失敗しても LINE・判定結果には影響させない
    let slack: any[] = [];
    if (anomalies.length && body.slack !== false) {
      for (const a of anomalies) {
        try { slack.push(await slackAlert(sb, a)); } catch (e) { slack.push({ labor_cost_daily_id: a.id, error: String(e).slice(0, 200) }); }
      }
    }

    return json({
      ok: true,
      dateFrom, dateTo,
      checked: (rows ?? []).length,
      anomalyCount: anomalies.length,
      anomalies: anomalies.map(({ id: _i, user_id: _u, store_id: _s, clock_in: _ci, clock_out: _co, kind_code: _k, ...rest }) => rest),
      notified,
      slack,
    });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
