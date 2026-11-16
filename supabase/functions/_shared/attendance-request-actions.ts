// =============================================================
// 勤怠の追加・修正申請の「専用の操作」（2026-11-15・社長の指示: 店舗別の 2 段階承認）
//   一次承認・本人確認中・差戻し・却下・最終承認・取り下げ・スマレジへの再実行・出し直し・質問と回答・一次承認者の設定。
//   Slack のボタン（slack-interact）と、管理システムの画面（attendance-request の op=req_act ほか）の両方が、ここを通る
//   ＝同じ検査（DB の関数）・同じカードの書き換え・同じスレッドの行 → Slack と管理システムの状態がずれない。
//
//   権限と状態の検査・状態の変更は、すべて DB の関数（sf_attendance_request_act ほか）。ここは「呼ぶ → 結果で Slack を書き換える」だけ。
//   どの関数も { ok, message, after } を返す。after は Slack の書き換え（数秒かかることがある）。
//   Slack のボタンでは、先に返事をしてから after を後ろで動かす（3 秒の制限）。Slack のふつうの文章の返信は、ここを通らない（＝承認にならない）。
// =============================================================
import { renderRequest, threadLine, askInThread, eventLine, syncAndReport, requestState, mentionOf, type LineKind } from "./attendance-request-notice.ts";
import type { Notify } from "./attendance-alert-notice.ts";

// deno-lint-ignore no-explicit-any
type Sb = any;
export type ReqAction = "first_approve" | "ask" | "return" | "reject" | "final_approve" | "cancel" | "retry_sync";
export const REQ_ACTIONS: ReqAction[] = ["first_approve", "ask", "return", "reject", "final_approve", "cancel", "retry_sync"];
export type ActResult = { ok: boolean; code?: string; message?: string; state?: string; after: () => Promise<void> };
export type SmaregiFix = (requestId: string) => Promise<{ ok: boolean; error?: string }>;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const none = async () => {};
const fail = (code: string, message: string): ActResult => ({ ok: false, code, message, after: none });
const LINE: Record<Exclude<ReqAction, "retry_sync">, LineKind> = { first_approve: "first_approved", ask: "asked", return: "returned", reject: "rejected", final_approve: "final_approved", cancel: "cancelled" };

/** 一次承認・本人確認中・差戻し・却下・最終承認・取り下げ・スマレジへの再実行 */
export async function actRequest(sb: Sb, notify: Notify, o: { requestId: unknown; actorId: string; action: ReqAction; note?: string | null; via: "slack" | "portal"; source: string; smaregiFix: SmaregiFix }): Promise<ActResult> {
  const id = String(o.requestId ?? "");
  if (!UUID_RE.test(id)) return fail("not_found", "この申請は見つかりません");
  if (!REQ_ACTIONS.includes(o.action)) return fail("invalid", "この操作はできません");
  const note = typeof o.note === "string" && o.note.trim() ? o.note.trim().slice(0, 300) : null;
  const stamp = Date.now();

  if (o.action === "retry_sync") {
    // 札を取れた 1 回だけ送る（同時に 2 回送らない）。失敗のときだけ・その店舗を管理できる人だけ（DB の関数が確かめる）
    const { data, error } = await sb.rpc("sf_attendance_request_sync_claim", { p_request_id: id, p_actor: o.actorId });
    if (error) return fail("error", String(error.message ?? error));
    if (!data?.ok) return fail(String(data?.code ?? "error"), String(data?.message ?? "送り直せませんでした"));
    return { ok: true, state: "sync_wait", after: async () => {
      const r = await renderRequest(sb, notify, id);
      if (!r.v2 || !r.refs) return;
      await threadLine(notify, r.refs, id, { text: "🔁 スマレジへもう一度送ります", event: "attendance_request_sync", source: o.source, dedupe: `attendance_req_ev:${id}:retry:${stamp}` });
      await syncAndReport(sb, notify, id, r.refs, { source: o.source, smaregiFix: o.smaregiFix, key: `retry:${stamp}` });
    } };
  }

  const { data, error } = await sb.rpc("sf_attendance_request_act", { p_request_id: id, p_actor: o.actorId, p_action: o.action, p_note: note, p_via: o.via });
  if (error) return fail("error", String(error.message ?? error));
  if (!data?.ok) {
    if (data?.code === "source_changed") {
      // 元データが変わっていたので、DB の関数が差戻しにした。カードを書き換えて、申請した人へ知らせる
      return { ok: false, code: "source_changed", message: String(data.message ?? ""), state: "returned", after: async () => {
        const r = await renderRequest(sb, notify, id);
        if (!r.v2 || !r.view || !r.refs) return;
        await threadLine(notify, r.refs, id, { text: eventLine("source_changed"), event: "attendance_request_event", source: o.source, dedupe: `attendance_req_ev:${id}:source_changed:r${r.view.round}` });
        await askInThread(sb, notify, r.view, r.refs, { source: o.source, key: `r${r.view.round}:returned:src`, dm: false });
      } };
    }
    return fail(String(data?.code ?? "error"), String(data?.message ?? "処理できませんでした"));
  }
  const action = o.action;
  return { ok: true, state: String(data.state ?? ""), after: async () => {
    const r = await renderRequest(sb, notify, id);     // 親とカードを、いまの状態に書き換える
    if (!r.v2 || !r.view || !r.refs) return;           // 今までの形の申請・控えが無い申請は、Slack には何も出さない（状態は DB に入っている）
    const v = r.view;
    const key = action === "ask" ? `${action}:${stamp}` : `${action}:r${v.round}`;
    await threadLine(notify, r.refs, id, { text: eventLine(LINE[action], { actor: String(data.actor_name ?? ""), at: new Date(stamp).toISOString(), note }), event: "attendance_request_event", source: o.source, dedupe: `attendance_req_ev:${id}:${key}` });
    // 次に動く人へ知らせる: 一次承認のあと＝社長（スレッドでメンション＋リンクだけの DM）／差戻しのあと＝申請した人
    if (action === "first_approve" || action === "return") await askInThread(sb, notify, v, r.refs, { source: o.source, key: `r${v.round}:${requestState(v).code}` });
    if (action === "final_approve") {
      // 最終承認が済んだときだけ、スマレジへ送る。札を取れた 1 回だけ（二重反映を防ぐ）
      const { data: c } = await sb.rpc("sf_attendance_request_sync_claim", { p_request_id: id, p_actor: null });
      if (c?.ok) await syncAndReport(sb, notify, id, r.refs, { source: o.source, smaregiFix: o.smaregiFix, key: `sync:r${v.round}` });
    }
  } };
}

export type ResubmitTimes = { clock_in: string | null; clock_out: string | null; break_start_1?: string | null; break_end_1?: string | null; break_start_2?: string | null; break_end_2?: string | null };
/** 差戻しのあとの出し直し（前の承認は消えて、一次承認からやり直し）。時刻の検査・権限は DB の関数 */
export async function resubmitRequest(sb: Sb, notify: Notify, o: { requestId: unknown; actorId: string; times: ResubmitTimes; reason: string; via: "form" | "portal"; source: string }): Promise<ActResult> {
  const id = String(o.requestId ?? "");
  if (!UUID_RE.test(id)) return fail("not_found", "この申請は見つかりません");
  const { data, error } = await sb.rpc("sf_attendance_request_resubmit", {
    p_request_id: id, p_actor: o.actorId, p_clock_in: o.times.clock_in, p_clock_out: o.times.clock_out, p_reason: o.reason,
    p_break_start_1: o.times.break_start_1 ?? null, p_break_end_1: o.times.break_end_1 ?? null, p_break_start_2: o.times.break_start_2 ?? null, p_break_end_2: o.times.break_end_2 ?? null, p_via: o.via,
  });
  if (error) return fail("error", String(error.message ?? error));
  if (!data?.ok) return fail(String(data?.code ?? "error"), String(data?.message ?? "出し直せませんでした"));
  return { ok: true, state: String(data.state ?? ""), after: async () => {
    const r = await renderRequest(sb, notify, id);
    if (!r.v2 || !r.view || !r.refs) return;
    await threadLine(notify, r.refs, id, { text: eventLine("resubmitted", { actor: String(data.actor_name ?? ""), at: new Date().toISOString() }), event: "attendance_request_event", source: o.source, dedupe: `attendance_req_ev:${id}:resubmitted:r${r.view.round}` });
    await askInThread(sb, notify, r.view, r.refs, { source: o.source, key: `r${r.view.round}:${requestState(r.view).code}` });
  } };
}

/** 質問（一次承認者）と回答（対象の本人・申請した人）。同じ申請の履歴に残し、同じスレッドに出す。承認にはならない */
export async function messageRequest(sb: Sb, notify: Notify, o: { requestId: unknown; actorId: string; body: string; via: "portal" | "nippo"; source: string }): Promise<ActResult & { kind?: string }> {
  const id = String(o.requestId ?? "");
  if (!UUID_RE.test(id)) return fail("not_found", "この申請は見つかりません");
  const body = String(o.body ?? "").trim();
  const { data, error } = await sb.rpc("sf_attendance_request_message", { p_request_id: id, p_actor: o.actorId, p_body: body, p_via: o.via });
  if (error) return fail("error", String(error.message ?? error));
  if (!data?.ok) return fail(String(data?.code ?? "error"), String(data?.message ?? "書けませんでした"));
  const kind = data.kind === "question" ? "question" : "answer";
  return { ok: true, kind, state: String(data.state ?? ""), after: async () => {
    const r = await renderRequest(sb, notify, id);
    if (!r.v2 || !r.view || !r.refs) return;
    const v = r.view;
    // 回答 → 一次承認者にメンション（答えが来たことに気付けるように）／質問 → 対象の本人が Slack にいればメンション（アルバイトは Slack にいないので、管理画面で見る）
    //   2026-11-16 STEP 2: 本人が Slack にいないときは、申請した人（店長など）にメンション＋「管理システムの勤怠画面で答えてもらう」案内（従業員本人へは何も送らない）
    const target = v.slack[v.userId] ?? (v.requestedBy && v.requestedBy !== v.userId ? v.slack[v.requestedBy] : null);
    const to = kind === "answer" ? (v.firstApproverId ? v.slack[v.firstApproverId] : null) : target;
    const who = mentionOf([to]);
    const hint = kind === "question" && !v.slack[v.userId] ? `\n本人は Slack を使っていません。本人には、管理システムの勤怠の画面（上に「確認の質問が届いています」と出ます）で答えてもらってください。` : "";
    await threadLine(notify, r.refs, id, { text: `${who ? who + "　" : ""}${eventLine(kind, { actor: String(data.actor_name ?? ""), at: new Date().toISOString(), note: body })}${hint}`,
      event: "attendance_request_message", source: o.source, dedupe: `attendance_req_ev:${id}:${kind}:${Date.now()}` });
  } };
}

/** 一次承認者の設定（社長だけ。DB の関数が確かめる）。その店舗の「確認待ち」の申請が動き出したら、カードを書き換えて一次承認者へ知らせる */
export async function approverSet(sb: Sb, notify: Notify, o: { storeId: unknown; userId: unknown; actorId: string; note?: string | null; source: string }): Promise<ActResult & { moved?: number; slackLinked?: boolean }> {
  const store = String(o.storeId ?? ""), user = o.userId === null || o.userId === undefined || o.userId === "" ? null : String(o.userId);
  if (!UUID_RE.test(store) || (user !== null && !UUID_RE.test(user))) return fail("invalid", "店舗と従業員を選んでください");
  const { data, error } = await sb.rpc("sf_attendance_first_approver_set", { p_store: store, p_user: user, p_actor: o.actorId, p_note: o.note ?? null });
  if (error) return fail("error", String(error.message ?? error));
  if (!data?.ok) return fail(String(data?.code ?? "error"), String(data?.message ?? "設定できませんでした"));
  const moved: string[] = Array.isArray(data.moved_request_ids) ? data.moved_request_ids.filter((x: unknown) => typeof x === "string") : [];
  return { ok: true, moved: moved.length, slackLinked: data.slack_linked === true, after: async () => {
    for (const id of moved) {
      const r = await renderRequest(sb, notify, id);
      if (r.v2 && r.view && r.refs) await askInThread(sb, notify, r.view, r.refs, { source: o.source, key: `r${r.view.round}:${requestState(r.view).code}` });
    }
  } };
}

// ---- 差戻し・却下の理由を書く窓（Slack）。理由が無いと送れない ----
export const REQ_REASON_MODAL = "attendance.req.reason.modal";
export function reasonModal(o: { requestId: unknown; notificationId: string | null; op: "return" | "reject" }) {
  const ret = o.op === "return";
  return {
    type: "modal", callback_id: REQ_REASON_MODAL,
    private_metadata: JSON.stringify({ request_id: String(o.requestId ?? ""), notification_id: o.notificationId, op: o.op }),
    title: { type: "plain_text", text: ret ? "勤怠申請の差戻し" : "勤怠申請の却下" },
    submit: { type: "plain_text", text: ret ? "差戻しにする" : "却下する" }, close: { type: "plain_text", text: "やめる" },
    blocks: [
      { type: "section", text: { type: "mrkdwn", text: ret ? "直してほしい所を書いてください。申請した人が出し直すと、一次承認からやり直しになります。" : "却下の理由を書いてください。この申請はここで終わりになります。" } },
      { type: "input", block_id: "reason", label: { type: "plain_text", text: "理由（必須）" },
        element: { type: "plain_text_input", action_id: "reason", multiline: true, max_length: 300, placeholder: { type: "plain_text", text: ret ? "例: 退勤は 23:00 のはずです" : "例: この日は出勤していません" } } },
    ],
  };
}
/** 窓の送信内容を読む。理由が空・形が違うときは null */
// deno-lint-ignore no-explicit-any
export function reasonFromView(view: any): { requestId: string; notificationId: string | null; op: "return" | "reject"; reason: string } | null {
  let meta: Record<string, unknown> = {};
  try { meta = JSON.parse(view?.private_metadata ?? "{}"); } catch { return null; }
  const reason = String(view?.state?.values?.reason?.reason?.value ?? "").trim();
  if (!reason || !UUID_RE.test(String(meta.request_id ?? "")) || (meta.op !== "return" && meta.op !== "reject")) return null;
  return { requestId: String(meta.request_id), notificationId: typeof meta.notification_id === "string" ? meta.notification_id : null, op: meta.op, reason: reason.slice(0, 300) };
}
