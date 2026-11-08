// =============================================================
// slack-events — Slack Events API の受け口（2026-11-08 新規）: 人が Slack に参加した瞬間に管理システムの従業員と紐づける
//   team_join / user_change: そのメンバーのメール（profile.email）と users.email が一致すれば user_slack に登録（matched_by=team_join）し、本人に DM で案内
//   url_verification: Slack がこの URL を登録するときの確認（challenge を返す）
// Slack アプリ側の設定（手順書）: Event Subscriptions を ON → Request URL にこの関数の URL → Subscribe to bot events に team_join・user_change
//   必要スコープ: users:read・users:read.email（取得済み）・chat:write（DM 用・取得済み）
// 署名検証は slack-interact と同じ（SLACK_SIGNING_SECRET）。3 秒以内に 200 を返し、処理は waitUntil で
// デプロイ: supabase functions deploy slack-events --no-verify-jwt --project-ref uuvsxzhpxtghojoubjcc --yes
// =============================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json" } });
declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void } | undefined;
function waitUntil(p: Promise<unknown>) {
  try { if (typeof EdgeRuntime !== "undefined" && EdgeRuntime?.waitUntil) { EdgeRuntime.waitUntil(p); return; } } catch (_) { /* fallthrough */ }
  p.catch(() => {});
}
async function verifySlackSignature(req: Request, rawBody: string): Promise<boolean> {
  const secret = Deno.env.get("SLACK_SIGNING_SECRET") ?? "";
  const ts = req.headers.get("x-slack-request-timestamp") ?? "";
  const sig = req.headers.get("x-slack-signature") ?? "";
  if (!secret || !ts || !sig) return false;
  if (Math.abs(Date.now() / 1000 - Number(ts)) > 60 * 5) return false;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`v0:${ts}:${rawBody}`));
  const expected = "v0=" + [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("");
  if (expected.length !== sig.length) return false;
  let r = 0; for (let i = 0; i < expected.length; i++) r |= expected.charCodeAt(i) ^ sig.charCodeAt(i);
  return r === 0;
}
async function notifySlack(body: Record<string, unknown>) {
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  try {
    const res = await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/notify-slack`, { method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}`, apikey: key }, body: JSON.stringify(body) });
    return await res.json().catch(() => null);
  } catch { return null; }
}

// メンバー 1 人をメールで紐づける。すでに紐づいていれば何もしない（手動紐づけを壊さない）
async function linkMember(sb: any, m: any): Promise<{ linked: boolean; user?: any; reason?: string }> {
  if (!m?.id || m.deleted || m.is_bot) return { linked: false, reason: "bot_or_deleted" };
  const em = String(m.profile?.email ?? "").toLowerCase().trim();
  if (!em) return { linked: false, reason: "no_email" };
  const { data: exists } = await sb.from("user_slack").select("user_id").eq("slack_user_id", m.id).maybeSingle();
  if (exists) return { linked: false, reason: "already" };
  const { data: u } = await sb.from("users").select("id,name,email,is_active").ilike("email", em).eq("is_active", true).maybeSingle();
  if (!u) return { linked: false, reason: "no_match" };
  const { data: taken } = await sb.from("user_slack").select("slack_user_id").eq("user_id", u.id).maybeSingle();
  if (taken) return { linked: false, reason: "user_already_linked" };
  const now = new Date().toISOString();
  const { error } = await sb.from("user_slack").upsert({ user_id: u.id, slack_user_id: m.id, matched_by: "team_join", matched_email: em, matched_at: now, slack_name: m.real_name ?? m.profile?.real_name ?? null, slack_display_name: m.profile?.display_name ?? null, updated_at: now }, { onConflict: "user_id" });
  if (error) return { linked: false, reason: error.message };
  return { linked: true, user: u };
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("POSTのみ", { status: 405 });
  const raw = await req.text();
  let body: any = {};
  try { body = JSON.parse(raw); } catch { return new Response("bad json", { status: 400 }); }
  // URL 登録時の確認は署名より先（Slack の仕様どおり challenge を返す。署名も付いているので検証はする）
  if (body.type === "url_verification") {
    if (!(await verifySlackSignature(req, raw))) return new Response("bad signature", { status: 401 });
    return json({ challenge: body.challenge });
  }
  if (!(await verifySlackSignature(req, raw))) return new Response("bad signature", { status: 401 });
  if (body.type !== "event_callback") return new Response("", { status: 200 });
  const ev = body.event ?? {};
  if (ev.type !== "team_join" && ev.type !== "user_change") {
    waitUntil(svc().from("slack_event_log").insert({ event_type: String(ev.type ?? "?"), result: "ignored", raw: { event_id: body.event_id ?? null } }).then(() => {}));
  }
  if (ev.type === "team_join" || ev.type === "user_change") {
    waitUntil((async () => {
      const sb = svc();
      const r = await linkMember(sb, ev.user);
      // 2026-11-08: 届いたイベントは全部記録（「届いているのに紐づかない」と「届いていない」を見分けるため）
      try {
        const em = String(ev.user?.profile?.email ?? "");
        await sb.from("slack_event_log").insert({ event_type: ev.type, slack_user_id: ev.user?.id ?? null, email_masked: em ? em.replace(/^(.).*(@.*)$/, "$1***$2") : null, result: r.linked ? "linked" : (r.reason ?? "?"), user_id: r.user?.id ?? null, raw: { team: body.team_id ?? null, event_id: body.event_id ?? null, event_time: body.event_time ?? null, real_name: ev.user?.real_name ?? null, is_bot: !!ev.user?.is_bot, deleted: !!ev.user?.deleted } });
      } catch (_) { /* 記録の失敗は無視 */ }
      if (r.linked && ev.type === "team_join") {
        await notifySlack({ action: "send", channel_key: `user:${r.user.id}`, event: "slack_link_welcome", source: "ef:slack-events",
          text: `👋 ${r.user.name}さん、N-Style の Slack へようこそ。管理システムの従業員情報と自動で紐づきました。\n勤怠確認のボタンや申請のやりとりがここに届きます。`,
          dedupe_key: `slack_link_welcome:${r.user.id}`, username: "N-Style 通知Bot" });
      }
      if (r.linked) await notifySlack({ action: "send", channel_key: "hq.dev_system", event: "slack_link", source: "ef:slack-events",
        text: `🔗 Slack 紐づけ: ${r.user.name} ↔ ${ev.user?.real_name ?? ev.user?.id}（${ev.type}・メール一致）`, dedupe_key: `slack_link:${r.user.id}:${ev.user?.id}` });
    })());
  }
  return new Response("", { status: 200 });
});
