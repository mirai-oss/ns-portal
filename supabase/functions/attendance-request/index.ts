// =============================================================
// attendance-request — 勤怠の追加・修正申請フォーム（kintai.html）の受け口（2026-11-07 新規）
//   op=staff  { store_id }            … その店舗の従業員（RPC sf_attendance_form_staff・ログインユーザー権限）
//   op=day    { store_id, work_date } … その日・その店舗の勤怠一覧＝修正前の値（RPC sf_attendance_form_day・2026-11-08）
//   op=submit { kind, store_id, user_id, work_date, clock_in, clock_out, break_start_1.., reason }
//             … RPC sf_attendance_request_submit（申請者=JWT のユーザー）→ マスターの Slack DM に承認依頼 → 勤怠確認チャンネルに「申請あり」
//   op=decide { request_id, approve: true|false, note? }   … 2026-11-08 管理システム（tori-dashboard 申請履歴）からの承認/却下
//   op=decide { alert_id, approve, note? }                 … 2026-11-08(2) 勤怠確認アラートからの修正/打刻削除の承認/却下（RPC sf_attendance_fix_decide・slack-interact の attendanceDecide と同じ後処理）
//             … RPC sf_attendance_request_decide（p_actor=JWT のユーザー・マスターのみ・p_via='portal'）→ Slack の承認依頼・申請あり
//               メッセージを「✅/❌」に書き換え → 承認なら smaregi-attendance-fix で勤務実績へ書き戻し（Slack のボタンと同じ流れ）
//   --- 2026-11-12 追加（ユーザー決定: 勤怠修正の入力は Slack のモーダルをやめて、このフォームに一本化）。上の op は変えていない ---
//   op=alert         { alert_id } … 勤怠確認アラート（Slack の「修正する」）からフォームを開いたときの自動入力の中身（対象者・勤務日・店舗・いまの打刻）
//   op=alert_fix     { alert_id, clock_in, clock_out, break_start_1.., no_break, reason } … RPC sf_attendance_fix_request（Slack のモーダル送信と同じ引数・同じ通知）
//   op=break_declare { store_id, user_id, work_date, kind: none|short, minutes, reason } … 休憩の申告。RPC sf_break_exception_submit（別担当が作成中。無ければ「この機能はまだ使えません」）
// 認証: Authorization: Bearer <ログインユーザーの JWT>（ポータルの nsportal_session_v1）。service_role は不可（申請者が要る）
// デプロイ: supabase functions deploy attendance-request --no-verify-jwt --project-ref uuvsxzhpxtghojoubjcc --yes（JWT は関数内で検証）
// =============================================================
import { createClient } from "npm:@supabase/supabase-js@2";
import { isUuid, jstLocalToIso, fixRequestArgs, fixRequestedParentText, fixApprovalSend, alertStatusMessage, alertFormRow, isMissingRpc, BREAK_NOT_READY, breakDeclareArgs, sameTimes, NO_CHANGE_MESSAGE } from "../_shared/attendance-fix-notify.ts";
import { afterRequest, afterDecide, alertCase } from "../_shared/attendance-alert-notice.ts";   // 2026-11-11: 勤怠確認の新しい形（親 1 行＋スレッド）。新しい形のアラートは共通部品が書き換える
// 2026-11-15（社長の指示）: フォームの勤怠申請も「親 1 行＋スレッド＋修正前後のカード」に。スイッチ app_settings.attendance_request_flow.thread が true のときだけ。false・設定なしは、下の今までの処理のまま
import { flowSettings, postRequest, requestCase, afterRequestDecide, afterAlertRequest, selfApplyPresident, afterSelfApply } from "../_shared/attendance-request-notice.ts";
// 2026-11-15: 2 段階承認の専用の操作（管理システムの承認画面から）。Slack のボタンと同じ共通部品・同じ DB の関数を通る（＝Slack と管理システムの状態がずれない）
import { actRequest, resubmitRequest, messageRequest, approverSet, REQ_ACTIONS, type ReqAction } from "../_shared/attendance-request-actions.ts";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });
const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const FORM_URL = "https://mirai-oss.github.io/ns-portal/kintai.html";

async function actorFromJwt(req: Request): Promise<{ id: string; name: string } | null> {
  const jwt = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!jwt) return null;
  const anon = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: `Bearer ${jwt}` } } });
  const { data } = await anon.auth.getUser();
  if (!data?.user) return null;
  const { data: u } = await svc().from("users").select("id,name,is_active").eq("id", data.user.id).maybeSingle();
  return u?.is_active ? { id: u.id, name: u.name } : null;
}
async function notifySlack(body: Record<string, unknown>) {
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const res = await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/notify-slack`, {
    method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}`, apikey: key }, body: JSON.stringify(body),
  });
  return await res.json().catch(() => null);
}
async function masterChannels(sb: any): Promise<string[]> {
  const { data: masters } = await sb.from("users").select("id").eq("is_master", true).eq("is_active", true);
  const ids = (masters ?? []).map((m: any) => m.id);
  if (!ids.length) return ["hq.keiri_kanshi"];
  const { data: linked } = await sb.from("user_slack").select("user_id").in("user_id", ids);
  const out = (linked ?? []).map((r: any) => `user:${r.user_id}`);
  return out.length ? out : ["hq.keiri_kanshi"];
}
// "YYYY-MM-DDTHH:MM"（JST）や ISO を timestamptz 文字列に
function toIso(v: unknown): string | null {
  if (!v || typeof v !== "string") return null;
  const s = v.trim();
  if (/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?$/.test(s)) return s.length === 16 ? `${s}:00+09:00` : `${s}+09:00`;
  const d = new Date(s);
  return isNaN(d.getTime()) ? null : d.toISOString();
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ ok: false, error: "POSTのみ" }, 405);
  const actor = await actorFromJwt(req);
  if (!actor) return json({ ok: false, error: "ログインが必要です" }, 401);
  let b: any = {};
  try { b = await req.json(); } catch { return json({ ok: false, error: "JSONを読めません" }, 400); }
  const sb = svc();

  if (b.op === "staff") {
    // ログインユーザーの権限で RPC を呼ぶ（店舗を管理できる人か、その店舗の所属者だけが見える）
    const jwt = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
    const asUser = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: `Bearer ${jwt}` } } });
    const { data, error } = await asUser.rpc("sf_attendance_form_staff", { p_store_id: String(b.store_id ?? "") });
    if (error) return json({ ok: false, error: error.message }, 400);
    return json({ ok: true, staff: data ?? [] });
  }
  if (b.op === "day") {
    // 2026-11-08: その日・その店舗の勤怠一覧（修正前の値）。RPC はログインユーザーの権限で（管理できる店舗は全員分、他は自分だけ）
    const jwt = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
    const asUser = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: `Bearer ${jwt}` } } });
    const { data, error } = await asUser.rpc("sf_attendance_form_day", { p_store_id: String(b.store_id ?? ""), p_work_date: String(b.work_date ?? "") });
    if (error) return json({ ok: false, error: error.message }, 400);
    return json({ ok: true, rows: data ?? [] });
  }
  if (b.op === "decide" && /^[0-9a-f-]{36}$/.test(String(b.alert_id ?? ""))) return await decideAlert(sb, actor, b);   // 2026-11-08(2) アラート由来（修正/打刻削除）
  if (b.op === "decide") return await decide(sb, actor, b);
  // 2026-11-12 追加の op（処理は末尾の関数。ここより上・下の既存の op は無変更）
  if (b.op === "alert") return await alertGet(sb, actor, b);
  if (b.op === "alert_fix") return await alertFix(sb, actor, b);
  if (b.op === "break_declare") return await breakDeclare(sb, actor, b);
  // 2026-11-15 追加の op（2 段階承認。処理は末尾の関数。ここより上・下の既存の op は無変更）
  if (b.op === "req_get") return await reqGet(sb, actor, b);
  if (b.op === "req_act") return await reqActOp(sb, actor, b);
  if (b.op === "req_resubmit") return await reqResubmit(sb, actor, b);
  if (b.op === "req_message") return await reqMessage(sb, actor, b);
  if (b.op === "req_mine") return await reqMine(sb, actor);
  if (b.op === "approver_set") return await approverSetOp(sb, actor, b);
  if (b.op !== "submit") return json({ ok: false, error: "op は staff / day / submit / decide" }, 400);

  // 2026-11-11（ユーザー決定）: 勤怠修正で、変更前後が同じ申請は受け付けない（その人・その日・その店舗の勤怠が 1 件に決まるときだけ確かめる）
  if (String(b.kind ?? "") === "fix" && b.user_id && b.work_date) {
    let q = sb.from("labor_cost_daily").select("clock_in,clock_out,break_start_1,break_end_1,break_start_2,break_end_2").eq("user_id", b.user_id).eq("work_date", b.work_date);
    if (b.store_id) q = q.eq("store_id", b.store_id);
    const { data: curRows } = await q.limit(2);
    if (curRows && curRows.length === 1 && sameTimes(curRows[0], { clock_in: toIso(b.clock_in), clock_out: toIso(b.clock_out), break_start_1: toIso(b.break_start_1), break_end_1: toIso(b.break_end_1), break_start_2: toIso(b.break_start_2), break_end_2: toIso(b.break_end_2) }))
      return json({ ok: false, code: "no_change", error: NO_CHANGE_MESSAGE }, 400);
  }
  // 2026-11-19 出勤取消（その日の勤務の記録を丸ごと削除する申請）。時刻は使わない。理由は必須（DB の関数が検査）。承認の流れは勤怠修正と同じ
  const { data, error } = String(b.kind ?? "") === "delete"
    ? await sb.rpc("sf_attendance_request_submit_delete", { p_actor: actor.id, p_store_id: b.store_id ?? null, p_user_id: b.user_id ?? null, p_work_date: b.work_date ?? null, p_reason: String(b.reason ?? ""), p_via: "form" })
    : await sb.rpc("sf_attendance_request_submit", {
    p_actor: actor.id, p_kind: String(b.kind ?? ""), p_store_id: b.store_id ?? null, p_user_id: b.user_id ?? null, p_work_date: b.work_date ?? null,
    p_clock_in: toIso(b.clock_in), p_clock_out: toIso(b.clock_out), p_reason: String(b.reason ?? ""),
    p_break_start_1: toIso(b.break_start_1), p_break_end_1: toIso(b.break_end_1), p_break_start_2: toIso(b.break_start_2), p_break_end_2: toIso(b.break_end_2),
    p_via: "form",
  });
  if (error) return json({ ok: false, error: error.message }, 400);
  if (!data?.ok) return json({ ok: false, error: data?.message ?? "申請できませんでした", code: data?.code }, 400);

  // 2026-11-15 新しい形（スイッチが ON のときだけ）: #勤怠確認 に親 1 行 → スレッドに修正前後のカード（承認・却下のボタン）→ 承認者へスレッドで知らせる（＋リンクだけの DM）。
  //   送れなかったときは、下の今までの通知（DM のボタン＋「申請あり」）へ進む（承認の依頼が届かないことを避ける）
  if ((await flowSettings(sb)).thread) {
    // 2026-11-16: 社長が自分の勤怠を申請したときだけ、承認を省略して反映する（条件は DB の関数が検査。ほかは何もしない）
    const selfApplied = await selfApplyPresident(sb, data.request_id).catch(() => false);
    const pr = await postRequest(sb, notifySlack, data.request_id, { source: "ef:attendance-request", slackToken: Deno.env.get("SLACK_BOT_TOKEN") ?? null }).catch((e) => ({ ok: false, error: String(e).slice(0, 200) }));
    if (pr.ok && selfApplied) waitUntil(afterSelfApply(sb, notifySlack, data.request_id, { source: "ef:attendance-request", smaregiFix: (id) => smaregiFix(id) }));
    if (pr.ok) return json({ ok: true, request_id: data.request_id, summary: data.summary, approvers_notified: (pr as { mentions?: number }).mentions ?? 0, form_url: FORM_URL, thread: true });
  }
  // マスターへ承認依頼（DM）
  const ids: string[] = [];
  const kindLabel = data.kind === "add" ? "勤怠追加" : data.kind === "delete" ? "出勤取消" : "勤怠修正";
  for (const ch of await masterChannels(sb)) {
    const nid = crypto.randomUUID();
    const val = JSON.stringify({ request_id: data.request_id, notification_id: nid });
    const r = await notifySlack({
      action: "send", notification_id: nid, channel_key: ch, event: "attendance_request", source: "ef:attendance-request",
      text: `🙋 ${kindLabel}の承認依頼 ${data.summary}`,
      blocks: [
        { type: "section", text: { type: "mrkdwn", text: `🙋 *${kindLabel}の承認依頼*（フォーム）\n${data.summary}\n申請: ${actor.name}${data.before ? `\n修正前: ${data.before}` : ""}\n理由: ${data.reason}` } },
        { type: "actions", block_id: "attendance_request", elements: [
          { type: "button", style: "primary", text: { type: "plain_text", text: "✅ 承認", emoji: true }, action_id: "attendance.request.approve", value: val },
          { type: "button", style: "danger", text: { type: "plain_text", text: "❌ 却下", emoji: true }, action_id: "attendance.request.reject", value: val },
        ] },
        { type: "context", elements: [{ type: "mrkdwn", text: `申請 \`${String(data.request_id).slice(0, 8)}\`・承認すると管理システムとスマレジの勤務実績に反映` }] },
      ],
      dedupe_key: `attendance_request:${data.request_id}:${ch}`, ref: { table: "sf_attendance_requests", id: data.request_id }, username: "勤怠確認", icon_emoji: ":alarm_clock:",
    });
    if (r?.ok && r.notification_id) ids.push(r.notification_id);
  }
  // 勤怠確認チャンネルにも「申請あり」（ボタン無し・店長の共有用）
  const noticeIds: string[] = [];
  const n = await notifySlack({
    action: "send", channel_key: "kintai.check", event: "attendance_request_notice", source: "ef:attendance-request",
    text: `📝 ${kindLabel}の申請（${actor.name}）: ${data.summary}\n理由: ${data.reason}\n承認待ち（マスター）`,
    dedupe_key: `attendance_request_notice:${data.request_id}`, ref: { table: "sf_attendance_requests", id: data.request_id }, username: "勤怠確認", icon_emoji: ":alarm_clock:",
  });
  if (n?.ok && n.notification_id) noticeIds.push(n.notification_id);
  await sb.from("sf_attendance_requests").update({ approval_notification_ids: ids, notice_notification_ids: noticeIds, updated_at: new Date().toISOString() }).eq("id", data.request_id);
  return json({ ok: true, request_id: data.request_id, summary: data.summary, approvers_notified: ids.length, form_url: FORM_URL });
});

// ---- 承認 / 却下（管理システムから）。slack-interact の requestDecide と同じ後処理 ----
declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void } | undefined;
function waitUntil(p: Promise<unknown>) {
  try { if (typeof EdgeRuntime !== "undefined" && EdgeRuntime?.waitUntil) { EdgeRuntime.waitUntil(p); return; } } catch (_) { /* fallthrough */ }
  p.catch(() => {});
}
async function updateMany(ids: unknown, text: string) {
  const list = Array.isArray(ids) ? ids.filter((x) => typeof x === "string") as string[] : [];
  await Promise.all(list.map((id) => notifySlack({ action: "update", notification_id: id, text })));
}
async function smaregiFix(requestId: string): Promise<{ ok: boolean; error?: string }> {
  try {
    const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    const res = await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/smaregi-attendance-fix`, {
      method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}`, apikey: key }, body: JSON.stringify({ request_id: requestId }),
    });
    const j = await res.json().catch(() => null);
    return { ok: !!j?.ok, error: j?.error ?? (res.ok ? undefined : `HTTP ${res.status}`) };
  } catch (e) { return { ok: false, error: String(e).slice(0, 200) }; }
}
async function decide(sb: any, actor: { id: string; name: string }, b: any) {
  const approve = b.approve === true || b.approve === "true";
  const note = typeof b.note === "string" && b.note.trim() ? b.note.trim().slice(0, 300) : null;
  // 2026-11-15: 2 段階承認の申請（flow=two_stage）は、今までの 1 段階の承認の関数では動かせない（DB が止める）。
  //   今までの画面（経営ダッシュボードの申請履歴）から来たときは、承認＝最終承認（社長だけ）・却下＝却下（理由が必須）として、専用の操作へ回す。
  //   第 2 弾の SQL が未適用のあいだは flow の列が無い＝読めない＝この分かれ道には入らない（今までどおり）
  {
    const { data: fr } = await sb.from("sf_attendance_requests").select("flow").eq("id", String(b.request_id ?? "")).maybeSingle();
    if (fr?.flow === "two_stage") {
      const r = await actRequest(sb, notifySlack, { requestId: b.request_id, actorId: actor.id, action: approve ? "final_approve" : "reject", note, via: "portal", source: "ef:attendance-request", smaregiFix: (id) => smaregiFix(id) });
      if (approve && r.ok) waitUntil(r.after()); else await r.after();
      if (!r.ok) return json({ ok: false, error: r.message ?? "処理できませんでした", code: r.code }, 400);
      return json({ ok: true, approved: approve, request_id: b.request_id, two_stage: true, state: r.state });
    }
  }
  const { data, error } = await sb.rpc("sf_attendance_request_decide", { p_request_id: String(b.request_id ?? ""), p_actor: actor.id, p_approve: approve, p_note: note, p_via: "portal" });
  if (error) return json({ ok: false, error: error.message }, 400);
  if (!data?.ok) return json({ ok: false, error: data?.message ?? "処理できませんでした", code: data?.code }, 400);
  // 2026-11-15 新しい形の申請（親 1 行＋スレッド）: スレッドに結果の行 → 親とカードを書き換え → 承認ならスマレジへ反映して、結果でもう一度。今までの形は下の処理のまま
  if (await requestCase(sb, data.request_id).catch(() => null)) {
    const after = afterRequestDecide(sb, notifySlack, data.request_id, { approve, source: "ef:attendance-request", smaregiFix: (id) => smaregiFix(id) });
    if (!approve) { await after; return json({ ok: true, approved: false, request_id: data.request_id }); }
    waitUntil(after);
    return json({ ok: true, approved: true, request_id: data.request_id, summary: data.summary });
  }
  const when = new Date().toLocaleString("ja-JP", { timeZone: "Asia/Tokyo", hour12: false });
  const kindLabel = data.kind === "add" ? "勤怠追加" : "勤怠修正";
  const via = "（管理システムから）";
  if (!approve) {
    await updateMany(data.approval_notification_ids, `❌ 却下しました（${actor.name}・${when}${via}）\n${data.summary}\n申請: ${data.requested_by_name}　理由: ${data.reason}${note ? `\n却下理由: ${note}` : ""}`);
    await updateMany(data.notice_notification_ids, `❌ ${kindLabel}の申請は却下されました（${actor.name}・${when}）\n${data.summary}\n申請: ${data.requested_by_name}`);
    return json({ ok: true, approved: false, request_id: data.request_id });
  }
  const head = `✅ 承認しました（${actor.name}・${when}${via}）\n${data.summary}\n申請: ${data.requested_by_name}　理由: ${data.reason}\n管理システムに反映済み。`;
  const headN = `✅ ${kindLabel}が承認され、管理システムに反映されました（${when}）\n${data.summary}\n申請: ${data.requested_by_name}\n`;
  waitUntil((async () => {
    await updateMany(data.approval_notification_ids, head + "スマレジへ反映中…");
    await updateMany(data.notice_notification_ids, headN + "スマレジへ反映中…");
    const r = await smaregiFix(data.request_id);
    const tail = r.ok ? "✅ スマレジの勤務実績にも反映済み" : `⚠️ スマレジへの反映に失敗: ${r.error ?? "不明"}\nスマレジの管理画面から直してください（管理システム側は反映済み・ロック中）`;
    await updateMany(data.approval_notification_ids, head + tail);
    await updateMany(data.notice_notification_ids, headN + tail);
  })());
  return json({ ok: true, approved: true, request_id: data.request_id, summary: data.summary });
}

// ---- アラート由来（店長の × 修正 / 🗑 打刻削除）の承認 / 却下。slack-interact の attendanceDecide と同じ文言・後処理 ----
async function smaregiFixAlert(alertId: string): Promise<{ ok: boolean; error?: string }> {
  try {
    const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    const res = await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/smaregi-attendance-fix`, {
      method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}`, apikey: key }, body: JSON.stringify({ alert_id: alertId }),
    });
    const j = await res.json().catch(() => null);
    return { ok: !!j?.ok, error: j?.error ?? (res.ok ? undefined : `HTTP ${res.status}`) };
  } catch (e) { return { ok: false, error: String(e).slice(0, 200) }; }
}
async function decideAlert(sb: any, actor: { id: string; name: string }, b: any) {
  const approve = b.approve === true || b.approve === "true";
  const note = typeof b.note === "string" && b.note.trim() ? b.note.trim().slice(0, 300) : null;
  const { data, error } = await sb.rpc("sf_attendance_fix_decide", { p_alert_id: String(b.alert_id), p_actor: actor.id, p_approve: approve, p_note: note, p_via: "portal" });
  if (error) return json({ ok: false, error: error.message }, 400);
  if (!data?.ok) return json({ ok: false, error: data?.message ?? "処理できませんでした", code: data?.code }, 400);
  const when = new Date().toLocaleString("ja-JP", { timeZone: "Asia/Tokyo", hour12: false }) + "（管理システムから）";
  const isDel = data.request_kind === "delete";
  // 2026-11-11 新しい形のアラート: Slack のスレッドのカードと親を書き換える（承認ならスマレジへ反映し、結果でもう一度）。古い形は下の今までの処理
  if (await alertCase(sb, data.alert_id).catch(() => null)) {
    if (!approve) { await afterDecide(sb, notifySlack, data.alert_id, false, (id) => smaregiFixAlert(id)); return json({ ok: true, approved: false, alert_id: data.alert_id }); }
    waitUntil(afterDecide(sb, notifySlack, data.alert_id, true, (id) => smaregiFixAlert(id)));
    return json({ ok: true, approved: true, alert_id: data.alert_id, summary: data.summary, request_kind: data.request_kind });
  }
  if (!approve) {
    waitUntil((async () => {
      await updateMany(data.approval_notification_ids, `❌ 却下しました（${actor.name}・${when}）\n${data.summary}\n→ 申請 ${data.proposed}（理由: ${data.reason}）${note ? `\n却下理由: ${note}` : ""}`);
      await updateMany(data.notification_ids, `❌ ${isDel ? "打刻削除の申請" : "修正申請"}は却下されました（${actor.name}・${when}）\n${data.summary}\n→ 申請 ${data.proposed}`);
    })());
    return json({ ok: true, approved: false, alert_id: data.alert_id });
  }
  const head = isDel
    ? `✅ 承認しました（${actor.name}・${when}）\n${data.summary}\n→ 打刻削除（理由: ${data.reason}）\n管理システムの勤怠実績を削除済み。`
    : `✅ 承認しました（${actor.name}・${when}）\n${data.summary}\n→ 修正後 ${data.proposed}（理由: ${data.reason}）\n管理システムに反映済み。`;
  const headMgr = isDel
    ? `🗑 打刻の削除が承認され、管理システムの勤怠実績を削除しました（${when}）\n${data.summary}\n`
    : `✅ 修正が承認され、管理システムに反映されました（${when}）\n${data.summary}\n→ 修正後 ${data.proposed}\n`;
  const doing = isDel ? "スマレジの勤務実績を削除中…" : "スマレジへ反映中…";
  waitUntil((async () => {
    await updateMany(data.approval_notification_ids, head + doing);
    await updateMany(data.notification_ids, headMgr + doing);
    const r = await smaregiFixAlert(data.alert_id);
    const tail = r.ok ? (isDel ? "✅ スマレジの勤務実績も削除済み" : "✅ スマレジの勤務実績にも反映済み")
      : (isDel ? `⚠️ スマレジ側の削除に失敗: ${r.error ?? "不明"}\nスマレジの管理画面から消してください（管理システム側は削除済み。消さないと翌朝の取込で戻ります）`
               : `⚠️ スマレジへの反映に失敗: ${r.error ?? "不明"}\nスマレジの管理画面から直してください（管理システム側は反映済み・ロック中）`);
    await updateMany(data.approval_notification_ids, head + tail);
    await updateMany(data.notification_ids, headMgr + tail);
  })());
  return json({ ok: true, approved: true, alert_id: data.alert_id, summary: data.summary, request_kind: data.request_kind });
}

// =============================================================
// 2026-11-12 追加: 勤怠確認アラートからの修正をフォームで受ける（Slack のモーダルの置き換え）＋ 休憩の申告
//   文面・引数の組み立ては _shared/attendance-fix-notify.ts（slack-interact に残したモーダル送信と共通）
// =============================================================
// op=alert: フォームの自動入力用。権限は「× 修正する」（RPC sf_attendance_fix_request）と同じ sf_can_request_as。open 以外は { ok:false, error, status }
async function alertGet(sb: any, actor: { id: string; name: string }, b: any) {
  const id = String(b.alert_id ?? "");
  const notFound = () => json({ ok: false, code: "not_found", error: "この勤怠確認は見つかりません" }, 404);
  if (!isUuid(id)) return notFound();
  const { data: a, error } = await sb.from("sf_attendance_alerts")
    .select("id,status,request_kind,user_id,store_id,work_date,labor_cost_daily_id,clock_in,clock_out,break_start_1,break_end_1,break_start_2,break_end_2")
    .eq("id", id).maybeSingle();
  if (error) return json({ ok: false, error: error.message }, 400);
  if (!a) return notFound();
  const { data: can } = await sb.rpc("sf_can_request_as", { p_actor: actor.id, p_store_id: a.store_id });   // 2026-11-28: 社員は所属店舗の分も申請できる
  if (can !== true) return json({ ok: false, code: "forbidden", error: "この店舗の勤怠を修正する権限がありません" }, 403);
  if (a.status !== "open") return json({ ok: false, code: "already", status: a.status, request_kind: a.request_kind ?? "fix", error: alertStatusMessage(a.status, a.request_kind) }, 409);
  // 「修正前」は勤怠実績の今の値（承認で上書きされる行。アラートの後に打刻が変わっていても今の値を出す）
  const { data: l } = a.labor_cost_daily_id
    ? await sb.from("labor_cost_daily").select("id,clock_in,clock_out,break_start_1,break_end_1,break_start_2,break_end_2,worked_minutes,break_minutes,manual_fixed_at").eq("id", a.labor_cost_daily_id).maybeSingle()
    : { data: null };
  if (!l) return json({ ok: false, code: "no_record", status: a.status, error: "元の勤怠実績が見つかりません（削除された可能性があります）。打刻が無い日は「➕ 勤怠追加」で申請してください。" }, 409);
  const [{ data: u }, { data: st }] = await Promise.all([
    sb.from("users").select("name").eq("id", a.user_id).maybeSingle(),
    sb.from("stores").select("name").eq("id", a.store_id).maybeSingle(),
  ]);
  return json({ ok: true, alert: alertFormRow(a, l, { user: u?.name ?? null, store: st?.name ?? null }) });
}

// op=alert_fix: Slack のモーダル送信（slack-interact の attendance.fix.modal）と同じ RPC・同じ通知。権限・状態・時刻の検査は RPC 側
async function alertFix(sb: any, actor: { id: string; name: string }, b: any) {
  const id = String(b.alert_id ?? "");
  if (!isUuid(id)) return json({ ok: false, code: "not_found", error: "この勤怠確認は見つかりません" }, 404);
  const reason = String(b.reason ?? "").trim();
  const clockIn = jstLocalToIso(b.clock_in), clockOut = jstLocalToIso(b.clock_out);
  if (!clockIn || !clockOut || !reason) return json({ ok: false, code: "invalid", error: "出勤・退勤・理由をすべて入れてください" }, 400);
  const noBreak = b.no_break === true || b.no_break === "true";
  const breaks: Record<string, string | null> = {};
  for (const [k, col] of [["b1s", "break_start_1"], ["b1e", "break_end_1"], ["b2s", "break_start_2"], ["b2e", "break_end_2"]]) {
    const raw = b[col];
    if (raw === null || raw === undefined || raw === "") { breaks[k] = null; continue; }
    const iso = jstLocalToIso(raw);
    if (!iso) return json({ ok: false, code: "invalid_break", error: "休憩の時刻を読めません。入れ直してください" }, 400);
    breaks[k] = iso;
  }
  // 2026-11-11（ユーザー決定）: 変更前後が同じ申請は受け付けない（いまの勤怠と、分の単位まで同じ）
  {
    const { data: al } = await sb.from("sf_attendance_alerts").select("labor_cost_daily_id").eq("id", id).maybeSingle();
    const { data: cur } = al?.labor_cost_daily_id ? await sb.from("labor_cost_daily").select("clock_in,clock_out,break_start_1,break_end_1,break_start_2,break_end_2").eq("id", al.labor_cost_daily_id).maybeSingle() : { data: null };
    const prop = { clock_in: clockIn, clock_out: clockOut, break_start_1: noBreak ? null : breaks.b1s, break_end_1: noBreak ? null : breaks.b1e, break_start_2: noBreak ? null : breaks.b2s, break_end_2: noBreak ? null : breaks.b2e };
    if (sameTimes(cur, prop)) return json({ ok: false, code: "no_change", error: NO_CHANGE_MESSAGE }, 400);
  }
  const { data, error } = await sb.rpc("sf_attendance_fix_request", fixRequestArgs({ alertId: id, actorId: actor.id, clockIn, clockOut, reason, via: "form", breaks, noBreak }));
  if (error) return json({ ok: false, error: error.message }, 400);
  if (!data?.ok) return json({ ok: false, error: data?.message ?? "申請できませんでした", code: data?.code }, 400);

  // 申請は RPC で記録済み。ここから先（Slack の書き換え・承認依頼）が失敗しても申請は有効なので、エラーにはせず結果に添える
  let approvers = 0, notifyError: string | null = null;
  try {
    // 2026-11-16 道A: アラートの「修正する」は、2 段階承認の申請として作られる（RPC が request_id を返す）。承認の依頼は申請のスレッドへ
    if (data.request_id) {
      const ar = await afterAlertRequest(sb, notifySlack, { alertId: data.alert_id, requestId: data.request_id, source: "ef:attendance-request", slackToken: Deno.env.get("SLACK_BOT_TOKEN") ?? null, smaregiFix: (rid) => smaregiFix(rid) });
      return json({ ok: true, alert_id: data.alert_id, request_id: data.request_id, summary: data.summary, proposed: data.proposed, approvers_notified: ar.mentions ?? 0, two_stage: true, ...(ar.selfApplied ? { self_applied: true } : {}), ...(ar.ok ? {} : { notify_error: ar.error ?? "Slack への投稿に失敗しました" }) });
    }
    // 2026-11-11 新しい形のアラート: スレッドのカードを「修正内容＋承認・却下」に書き換え、承認できる人へスレッドで知らせる
    const nv = await afterRequest(sb, notifySlack, data.alert_id, "ef:attendance-request");
    if (nv.v2) return json({ ok: true, alert_id: data.alert_id, summary: data.summary, proposed: data.proposed, approvers_notified: nv.approvers });
    const req = { alertId: data.alert_id, summary: data.summary, proposed: data.proposed, reason: data.reason, actorName: actor.name };
    const when = new Date().toLocaleString("ja-JP", { timeZone: "Asia/Tokyo", hour12: false });
    await updateMany(data.notification_ids, fixRequestedParentText({ ...req, when }));
    const ids: string[] = [];
    for (const ch of await masterChannels(sb)) {
      const nid = crypto.randomUUID();
      const r = await notifySlack(fixApprovalSend({ ...req, notificationId: nid, channelKey: ch, source: "ef:attendance-request" }));
      if (r?.ok && r.notification_id) ids.push(r.notification_id);
    }
    // 承認メッセージの台帳 id を控える（状態ではなく連絡の記録。状態遷移は RPC のみ）
    if (ids.length) await sb.from("sf_attendance_alerts").update({ approval_notification_ids: ids, updated_at: new Date().toISOString() }).eq("id", data.alert_id);
    approvers = ids.length;
    if (!approvers) notifyError = "承認依頼の Slack 通知を送れませんでした";
  } catch (e) { notifyError = String(e).slice(0, 200); }
  return json({ ok: true, alert_id: data.alert_id, summary: data.summary, proposed: data.proposed, approvers_notified: approvers, ...(notifyError ? { notify_error: notifyError } : {}) });
}

// op=break_declare: 休憩の申告（この日は休憩を取っていない／短かった）。記録と権限は RPC sf_break_exception_submit（別担当が作成中）
//   ここでも入口の確認だけ行う: 本人の申告か、その店舗を管理できる人が、その店舗の所属者（またはその日その店舗で勤務した人）について出す場合だけ通す
async function breakDeclare(sb: any, actor: { id: string; name: string }, b: any) {
  const p = breakDeclareArgs(b ?? {}, actor.id);
  if ("error" in p) return json({ ok: false, code: "invalid", error: p.error }, 400);
  if (p.args.p_user !== actor.id) {
    const storeId = String(b.store_id ?? "");
    const forbidden = () => json({ ok: false, code: "forbidden", error: "この人の休憩を申告する権限がありません" }, 403);
    if (!isUuid(storeId)) return forbidden();
    const { data: can } = await sb.rpc("sf_can_manage_as", { p_actor: actor.id, p_store_id: storeId });
    if (can !== true) return forbidden();
    const [{ data: member }, { data: worked }] = await Promise.all([
      sb.from("user_stores").select("user_id").eq("user_id", p.args.p_user).eq("store_id", storeId).limit(1),
      sb.from("labor_cost_daily").select("id").eq("user_id", p.args.p_user).eq("store_id", storeId).eq("work_date", p.args.p_work_date).limit(1),
    ]);
    if (!(member ?? []).length && !(worked ?? []).length) return forbidden();
  }
  const { data, error } = await sb.rpc("sf_break_exception_submit", p.args);
  if (error) {
    if (isMissingRpc(error)) return json({ ok: false, code: "not_ready", error: BREAK_NOT_READY }, 400);
    return json({ ok: false, error: error.message }, 400);   // RPC の例外は日本語メッセージ。そのまま画面に出す
  }
  if (!data?.ok) return json({ ok: false, error: data?.message ?? data?.error ?? "申告できませんでした", code: data?.code }, 400);
  // message / already_autofilled: RPC が返す案内（例: すでに自動補完済みなので勤怠修正で直す）。あれば画面にそのまま出す
  return json({ ok: true, id: data.id ?? null, message: typeof data.message === "string" ? data.message : null, already_autofilled: data.already_autofilled === true });
}

// =============================================================
// 2026-11-15 追加: 勤怠申請の 2 段階承認（管理システムの承認画面 kintai.html?req=<id> から）
//   権限と状態の検査は DB の関数（sf_attendance_request_detail / _act / _resubmit / _message / sf_attendance_first_approver_set）。
//   Slack のカードと親の書き換え・スレッドの行は、共通部品（_shared/attendance-request-actions.ts）が Slack のボタンと同じように行う。
// =============================================================
// op=req_get { request_id } … 中身（修正前後）・状態・履歴・「あなたが今できる操作」。見られるのは、対象の本人・申請した人・一次承認者・その店舗を管理できる人
async function reqGet(sb: any, actor: { id: string; name: string }, b: any) {
  const id = String(b.request_id ?? "");
  if (!isUuid(id)) return json({ ok: false, code: "not_found", error: "この申請は見つかりません" }, 404);
  const { data, error } = await sb.rpc("sf_attendance_request_detail", { p_request_id: id, p_viewer: actor.id });
  if (error) return json({ ok: false, error: isMissingRpc(error) ? "この機能はまだ使えません" : error.message }, 400);
  if (!data?.ok) return json({ ok: false, code: data?.code, error: data?.message ?? "見られません" }, data?.code === "not_found" ? 404 : 403);
  return json(data);
}
// op=req_act { request_id, action: first_approve|ask|return|reject|final_approve|cancel|retry_sync, note? } … 差戻し・却下は note（理由）が必須（DB の関数が確かめる）
async function reqActOp(sb: any, actor: { id: string; name: string }, b: any) {
  const action = String(b.action ?? "") as ReqAction;
  if (!REQ_ACTIONS.includes(action)) return json({ ok: false, code: "invalid", error: "この操作はできません" }, 400);
  const r = await actRequest(sb, notifySlack, { requestId: b.request_id, actorId: actor.id, action, note: typeof b.note === "string" ? b.note : null, via: "portal", source: "ef:attendance-request", smaregiFix: (id) => smaregiFix(id) });
  // スマレジへ送る操作（最終承認・再実行）は数秒かかるので、返事のあとで。ほかは、Slack の書き換えまで済ませてから返す
  if (r.ok && (action === "final_approve" || action === "retry_sync")) waitUntil(r.after()); else await r.after();
  if (!r.ok) return json({ ok: false, code: r.code, error: r.message ?? "処理できませんでした" }, 400);
  return json({ ok: true, request_id: b.request_id, action, state: r.state });
}
// op=req_resubmit { request_id, clock_in, clock_out, break_start_1.., reason } … 差戻しのあとの出し直し（時刻は "YYYY-MM-DDTHH:MM"＝JST）
async function reqResubmit(sb: any, actor: { id: string; name: string }, b: any) {
  // 出勤取消の申請は、出し直しできない（時刻の入力が無いため。取り下げて、もう一度申請する）
  const { data: rk } = await sb.from("sf_attendance_requests").select("kind").eq("id", String(b.request_id ?? "")).maybeSingle();
  if (rk?.kind === "delete") return json({ ok: false, code: "delete_no_resubmit", error: "出勤取消の申請は、出し直しできません。取り下げてから、もう一度申請してください" }, 400);
  const r = await resubmitRequest(sb, notifySlack, { requestId: b.request_id, actorId: actor.id, reason: String(b.reason ?? ""), via: "form", source: "ef:attendance-request",
    times: { clock_in: toIso(b.clock_in), clock_out: toIso(b.clock_out), break_start_1: toIso(b.break_start_1), break_end_1: toIso(b.break_end_1), break_start_2: toIso(b.break_start_2), break_end_2: toIso(b.break_end_2) } });
  await r.after();
  if (!r.ok) return json({ ok: false, code: r.code, error: r.message ?? "出し直せませんでした" }, 400);
  return json({ ok: true, request_id: b.request_id, state: r.state });
}
// op=req_message { request_id, body } … 質問（一次承認者）／回答（対象の本人・申請した人）。同じ申請の履歴に残り、同じスレッドに出る。承認にはならない
async function reqMessage(sb: any, actor: { id: string; name: string }, b: any) {
  const r = await messageRequest(sb, notifySlack, { requestId: b.request_id, actorId: actor.id, body: String(b.body ?? ""), via: "portal", source: "ef:attendance-request" });
  await r.after();
  if (!r.ok) return json({ ok: false, code: r.code, error: r.message ?? "書けませんでした" }, 400);
  return json({ ok: true, request_id: b.request_id, kind: r.kind, state: r.state });
}
// op=req_mine … 自分（本人または申請した人）あてに「確認の質問」が来ている申請の一覧（kintai.html の上の目立つ欄。Slack を使っていない人のため）
async function reqMine(sb: any, actor: { id: string; name: string }) {
  const { data } = await sb.from("sf_attendance_requests").select("id,work_date,store_id,user_id")
    .eq("status", "pending").eq("flow", "two_stage").eq("stage", "asking").or(`user_id.eq.${actor.id},requested_by.eq.${actor.id}`)
    .order("requested_at", { ascending: false }).limit(20);
  const rows = data ?? [];
  if (!rows.length) return json({ ok: true, items: [] });
  const [{ data: sts }, { data: us }] = await Promise.all([
    sb.from("stores").select("id,name").in("id", [...new Set(rows.map((r: any) => r.store_id))]),
    sb.from("users").select("id,name").in("id", [...new Set(rows.map((r: any) => r.user_id))]),
  ]);
  const nm = (arr: any[] | null, id: string) => (arr ?? []).find((x) => x.id === id)?.name ?? null;
  return json({ ok: true, items: rows.map((r: any) => ({ request_id: r.id, work_date: r.work_date, store_name: nm(sts, r.store_id), user_name: nm(us, r.user_id) })) });
}
// op=approver_set { store_id, user_id（null で未設定に戻す）, note? } … 一次承認者の設定。社長だけ（DB の関数が確かめる）
async function approverSetOp(sb: any, actor: { id: string; name: string }, b: any) {
  const r = await approverSet(sb, notifySlack, { storeId: b.store_id, userId: b.user_id ?? null, actorId: actor.id, note: typeof b.note === "string" ? b.note : null, source: "ef:attendance-request" });
  await r.after();
  if (!r.ok) return json({ ok: false, code: r.code, error: r.message ?? "設定できませんでした" }, r.code === "forbidden" ? 403 : 400);
  return json({ ok: true, store_id: b.store_id, user_id: b.user_id ?? null, moved_requests: r.moved ?? 0, slack_linked: r.slackLinked === true });
}
