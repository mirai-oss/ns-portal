// =============================================================
// 勤怠確認の Slack 通知「新しい形」（2026-11-11 ユーザー決定）
//   親メッセージ = 1 行だけ（状態の印・「勤怠確認」・氏名・日付）＋「詳細を確認」。1 件のアラートに親は 1 つ。
//   スレッド     = 1 通目に「詳細と操作のカード」（状態が変わるたびに同じカードを書き換える＝古いボタンが残らない）。
//                  承認の依頼・リマインドは、スレッドへの返信（ここでだけメンション）。
//   まだ修正が申請されていないあいだは、承認ボタンを出さない。申請があるときだけ、変更前後の差分と理由を出して承認・却下を出す。
//
//   前半は「文面を組み立てるだけ」（DB にも Slack にも触らない＝単体でテストできる）。
//   後半は「読んで・組み立てて・送る」処理（sb と notify を外から受け取る。anomaly-check / slack-interact / attendance-request / pending-reminders が使う）。
//   どのアラートが新しい形かは、案件の控え notice_cases（type_key=attendance_fix）に card の控えがあるかで決まる。
//   控えの無いアラート（古い形）は、各 EF の今までの処理がそのまま動く。
// =============================================================
import { alertFixButton } from "./attendance-fix-notify.ts";

export const NOTICE_TYPE = "attendance_fix";
export const REF_TABLE = "sf_attendance_alerts";
const USERNAME = "勤怠確認", ICON = ":alarm_clock:";

// ---- 1. 文面（純粋な関数） ---------------------------------------------------------
export type Times = { clock_in?: string | null; clock_out?: string | null; break_start_1?: string | null; break_end_1?: string | null; break_start_2?: string | null; break_end_2?: string | null };
const WD = ["日", "月", "火", "水", "木", "金", "土"];
const clean = (s: unknown, max = 40) => String(s ?? "").replace(/[\n\r|｜<>]/g, " ").trim().slice(0, max) || "—";

/** "2026-11-10" → { md: "11/10", mdw: "11/10（火）" } */
export function dateLabel(workDate: string): { md: string; mdw: string } {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(workDate ?? ""));
  if (!m) return { md: "—", mdw: "—" };
  const md = `${Number(m[2])}/${Number(m[3])}`;
  return { md, mdw: `${md}（${WD[new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]))).getUTCDay()]}）` };
}
/** 時刻（日本時間の HH:MM）。勤務日の翌日なら「翌」、前日なら「前日」を頭に付ける。null は null */
export function hm(iso: string | null | undefined, workDate: string): string | null {
  if (!iso) return null;
  const t = new Date(iso).getTime();
  if (!Number.isFinite(t)) return null;
  const j = new Date(t + 9 * 3600e3).toISOString();
  const d = j.slice(0, 10), w = String(workDate).slice(0, 10);
  return (d > w ? "翌" : d < w ? "前日" : "") + j.slice(11, 16);
}
/** 日時（M/D HH:MM・日本時間） */
export function whenJst(iso: string | null | undefined): string {
  if (!iso) return "";
  const t = new Date(iso).getTime();
  if (!Number.isFinite(t)) return "";
  const j = new Date(t + 9 * 3600e3);
  return `${j.getUTCMonth() + 1}/${j.getUTCDate()} ${String(j.getUTCHours()).padStart(2, "0")}:${String(j.getUTCMinutes()).padStart(2, "0")}`;
}
const minuteOf = (v: string | null | undefined) => { if (!v) return null; const t = new Date(v).getTime(); return Number.isFinite(t) ? Math.floor(t / 60000) : null; };
const breakPair = (s: string | null | undefined, e: string | null | undefined, wd: string) => (s ? `${hm(s, wd)}−${e ? hm(e, wd) : "終了なし"}` : "なし");

/** いまの打刻を 1 行で（出勤 15:00／退勤 未登録／休憩 なし） */
export function punchLine(t: Times, workDate: string): string {
  const breaks = [[t.break_start_1, t.break_end_1], [t.break_start_2, t.break_end_2]].filter(([s]) => !!s).map(([s, e]) => breakPair(s, e, workDate));
  return `出勤 ${hm(t.clock_in, workDate) ?? "未登録"}／退勤 ${hm(t.clock_out, workDate) ?? "未登録"}／休憩 ${breaks.length ? breaks.join("・") : "なし"}`;
}
/** 変更前 → 変更後。変わった項目だけ（分の単位で比べる）。休憩 2 がどちらにも無ければ「休憩」、あれば「休憩1」「休憩2」 */
export function diffLines(before: Times | null | undefined, after: Times, workDate: string): string[] {
  const b = before ?? {};
  const out: string[] = [];
  const one = (label: string, x: string | null | undefined, y: string | null | undefined) => {
    if (minuteOf(x) !== minuteOf(y)) out.push(`${label}：${hm(x, workDate) ?? "未登録"} → ${hm(y, workDate) ?? "未登録"}`);
  };
  one("出勤", b.clock_in, after.clock_in);
  one("退勤", b.clock_out, after.clock_out);
  const two = !!(b.break_start_2 || after.break_start_2);
  const pair = (label: string, bs: string | null | undefined, be: string | null | undefined, as: string | null | undefined, ae: string | null | undefined) => {
    if (minuteOf(bs) !== minuteOf(as) || minuteOf(be) !== minuteOf(ae)) out.push(`${label}：${breakPair(bs, be, workDate)} → ${breakPair(as, ae, workDate)}`);
  };
  pair(two ? "休憩1" : "休憩", b.break_start_1, b.break_end_1, after.break_start_1, after.break_end_1);
  if (two) pair("休憩2", b.break_start_2, b.break_end_2, after.break_start_2, after.break_end_2);
  return out;
}

/** アラートの種類（sf_attendance_alerts.kind）→ 見出しの言葉 */
export const KIND_LABEL: Record<string, string> = {
  no_clock_out: "打刻漏れ", short: "短すぎる勤務", long: "長すぎる勤務", extreme: "24時間超え", late_leave: "遅い時刻の退勤", break_long: "休憩の確認",
};

export type AlertView = {
  alertId: string; status: string; requestKind: string; kind: string; reasons: string[];
  workDate: string; storeName: string | null; userName: string | null;
  detected: Times;            // 検知した時点の打刻
  before: Times | null;       // 申請の時点の打刻（差分の左側）。無ければ detected
  proposed: Times;            // 申請された修正後
  fixReason: string | null; requestedByName: string | null; requestedAt: string | null;
  confirmedByName: string | null; confirmedAt: string | null;
  decidedByName: string | null; decidedAt: string | null; decisionNote: string | null;
  smaregi: string | null; smaregiError: string | null;
  test: boolean;              // テスト用（スマレジへ反映しない）
};

/** 親メッセージの状態。done=完了（これ以上の対応は要らない） */
export function parentState(v: Pick<AlertView, "status" | "smaregi" | "test">): { mark: string; suffix: string; done: boolean; code: "todo" | "waiting" | "done" | "alert" } {
  switch (v.status) {
    case "open": return { mark: "🕒", suffix: "", done: false, code: "todo" };
    case "fix_requested": return { mark: "📝", suffix: "承認待ち", done: false, code: "waiting" };
    case "approved":
      if (v.smaregi === "failed") return { mark: "🔴", suffix: "要対応", done: false, code: "alert" };
      return { mark: "✅", suffix: "完了", done: true, code: "done" };
    case "confirmed": return { mark: "✅", suffix: "完了", done: true, code: "done" };
    case "rejected": return { mark: "✅", suffix: "完了（却下）", done: true, code: "done" };
    case "cancelled": return { mark: "✅", suffix: "完了（取り消し）", done: true, code: "done" };
    default: return { mark: "🕒", suffix: "", done: false, code: "todo" };
  }
}
/**
 * 親メッセージ（1 行）。例: 🕒 勤怠確認｜山田太郎｜11/11
 * 種類・原因・時刻・理由・履歴・承認や修正のボタンは出さない。「詳細を確認」は、スレッドを開くリンクのボタン（完了したら外す）。
 */
export function parentMessage(v: Pick<AlertView, "alertId" | "status" | "smaregi" | "test" | "userName" | "workDate">, o: { permalink?: string | null } = {}): { text: string; blocks: unknown[] } {
  const st = parentState(v);
  const text = `${st.mark} 勤怠確認｜${clean(v.userName, 30)}｜${dateLabel(v.workDate).md}${st.suffix ? `｜${st.suffix}` : ""}`;
  const blocks: unknown[] = [{ type: "section", text: { type: "mrkdwn", text } }];
  if (o.permalink && !st.done) {
    blocks.push({ type: "actions", block_id: "attendance_open", elements: [
      { type: "button", text: { type: "plain_text", text: "詳細を確認", emoji: true }, action_id: "attendance.alert.open", url: o.permalink, value: JSON.stringify({ alert_id: v.alertId }) },
    ] });
  }
  return { text, blocks };
}

function smaregiLine(v: AlertView): string {
  const del = v.requestKind === "delete";
  if (v.smaregi === "synced") return del ? "スマレジ：✅ 削除済み" : "スマレジ：✅ 反映済み";
  if (v.smaregi === "failed") return `スマレジ：⚠️ ${del ? "削除" : "反映"}に失敗（${String(v.smaregiError ?? "不明").slice(0, 200)}）\nスマレジの管理画面から${del ? "消して" : "直して"}ください（管理システム側は${del ? "削除" : "反映"}済み）`;
  if (v.smaregi === "skipped") return v.test ? "スマレジ：テストのため反映していません" : "スマレジ：反映なし（スマレジ側に記録がありません）";
  return del ? "スマレジ：削除中…" : "スマレジ：反映中…";
}
/**
 * スレッドの 1 通目「詳細と操作のカード」。状態ごとに、いま押せるボタンだけを出す。
 *   open           … 問題の内容と打刻 ＋［○ 合っている］［✏️ 修正する］［🗑 打刻を消す］（承認ボタンは出さない）
 *   fix_requested  … 修正内容（変わった項目だけ）・理由・申請者 ＋［✅ 承認］［❌ 却下］
 *   それ以外       … 結果だけ（ボタンなし）
 */
export function cardMessage(v: AlertView, o: { notificationId: string }): { text: string; blocks: unknown[] } {
  const d = dateLabel(v.workDate);
  const title = `【勤怠確認｜${KIND_LABEL[v.kind] ?? "確認"}】`;
  const head = [`*${title}*`, `店舗：${clean(v.storeName, 30)}`, `対象者：${clean(v.userName, 30)}`, `対象日：${d.mdw}`];
  const isDel = v.requestKind === "delete";
  const val = JSON.stringify({ alert_id: v.alertId, notification_id: o.notificationId });
  const requested = v.status === "fix_requested" || v.status === "approved" || v.status === "rejected";
  const lines: string[] = [...head];
  if (!requested) {
    lines.push(`打刻：${punchLine(v.detected, v.workDate)}`);
    for (const r of v.reasons ?? []) lines.push(`⚠️ ${String(r).slice(0, 80)}`);
  } else {
    lines.push("", "*【修正内容】*");
    if (isDel) lines.push("打刻の削除（この日の勤務を取り消す）");
    else {
      const diff = diffLines(v.before ?? v.detected, v.proposed, v.workDate);
      lines.push(...(diff.length ? diff : ["（変更なし）"]));
    }
    lines.push("", `理由：${String(v.fixReason ?? "—").slice(0, 300)}`, `申請：${clean(v.requestedByName, 20)}${v.requestedAt ? `（${whenJst(v.requestedAt)}）` : ""}`);
  }
  const blocks: unknown[] = [];
  const push = () => blocks.push({ type: "section", text: { type: "mrkdwn", text: lines.join("\n") } });
  if (v.status === "open") {
    push();
    blocks.push({ type: "actions", block_id: "attendance", elements: [
      { type: "button", style: "primary", text: { type: "plain_text", text: "○ 合っている", emoji: true }, action_id: "attendance.alert.confirm", value: val },
      alertFixButton({ alertId: v.alertId, notificationId: o.notificationId, title: `${d.mdw}　${clean(v.storeName, 30)}　${clean(v.userName, 30)}` }),
      { type: "button", style: "danger", text: { type: "plain_text", text: "🗑 打刻を消す", emoji: true }, action_id: "attendance.alert.delete", value: JSON.stringify({ alert_id: v.alertId, notification_id: o.notificationId, title: `${d.mdw}　${clean(v.storeName, 30)}　${clean(v.userName, 30)}` }) },
    ] });
  } else if (v.status === "fix_requested") {
    lines.push("状況：🟡 承認待ち");
    push();
    blocks.push({ type: "actions", block_id: "attendance_fix", elements: [
      { type: "button", style: isDel ? "danger" : "primary", text: { type: "plain_text", text: isDel ? "✅ 承認して削除" : "✅ 承認", emoji: true }, action_id: "attendance.fix.approve", value: val },
      { type: "button", ...(isDel ? {} : { style: "danger" }), text: { type: "plain_text", text: "❌ 却下", emoji: true }, action_id: "attendance.fix.reject", value: val },
    ] });
  } else {
    const who = (name: string | null, at: string | null) => `${clean(name, 20)}${at ? `・${whenJst(at)}` : ""}`;
    if (v.status === "confirmed") lines.push(`状況：✅ 合っている（${who(v.confirmedByName, v.confirmedAt)}）`);
    else if (v.status === "approved") lines.push(`状況：✅ 承認（${who(v.decidedByName, v.decidedAt)}）`, smaregiLine(v));
    else if (v.status === "rejected") lines.push(`状況：❌ 却下（${who(v.decidedByName, v.decidedAt)}）${v.decisionNote ? `　${String(v.decisionNote).slice(0, 200)}` : ""}`);
    else lines.push("状況：取り消し");
    push();
  }
  return { text: `${title}${clean(v.userName, 30)} ${d.md}`, blocks };
}

const mention = (ids: (string | null | undefined)[]) => [...new Set(ids.filter((x): x is string => /^[UW][A-Z0-9]{6,}$/.test(String(x ?? ""))))].map((x) => `<@${x}>`).join(" ");
/** 承認の依頼（スレッドへの返信。承認できる人にメンション） */
export function approvalAskText(slackIds: (string | null | undefined)[], isDelete: boolean): string {
  const who = mention(slackIds);
  return `${who ? who + "　" : ""}${isDelete ? "打刻の削除" : "修正"}の申請があります。上の内容を確認して、［承認］か［却下］を押してください。`;
}
/** リマインド（スレッドへの返信。親メッセージは増やさない） */
export function reminderText(slackIds: (string | null | undefined)[], o: { n: number; age: string; approval: boolean }): string {
  const who = mention(slackIds);
  return `${who ? who + "　" : ""}⏰ リマインド（${o.n}回目）　${o.approval ? `申請が承認待ちのままです（${o.age}）。上の内容を確認して、［承認］か［却下］を押してください。` : `まだ確認されていません（${o.age}）。上の［○ 合っている］か［✏️ 修正する］を押してください。`}`;
}

// ---- 2. 読んで・組み立てて・送る ---------------------------------------------------
// deno-lint-ignore no-explicit-any
type Sb = any;
export type Notify = (body: Record<string, unknown>) => Promise<{ ok?: boolean; notification_id?: string; ts?: string; slack_channel_id?: string; error?: string } | null>;
export type CaseRefs = { parent?: string; card?: string; ts?: string; channel_key?: string; permalink?: string | null; test?: boolean; before?: Times | null; before_key?: string | null };

/** 新しい形のアラートなら控えを返す。古い形（控えなし）は null */
export async function alertCase(sb: Sb, alertId: unknown): Promise<CaseRefs | null> {
  if (typeof alertId !== "string" || !/^[0-9a-f-]{36}$/i.test(alertId)) return null;
  const { data } = await sb.from("notice_cases").select("slack_refs").eq("type_key", NOTICE_TYPE).eq("ref_table", REF_TABLE).eq("ref_id", alertId).maybeSingle();
  const refs = (data?.slack_refs ?? null) as CaseRefs | null;
  return refs && refs.parent && refs.card ? refs : null;
}
async function caseUpsert(sb: Sb, alertId: string, patch: Record<string, unknown>) {
  const { error } = await sb.rpc("notice_case_upsert", { p_type: NOTICE_TYPE, p_ref_table: REF_TABLE, p_ref_id: alertId, p_patch: patch });
  return error ? String(error.message ?? error) : null;
}
const TIME_COLS = "clock_in,clock_out,break_start_1,break_end_1,break_start_2,break_end_2";
const pickTimes = (r: Record<string, unknown> | null | undefined, prefix = ""): Times => ({
  clock_in: (r?.[prefix + "clock_in"] ?? null) as string | null, clock_out: (r?.[prefix + "clock_out"] ?? null) as string | null,
  break_start_1: (r?.[prefix + "break_start_1"] ?? null) as string | null, break_end_1: (r?.[prefix + "break_end_1"] ?? null) as string | null,
  break_start_2: (r?.[prefix + "break_start_2"] ?? null) as string | null, break_end_2: (r?.[prefix + "break_end_2"] ?? null) as string | null,
});

/**
 * アラートのいまの状態を読んで、親メッセージとカードを書き換える（新しい形のアラートだけ。古い形は { v2:false } を返して何もしない）。
 * 状態（status・スマレジ反映の結果）は DB のものをそのまま出す。ここでは状態を変えない。
 */
export async function renderAlert(sb: Sb, notify: Notify, alertId: string): Promise<{ v2: boolean; ok?: boolean; error?: string }> {
  const refs = await alertCase(sb, alertId);
  if (!refs) return { v2: false };
  const { data: a } = await sb.from(REF_TABLE).select(`id,status,request_kind,kind,reasons,user_id,store_id,work_date,labor_cost_daily_id,${TIME_COLS},proposed_clock_in,proposed_clock_out,proposed_break_start_1,proposed_break_end_1,proposed_break_start_2,proposed_break_end_2,fix_reason,requested_by,requested_at,confirmed_by,confirmed_at,decided_by,decided_at,decision_note,smaregi_sync_status,smaregi_error`).eq("id", alertId).maybeSingle();
  if (!a) return { v2: true, ok: false, error: "alert not found" };
  const ids = [...new Set([a.user_id, a.requested_by, a.confirmed_by, a.decided_by].filter(Boolean))];
  const [{ data: us }, { data: st }] = await Promise.all([
    sb.from("users").select("id,name").in("id", ids),
    sb.from("stores").select("name").eq("id", a.store_id).maybeSingle(),
  ]);
  const nameOf = (id: string | null) => (us ?? []).find((u: { id: string; name: string }) => u.id === id)?.name ?? null;
  // 差分の左側（申請の時点の打刻）: 申請ごとに 1 回だけ、勤怠実績の今の値を控える（承認すると勤怠実績が書き換わるため）
  let before = refs.before ?? null;
  const patch: Record<string, unknown> = {};
  if (a.status === "fix_requested" && a.request_kind !== "delete" && refs.before_key !== a.requested_at) {
    const { data: l } = a.labor_cost_daily_id ? await sb.from("labor_cost_daily").select(TIME_COLS).eq("id", a.labor_cost_daily_id).maybeSingle() : { data: null };
    before = l ? pickTimes(l) : pickTimes(a);
    patch.slack_refs = { before, before_key: a.requested_at };
  }
  const v: AlertView = {
    alertId: a.id, status: a.status, requestKind: a.request_kind ?? "fix", kind: a.kind, reasons: a.reasons ?? [],
    workDate: String(a.work_date).slice(0, 10), storeName: st?.name ?? null, userName: nameOf(a.user_id),
    detected: pickTimes(a), before, proposed: pickTimes(a, "proposed_"),
    fixReason: a.fix_reason ?? null, requestedByName: nameOf(a.requested_by), requestedAt: a.requested_at ?? null,
    confirmedByName: nameOf(a.confirmed_by), confirmedAt: a.confirmed_at ?? null,
    decidedByName: nameOf(a.decided_by), decidedAt: a.decided_at ?? null, decisionNote: a.decision_note ?? null,
    smaregi: a.smaregi_sync_status ?? null, smaregiError: a.smaregi_error ?? null, test: refs.test === true,
  };
  const p = parentMessage(v, { permalink: refs.permalink ?? null });
  const c = cardMessage(v, { notificationId: refs.card! });
  const [r1, r2] = await Promise.all([
    notify({ action: "update", notification_id: refs.parent, text: p.text, blocks: p.blocks }),
    notify({ action: "update", notification_id: refs.card, text: c.text, blocks: c.blocks }),
  ]);
  patch.status_code = parentState(v).code;
  await caseUpsert(sb, alertId, patch);
  const ok = !!(r1?.ok && r2?.ok);
  return { v2: true, ok, ...(ok ? {} : { error: String(r1?.error ?? r2?.error ?? "update_failed") }) };
}

/** 承認できる人（マスター）の Slack ID */
async function masterSlackIds(sb: Sb): Promise<string[]> {
  const { data: masters } = await sb.from("users").select("id").eq("is_master", true).eq("is_active", true);
  const ids = (masters ?? []).map((m: { id: string }) => m.id);
  if (!ids.length) return [];
  const { data: linked } = await sb.from("user_slack").select("slack_user_id").in("user_id", ids);
  return (linked ?? []).map((r: { slack_user_id: string }) => r.slack_user_id).filter(Boolean);
}
async function threadReply(notify: Notify, refs: CaseRefs, alertId: string, o: { text: string; event: string; source: string; dedupe: string }) {
  return await notify({ action: "send", channel_key: refs.channel_key, thread_ts: refs.ts, text: o.text, event: o.event, source: o.source, dedupe_key: o.dedupe,
    ref: { table: REF_TABLE, id: alertId }, username: USERNAME, icon_emoji: ICON });
}

/**
 * 修正・打刻削除が申請されたあと: カードを「修正内容＋承認・却下」に書き換え、承認できる人へスレッドで知らせる。
 * 新しい形のアラートなら true（古い形は false ＝ 呼び出し側が今までの処理をする）。
 */
export async function afterRequest(sb: Sb, notify: Notify, alertId: string, source: string): Promise<{ v2: boolean; approvers: number }> {
  const refs = await alertCase(sb, alertId);
  if (!refs) return { v2: false, approvers: 0 };
  await renderAlert(sb, notify, alertId);
  const { data: a } = await sb.from(REF_TABLE).select("request_kind,requested_at").eq("id", alertId).maybeSingle();
  const ids = await masterSlackIds(sb);
  await threadReply(notify, refs, alertId, { text: approvalAskText(ids, a?.request_kind === "delete"), event: "attendance_fix_request", source, dedupe: `attendance_fix_v2:${alertId}:${a?.requested_at ?? ""}` });
  return { v2: true, approvers: ids.length };
}

/**
 * 承認・却下のあと: カードと親を書き換える。承認のときはスマレジへ反映し（テスト用のアラートは反映しない）、結果でもう一度書き換える。
 * 新しい形のアラートなら true。
 */
export async function afterDecide(sb: Sb, notify: Notify, alertId: string, approve: boolean, smaregiFix: (alertId: string) => Promise<{ ok: boolean; error?: string }>): Promise<boolean> {
  const refs = await alertCase(sb, alertId);
  if (!refs) return false;
  if (!approve) { await renderAlert(sb, notify, alertId); return true; }
  if (refs.test === true) {
    // テスト用（本物の従業員ではない・スマレジに勤務が無い）: スマレジには何も送らない
    await sb.from(REF_TABLE).update({ smaregi_sync_status: "skipped", smaregi_error: null, updated_at: new Date().toISOString() }).eq("id", alertId);
    await renderAlert(sb, notify, alertId);
    return true;
  }
  await renderAlert(sb, notify, alertId);          // 「反映中…」
  await smaregiFix(alertId);                        // 結果は sf_attendance_alerts.smaregi_sync_status / smaregi_error に入る
  await renderAlert(sb, notify, alertId);          // 「反映済み」または「失敗」
  return true;
}

function ageText(sinceIso: string): string {
  const h = Math.max(0, Math.floor((Date.now() - new Date(sinceIso).getTime()) / 3600000));
  if (h < 24) return `${h}時間`;
  const d = Math.floor(h / 24);
  return h % 24 ? `${d}日${h % 24}時間` : `${d}日`;
}
/**
 * リマインドをスレッドへの返信で出す（親メッセージは増やさない）。メンション先: 未確認＝対象店舗の社員・店長＋担当チーム長（notice_mention_rules）、
 * 承認待ち＝承認できる人。テスト用のアラートは承認できる人だけ。新しい形のアラートでなければ { v2:false }。
 */
export async function remindInThread(sb: Sb, notify: Notify, o: { alertId: string; approval: boolean; n: number; since: string; dryRun?: boolean }): Promise<{ v2: boolean; ok?: boolean; mentions?: number; error?: string }> {
  const refs = await alertCase(sb, o.alertId);
  if (!refs) return { v2: false };
  let ids: string[] = [];
  if (o.approval || refs.test === true) ids = await masterSlackIds(sb);
  else {
    const { data: a } = await sb.from(REF_TABLE).select("store_id").eq("id", o.alertId).maybeSingle();
    const { data: t } = await sb.rpc("notice_mention_targets", { p_type: NOTICE_TYPE, p_scene: "open", p_store: a?.store_id ?? null, p_task_assignees: null });
    ids = ((t?.targets ?? []) as { slack_user_id?: string }[]).map((x) => String(x.slack_user_id ?? "")).filter(Boolean);
  }
  if (o.dryRun) return { v2: true, ok: true, mentions: ids.length };
  const r = await threadReply(notify, refs, o.alertId, { text: reminderText(ids, { n: o.n, age: ageText(o.since), approval: o.approval }), event: "reminder", source: "ef:pending-reminders", dedupe: `remind:${REF_TABLE}:${o.alertId}:${o.n}` });
  return { v2: true, ok: !!r?.ok, mentions: ids.length, ...(r?.ok ? {} : { error: String(r?.error ?? "send_failed") }) };
}

/**
 * 新しい形で勤怠確認を出す: 親（1 行）→ スレッドにカード →（取れたら）親に「詳細を確認」ボタン → 控えを残す。
 * a は anomaly-check が作る 1 件ぶん（アラート行は作成済み）。
 */
export async function postAlert(sb: Sb, notify: Notify, a: {
  alertId: string; userId: string; storeId: string; workDate: string; userName: string; storeName: string; kind: string; reasons: string[]; times: Times;
}, o: { channelKey: string; test?: boolean; detailButton?: boolean; slackToken?: string | null; source: string }): Promise<{ alert_id: string; ok: boolean; format: "v2"; error?: string; permalink?: boolean }> {
  const v: AlertView = {
    alertId: a.alertId, status: "open", requestKind: "fix", kind: a.kind, reasons: a.reasons, workDate: a.workDate, storeName: a.storeName, userName: a.userName,
    detected: a.times, before: null, proposed: {}, fixReason: null, requestedByName: null, requestedAt: null, confirmedByName: null, confirmedAt: null,
    decidedByName: null, decidedAt: null, decisionNote: null, smaregi: null, smaregiError: null, test: o.test === true,
  };
  const ref = { table: REF_TABLE, id: a.alertId };
  const p = parentMessage(v);
  const r1 = await notify({ action: "send", notification_id: crypto.randomUUID(), channel_key: o.channelKey, text: p.text, blocks: p.blocks, event: "attendance_alert", source: o.source,
    dedupe_key: `attendance_alert:${a.alertId}:${o.channelKey}`, ref, username: USERNAME, icon_emoji: ICON });
  if (!r1?.ok || !r1.notification_id || !r1.ts) return { alert_id: a.alertId, ok: false, format: "v2", error: String(r1?.error ?? "parent_send_failed") };
  const cardId = crypto.randomUUID();
  const c = cardMessage(v, { notificationId: cardId });
  const sendCard = () => notify({ action: "send", notification_id: cardId, channel_key: o.channelKey, thread_ts: r1.ts, text: c.text, blocks: c.blocks, event: "attendance_alert_card", source: o.source,
    dedupe_key: `attendance_alert_card:${a.alertId}`, ref, username: USERNAME, icon_emoji: ICON });
  let r2 = await sendCard();
  if (!r2?.ok) r2 = await sendCard();
  if (!r2?.ok || !r2.notification_id) return { alert_id: a.alertId, ok: false, format: "v2", error: "card_send_failed: " + String(r2?.error ?? "") };
  // 「詳細を確認」: スレッドの 1 通目（カード）へのリンク。取れなければボタンなし（Slack 標準の「○件の返信」から開ける）
  let permalink: string | null = null;
  if (o.detailButton !== false && o.slackToken && r1.slack_channel_id && r2.ts) {
    try {
      const res = await fetch(`https://slack.com/api/chat.getPermalink?channel=${encodeURIComponent(r1.slack_channel_id)}&message_ts=${encodeURIComponent(r2.ts)}`, { headers: { Authorization: `Bearer ${o.slackToken}` } });
      const j = await res.json();
      if (j?.ok && typeof j.permalink === "string" && j.permalink.startsWith("https://")) permalink = j.permalink;
    } catch (_e) { /* ボタンなしで続ける */ }
  }
  const refs: CaseRefs = { parent: r1.notification_id, card: r2.notification_id, ts: r1.ts, channel_key: o.channelKey, permalink, test: o.test === true };
  const err = await caseUpsert(sb, a.alertId, { subject_user: a.userId, store_id: a.storeId, subject_date: a.workDate, status_code: "todo", slack_refs: refs });
  if (err) return { alert_id: a.alertId, ok: false, format: "v2", error: "case: " + err };
  if (permalink) { const p2 = parentMessage(v, { permalink }); await notify({ action: "update", notification_id: refs.parent, text: p2.text, blocks: p2.blocks }); }
  await sb.from(REF_TABLE).update({ notification_ids: [refs.parent], updated_at: new Date().toISOString() }).eq("id", a.alertId);
  return { alert_id: a.alertId, ok: true, format: "v2", permalink: !!permalink };
}
