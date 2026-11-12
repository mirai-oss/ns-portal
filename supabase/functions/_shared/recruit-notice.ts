// =============================================================
// 採用管理の Slack 通知（2026-11-16 下書き・本番未適用）
//   決定（2026-11-12 ユーザー）: 応募者 1 人につき親メッセージは 1 件だけ。以後の出来事（面接・結果・採用・辞退・やり取り）は、その親のスレッドで管理する。
//   親     = 1 行（👤 採用管理｜氏名｜応募店舗｜短い状態）＋［詳細を確認］。状態が変わったら、同じ親を書き換える（新しい親は作らない）。
//   スレッド = 1 通目に「概要のカード」（状態・媒体・面接・担当。状態が変わるたびに同じカードを書き換える）。2 通目からは時系列の返信。
//   電話番号・メールアドレスは出さない（管理画面へのリンクから見る）。応募者のメッセージ本文は、長さを切り、電話・メールらしい文字列を伏せる。
//
//   共通の作り（勤怠確認と同じ）を使う: 控え＝notice_cases（type_key=recruit, ref_table=applicants, ref_id=応募者 ID）／送信＝notify-slack。
//   前半は「文面を組み立てるだけ」（DB にも Slack にも触らない）。後半は「読んで・組み立てて・送る」（db と notify を外から受け取る）。
//   設計: scratchpad rc1/設計_採用管理のSlack通知.md
// =============================================================
import type { StatusCode } from "./notice-blocks.ts";

export const NOTICE_TYPE = "recruit";
export const REF_TABLE = "applicants";
export const NIPPO_URL = "https://mirai-oss.github.io/nippo/";
const USERNAME = "採用管理", ICON = ":bust_in_silhouette:";
// リンクのボタンの action_id: slack-interact は「hr.onboarding.link」で始まるものを「何もしない」で受ける（既存の作り。slack-interact を変えずに済む）
const LINK_ACTION = "hr.onboarding.link.recruit";

// ---- 1. 文面（純粋な関数） ---------------------------------------------------------
/** 選考中（管理画面の APPLICANT_ACTIVE と同じ） */
export const ACTIVE = ["new", "contacted", "interview_set", "interviewed"];
/** 管理画面（nippo index.html の APPLICANT_STATUS）と同じ並び。バックレは Slack では「連絡なし」と書く */
export const STATUS_LABEL: Record<string, string> = {
  new: "新規", contacted: "連絡済み", interview_set: "面接設定", interviewed: "面接済み", hired: "採用", retired: "退職", noshow: "連絡なし", rejected: "不採用", declined: "辞退",
};
export const SOURCE_LABEL: Record<string, string> = { form: "フォーム", indeed: "Indeed", manual: "手動登録", csv: "CSV", referral: "紹介", line: "LINE" };
const EXIT_STAGE: Record<string, string> = { before_interview: "面接前", interview: "面接", after_hire: "採用後", during_registration: "入社登録中", first_shift: "初回勤務" };
const EXIT_REASON: Record<string, string> = {
  interview_noshow: "面接に来なかった", declined_before_interview: "面接前に辞退", no_contact_after_hire: "採用後に連絡がつかない", dropped_during_registration: "入社登録の途中で離脱",
  first_shift_noshow: "初回勤務に来なかった", declined_before_start: "入社前に辞退", company_reason: "会社の都合で中止", other: "その他",
};
const WD = ["日", "月", "火", "水", "木", "金", "土"];

/** 1 行の中に入れる文字（氏名・店舗名など）: 改行・区切り・Slack の記法になる文字を除く */
export const clean = (s: unknown, max = 40) => String(s ?? "").replace(/[\n\r|｜<>]/g, " ").replace(/&/g, "＆").replace(/\s+/g, " ").trim().slice(0, max) || "—";
/** Slack の記法として解釈されないようにする（<!channel> やリンクを作らせない） */
export const escapeMrkdwn = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
// 全角の数字・＠・＋だけ半角にする（カタカナの長音「ー」などは変えない。電話番号の区切りとしては、下の正規表現の側で受ける）
const toHalf = (s: string) => s.replace(/[０-９＠＋]/g, (c) => String.fromCharCode(c.charCodeAt(0) - 0xfee0));
const SEP = "[-\\s().（）－ー―‐]";

/** 電話番号・メールアドレスらしい文字列を伏せる（全角の数字は半角にしてから見る） */
export function maskPII(s: string): string {
  return toHalf(String(s ?? ""))
    .replace(/[A-Za-z0-9._%+-]+\s*@\s*[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+/g, "（メールアドレス）")
    .replace(new RegExp(`(?<!\\d)[（(]?(?:\\+81${SEP}?\\d|0\\d)(?:${SEP}{0,2}\\d){8,10}(?!\\d)`, "g"), "（電話番号）");
}
/** メッセージ本文の抜き出し: 個人情報を伏せ、改行を詰め、長さを切る。max が 0 以下なら本文は出さない */
export function excerpt(body: unknown, max = 200): string {
  if (max <= 0) return "（本文は管理画面で確認してください）";
  const t = maskPII(String(body ?? "")).replace(/\s+/g, " ").trim();
  if (!t) return "（本文なし）";
  return escapeMrkdwn(t.length > max ? t.slice(0, max) + "…（続きは管理画面で）" : t);
}
const jst = (iso: string | null | undefined) => { const t = iso ? new Date(iso).getTime() : NaN; return Number.isFinite(t) ? new Date(t + 9 * 3600e3) : null; };
/** 日時（M/D HH:MM・日本時間） */
export function whenJst(iso: string | null | undefined): string {
  const j = jst(iso);
  return j ? `${j.getUTCMonth() + 1}/${j.getUTCDate()} ${String(j.getUTCHours()).padStart(2, "0")}:${String(j.getUTCMinutes()).padStart(2, "0")}` : "—";
}
/** 面接の日時（M/D（曜）HH:MM・日本時間） */
export function dayJst(iso: string | null | undefined): string {
  const j = jst(iso);
  return j ? `${j.getUTCMonth() + 1}/${j.getUTCDate()}（${WD[j.getUTCDay()]}）${String(j.getUTCHours()).padStart(2, "0")}:${String(j.getUTCMinutes()).padStart(2, "0")}` : "—";
}
/** 短い印（変わったかどうかを比べるためだけ。元の文字列には戻せない） */
export function sig(s: string): string {
  let h = 5381;
  for (let i = 0; i < s.length; i++) h = ((h << 5) + h + s.charCodeAt(i)) >>> 0;
  return h.toString(16);
}
/** 鍵の文字列から、いつも同じ UUID を作る（台帳の番号に使う。同じ出来事のやり直しが、同じ台帳の行に当たるようにする） */
export async function uuidFrom(key: string): Promise<string> {
  const b = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(key))).slice(0, 16);
  b[6] = (b[6] & 0x0f) | 0x50; b[8] = (b[8] & 0x3f) | 0x80;
  const h = [...b].map((x) => x.toString(16).padStart(2, "0")).join("");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}
const mention = (ids: (string | null | undefined)[]) => [...new Set(ids.filter((x): x is string => /^[UW][A-Z0-9]{6,}$/.test(String(x ?? ""))))].map((x) => `<@${x}>`).join(" ");

/** 応募者の行（applicants）。ここで使う列だけ。電話・メール・回答の中身は、文面には使わない */
export type Applicant = {
  id: string; name?: string | null; source?: string | null; job_type?: string | null; status?: string | null; store_id?: string | null; assignee_id?: string | null; user_id?: string | null;
  applied_at?: string | null; status_changed_at?: string | null; interview_at?: string | null; interview_mode?: string | null; interview_place?: string | null; interview_prefs?: unknown; interview_set_by?: string | null;
  handled_at?: string | null; handled_by?: string | null; hired_at?: string | null; exit_stage?: string | null; exit_reason?: string | null;
  last_msg_at?: string | null; last_msg_dir?: string | null; last_actor_id?: string | null; form_received_at?: string | null; line_linked_at?: string | null;
  answers?: Record<string, unknown> | null; indeed_url?: string | null;
};
export type Onboarding = { id: string; status?: string | null; user_id?: string | null; slack_channel_id?: string | null; slack_parent_ts?: string | null };
export type Cfg = { enabled: boolean; since: string | null; channelKey: string; bodyChars: number };

const ms = (iso: string | null | undefined) => { const t = iso ? new Date(iso).getTime() : NaN; return Number.isFinite(t) ? t : 0; };
const prefsOf = (a: Applicant): unknown[] => (Array.isArray(a.interview_prefs) ? a.interview_prefs : []);
/** 未対応: 選考中で、最後のやり取りが「応募者から」のまま。対応済みにしたあとに新しく届いたら、また未対応（管理画面の rcWaiting のメッセージの部分と同じ） */
export function waitingOf(a: Applicant): boolean {
  if (!ACTIVE.includes(String(a.status ?? ""))) return false;
  if (a.last_msg_dir !== "in" || !a.last_msg_at) return false;
  return !(a.handled_at && ms(a.handled_at) >= ms(a.last_msg_at));
}
/** 面接日を 12 時間過ぎても選考中のまま（管理画面の rcOverdue と同じ） */
export const overdueOf = (a: Applicant, now: number) => ACTIVE.includes(String(a.status ?? "")) && !!a.interview_at && ms(a.interview_at) < now - 12 * 3600e3;

/** 親に出す短い状態。label が null のときは、親に状態を付けない（応募受付のまま） */
export function stateOf(a: Applicant, moved: boolean): { label: string | null; code: StatusCode; done: boolean } {
  const s = String(a.status ?? "new");
  const scheduling = !a.interview_at && prefsOf(a).length > 0;
  switch (s) {
    case "new": return a.interview_at ? { label: "面接確定", code: "doing", done: false } : scheduling ? { label: "面接調整中", code: "doing", done: false } : { label: null, code: "todo", done: false };
    case "contacted": return { label: a.interview_at ? "面接確定" : "面接調整中", code: "doing", done: false };
    case "interview_set": return { label: a.interview_at ? "面接確定" : "面接調整中", code: "doing", done: false };
    case "interviewed": return { label: "面接済み・結果待ち", code: "waiting", done: false };
    case "hired": return { label: moved ? "採用決定・入社登録へ移行済み" : "採用決定", code: "done", done: true };
    case "rejected": return { label: "不採用", code: "done", done: true };
    case "declined": return { label: "辞退", code: "done", done: true };
    case "noshow": return { label: "連絡なし", code: "done", done: true };
    case "retired": return { label: "退職", code: "done", done: true };
    default: return { label: clean(s, 12), code: "doing", done: false };
  }
}

export type View = {
  id: string; name: string; storeId: string | null; storeName: string | null; source: string | null; jobType: string | null; appliedAt: string | null;
  status: string; label: string | null; code: StatusCode; done: boolean;
  interviewAt: string | null; interviewMode: string | null; interviewPlace: string | null; prefsN: number; prefsSig: string;
  assigneeId: string | null; assigneeName: string | null; actorName: string | null; handledAt: string | null; handledByName: string | null; interviewSetByName: string | null;
  waiting: boolean; overdue: boolean; needSchedule: boolean; lastMsgAt: string | null; lastMsgDir: string | null;
  exitStage: string | null; exitReason: string | null; formAt: string | null; lineAt: string | null; reapplySig: string | null;
  userId: string | null; onboarding: Onboarding | null; onboardingLink: string | null; moved: string | null;
};
export function viewOf(a: Applicant, c: { storeName?: string | null; names?: Record<string, string>; onboarding?: Onboarding | null; onboardingLink?: string | null; now: number }): View {
  const nm = (id: string | null | undefined) => (id ? c.names?.[id] ?? null : null);
  const onb = c.onboarding && c.onboarding.status !== "cancelled" ? c.onboarding : null;
  const moved = onb ? onb.id : a.user_id ? "user" : null;   // 入社登録へ進んだ印（入社ワークフローの id。まだ無ければ、本人のアカウントができた印）
  const st = stateOf(a, !!moved);
  const waiting = waitingOf(a), overdue = overdueOf(a, c.now);
  const ans = (a.answers ?? {}) as Record<string, unknown>;
  // Indeed からの再応募を見分ける印（求人・勤務地・返信用の宛先が変わったか）。中身そのものは控えに残さない
  const reapply = a.source === "indeed" || ans["Indeed連絡先"] ? sig([ans["求人"], ans["勤務地"], ans["店舗"], ans["Indeed連絡先"], a.indeed_url].map((x) => String(x ?? "")).join("|")) : null;
  const prefs = prefsOf(a);
  return {
    id: a.id, name: clean(a.name, 30), storeId: a.store_id ?? null, storeName: c.storeName ?? null, source: a.source ?? null, jobType: a.job_type ?? null, appliedAt: a.applied_at ?? null,
    status: String(a.status ?? "new"), label: st.label, code: waiting || overdue ? "alert" : st.code, done: st.done,
    interviewAt: a.interview_at ?? null, interviewMode: a.interview_mode ?? null, interviewPlace: a.interview_place ?? null, prefsN: prefs.length, prefsSig: prefs.length ? sig(JSON.stringify(prefs)) : "",
    assigneeId: a.assignee_id ?? null, assigneeName: nm(a.assignee_id), actorName: nm(a.last_actor_id), handledAt: a.handled_at ?? null, handledByName: nm(a.handled_by), interviewSetByName: nm(a.interview_set_by),
    waiting, overdue, needSchedule: ACTIVE.includes(String(a.status ?? "")) && !a.interview_at && prefs.length > 0, lastMsgAt: a.last_msg_at ?? null, lastMsgDir: a.last_msg_dir ?? null,
    exitStage: a.exit_stage ?? null, exitReason: a.exit_reason ?? null, formAt: a.form_received_at ?? null, lineAt: a.line_linked_at ?? null, reapplySig: reapply,
    userId: onb?.user_id ?? a.user_id ?? null, onboarding: onb, onboardingLink: c.onboardingLink ?? null, moved,
  };
}

const interviewText = (at: string | null, mode: string | null, place: string | null) =>
  at ? `${dayJst(at)}${mode === "onsite" ? `・対面${place ? `（${clean(place, 30)}）` : ""}` : mode === "online" ? "・オンライン" : ""}` : "未定";
/** 対応が要る印（親とカードに出す）。無ければ null */
export const attentionOf = (v: Pick<View, "waiting" | "overdue">) => (v.waiting ? "未対応" : v.overdue ? "面接結果の入力待ち" : null);
/** 親の変わらない部分: 👤 採用管理｜氏名｜応募店舗 */
export const parentTitle = (v: Pick<View, "name" | "storeName">) => `👤 採用管理｜${clean(v.name, 30)}｜${v.storeName ? clean(v.storeName, 20) : "店舗未設定"}`;
const linkButton = (text: string, url: string, id: string, key = "") => ({ type: "button", text: { type: "plain_text", text, emoji: true }, action_id: LINK_ACTION + key, url, value: JSON.stringify({ applicant_id: id }) });

/**
 * 親メッセージ（1 行）。例: 👤 採用管理｜山田太郎｜鳥一代 本店｜面接調整中
 * 未対応・面接結果の入力待ちのときだけ、後ろに「🔴未対応（担当 佐藤）」を付ける。電話・メール・本文・履歴は出さない。
 * 「詳細を確認」は、スレッドの 1 通目（カード）を開くリンクのボタン（リンクが取れなければ付けない）。
 */
export function parentMessage(v: View, o: { permalink?: string | null } = {}): { text: string; blocks: unknown[] } {
  const att = attentionOf(v);
  const text = `${parentTitle(v)}${v.label ? `｜${v.label}` : ""}${att ? `｜🔴${att}（担当 ${v.assigneeName ? clean(v.assigneeName, 20) : "未定"}）` : ""}`;
  const blocks: unknown[] = [{ type: "section", text: { type: "mrkdwn", text } }];
  if (o.permalink) blocks.push({ type: "actions", block_id: "recruit_open", elements: [linkButton("詳細を確認", o.permalink, v.id, "_thread")] });
  return { text, blocks };
}

/** スレッドの 1 通目「概要のカード」。状態が変わるたびに、同じメッセージを書き換える。押せるのはリンクのボタンだけ（Slack から状態は変えない） */
export function cardMessage(v: View): { text: string; blocks: unknown[] } {
  const att = attentionOf(v);
  const src = SOURCE_LABEL[String(v.source ?? "")] ?? clean(v.source, 12);
  const lines = [
    `*【採用管理】${clean(v.name, 30)}*`,
    `状態：${v.label ?? "応募受付"}${att ? `　🔴${att}` : ""}`,
    `応募店舗：${v.storeName ? clean(v.storeName, 30) : "店舗未設定"}`,
    `応募媒体：${src}${v.jobType ? `（${clean(v.jobType, 40)}）` : ""}`,
    `応募日時：${whenJst(v.appliedAt)}`,
    `面接：${interviewText(v.interviewAt, v.interviewMode, v.interviewPlace)}${v.needSchedule ? `（希望日時 ${v.prefsN} 件あり → 日程の確定をお願いします）` : ""}`,
    `担当：${v.assigneeName ? clean(v.assigneeName, 20) : "未定"}`,
  ];
  if (v.lastMsgAt) lines.push(`やり取り：最後は${v.lastMsgDir === "in" ? "応募者から" : "こちらから"}（${whenJst(v.lastMsgAt)}）`);
  if (v.exitReason) lines.push(`離脱の記録：${EXIT_STAGE[String(v.exitStage ?? "")] ?? "—"}・${EXIT_REASON[v.exitReason] ?? "その他"}`);
  if (v.moved) lines.push(v.onboarding ? "入社登録：✅ 入社登録へ移行済み（以降の手続きは、入社登録のスレッドで進めます）" : "入社登録：✅ 本人の登録が済みました");
  const blocks: unknown[] = [
    { type: "section", text: { type: "mrkdwn", text: lines.join("\n") } },
    { type: "context", elements: [{ type: "mrkdwn", text: "電話番号・メールアドレス・回答の内容は Slack に出しません。管理画面で確認してください。" }] },
  ];
  const btns: unknown[] = [linkButton("管理画面で開く", `${NIPPO_URL}?a=${v.id}`, v.id)];
  if (v.onboardingLink) btns.push(linkButton("入社登録のスレッド", v.onboardingLink, v.id, "_onb"));
  if (v.moved && v.userId) btns.push(linkButton("従業員ページ", `${NIPPO_URL}?page=admin&u=${v.userId}`, v.id, "_user"));
  blocks.push({ type: "actions", block_id: "recruit_links", elements: btns });
  return { text: `【採用管理】${clean(v.name, 30)}｜${v.label ?? "応募受付"}`, blocks };
}

/** 応募者とのやり取り 1 通ぶん（スレッドへの返信）。本文は、伏せて・切って・引用の形で出す */
export function messageLine(m: Msg, o: { bodyChars: number; staffName?: string | null }): string {
  const ch = SOURCE_LABEL[String(m.channel ?? "")] ?? clean(m.channel, 10);
  const head = m.direction === "in" ? `💬 応募者から（${ch}・${whenJst(m.sent_at)}）` : `↩️ こちらから（${ch}${o.staffName ? `・${clean(o.staffName, 20)}` : ""}・${whenJst(m.sent_at)}）`;
  return `${head}\n> ${excerpt(m.body, o.bodyChars)}`;
}

/** スレッドの最初の返信（応募受付）。fresh=いま届いた応募／そうでなければ、前からいる応募者のスレッドを作り始めたとき */
export function openLine(v: View, fresh: boolean): string {
  const src = SOURCE_LABEL[String(v.source ?? "")] ?? clean(v.source, 12);
  if (!fresh) return `🗂 このスレッドで管理を始めます（応募 ${whenJst(v.appliedAt)}・${src}・いまの状態: ${v.label ?? "応募受付"}）`;
  return `📥 応募受付｜${src}｜${whenJst(v.appliedAt)}${v.needSchedule ? `\n📅 面接の希望日時が届いています（${v.prefsN} 件）。日程の確定をお願いします。` : ""}`;
}

/** 控えに残す「前回の状態」。次の出来事で、これと比べて変わったところだけをスレッドに書く */
export type Snap = {
  status: string; label: string | null; iv: string | null; ivText: string; asg: string | null; asgName: string | null; store: string | null; storeName: string | null;
  waiting: boolean; overdue: boolean; prefs: string; form: string | null; line: string | null; reapply: string | null; exit: string | null; handled: string | null; moved: string | null;
};
export const snapOf = (v: View): Snap => ({
  status: v.status, label: v.label, iv: v.interviewAt, ivText: interviewText(v.interviewAt, v.interviewMode, v.interviewPlace), asg: v.assigneeId, asgName: v.assigneeName, store: v.storeId, storeName: v.storeName,
  waiting: v.waiting, overdue: v.overdue, prefs: v.prefsSig, form: v.formAt, line: v.lineAt, reapply: v.reapplySig, exit: v.exitReason, handled: v.handledAt, moved: v.moved,
});
export type Line = { kind: string; text: string; mention: boolean };
/**
 * 前回の状態と比べて、スレッドに足す行を作る（時系列の履歴）。
 * mention=true は「対応が要る出来事」だけ（再応募・希望日時が届いた・面接日を過ぎた・未対応のまま担当が替わった）。担当者が自分でした操作にはメンションしない。
 */
export function historyLines(prev: Snap, v: View): Line[] {
  const out: Line[] = []; const by = v.actorName ? `（操作: ${clean(v.actorName, 20)}）` : "";
  const sameT = (x: string | null, y: string | null) => ms(x) === ms(y);
  if (prev.form !== v.formAt && v.formAt && !sameT(prev.form, v.formAt)) out.push({ kind: "form", text: "📝 フォームの回答が届きました（すでに登録がある方の再応募を含みます）。", mention: true });
  if (prev.reapply && v.reapplySig && prev.reapply !== v.reapplySig) out.push({ kind: "reapply", text: `🔁 Indeed から、もう一度応募がありました${v.jobType ? `（求人: ${clean(v.jobType, 40)}）` : ""}。`, mention: true });
  if (prev.line !== v.lineAt && v.lineAt && !sameT(prev.line, v.lineAt)) out.push({ kind: "line", text: "💚 LINE が連携されました。", mention: false });
  if (prev.prefs !== v.prefsSig && v.needSchedule) out.push({ kind: "prefs", text: `📅 面接の希望日時が届いています（${v.prefsN} 件）。日程の確定をお願いします。`, mention: true });
  if (!sameT(prev.iv, v.interviewAt) || (v.interviewAt && prev.ivText !== interviewText(v.interviewAt, v.interviewMode, v.interviewPlace))) {
    const now = interviewText(v.interviewAt, v.interviewMode, v.interviewPlace); const who = v.interviewSetByName ?? v.actorName;
    out.push({ kind: "interview", mention: false, text: !v.interviewAt ? `📅 面接の日程を取り消しました${by}` : !prev.iv ? `📅 面接の日程が決まりました：${now}${who ? `（確定: ${clean(who, 20)}）` : ""}` : `📅 面接の日程を変更しました：${prev.ivText} → ${now}${by}` });
  }
  if (prev.status !== v.status) {
    const a = STATUS_LABEL[prev.status] ?? clean(prev.status, 12), b = STATUS_LABEL[v.status] ?? clean(v.status, 12);
    out.push({ kind: "status", mention: false, text: v.status === "hired" ? `🎉 採用が決まりました${by}。入社の手続きは、入社登録の流れで進めます。` : `🔄 状態：${a} → ${b}${by}` });
  }
  if (v.exitReason && prev.exit !== v.exitReason) out.push({ kind: "exit", mention: false, text: `📝 離脱の記録：${EXIT_STAGE[String(v.exitStage ?? "")] ?? "—"}・${EXIT_REASON[v.exitReason] ?? "その他"}` });
  if (!prev.moved && v.moved) {
    out.push({ kind: "moved", mention: false, text: v.onboarding
      ? `✅ 入社登録へ移行済みです。以降の手続き（賃金・交通費など）は、入社登録のスレッドで進めます${v.onboardingLink ? `： <${v.onboardingLink}|入社登録のスレッドを開く>` : "（管理画面の従業員ページから確認できます）"}`
      : "✅ 本人の入社登録（アカウントの作成）が済みました。" });
  }
  if (prev.store !== v.storeId) out.push({ kind: "store", mention: false, text: `🏪 応募店舗：${prev.storeName ? clean(prev.storeName, 20) : "店舗未設定"} → ${v.storeName ? clean(v.storeName, 20) : "店舗未設定"}${by}` });
  if (prev.asg !== v.assigneeId) out.push({ kind: "assignee", mention: !!v.assigneeId && (v.waiting || v.overdue || v.needSchedule), text: `👤 担当：${prev.asgName ? clean(prev.asgName, 20) : "未定"} → ${v.assigneeName ? clean(v.assigneeName, 20) : "未定"}${by}` });
  if (prev.waiting && !v.waiting && v.handledAt && !sameT(prev.handled, v.handledAt)) out.push({ kind: "handled", mention: false, text: `✅ 対応済みにしました${v.handledByName ? `（${clean(v.handledByName, 20)}）` : ""}` });
  if (!prev.waiting && v.waiting && prev.handled && !v.handledAt) out.push({ kind: "unhandled", mention: false, text: `↩️ 未対応に戻しました${by}` });
  if (!prev.overdue && v.overdue) out.push({ kind: "overdue", mention: true, text: `⏰ 面接日（${dayJst(v.interviewAt)}）を過ぎています。面接の結果（状態）を入れてください。` });
  return out;
}

// ---- 2. 読んで・組み立てて・送る ---------------------------------------------------
export type Msg = { id: string; channel?: string | null; direction?: string | null; body?: string | null; sent_at?: string | null; sent_by?: string | null };
/** 控え（notice_cases.slack_refs）に入れているもの */
export type Refs = {
  parent?: string; card?: string; ts?: string; channel_key?: string; channel_id?: string | null; permalink?: string | null; title?: string; opened_at?: string;
  parent_sig?: string; card_sig?: string; snap?: Snap; seq?: number; retry?: boolean; onb_ts?: string | null; onb_link?: string | null;
  merged_from?: { id: string; mode: string; at?: string }[]; merged_done?: string[]; merged_into?: string; merged_shown?: boolean; tombstone?: boolean;
};
export type NotifyResult = { ok?: boolean; notification_id?: string; ts?: string; slack_channel_id?: string; status?: string; error?: string } | null;
export type Notify = (body: Record<string, unknown>) => Promise<NotifyResult>;
/** DB と Slack の読み書き（Edge Function が本物を、テストがにせものを渡す） */
export type Db = {
  settings(): Promise<Cfg>;
  applicant(id: string): Promise<Applicant | null>;
  caseOf(id: string): Promise<{ refs: Refs } | null>;
  lock(id: string, token: string): Promise<boolean>;      // この応募者の処理を自分だけにする。取れなければ「やり直しの印」を付けて false
  unlock(id: string, token: string): Promise<boolean>;    // true=処理中に別の出来事が来た（もう一周する。処理の権利は持ったまま）
  claim(id: string): Promise<boolean>;                    // 親を作る権利。初めて（または、親が出ないまま時間がたった控えの取り直し）のときだけ true
  merge(keepId: string, mergedId: string): Promise<boolean>;   // 統合のあと、控えを残る側に寄せる（消える側の応募者の行が無くなっているときだけ。DB 側で確かめる）
  saveCase(id: string, patch: Record<string, unknown>): Promise<string | null>;
  names(ids: string[]): Promise<Record<string, string>>;
  storeName(id: string): Promise<string | null>;
  onboarding(applicantId: string): Promise<Onboarding | null>;
  messages(applicantId: string, sinceIso: string, extraId?: string | null): Promise<Msg[]>;
  delivered(keys: string[]): Promise<Set<string>>;        // すでに Slack に出した鍵（台帳 notification_deliveries で確かめる）
  mentions(scene: string, storeId: string | null, assignees: string[] | null): Promise<string[]>;   // Slack のユーザー ID
  permalink(channelId: string, ts: string): Promise<string | null>;
};
export type EventOpts = { kind?: string; ref?: string | null; source?: string; now?: number };
export type SyncResult = { ok: boolean; skipped?: string; queued?: boolean; pending?: string; opened?: boolean; replies?: number; updated?: number; incomplete?: boolean; error?: string };

/**
 * 親（スレッド）を作るかどうか。
 *   切り替えのあとに届いた応募（CSV の取り込みを除く）は、いつも作る。
 *   切り替えより前からいる応募者は、動きがあったときだけ作る（応募者から返信が来て未対応／これから面接がある／切り替え後に採用が決まった／切り替え後にフォームの回答が届いた）。
 */
export function shouldOpen(a: Applicant, cfg: Cfg, now: number): boolean {
  const since = ms(cfg.since); if (!since) return false;
  if (a.source !== "csv" && ms(a.applied_at) >= since) return true;
  if (waitingOf(a) && ms(a.last_msg_at) >= since) return true;
  if (ACTIVE.includes(String(a.status ?? "")) && ms(a.interview_at) > now) return true;
  if (a.status === "hired" && ms(a.hired_at) >= since) return true;
  return ms(a.form_received_at) >= since;
}

const base = (source: string) => ({ source, username: USERNAME, icon_emoji: ICON });
const isUuid = (s: unknown) => typeof s === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s);

/**
 * 出来事 1 件の入口。応募者ごとに「処理の権利」を取ってから、いまの DB の状態に Slack を合わせる（何が起きたかではなく、いまの状態を見る＝同じ出来事が二度届いても、二度は書かない）。
 * 権利が取れなければ（同じ応募者を別の実行が処理中）、やり直しの印だけ付けて終わる。処理中の実行が、終わりぎわにその印を見て、もう一周する。
 */
export async function handleEvent(db: Db, notify: Notify, applicantId: string, o: EventOpts = {}): Promise<SyncResult> {
  if (!isUuid(applicantId)) return { ok: false, error: "applicant_id が正しくありません" };
  const cfg = await db.settings();
  if (!cfg.enabled || !cfg.since) return { ok: true, skipped: "disabled" };
  const now = o.now ?? Date.now();
  // 統合の知らせ: 消える側（ref）の控えを、残る側（この応募者）に寄せてから、いつもの処理をする
  if (o.kind === "merged" && isUuid(o.ref) && o.ref !== applicantId) await db.merge(applicantId, o.ref as string);
  const [a, cs] = await Promise.all([db.applicant(applicantId), db.caseOf(applicantId)]);
  // 親がまだ無く、作る条件にも当たらない（消えた応募者・前からいる応募者の小さな変更）→ 控えも作らない
  if (!cs?.refs?.ts && !(a && shouldOpen(a, cfg, now))) return { ok: true, skipped: a ? "not_opened" : "gone" };
  const token = crypto.randomUUID();
  if (!(await db.lock(applicantId, token))) return { ok: true, queued: true };
  let r: SyncResult = { ok: true };
  try {
    let again = false;
    for (let i = 0; i < 3; i++) {
      r = await syncOnce(db, notify, cfg, applicantId, { ...o, now });
      again = await db.unlock(applicantId, token);
      if (!again) break;
    }
    if (again) await db.saveCase(applicantId, { slack_refs: { retry: true } });   // 3 周しても出来事が続いている: 見回り（recruit_notice_sweep）に任せる
  } catch (e) {
    try { await db.unlock(applicantId, token); } catch (_e) { /* 権利は時間で切れる */ }
    try { await db.saveCase(applicantId, { slack_refs: { retry: true } }); } catch (_e) { /* 見回りが拾う */ }
    return { ok: false, error: String((e as Error)?.message ?? e).slice(0, 300) };
  }
  return r;
}

async function syncOnce(db: Db, notify: Notify, cfg: Cfg, id: string, o: EventOpts & { now: number }): Promise<SyncResult> {
  const source = o.source ?? "ef:recruit-notify";
  const [a, cs] = await Promise.all([db.applicant(id), db.caseOf(id)]);
  let refs: Refs = cs?.refs ?? {};
  if (!a) return await renderGone(db, notify, id, refs, source);
  if (refs.merged_into || refs.tombstone) return { ok: true, skipped: "closed" };

  // ---- 読み込み（氏名・店舗名・入社登録） ----
  const onb = await db.onboarding(id);
  const ids = [...new Set([a.assignee_id, a.handled_by, a.last_actor_id, a.interview_set_by].filter((x): x is string => !!x))];
  const [names, storeName] = await Promise.all([ids.length ? db.names(ids) : Promise.resolve({} as Record<string, string>), a.store_id ? db.storeName(a.store_id) : Promise.resolve(null)]);
  const patch: Refs = {};
  let onbLink: string | null = null;
  if (onb && onb.status !== "cancelled" && onb.slack_channel_id && onb.slack_parent_ts) {
    if (refs.onb_ts === onb.slack_parent_ts && refs.onb_link) onbLink = refs.onb_link;
    else { onbLink = await db.permalink(onb.slack_channel_id, onb.slack_parent_ts); if (onbLink) { patch.onb_ts = onb.slack_parent_ts; patch.onb_link = onbLink; } }
  }
  const v = viewOf(a, { storeName, names, onboarding: onb, onboardingLink: onbLink, now: o.now });
  const ref = { table: REF_TABLE, id };
  let replies = 0, updated = 0, incomplete = false, opened = false;

  // ---- 親が無ければ作る（権利を取れた実行だけ） ----
  if (!refs.ts) {
    if (!shouldOpen(a, cfg, o.now)) return { ok: true, skipped: "not_opened" };
    if (!(await db.claim(id))) return { ok: true, pending: "claimed_by_other" };
    const op = await openThread(db, notify, cfg, v, refs, source);
    if (!op.refs) return { ok: false, error: op.error ?? "open_failed" };
    refs = op.refs; opened = true; updated += op.updated;
  }
  const channelKey = refs.channel_key ?? cfg.channelKey;
  const reply = async (key: string, text: string, event: string) => {
    const r = await notify({ action: "send", notification_id: await uuidFrom(key), channel_key: channelKey, thread_ts: refs.ts, text, event, dedupe_key: key, ref, ...base(source) });
    if (r?.ok) { if (r.status !== "duplicate") replies++; return true; }
    incomplete = true; return false;
  };
  // メンション先: 担当者がいれば担当者／いなければ応募店舗の担当（notice_mention_rules の recruit）。相手が Slack と紐付いていなくても、ほかの人には広げない
  let who: string | null = null;
  const withMention = async (text: string) => {
    if (who === null) who = mention(await db.mentions(v.assigneeId ? "assignee" : v.storeId ? "open" : "no_store", v.storeId, v.assigneeId ? [v.assigneeId] : null));
    return who ? `${who}　${text}` : text;
  };

  // ---- 親とカードを、いまの状態に合わせる（変わったときだけ書き換える） ----
  const p = parentMessage(v, { permalink: refs.permalink ?? null }); const pSig = sig(JSON.stringify(p));
  if (pSig !== refs.parent_sig) {
    const r = await notify({ action: "update", notification_id: refs.parent, text: p.text, blocks: p.blocks });
    if (r?.ok) { patch.parent_sig = pSig; patch.title = parentTitle(v); updated++; } else incomplete = true;
  }
  const c = cardMessage(v); const cSig = sig(JSON.stringify(c));
  if (cSig !== refs.card_sig) {
    const r = await notify({ action: "update", notification_id: refs.card, text: c.text, blocks: c.blocks });
    if (r?.ok) { patch.card_sig = cSig; updated++; } else incomplete = true;
  }

  // ---- スレッドに足す行（応募受付／前回から変わったところ／応募者とのやり取り） ----
  const seq = refs.seq ?? 0;
  const pendingMerge = (refs.merged_from ?? []).filter((m) => !(refs.merged_done ?? []).includes(m.id));
  let lines: Line[] = [];
  if (opened) {
    const fresh = ms(a.applied_at) >= ms(cfg.since) && o.now - ms(a.applied_at) < 24 * 3600e3;
    lines = [{ kind: "open", text: openLine(v, fresh), mention: fresh && (a.source === "form" || a.source === "indeed") }];
  } else if (refs.snap && !pendingMerge.some((m) => m.mode === "moved")) lines = historyLines(refs.snap, v);   // 統合で控えが付け替わった直後は、前回の状態が別の応募のものなので比べない
  const todo: { key: string; text: string; event: string; mention: boolean; inbound: boolean }[] =
    lines.map((l) => ({ key: `recruit:${id}:h${seq}:${l.kind}`, text: l.text, event: `recruit_${l.kind}`, mention: l.mention, inbound: false }));
  // やり取りは、まだ出していないものだけ（台帳で確かめる）。
  //   どこから見るか: 切り替え後の応募は切り替えの時刻から／前からいる応募者は、スレッドを作った 1 時間前から（昔のやり取りを流し込まない）。出来事で渡されたメッセージは、時刻に関係なく見る
  const floor = new Date(ms(a.applied_at) >= ms(cfg.since) ? ms(cfg.since) : (ms(refs.opened_at) || o.now) - 3600e3).toISOString();
  const msgs = await db.messages(id, floor, o.kind === "message" && isUuid(o.ref) ? o.ref : null);
  if (msgs.length) {
    const key = (m: Msg) => `recruit:msg:${m.id}`;
    const done = await db.delivered(msgs.map(key));
    const rest = msgs.filter((m) => !done.has(key(m)));
    const need = [...new Set(rest.map((m) => m.sent_by).filter((x): x is string => !!x && !names[x]))];
    const staff = need.length ? await db.names(need) : {};
    for (const m of rest) {
      const inbound = m.direction === "in";
      todo.push({ key: key(m), text: messageLine(m, { bodyChars: cfg.bodyChars, staffName: m.sent_by ? names[m.sent_by] ?? staff[m.sent_by] ?? null : null }), event: inbound ? "recruit_message_in" : "recruit_message_out", mention: inbound, inbound });
    }
  }
  // メンションは 1 回の実行で 1 通だけ（応募者からのメッセージがあれば、その最初の 1 通。無ければ、対応が要る最初の行）
  const target = todo.find((t) => t.inbound) ?? todo.find((t) => t.mention);
  for (const t of todo) await reply(t.key, t === target ? await withMention(t.text) : t.text, t.event);

  // ---- 統合のお知らせ（同じ方の別の応募を、この応募にまとめたとき） ----
  const mergedDone = [...(refs.merged_done ?? [])];
  for (const m of pendingMerge) {
    let extra = "";
    if (m.mode === "closed") {
      const mc = await db.caseOf(m.id);
      if (mc?.refs?.ts) { await renderMerged(db, notify, m.id, mc.refs, refs, source); if (mc.refs.permalink) extra = `\n統合前のスレッド： <${mc.refs.permalink}|開く>`; }
    }
    if (await reply(`recruit:${id}:merge:${m.id}`, `🔀 同じ方の別の応募を、この応募にまとめました。以後は、このスレッドで管理します。${extra}`, "recruit_merged")) mergedDone.push(m.id);
  }

  // ---- 控えを残す（行を出し切れなかったときは、前回の状態を進めない＝次の実行が同じ行をもう一度試す。出せた行は台帳が覚えているので二重にならない） ----
  const err = await db.saveCase(id, {
    store_id: v.storeId ?? "", status_code: v.code, status_label: `${v.label ?? "応募受付"}${attentionOf(v) ? `・${attentionOf(v)}` : ""}`, assignees: v.assigneeId ? [v.assigneeId] : [],
    slack_refs: { ...patch, retry: incomplete, ...(mergedDone.length ? { merged_done: mergedDone } : {}), ...(incomplete ? {} : { snap: snapOf(v), seq: lines.length ? seq + 1 : seq }) },
  });
  if (err) return { ok: false, error: "case: " + err, opened, replies, updated };
  return { ok: !incomplete, opened, replies, updated, ...(incomplete ? { incomplete: true } : {}) };
}

/**
 * 親（1 行）→ スレッドの 1 通目にカード →（取れたら）親に「詳細を確認」→ 控えに ts を残す。
 * 台帳の番号と重複防止の鍵は、応募者 ID から決まる（やり直しても同じ番号・同じ鍵）。前の実行が親を出したあとで止まっていた場合、notify-slack は「送信済み」と答えて ts を返すので、親は増えない。
 */
async function openThread(db: Db, notify: Notify, cfg: Cfg, v: View, old: Refs, source: string): Promise<{ refs?: Refs; error?: string; updated: number }> {
  const ref = { table: REF_TABLE, id: v.id };
  const parentId = old.parent ?? await uuidFrom(`recruit:parent:${v.id}`), cardId = old.card ?? await uuidFrom(`recruit:card:${v.id}`);
  const p = parentMessage(v);
  const r1 = await notify({ action: "send", notification_id: parentId, channel_key: cfg.channelKey, text: p.text, blocks: p.blocks, event: "recruit_parent", dedupe_key: `recruit:parent:${v.id}`, ref, ...base(source) });
  if (!r1?.ok || !r1.ts) return { error: "parent_send_failed: " + String(r1?.error ?? ""), updated: 0 };
  const c = cardMessage(v);
  const sendCard = () => notify({ action: "send", notification_id: cardId, channel_key: cfg.channelKey, thread_ts: r1.ts, text: c.text, blocks: c.blocks, event: "recruit_card", dedupe_key: `recruit:card:${v.id}`, ref, ...base(source) });
  let r2 = await sendCard();
  if (!r2?.ok) r2 = await sendCard();
  if (!r2?.ok) return { error: "card_send_failed: " + String(r2?.error ?? ""), updated: 0 };
  const permalink = r1.slack_channel_id && r2.ts ? await db.permalink(r1.slack_channel_id, r2.ts) : null;
  const refs: Refs = { ...old, parent: parentId, card: cardId, ts: r1.ts, channel_key: cfg.channelKey, channel_id: r1.slack_channel_id ?? null, permalink, title: parentTitle(v), opened_at: new Date().toISOString(),
    parent_sig: sig(JSON.stringify(p)), card_sig: sig(JSON.stringify(c)) };
  const err = await db.saveCase(v.id, { store_id: v.storeId ?? "", status_code: v.code, slack_refs: refs });
  if (err) return { error: "case: " + err, updated: 0 };
  return { refs, updated: 0 };   // 「詳細を確認」のボタンは、このあとの「親をいまの状態に合わせる」で付く（リンクが取れたときだけ）
}

/** 応募者の行が無くなったとき（統合で消えた・管理画面で削除した）: 親とカードを「統合済み／削除済み」にして閉じる。親は消さない（履歴を残す） */
async function renderGone(db: Db, notify: Notify, id: string, refs: Refs, source: string): Promise<SyncResult> {
  if (!refs.ts) return { ok: true, skipped: "gone" };
  if (refs.merged_into) {
    const kc = await db.caseOf(refs.merged_into);
    return await renderMerged(db, notify, id, refs, kc?.refs ?? {}, source);
  }
  if (refs.tombstone) return { ok: true, skipped: "closed" };
  const title = refs.title ?? "👤 採用管理";
  const text = `${title}｜削除済み`;
  const r1 = await notify({ action: "update", notification_id: refs.parent, text, blocks: [{ type: "section", text: { type: "mrkdwn", text } }] });
  const body = "この応募者は、管理システムから削除されました。";
  const r2 = await notify({ action: "update", notification_id: refs.card, text: body, blocks: [{ type: "section", text: { type: "mrkdwn", text: body } }] });
  const ok = !!(r1?.ok && r2?.ok);
  // 親・カードの印を消しておく（あとで統合と分かって控えが付け替わったときに、必ず書き直すため）
  await db.saveCase(id, { status_code: "done", status_label: "削除済み", slack_refs: { tombstone: ok, retry: !ok, parent_sig: "", card_sig: "" } });
  return { ok, updated: 2 };
}

/** 統合で消えた側の親・カード・スレッド: 「統合済み」にして、統合先のスレッドへのリンクを出す（Slack のメッセージは別のスレッドへ移せないため、古いスレッドは残して閉じる） */
async function renderMerged(db: Db, notify: Notify, mergedId: string, mRefs: Refs, keepRefs: Refs, source: string): Promise<SyncResult> {
  if (mRefs.merged_shown || !mRefs.ts) return { ok: true, skipped: "closed" };
  const link = keepRefs.permalink ?? null;
  const text = `${mRefs.title ?? "👤 採用管理"}｜統合済み`;
  const btn = link ? [{ type: "actions", block_id: "recruit_open", elements: [linkButton("統合先のスレッド", link, mergedId, "_thread")] }] : [];
  const r1 = await notify({ action: "update", notification_id: mRefs.parent, text, blocks: [{ type: "section", text: { type: "mrkdwn", text } }, ...btn] });
  const body = "この応募は、同じ方の別の応募にまとめました。以後のやり取りは、統合先のスレッドで管理します。";
  const r2 = await notify({ action: "update", notification_id: mRefs.card, text: body, blocks: [{ type: "section", text: { type: "mrkdwn", text: body } }, ...btn] });
  const key = `recruit:${mergedId}:merged_into`;
  const r3 = await notify({ action: "send", notification_id: await uuidFrom(key), channel_key: mRefs.channel_key, thread_ts: mRefs.ts, text: `🔀 このスレッドは統合しました。${link ? `続きは <${link}|統合先のスレッド> へ。` : "続きは、統合先のスレッドで管理します。"}`,
    event: "recruit_merged", dedupe_key: key, ref: { table: REF_TABLE, id: mergedId }, ...base(source) });
  const ok = !!(r1?.ok && r2?.ok && r3?.ok);
  await db.saveCase(mergedId, { status_code: "done", status_label: "統合済み", slack_refs: { tombstone: ok, merged_shown: ok, retry: !ok } });
  return { ok, updated: 2 };
}
