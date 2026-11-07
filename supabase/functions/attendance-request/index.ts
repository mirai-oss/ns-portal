// =============================================================
// attendance-request — 勤怠の追加・修正申請フォーム（kintai.html）の受け口（2026-11-07 新規）
//   op=staff  { store_id }            … その店舗の従業員（RPC sf_attendance_form_staff・ログインユーザー権限）
//   op=submit { kind, store_id, user_id, work_date, clock_in, clock_out, break_start_1.., reason }
//             … RPC sf_attendance_request_submit（申請者=JWT のユーザー）→ マスターの Slack DM に承認依頼 → 勤怠確認チャンネルに「申請あり」
// 認証: Authorization: Bearer <ログインユーザーの JWT>（ポータルの nsportal_session_v1）。service_role は不可（申請者が要る）
// デプロイ: supabase functions deploy attendance-request --no-verify-jwt --project-ref uuvsxzhpxtghojoubjcc --yes（JWT は関数内で検証）
// =============================================================
import { createClient } from "npm:@supabase/supabase-js@2";

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
  if (b.op !== "submit") return json({ ok: false, error: "op は staff か submit" }, 400);

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
