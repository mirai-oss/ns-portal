// =============================================================
// 採用管理: Slack のカードからの操作（2026-11-26 下書き・本番未適用）
//   いまあるのは［担当者を変更］だけ。押した人の特定・署名の確認・返事の送り方は slack-interact が持つ。
//   ここは「何を確かめて、どの RPC を呼び、どう返すか」だけ（DB と設定の読み書きは外から受け取る＝テストでにせものを渡せる）。
//
//   守ること:
//     ・業務の処理は RPC（recruit_assignee_candidates / recruit_assignee_set）。権限・古い値の照合・二重防止は RPC 側で確かめる。ここでは DB を直接書かない。
//     ・ここからは Slack に投稿しない。応募者へも何も送らない。親とカードの書き換え・スレッドの記録は、応募者の行が変わったことを既存のトリガーが拾って recruit-notify が行う。
//     ・設定（app_settings.recruit_slack.actions_enabled）が true のときだけ動く。
//   設計: scratchpad ob18/設計_採用_面接確定とLINEのSlack操作.md ／ DB 側: supabase/2026-11-26_recruit_action_base.sql
// =============================================================
import { ASSIGNEE_ACTION, clean, dayJst, HIRE_ACTION, INTERVIEW_ACTION, INTERVIEW_CANCEL_ACTION, LINE_ACTION, prefLine, PREFS_MAX } from "./recruit-notice.ts";
import { interviewText } from "./recruit-interview-text.ts";
import { RETRY_CAL_ACTION, RETRY_SEND_ACTION } from "./recruit-ops.ts";

export { HIRE_ACTION, RETRY_CAL_ACTION, RETRY_SEND_ACTION };
/** ［採用を決める］の確認の窓 */
export const HIRE_MODAL = "recruit.hire.modal";
/** 失敗の知らせの［もう一度］の、確かめの窓 */
export const RETRY_SEND_MODAL = "recruit.retry.send.modal", RETRY_CAL_MODAL = "recruit.retry.calendar.modal";

export { ASSIGNEE_ACTION, INTERVIEW_ACTION, INTERVIEW_CANCEL_ACTION, LINE_ACTION };
/** ［面接を確定］［面接を変更］の窓: 入力（INTERVIEW_MODAL）→ 確認（INTERVIEW_CONFIRM）／［面接を取り消す］の窓（INTERVIEW_CANCEL_MODAL） */
export const INTERVIEW_MODAL = "recruit.interview.modal", INTERVIEW_CONFIRM = "recruit.interview.confirm", INTERVIEW_CANCEL_MODAL = "recruit.interview.cancel.modal";
/** ［応募者へ LINE 返信］の窓: 入力（LINE_MODAL）→ 確認（LINE_CONFIRM） */
export const LINE_MODAL = "recruit.line.modal", LINE_CONFIRM = "recruit.line.confirm";
/** 選ぶ窓（モーダル）の callback_id */
export const ASSIGNEE_MODAL = "recruit.assignee.modal";

export type RecruitActor = { user_id: string; name?: string };
// deno-lint-ignore no-explicit-any
export type RpcResult = { data: any; error: { message: string } | null };
export type RecruitDeps = {
  /** 設定 app_settings.recruit_slack.actions_enabled が true か */
  actionsEnabled(): Promise<boolean>;
  rpc(name: string, args: Record<string, unknown>): Promise<RpcResult>;
  /** 共通の操作の入口（Edge Function recruit-action）を、押した人の操作として呼ぶ。返るのは { ok, code, message, … }（LINE の宛先・本文は返らない） */
  // deno-lint-ignore no-explicit-any
  action?(body: Record<string, unknown>): Promise<any>;
  /** 面接の窓に出す材料（応募者のいまの面接・希望日時・面接場所の一覧・モード）。権限が無ければ ok=false。LINE の宛先・電話・メールは含めない */
  interviewInfo?(applicantId: string): Promise<InterviewInfo>;
  /** 押した人だけに見える知らせ（窓を閉じたあとの結果）。place＝ボタンを押した場所（チャンネルとスレッド） */
  tell?(place: Place, text: string): Promise<void>;
};
export type Place = { channel_id?: string | null; thread_ts?: string | null };
export type IvPlaceRow = { name: string; address?: string | null; note?: string | null };
export type InterviewInfo = {
  ok: boolean; code?: string; message?: string;
  name?: string; is_test?: boolean; linked?: boolean; assignee_id?: string | null;
  interview_at?: string | null; interview_mode?: string | null; interview_place?: string | null; interview_url?: string | null;
  prefs?: unknown[]; format_wish?: string | null; places?: IvPlaceRow[];
  /** 実在の応募者の面接を、ここから確定できるか（送信のスイッチ true ＆ カレンダー本番モード） */
  enabled?: boolean; line_mode?: string; calendar_mode?: string;
};
/** slack-interact が Slack への返事に直す: ephemeral＝押した人だけに見える返事／modal＝窓を開く／errors＝窓の中にエラーを出す（窓は閉じない）／clear＝窓を閉じる */
export type RecruitOutcome =
  | { kind: "ephemeral"; text: string }
  | { kind: "modal"; view: Record<string, unknown> }
  | { kind: "errors"; errors: Record<string, string> }
  | { kind: "push"; view: Record<string, unknown> }                // 窓の上に、次の窓（確認）を重ねる
  | { kind: "clear"; after?: () => Promise<void> };                // 窓を全部閉じる。after があれば、返事のあとで実行する（3 秒の決まりの外で）

const isUuid = (s: unknown): s is string => typeof s === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s);
const OFF_TEXT = "この操作は、まだ使えません（設定が OFF です）。管理画面から操作してください。";
const DENIED_TEXT = "権限がありません（採用の権限がある人だけが操作できます）。";
const plain = (text: string) => ({ type: "plain_text", text, emoji: true });

export type Candidate = { id: string; name: string };
/** 選ぶ窓。private_metadata には、応募者の id・開いたときの担当（＝押した人が見ていた値）・カードの台帳の番号だけを入れる */
export function assigneeModal(
  meta: { applicant_id: string; expected_assignee: string | null; notification_id: string | null },
  d: { applicantName: string; currentName: string | null; candidates: Candidate[] },
): Record<string, unknown> {
  return {
    type: "modal", callback_id: ASSIGNEE_MODAL, private_metadata: JSON.stringify(meta),
    title: plain("担当者を変更"), submit: plain("変更する"), close: plain("やめる"),
    blocks: [
      { type: "section", text: { type: "mrkdwn", text: `*${clean(d.applicantName, 30)}* さんの担当者を変更します。\nいまの担当：${d.currentName ? clean(d.currentName, 20) : "未定"}` } },
      { type: "input", block_id: "assignee", label: plain("新しい担当者"), element: {
        type: "static_select", action_id: "assignee", placeholder: plain("選んでください"),
        options: d.candidates.slice(0, 100).map((c) => ({ text: plain(clean(c.name, 40)), value: c.id })),
      } },
      { type: "input", optional: true, block_id: "reason", label: plain("理由（任意）"), element: { type: "plain_text_input", action_id: "reason", max_length: 200 } },
      { type: "context", elements: [{ type: "mrkdwn", text: "選べるのは、採用の権限があり、この応募者の店舗を担当できる人です。応募者へは何も送られません。変更は、管理システムとこのスレッドに記録されます。" }] },
    ],
  };
}

/** カードの［担当者を変更］が押されたとき: 設定と権限を確かめ、選ぶ窓を返す。権限が無ければ、押した人だけに「権限がありません」 */
export async function assigneeOpen(deps: RecruitDeps, actor: RecruitActor, value: { applicant_id?: unknown; notification_id?: unknown }): Promise<RecruitOutcome> {
  const applicantId = value?.applicant_id;
  if (!isUuid(applicantId)) return { kind: "ephemeral", text: "応募者の番号が読めませんでした。カードを更新してから、もう一度押してください。" };
  if (!(await deps.actionsEnabled())) return { kind: "ephemeral", text: OFF_TEXT };
  const { data, error } = await deps.rpc("recruit_assignee_candidates", { p_applicant: applicantId, p_actor: actor.user_id });
  if (error) return { kind: "ephemeral", text: "読み込めませんでした: " + String(error.message).slice(0, 150) };
  if (!data?.ok) return { kind: "ephemeral", text: data?.code === "denied" ? DENIED_TEXT : String(data?.message ?? "読み込めませんでした") };
  const current: string | null = isUuid(data.assignee_id) ? data.assignee_id : null;
  const candidates = (Array.isArray(data.candidates) ? data.candidates : [])
    .filter((c: Candidate) => isUuid(c?.id) && c.id !== current && typeof c.name === "string" && c.name);
  if (!candidates.length) return { kind: "ephemeral", text: "ほかに担当にできる人がいません（採用の権限がある人が対象です）。" };
  return { kind: "modal", view: assigneeModal(
    { applicant_id: applicantId, expected_assignee: current, notification_id: isUuid(value?.notification_id) ? value.notification_id : null },
    { applicantName: String(data.applicant_name ?? ""), currentName: typeof data.assignee_name === "string" ? data.assignee_name : null, candidates },
  ) };
}

/**
 * 選ぶ窓の［変更する］が押されたとき: RPC recruit_assignee_set を呼ぶ。
 *   依頼の鍵＝その窓の番号（Slack が同じ送信をもう一度届けても、同じ鍵＝ 1 回だけ）。
 *   見ていた値＝窓を開いたときの担当（そのあとにだれかが変えていたら、RPC が何も変えずに「先に変更されています」を返す）。
 */
// deno-lint-ignore no-explicit-any
export async function assigneeSubmit(deps: RecruitDeps, actor: RecruitActor, view: any): Promise<RecruitOutcome> {
  const fail = (text: string): RecruitOutcome => ({ kind: "errors", errors: { assignee: text.slice(0, 180) } });
  let meta: { applicant_id?: unknown; expected_assignee?: unknown } = {};
  try { meta = JSON.parse(view?.private_metadata ?? "{}") ?? {}; } catch (_e) { meta = {}; }
  const viewId = typeof view?.id === "string" ? view.id.trim() : "";
  const selected = view?.state?.values?.assignee?.assignee?.selected_option?.value;
  const reason = String(view?.state?.values?.reason?.reason?.value ?? "").trim() || null;
  if (!isUuid(meta.applicant_id) || !viewId) return fail("この窓の情報が読めませんでした。閉じて、もう一度開いてください。");
  if (!isUuid(selected)) return fail("新しい担当者を選んでください。");
  if (!(await deps.actionsEnabled())) return fail(OFF_TEXT);
  const { data, error } = await deps.rpc("recruit_assignee_set", {
    p_applicant: meta.applicant_id, p_assignee: selected, p_expected_assignee: isUuid(meta.expected_assignee) ? meta.expected_assignee : null,
    p_request_key: `slack:view:${viewId}`, p_actor: actor.user_id, p_via: "slack", p_reason: reason,
  });
  if (error) return fail("変更できませんでした: " + String(error.message));
  if (data?.ok) return { kind: "clear" };   // 変えた／すでにその担当だった。結果は、スレッドの記録とカードで見える
  if (data?.code === "conflict") return fail(`先に変更されています（いまの担当：${data.current_name ? clean(data.current_name, 20) : "未定"}）。この窓を閉じて、もう一度開いてください。`);
  if (data?.code === "denied") return fail(DENIED_TEXT);
  return fail(String(data?.message ?? "変更できませんでした"));
}

// ---- ［応募者へ LINE 返信］（2026-11-27）: 入力 → 確認（宛先と本文）→ 送信 ----------------------------------
//   送るのは recruit-action（送信箱・スイッチ・試しモード・二重防止は、そちらと RPC が決める）。ここは、窓と、結果の知らせだけ。
//   スレッドのふつうの返信は、ここを通らない（＝今までどおり、応募者へは送られない）。
const LINE_MAX = 1000;
const DRY_NOTE = "🧪 いまは試しモードです。この窓から送っても、応募者には届きません（送信箱に「試し」と残るだけ）。";
type LineMeta = { applicant_id: string; notification_id: string | null; name: string; channel_id: string | null; thread_ts: string | null };
const strOrNull = (x: unknown) => (typeof x === "string" && x ? x : null);

/** 入力の窓 */
export function lineInputModal(meta: LineMeta, d: { dry: boolean }): Record<string, unknown> {
  return {
    type: "modal", callback_id: LINE_MODAL, private_metadata: JSON.stringify(meta),
    title: plain("応募者へ LINE 返信"), submit: plain("確認へ"), close: plain("やめる"),
    blocks: [
      { type: "section", text: { type: "mrkdwn", text: `宛先：*${clean(meta.name, 30)}* さん（LINE）` } },
      ...(d.dry ? [{ type: "context", elements: [{ type: "mrkdwn", text: DRY_NOTE }] }] : []),
      { type: "input", block_id: "body", label: plain("本文"), element: { type: "plain_text_input", action_id: "body", multiline: true, max_length: LINE_MAX } },
      { type: "context", elements: [{ type: "mrkdwn", text: "次の画面で、宛先と本文を確かめてから送ります。スレッドのふつうの返信は社内の連絡で、応募者には届きません。" }] },
    ],
  };
}
/** 確認の窓（「この文面を、応募者の LINE へ送ります」）。本文は、記法として解釈されない形（plain_text）で、そのまま見せる */
export function lineConfirmModal(meta: LineMeta & { body: string }, d: { dry: boolean }): Record<string, unknown> {
  return {
    type: "modal", callback_id: LINE_CONFIRM, private_metadata: JSON.stringify(meta),
    title: plain("送信の確認"), submit: plain("送信する"), close: plain("もどる"),
    blocks: [
      { type: "section", text: { type: "mrkdwn", text: `*この文面を、応募者の LINE へ送ります。*\n宛先：*${clean(meta.name, 30)}* さん（LINE）` } },
      { type: "divider" },
      { type: "section", text: { type: "plain_text", text: meta.body, emoji: false } },
      { type: "divider" },
      { type: "context", elements: [{ type: "mrkdwn", text: d.dry ? DRY_NOTE : "［送信する］を押すと、応募者本人に届きます。取り消せません。" }] },
    ],
  };
}
// deno-lint-ignore no-explicit-any
const refusal = (r: any) => (r?.code === "denied" && !r?.message ? DENIED_TEXT : String(r?.message ?? "実行できませんでした"));   // 2026-11-30: 断った理由（「社長だけ」など）が RPC から来ていれば、それを見せる

/** カードの［応募者へ LINE 返信］が押されたとき: 設定・権限・LINE の連携を確かめて、入力の窓を返す。送れないときは、押した人だけに理由を知らせる */
export async function lineOpen(deps: RecruitDeps, _actor: RecruitActor, value: { applicant_id?: unknown; notification_id?: unknown }, place: Place = {}): Promise<RecruitOutcome> {
  const applicantId = value?.applicant_id;
  if (!isUuid(applicantId)) return { kind: "ephemeral", text: "応募者の番号が読めませんでした。カードを更新してから、もう一度押してください。" };
  if (!deps.action || !(await deps.actionsEnabled())) return { kind: "ephemeral", text: OFF_TEXT };
  const r = await deps.action({ op: "message_check", applicant_id: applicantId });
  if (!r?.ok || r.can_send !== true) return { kind: "ephemeral", text: refusal(r) };
  return { kind: "modal", view: lineInputModal(
    { applicant_id: applicantId, notification_id: isUuid(value?.notification_id) ? value.notification_id : null, name: String(r.applicant_name ?? ""), channel_id: strOrNull(place.channel_id), thread_ts: strOrNull(place.thread_ts) },
    { dry: r.mode !== "live" }) };
}

// deno-lint-ignore no-explicit-any
function readMeta(view: any): (LineMeta & { body?: unknown }) | null {
  try {
    const m = JSON.parse(view?.private_metadata ?? "{}") ?? {};
    if (!isUuid(m.applicant_id)) return null;
    return { applicant_id: m.applicant_id, notification_id: isUuid(m.notification_id) ? m.notification_id : null, name: String(m.name ?? ""), channel_id: strOrNull(m.channel_id), thread_ts: strOrNull(m.thread_ts), body: m.body };
  } catch (_e) { return null; }
}

/** 入力の窓の［確認へ］: 本文を確かめ、もう一度「送ってよいか」を確かめて、確認の窓を重ねる（ここでは送らない） */
// deno-lint-ignore no-explicit-any
export async function lineInput(deps: RecruitDeps, _actor: RecruitActor, view: any): Promise<RecruitOutcome> {
  const fail = (text: string): RecruitOutcome => ({ kind: "errors", errors: { body: text.slice(0, 180) } });
  const meta = readMeta(view);
  const body = String(view?.state?.values?.body?.body?.value ?? "").trim();
  if (!meta) return fail("この窓の情報が読めませんでした。閉じて、もう一度開いてください。");
  if (!body) return fail("本文を入れてください。");
  if (body.length > LINE_MAX) return fail(`本文が長すぎます（${LINE_MAX} 文字まで）。`);
  if (!deps.action || !(await deps.actionsEnabled())) return fail(OFF_TEXT);
  const r = await deps.action({ op: "message_check", applicant_id: meta.applicant_id });
  if (!r?.ok || r.can_send !== true) return fail(refusal(r));
  return { kind: "push", view: lineConfirmModal({ ...meta, name: String(r.applicant_name ?? meta.name), body }, { dry: r.mode !== "live" }) };
}

/**
 * 確認の窓の［送信する］: 窓を閉じ、そのあとで recruit-action の message_send を 1 回だけ呼ぶ。
 *   依頼の鍵＝最初の窓の番号（Slack が同じ送信をもう一度届けても、同じ鍵＝ 1 回だけ）。
 *   結果: 押した人には、本人だけに見える知らせ。みんなには、スレッドの記録（成功＝既存の通知の「↩️ こちらから」／試し・失敗・結果不明＝ recruit-action が 1 行）。
 */
// deno-lint-ignore no-explicit-any
export async function lineConfirm(deps: RecruitDeps, _actor: RecruitActor, view: any): Promise<RecruitOutcome> {
  const meta = readMeta(view);
  const body = typeof meta?.body === "string" ? meta.body.trim() : "";
  const root = strOrNull(view?.root_view_id) ?? strOrNull(view?.id);
  // 窓の情報が読めない: 何も送らずに閉じ、押した人にだけ知らせる
  if (!meta || !body || !root || !deps.action) {
    return { kind: "clear", after: async () => { await deps.tell?.({ channel_id: meta?.channel_id, thread_ts: meta?.thread_ts }, "送信できませんでした（窓の情報が読めませんでした）。応募者には送っていません。もう一度、カードのボタンから開いてください。"); } };
  }
  const action = deps.action;
  const place: Place = { channel_id: meta.channel_id, thread_ts: meta.thread_ts };
  return { kind: "clear", after: async () => {
    // deno-lint-ignore no-explicit-any
    let r: any;
    try { r = await action({ op: "message_send", applicant_id: meta.applicant_id, text: body, request_key: `slack:line:${root}`, purpose: "reply" }); }
    catch (e) { r = { ok: false, code: "error", message: "送信の入口を呼べませんでした: " + String((e as Error)?.message ?? e).slice(0, 100) }; }
    const name = clean(meta.name, 30);
    const text = r?.code === "sent" || (r?.code === "replayed" && r?.status === "sent") ? `✅ ${name} さんへ、LINE で送りました。`
      : r?.code === "dry" || (r?.code === "replayed" && r?.status === "dry_done") ? `🧪 試しモードのため、${name} さんへは送っていません（送信箱に「試し」と残しました）。`
      : r?.code === "unknown" || r?.code === "sent_unrecorded" ? `⚠️ ${String(r?.message ?? "送れたか確認できていません")}。もう一度送る前に、管理画面でやり取りを確かめてください。`
      : `⚠️ ${name} さんへは送っていません: ${refusal(r)}`;
    await deps.tell?.(place, text);
  } };
}

// ---- ［面接を確定］［面接を変更］［面接を取り消す］（2026-11-29）: 希望日時から選ぶか日時を入力 → 方法と場所 → 確認 → 確定 ----------------
//   確定するのは recruit-action の interview_confirm / interview_cancel（権限・スイッチ・同じ鍵・同時の操作・古い値の照合は、そちらと RPC が決める）。
//   ここは、窓と、結果の知らせだけ。親・カード・スレッドへの反映は、応募者の行が変わったことを既存の通知が拾う。
type IvMeta = LineMeta & { exp_at: string | null; exp_asg: string | null; linked: boolean };
type IvChoice = { at: string; mode: "online" | "onsite"; place: string | null; notify: boolean };
const MODE_LABEL: Record<string, string> = { online: "オンライン（Meet の URL を発行）", onsite: "対面（場所を案内）" };
const IV_OFF = "面接の確定は、まだここからは使えません（スイッチが OFF、または、カレンダーが試しモードです）。管理画面から操作してください。";
const opt = (text: string, value: string) => ({ text: plain(text.slice(0, 75)), value });
/** 希望日時 1 件を、確定できる日時（ISO）にする。「この日のこの時刻」「この日のこの時間帯（始まり）」だけ。日本時間。「いつでも」・読めない形は null */
export function prefToIso(x: unknown): string | null {
  if (!x || typeof x !== "object") return null;
  const p = x as Record<string, unknown>;
  if (p.mode !== "exact" && p.mode !== "range") return null;
  const d = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(p.date ?? "")), t = /^(\d{1,2}):(\d{2})$/.exec(String(p.from ?? ""));
  if (!d || !t || Number(t[1]) > 23 || Number(t[2]) > 59) return null;
  const ms = Date.parse(`${d[1]}-${d[2]}-${d[3]}T${t[1].padStart(2, "0")}:${t[2]}:00+09:00`);
  return Number.isFinite(ms) ? new Date(ms).toISOString() : null;
}
const ivWhen = (iso: string | null | undefined, mode?: string | null, place?: string | null) =>
  iso ? `${dayJst(iso)}${mode === "onsite" ? `・対面${place ? `（${clean(place, 30)}）` : ""}` : mode === "online" ? "・オンライン" : ""}` : "未定";
const modeNotes = (info: InterviewInfo) => [
  info.calendar_mode !== "live" ? "🧪 カレンダーは試しモードです（予定は作られません・Meet の URL も発行されません）。" : null,
  info.line_mode !== "live" ? "🧪 LINE は試しモードです（案内は、応募者には届きません）。" : null,
].filter((x): x is string => !!x);

/** 入力の窓 */
export function interviewInputModal(meta: IvMeta, info: InterviewInfo): Record<string, unknown> {
  const picks = (info.prefs ?? []).slice(0, PREFS_MAX).map((p) => ({ iso: prefToIso(p), label: prefLine(p) })).filter((x): x is { iso: string; label: string } => !!x.iso && !!x.label);
  const loose = (info.prefs ?? []).slice(0, PREFS_MAX).map((p) => (prefToIso(p) ? null : prefLine(p))).filter((x): x is string => !!x);
  const places = (info.places ?? []).filter((p) => p && typeof p.name === "string" && p.name).slice(0, 100);
  const mode0 = info.interview_mode === "onsite" || info.interview_mode === "online" ? info.interview_mode : info.format_wish === "onsite" ? "onsite" : "online";
  const place0 = places.find((p) => p.name === info.interview_place);
  const change = !!info.interview_at;
  const blocks: unknown[] = [
    { type: "section", text: { type: "mrkdwn", text: `*${clean(meta.name, 30)}* さんの面接を${change ? "変更" : "確定"}します。\nいまの面接：${ivWhen(info.interview_at, info.interview_mode, info.interview_place)}` } },
  ];
  if (picks.length) blocks.push({ type: "input", optional: true, block_id: "pick", label: plain("本人の希望日時から選ぶ"), element: { type: "radio_buttons", action_id: "pick", options: picks.map((p) => opt(p.label, p.iso)) } });
  if (loose.length) blocks.push({ type: "context", elements: [{ type: "mrkdwn", text: `そのほかの希望：${loose.map((t) => clean(t, 40)).join("／")}` }] });
  blocks.push({ type: "input", optional: true, block_id: "at", label: plain(picks.length ? "別の日時にする（希望日時を選ばないとき）" : "面接の日時"), element: { type: "datetimepicker", action_id: "at" } });
  blocks.push({ type: "input", block_id: "mode", label: plain("面接のやり方"), element: { type: "radio_buttons", action_id: "mode", initial_option: opt(MODE_LABEL[mode0], mode0), options: [opt(MODE_LABEL.online, "online"), opt(MODE_LABEL.onsite, "onsite")] } });
  if (places.length) blocks.push({ type: "input", optional: true, block_id: "place", label: plain("面接場所（対面のとき）"), element: { type: "static_select", action_id: "place", placeholder: plain("選んでください"), ...(place0 ? { initial_option: opt(clean(place0.name, 60), place0.name) } : {}), options: places.map((p) => opt(clean(p.name, 60), p.name)) } });
  else blocks.push({ type: "context", elements: [{ type: "mrkdwn", text: "面接場所が、まだ登録されていません（対面にするには、管理画面の設定 →「面接場所」で登録してください）。" }] });
  if (meta.linked) blocks.push({ type: "input", optional: true, block_id: "notify", label: plain("応募者への案内"), element: { type: "checkboxes", action_id: "notify", initial_options: [opt("LINE で案内を送る", "yes")], options: [opt("LINE で案内を送る", "yes")] } });
  else blocks.push({ type: "context", elements: [{ type: "mrkdwn", text: "この応募者は LINE と連携していないため、ここからは案内を送れません。確定のあと、案内文をあなただけに表示します（Indeed などで送ってください）。" }] });
  const notes = modeNotes(info);
  if (notes.length) blocks.push({ type: "context", elements: notes.map((t) => ({ type: "mrkdwn", text: t })) });
  return { type: "modal", callback_id: INTERVIEW_MODAL, private_metadata: JSON.stringify(meta), title: plain(change ? "面接を変更" : "面接を確定"), submit: plain("確認へ"), close: plain("やめる"), blocks };
}

/** 確認の窓（日時・方法・場所・予定・案内の文面） */
export function interviewConfirmModal(meta: IvMeta & IvChoice, info: InterviewInfo): Record<string, unknown> {
  const pl = (info.places ?? []).find((p) => p.name === meta.place) ?? null;
  const lines = [
    `*${clean(meta.name, 30)}* さんの面接を、この内容で確定します。`,
    `日時：*${dayJst(meta.at)}*${meta.exp_at ? `（前：${dayJst(meta.exp_at)}）` : ""}`,
    `やり方：${meta.mode === "onsite" ? `対面（${clean(meta.place ?? "", 40)}）` : "オンライン"}`,
    `カレンダー：${info.calendar_mode === "live" ? (meta.mode === "online" ? "予定を登録し、Meet の URL を発行します" : "予定を登録します") : "🧪 試しモード（予定は作りません）"}`,
    `応募者への案内：${!meta.linked ? "送れません（LINE 未連携。確定のあと、案内文をあなただけに表示します）" : !meta.notify ? "送りません" : info.line_mode === "live" ? "LINE で、下の文面を送ります" : "🧪 試しモード（応募者には届きません。文面は下のとおり）"}`,
  ];
  const blocks: unknown[] = [{ type: "section", text: { type: "mrkdwn", text: lines.join("\n") } }];
  if (meta.notify || !meta.linked) {
    const text = interviewText({ name: meta.name, interview_at: meta.at, interview_mode: meta.mode, interview_place: meta.place ?? "", interview_address: pl?.address ?? "",
      interview_url: meta.mode === "online" ? (info.interview_url || "（確定のときに発行します）") : null }, meta.mode === "onsite" ? pl : null);
    blocks.push({ type: "divider" }, { type: "section", text: { type: "plain_text", text: text.slice(0, 2900), emoji: false } });
  }
  return { type: "modal", callback_id: INTERVIEW_CONFIRM, private_metadata: JSON.stringify(meta), title: plain("面接の確認"), submit: plain("確定する"), close: plain("もどる"), blocks };
}

const ivMeta = (applicantId: string, notificationId: unknown, info: InterviewInfo, place: Place): IvMeta => ({
  applicant_id: applicantId, notification_id: isUuid(notificationId) ? notificationId : null, name: String(info.name ?? ""), channel_id: strOrNull(place.channel_id), thread_ts: strOrNull(place.thread_ts),
  exp_at: strOrNull(info.interview_at), exp_asg: isUuid(info.assignee_id) ? info.assignee_id : null, linked: info.linked === true,
});
async function loadInfo(deps: RecruitDeps, applicantId: string): Promise<{ info?: InterviewInfo; text?: string }> {
  if (!deps.action || !deps.interviewInfo || !(await deps.actionsEnabled())) return { text: OFF_TEXT };
  const info = await deps.interviewInfo(applicantId);
  if (!info?.ok) return { text: info?.code === "denied" ? DENIED_TEXT : String(info?.message ?? "読み込めませんでした") };
  if (info.enabled !== true && info.is_test !== true) return { text: IV_OFF };
  return { info };
}
// deno-lint-ignore no-explicit-any
function readIvMeta(view: any): (IvMeta & Partial<IvChoice>) | null {
  const b = readMeta(view); if (!b) return null;
  try {
    const m = JSON.parse(view?.private_metadata ?? "{}") ?? {};
    return { ...b, exp_at: strOrNull(m.exp_at), exp_asg: isUuid(m.exp_asg) ? m.exp_asg : null, linked: m.linked === true,
      at: strOrNull(m.at) ?? undefined, mode: m.mode === "onsite" || m.mode === "online" ? m.mode : undefined, place: strOrNull(m.place), notify: m.notify === true };
  } catch (_e) { return null; }
}

/** カードの［面接を確定］／［面接を変更］が押されたとき: 設定・権限を確かめて、入力の窓を返す */
export async function interviewOpen(deps: RecruitDeps, _actor: RecruitActor, value: { applicant_id?: unknown; notification_id?: unknown }, place: Place = {}): Promise<RecruitOutcome> {
  const applicantId = value?.applicant_id;
  if (!isUuid(applicantId)) return { kind: "ephemeral", text: "応募者の番号が読めませんでした。カードを更新してから、もう一度押してください。" };
  const { info, text } = await loadInfo(deps, applicantId);
  if (!info) return { kind: "ephemeral", text: text ?? OFF_TEXT };
  return { kind: "modal", view: interviewInputModal(ivMeta(applicantId, value?.notification_id, info, place), info) };
}

/** 入力の窓の［確認へ］: 日時・方法・場所を確かめて、確認の窓を重ねる（ここでは確定しない） */
// deno-lint-ignore no-explicit-any
export async function interviewInput(deps: RecruitDeps, _actor: RecruitActor, view: any, now = Date.now()): Promise<RecruitOutcome> {
  const meta = readIvMeta(view);
  const err = (block: string, text: string): RecruitOutcome => ({ kind: "errors", errors: { [block]: text.slice(0, 180) } });
  if (!meta) return err("mode", "この窓の情報が読めませんでした。閉じて、もう一度開いてください。");
  const v = view?.state?.values ?? {};
  const pick = strOrNull(v.pick?.pick?.selected_option?.value), sec = Number(v.at?.at?.selected_date_time);
  const typed = Number.isFinite(sec) && sec > 0 ? new Date(sec * 1000).toISOString() : null;
  if (pick && typed) return err("at", "希望日時か、別の日時の、どちらか 1 つにしてください。");
  const at = pick ?? typed;
  if (!at || !Number.isFinite(Date.parse(at))) return err("at", "面接の日時を、選ぶか入れてください。");
  if (Date.parse(at) < now - 5 * 60e3) return err("at", "過ぎた日時は選べません。");
  const mode = v.mode?.mode?.selected_option?.value;
  if (mode !== "online" && mode !== "onsite") return err("mode", "面接のやり方を選んでください。");
  const placeName = mode === "onsite" ? strOrNull(v.place?.place?.selected_option?.value) : null;
  const { info, text } = await loadInfo(deps, meta.applicant_id);
  if (!info) return err("mode", text ?? OFF_TEXT);
  if (mode === "onsite" && (!placeName || !(info.places ?? []).some((p) => p.name === placeName))) return err((info.places ?? []).length ? "place" : "mode", "対面のときは、面接場所を選んでください。");
  const notify = meta.linked && (v.notify?.notify?.selected_options ?? []).some((o: { value?: string }) => o?.value === "yes");
  return { kind: "push", view: interviewConfirmModal({ ...meta, name: String(info.name ?? meta.name), at, mode, place: placeName, notify }, info) };
}

// deno-lint-ignore no-explicit-any
function ivResultText(name: string, r: any, what: "confirm" | "cancel"): string {
  const n = clean(name, 30);
  if (r?.code === "conflict") return `⚠️ ${n} さんの面接は、先に変更されています（いまの面接：${ivWhen(r.current_interview_at)}・担当：${r.current_assignee_name ? clean(r.current_assignee_name, 20) : "未定"}）。何も変えていません。カードを確かめて、もう一度開いてください。`;
  if (r?.code === "noop") return `ℹ️ ${String(r.message ?? "すでにその内容です")}（何も変えていません）。`;
  if (r?.code === "replayed") return r.ok ? `ℹ️ ${String(r.message ?? "処理済みです")}` : `⚠️ ${String(r.message ?? "処理できていません")}`;
  if (!r?.ok) return `⚠️ ${n} さんの面接は、${what === "cancel" ? "取り消して" : "確定して"}いません: ${r?.code === "denied" && !r?.message ? DENIED_TEXT : String(r?.message ?? "実行できませんでした")}`;
  if (what === "cancel") return r.code === "done" ? `✅ ${n} さんの面接の日程を取り消しました（応募者へは連絡していません）。` : `⚠️ ${n} さんの面接は取り消しましたが、カレンダーの予定を消せませんでした。カレンダーで、手で消してください。`;
  const iv = r.interview ?? {}, cal = r.calendar ?? {}, nt = r.notice ?? {};
  const parts = [`${r.code === "done" ? "✅" : "⚠️"} ${n} さんの面接を確定しました（${ivWhen(iv.at, iv.mode, iv.place)}）。`];
  parts.push(cal.ok === false ? `カレンダー：登録できませんでした（${clean(cal.why ?? "不明", 100)}）` : cal.mode === "dry" ? "カレンダー：🧪 試しモード（予定は作っていません）" : cal.mode === "manual" ? "カレンダー：貼り付けた URL を使いました" : "カレンダー：登録しました");
  const ns: Record<string, string> = { sent: "LINE で送りました", dry: "🧪 試しモード（応募者には届いていません）", dry_done: "🧪 試しモード（応募者には届いていません）", skipped_off: "送っていません（送らない設定）",
    skipped_unlinked: "送っていません（LINE 未連携。下の文面を、Indeed などで送ってください）", failed: "⚠️ LINE を送れませんでした（自動では再送しません）", unknown: "⚠️ LINE を送れたか確認できていません（自動では再送しません）",
    duplicate: "同じ内容を、すでに送っています", duplicate_recent: "同じ文面を、直前に送っています" };
  parts.push(`応募者への案内：${ns[String(nt.status)] ?? "⚠️ 送れていません（" + clean(nt.status ?? "不明", 30) + "）"}`);
  if (nt.status === "skipped_unlinked" && typeof nt.text === "string") parts.push("```" + nt.text.replace(/`/g, "'").slice(0, 2500) + "```");
  return parts.join("\n");
}

/** 確認の窓の［確定する］: 窓を閉じ、そのあとで recruit-action の interview_confirm を 1 回だけ呼ぶ（依頼の鍵＝最初の窓の番号。見ていた値＝窓を開いたときの面接日時と担当） */
// deno-lint-ignore no-explicit-any
export async function interviewConfirmSubmit(deps: RecruitDeps, _actor: RecruitActor, view: any): Promise<RecruitOutcome> {
  const meta = readIvMeta(view);
  const root = strOrNull(view?.root_view_id) ?? strOrNull(view?.id);
  const place: Place = { channel_id: meta?.channel_id, thread_ts: meta?.thread_ts };
  if (!meta || !meta.at || !meta.mode || !root || !deps.action) {
    return { kind: "clear", after: async () => { await deps.tell?.(place, "面接は確定していません（窓の情報が読めませんでした）。もう一度、カードのボタンから開いてください。"); } };
  }
  const action = deps.action;
  return { kind: "clear", after: async () => {
    // deno-lint-ignore no-explicit-any
    let r: any;
    try { r = await action({ op: "interview_confirm", applicant_id: meta.applicant_id, at: meta.at, mode: meta.mode, place: meta.place ?? null,
      notify: meta.notify === true || !meta.linked,   // LINE 未連携のときは「案内文を作る」ために true（未連携なので送られない。文面だけが返る）
      request_key: `slack:iv:${root}`, expected: { interview_at: meta.exp_at, assignee_id: meta.exp_asg } }); }
    catch (e) { r = { ok: false, code: "error", message: "入口を呼べませんでした: " + String((e as Error)?.message ?? e).slice(0, 100) }; }
    await deps.tell?.(place, ivResultText(meta.name, r, "confirm"));
  } };
}

/** カードの［面接を取り消す］が押されたとき: 確かめの窓を返す */
export async function interviewCancelOpen(deps: RecruitDeps, _actor: RecruitActor, value: { applicant_id?: unknown; notification_id?: unknown }, place: Place = {}): Promise<RecruitOutcome> {
  const applicantId = value?.applicant_id;
  if (!isUuid(applicantId)) return { kind: "ephemeral", text: "応募者の番号が読めませんでした。カードを更新してから、もう一度押してください。" };
  const { info, text } = await loadInfo(deps, applicantId);
  if (!info) return { kind: "ephemeral", text: text ?? OFF_TEXT };
  if (!info.interview_at) return { kind: "ephemeral", text: "面接の日程は、入っていません。" };
  const meta = ivMeta(applicantId, value?.notification_id, info, place);
  return { kind: "modal", view: {
    type: "modal", callback_id: INTERVIEW_CANCEL_MODAL, private_metadata: JSON.stringify(meta), title: plain("面接を取り消す"), submit: plain("取り消す"), close: plain("やめる"),
    blocks: [
      { type: "section", text: { type: "mrkdwn", text: `*${clean(meta.name, 30)}* さんの面接（${ivWhen(info.interview_at, info.interview_mode, info.interview_place)}）を取り消します。` } },
      { type: "context", elements: [
        { type: "mrkdwn", text: info.calendar_mode === "live" ? "カレンダーの予定も消します。" : "🧪 カレンダーは試しモードです（予定は消しません）。" },
        { type: "mrkdwn", text: "応募者へは、連絡しません（いまの管理システムと同じ）。知らせるときは、取り消したあとに連絡してください。" },
      ] },
    ],
  } };
}

/** 取り消しの窓の［取り消す］: 窓を閉じ、そのあとで recruit-action の interview_cancel を 1 回だけ呼ぶ */
// deno-lint-ignore no-explicit-any
export async function interviewCancelSubmit(deps: RecruitDeps, _actor: RecruitActor, view: any): Promise<RecruitOutcome> {
  const meta = readIvMeta(view);
  const root = strOrNull(view?.root_view_id) ?? strOrNull(view?.id);
  const place: Place = { channel_id: meta?.channel_id, thread_ts: meta?.thread_ts };
  if (!meta || !root || !deps.action) return { kind: "clear", after: async () => { await deps.tell?.(place, "面接は取り消していません（窓の情報が読めませんでした）。もう一度、カードのボタンから開いてください。"); } };
  const action = deps.action;
  return { kind: "clear", after: async () => {
    // deno-lint-ignore no-explicit-any
    let r: any;
    try { r = await action({ op: "interview_cancel", applicant_id: meta.applicant_id, request_key: `slack:ivc:${root}`, expected: { interview_at: meta.exp_at, assignee_id: meta.exp_asg } }); }
    catch (e) { r = { ok: false, code: "error", message: "入口を呼べませんでした: " + String((e as Error)?.message ?? e).slice(0, 100) }; }
    await deps.tell?.(place, ivResultText(meta.name, r, "cancel"));
  } };
}

// ---- 失敗の知らせの［もう一度］（2026-11-29）: 人が確かめてから、のときだけ動く ---------------------------------------------
//   LINE: 失敗・結果不明の行を、同じ行・同じ再送の鍵で送り直す（recruit-action の message_retry）。結果不明は「やり取りを確かめた」のチェックが要る。
//   カレンダー: いまの面接の予定を、もう一度登録する（calendar_retry）。面接の確定そのものは変えない。
type RetryMeta = LineMeta & { outbox_id?: string | null; status?: string | null; note_key?: string | null; online?: boolean };
// deno-lint-ignore no-explicit-any
function readRetryMeta(view: any): RetryMeta | null {
  const b = readMeta(view); if (!b) return null;
  try {
    const m = JSON.parse(view?.private_metadata ?? "{}") ?? {};
    return { ...b, outbox_id: isUuid(m.outbox_id) ? m.outbox_id : null, status: strOrNull(m.status), note_key: strOrNull(m.note_key), online: m.online === true };
  } catch (_e) { return null; }
}

/** 「送れませんでした」の行の［もう一度送る］: 権限と状態を確かめて、確かめの窓（宛先・本文・状態）を返す */
export async function retrySendOpen(deps: RecruitDeps, _actor: RecruitActor, value: { applicant_id?: unknown; outbox_id?: unknown }, place: Place = {}): Promise<RecruitOutcome> {
  if (!isUuid(value?.applicant_id) || !isUuid(value?.outbox_id)) return { kind: "ephemeral", text: "送信の記録の番号が読めませんでした。" };
  if (!deps.action || !(await deps.actionsEnabled())) return { kind: "ephemeral", text: OFF_TEXT };
  const r = await deps.action({ op: "message_retry_info", outbox_id: value.outbox_id });
  if (!r?.ok || r.can_retry !== true) return { kind: "ephemeral", text: refusal(r) };
  const unknown = r.status === "unknown", dry = r.mode !== "live";
  const meta: RetryMeta = { applicant_id: value.applicant_id, notification_id: null, name: String(r.applicant_name ?? ""), channel_id: strOrNull(place.channel_id), thread_ts: strOrNull(place.thread_ts), outbox_id: value.outbox_id, status: unknown ? "unknown" : "failed" };
  const blocks: unknown[] = [
    { type: "section", text: { type: "mrkdwn", text: `*${clean(meta.name, 30)}* さんへの LINE（${unknown ? "送れたか確認できていない" : "送れなかった"}もの）を、もう一度送ります。\n*この文面が、応募者の LINE に届きます。*` } },
    { type: "divider" }, { type: "section", text: { type: "plain_text", text: String(r.body ?? "").slice(0, 2900) || "（本文なし）", emoji: false } }, { type: "divider" },
  ];
  if (unknown) blocks.push({ type: "input", block_id: "checked", label: plain("送る前の確かめ"), element: { type: "checkboxes", action_id: "checked", options: [opt("応募者とのやり取りを確かめました（まだ届いていません）", "yes")] } });
  blocks.push({ type: "context", elements: [{ type: "mrkdwn", text: dry ? DRY_NOTE : unknown ? "前の送信が実は届いていた場合に二重にならないよう、同じ「再送の鍵」で送ります（時間がたっていると効かないことがあるので、必ず確かめてください）。" : "［送り直す］を押すと、応募者本人に届きます。取り消せません。" }] });
  return { kind: "modal", view: { type: "modal", callback_id: RETRY_SEND_MODAL, private_metadata: JSON.stringify(meta), title: plain("LINE を送り直す"), submit: plain("送り直す"), close: plain("やめる"), blocks } };
}

/** 確かめの窓の［送り直す］: 窓を閉じ、そのあとで recruit-action の message_retry を 1 回だけ呼ぶ */
// deno-lint-ignore no-explicit-any
export async function retrySendSubmit(deps: RecruitDeps, _actor: RecruitActor, view: any): Promise<RecruitOutcome> {
  const meta = readRetryMeta(view);
  const root = strOrNull(view?.root_view_id) ?? strOrNull(view?.id);
  const place: Place = { channel_id: meta?.channel_id, thread_ts: meta?.thread_ts };
  if (!meta || !meta.outbox_id || !root || !deps.action) return { kind: "clear", after: async () => { await deps.tell?.(place, "送り直していません（窓の情報が読めませんでした）。もう一度、ボタンから開いてください。"); } };
  if (meta.status === "unknown" && !(view?.state?.values?.checked?.checked?.selected_options ?? []).some((o: { value?: string }) => o?.value === "yes")) {
    return { kind: "errors", errors: { checked: "応募者とのやり取りを確かめてから、チェックを入れてください。" } };
  }
  const action = deps.action, outboxId = meta.outbox_id;
  return { kind: "clear", after: async () => {
    // deno-lint-ignore no-explicit-any
    let r: any;
    try { r = await action({ op: "message_retry", outbox_id: outboxId, request_key: `slack:retry:${root}` }); }
    catch (e) { r = { ok: false, code: "error", message: "入口を呼べませんでした: " + String((e as Error)?.message ?? e).slice(0, 100) }; }
    const n = clean(meta.name, 30);
    await deps.tell?.(place, r?.code === "sent" ? `✅ ${n} さんへ、LINE を送り直しました。` : r?.code === "dry" ? `🧪 試しモードのため、${n} さんへは送っていません。`
      : r?.code === "unknown" || r?.code === "sent_unrecorded" ? `⚠️ ${String(r?.message ?? "送れたか確認できていません")}。もう一度送る前に、管理画面でやり取りを確かめてください。` : `⚠️ ${n} さんへは送っていません: ${refusal(r)}`);
  } };
}

/** 「カレンダーに登録できませんでした」の行の［もう一度登録］: 権限と、いまの面接を確かめて、確かめの窓を返す */
export async function retryCalendarOpen(deps: RecruitDeps, _actor: RecruitActor, value: { applicant_id?: unknown; note_key?: unknown }, place: Place = {}): Promise<RecruitOutcome> {
  const applicantId = value?.applicant_id;
  if (!isUuid(applicantId)) return { kind: "ephemeral", text: "応募者の番号が読めませんでした。" };
  const { info, text } = await loadInfo(deps, applicantId);
  if (!info) return { kind: "ephemeral", text: text ?? OFF_TEXT };
  if (!info.interview_at) return { kind: "ephemeral", text: "面接の日程が入っていません（取り消されています）。予定は登録しません。" };
  const online = info.interview_mode !== "onsite";
  const meta: RetryMeta = { applicant_id: applicantId, notification_id: null, name: String(info.name ?? ""), channel_id: strOrNull(place.channel_id), thread_ts: strOrNull(place.thread_ts),
    note_key: typeof value?.note_key === "string" && /^recruit:iv:[0-9a-f-]{36}:calendar$/i.test(value.note_key) ? value.note_key : null, online };
  const blocks: unknown[] = [{ type: "section", text: { type: "mrkdwn", text: `*${clean(meta.name, 30)}* さんの面接（${ivWhen(info.interview_at, info.interview_mode, info.interview_place)}）の予定を、カレンダーにもう一度登録します。\n面接の日時・やり方は変えません。` } }];
  if (online && info.linked === true) blocks.push({ type: "input", optional: true, block_id: "notify", label: plain("応募者への案内"), element: { type: "checkboxes", action_id: "notify",
    ...(info.interview_url ? {} : { initial_options: [opt("登録できたら、URL 入りの案内を LINE で送る", "yes")] }), options: [opt("登録できたら、URL 入りの案内を LINE で送る", "yes")] } });
  const notes = modeNotes(info);
  if (notes.length) blocks.push({ type: "context", elements: notes.map((t) => ({ type: "mrkdwn", text: t })) });
  return { kind: "modal", view: { type: "modal", callback_id: RETRY_CAL_MODAL, private_metadata: JSON.stringify(meta), title: plain("カレンダーに登録"), submit: plain("登録する"), close: plain("やめる"), blocks } };
}

/** 確かめの窓の［登録する］: 窓を閉じ、そのあとで recruit-action の calendar_retry を 1 回だけ呼ぶ */
// deno-lint-ignore no-explicit-any
export async function retryCalendarSubmit(deps: RecruitDeps, _actor: RecruitActor, view: any): Promise<RecruitOutcome> {
  const meta = readRetryMeta(view);
  const root = strOrNull(view?.root_view_id) ?? strOrNull(view?.id);
  const place: Place = { channel_id: meta?.channel_id, thread_ts: meta?.thread_ts };
  if (!meta || !root || !deps.action) return { kind: "clear", after: async () => { await deps.tell?.(place, "登録していません（窓の情報が読めませんでした）。もう一度、ボタンから開いてください。"); } };
  const notify = (view?.state?.values?.notify?.notify?.selected_options ?? []).some((o: { value?: string }) => o?.value === "yes");
  const action = deps.action;
  return { kind: "clear", after: async () => {
    // deno-lint-ignore no-explicit-any
    let r: any;
    try { r = await action({ op: "calendar_retry", applicant_id: meta.applicant_id, request_key: `slack:calretry:${root}`, notify, note_key: meta.note_key ?? null }); }
    catch (e) { r = { ok: false, code: "error", message: "入口を呼べませんでした: " + String((e as Error)?.message ?? e).slice(0, 100) }; }
    const n = clean(meta.name, 30), nt = String(r?.notice?.status ?? "");
    const tail = nt === "sent" ? "案内を LINE で送りました。" : nt === "dry" || nt === "dry_done" ? "🧪 案内は試しモード（応募者には届いていません）。" : nt === "duplicate" || nt === "duplicate_recent" ? "同じ案内を、すでに送っています。"
      : nt === "failed" || nt === "unknown" ? "⚠️ 案内の LINE は送れていません（自動では再送しません）。" : meta.online ? "応募者への案内は送っていません（URL を知らせるときは、LINE 返信で送ってください）。" : "";
    await deps.tell?.(place, r?.code === "dry" ? `🧪 カレンダーは試しモードのため、${n} さんの予定は作っていません。` : r?.ok ? `${r.code === "done" ? "✅" : "⚠️"} ${n} さんの面接の予定を、カレンダーに登録しました。${tail}`
      : r?.code === "replayed" ? `ℹ️ ${String(r?.message ?? "この操作は、すでに受け付けています")}` : `⚠️ ${n} さんの予定は登録できていません: ${refusal(r)}`);
  } };
}

// ---- ［採用を決める］（2026-11-30）: 確認の窓（役割・所属店舗＝いまの画面が聞いている項目と同じ）→ 採用 ---------------------------------
//   採用にするのは recruit-action の hire（既存の採用の処理を、そのまま呼ぶ）。権限・雇用区分・社員採用は社長だけ・スイッチ・同じ鍵・古い値の照合は、RPC が確かめる。
//   招待リンクは、Slack には出さない（LINE と連携していれば、送信箱を通して本人へ。未連携なら、管理画面の「リンクを送る」から）。
const ROLE_LABEL: Record<string, string> = { AL: "アルバイト", SHAIN: "社員", TENCHO: "店長", TEAM: "チーム長", HQ: "本部" };
const KIND_LABEL: Record<string, string> = { part: "アルバイト・パート", employee: "社員" };
type HireMeta = LineMeta & { exp_status: string | null; linked: boolean };

/** カードの［採用を決める］が押されたとき: 権限・雇用区分・スイッチを確かめて、確認の窓を返す。決められないときは、押した人だけに理由 */
export async function hireOpen(deps: RecruitDeps, _actor: RecruitActor, value: { applicant_id?: unknown; notification_id?: unknown }, place: Place = {}): Promise<RecruitOutcome> {
  const applicantId = value?.applicant_id;
  if (!isUuid(applicantId)) return { kind: "ephemeral", text: "応募者の番号が読めませんでした。カードを更新してから、もう一度押してください。" };
  if (!deps.action || !(await deps.actionsEnabled())) return { kind: "ephemeral", text: OFF_TEXT };
  const r = await deps.action({ op: "hire_info", applicant_id: applicantId });
  if (!r?.ok || r.can !== true) return { kind: "ephemeral", text: refusal(r) };
  const roles: string[] = (Array.isArray(r.roles) ? r.roles : []).filter((x: unknown) => typeof x === "string" && ROLE_LABEL[x as string]);
  const stores: { id: string; name: string }[] = (Array.isArray(r.stores) ? r.stores : []).filter((s: { id?: unknown; name?: unknown }) => isUuid(s?.id) && typeof s?.name === "string" && s.name).slice(0, 100);
  if (!roles.length || !stores.length) return { kind: "ephemeral", text: "役割または店舗の一覧が読めませんでした。管理画面から操作してください。" };
  const meta: HireMeta = { applicant_id: applicantId, notification_id: isUuid(value?.notification_id) ? value.notification_id : null, name: String(r.name ?? ""), channel_id: strOrNull(place.channel_id), thread_ts: strOrNull(place.thread_ts),
    exp_status: strOrNull(r.status), linked: r.linked === true };
  const role0 = roles.includes(r.default_role) ? r.default_role : roles[0], store0 = stores.find((s) => s.id === r.store_id);
  const sOpt = (s: { id: string; name: string }) => opt(clean(s.name, 60), s.id);
  const blocks: unknown[] = [
    { type: "section", text: { type: "mrkdwn", text: `*${clean(meta.name, 30)}* さんを *採用* にします（区分：${KIND_LABEL[String(r.kind)] ?? "—"}）。\n採用にすると、入社登録の招待リンクが発行され、本人が入社登録に進めるようになります。` } },
    { type: "input", block_id: "role", label: plain("役割"), element: { type: "static_select", action_id: "role", initial_option: opt(ROLE_LABEL[role0], role0), options: roles.map((x) => opt(ROLE_LABEL[x], x)) } },
    { type: "input", block_id: "stores", label: plain("所属店舗"), element: { type: "multi_static_select", action_id: "stores", placeholder: plain("選んでください"), ...(store0 ? { initial_options: [sOpt(store0)] } : {}), options: stores.map(sOpt) } },
  ];
  if (meta.linked) blocks.push({ type: "input", optional: true, block_id: "notify", label: plain("招待リンク"), element: { type: "checkboxes", action_id: "notify", initial_options: [opt("LINE で本人に送る", "yes")], options: [opt("LINE で本人に送る", "yes")] } });
  else blocks.push({ type: "context", elements: [{ type: "mrkdwn", text: "この応募者は LINE と連携していないため、招待リンクは、ここからは送れません。採用のあと、管理画面の「リンクを送る」から送ってください。" }] });
  blocks.push({ type: "context", elements: [{ type: "mrkdwn", text: `${r.mode !== "live" && meta.linked ? DRY_NOTE + "\n" : ""}不採用・辞退・採用の取り消しは、管理画面から行ってください。` }] });
  return { kind: "modal", view: { type: "modal", callback_id: HIRE_MODAL, private_metadata: JSON.stringify(meta), title: plain("採用の確認"), submit: plain("採用にする"), close: plain("やめる"), blocks } };
}

/** 確認の窓の［採用にする］: 窓を閉じ、そのあとで recruit-action の hire を 1 回だけ呼ぶ（依頼の鍵＝窓の番号。見ていた値＝窓を開いたときの状態） */
// deno-lint-ignore no-explicit-any
export async function hireSubmit(deps: RecruitDeps, _actor: RecruitActor, view: any): Promise<RecruitOutcome> {
  const b = readMeta(view);
  let exp: string | null = null, linked = false;
  try { const m = JSON.parse(view?.private_metadata ?? "{}") ?? {}; exp = strOrNull(m.exp_status); linked = m.linked === true; } catch (_e) { /* 下で、読めないとして扱う */ }
  const root = strOrNull(view?.root_view_id) ?? strOrNull(view?.id);
  const place: Place = { channel_id: b?.channel_id, thread_ts: b?.thread_ts };
  if (!b || !root || !deps.action) return { kind: "clear", after: async () => { await deps.tell?.(place, "採用にしていません（窓の情報が読めませんでした）。もう一度、カードのボタンから開いてください。"); } };
  const v = view?.state?.values ?? {};
  const role = v.role?.role?.selected_option?.value;
  const stores: string[] = (v.stores?.stores?.selected_options ?? []).map((o: { value?: string }) => o?.value).filter(isUuid);
  if (typeof role !== "string" || !ROLE_LABEL[role]) return { kind: "errors", errors: { role: "役割を選んでください。" } };
  if (!stores.length) return { kind: "errors", errors: { stores: "所属店舗を、1 つ以上選んでください。" } };
  const notify = linked && (v.notify?.notify?.selected_options ?? []).some((o: { value?: string }) => o?.value === "yes");
  const action = deps.action;
  return { kind: "clear", after: async () => {
    // deno-lint-ignore no-explicit-any
    let r: any;
    try { r = await action({ op: "hire", applicant_id: b.applicant_id, role, store_ids: stores, notify, request_key: `slack:hire:${root}`, expected: { status: exp } }); }
    catch (e) { r = { ok: false, code: "error", message: "入口を呼べませんでした: " + String((e as Error)?.message ?? e).slice(0, 100) }; }
    const n = clean(b.name, 30), st = String(r?.invite?.status ?? "");
    const inv = st === "sent" ? "招待リンクを、LINE で本人に送りました。" : st === "dry" || st === "dry_done" ? "🧪 招待リンクは試しモード（本人には届いていません）。" : st === "skipped_unlinked" ? "招待リンクは送っていません（LINE 未連携）。管理画面の「リンクを送る」から送ってください。"
      : st === "skipped_off" ? "招待リンクは送っていません。管理画面の「リンクを送る」から送れます。" : st === "duplicate" || st === "duplicate_recent" ? "同じ招待を、すでに送っています。" : "⚠️ 招待リンクの LINE は送れていません（自動では再送しません）。管理画面の「リンクを送る」から送ってください。";
    await deps.tell?.(place, r?.code === "done" ? `🎉 ${n} さんを採用にしました（役割：${ROLE_LABEL[role]}）。${inv}`
      : r?.code === "noop" || r?.code === "replayed" ? `ℹ️ ${String(r?.message ?? "すでに採用済みです")}`
      : r?.code === "conflict" ? `⚠️ ${n} さんの状態が、先に変更されています。何も変えていません。カードを確かめて、もう一度開いてください。` : `⚠️ ${n} さんは、採用にしていません: ${refusal(r)}`);
  } };
}
