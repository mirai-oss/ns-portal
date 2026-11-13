// =============================================================
// 採用管理: 共通の操作（recruit-action の中身。2026-11-27 下書き・本番未適用）
//   管理システムの画面・Slack・将来のアプリが、同じ処理を呼ぶ。ここは「順番」を持つ（DB の確認 → 外を呼ぶ → 結果の記録）。
//   DB・LINE・Slack の読み書きは外から受け取る（Edge Function が本物を、テストがにせものを渡す）。
//
//   守ること:
//     ・DB の変更は RPC だけ（recruit_send_begin / recruit_send_finish …）。権限・スイッチ・試しモード・二重の確認は、RPC（サーバー側）が決める。
//     ・LINE を呼ぶのは、RPC が code=send を返したときだけ（＝本番モード、かつ、送ってよい応募者）。それ以外は、どの道を通っても LINE を呼ばない。
//     ・失敗・結果不明は記録して、自動では再送しない。
//     ・返す値に、LINE の宛先・本文・電話・メールを入れない。
//   設計: docs/設計書_採用_面接確定とLINEのSlack操作_2026-11-13.md ／ DB 側: supabase/2026-11-27_recruit_outbox.sql
// =============================================================
import { clean, excerpt, sig, whenJst } from "./recruit-notice.ts";
import type { LineResult } from "./recruit-line.ts";
import type { GasConfig, MeetArgs, MeetResult } from "./recruit-calendar.ts";
import { interviewText } from "./recruit-interview-text.ts";

// deno-lint-ignore no-explicit-any
export type Rpc = (name: string, args: Record<string, unknown>) => Promise<{ data: any; error: { message: string } | null }>;
export type OpsDeps = {
  rpc: Rpc;
  /** LINE のチャネルアクセストークン（app_secrets.line_channel_token）。本番モードのときだけ読む */
  lineToken(): Promise<string>;
  /** LINE を 1 通送る（本物は _shared/recruit-line.ts の linePushOnce） */
  linePush(token: string, to: string, text: string, retryKey: string): Promise<LineResult>;
  /** その応募者の Slack のスレッドに 1 行足す（スレッドが無ければ何もしない。失敗しても処理は止めない）。key は重複防止の鍵（同じ鍵は 1 回だけ）。blocks＝ボタンつきの形 */
  threadNote(applicantId: string, key: string, text: string, blocks?: unknown[]): Promise<void>;
  /** 上と同じ投稿をして、結果を返す（sent＝出した／duplicate＝同じ鍵で、もう出してある／no_thread＝その応募者の親が無い／failed）。24 時間の未対応の知らせで使う */
  threadPost?(applicantId: string, key: string, text: string): Promise<"sent" | "duplicate" | "no_thread" | "failed">;
  /** すでに出した 1 行（鍵で指す）を、書き換える（ボタンを外す）。無ければ何もしない */
  noteUpdate?(key: string, text: string): Promise<void>;
  /** 利用者の氏名と、Slack の利用者 ID（紐づいていなければ null） */
  people?(ids: string[]): Promise<Record<string, { name: string | null; slack: string | null }>>;
  /** スレッドに出す本文の長さ（app_settings.recruit_slack.body_chars。既定 200・0 なら本文を出さない） */
  bodyChars(): Promise<number>;
  /** 面接の予定（GAS）。カレンダーが本番モードのときだけ使う。config＝app_secrets の gas_url / gas_key / gas_cal（無ければ null） */
  calendar?: {
    config(): Promise<GasConfig | null>;
    meet(cfg: GasConfig, a: MeetArgs): Promise<MeetResult>;
    remove(cfg: GasConfig, eventId: string): Promise<{ ok: boolean; why: string | null }>;
  };
};
export type OpsActor = { user_id: string; via: "slack" | "web" | "app" };
export type OpsResult = { ok: boolean; code: string; message?: string; status?: string; mode?: string; outbox_id?: string; replayed?: boolean; [k: string]: unknown };

const isUuid = (s: unknown): s is string => typeof s === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s);
const bad = (message: string): OpsResult => ({ ok: false, code: "bad_request", message });
const who = (name: unknown) => (typeof name === "string" && name ? clean(name, 20) : "不明");
const note = async (deps: OpsDeps, applicantId: string, key: string, text: string, blocks?: unknown[]) => { try { await deps.threadNote(applicantId, key, text, blocks); } catch (_e) { /* スレッドへの記録は、できなくても止めない */ } };
// ---- 失敗の知らせに付ける［もう一度］（2026-11-29）: 押すと slack-interact が受け、確かめの窓を出す。人が確かめてから、のときだけ動く ----
/** LINE の送信失敗・結果不明の行の［もう一度送る］／カレンダー登録の失敗の行の［もう一度登録］ */
export const RETRY_SEND_ACTION = "recruit.retry.send", RETRY_CAL_ACTION = "recruit.retry.calendar";
const withButton = (text: string, label: string, actionId: string, value: Record<string, unknown>) => [
  { type: "section", text: { type: "mrkdwn", text } },
  { type: "actions", block_id: "recruit_retry", elements: [{ type: "button", text: { type: "plain_text", text: label, emoji: true }, action_id: actionId, value: JSON.stringify(value) }] },
];
const sendNoteKey = (outboxId: string, status: string) => `recruit:outbox:${outboxId}:${status}`;
const sendFailText = (status: "failed" | "unknown", by: string, error: string | null) => status === "failed"
  ? `⚠️ LINE を送れませんでした（操作: ${by}）。応募者には届いていません。\n理由: ${clean(error ?? "不明", 160)}`
  : `⚠️ LINE を送れたか、確認できていません（操作: ${by}）。自動では再送しません。もう一度送る前に、応募者とのやり取りを確かめてください。`;

/** 送ってよいかの確認（窓を開く前に使う。何も書かない・何も送らない） */
export async function messageCheck(deps: OpsDeps, actor: OpsActor, b: { applicant_id?: unknown }): Promise<OpsResult> {
  if (!isUuid(b.applicant_id)) return bad("applicant_id が正しくありません");
  const { data, error } = await deps.rpc("recruit_send_check", { p_applicant: b.applicant_id, p_actor: actor.user_id });
  if (error) return { ok: false, code: "error", message: String(error.message).slice(0, 200) };
  return { ok: !!data?.ok, code: String(data?.code ?? "error"), message: data?.message ?? undefined, can_send: data?.can_send === true, linked: data?.linked === true,
    is_test: data?.is_test === true, send_enabled: data?.send_enabled === true, mode: data?.line_mode === "live" ? "live" : "dry", applicant_name: data?.applicant_name ?? null };
}

/**
 * 応募者へ 1 通送る。送信箱に入れる → （本番モードのときだけ）LINE を呼ぶ → 結果を記録する。
 *   成功: やり取りに「こちらから」が、送った人つきで 1 通入る（RPC）。Slack のスレッドには、既存の通知が「↩️ こちらから」を出す。
 *   試しモード・失敗・結果不明: やり取りには入らない。スレッドに、その旨を 1 行（ここから）。
 */
export async function messageSend(deps: OpsDeps, actor: OpsActor,
  b: { applicant_id?: unknown; text?: unknown; request_key?: unknown; purpose?: unknown; dedupe_key?: unknown }): Promise<OpsResult> {
  if (!isUuid(b.applicant_id)) return bad("applicant_id が正しくありません");
  const text = typeof b.text === "string" ? b.text.trim() : "";
  const key = typeof b.request_key === "string" ? b.request_key.trim() : "";
  if (!text) return bad("本文が空です");
  if (key.length < 8 || key.length > 200) return bad("request_key が正しくありません");
  const applicantId = b.applicant_id;
  const begin = await deps.rpc("recruit_send_begin", {
    p_applicant: applicantId, p_body: text, p_purpose: typeof b.purpose === "string" && b.purpose ? b.purpose : "reply", p_request_key: key,
    p_actor: actor.user_id, p_via: actor.via, p_dedupe_key: typeof b.dedupe_key === "string" && b.dedupe_key ? b.dedupe_key : null,
  });
  if (begin.error) return { ok: false, code: "error", message: String(begin.error.message).slice(0, 200) };
  const d = begin.data ?? {};
  const outboxId: string | undefined = isUuid(d.outbox_id) ? d.outbox_id : undefined;
  // 同じ依頼の 2 回目: 何も送らない。前の状態を返すだけ
  if (d.code === "replayed") return { ok: d.ok === true, code: "replayed", replayed: true, status: String(d.status ?? ""), mode: d.mode, outbox_id: outboxId, message: d.message };
  // 断られた（権限・スイッチ・未連携・二重など）: 何も送らない
  if (!d.ok) return { ok: false, code: String(d.code ?? "error"), message: d.message ?? "送れませんでした" };
  // 試しモード: LINE を呼ばない
  if (d.code === "dry") {
    if (outboxId) await note(deps, applicantId, `recruit:outbox:${outboxId}:dry`, `🧪 試しモード：LINE は送っていません（操作: ${who(d.actor_name)}）\n> ${excerpt(text, await deps.bodyChars())}`);
    return { ok: true, code: "dry", status: "dry_done", mode: "dry", outbox_id: outboxId, message: "試しモードのため、LINE は送っていません" };
  }
  // ここから先は、RPC が「送ってよい」と答えたときだけ（本番モード）
  if (d.code !== "send" || !outboxId || typeof d.to !== "string" || !d.to || typeof d.retry_key !== "string") return { ok: false, code: "error", message: "送信の準備ができませんでした" };
  let r: LineResult;
  try {
    r = await deps.linePush(await deps.lineToken(), d.to, String(d.text ?? text), d.retry_key);
  } catch (e) {
    r = { status: "unknown", http: null, error: "送信の処理が止まりました: " + String((e as Error)?.message ?? e).slice(0, 80), requestId: null };
  }
  const fin = await deps.rpc("recruit_send_finish", { p_outbox: outboxId, p_status: r.status, p_error: r.error, p_response: { http: r.http, request_id: r.requestId } });
  const by = who(d.actor_name);
  if (r.status === "sent") {
    if (fin.error || fin.data?.ok === false) {
      // LINE は受け付けたが、記録に失敗した: 成功したとは言い切らず、はっきり知らせる（送信箱は「送信中」のまま残り、あとで「結果不明」になる）
      await note(deps, applicantId, `recruit:outbox:${outboxId}:unrecorded`, `⚠️ LINE は送れましたが、記録に失敗しました（操作: ${by}）。もう一度は送らないでください。管理画面で、やり取りを確かめてください。`);
      return { ok: false, code: "sent_unrecorded", status: "sent", mode: "live", outbox_id: outboxId, message: "LINE は送れましたが、記録に失敗しました。もう一度は送らないでください" };
    }
    return { ok: true, code: "sent", status: "sent", mode: "live", outbox_id: outboxId, message: "LINE で送りました" };
  }
  // 失敗・結果不明: スレッドに 1 行と［もう一度送る］（同じ鍵は 1 回だけ＝同じ失敗の行は増えない）
  const text2 = sendFailText(r.status, by, r.error);
  await note(deps, applicantId, sendNoteKey(outboxId, r.status), text2, withButton(text2, "もう一度送る（確かめてから）", RETRY_SEND_ACTION, { applicant_id: applicantId, outbox_id: outboxId }));
  if (r.status === "failed") return { ok: false, code: "failed", status: "failed", mode: "live", outbox_id: outboxId, message: "LINE を送れませんでした: " + String(r.error ?? "不明").slice(0, 160) };
  return { ok: false, code: "unknown", status: "unknown", mode: "live", outbox_id: outboxId, message: "LINE を送れたか、確認できていません（自動では再送しません）" };
}

/** 送り直しの窓に出す材料（状態・宛先の氏名・本文）。本文は、RPC が権限を確かめた人にだけ返す。LINE の宛先は返さない */
export async function messageRetryInfo(deps: OpsDeps, actor: OpsActor, b: { outbox_id?: unknown }): Promise<OpsResult> {
  if (!isUuid(b.outbox_id)) return bad("outbox_id が正しくありません");
  const { data, error } = await deps.rpc("recruit_send_retry_info", { p_outbox: b.outbox_id, p_actor: actor.user_id });
  if (error) return { ok: false, code: "error", message: String(error.message).slice(0, 200) };
  return { ok: data?.ok === true, code: String(data?.code ?? "error"), message: data?.message ?? undefined, can_retry: data?.can_retry === true, status: data?.status, purpose: data?.purpose,
    applicant_id: data?.applicant_id, applicant_name: data?.applicant_name ?? null, body: typeof data?.body === "string" ? data.body : null, mode: data?.line_mode === "live" ? "live" : "dry" };
}

/**
 * LINE の送り直し（人が確かめてから）。失敗・結果不明の行を、同じ行・同じ再送の鍵で、もう一度送る（最初の送信が実は届いていた場合、LINE の側で二重にならない）。
 * 試しモードなら、何も送らない。成功したら、元の「送れませんでした」の行を書き換えて、ボタンを外す。もう一度失敗しても、同じ行は増やさない。
 */
export async function messageRetry(deps: OpsDeps, actor: OpsActor, b: { outbox_id?: unknown; request_key?: unknown }): Promise<OpsResult> {
  if (!isUuid(b.outbox_id)) return bad("outbox_id が正しくありません");
  const key = typeof b.request_key === "string" ? b.request_key.trim() : "";
  if (key.length < 8 || key.length > 200) return bad("request_key が正しくありません");
  const outboxId = b.outbox_id;
  const begin = await deps.rpc("recruit_send_retry_begin", { p_outbox: outboxId, p_request_key: key, p_actor: actor.user_id, p_via: actor.via });
  if (begin.error) return { ok: false, code: "error", message: String(begin.error.message).slice(0, 200) };
  const d = begin.data ?? {};
  if (d.code === "replayed") return { ok: false, code: "replayed", replayed: true, status: d.status, outbox_id: outboxId, message: d.message };
  if (!d.ok) return { ok: false, code: String(d.code ?? "error"), status: d.status, message: d.message ?? "送り直せませんでした" };
  if (d.code === "dry") return { ok: true, code: "dry", status: d.status, mode: "dry", outbox_id: outboxId, message: "試しモードのため、LINE は送っていません" };
  if (d.code !== "send" || typeof d.to !== "string" || !d.to || typeof d.retry_key !== "string" || typeof d.text !== "string") return { ok: false, code: "error", message: "送信の準備ができませんでした" };
  let r: LineResult;
  try { r = await deps.linePush(await deps.lineToken(), d.to, d.text, d.retry_key); }
  catch (e) { r = { status: "unknown", http: null, error: "送信の処理が止まりました: " + String((e as Error)?.message ?? e).slice(0, 80), requestId: null }; }
  const fin = await deps.rpc("recruit_send_finish", { p_outbox: outboxId, p_status: r.status, p_error: r.error, p_response: { http: r.http, request_id: r.requestId } });
  const by = who(d.actor_name);
  if (r.status === "sent") {
    if (fin.error || fin.data?.ok === false) return { ok: false, code: "sent_unrecorded", status: "sent", mode: "live", outbox_id: outboxId, message: "LINE は送れましたが、記録に失敗しました。もう一度は送らないでください" };
    for (const st of ["failed", "unknown"]) { try { await deps.noteUpdate?.(sendNoteKey(outboxId, st), `✅ LINE を送り直しました（操作: ${by}）。`); } catch (_e) { /* 書き換えは、できなくても止めない */ } }
    return { ok: true, code: "sent", status: "sent", mode: "live", outbox_id: outboxId, message: "LINE で送りました" };
  }
  // もう一度失敗・結果不明: 状態が前と違うときだけ、その状態の行が 1 つ増える（同じ状態なら、同じ鍵＝増えない）
  const applicantId = isUuid(d.applicant_id) ? d.applicant_id : null;
  const t2 = sendFailText(r.status, by, r.error);
  if (applicantId) await note(deps, applicantId, sendNoteKey(outboxId, r.status), t2, withButton(t2, "もう一度送る（確かめてから）", RETRY_SEND_ACTION, { applicant_id: applicantId, outbox_id: outboxId }));
  return { ok: false, code: r.status, status: r.status, mode: "live", outbox_id: outboxId, message: r.status === "failed" ? "LINE を送れませんでした: " + String(r.error ?? "不明").slice(0, 160) : "LINE を送れたか、確認できていません（自動では再送しません）" };
}

/**
 * 24 時間の未対応 → 予備の担当への知らせ（定期実行から呼ぶ）。知らせるだけで、担当者は変えない。
 *   スイッチ（recruit_alerts_on）が閉じていれば、何もしない。対象（RPC が決める: 1 日 1 回・対応済みは出ない・社員採用は対象外）ごとに、
 *   その応募者のスレッドに 1 行（予備の担当へメンション）→ 出せたら「知らせた印」を付ける。スレッドの無い応募者は、出さない（印も付けない）。
 *   本文・電話・メール・LINE の ID は出さない。
 */
export async function alertsScan(deps: OpsDeps, b: { include_test?: unknown; limit?: unknown; now?: unknown } = {}): Promise<OpsResult> {
  const on = await deps.rpc("recruit_alerts_on", {});
  if (on.error) return { ok: false, code: "error", message: String(on.error.message).slice(0, 200) };
  if (on.data !== true) return { ok: true, code: "off", sent: 0 };
  if (!deps.threadPost) return { ok: false, code: "error", message: "スレッドへ出す部品がありません" };
  const nowMs = typeof b.now === "number" && Number.isFinite(b.now) ? b.now : Date.now();
  const now = new Date(nowMs).toISOString();
  const day = new Date(nowMs + 9 * 3600e3).toISOString().slice(0, 10).replace(/-/g, "");   // 日本時間の日付
  const t = await deps.rpc("recruit_unhandled_targets", { p_now: now, p_include_test: b.include_test === true });
  if (t.error) return { ok: false, code: "error", message: String(t.error.message).slice(0, 200) };
  const max = Math.max(1, Math.min(50, Number(b.limit) || 20));
  // deno-lint-ignore no-explicit-any
  const all = (Array.isArray(t.data) ? t.data : []).filter((x: any) => isUuid(x?.applicant_id) && isUuid(x?.backup_user_id));
  const list = all.slice(0, max);
  // deno-lint-ignore no-explicit-any
  const ids = [...new Set(list.flatMap((x: any) => [x.backup_user_id, x.assignee_id]).filter(isUuid))];
  const people = ids.length && deps.people ? await deps.people(ids).catch(() => ({} as Record<string, { name: string | null; slack: string | null }>)) : {};
  let sent = 0, skipped = 0, failed = 0;
  for (const x of list) {
    const bk = people[x.backup_user_id], as = isUuid(x.assignee_id) ? people[x.assignee_id] : null;
    const to = bk?.slack && /^[UW][A-Z0-9]{6,}$/.test(bk.slack) ? `<@${bk.slack}>` : `（予備の担当：${who(bk?.name)} さん・Slack 未連携のためメンションできません）`;
    const text = `${to}　⏰ 応募者からのメッセージに、24 時間以上 返信していません（最初の未返信：${whenJst(x.waiting_since)}・担当：${as?.name ? clean(as.name, 20) : "未定"}）。対応をお願いします。\n※ 予備の担当へのお知らせです。担当者は変えていません。`;
    let res: string;
    try { res = await deps.threadPost(x.applicant_id, `recruit:unhandled:${x.applicant_id}:${day}`, text); } catch (_e) { res = "failed"; }
    if (res === "sent" || res === "duplicate") {
      await deps.rpc("recruit_unhandled_mark", { p_applicant: x.applicant_id, p_now: now }).catch(() => null);   // 印が付かなくても、同じ日の行は、同じ鍵で増えない
      if (res === "sent") sent++; else skipped++;
    } else if (res === "no_thread") skipped++; else failed++;
  }
  return { ok: true, code: "scanned", targets: all.length, sent, skipped, failed, more: all.length > list.length };
}

// ---- 面接の確定・変更・取り消し（2026-11-28） ---------------------------------------------------------
//   いまの画面（nippo の ivConfirm）と同じ順番: 予定と Meet の発行 → 確定の保存 → 応募者への案内（LINE）→ 案内を送った印。
//   違い: 始める前に、同じ鍵・同時の操作・古い値を確かめる／段ごとの結果を残す／予定の番号を、確定と同じ 1 回で保存する／案内は送信箱を通す。
//   予定か案内が失敗しても、確定は残る（partial）。失敗は記録して、自動ではやり直さない。
type Cal = { ok: boolean; mode: "dry" | "live" | "manual"; url: string | null; event_id: string | null; updated: boolean; why: string | null; deleted_old: boolean };
const NOTICE_BAD = ["failed", "unknown", "sent_unrecorded", "error"];
const finish = (deps: OpsDeps, op: string, result: string, error: string | null) => deps.rpc("recruit_interview_finish", { p_op: op, p_result: result, p_error: error }).catch(() => null);
const step = (deps: OpsDeps, op: string, name: string, data: Record<string, unknown>) => deps.rpc("recruit_interview_step", { p_op: op, p_step: name, p_data: data }).catch(() => null);
// deno-lint-ignore no-explicit-any
function refused(d: any): OpsResult | null {
  if (d?.code === "replayed") return { ok: d.ok === true, code: "replayed", replayed: true, result: d.result, message: d.message };
  if (d?.code === "noop") return { ok: true, code: "noop", message: d.message };
  if (!d?.ok || d.code !== "go" || !isUuid(d.op_id)) {
    return { ok: false, code: String(d?.code ?? "error"), message: d?.message ?? "実行できませんでした",
      ...(d?.code === "conflict" ? { current_interview_at: d.current_interview_at ?? null, current_assignee_name: d.current_assignee_name ?? null } : {}) };
  }
  return null;
}

export async function interviewConfirm(deps: OpsDeps, actor: OpsActor,
  b: { applicant_id?: unknown; at?: unknown; mode?: unknown; place?: unknown; notify?: unknown; request_key?: unknown; expected?: unknown; manual_url?: unknown }): Promise<OpsResult> {
  if (!isUuid(b.applicant_id)) return bad("applicant_id が正しくありません");
  const key = typeof b.request_key === "string" ? b.request_key.trim() : "";
  if (key.length < 8 || key.length > 200) return bad("request_key が正しくありません");
  const t = typeof b.at === "string" || typeof b.at === "number" ? new Date(b.at).getTime() : NaN;
  if (!Number.isFinite(t)) return bad("面接日時が正しくありません");
  if (b.mode !== "online" && b.mode !== "onsite") return bad("面接のやり方（online / onsite）が正しくありません");
  const at = new Date(t).toISOString(), mode = b.mode, applicantId = b.applicant_id;
  const manual = mode === "online" && typeof b.manual_url === "string" && /^https:\/\/\S+$/.test(b.manual_url.trim()) ? b.manual_url.trim() : null;
  const begin = await deps.rpc("recruit_interview_begin", {
    p_applicant: applicantId, p_kind: "confirm", p_request_key: key, p_actor: actor.user_id, p_via: actor.via, p_at: at, p_mode: mode,
    p_place: typeof b.place === "string" && b.place.trim() ? b.place.trim() : null, p_notify: b.notify !== false, p_expected: b.expected && typeof b.expected === "object" ? b.expected : null,
  });
  if (begin.error) return { ok: false, code: "error", message: String(begin.error.message).slice(0, 200) };
  const d = begin.data ?? {};
  const no = refused(d); if (no) return no;
  const op: string = d.op_id, by = who(d.actor_name);
  try {
    // 1) 予定と Meet（試しモードなら呼ばない。手で貼った URL があれば、発行しない＝画面と同じ）
    let cal: Cal;
    if (manual) cal = { ok: true, mode: "manual", url: manual, event_id: null, updated: false, why: null, deleted_old: false };
    else if (d.calendar_mode !== "live") cal = { ok: true, mode: "dry", url: null, event_id: null, updated: false, why: null, deleted_old: false };
    else {
      const cfg = deps.calendar ? await deps.calendar.config().catch(() => null) : null;
      if (!deps.calendar || !cfg?.url) cal = { ok: false, mode: "live", url: null, event_id: null, updated: false, why: "カレンダーの設定（GAS の URL）がありません", deleted_old: false };
      else {
        const old: string = typeof d.event_id === "string" ? d.event_id : "";
        let deleted = false;
        // オンライン⇔対面の切り替え: 古い予定（Meet の有無が違う）を消してから、新しく作る（画面と同じ）
        if (d.mode_changed === true && old) { await deps.calendar.remove(cfg, old).catch(() => null); deleted = true; }
        let r: MeetResult;
        try {
          r = await deps.calendar.meet(cfg, { name: String(d.applicant_name ?? ""), start: at, eventId: deleted ? "" : old, mode, place: String(d.place ?? ""), address: String(d.address ?? ""), interviewer: String(d.interviewer_name ?? "") });
        } catch (e) { r = { ok: false, url: null, event_id: null, updated: false, why: "予定の処理が止まりました: " + String((e as Error)?.message ?? e).slice(0, 80) }; }
        cal = { ...r, mode: "live", deleted_old: deleted };
      }
    }
    await step(deps, op, "calendar", { ok: cal.ok, mode: cal.mode, event_id: cal.mode === "dry" ? `dry-${op}` : cal.event_id, updated: cal.updated, why: cal.why, deleted_old: cal.deleted_old });

    // 2) 確定の保存（予定が失敗でも、確定は保存する＝画面と同じ）。予定の番号は、本番モードで作れたときだけ入れる（試しの番号は、応募者の行には入れない）
    const save = await deps.rpc("recruit_interview_save", {
      p_op: op, p_url: mode === "online" && cal.ok ? cal.url : null, p_event_id: cal.mode === "live" && cal.event_id ? cal.event_id : null,
      p_event_clear: cal.mode === "live" && cal.deleted_old && !cal.event_id,
    });
    if (save.error || !save.data?.ok) {
      const msg = String(save.error?.message ?? save.data?.message ?? "不明").slice(0, 200);
      await finish(deps, op, "failed", "保存できませんでした: " + msg);
      if (cal.mode === "live" && cal.ok) await note(deps, applicantId, `recruit:iv:${op}:save`, `⚠️ 面接の確定を保存できませんでした（操作: ${by}）。カレンダーの予定は作られています。もう一度確定すると、同じ予定を使います。`);
      return { ok: false, code: "failed", message: "面接の確定を保存できませんでした: " + msg };
    }
    const s = save.data;

    // 3) 応募者への案内（「送る」を選んだときだけ。LINE と連携していなければ、送らずに文面を返す）
    let notice: { status: string; outbox_id?: string; text?: string } = { status: "skipped_off" };
    if (d.notify !== false) {
      const text = interviewText({ name: String(s.applicant_name ?? d.applicant_name ?? ""), interview_at: String(s.interview_at ?? at), interview_mode: mode, interview_place: s.interview_place ?? d.place ?? "",
        interview_address: s.interview_address ?? d.address ?? "", interview_url: s.interview_url ?? null }, mode === "onsite" ? { name: d.place, address: d.address, note: d.place_note } : null);
      if (d.linked !== true) notice = { status: "skipped_unlinked", text };
      else {
        const r = await messageSend(deps, actor, { applicant_id: applicantId, text, request_key: `iv:${op}:notice`, purpose: "interview_notice",
          dedupe_key: `interview:${applicantId}:${sig([at, mode, s.interview_place ?? "", s.interview_url ?? ""].join("|"))}` });
        notice = { status: r.code === "replayed" ? String(r.status ?? "replayed") : r.code, outbox_id: r.outbox_id };
      }
    }
    await step(deps, op, "notice", { status: notice.status, outbox_id: notice.outbox_id ?? null });

    // 4) 終わり。予定の失敗は、スレッドに知らせる（案内の失敗・試しは、送信の処理が知らせている）
    if (!cal.ok) {
      const ck = `recruit:iv:${op}:calendar`, ct = `⚠️ カレンダーに予定を登録できませんでした（操作: ${by}）。面接の確定は保存されています。\n理由: ${clean(cal.why ?? "不明", 160)}`;
      await note(deps, applicantId, ck, ct, withButton(ct, "カレンダーにもう一度登録", RETRY_CAL_ACTION, { applicant_id: applicantId, note_key: ck }));
    }
    const noticeBad = NOTICE_BAD.includes(notice.status);
    const result = cal.ok && !noticeBad ? "done" : "partial";
    await finish(deps, op, result, result === "done" ? null : [cal.ok ? null : "予定: " + (cal.why ?? "失敗"), noticeBad ? "案内: " + notice.status : null].filter(Boolean).join(" ／ "));
    return { ok: true, code: result, op_id: op, message: result === "done" ? "面接を確定しました" : "面接は確定しましたが、予定か案内が失敗しています",
      calendar: { ok: cal.ok, mode: cal.mode, updated: cal.updated, why: cal.why }, notice,
      interview: { at: s.interview_at ?? at, mode, place: s.interview_place ?? null, has_url: !!s.interview_url } };
  } catch (e) {
    await finish(deps, op, "failed", "処理が止まりました: " + String((e as Error)?.message ?? e).slice(0, 200));
    return { ok: false, code: "error", message: "処理が止まりました。面接の状態を、管理画面で確かめてください" };
  }
}

/** 面接の取り消し（いまの画面の「取り消す」と同じ: 予定を消す → 日時・URL・予定の番号・案内の印を空に。応募者へは送らない） */
export async function interviewCancel(deps: OpsDeps, actor: OpsActor, b: { applicant_id?: unknown; request_key?: unknown; expected?: unknown }): Promise<OpsResult> {
  if (!isUuid(b.applicant_id)) return bad("applicant_id が正しくありません");
  const key = typeof b.request_key === "string" ? b.request_key.trim() : "";
  if (key.length < 8 || key.length > 200) return bad("request_key が正しくありません");
  const applicantId = b.applicant_id;
  const begin = await deps.rpc("recruit_interview_begin", { p_applicant: applicantId, p_kind: "cancel", p_request_key: key, p_actor: actor.user_id, p_via: actor.via,
    p_expected: b.expected && typeof b.expected === "object" ? b.expected : null });
  if (begin.error) return { ok: false, code: "error", message: String(begin.error.message).slice(0, 200) };
  const d = begin.data ?? {};
  const no = refused(d); if (no) return no;
  const op: string = d.op_id, by = who(d.actor_name);
  try {
    const old: string = typeof d.event_id === "string" ? d.event_id : "";
    let cal: { ok: boolean; mode: string; why: string | null } = { ok: true, mode: d.calendar_mode === "live" ? "live" : "dry", why: null };
    if (d.calendar_mode === "live" && old) {
      const cfg = deps.calendar ? await deps.calendar.config().catch(() => null) : null;
      if (!deps.calendar || !cfg?.url) cal = { ok: false, mode: "live", why: "カレンダーの設定（GAS の URL）がありません" };
      else { const r = await deps.calendar.remove(cfg, old).catch((e) => ({ ok: false, why: String((e as Error)?.message ?? e).slice(0, 80) })); cal = { ok: r.ok, mode: "live", why: r.why }; }
    }
    await step(deps, op, "calendar", { ok: cal.ok, mode: cal.mode, event_id: old || null, why: cal.why, deleted_old: cal.mode === "live" && !!old && cal.ok });
    const save = await deps.rpc("recruit_interview_save", { p_op: op });
    if (save.error || !save.data?.ok) {
      const msg = String(save.error?.message ?? save.data?.message ?? "不明").slice(0, 200);
      await finish(deps, op, "failed", "保存できませんでした: " + msg);
      return { ok: false, code: "failed", message: "面接の取り消しを保存できませんでした: " + msg };
    }
    if (!cal.ok) await note(deps, applicantId, `recruit:iv:${op}:calendar`, `⚠️ カレンダーの予定を消せませんでした（操作: ${by}）。面接の取り消しは保存されています。予定は、カレンダーで手で消してください。\n理由: ${clean(cal.why ?? "不明", 160)}`);
    const result = cal.ok ? "done" : "partial";
    await finish(deps, op, result, cal.ok ? null : "予定: " + (cal.why ?? "失敗"));
    return { ok: true, code: result, op_id: op, message: cal.ok ? "面接の日程を取り消しました" : "面接は取り消しましたが、カレンダーの予定を消せませんでした", calendar: cal };
  } catch (e) {
    await finish(deps, op, "failed", "処理が止まりました: " + String((e as Error)?.message ?? e).slice(0, 200));
    return { ok: false, code: "error", message: "処理が止まりました。面接の状態を、管理画面で確かめてください" };
  }
}

/**
 * カレンダーの登録のやり直し（面接の確定は、そのまま。予定と Meet だけ、もう一度）。人がボタンを押し、確かめの窓で確かめてから、のときだけ。
 *   予定の番号があれば、同じ予定を直す（予定は増えない）。成功したら、予定の番号と（オンラインで新しく出た）URL を保存し、元の「登録できませんでした」の行を書き換える。
 *   notify=true のときだけ、URL 入りの案内を、送信箱を通して送る（同じ内容は 1 回だけ）。もう一度失敗しても、スレッドの行は増やさない（押した人に返すだけ）。
 */
export async function calendarRetry(deps: OpsDeps, actor: OpsActor, b: { applicant_id?: unknown; request_key?: unknown; notify?: unknown; note_key?: unknown }): Promise<OpsResult> {
  if (!isUuid(b.applicant_id)) return bad("applicant_id が正しくありません");
  const key = typeof b.request_key === "string" ? b.request_key.trim() : "";
  if (key.length < 8 || key.length > 200) return bad("request_key が正しくありません");
  const applicantId = b.applicant_id;
  const begin = await deps.rpc("recruit_calendar_retry_begin", { p_applicant: applicantId, p_request_key: key, p_actor: actor.user_id, p_via: actor.via, p_notify: b.notify === true });
  if (begin.error) return { ok: false, code: "error", message: String(begin.error.message).slice(0, 200) };
  const d = begin.data ?? {};
  const no = refused(d); if (no) return no;
  const op: string = d.op_id, by = who(d.actor_name), mode = d.mode === "onsite" ? "onsite" : "online";
  try {
    if (d.calendar_mode !== "live") {
      await step(deps, op, "calendar", { ok: true, mode: "dry", event_id: `dry-${op}`, updated: false, why: null, deleted_old: false });
      await finish(deps, op, "done", null);
      return { ok: true, code: "dry", op_id: op, message: "カレンダーは試しモードのため、予定は作っていません", calendar: { ok: true, mode: "dry" } };
    }
    const cfg = deps.calendar ? await deps.calendar.config().catch(() => null) : null;
    let r: MeetResult;
    if (!deps.calendar || !cfg?.url) r = { ok: false, url: null, event_id: null, updated: false, why: "カレンダーの設定（GAS の URL）がありません" };
    else {
      try { r = await deps.calendar.meet(cfg, { name: String(d.applicant_name ?? ""), start: new Date(String(d.at)).toISOString(), eventId: typeof d.event_id === "string" ? d.event_id : "", mode, place: String(d.place ?? ""), address: String(d.address ?? ""), interviewer: String(d.interviewer_name ?? "") }); }
      catch (e) { r = { ok: false, url: null, event_id: null, updated: false, why: "予定の処理が止まりました: " + String((e as Error)?.message ?? e).slice(0, 80) }; }
    }
    await step(deps, op, "calendar", { ok: r.ok, mode: "live", event_id: r.event_id, updated: r.updated, why: r.why, deleted_old: false });
    if (!r.ok) {
      await finish(deps, op, "failed", "予定: " + (r.why ?? "失敗"));
      return { ok: false, code: "failed", op_id: op, message: "カレンダーに登録できませんでした: " + clean(r.why ?? "不明", 160), calendar: { ok: false, mode: "live", why: r.why } };
    }
    const save = await deps.rpc("recruit_calendar_retry_save", { p_op: op, p_url: mode === "online" ? r.url : null, p_event_id: r.event_id });
    if (save.error || !save.data?.ok) {
      const msg = String(save.error?.message ?? save.data?.message ?? "不明").slice(0, 200);
      await finish(deps, op, "failed", "保存できませんでした: " + msg);
      return { ok: false, code: "failed", op_id: op, message: "予定は作れましたが、保存できませんでした（もう一度登録すると、同じ予定を使います）: " + msg };
    }
    const s = save.data;
    let notice: { status: string; outbox_id?: string } = { status: "skipped_off" };
    if (d.notify === true && d.linked === true) {
      const text = interviewText({ name: String(s.applicant_name ?? ""), interview_at: String(s.interview_at), interview_mode: mode, interview_place: s.interview_place ?? "", interview_address: s.interview_address ?? d.address ?? "", interview_url: s.interview_url ?? null },
        mode === "onsite" ? { name: d.place, address: d.address, note: d.place_note } : null);
      const m = await messageSend(deps, actor, { applicant_id: applicantId, text, request_key: `iv:${op}:notice`, purpose: "interview_notice",
        dedupe_key: `interview:${applicantId}:${sig([new Date(String(s.interview_at)).toISOString(), mode, s.interview_place ?? "", s.interview_url ?? ""].join("|"))}` });
      notice = { status: m.code === "replayed" ? String(m.status ?? "replayed") : m.code, outbox_id: m.outbox_id };
    }
    await step(deps, op, "notice", { status: notice.status, outbox_id: notice.outbox_id ?? null });
    const noticeBad = NOTICE_BAD.includes(notice.status);
    await finish(deps, op, noticeBad ? "partial" : "done", noticeBad ? "案内: " + notice.status : null);
    if (typeof b.note_key === "string" && /^recruit:iv:[0-9a-f-]{36}:calendar$/i.test(b.note_key)) { try { await deps.noteUpdate?.(b.note_key, `✅ カレンダーに登録しました（操作: ${by}）。`); } catch (_e) { /* 書き換えは、できなくても止めない */ } }
    return { ok: true, code: noticeBad ? "partial" : "done", op_id: op, message: "カレンダーに登録しました", calendar: { ok: true, mode: "live", updated: r.updated }, notice, has_url: !!s.interview_url };
  } catch (e) {
    await finish(deps, op, "failed", "処理が止まりました: " + String((e as Error)?.message ?? e).slice(0, 200));
    return { ok: false, code: "error", message: "処理が止まりました。面接の状態を、管理画面で確かめてください" };
  }
}

// ---- 採用を決める（2026-11-30） ---------------------------------------------------------------------
//   採用の処理そのものは、既存の hire_applicant（RPC recruit_hire が、確かめのあと、押した人の操作として呼ぶ）。ここは、そのあとの「招待の LINE」を送信箱に通すだけ。
//   招待リンクの入った文面は、RPC から受け取って送信箱へ渡すだけで、返す値・スレッドの記録には入れない。
/** 招待リンクの土台（いまの画面は location.origin + location.pathname ＝ 公開している nippo の URL を使っている） */
export const INVITE_BASE = "https://mirai-oss.github.io/nippo/";

/** 採用の窓に出す材料（何も書かない） */
export async function hireInfo(deps: OpsDeps, actor: OpsActor, b: { applicant_id?: unknown }): Promise<OpsResult> {
  if (!isUuid(b.applicant_id)) return bad("applicant_id が正しくありません");
  const { data, error } = await deps.rpc("recruit_hire_info", { p_applicant: b.applicant_id, p_actor: actor.user_id });
  if (error) return { ok: false, code: "error", message: String(error.message).slice(0, 200) };
  return { ok: data?.ok === true, code: String(data?.code ?? "error"), message: data?.message ?? undefined, can: data?.can === true, name: data?.name ?? null, kind: data?.kind ?? null, status: data?.status ?? null,
    default_role: data?.default_role ?? null, roles: Array.isArray(data?.roles) ? data.roles : [], stores: Array.isArray(data?.stores) ? data.stores : [], store_id: data?.store_id ?? null,
    linked: data?.linked === true, is_test: data?.is_test === true, mode: data?.line_mode === "live" ? "live" : "dry" };
}

export async function hire(deps: OpsDeps, actor: OpsActor,
  b: { applicant_id?: unknown; role?: unknown; store_ids?: unknown; request_key?: unknown; expected?: unknown; notify?: unknown }): Promise<OpsResult> {
  if (!isUuid(b.applicant_id)) return bad("applicant_id が正しくありません");
  const key = typeof b.request_key === "string" ? b.request_key.trim() : "";
  if (key.length < 8 || key.length > 200) return bad("request_key が正しくありません");
  if (typeof b.role !== "string" || !b.role) return bad("役割が指定されていません");
  const stores = Array.isArray(b.store_ids) ? b.store_ids.filter(isUuid) : [];
  if (!stores.length || stores.length !== (Array.isArray(b.store_ids) ? b.store_ids.length : 0)) return bad("所属店舗が正しくありません");
  const applicantId = b.applicant_id;
  const r = await deps.rpc("recruit_hire", { p_applicant: applicantId, p_role: b.role, p_store_ids: stores, p_request_key: key, p_actor: actor.user_id, p_via: actor.via,
    p_expected: b.expected && typeof b.expected === "object" ? b.expected : null, p_invite_base: INVITE_BASE });
  if (r.error) return { ok: false, code: "error", message: String(r.error.message).slice(0, 200) };
  const d = r.data ?? {};
  if (d.code === "replayed") return { ok: d.ok === true, code: "replayed", replayed: true, result: d.result, message: d.message };
  if (d.code === "noop") return { ok: true, code: "noop", message: d.message };
  if (!d.ok || d.code !== "done" || !isUuid(d.op_id)) return { ok: false, code: String(d.code === "done" ? "error" : d.code ?? "error"), message: d.message ?? "採用にできませんでした", ...(d.code === "conflict" ? { current_status: d.current_status ?? null } : {}) };
  // 招待の LINE（「送る」を選び、LINE と連携しているときだけ。送信箱を通す＝スイッチ・試しモード・二重防止の決まりは、ほかの送信と同じ）
  let invite: { status: string; outbox_id?: string } = { status: b.notify === false ? "skipped_off" : "skipped_unlinked" };
  if (b.notify !== false && d.linked === true) {
    if (typeof d.invite_text !== "string" || !d.invite_text.trim()) invite = { status: "no_text" };
    else {
      const m = await messageSend(deps, actor, { applicant_id: applicantId, text: d.invite_text, request_key: `hire:${d.op_id}:invite`, purpose: "invite", dedupe_key: `invite:${applicantId}:${sig(d.invite_text)}` });
      invite = { status: m.code === "replayed" ? String(m.status ?? "replayed") : m.code, outbox_id: m.outbox_id };
      if (m.code === "sent") await deps.rpc("recruit_invite_sent", { p_applicant: applicantId, p_actor: actor.user_id }).catch(() => null);   // 招待を送った印（画面と同じ）
    }
  }
  return { ok: true, code: "done", op_id: d.op_id, message: "採用にしました", role: d.role, kind: d.kind, linked: d.linked === true, invite };   // 招待リンク・文面は返さない
}

/** 入口: op で振り分ける */
// deno-lint-ignore no-explicit-any
export async function handleOp(deps: OpsDeps, actor: OpsActor, body: any): Promise<OpsResult> {
  switch (body?.op) {
    case "message_check": return await messageCheck(deps, actor, body);
    case "message_send": return await messageSend(deps, actor, body);
    case "interview_confirm": return await interviewConfirm(deps, actor, body);
    case "interview_cancel": return await interviewCancel(deps, actor, body);
    case "message_retry_info": return await messageRetryInfo(deps, actor, body);
    case "message_retry": return await messageRetry(deps, actor, body);
    case "calendar_retry": return await calendarRetry(deps, actor, body);
    case "hire_info": return await hireInfo(deps, actor, body);
    case "hire": return await hire(deps, actor, body);
    default: return { ok: false, code: "unknown_op", message: "不明な op です" };
  }
}
