// =============================================================
// 勤怠確認アラートの「修正」まわりの共通部品（2026-11-12 新規）
//   ユーザー決定: Slack の入力画面（モーダル）は廃止し、管理システムのフォーム（kintai.html）に一本化する。
//   ここは「文面・ボタン・引数を組み立てるだけ」の部品（DB にも Slack にも触らない＝単体でテストできる）。
//   使う側:
//     smaregi-attendance-anomaly-check … alertFixButton（「✏️ 修正する（フォームを開く）」＝url 付きボタン）
//     slack-interact                    … isFormLinkPress / fixFormLinkText（古いボタンにはフォームのリンクを返す）
//                                         fixRequestArgs / fixRequestedParentText / fixApprovalSend（残っているモーダル送信）
//     attendance-request                … op=alert / alert_fix（フォームからの修正申請。Slack と同じ RPC・同じ通知）
//   同じ文面を 2 か所に書かない（2026-11-08 に slack-interact 側だけ ref・表示名が抜けた不具合の再発防止）。
// =============================================================

/** ポータルの勤怠フォーム（GitHub Pages）。アラートから開くときは ?alert=<uuid> */
export const ATTENDANCE_FORM_URL = "https://mirai-oss.github.io/ns-portal/kintai.html";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const isUuid = (v: unknown): v is string => typeof v === "string" && UUID_RE.test(v);

export function alertFormUrl(alertId: string): string {
  return `${ATTENDANCE_FORM_URL}?alert=${encodeURIComponent(alertId)}`;
}

// ---- 1. アラートの「修正する」ボタン ------------------------------------------
export type AlertFixButtonInput = {
  alertId: string; notificationId: string; title: string;
  // 検知時点の打刻（unix 秒）。フォームは DB から読み直すので使わないが、古い版（モーダル）へ戻すときのために残す
  in?: number | null; out?: number | null; b1s?: number | null; b1e?: number | null; b2s?: number | null; b2e?: number | null;
};
/**
 * 「✏️ 修正する（フォームを開く）」。action_id は従来どおり attendance.alert.fix（変えない）。
 * url 付きのボタンは、押すと Slack がその URL を開き、同時に slack-interact へ押下の通知も送る。
 * value の form:1 が「url 付きの新しいボタン」の印（slack-interact は何も返さず終わる）。印の無い古いボタンにはリンクを返信する。
 */
export function alertFixButton(o: AlertFixButtonInput) {
  return {
    type: "button", text: { type: "plain_text", text: "✏️ 修正する（フォームを開く）", emoji: true }, action_id: "attendance.alert.fix",
    url: alertFormUrl(o.alertId),
    value: JSON.stringify({
      alert_id: o.alertId, notification_id: o.notificationId, in: o.in ?? null, out: o.out ?? null, title: o.title,
      b1s: o.b1s ?? null, b1e: o.b1e ?? null, b2s: o.b2s ?? null, b2e: o.b2e ?? null, form: 1,
    }),
  };
}
/** url 付きの新しいボタンが押されたか（＝Slack がフォームを開いている。こちらからは何も返さない） */
export function isFormLinkPress(value: unknown): boolean {
  return !!value && typeof value === "object" && (value as Record<string, unknown>).form === 1;
}
/** 古いボタン（url なし）が押されたときに、押した人だけに返す文面 */
export function fixFormLinkText(alertId: string, title?: string | null): string {
  const t = String(title ?? "").trim();
  return `✏️ <${alertFormUrl(alertId)}|修正フォームを開く>${t ? `（${t}）` : ""}\n` +
    "対象の人・日付・いまの打刻が入った状態で開きます。直して「修正を申請する」を押すと、マスターの承認へ進みます。";
}

// ---- 2. 時刻の変換 --------------------------------------------------------------
/** "YYYY-MM-DDTHH:MM"（JST・フォームの形）→ timestamptz 文字列。それ以外は null */
export function jstLocalToIso(v: unknown): string | null {
  if (typeof v !== "string") return null;
  const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2}))?$/.exec(v.trim());
  if (!m) return null;
  const [, y, mo, d, h, mi, s] = m;
  if (Number(mo) < 1 || Number(mo) > 12 || Number(d) < 1 || Number(d) > 31 || Number(h) > 23 || Number(mi) > 59 || Number(s ?? "0") > 59) return null;
  const iso = `${y}-${mo}-${d}T${h}:${mi}:${s ?? "00"}+09:00`;
  return isNaN(new Date(iso).getTime()) ? null : iso;
}
/** timestamptz → "YYYY-MM-DDTHH:MM"（JST）。RPC sf_attendance_form_day（op=day）と同じ形 */
export function isoToJstLocal(v: unknown): string | null {
  if (!v || typeof v !== "string") return null;
  const d = new Date(v);
  if (isNaN(d.getTime())) return null;
  return new Date(d.getTime() + 9 * 3600 * 1000).toISOString().slice(0, 16);
}
/** Slack の datetimepicker（unix 秒）→ ISO */
export function unixToIso(sec: unknown): string | null {
  const n = Number(sec);
  return sec === null || sec === undefined || sec === "" || !Number.isFinite(n) ? null : new Date(n * 1000).toISOString();
}

// ---- 3. RPC sf_attendance_fix_request の引数（Slack のモーダルとフォームで同じ作り方）----
export type FixRequestInput = {
  alertId: string; actorId: string; clockIn: string; clockOut: string; reason: string; via: "slack" | "form";
  breaks?: { b1s?: string | null; b1e?: string | null; b2s?: string | null; b2e?: string | null };
  noBreak?: boolean;   // true のときは休憩欄を無視して全部 null（＝休憩なしにする）
};
export function fixRequestArgs(o: FixRequestInput) {
  const pick = (v: string | null | undefined) => (o.noBreak ? null : (v ?? null));
  return {
    p_alert_id: o.alertId, p_actor: o.actorId,
    p_clock_in: o.clockIn, p_clock_out: o.clockOut,
    p_reason: o.reason, p_via: o.via,
    p_break_start_1: pick(o.breaks?.b1s), p_break_end_1: pick(o.breaks?.b1e), p_break_start_2: pick(o.breaks?.b2s), p_break_end_2: pick(o.breaks?.b2e),
  };
}

// ---- 4. 申請後の通知の文面 ------------------------------------------------------
export type FixRequested = { alertId: string; summary: string; proposed: string; reason: string; actorName: string };
/** 勤怠確認チャンネルの元メッセージを書き換える文面（ボタンが消えて「承認待ち」になる） */
export function fixRequestedParentText(d: FixRequested & { when: string }): string {
  return `📝 修正を申請しました（${d.actorName}・${d.when}）\n${d.summary}\n→ 修正後 ${d.proposed}　理由: ${d.reason}\n承認待ち（マスター）`;
}
/**
 * マスターへの承認依頼（notify-slack の send にそのまま渡す本体）。
 * ref（台帳 notification_deliveries.ref_table / ref_id）・username・icon_emoji を必ず含める。
 * dedupe_key の末尾に通知 id の先頭 8 桁: 同じアラートに 2 度目の申請が来たとき（テストの再利用など）に「重複」で送られない事故を防ぐ（2026-11-08）。
 */
export function fixApprovalSend(d: FixRequested & { notificationId: string; channelKey: string; source: string }) {
  const val = JSON.stringify({ alert_id: d.alertId, notification_id: d.notificationId });
  return {
    action: "send", notification_id: d.notificationId, channel_key: d.channelKey, event: "attendance_fix_request", source: d.source,
    text: `🙋 勤怠修正の承認依頼 ${d.summary} → ${d.proposed}`,
    blocks: [
      { type: "section", text: { type: "mrkdwn", text: `🙋 *勤怠修正の承認依頼*\n${d.summary}\n申請: ${d.actorName}\n*修正後: ${d.proposed}*\n理由: ${d.reason}` } },
      { type: "actions", block_id: "attendance_fix", elements: [
        { type: "button", style: "primary", text: { type: "plain_text", text: "✅ 承認", emoji: true }, action_id: "attendance.fix.approve", value: val },
        { type: "button", style: "danger", text: { type: "plain_text", text: "❌ 却下", emoji: true }, action_id: "attendance.fix.reject", value: val },
      ] },
      { type: "context", elements: [{ type: "mrkdwn", text: `確認 \`${String(d.alertId).slice(0, 8)}\`・承認すると管理システムの勤怠実績に反映（スマレジ側の打刻は別途修正）` }] },
    ],
    dedupe_key: `attendance_fix:${d.alertId}:${d.channelKey}:${d.notificationId.slice(0, 8)}`,
    ref: { table: "sf_attendance_alerts", id: d.alertId },
    username: "勤怠確認", icon_emoji: ":alarm_clock:",
  };
}

// ---- 5. フォーム（op=alert）に返す内容 -------------------------------------------
/** open 以外のアラートを開いたときの説明 */
export function alertStatusMessage(status: string, requestKind?: string | null): string {
  const del = requestKind === "delete";
  switch (status) {
    case "confirmed": return "この勤怠確認は、すでに「○ 合っている」で確認済みです。直すときは、下の通常のフォームから申請してください。";
    case "fix_requested": return del ? "この勤怠確認は、すでに打刻の削除を申請済みです（マスターの承認待ち）。" : "この勤怠確認は、すでに修正を申請済みです（マスターの承認待ち）。";
    case "approved": return del ? "この勤怠確認は、打刻の削除が承認済みです。" : "この勤怠確認は、修正が承認されて反映済みです。さらに直すときは、下の通常のフォームから申請してください。";
    case "rejected": return "この勤怠確認の申請は却下されています。直すときは、下の通常のフォームから申請し直してください。";
    case "cancelled": return "この勤怠確認は取り消されています。";
    default: return `この勤怠確認はすでに処理されています（${status}）。`;
  }
}
const TIME_COLS = ["clock_in", "clock_out", "break_start_1", "break_end_1", "break_start_2", "break_end_2"] as const;
type TimeRow = Partial<Record<(typeof TIME_COLS)[number], string | null>>;
export type AlertFormRow = {
  id: string; status: string; request_kind: string; user_id: string; name: string; store_id: string; store_name: string; work_date: string;
  clock_in: string | null; clock_out: string | null; break_start_1: string | null; break_end_1: string | null; break_start_2: string | null; break_end_2: string | null;
  worked_minutes: number | null; break_minutes: number | null; locked: boolean; changed_since_alert: boolean;
};
/**
 * フォームに入れる「いまの勤怠」。勤怠実績（labor_cost_daily）の今の値を使う（承認で上書きされるのはこの行。アラートの後に
 * 退勤が打たれた・スマレジ側で直された場合も、今の値が「修正前」になる）。時刻は JST の "YYYY-MM-DDTHH:MM"（op=day と同じ形）。
 * changed_since_alert: アラートを出した時点の打刻から変わっているか（画面に一言出す）。
 */
export function alertFormRow(
  alert: TimeRow & { id: string; status: string; request_kind?: string | null; user_id: string; store_id: string; work_date: string },
  labor: TimeRow & { worked_minutes?: number | string | null; break_minutes?: number | string | null; manual_fixed_at?: string | null },
  names: { user: string | null; store: string | null },
): AlertFormRow {
  const t = (v: unknown) => isoToJstLocal(v);
  const num = (v: unknown) => (v === null || v === undefined || v === "" || !Number.isFinite(Number(v)) ? null : Math.round(Number(v)));
  const changed = TIME_COLS.some((c) => t(alert[c]) !== t(labor[c]));
  return {
    id: alert.id, status: alert.status, request_kind: alert.request_kind ?? "fix",
    user_id: alert.user_id, name: names.user ?? "", store_id: alert.store_id, store_name: names.store ?? "", work_date: String(alert.work_date).slice(0, 10),
    clock_in: t(labor.clock_in), clock_out: t(labor.clock_out),
    break_start_1: t(labor.break_start_1), break_end_1: t(labor.break_end_1), break_start_2: t(labor.break_start_2), break_end_2: t(labor.break_end_2),
    worked_minutes: num(labor.worked_minutes), break_minutes: num(labor.break_minutes), locked: !!labor.manual_fixed_at, changed_since_alert: changed,
  };
}

// ---- 6. 休憩の申告（op=break_declare）--------------------------------------------
/** RPC がまだ無い（別の担当が作成中）ときのエラーか。PostgREST は PGRST202、Postgres は 42883 を返す */
export function isMissingRpc(error: { code?: string | null; message?: string | null } | null | undefined): boolean {
  if (!error) return false;
  return error.code === "PGRST202" || error.code === "42883" || /could not find the function/i.test(String(error.message ?? ""));
}
export const BREAK_NOT_READY = "この機能はまだ使えません";
/** 入力の形だけ検査（権限・重複などは RPC 側）。エラー文か、RPC に渡す引数 */
export function breakDeclareArgs(b: Record<string, unknown>, actorId: string): { error: string } | { args: { p_user: string; p_work_date: string; p_kind: "none" | "short"; p_minutes: number | null; p_reason: string; p_actor: string } } {
  const user = String(b.user_id ?? ""), date = String(b.work_date ?? ""), kind = String(b.kind ?? ""), reason = String(b.reason ?? "").trim();
  if (!isUuid(user)) return { error: "対象の人を選んでください" };
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || isNaN(new Date(date + "T00:00:00Z").getTime())) return { error: "勤務日を選んでください" };
  if (kind !== "none" && kind !== "short") return { error: "「休憩を取っていない」か「休憩が短かった」を選んでください" };
  let minutes: number | null = null;
  if (kind === "short") {
    const n = typeof b.minutes === "number" ? b.minutes : Number(String(b.minutes ?? "").trim() || NaN);
    if (!Number.isInteger(n) || n < 1 || n > 59) return { error: "実際に休憩した分数を 1〜59 で入れてください" };
    minutes = n;
  }
  const len = [...reason].length;
  if (len < 1 || len > 300) return { error: "理由を 300 字以内で入れてください" };
  return { args: { p_user: user, p_work_date: date, p_kind: kind, p_minutes: minutes, p_reason: reason, p_actor: actorId } };
}

// ---- 変更が無い修正申請は受け付けない（2026-11-11 ユーザー決定。画面でも止めるが、受け口でも確かめる） ----
//   出勤・退勤・休憩 1・休憩 2 が、いまの勤怠と分の単位まで同じなら true
export type TimesLike = { clock_in?: string | null; clock_out?: string | null; break_start_1?: string | null; break_end_1?: string | null; break_start_2?: string | null; break_end_2?: string | null };
export function sameTimes(cur: TimesLike | null | undefined, prop: TimesLike): boolean {
  if (!cur) return false;
  const m = (v: string | null | undefined) => { if (!v) return null; const t = new Date(v).getTime(); return Number.isFinite(t) ? Math.floor(t / 60000) : NaN; };
  return (["clock_in", "clock_out", "break_start_1", "break_end_1", "break_start_2", "break_end_2"] as const).every((k) => m(cur[k]) === m(prop[k]));
}
export const NO_CHANGE_MESSAGE = "修正前から変わっていません。直す時刻を入れてから申請してください";
