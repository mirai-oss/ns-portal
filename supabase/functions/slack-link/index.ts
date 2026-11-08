// =============================================================
// slack-link — 従業員と Slack の紐づけ（2026-11-08 新規）
//   op=sync        Slack のメンバー一覧（users.list・users:read.email）と users.email を突き合わせて user_slack に登録（既に紐づいている人は表示名だけ更新）
//   op=members     Slack のメンバー一覧（Bot・削除済みを除く）＋どの従業員に紐づいているか。手で紐づけるときの候補用（メールは伏せ字）
//   op=invite      { user_id, channel: line|email|copy } 招待リンク（app_settings 'slack_invite'）を本人の LINE かメール（Resend）で送る／copy=文面だけ返す（手渡し用）
//   op=link        { user_id, slack_user_id } 手で紐づけ（matched_by=manual）／ op=unlink { user_id }
//   op=set_invite  { url } 招待リンクを保存（Slack の「メンバーを招待 → 招待リンクをコピー」で作ったもの）
//   op=status      { user_id? } 紐づけ状態と招待の履歴
// 認証: JWT（CEO/HQ/マスター）。op=sync だけは x-notify-secret（pg_cron 毎朝 09:30）と service_role でも可
// デプロイ: supabase functions deploy slack-link --no-verify-jwt --project-ref uuvsxzhpxtghojoubjcc --yes
// =============================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info, x-notify-secret", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });
const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const mask = (em: string) => em.replace(/^(.).*(@.*)$/, "$1***$2");
const RESEND_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const RESEND_FROM = Deno.env.get("RESEND_FROM") ?? "鳥一代グループ 日報システム <onboarding@resend.dev>";
async function emailSend(to: string, subject: string, text: string): Promise<{ ok: boolean; error?: string }> {
  if (!RESEND_KEY) return { ok: false, error: "RESEND_API_KEY 未設定" };
  const html = `<div style="font-family:sans-serif;line-height:1.8;font-size:15px">${text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/(https?:\/\/\S+)/g, '<a href="$1">$1</a>').replace(/\n/g, "<br>")}</div>`;
  const r = await fetch("https://api.resend.com/emails", { method: "POST", headers: { Authorization: `Bearer ${RESEND_KEY}`, "Content-Type": "application/json" }, body: JSON.stringify({ from: RESEND_FROM, to, subject, html, text }) });
  if (!r.ok) return { ok: false, error: `メール送信エラー(${r.status}) ${(await r.text()).slice(0, 120)}` };
  return { ok: true };
}

function timingSafeEqual(a: string, b: string) {
  if (a.length !== b.length) return false;
  let r = 0; for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}
type Actor = { id: string; name: string; role: string; is_master: boolean };
async function auth(req: Request): Promise<{ mode: "user" | "secret" | "service"; actor?: Actor } | null> {
  const key = (Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "").trim();
  const bearer = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (key && bearer && timingSafeEqual(bearer, key)) return { mode: "service" };
  const secret = (Deno.env.get("NOTIFY_SLACK_SECRET") ?? "").trim();
  const hdr = (req.headers.get("x-notify-secret") ?? "").trim();
  if (secret && hdr && timingSafeEqual(secret, hdr)) return { mode: "secret" };
  if (!bearer) return null;
  const anon = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: `Bearer ${bearer}` } } });
  const { data } = await anon.auth.getUser();
  if (!data?.user) return null;
  const { data: u } = await svc().from("users").select("id,name,role,is_master,is_active").eq("id", data.user.id).maybeSingle();
  if (!u?.is_active) return null;
  if (!(u.is_master || ["CEO", "HQ"].includes(u.role))) return null;
  return { mode: "user", actor: { id: u.id, name: u.name, role: u.role, is_master: !!u.is_master } };
}

async function slackApi(method: string, params: Record<string, string> = {}): Promise<any> {
  const token = Deno.env.get("SLACK_BOT_TOKEN") ?? "";
  const qs = new URLSearchParams(params).toString();
  const r = await fetch(`https://slack.com/api/${method}${qs ? "?" + qs : ""}`, { headers: { Authorization: `Bearer ${token}` } });
  return await r.json().catch(() => ({ ok: false, error: "bad_json" }));
}
type Member = { id: string; email: string; real_name: string; display_name: string };
async function listMembers(): Promise<Member[]> {
  const out: Member[] = [];
  let cursor = "";
  do {
    const r = await slackApi("users.list", { limit: "200", ...(cursor ? { cursor } : {}) });
    if (!r.ok) throw new Error("users.list: " + (r.error ?? "?"));
    for (const m of r.members ?? []) {
      if (m.deleted || m.is_bot || m.id === "USLACKBOT") continue;
      out.push({ id: m.id, email: String(m.profile?.email ?? "").toLowerCase().trim(), real_name: m.real_name ?? m.profile?.real_name ?? "", display_name: m.profile?.display_name ?? "" });
    }
    cursor = r.response_metadata?.next_cursor ?? "";
  } while (cursor);
  return out;
}

// メール一致で紐づける（既に紐づいている人は表示名だけ更新。手動紐づけは上書きしない）
async function sync(sb: any) {
  const members = await listMembers();
  const byEmail = new Map<string, Member>();
  for (const m of members) if (m.email) byEmail.set(m.email, m);
  const { data: users } = await sb.from("users").select("id,email,name,is_active").eq("is_active", true);
  const { data: links } = await sb.from("user_slack").select("user_id,slack_user_id,matched_by");
  const linked = new Map<string, any>((links ?? []).map((l: any) => [l.user_id, l]));
  const now = new Date().toISOString();
  const newly: { user_id: string; name: string; slack_user_id: string }[] = [];
  const rows: any[] = [];
  for (const u of users ?? []) {
    const em = (u.email ?? "").toLowerCase().trim();
    const m = em ? byEmail.get(em) : undefined;
    const cur = linked.get(u.id);
    if (cur) {
      const mm = members.find((x) => x.id === cur.slack_user_id);
      if (mm) rows.push({ user_id: u.id, slack_user_id: cur.slack_user_id, matched_by: cur.matched_by ?? "email", slack_name: mm.real_name, slack_display_name: mm.display_name, updated_at: now });
      continue;
    }
    if (m) { rows.push({ user_id: u.id, slack_user_id: m.id, matched_by: "email", matched_email: em, matched_at: now, slack_name: m.real_name, slack_display_name: m.display_name, updated_at: now }); newly.push({ user_id: u.id, name: u.name, slack_user_id: m.id }); }
  }
  if (rows.length) { const { error } = await sb.from("user_slack").upsert(rows, { onConflict: "user_id" }); if (error) throw new Error(error.message); }
  const linkedSlack = new Set(rows.map((r) => r.slack_user_id));
  const unmatchedSlack = members.filter((m) => !linkedSlack.has(m.id)).map((m) => ({ id: m.id, name: m.real_name, email: m.email ? mask(m.email) : "" }));
  const unlinkedUsers = (users ?? []).filter((u: any) => !rows.some((r) => r.user_id === u.id)).length;
  return { ok: true, slack_members: members.length, linked: rows.length, newly_linked: newly, unlinked_users: unlinkedUsers, unmatched_slack: unmatchedSlack };
}

async function linePush(sb: any, lineUserId: string, text: string): Promise<{ ok: boolean; error?: string }> {
  const { data: sec } = await sb.from("app_secrets").select("value").eq("key", "line_channel_token").maybeSingle();
  const token = (sec?.value ?? "").trim();
  if (!token) return { ok: false, error: "line_channel_token 未設定" };
  const r = await fetch("https://api.line.me/v2/bot/message/push", { method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` }, body: JSON.stringify({ to: lineUserId, messages: [{ type: "text", text }] }) });
  if (!r.ok) return { ok: false, error: `LINE ${r.status} ${(await r.text()).slice(0, 160)}` };
  return { ok: true };
}
async function inviteSetting(sb: any): Promise<{ url: string; note: string } | null> {
  const { data } = await sb.from("app_settings").select("value").eq("key", "slack_invite").maybeSingle();
  const v = data?.value ?? null;
  return v?.url ? { url: String(v.url), note: String(v.note ?? "") } : null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ ok: false, error: "POSTのみ" }, 405);
  const a = await auth(req);
  if (!a) return json({ ok: false, error: "権限がありません（本部・社長・マスターのログインが必要です）" }, 401);
  let b: any = {};
  try { b = await req.json(); } catch { b = {}; }
  const sb = svc();
  const op = String(b.op ?? "");
  try {
    if (op === "sync") return json(await sync(sb));
    if (a.mode === "secret") return json({ ok: false, error: "この操作はログインが必要です" }, 403);
    const actorId = a.actor?.id ?? null;

    if (op === "members") {
      const members = await listMembers();
      const { data: links } = await sb.from("user_slack").select("user_id,slack_user_id");
      const { data: users } = await sb.from("users").select("id,name");
      const uname = new Map<string, string>((users ?? []).map((u: any) => [u.id, u.name]));
      const bySlack = new Map<string, string>((links ?? []).map((l: any) => [l.slack_user_id, l.user_id]));
      return json({ ok: true, members: members.map((m) => ({ id: m.id, name: m.real_name, display_name: m.display_name, email_masked: m.email ? mask(m.email) : "", linked_user_id: bySlack.get(m.id) ?? null, linked_user_name: bySlack.get(m.id) ? uname.get(bySlack.get(m.id)!) ?? "" : "" })).sort((x, y) => (x.linked_user_id ? 1 : 0) - (y.linked_user_id ? 1 : 0) || x.name.localeCompare(y.name, "ja")) });
    }
    if (op === "set_invite") {
      const url = String(b.url ?? "").trim();
      if (!/^https:\/\/(join\.slack\.com|[a-z0-9-]+\.slack\.com)\//.test(url)) return json({ ok: false, error: "Slack の招待リンク（https://join.slack.com/… か https://xxx.slack.com/…）を入れてください" }, 400);
      const { error } = await sb.from("app_settings").upsert({ key: "slack_invite", value: { url, note: String(b.note ?? ""), set_at: new Date().toISOString(), set_by: actorId }, updated_at: new Date().toISOString(), updated_by: actorId }, { onConflict: "key" });
      if (error) return json({ ok: false, error: error.message }, 500);
      return json({ ok: true });
    }
    if (op === "invite") {
      const uid = String(b.user_id ?? "");
      const { data: u } = await sb.from("users").select("id,name,email,line_user_id,is_active").eq("id", uid).maybeSingle();
      if (!u) return json({ ok: false, error: "従業員が見つかりません" }, 404);
      const inv = await inviteSetting(sb);
      if (!inv) return json({ ok: false, code: "no_invite_url", error: "Slack の招待リンクがまだ登録されていません（従業員一覧の「Slack の招待リンクを設定」から入れてください）" }, 400);
      const text = `【${u.name}さん】会社の連絡を Slack に移します。下のリンクから Slack に登録してください。\n\n${inv.url}\n\n★登録するときのメールは、管理システムに登録している「${u.email}」にしてください（同じメールだと自動で管理システムと紐づきます）。${inv.note ? "\n" + inv.note : ""}`;
      if (b.channel === "copy") {
        await sb.from("slack_invite_log").insert({ user_id: uid, sent_by: actorId, channel: "copy" });
        return json({ ok: true, sent_via: "copy", invite_url: inv.url, text });
      }
      if (b.channel === "email") {
        if (!u.email) return json({ ok: false, code: "no_email", error: "この人はメールが登録されていません", invite_url: inv.url, text });
        const r = await emailSend(u.email, "【鳥一代グループ】Slack 登録のお願い", text);
        if (!r.ok) return json({ ok: false, error: r.error, invite_url: inv.url, text }, 502);
        await sb.from("slack_invite_log").insert({ user_id: uid, sent_by: actorId, channel: "email" });
        return json({ ok: true, sent_via: "email" });
      }
      if (b.channel === "auto") b.channel = u.line_user_id ? "line" : "email";
      if (b.channel === "email") {   // auto でメールに倒れたとき
        const r = await emailSend(u.email, "【鳥一代グループ】Slack 登録のお願い", text);
        if (!r.ok) return json({ ok: false, error: r.error, invite_url: inv.url, text }, 502);
        await sb.from("slack_invite_log").insert({ user_id: uid, sent_by: actorId, channel: "email" });
        return json({ ok: true, sent_via: "email" });
      }
      if (!u.line_user_id) return json({ ok: false, code: "no_line", error: "この人は LINE 未連携なので LINE では送れません。「メールで送る」か、文面をコピーして渡してください", invite_url: inv.url, text });
      const r = await linePush(sb, u.line_user_id, text);
      if (!r.ok) return json({ ok: false, error: "LINE 送信に失敗: " + r.error, invite_url: inv.url, text }, 502);
      await sb.from("slack_invite_log").insert({ user_id: uid, sent_by: actorId, channel: "line" });
      return json({ ok: true, sent_via: "line" });
    }
    if (op === "link") {
      const uid = String(b.user_id ?? ""), sid = String(b.slack_user_id ?? "");
      if (!uid || !/^[UW][A-Z0-9]+$/.test(sid)) return json({ ok: false, error: "従業員と Slack メンバーを選んでください" }, 400);
      const { data: dup } = await sb.from("user_slack").select("user_id").eq("slack_user_id", sid).neq("user_id", uid).maybeSingle();
      if (dup) return json({ ok: false, error: "その Slack メンバーは別の従業員に紐づいています。先にそちらを解除してください" }, 409);
      const members = await listMembers();
      const m = members.find((x) => x.id === sid);
      const now = new Date().toISOString();
      const { error } = await sb.from("user_slack").upsert({ user_id: uid, slack_user_id: sid, matched_by: "manual", matched_email: m?.email ?? null, matched_at: now, slack_name: m?.real_name ?? null, slack_display_name: m?.display_name ?? null, updated_at: now }, { onConflict: "user_id" });
      if (error) return json({ ok: false, error: error.message }, 500);
      return json({ ok: true, slack_name: m?.real_name ?? "" });
    }
    if (op === "unlink") {
      const uid = String(b.user_id ?? "");
      const { error } = await sb.from("user_slack").delete().eq("user_id", uid);
      if (error) return json({ ok: false, error: error.message }, 500);
      return json({ ok: true });
    }
    if (op === "status") {
      const inv = await inviteSetting(sb);
      const uid = b.user_id ? String(b.user_id) : null;
      const { data: link } = uid ? await sb.from("user_slack").select("*").eq("user_id", uid).maybeSingle() : { data: null };
      const { data: log } = uid ? await sb.from("slack_invite_log").select("channel,sent_at,sent_by").eq("user_id", uid).order("sent_at", { ascending: false }).limit(5) : { data: [] };
      return json({ ok: true, invite_url: inv?.url ?? null, invite_note: inv?.note ?? "", link, invites: log ?? [] });
    }
    return json({ ok: false, error: "op は sync / members / invite / link / unlink / set_invite / status" }, 400);
  } catch (e) { return json({ ok: false, error: String(e).slice(0, 300) }, 500); }
});
