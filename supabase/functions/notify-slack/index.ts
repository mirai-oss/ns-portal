// =============================================================
// notify-slack — Slack 送信専用 Edge Function（Phase 1 ドラフト・2026-10-29）
// 状態: ★ 未デプロイ ★（TK-243 で疎通テストのうえデプロイ。設計: docs/設計書_Slack通知基盤_Phase1_2026-10-29.md §4）
//
// 役割: 社内の全送信元（DB関数 / 他のEdge Function / Mac mini / GitHub Actions / ポータル画面）から
//       「channel_key ＋ 本文」を受け取り、Slack に送る唯一の出口。Bot Token はこの関数の secret にだけ置く。
//       1通ごとに notification_deliveries（台帳）へ notification_id → channel_key → slack_channel_id → slack_ts
//       → delivery_status を残す。
//
// 認証（いずれか1つ）:
//   A) Authorization: Bearer <service_role キー>      … 他の Edge Function・運用スクリプト
//   B) x-notify-secret: <NOTIFY_SLACK_SECRET>          … DB(pg_net)・Mac mini・GitHub Actions
//   C) Authorization: Bearer <ログインユーザーのJWT>    … ポータル画面（CEO/HQ/master のみ）
//
// secrets（supabase secrets set …。コード・リポジトリに書かない）:
//   SLACK_BOT_TOKEN       Bot User OAuth Token（xoxb-…）
//   NOTIFY_SLACK_SECRET   内部合言葉（app_secrets.notify_slack_secret / Mac mini .env / GitHub Secrets と同じ値）
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY / SUPABASE_ANON_KEY は自動で入る
//
// デプロイ: supabase functions deploy notify-slack --no-verify-jwt --project-ref uuvsxzhpxtghojoubjcc
//   （B の合言葉方式があるため JWT 検証は関数内で行う）
// =============================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info, x-notify-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });

const SLACK_API = "https://slack.com/api/";
const TEXT_LIMIT = 3900; // 1メッセージの本文上限（Slack は 40,000 だが読みやすさのため分割）

type SendBody = {
  action?: "send" | "update" | "users_sync" | "channels" | "health";
  notification_id?: string;
  channel_key?: string;          // 'hq.keiri_kanshi' または 'user:<users.id>'
  text?: string;
  blocks?: unknown[];
  thread_ts?: string;
  dedupe_key?: string;
  event?: string;
  source?: string;
  ref?: { table?: string; id?: string };
  legacy?: { kind?: string; sent?: boolean };
  username?: string;             // chat:write.customize（送信元の見分け用。例: '経営日報'）
  icon_emoji?: string;
  dry_run?: boolean;             // users_sync 用
};

const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

// ---- 認証 ---------------------------------------------------
async function authorize(req: Request): Promise<{ ok: boolean; mode?: string; user_id?: string; error?: string }> {
  const secret = (Deno.env.get("NOTIFY_SLACK_SECRET") ?? "").trim();
  const hdrSecret = (req.headers.get("x-notify-secret") ?? "").trim();
  if (secret && hdrSecret && timingSafeEqual(secret, hdrSecret)) return { ok: true, mode: "secret" };

  const auth = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!auth) return { ok: false, error: "認証がありません" };
  const serviceKey = (Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "").trim();
  if (serviceKey && timingSafeEqual(auth, serviceKey)) return { ok: true, mode: "service_role" };

  // ログインユーザー（ポータル画面）: CEO/HQ/master だけ許可
  const anon = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: `Bearer ${auth}` } },
  });
  const { data: u } = await anon.auth.getUser();
  if (!u?.user) return { ok: false, error: "ログインが必要です" };
  const { data: row } = await svc().from("users").select("role,is_master,is_active").eq("id", u.user.id).maybeSingle();
  if (!row?.is_active || !(row.is_master || ["CEO", "HQ"].includes(row.role))) return { ok: false, error: "権限がありません" };
  return { ok: true, mode: "user", user_id: u.user.id };
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}

// ---- Slack API ----------------------------------------------
async function slack(method: string, body: Record<string, unknown>): Promise<any> {
  const token = Deno.env.get("SLACK_BOT_TOKEN");
  if (!token) return { ok: false, error: "SLACK_BOT_TOKEN_not_configured" };
  for (let attempt = 0; attempt < 3; attempt++) {
    const res = await fetch(SLACK_API + method, {
      method: "POST",
      headers: { "Content-Type": "application/json; charset=utf-8", Authorization: `Bearer ${token}` },
      body: JSON.stringify(body),
    });
    if (res.status === 429) {
      const wait = Math.min(Number(res.headers.get("retry-after") ?? "1"), 5);
      await new Promise((r) => setTimeout(r, wait * 1000));
      continue;
    }
    return await res.json();
  }
  return { ok: false, error: "ratelimited" };
}

// ---- 宛先解決 ------------------------------------------------
async function resolveTarget(sb: any, channelKey: string): Promise<{ channel?: string; slack_user_id?: string; error?: string }> {
  if (channelKey.startsWith("user:")) {
    const userId = channelKey.slice(5);
    const { data: us } = await sb.from("user_slack").select("slack_user_id").eq("user_id", userId).maybeSingle();
    if (!us?.slack_user_id) return { error: `Slack未紐付けのユーザー: ${userId}` };
    const opened = await slack("conversations.open", { users: us.slack_user_id });
    if (!opened.ok) return { error: `conversations.open: ${opened.error}` };
    return { channel: opened.channel.id, slack_user_id: us.slack_user_id };
  }
  const { data: ch } = await sb.from("slack_channels").select("slack_channel_id,is_active").eq("channel_key", channelKey).maybeSingle();
  if (!ch) return { error: `unknown channel_key: ${channelKey}` };
  if (!ch.is_active) return { error: `inactive channel_key: ${channelKey}` };
  if (!ch.slack_channel_id) return { error: `slack_channel_id 未設定: ${channelKey}` };
  return { channel: ch.slack_channel_id };
}

// ---- send ---------------------------------------------------
async function doSend(sb: any, b: SendBody, actor: string) {
  const channelKey = (b.channel_key ?? "").trim();
  const text = (b.text ?? "").trim();
  if (!channelKey) return json({ ok: false, error: "channel_key が必要です" }, 400);
  if (!text && !b.blocks) return json({ ok: false, error: "text か blocks が必要です" }, 400);

  // 冪等: dedupe_key が既に sent なら再送しない
  if (b.dedupe_key) {
    const { data: dup } = await sb.from("notification_deliveries").select("id,slack_channel_id,slack_ts,delivery_status")
      .eq("dedupe_key", b.dedupe_key).maybeSingle();
    if (dup && (dup.delivery_status === "sent" || dup.delivery_status === "updated")) {
      return json({ ok: true, notification_id: dup.id, slack_channel_id: dup.slack_channel_id, ts: dup.slack_ts, status: "duplicate" });
    }
  }

  // 台帳の行を確保（DB からの呼び出しは notification_id 付きで来る＝既に queued 行がある）
  let id = b.notification_id ?? null;
  const base = {
    source: b.source ?? actor, event: b.event ?? "generic", channel_key: channelKey,
    payload: { text: text.slice(0, 40000), blocks: b.blocks ?? null, thread_ts: b.thread_ts ?? null },
    dedupe_key: b.dedupe_key ?? null, ref_table: b.ref?.table ?? null, ref_id: b.ref?.id ?? null,
    legacy_kind: b.legacy?.kind ?? null, legacy_sent: b.legacy?.sent ?? null,
  };
  if (id) {
    await sb.from("notification_deliveries").update({ ...base, updated_at: new Date().toISOString() }).eq("id", id);
  } else {
    const { data: ins, error } = await sb.from("notification_deliveries").insert(base).select("id").single();
    if (error) return json({ ok: false, error: "台帳に書けません: " + error.message }, 500);
    id = ins.id;
  }

  const target = await resolveTarget(sb, channelKey);
  if (target.error) {
    await sb.from("notification_deliveries").update({ delivery_status: "failed", error: target.error, attempts: 1, updated_at: new Date().toISOString() }).eq("id", id);
    return json({ ok: false, notification_id: id, error: target.error }, 422);
  }

  // 本文が長いときは先頭を本文、残りをスレッド返信にする
  const head = text.length > TEXT_LIMIT ? text.slice(0, TEXT_LIMIT) + "\n…（続きはスレッド）" : text;
  const msg: Record<string, unknown> = {
    channel: target.channel, text: head,
    ...(b.blocks ? { blocks: b.blocks } : {}),
    ...(b.thread_ts ? { thread_ts: b.thread_ts } : {}),
    ...(b.username ? { username: b.username } : {}),
    ...(b.icon_emoji ? { icon_emoji: b.icon_emoji } : {}),
    metadata: { event_type: b.event ?? "generic", event_payload: { notification_id: id } },
    unfurl_links: false, unfurl_media: false,
  };
  const res = await slack("chat.postMessage", msg);
  const now = new Date().toISOString();
  if (!res.ok) {
    await sb.from("notification_deliveries").update({ delivery_status: "failed", error: res.error ?? "slack_error", response: res, attempts: 1, slack_channel_id: target.channel, slack_user_id: target.slack_user_id ?? null, updated_at: now }).eq("id", id);
    return json({ ok: false, notification_id: id, error: res.error }, 502);
  }
  if (text.length > TEXT_LIMIT) {
    for (let i = TEXT_LIMIT; i < text.length; i += TEXT_LIMIT) {
      await slack("chat.postMessage", { channel: target.channel, thread_ts: res.ts, text: text.slice(i, i + TEXT_LIMIT) });
    }
  }
  await sb.from("notification_deliveries").update({
    delivery_status: "sent", slack_channel_id: target.channel, slack_user_id: target.slack_user_id ?? null,
    slack_ts: res.ts, thread_ts: b.thread_ts ?? null, response: { ok: true, ts: res.ts }, attempts: 1, sent_at: now, updated_at: now,
  }).eq("id", id);
  return json({ ok: true, notification_id: id, slack_channel_id: target.channel, ts: res.ts, status: "sent" });
}

// ---- update（送信済みメッセージの差し替え。ボタン操作後の「✅修正済み」など）----
async function doUpdate(sb: any, b: SendBody) {
  if (!b.notification_id) return json({ ok: false, error: "notification_id が必要です" }, 400);
  const { data: row } = await sb.from("notification_deliveries").select("id,slack_channel_id,slack_ts,payload").eq("id", b.notification_id).maybeSingle();
  if (!row?.slack_ts) return json({ ok: false, error: "送信済みの通知ではありません" }, 404);
  const res = await slack("chat.update", {
    channel: row.slack_channel_id, ts: row.slack_ts,
    text: (b.text ?? row.payload?.text ?? "").slice(0, TEXT_LIMIT),
    ...(b.blocks ? { blocks: b.blocks } : { blocks: [] }),
  });
  const now = new Date().toISOString();
  await sb.from("notification_deliveries").update({
    delivery_status: res.ok ? "updated" : "failed", error: res.ok ? null : res.error, response: res,
    payload: { ...(row.payload ?? {}), updated_text: b.text ?? null, updated_blocks: b.blocks ?? null }, updated_at: now,
  }).eq("id", row.id);
  return json({ ok: !!res.ok, notification_id: row.id, error: res.error ?? null });
}

// ---- users_sync（users:read.email でメール照合 → user_slack）----
async function doUsersSync(sb: any, dryRun: boolean) {
  const members: any[] = [];
  let cursor = "";
  do {
    const r = await slack("users.list", { limit: 200, ...(cursor ? { cursor } : {}) });
    if (!r.ok) return json({ ok: false, error: r.error }, 502);
    members.push(...(r.members ?? []));
    cursor = r.response_metadata?.next_cursor ?? "";
  } while (cursor);
  const byEmail = new Map<string, string>();
  for (const m of members) {
    if (m.deleted || m.is_bot || m.id === "USLACKBOT") continue;
    const em = (m.profile?.email ?? "").toLowerCase().trim();
    if (em) byEmail.set(em, m.id);
  }
  const { data: users } = await sb.from("users").select("id,email,name,is_active").eq("is_active", true);
  const matched: { user_id: string; slack_user_id: string; matched_email: string }[] = [];
  const unmatchedUsers: string[] = [];
  for (const u of users ?? []) {
    const em = (u.email ?? "").toLowerCase().trim();
    const sid = em ? byEmail.get(em) : undefined;
    if (sid) matched.push({ user_id: u.id, slack_user_id: sid, matched_email: em });
    else unmatchedUsers.push(u.name ?? u.id);
  }
  const matchedSlackIds = new Set(matched.map((m) => m.slack_user_id));
  const unmatchedSlack = [...byEmail.entries()].filter(([, id]) => !matchedSlackIds.has(id)).map(([em]) => em.replace(/^(.).*(@.*)$/, "$1***$2"));
  if (!dryRun && matched.length) {
    const rows = matched.map((m) => ({ ...m, matched_by: "email", matched_at: new Date().toISOString(), updated_at: new Date().toISOString() }));
    const { error } = await sb.from("user_slack").upsert(rows, { onConflict: "user_id" });
    if (error) return json({ ok: false, error: error.message }, 500);
  }
  return json({ ok: true, dry_run: dryRun, matched: matched.length, unmatched_users: unmatchedUsers, unmatched_slack_emails_masked: unmatchedSlack });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ ok: false, error: "POSTのみ" }, 405);
  const auth = await authorize(req);
  if (!auth.ok) return json({ ok: false, error: auth.error }, 401);

  let b: SendBody;
  try { b = await req.json(); } catch (_) { return json({ ok: false, error: "JSONを読めません" }, 400); }
  const sb = svc();
  const actor = auth.mode === "user" ? `portal:${auth.user_id}` : (b.source ?? auth.mode ?? "unknown");

  switch (b.action ?? "send") {
    case "health": return json({ ok: true, token_configured: !!Deno.env.get("SLACK_BOT_TOKEN"), mode: auth.mode });
    case "channels": {
      const { data } = await sb.from("slack_channels").select("channel_key,display_name,purpose,is_active,slack_channel_id").order("channel_key");
      return json({ ok: true, channels: (data ?? []).map((c: any) => ({ ...c, slack_channel_id: c.slack_channel_id ? "set" : "" })) });
    }
    case "users_sync":
      if (auth.mode === "secret") return json({ ok: false, error: "users_sync は service_role か本部ユーザーのみ" }, 403);
      return await doUsersSync(sb, !!b.dry_run);
    case "update": return await doUpdate(sb, b);
    case "send": return await doSend(sb, b, actor);
    default: return json({ ok: false, error: "不明な action" }, 400);
  }
});
