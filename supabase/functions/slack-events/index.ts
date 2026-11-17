// =============================================================
// slack-events — Slack の「イベント」の受け口（2026-11-17 新規）
//   いまの用途: @アプリ へのメンション（app_mention）→ 本部タスクの下書き（AI が文章から下書きを作り、本人が確認して作成）
//   Slack アプリの設定: Event Subscriptions の Request URL にこの関数の URL・購読は app_mention だけ・スコープ app_mentions:read
//   動き: ①署名を確かめる ②url_verification に答える ③app_mention は 3 秒以内に 200 を返し、本処理は後ろで行う（再送は無視）
//   本処理: 設定 hq_task_slack.ai_enabled が true・Slack と紐づいた本部/社長/店長/マスターだけ・1 日の上限（ai_daily_cap）以内
//     → 名簿（Slack ID と名前）と今日の日付を付けて、そのメンション 1 通の文章だけを AI に渡す（チャンネル全体は読まない）→ 下書きカードをスレッドに返す。
//   AI の鍵: Supabase の秘密情報 ANTHROPIC_API_KEY（コードには書かない）。モデル: hq_task_slack.ai_model（既定 claude-haiku-5-5）。
//   ログ: hq_slack_ai_log（イベント ID・状態・トークン数。本文は保存しない）。
// デプロイ: supabase functions deploy slack-events --no-verify-jwt --project-ref uuvsxzhpxtghojoubjcc --yes
// =============================================================
import { createClient } from "npm:@supabase/supabase-js@2";
import { callModel, draftCard, ensureChannelKey, jstToday, stripBotMention, systemPrompt, toDraft, type RosterEntry } from "../_shared/hqtask-ai.ts";

const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const text = (s: string, status = 200) => new Response(s, { status, headers: { "Content-Type": "text/plain; charset=utf-8" } });
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json" } });

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
async function sendSlack(body: Record<string, unknown>): Promise<any> {
  try {
    const res = await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/notify-slack`, {
      method: "POST", headers: { "Content-Type": "application/json", "x-notify-secret": Deno.env.get("NOTIFY_SLACK_SECRET") ?? "", apikey: Deno.env.get("SUPABASE_ANON_KEY") ?? "" }, body: JSON.stringify(body),
    });
    return await res.json();
  } catch (_e) { return { ok: false }; }
}
function waitUntil(p: Promise<unknown>) {
  // deno-lint-ignore no-explicit-any
  const rt = (globalThis as any).EdgeRuntime;
  try { if (rt?.waitUntil) { rt.waitUntil(p); return; } } catch (_) { /* fallthrough */ }
  p.catch(() => {});
}

// deno-lint-ignore no-explicit-any
async function reply(sb: any, channelId: string, threadTs: string, msg: string) {
  const key = await ensureChannelKey(sb, channelId);
  if (!key) return;
  await sendSlack({ action: "send", channel_key: key, thread_ts: threadTs, text: msg, event: "hqtask_ai_reply", source: "ef:slack-events" });
}

// deno-lint-ignore no-explicit-any
async function handleMention(body: any) {
  const ev = body.event;
  const sb = svc();
  const eventId = String(body.event_id ?? "");
  const channel = String(ev.channel ?? "");
  const threadTs = String(ev.thread_ts ?? ev.ts ?? "");
  if (!eventId || !channel || !threadTs) return;
  // 同じイベントは 1 回だけ処理（再送・二重配信を防ぐ）
  const ins = await sb.from("hq_slack_ai_log").insert({ event_id: eventId, status: "started" });
  if (ins.error) return;
  const finish = (status: string, extra: Record<string, unknown> = {}) => sb.from("hq_slack_ai_log").update({ status, ...extra }).eq("event_id", eventId);

  const { data: s } = await sb.from("app_settings").select("value").eq("key", "hq_task_slack").maybeSingle();
  const set = s?.value ?? {};
  if (set.ai_enabled !== true) { await finish("rejected"); await reply(sb, channel, threadTs, "この機能は、まだ有効になっていません。"); return; }
  const { data: link } = await sb.from("user_slack").select("user_id").eq("slack_user_id", ev.user).maybeSingle();
  const { data: me } = link ? await sb.from("users").select("id,name,role,is_master,is_active").eq("id", link.user_id).maybeSingle() : { data: null };
  if (!me?.is_active) { await finish("rejected"); await reply(sb, channel, threadTs, "あなたの Slack は、管理システムに紐づいていません。本部に連絡してください。"); return; }
  if (!(me.is_master || ["CEO", "HQ", "TENCHO"].includes(me.role))) { await finish("rejected", { user_id: me.id }); await reply(sb, channel, threadTs, "タスクを作れるのは、本部・社長・店長だけです。"); return; }
  // 1 日の上限（日本時間）
  const cap = Number(set.ai_daily_cap) > 0 ? Number(set.ai_daily_cap) : 200;
  const dayStart = new Date(new Date(Date.now() + 9 * 3600_000).toISOString().slice(0, 10) + "T00:00:00+09:00").toISOString();
  const { count } = await sb.from("hq_slack_ai_log").select("event_id", { count: "exact", head: true }).in("status", ["ok", "failed"]).gte("created_at", dayStart);
  if ((count ?? 0) >= cap) { await finish("over_cap", { user_id: me.id }); await reply(sb, channel, threadTs, `今日の AI の利用回数の上限（${cap} 回）に達しました。管理システムの本部タスク画面か、「＋ タスクを作る」のボタンのフォームから作ってください。`); return; }
  const apiKey = Deno.env.get("ANTHROPIC_API_KEY") ?? "";
  if (!apiKey) { await finish("failed", { user_id: me.id }); await reply(sb, channel, threadTs, "AI の設定が未完了です（本部に連絡してください）。"); return; }

  const botId: string | null = body.authorizations?.[0]?.user_id ?? null;
  const msg = stripBotMention(String(ev.text ?? ""), botId);
  if (msg.length < 4) { await finish("rejected", { user_id: me.id }); await reply(sb, channel, threadTs, "タスクの内容を書いてください。例：「@アプリ 田中さんに来週金曜までに請求書の確認をお願い」"); return; }

  const { data: ros } = await sb.from("user_slack").select("slack_user_id,user_id");
  const { data: us } = await sb.from("users").select("id,name,role").eq("is_active", true).in("id", (ros ?? []).map((r: any) => r.user_id));
  const byId = new Map((us ?? []).map((u: any) => [u.id, u]));
  const roster: RosterEntry[] = (ros ?? []).filter((r: any) => byId.has(r.user_id)).map((r: any) => ({ slack_user_id: r.slack_user_id, name: String((byId.get(r.user_id) as any).name ?? "").replace(/[\s　]+/g, ""), role: (byId.get(r.user_id) as any).role }));
  const today = jstToday();
  const out = await callModel({ apiKey, model: String(set.ai_model || "claude-haiku-5-5"), system: systemPrompt(today, roster), user: `次の文章から、本部タスクの下書きを作ってください。\n\n${msg}` });
  if (!out) { await finish("failed", { user_id: me.id }); await reply(sb, channel, threadTs, "うまく読み取れませんでした。「＋ タスクを作る」のボタンのフォームから作ってください。"); return; }
  const draft = toDraft(out.json, roster, today);
  const { data: row, error } = await sb.from("hq_slack_ai_draft").insert({ requester_id: me.id, channel_id: channel, thread_ts: threadTs, draft }).select("id").single();
  if (error || !row) { await finish("failed", { user_id: me.id, in_tokens: out.inTokens, out_tokens: out.outTokens }); return; }
  const names = new Map(roster.map((r) => [r.slack_user_id, r.name]));
  const card = draftCard(draft, row.id, names);
  const key = await ensureChannelKey(sb, channel);
  const r = key ? await sendSlack({ action: "send", channel_key: key, thread_ts: threadTs, text: card.text, blocks: card.blocks, event: "hqtask_ai_draft", source: "ef:slack-events", dedupe_key: `hqtask_ai_draft:${row.id}` }) : null;
  if (r?.notification_id) await sb.from("hq_slack_ai_draft").update({ card_notification_id: r.notification_id }).eq("id", row.id);
  await finish("ok", { user_id: me.id, in_tokens: out.inTokens, out_tokens: out.outTokens });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return text("POSTのみ", 405);
  const raw = await req.text();
  if (!(await verifySlackSignature(req, raw))) return text("署名が一致しません", 401);
  // deno-lint-ignore no-explicit-any
  let body: any = {}; try { body = JSON.parse(raw); } catch { return text("bad json", 400); }
  if (body.type === "url_verification") return json({ challenge: body.challenge });
  if (req.headers.get("x-slack-retry-num")) return text("ok");   // Slack の再送は無視（最初の 1 回で処理済み）
  if (body.type === "event_callback" && body.event?.type === "app_mention" && !body.event?.bot_id) waitUntil(handleMention(body));
  return text("ok");
});
