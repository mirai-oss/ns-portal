// =============================================================
// 勤怠の追加・修正申請（フォーム申請＝sf_attendance_requests）の Slack 通知「親 1 行＋スレッド」（2026-11-15・社長の指示）
//   親メッセージ = 1 行だけ（状態の印・「勤怠修正」・氏名・日付・いまの承認状況）＋「詳細を確認」。申請 1 件に親は 1 つ（同じ申請で親を作り直さない）。
//   スレッド     = 1 通目に「修正前 → 修正後のカード」（状態が変わるたびに同じカードを書き換える＝古いボタンが残らない）。
//                  承認の依頼・結果・スマレジの反映結果・リマインドは、スレッドへの返信（ここでだけメンション）。
//   切り替え: app_settings.attendance_request_flow.thread が true のときだけ、新しい申請をこの形で出す（false・設定なし＝今までどおり）。
//   どの申請が新しい形かは、案件の控え notice_cases（type_key=attendance_request）に parent と card の控えがあるかで決まる。
//   控えの無い申請（今までの形）は、各 Edge Function の今までの処理がそのまま動く。
//
//   前半は「文面を組み立てるだけ」（DB にも Slack にも触らない＝単体でテストできる）。
//   後半は「読んで・組み立てて・送る」処理（sb と notify を外から受け取る）。
//   状態（status・stage・スマレジの結果）は DB のものをそのまま出す。ここでは状態を変えない。
//   2 段階承認（第 2 弾）の状態とボタンの形も、ここに入れてある（列 flow / stage が無いあいだは、今までの 1 段階の形だけが出る）。
// =============================================================
import { hm, dateLabel, whenJst, renderAlert, type Times, type Notify } from "./attendance-alert-notice.ts";
import { ATTENDANCE_FORM_URL } from "./attendance-fix-notify.ts";

export const REQ_NOTICE_TYPE = "attendance_request";
export const REQ_REF_TABLE = "sf_attendance_requests";
export const REQ_CHANNEL = "kintai.check";
const USERNAME = "勤怠確認", ICON = ":alarm_clock:";
const clean = (s: unknown, max = 40) => String(s ?? "").replace(/[\n\r|｜<>]/g, " ").trim().slice(0, max) || "—";
const cut = (s: unknown, max = 300) => String(s ?? "").replace(/[<>]/g, " ").trim().slice(0, max);

// ---- 0. スイッチ -------------------------------------------------------------------
export type FlowSettings = { thread: boolean; twoStage: boolean; presidentDm: boolean };
/** app_settings.attendance_request_flow の値を読む。true とはっきり書いてあるときだけ ON（文字の "true" や 1 は OFF 扱い） */
export function parseFlow(value: unknown): FlowSettings {
  const v = (value && typeof value === "object" ? value : {}) as Record<string, unknown>;
  const thread = v.thread === true;
  return { thread, twoStage: thread && v.two_stage === true, presidentDm: v.president_dm !== false };
}

// ---- 1. 修正前 → 修正後の比較（純粋な関数） -------------------------------------------
const ms = (v: string | null | undefined) => { if (!v) return null; const t = new Date(v).getTime(); return Number.isFinite(t) ? Math.floor(t / 60000) : null; };
/** 分 → 「6時間00分」「45分」 */
export function durText(min: number): string {
  const m = Math.abs(Math.round(min)); const h = Math.floor(m / 60);
  return h ? `${h}時間${String(m % 60).padStart(2, "0")}分` : `${m}分`;
}
/** 勤務（退勤−出勤）・休憩・実働（分）。出勤か退勤が無ければ work は null */
export function minutesOf(t: Times | null | undefined): { span: number | null; breaks: number; work: number | null } {
  const a = ms(t?.clock_in), b = ms(t?.clock_out);
  const pair = (s: string | null | undefined, e: string | null | undefined) => { const x = ms(s), y = ms(e); return x !== null && y !== null && y > x ? y - x : 0; };
  const breaks = pair(t?.break_start_1, t?.break_end_1) + pair(t?.break_start_2, t?.break_end_2);
  const span = a !== null && b !== null && b > a ? b - a : null;
  return { span, breaks, work: span === null ? null : Math.max(0, span - breaks) };
}
const breakList = (t: Times | null | undefined, wd: string): string[] =>
  [[t?.break_start_1, t?.break_end_1], [t?.break_start_2, t?.break_end_2]].filter(([s]) => !!s).map(([s, e]) => `${hm(s, wd)}−${e ? hm(e, wd) : "終了なし"}`);
const NUM = ["①", "②"];
const breakDetail = (list: string[]) => (list.length > 1 ? list.map((x, i) => `${NUM[i]}${x}`).join(" ") : list[0] ?? "");

export type CompareRow = { key: "in" | "out" | "break" | "work"; label: string; before: string; after: string; changed: boolean; detail: string[] };
export type Compare = { rows: CompareRow[]; delta: string; deltaMinutes: number | null; anyChange: boolean };
/**
 * 修正前と修正後を、出勤・退勤・休憩・実働の 4 行で比べる（分の単位）。before が null＝打刻なし（勤怠追加）。
 * 打刻が無い所は「未打刻」。休憩は合計の分数。内訳（detail）は、休憩が変わったときと、休憩が 2 回あるときに出す。
 */
export function compareTimes(before: Times | null | undefined, after: Times, workDate: string): Compare {
  const b = before ?? {};
  const t = (v: string | null | undefined) => hm(v, workDate) ?? "未打刻";
  const mb = minutesOf(before), ma = minutesOf(after);
  const lb = breakList(before, workDate), la = breakList(after, workDate);
  const breakChanged = ms(b.break_start_1) !== ms(after.break_start_1) || ms(b.break_end_1) !== ms(after.break_end_1) || ms(b.break_start_2) !== ms(after.break_start_2) || ms(b.break_end_2) !== ms(after.break_end_2);
  const detail: string[] = [];
  if (breakChanged) { if (lb.length) detail.push(`修正前 ${breakDetail(lb)}`); if (la.length) detail.push(`修正後 ${breakDetail(la)}`); }
  else if (la.length > 1) detail.push(breakDetail(la));
  const bt = (n: number, list: string[]) => (list.length ? `${n}分` : "なし");
  const wt = (n: number | null) => (n === null ? "—" : durText(n));
  const rows: CompareRow[] = [
    { key: "in", label: "出勤", before: t(b.clock_in), after: t(after.clock_in), changed: ms(b.clock_in) !== ms(after.clock_in), detail: [] },
    { key: "out", label: "退勤", before: t(b.clock_out), after: t(after.clock_out), changed: ms(b.clock_out) !== ms(after.clock_out), detail: [] },
    { key: "break", label: "休憩", before: bt(mb.breaks, lb), after: bt(ma.breaks, la), changed: breakChanged, detail },
    { key: "work", label: "実働", before: wt(mb.work), after: wt(ma.work), changed: mb.work !== ma.work, detail: [] },
  ];
  const dm = mb.work !== null && ma.work !== null ? ma.work - mb.work : null;
  const delta = dm === null ? (mb.work === null && ma.work !== null ? "—（修正前が未打刻）" : "—") : dm === 0 ? "±0分" : `${dm > 0 ? "+" : "−"}${durText(dm)}`;
  return { rows, delta, deltaMinutes: dm, anyChange: rows.some((r) => r.changed) };
}
/** カードに出す行。変わった行は 🔸 と太字、変わらない行は「（変更なし）」で短く。1 行を短くして、スマートフォンでも折り返しにくくする */
export function compareLines(c: Compare): string[] {
  const out: string[] = [];
  for (const r of c.rows) {
    out.push(r.changed ? `🔸 *${r.label}：${r.before} → ${r.after}*` : `${r.label}：${r.after}（変更なし）`);
    for (const d of r.detail) out.push(`　└ ${d}`);
  }
  out.push(`実働の増減：${c.delta}`);
  return out;
}

/** 出勤取消（2026-11-19）: 取り消す勤務の中身（出勤・退勤・休憩）。申請の時点の控え（before）から。 */
export function deleteLines(before: Times | null | undefined, workDate: string): string[] {
  const c = compareTimes(before ?? null, (before ?? { clock_in: null, clock_out: null }) as Times, workDate);
  const out: string[] = [];
  for (const r of c.rows) out.push(`${r.label}：${r.after}`);
  return out.length ? out : ["（元の勤務の記録が読めません）"];
}

// ---- 2. 状態（社長の指示の言葉） -------------------------------------------------------
export type ReqStateCode = "pending" | "first_wait" | "asking" | "returned" | "final_wait" | "hold" | "sync_wait" | "synced" | "sync_error" | "rejected" | "cancelled";
export type ReqState = { code: ReqStateCode; label: string; mark: string; done: boolean; notice: "todo" | "waiting" | "done" | "alert" };
const STAGE_LABEL: Record<string, string> = { first_wait: "一次承認待ち", asking: "本人確認中", returned: "差戻し", final_wait: "最終承認待ち", hold: "確認待ち（一次承認者が未設定）" };
export function requestState(v: { status: string; flow?: string | null; stage?: string | null; smaregi?: string | null }): ReqState {
  if (v.status === "pending") {
    if (v.flow === "two_stage" && v.stage && STAGE_LABEL[v.stage]) {
      const hold = v.stage === "hold";
      return { code: v.stage as ReqStateCode, label: STAGE_LABEL[v.stage], mark: hold ? "🕒" : "📝", done: false, notice: hold ? "todo" : "waiting" };
    }
    return { code: "pending", label: "承認待ち", mark: "📝", done: false, notice: "waiting" };
  }
  if (v.status === "approved") {
    if (v.smaregi === "failed") return { code: "sync_error", label: "同期エラー", mark: "🔴", done: false, notice: "alert" };
    if (v.smaregi === "synced" || v.smaregi === "skipped") return { code: "synced", label: "同期済み", mark: "✅", done: true, notice: "done" };
    return { code: "sync_wait", label: "承認済み・スマレジ反映待ち", mark: "📝", done: false, notice: "waiting" };
  }
  if (v.status === "rejected") return { code: "rejected", label: "却下", mark: "✅", done: true, notice: "done" };
  return { code: "cancelled", label: "取り消し", mark: "✅", done: true, notice: "done" };
}

// ---- 3. 表示用の中身 -------------------------------------------------------------------
export type Person = { user_id: string; slack_user_id: string | null };
export type RequestView = {
  requestId: string; kind: "add" | "fix" | "delete"; status: string; flow: string | null; stage: string | null; round: number;
  workDate: string; storeId: string | null; storeName: string | null;
  userId: string; userName: string | null; requestedBy: string | null; requestedByName: string | null; requestedAt: string | null; reason: string | null;
  before: Times | null; after: Times;
  firstApproverId: string | null; firstApproverName: string | null; firstSkipped: boolean; firstDecidedByName: string | null; firstDecidedAt: string | null;
  returnNote: string | null; returnedByName: string | null; returnedAt: string | null;
  decidedByName: string | null; decidedAt: string | null; decisionNote: string | null;
  smaregi: string | null; smaregiError: string | null;
  source: "same" | "changed" | "gone" | "appeared" | "na";
  slack: Record<string, string>;      // 従業員 id → Slack のユーザー ID（出てくる人だけ）
  masters: Person[]; presidents: Person[];
};
const TIME_KEYS = ["clock_in", "clock_out", "break_start_1", "break_end_1", "break_start_2", "break_end_2"] as const;
// deno-lint-ignore no-explicit-any
const pick = (r: any): Times => Object.fromEntries(TIME_KEYS.map((k) => [k, (r?.[k] ?? null) as string | null])) as Times;
const str = (v: unknown): string | null => (typeof v === "string" && v ? v : null);
/** RPC sf_attendance_request_view の結果 → 表示用の中身。読めなければ null */
// deno-lint-ignore no-explicit-any
export function viewFromRpc(j: any): RequestView | null {
  const r = j?.request;
  if (!r || typeof r.id !== "string") return null;
  const names = (j.names ?? {}) as Record<string, string>;
  const nm = (id: unknown) => (typeof id === "string" && names[id] ? names[id] : null);
  const people = (a: unknown): Person[] => (Array.isArray(a) ? a : []).filter((x) => x && typeof x.user_id === "string").map((x) => ({ user_id: x.user_id, slack_user_id: str(x.slack_user_id) }));
  const src = String(j.source?.state ?? "na");
  return {
    requestId: r.id, kind: r.kind === "add" ? "add" : r.kind === "delete" ? "delete" : "fix", status: String(r.status ?? ""), flow: str(r.flow), stage: str(r.stage), round: Number(r.round ?? 1) || 1,
    workDate: String(r.work_date ?? "").slice(0, 10), storeId: str(r.store_id), storeName: str(j.store_name),
    userId: String(r.user_id ?? ""), userName: nm(r.user_id), requestedBy: str(r.requested_by), requestedByName: nm(r.requested_by), requestedAt: str(r.requested_at), reason: str(r.reason),
    before: (r.kind === "fix" || r.kind === "delete") && r.before ? pick(r.before) : null, after: pick(r),
    firstApproverId: str(r.first_approver_id), firstApproverName: nm(r.first_approver_id), firstSkipped: r.first_skipped === true,
    firstDecidedByName: nm(r.first_decided_by), firstDecidedAt: str(r.first_decided_at),
    returnNote: str(r.return_note), returnedByName: nm(r.returned_by), returnedAt: str(r.returned_at),
    decidedByName: nm(r.decided_by), decidedAt: str(r.decided_at), decisionNote: str(r.decision_note),
    smaregi: str(r.smaregi_sync_status), smaregiError: str(r.smaregi_error),
    source: (["same", "changed", "gone", "appeared"].includes(src) ? src : "na") as RequestView["source"],
    slack: (j.slack ?? {}) as Record<string, string>, masters: people(j.masters), presidents: people(j.presidents),
  };
}
export const kindLabel = (kind: string) => (kind === "add" ? "勤怠追加" : kind === "delete" ? "出勤取消" : "勤怠修正");
/** 管理システムの承認画面（勤怠フォームの ?req=）。差戻しの出し直しも、ここから */
export const requestFormUrl = (requestId: string) => `${ATTENDANCE_FORM_URL}?req=${encodeURIComponent(requestId)}`;

// ---- 4. 親メッセージ（1 行） -----------------------------------------------------------
/** 例: 📝 勤怠修正｜山田太郎｜11/14｜一次承認待ち。時刻・理由・承認のボタンは出さない。「詳細を確認」は完了したら外す */
export function requestParent(v: RequestView, o: { permalink?: string | null } = {}): { text: string; blocks: unknown[] } {
  const st = requestState(v);
  const text = `${st.mark} ${kindLabel(v.kind)}｜${clean(v.userName, 30)}｜${v.storeName ? `${clean(v.storeName, 20)}｜` : ""}${dateLabel(v.workDate).md}｜${st.label}`;   // 2026-11-19 どの店舗かも出す
  const blocks: unknown[] = [{ type: "section", text: { type: "mrkdwn", text } }];
  if (o.permalink && !st.done) {
    blocks.push({ type: "actions", block_id: "attendance_req_open", elements: [
      { type: "button", text: { type: "plain_text", text: "詳細を確認", emoji: true }, action_id: "attendance.alert.open", url: o.permalink, value: JSON.stringify({ request_id: v.requestId }) },
    ] });
  }
  return { text, blocks };
}

// ---- 5. スレッドの 1 通目「修正前 → 修正後のカード」 ---------------------------------------
const SOURCE_WARN: Record<string, string> = {
  changed: "⚠️ 申請のあとに、元の打刻が変わっています。このままの内容では反映できません（内容を確かめて、出し直してください）。",
  gone: "⚠️ 申請のあとに、元の勤怠が無くなっています。このままの内容では反映できません。",
  appeared: "⚠️ 申請のあとに、この日の打刻が登録されています。「勤怠修正」で出し直してください。",
};
const btn = (text: string, action_id: string, value: string, style?: "primary" | "danger") =>
  ({ type: "button", ...(style ? { style } : {}), text: { type: "plain_text", text, emoji: true }, action_id, value });
/**
 * 状態ごとに、いま押せるボタンだけを出す。
 *   今までの 1 段階（flow なし）の承認待ち … ［✅ 承認］［❌ 却下］（今あるボタンと同じ action_id＝attendance.request.approve / .reject）
 *   2 段階: 一次承認待ち・本人確認中 … ［✅ 一次承認］［↩️ 差戻し］［❌ 却下］（＋一次承認待ちのときだけ［💬 本人に確認中］）
 *           最終承認待ち … ［✅ 最終承認］［↩️ 差戻し］［❌ 却下］／差戻し … ［✏️ 直して出し直す］／同期エラー … ［🔁 もう一度スマレジへ送る］
 */
export function requestCard(v: RequestView, o: { notificationId: string }): { text: string; blocks: unknown[] } {
  const d = dateLabel(v.workDate), st = requestState(v);
  const title = `【${kindLabel(v.kind)}の申請】`;
  const two = v.flow === "two_stage";
  const lines: string[] = [
    `*${title}*`, `店舗：${clean(v.storeName, 30)}`, `対象：${clean(v.userName, 30)}`, `勤務日：${d.mdw}`,
    `申請：${clean(v.requestedByName, 20)}${v.requestedAt ? `（${whenJst(v.requestedAt)}）` : ""}`, `> *📝 理由：${(cut(v.reason) || "—").replace(/[*_~`>\n]/g, " ")}*`,   // 2026-11-19 理由は目立たせる（引用＋太字）
    "", ...(v.kind === "delete"
      ? ["*🗑 取り消す勤務（この日の勤務の記録を、丸ごと削除します）*", ...deleteLines(v.before, v.workDate)]
      : ["*修正前 → 修正後*", ...compareLines(compareTimes(v.before, v.after, v.workDate))]), "",
  ];
  if (two) lines.push(`一次承認者：${v.firstSkipped ? "省略（一次承認者 本人の申請）" : v.firstApproverId ? clean(v.firstApproverName, 20) : "未設定"}${v.firstDecidedAt ? `（一次承認 ${clean(v.firstDecidedByName, 20)}・${whenJst(v.firstDecidedAt)}）` : ""}`);
  const who = (name: string | null, at: string | null) => `${clean(name, 20)}${at ? `・${whenJst(at)}` : ""}`;
  let status = `状況：${st.done ? st.mark : st.code === "sync_error" ? "🔴" : st.code === "hold" ? "🕒" : "🟡"} ${st.label}`;
  if (st.code === "returned" && (v.returnNote || v.returnedAt)) status += `（${who(v.returnedByName, v.returnedAt)}）${v.returnNote ? `\n差戻しの理由：${cut(v.returnNote, 200)}` : ""}`;
  if (st.code === "rejected") status += `（${who(v.decidedByName, v.decidedAt)}）${v.decisionNote ? `\n却下の理由：${cut(v.decisionNote, 200)}` : ""}`;
  if (v.status === "approved") status += `\n${two ? "最終承認" : "承認"}：${who(v.decidedByName, v.decidedAt)}`;
  if (st.code === "sync_error") status += `\nスマレジ：⚠️ 反映に失敗（${cut(v.smaregiError ?? "不明", 200)}）`;
  if (st.code === "synced") status += v.smaregi === "skipped" ? "\nスマレジ：反映なし" : "\nスマレジ：✅ 反映済み";
  if (st.code === "hold") status += "\nこの店舗の一次承認者が決まるまで、承認へ進みません。";
  lines.push(status);
  if (v.status === "pending" && SOURCE_WARN[v.source]) lines.push(SOURCE_WARN[v.source]);
  const blocks: unknown[] = [{ type: "section", text: { type: "mrkdwn", text: lines.join("\n") } }];
  const val = JSON.stringify({ request_id: v.requestId, notification_id: o.notificationId });
  const open = { type: "button", text: { type: "plain_text", text: "管理システムで開く", emoji: true }, action_id: "attendance.req.open", url: requestFormUrl(v.requestId), value: JSON.stringify({ request_id: v.requestId }) };
  const el: unknown[] = [];
  if (st.code === "pending") el.push(btn("✅ 承認", "attendance.request.approve", val, "primary"), btn("❌ 却下", "attendance.request.reject", val, "danger"));
  else if (st.code === "first_wait" || st.code === "asking") {
    el.push(btn("✅ 一次承認", "attendance.req.first.approve", val, "primary"), btn("↩️ 差戻し", "attendance.req.return", val), btn("❌ 却下", "attendance.req.reject", val, "danger"));
    if (st.code === "first_wait") el.push(btn("💬 本人に確認中", "attendance.req.ask", val));
    el.push(open);
  } else if (st.code === "final_wait") el.push(btn("✅ 最終承認", "attendance.req.final.approve", val, "primary"), btn("↩️ 差戻し", "attendance.req.return", val), btn("❌ 却下", "attendance.req.reject", val, "danger"), open);
  else if (st.code === "returned") el.push({ ...open, text: { type: "plain_text", text: "✏️ 直して出し直す", emoji: true } });
  else if (st.code === "sync_error" && two) el.push(btn("🔁 もう一度スマレジへ送る", "attendance.req.sync.retry", val));
  if (el.length) blocks.push({ type: "actions", block_id: "attendance_request", elements: el });
  return { text: `${title}${clean(v.userName, 30)} ${d.md}`, blocks };
}

// ---- 6. スレッドの行（返信） -------------------------------------------------------------
export const mentionOf = (ids: (string | null | undefined)[]) => [...new Set(ids.filter((x): x is string => /^[UW][A-Z0-9]{6,}$/.test(String(x ?? ""))))].map((x) => `<@${x}>`).join(" ");
/** いまの状態で「次に動く人」。slackIds＝メンション先／userIds＝リンクだけの DM を送る先（社長・今までの承認者だけ） */
export function nextActors(v: RequestView): { slackIds: string[]; dmUserIds: string[]; text: string } {
  const st = requestState(v);
  const ids = (p: Person[]) => p.map((x) => x.slack_user_id).filter((x): x is string => !!x);
  switch (st.code) {
    case "pending": return { slackIds: ids(v.masters), dmUserIds: v.masters.filter((x) => x.slack_user_id).map((x) => x.user_id), text: "承認をお願いします。上のカードの［承認］か［却下］を押してください。" };
    case "first_wait": case "asking": {
      const s = v.firstApproverId ? v.slack[v.firstApproverId] : null;
      return { slackIds: s ? [s] : [], dmUserIds: [], text: s ? "一次承認をお願いします。現場の事実を確かめて、上のカードから操作してください。" : `一次承認者（${clean(v.firstApproverName, 20)}）は Slack と紐付いていないため、ここでは知らせられません。管理システムから操作してください。` };
    }
    case "final_wait": return { slackIds: ids(v.presidents), dmUserIds: v.presidents.filter((x) => x.slack_user_id).map((x) => x.user_id), text: `${v.firstSkipped ? "一次承認者 本人の申請のため、一次承認を省略しました。" : "一次承認が済みました。"}最終承認をお願いします。上のカードの［最終承認］から。` };
    case "returned": { const s = v.requestedBy ? v.slack[v.requestedBy] : null; return { slackIds: s ? [s] : [], dmUserIds: [], text: "差戻しになりました。内容を確かめて、上のカードの［直して出し直す］から出し直してください。" }; }
    case "hold": return { slackIds: ids(v.presidents), dmUserIds: [], text: "この店舗の一次承認者が未設定のため、確認待ちです。一次承認者が決まるまで、承認へ進みません。" };
    case "sync_error": { const s = v.firstApproverId ? v.slack[v.firstApproverId] : null; return { slackIds: s ? [s] : ids(v.masters), dmUserIds: [], text: "スマレジへ反映できませんでした。上のカードの内容を確かめてください。" }; }
    default: return { slackIds: [], dmUserIds: [], text: "" };
  }
}
export function askText(v: RequestView): string {
  const n = nextActors(v); if (!n.text) return "";
  const who = mentionOf(n.slackIds);
  return `${who ? who + "　" : ""}${n.text}`;
}
export type LineKind = "approved" | "first_approved" | "final_approved" | "rejected" | "returned" | "cancelled" | "asked" | "resubmitted" | "source_changed" | "sync_ok" | "sync_skipped" | "sync_failed" | "sync_retry" | "question" | "answer" | "president_self";
/** できごとを 1 行で（だれが・いつ・何を・理由）。ふつうの文章の返信と区別がつくように、先頭に印を付ける */
export function eventLine(kind: LineKind, o: { actor?: string | null; at?: string | null; note?: string | null } = {}): string {
  const who = `（${clean(o.actor, 20)}${o.at ? `・${whenJst(o.at)}` : ""}）`;
  const note = o.note ? `　理由：${cut(o.note, 200)}` : "";
  switch (kind) {
    case "approved": return `✅ 承認${who}→ スマレジへ反映します`;
    case "first_approved": return `✅ 一次承認${who}`;
    case "final_approved": return `✅ 最終承認${who}→ スマレジへ反映します`;
    case "rejected": return `❌ 却下${who}${note}`;
    case "returned": return `↩️ 差戻し${who}${note}`;
    case "cancelled": return `🚫 取り下げ${who}${note}`;
    case "asked": return `💬 本人に確認中${who}`;
    case "resubmitted": return `✏️ 出し直し${who}　上のカードが新しい内容に変わりました。前の承認は取り消して、一次承認からやり直します。`;
    case "source_changed": return "⚠️ 申請のあとに元の打刻が変わったため、差戻しにしました。内容を確かめて、出し直してください。";
    case "sync_ok": return "🔄 スマレジへ反映しました";
    case "sync_skipped": return "スマレジへの反映はありません（スマレジ側に送る物がありません）";
    case "sync_failed": return `🔴 スマレジへ反映できませんでした：${cut(o.note ?? "不明", 200)}`;
    case "sync_retry": return `🔁 スマレジへもう一度送ります${who}`;
    case "question": return `💬 質問${who}：${cut(o.note, 300)}`;
    case "answer": return `💬 回答${who}：${cut(o.note, 300)}`;
    case "president_self": return "✅ 本人（社長）の申請のため、承認を省略して反映しました（記録のみ）→ スマレジへ反映します";
  }
}
/** リマインド（スレッドへの返信。親は増やさない） */
export function requestReminderText(v: RequestView, o: { n: number; age: string }): string {
  const n = nextActors(v); const who = mentionOf(n.slackIds);
  return `${who ? who + "　" : ""}⏰ リマインド（${o.n}回目）　${requestState(v).label}のままです（${o.age}）。${n.text}`;
}
/** 社長・承認者への DM（リンクだけ。ボタンは付けない＝承認する場所はスレッドのカード 1 つだけ） */
export function dmLinkText(v: RequestView, permalink: string | null): string {
  const st = requestState(v);
  return `🙋 ${kindLabel(v.kind)}の${st.code === "final_wait" ? "最終承認" : "承認"}の依頼が届いています（${clean(v.userName, 30)}・${dateLabel(v.workDate).md}）。\n${permalink ? `<${permalink}|スレッドを開く>` : "#勤怠確認 のスレッドを見てください"}（承認・却下は、スレッドのカードから）`;
}

// ---- 7. 読んで・組み立てて・送る ---------------------------------------------------------
// deno-lint-ignore no-explicit-any
type Sb = any;
export type ReqRefs = { parent?: string; card?: string; ts?: string; channel_key?: string; permalink?: string | null };

/** スイッチを読む。読めなければ全部 OFF（＝今までどおり） */
export async function flowSettings(sb: Sb): Promise<FlowSettings> {
  try {
    const { data } = await sb.from("app_settings").select("value").eq("key", "attendance_request_flow").maybeSingle();
    return parseFlow(data?.value);
  } catch (_e) { return parseFlow(null); }
}
/** 新しい形の申請なら控えを返す。今までの形（控えなし）は null */
export async function requestCase(sb: Sb, requestId: unknown): Promise<ReqRefs | null> {
  if (typeof requestId !== "string" || !/^[0-9a-f-]{36}$/i.test(requestId)) return null;
  const { data } = await sb.from("notice_cases").select("slack_refs").eq("type_key", REQ_NOTICE_TYPE).eq("ref_table", REQ_REF_TABLE).eq("ref_id", requestId).maybeSingle();
  const refs = (data?.slack_refs ?? null) as ReqRefs | null;
  return refs && refs.parent && refs.card ? refs : null;
}
export async function loadView(sb: Sb, requestId: string): Promise<RequestView | null> {
  const { data, error } = await sb.rpc("sf_attendance_request_view", { p_request_id: requestId });
  return error ? null : viewFromRpc(data);
}
async function caseUpsert(sb: Sb, requestId: string, patch: Record<string, unknown>): Promise<string | null> {
  const { error } = await sb.rpc("notice_case_upsert", { p_type: REQ_NOTICE_TYPE, p_ref_table: REQ_REF_TABLE, p_ref_id: requestId, p_patch: patch });
  return error ? String(error.message ?? error) : null;
}
/** スレッドへの返信を 1 行。dedupe＝同じ行を 2 回出さないための鍵 */
export async function threadLine(notify: Notify, refs: ReqRefs, requestId: string, o: { text: string; event: string; source: string; dedupe: string }) {
  if (!o.text || !refs.ts || !refs.channel_key) return null;
  return await notify({ action: "send", channel_key: refs.channel_key, thread_ts: refs.ts, text: o.text, event: o.event, source: o.source, dedupe_key: o.dedupe,
    ref: { table: REQ_REF_TABLE, id: requestId }, username: USERNAME, icon_emoji: ICON });
}

/** 申請のいまの状態を読んで、親とカードを書き換える（新しい形の申請だけ。今までの形は { v2:false } を返して何もしない） */
export async function renderRequest(sb: Sb, notify: Notify, requestId: string): Promise<{ v2: boolean; ok?: boolean; view?: RequestView; refs?: ReqRefs; error?: string }> {
  const refs = await requestCase(sb, requestId);
  if (!refs) return { v2: false };
  const v = await loadView(sb, requestId);
  if (!v) return { v2: true, ok: false, refs, error: "request not found" };
  const p = requestParent(v, { permalink: refs.permalink ?? null });
  const c = requestCard(v, { notificationId: refs.card! });
  const [r1, r2] = await Promise.all([
    notify({ action: "update", notification_id: refs.parent, text: p.text, blocks: p.blocks }),
    notify({ action: "update", notification_id: refs.card, text: c.text, blocks: c.blocks }),
  ]);
  const st = requestState(v);
  await caseUpsert(sb, requestId, { status_code: st.notice, status_label: st.label });
  await renderLinkedAlert(sb, notify, requestId).catch(() => {});   // 朝のアラートから出した申請なら、アラートのカードも同じ状態に書き換える
  const ok = !!(r1?.ok && r2?.ok);
  return { v2: true, ok, view: v, refs, ...(ok ? {} : { error: String(r1?.error ?? r2?.error ?? "update_failed") }) };
}
/** 申請の元の勤怠（labor_cost_daily）に朝のアラートがあれば、アラートのカードと親を書き換える（アラートの状態は DB のトリガーが申請に合わせてある。ここでは状態を変えない） */
async function renderLinkedAlert(sb: Sb, notify: Notify, requestId: string) {
  const { data: r } = await sb.from(REQ_REF_TABLE).select("labor_cost_daily_id").eq("id", requestId).maybeSingle();
  if (!r?.labor_cost_daily_id) return;
  const { data: a } = await sb.from("sf_attendance_alerts").select("id").eq("labor_cost_daily_id", r.labor_cost_daily_id).maybeSingle();
  if (a?.id) await renderAlert(sb, notify, a.id);
}

/**
 * 申請を作った直後に、社長が自分の勤怠を申請したときだけ承認を省略する（条件の検査は DB の関数 sf_attendance_request_self_apply。条件に合わなければ何もしない）。
 * 反映できたら true。スマレジへの書き戻しは、afterSelfApply（投稿のあと）で行う。
 */
export async function selfApplyPresident(sb: Sb, requestId: string): Promise<boolean> {
  const { data, error } = await sb.rpc("sf_attendance_request_self_apply", { p_request_id: requestId });
  return !error && data?.applied === true;
}
/**
 * 朝のアラートの「修正する」から 2 段階承認の申請が作られた直後（道A）: 社長の本人申請なら承認を省略 → アラートのカードを「承認の流れへ」に書き換え
 * → #勤怠確認 に申請の親＋カード（承認者へメンション）→ 省略したときはスマレジへ反映。同じ申請を 2 回出さない鍵は postRequest 側（申請 id）。
 */
export async function afterAlertRequest(sb: Sb, notify: Notify, o: { alertId: string; requestId: string; source: string; slackToken?: string | null; smaregiFix: (requestId: string) => Promise<{ ok: boolean; error?: string }> }): Promise<{ ok: boolean; error?: string; mentions?: number; selfApplied: boolean }> {
  const applied = await selfApplyPresident(sb, o.requestId).catch(() => false);
  await renderAlert(sb, notify, o.alertId).catch(() => {});
  const pr = await postRequest(sb, notify, o.requestId, { source: o.source, slackToken: o.slackToken ?? null }).catch((e) => ({ ok: false, error: String(e).slice(0, 200) }));
  if (!pr.ok) return { ok: false, error: pr.error, selfApplied: applied };
  if (applied) await afterSelfApply(sb, notify, o.requestId, { source: o.source, smaregiFix: o.smaregiFix });
  return { ok: true, mentions: (pr as { mentions?: number }).mentions ?? 0, selfApplied: applied };
}
/** 省略して反映したあと: スレッドに記録の行 → スマレジへ反映（札を取れた 1 回だけ）→ 結果の行 */
export async function afterSelfApply(sb: Sb, notify: Notify, requestId: string, o: { source: string; smaregiFix: (requestId: string) => Promise<{ ok: boolean; error?: string }> }): Promise<void> {
  const r = await renderRequest(sb, notify, requestId);
  if (!r.v2 || !r.refs) return;
  await threadLine(notify, r.refs, requestId, { text: eventLine("president_self"), event: "attendance_request_event", source: o.source, dedupe: `attendance_req_ev:${requestId}:president_self` });
  const { data: c } = await sb.rpc("sf_attendance_request_sync_claim", { p_request_id: requestId, p_actor: null });
  if (c?.ok) await syncAndReport(sb, notify, requestId, r.refs, { source: o.source, smaregiFix: o.smaregiFix, key: "sync:self" });
}

/** いま動く人へ、スレッドで知らせる（メンション）。社長・承認者には、リンクだけの DM も送る（設定で止められる）。key＝同じ知らせを 2 回出さない鍵 */
export async function askInThread(sb: Sb, notify: Notify, v: RequestView, refs: ReqRefs, o: { source: string; key: string; dm?: boolean }): Promise<{ mentions: number; dms: number }> {
  const n = nextActors(v);
  const text = askText(v);
  if (text) await threadLine(notify, refs, v.requestId, { text, event: "attendance_request_ask", source: o.source, dedupe: `attendance_req_ask:${v.requestId}:${o.key}` });
  let dms = 0;
  if (o.dm !== false && n.dmUserIds.length && (await flowSettings(sb)).presidentDm) {
    for (const uid of n.dmUserIds) {
      const r = await notify({ action: "send", channel_key: `user:${uid}`, text: dmLinkText(v, refs.permalink ?? null), event: "attendance_request_dm", source: o.source,
        dedupe_key: `attendance_req_dm:${v.requestId}:${o.key}:${uid}`, ref: { table: REQ_REF_TABLE, id: v.requestId }, username: USERNAME, icon_emoji: ICON });
      if (r?.ok) dms++;
    }
  }
  return { mentions: n.slackIds.length, dms };
}

/**
 * 新しい形で申請を出す: 親（1 行）→ スレッドにカード →（取れたら）親に「詳細を確認」→ 控えを残す → いま動く人へスレッドで知らせる。
 * 親の送信には申請 id の鍵を付ける（同じ申請で 2 回呼ばれても、親は 1 つ。2 回目は前の親が返る）。
 */
export async function postRequest(sb: Sb, notify: Notify, requestId: string, o: { source: string; slackToken?: string | null; channelKey?: string }): Promise<{ ok: boolean; error?: string; permalink?: boolean; mentions?: number; dms?: number }> {
  const v = await loadView(sb, requestId);
  if (!v) return { ok: false, error: "request not found" };
  const channelKey = o.channelKey ?? REQ_CHANNEL;
  const ref = { table: REQ_REF_TABLE, id: requestId };
  const p = requestParent(v);
  const r1 = await notify({ action: "send", notification_id: crypto.randomUUID(), channel_key: channelKey, text: p.text, blocks: p.blocks, event: "attendance_request_parent", source: o.source,
    dedupe_key: `attendance_req_parent:${requestId}`, ref, username: USERNAME, icon_emoji: ICON });
  if (!r1?.ok || !r1.notification_id || !r1.ts) return { ok: false, error: String(r1?.error ?? "parent_send_failed") };
  const cardId = crypto.randomUUID();
  const sendCard = () => { const c = requestCard(v, { notificationId: cardId }); return notify({ action: "send", notification_id: cardId, channel_key: channelKey, thread_ts: r1.ts, text: c.text, blocks: c.blocks,
    event: "attendance_request_card", source: o.source, dedupe_key: `attendance_req_card:${requestId}`, ref, username: USERNAME, icon_emoji: ICON }); };
  let r2 = await sendCard();
  if (!r2?.ok) r2 = await sendCard();
  if (!r2?.ok || !r2.notification_id) return { ok: false, error: "card_send_failed: " + String(r2?.error ?? "") };
  let permalink: string | null = null;
  if (o.slackToken && r1.slack_channel_id && r2.ts) {
    try {
      const res = await fetch(`https://slack.com/api/chat.getPermalink?channel=${encodeURIComponent(r1.slack_channel_id)}&message_ts=${encodeURIComponent(r2.ts)}`, { headers: { Authorization: `Bearer ${o.slackToken}` } });
      const j = await res.json();
      if (j?.ok && typeof j.permalink === "string" && j.permalink.startsWith("https://")) permalink = j.permalink;
    } catch (_e) { /* ボタンなしで続ける（Slack 標準の「○件の返信」から開ける） */ }
  }
  const refs: ReqRefs = { parent: r1.notification_id, card: r2.notification_id, ts: r1.ts, channel_key: channelKey, permalink };
  const st = requestState(v);
  const err = await caseUpsert(sb, requestId, { subject_user: v.userId, store_id: v.storeId ?? "", subject_date: v.workDate, status_code: st.notice, status_label: st.label, slack_refs: refs });
  if (err) return { ok: false, error: "case: " + err };
  // カードのボタンの notification_id は、台帳の id（重複で前のカードが返ったときは、その id）に合わせて書き直す。親には「詳細を確認」を付ける
  if (r2.notification_id !== cardId) { const c2 = requestCard(v, { notificationId: r2.notification_id }); await notify({ action: "update", notification_id: r2.notification_id, text: c2.text, blocks: c2.blocks }); }
  if (permalink) { const p2 = requestParent(v, { permalink }); await notify({ action: "update", notification_id: refs.parent, text: p2.text, blocks: p2.blocks }); }
  const a = await askInThread(sb, notify, v, refs, { source: o.source, key: `r${v.round}:${st.code}` });
  return { ok: true, permalink: !!permalink, mentions: a.mentions, dms: a.dms };
}

/**
 * 今までの 1 段階の承認・却下のあと（RPC sf_attendance_request_decide が済んだあと）: スレッドに結果の行 → 親とカードを書き換え。
 * 承認のときはスマレジへ反映し、結果でもう一度書き換えて、結果の行を出す。新しい形の申請なら true（今までの形は false＝呼び出し側が今までの処理をする）。
 */
export async function afterRequestDecide(sb: Sb, notify: Notify, requestId: string, o: { approve: boolean; source: string; smaregiFix: (requestId: string) => Promise<{ ok: boolean; error?: string }> }): Promise<boolean> {
  const first = await renderRequest(sb, notify, requestId);
  if (!first.v2) return false;
  const v = first.view, refs = first.refs!;
  if (!v) return true;
  await threadLine(notify, refs, requestId, { text: eventLine(o.approve ? "approved" : "rejected", { actor: v.decidedByName, at: v.decidedAt, note: v.decisionNote }), event: "attendance_request_decided", source: o.source,
    dedupe: `attendance_req_ev:${requestId}:decided` });
  if (!o.approve) return true;
  await syncAndReport(sb, notify, requestId, refs, { source: o.source, smaregiFix: o.smaregiFix, key: "sync1" });
  return true;
}
/** スマレジへ送る → 親とカードを書き換え → 結果の行をスレッドへ（失敗のときは、担当にメンション） */
export async function syncAndReport(sb: Sb, notify: Notify, requestId: string, refs: ReqRefs, o: { source: string; smaregiFix: (requestId: string) => Promise<{ ok: boolean; error?: string }>; key: string }): Promise<void> {
  await o.smaregiFix(requestId);                      // 結果は sf_attendance_requests.smaregi_sync_status / smaregi_error に入る
  const r = await renderRequest(sb, notify, requestId);
  const v = r.view; if (!v) return;
  const st = requestState(v);
  let text = "";
  if (st.code === "synced") text = eventLine(v.smaregi === "skipped" ? "sync_skipped" : "sync_ok");
  else if (st.code === "sync_error") { const who = mentionOf(nextActors(v).slackIds); text = `${who ? who + "　" : ""}${eventLine("sync_failed", { note: v.smaregiError })}`; }
  if (text) await threadLine(notify, refs, requestId, { text, event: "attendance_request_sync", source: o.source, dedupe: `attendance_req_ev:${requestId}:${o.key}:${st.code}` });
}

function ageText(sinceIso: string): string {
  const h = Math.max(0, Math.floor((Date.now() - new Date(sinceIso).getTime()) / 3600000));
  if (h < 24) return `${h}時間`;
  const d = Math.floor(h / 24);
  return h % 24 ? `${d}日${h % 24}時間` : `${d}日`;
}
/** リマインドをスレッドへの返信で出す（親は増やさない）。新しい形の申請でなければ { v2:false }（＝呼び出し側が今までの再送をする） */
export async function remindRequestInThread(sb: Sb, notify: Notify, o: { requestId: string; n: number; since: string; dryRun?: boolean }): Promise<{ v2: boolean; ok?: boolean; mentions?: number; error?: string }> {
  const refs = await requestCase(sb, o.requestId);
  if (!refs) return { v2: false };
  const v = await loadView(sb, o.requestId);
  if (!v) return { v2: true, ok: false, error: "request not found" };
  const mentions = nextActors(v).slackIds.length;
  if (o.dryRun) return { v2: true, ok: true, mentions };
  const r = await threadLine(notify, refs, o.requestId, { text: requestReminderText(v, { n: o.n, age: ageText(o.since) }), event: "reminder", source: "ef:pending-reminders", dedupe: `remind:${REQ_REF_TABLE}:${o.requestId}:${o.n}` });
  return { v2: true, ok: !!r?.ok, mentions, ...(r?.ok ? {} : { error: String(r?.error ?? "send_failed") }) };
}
