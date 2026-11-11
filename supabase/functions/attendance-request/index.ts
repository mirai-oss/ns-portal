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
import { isUuid, jstLocalToIso, fixRequestArgs, fixRequestedParentText, fixApprovalSend, alertStatusMessage, alertFormRow, isMissingRpc, BREAK_NOT_READY, breakDeclareArgs } from "../_shared/attendance-fix-notify.ts";

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
  if (b.op !== "submit") return json({ ok: false, error: "op は staff / day / submit / decide" }, 400);

  const { data, error } = await sb.rpc("sf_attendance_request_submit", {
    p_actor: actor.id, p_kind: String(b.kind ?? ""), p_store_id: b.store_id ?? null, p_user_id: b.user_id ?? null, p_work_date: b.work_date ?? null,
    p_clock_in: toIso(b.clock_in), p_clock_out: toIso(b.clock_out), p_reason: String(b.reason ?? ""),
    p_break_start_1: toIso(b.break_start_1), p_break_end_1: toIso(b.break_end_1), p_break_start_2: toIso(b.break_start_2), p_break_end_2: toIso(b.break_end_2),
    p_via: "form",
  });
  if (error) return json({ ok: false, error: error.message }, 400);
  if (!data?.ok) return json({ ok: false, error: data?.message ?? "申請できませんでした", code: data?.code }, 400);

  // マスターへ承認依頼（DM）
  const ids: string[] = [];
  const kindLabel = data.kind === "add" ? "勤怠追加" : "勤怠修正";
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
  const { data, error } = await sb.rpc("sf_attendance_request_decide", { p_request_id: String(b.request_id ?? ""), p_actor: actor.id, p_approve: approve, p_note: note, p_via: "portal" });
  if (error) return json({ ok: false, error: error.message }, 400);
  if (!data?.ok) return json({ ok: false, error: data?.message ?? "処理できませんでした", code: data?.code }, 400);
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
// op=alert: フォームの自動入力用。権限は「× 修正する」（RPC sf_attendance_fix_request）と同じ sf_can_manage_as。open 以外は { ok:false, error, status }
async function alertGet(sb: any, actor: { id: string; name: string }, b: any) {
  const id = String(b.alert_id ?? "");
  const notFound = () => json({ ok: false, code: "not_found", error: "この勤怠確認は見つかりません" }, 404);
  if (!isUuid(id)) return notFound();
  const { data: a, error } = await sb.from("sf_attendance_alerts")
    .select("id,status,request_kind,user_id,store_id,work_date,labor_cost_daily_id,clock_in,clock_out,break_start_1,break_end_1,break_start_2,break_end_2")
    .eq("id", id).maybeSingle();
  if (error) return json({ ok: false, error: error.message }, 400);
  if (!a) return notFound();
  const { data: can } = await sb.rpc("sf_can_manage_as", { p_actor: actor.id, p_store_id: a.store_id });
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
  const { data, error } = await sb.rpc("sf_attendance_fix_request", fixRequestArgs({ alertId: id, actorId: actor.id, clockIn, clockOut, reason, via: "form", breaks, noBreak }));
  if (error) return json({ ok: false, error: error.message }, 400);
  if (!data?.ok) return json({ ok: false, error: data?.message ?? "申請できませんでした", code: data?.code }, 400);

  // 申請は RPC で記録済み。ここから先（Slack の書き換え・承認依頼）が失敗しても申請は有効なので、エラーにはせず結果に添える
  let approvers = 0, notifyError: string | null = null;
  try {
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
