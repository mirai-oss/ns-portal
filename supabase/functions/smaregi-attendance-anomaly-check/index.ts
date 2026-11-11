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
// 2026-11-07 条件の追加（ユーザー決定「全店舗共通」）:
//   short=1時間以内／long=12時間以上（休憩除く＝(退勤−出勤)−休憩。休憩が無ければ worked_minutes）／extreme=24時間超
//   late_leave=翌朝 6 時以降の退勤／no_clock_out=退勤打刻なし（勤務日の翌朝になっても退勤が無い＝旧「対象外」を対象に）
//   break_long=休憩合計 120 分超、または休憩の終了打刻なし
//   1 勤務に複数該当しても Slack は 1 通（kind=先頭・reasons に全部）。
//
// 2026-11-07 追記（Slack 勤怠確認ボタン・ユーザー決定）: 異常値を sf_attendance_alerts に積み、勤怠確認チャンネル
//   （slack_channels 'kintai.check'＝C0CFQLYUM1Q・店長が参加）へ「○ 合っている / × 修正する」を送る。
//   ボタンの先は slack-interact → RPC（設計書 §10-5・SQL 2026-11-07_sf_attendance_alerts.sql）。押せる人は RPC が判定（店長=自店舗・TEAM/HQ/CEO）。
//   判定ロジックは無変更。通知は Slack（勤怠確認チャンネル・ボタン付き）。LINE は 2026-11-08 に停止（body { line: true } で一時的に送れる）。body { slack: false } で Slack を止められる（テスト用）。
import { createClient } from "npm:@supabase/supabase-js@2";
import { alertFixButton } from "../_shared/attendance-fix-notify.ts";
import { postAlert } from "../_shared/attendance-alert-notice.ts";   // 2026-11-11: 新しい形（親 1 行＋スレッドに詳細と操作）   // 2026-11-12: 「修正する」はフォームを開く url 付きボタン（定義は共通部品・単体テストあり）

const SHORT_MINUTES = 60;
const LONG_MINUTES = 12 * 60;      // 2026-11-07 ユーザー決定: 12 時間以上（休憩除く）。旧 13 時間超から変更
const EXTREME_MINUTES = 24 * 60;   // 1440
const LATE_LEAVE_HOUR = 6;         // 翌朝 6 時以降の退勤
const BREAK_LONG_MINUTES = 120;    // 休憩合計がこれを超えたら「長すぎる」（押し忘れの可能性）

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
  const outTxt = co ? ((co.date > a.work_date ? "翌" : "") + co.hm) : "退勤なし";
  const title = `${m}/${d}（${wd}）　${a.store}`;
  const brk = (s: string | null, e: string | null) => s ? `${jstParts(s)!.hm}−${e ? jstParts(e)!.hm : "終了なし"}` : null;
  const breaks = [brk(a.b1s, a.b1e), brk(a.b2s, a.b2e)].filter(Boolean);
  const breakTxt = breaks.length ? `休憩 ${breaks.join("・")}` : "休憩なし";
  const line = `*${a.name}*　${ci?.hm ?? "-"}−${outTxt}（${a.worked_minutes == null ? "-" : fmtHM(a.worked_minutes)}・${breakTxt}）`;
  // 2026-11-08 ユーザー要望「もっと分かりやすい表記に」: 1 行 1 項目。異常のある項目の頭に ⚠️
  const codes: string[] = a.reason_codes ?? [];
  const has = (...c: string[]) => codes.some((x) => c.includes(x));
  const brkMin = a.break_minutes != null ? Number(a.break_minutes)
    : [[a.b1s, a.b1e], [a.b2s, a.b2e]].reduce((acc, [s0, e0]) => (s0 && e0) ? acc + Math.round((new Date(e0).getTime() - new Date(s0).getTime()) / 60000) : acc, 0);
  const breakLine = breaks.length ? `${breaks.join("・")}（${fmtHM(brkMin)}）` : "なし";
  const body = [
    `${title}　*${a.name}*`,
    `打刻時間：${ci?.hm ?? "-"}−${outTxt}`,
    `出勤時間：${ci?.hm ?? "-"}`,
    `${has("late_leave", "no_clock_out") ? "⚠️" : ""}退勤時間：${co ? outTxt : "なし（打刻忘れ？）"}`,
    `${has("short", "long", "extreme") ? "⚠️" : ""}勤務時間：${a.worked_minutes == null ? "-" : fmtHM(a.worked_minutes)}${breaks.length ? "（休憩除く）" : ""}`,
    `${has("break_long") ? "⚠️" : ""}休憩時間：${breakLine}`,
    ...((a.reasons ?? []) as string[]).map((r) => `⚠️ ${r}。打刻は合っていますか？`),
  ].join("\n");
  return { title, line, ci, co, body };
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
// 2026-11-11（ユーザー決定）: 通知の形。"v2"＝親メッセージは 1 行だけ・詳細と操作はスレッド／"v1"＝今までの形（親に詳細とボタン）。
//   既定は app_settings.slack_policy.attendance_alert_format（無ければ v1）。body.format で 1 回だけ上書きできる（テスト投稿用）。
//   opt.test=true: テスト用のアラート（承認してもスマレジへ送らない・リマインドのメンションは承認者だけ）。opt.channelKey: テストのときだけ宛先を変えられる。
type AlertOpt = { format: "v1" | "v2"; test: boolean; channelKey: string; detailButton: boolean };
async function slackAlert(sb: any, a: any, opt: AlertOpt) {
  // アラート行を確保（同じ勤怠実績には 1 行。既に通知済みなら送らない）
  await sb.from("sf_attendance_alerts").upsert({
    labor_cost_daily_id: a.id, user_id: a.user_id, store_id: a.store_id, work_date: a.work_date,
    clock_in: a.clock_in, clock_out: a.clock_out, worked_minutes: a.worked_minutes, kind: a.kind_code, reasons: a.reasons ?? null,
    break_start_1: a.b1s ?? null, break_end_1: a.b1e ?? null, break_start_2: a.b2s ?? null, break_end_2: a.b2e ?? null,
  }, { onConflict: "labor_cost_daily_id", ignoreDuplicates: true });
  const { data: alert } = await sb.from("sf_attendance_alerts").select("id,status,notification_ids").eq("labor_cost_daily_id", a.id).maybeSingle();
  if (!alert) return { labor_cost_daily_id: a.id, error: "alert row not found" };
  if (alert.status !== "open" || (alert.notification_ids ?? []).length) return { alert_id: alert.id, skipped: alert.status };

  if (opt.format === "v2") {
    return await postAlert(sb, notifySlack, {
      alertId: alert.id, userId: a.user_id, storeId: a.store_id, workDate: String(a.work_date), userName: a.name, storeName: a.store, kind: a.kind_code, reasons: a.reasons ?? [],
      times: { clock_in: a.clock_in, clock_out: a.clock_out, break_start_1: a.b1s ?? null, break_end_1: a.b1e ?? null, break_start_2: a.b2s ?? null, break_end_2: a.b2e ?? null },
    }, { channelKey: opt.channelKey, test: opt.test, detailButton: opt.detailButton, slackToken: Deno.env.get("SLACK_BOT_TOKEN") ?? null, source: "ef:smaregi-attendance-anomaly-check" });
  }
  const { title, ci, co, body } = alertText(a);
  const channels = [opt.channelKey];
  const sent: { channel_key: string; ok: boolean; notification_id?: string; error?: string }[] = [];
  const ids: string[] = [];
  for (const ch of channels) {
    const nid = crypto.randomUUID();
    const v = (extra: Record<string, unknown> = {}) => JSON.stringify({ alert_id: alert.id, notification_id: nid, ...extra });
    const blocks = [
      { type: "section", text: { type: "mrkdwn", text: `⚠️ *勤怠確認*\n${body}` } },
      { type: "actions", block_id: "attendance", elements: [
        { type: "button", style: "primary", text: { type: "plain_text", text: "○ 合っている", emoji: true }, action_id: "attendance.alert.confirm", value: v() },
        // 2026-11-12（ユーザー決定）: 修正の入力は管理システムのフォームに一本化。押すと kintai.html?alert=<id> が開く（action_id は従来どおり attendance.alert.fix）
        alertFixButton({ alertId: alert.id, notificationId: nid, title: `${title}　${a.name}`, in: ci?.unix ?? null, out: co?.unix ?? null,
          b1s: jstParts(a.b1s)?.unix ?? null, b1e: jstParts(a.b1e)?.unix ?? null, b2s: jstParts(a.b2s)?.unix ?? null, b2e: jstParts(a.b2e)?.unix ?? null }),
        // 2026-11-08 本人が出勤していなかった等: 理由だけ入れて削除を申請（マスター承認後に管理システムとスマレジから削除）
        { type: "button", style: "danger", text: { type: "plain_text", text: "🗑 打刻を消す", emoji: true }, action_id: "attendance.alert.delete", value: v({ title: `${title}　${a.name}` }) },
      ] },
      { type: "context", elements: [{ type: "mrkdwn", text: `確認 \`${alert.id.slice(0, 8)}\`・修正はマスターの承認後に管理システムとスマレジへ反映。別の日や打刻が無い日の申請は <https://mirai-oss.github.io/ns-portal/kintai.html|勤怠の追加・修正フォーム>` }] },
    ];
    const r = await notifySlack({
      action: "send", notification_id: nid, channel_key: ch, text: `⚠️ 勤怠確認 ${title} ${a.name} ${a.kind}`, blocks,
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
    // 2026-11-08: pg_cron（毎朝 10:00 JST・attendance_anomaly_check_trigger）からは x-notify-secret で呼ぶ（他の cron 起動 EF と同じ）
    const secret = (Deno.env.get("NOTIFY_SLACK_SECRET") ?? "").trim();
    const hdr = (req.headers.get("x-notify-secret") ?? "").trim();
    const isCronSecret = !!(secret && hdr && secret.length === hdr.length && [...secret].every((c, i) => c === hdr[i]));
    if (!isServiceRole && !isCronSecret) {
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

    // 2026-11-08 修正: labor_cost_daily は users を 2 本参照する（user_id と manual_fixed_by=手修正ロック 2026-11-07）ため
    // `users(name)` だと PostgREST が「どちらか分からない」で失敗し、エラーを握りつぶして checked=0 になっていた（11/7 昼〜11/8 朝の実損）。参照名を明示する
    // 2026-11-11: body.only_ids（勤怠実績の id の配列）があれば、その行だけを対象にする（テスト投稿・個別の出し直し用。実行記録は残さない）
    const onlyIds: string[] = Array.isArray(body.only_ids) ? body.only_ids.filter((x: unknown) => typeof x === "string" && /^[0-9a-f-]{36}$/i.test(x)).slice(0, 20) : [];
    const sel = "id,user_id,store_id,work_date,clock_in,clock_out,worked_minutes,break_start_1,break_end_1,break_start_2,break_end_2,break_minutes,users!labor_cost_daily_user_id_fkey(name),stores!labor_cost_daily_store_id_fkey(name)";
    const { data: rows, error: qErr } = onlyIds.length
      ? await sb.from("labor_cost_daily").select(sel).in("id", onlyIds)
      : await sb.from("labor_cost_daily").select(sel)
      .gte("work_date", dateFrom)
      .lte("work_date", dateTo); // 2026-11-07: 退勤なし（clock_out null）も対象（勤務日の翌朝以降に残っていれば打刻忘れ）

    if (qErr) return json({ ok: false, error: "labor_cost_daily を読めません: " + qErr.message, dateFrom, dateTo }, 500);
    const anomalies: any[] = [];
    for (const r of rows ?? []) {
      const mins = Number((r as any).worked_minutes ?? 0);
      const name = (r as any).users?.name ?? "(不明)";
      const store = (r as any).stores?.name ?? "(不明)";
      const x = r as any;
      const base = { name, store, work_date: r.work_date, worked_minutes: (x.worked_minutes == null ? null : mins),
        id: x.id, user_id: x.user_id, store_id: x.store_id, clock_in: x.clock_in, clock_out: x.clock_out,
        b1s: x.break_start_1, b1e: x.break_end_1, b2s: x.break_start_2, b2e: x.break_end_2, break_minutes: x.break_minutes };
      const reasons: { code: string; label: string }[] = [];
      const todayJst = nowJst.toISOString().slice(0, 10);
      if (!x.clock_out) {
        // 勤務日の翌日以降（＝毎朝 08:00 の実行時点で前日の勤務が開いたまま）なら退勤打刻なし
        if (String(r.work_date) < todayJst) reasons.push({ code: "no_clock_out", label: "退勤打刻なし" });
      } else {
        const span = (new Date(x.clock_out).getTime() - new Date(x.clock_in).getTime()) / 60000;
        const net = x.break_minutes != null ? span - Number(x.break_minutes) : mins;   // 休憩除く
        if (span > EXTREME_MINUTES) reasons.push({ code: "extreme", label: "24時間超え（要確認）" });
        else if (net >= LONG_MINUTES) reasons.push({ code: "long", label: `12時間以上の勤務（休憩除く ${fmtHM(Math.round(net))}）` });
        if (mins <= SHORT_MINUTES) reasons.push({ code: "short", label: "短すぎる勤務（1時間以内）" });
        const co = jstParts(x.clock_out);
        if (co && co.date > String(r.work_date) && Number(co.hm.slice(0, 2)) >= LATE_LEAVE_HOUR) reasons.push({ code: "late_leave", label: `翌朝 ${LATE_LEAVE_HOUR} 時以降の退勤（${co.hm}）` });
      }
      const breakOpen = (x.break_start_1 && !x.break_end_1) || (x.break_start_2 && !x.break_end_2);
      if (breakOpen) reasons.push({ code: "break_long", label: "休憩の終了打刻なし" });
      else if (x.break_minutes != null && Number(x.break_minutes) > BREAK_LONG_MINUTES) reasons.push({ code: "break_long", label: `休憩が長すぎる（${fmtHM(Number(x.break_minutes))}）` });
      if (reasons.length) {
        anomalies.push({ ...base, kind: reasons.map((q) => q.label).join("・"), kind_code: reasons[0].code, reasons: reasons.map((q) => q.label), reason_codes: reasons.map((q) => q.code) });
      }
    }

    let notified = null;
    // 2026-11-08 ユーザー決定「LINE の異常値アラートは止めて Slack だけで運用」: LINE は body { line: true } のときだけ送る
    if (anomalies.length && body.line === true) {
      const lines = anomalies.map((a) =>
        `${a.work_date} ${a.name}（${a.store}）: ${a.kind}${a.worked_minutes == null ? "" : " " + fmtHM(a.worked_minutes)}`
      );
      const text = `⚠️ 勤怠の異常値アラート（${dateFrom}〜${dateTo}）\n${anomalies.length}件見つかりました。打刻ミスの可能性があります（Slack の勤怠確認にもボタン付きで届いています）。\n\n${lines.join("\n")}`;
      notified = await linePush(sb, text);
    }

    // 2026-11-07: Slack の勤怠確認ボタン（店長へ個人DM）。失敗しても LINE・判定結果には影響させない
    let slack: any[] = [];
    if (anomalies.length && body.slack !== false) {
      // 通知の形: body.format（1 回だけ）→ 設定 slack_policy.attendance_alert_format → v1
      let fmt: "v1" | "v2" = "v1";
      try { const { data: pol } = await sb.from("app_settings").select("value").eq("key", "slack_policy").maybeSingle(); if (pol?.value?.attendance_alert_format === "v2") fmt = "v2"; } catch (_) { /* 読めなければ今までの形 */ }
      if (body.format === "v1" || body.format === "v2") fmt = body.format;
      const test = body.test === true;
      const opt: AlertOpt = { format: fmt, test, channelKey: test && typeof body.channel_key === "string" && body.channel_key ? body.channel_key : ATTENDANCE_CHANNEL_KEY, detailButton: body.detail_button !== false };
      for (const a of anomalies) {
        try { slack.push(await slackAlert(sb, a, opt)); } catch (e) { slack.push({ labor_cost_daily_id: a.id, error: String(e).slice(0, 200) }); }
      }
    }

    // 2026-11-08: 実行記録（対象の終わりの日ごと）。10:00 の時点で昨日の行が無かった（checked=0）ときは
    // attendance_anomaly_catchup()（pg_cron 15 分おき）が行の到着を見て流し直す
    if (!onlyIds.length) try {
      await sb.from("sf_attendance_anomaly_runs").upsert({
        date_to: dateTo, date_from: dateFrom, checked: (rows ?? []).length, anomaly_count: anomalies.length,
        slack_sent: slack.filter((x: any) => x && !x.error).length, ran_at: new Date().toISOString(),
        trigger: body.trigger ?? (isServiceRole ? "service_role" : isCronSecret ? "cron" : "user"),
      }, { onConflict: "date_to" });
    } catch (_) { /* 記録の失敗は結果に影響させない */ }

    return json({
      ok: true,
      dateFrom, dateTo,
      checked: (rows ?? []).length,
      anomalyCount: anomalies.length,
      anomalies: anomalies.map(({ id: _i, user_id: _u, store_id: _s, clock_in: _ci, clock_out: _co, kind_code: _k, b1s: _a, b1e: _b, b2s: _c, b2e: _d, ...rest }) => rest),
      notified,
      slack,
    });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
