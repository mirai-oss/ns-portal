// @アプリ へのメンション（app_mention）→ 本部タスクの下書き。EF slack-events（既存: team_join・user_change の自動紐づけ）から呼ばれる。
//   AI は、メンションされた 1 通の文章だけを読んで下書きを作る。作成は本人が「作成する」を押したとき。詳細は _shared/hqtask-ai.ts・EF slack-events の冒頭。
import { createClient } from "npm:@supabase/supabase-js@2";
import { callModel, draftCard, ensureChannelKey, jstToday, stripBotMention, systemPrompt, toDraft, type RosterEntry } from "./hqtask-ai.ts";

const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
async function sendSlack(body: Record<string, unknown>): Promise<any> {
  try {
    const res = await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/notify-slack`, {
      method: "POST", headers: { "Content-Type": "application/json", "x-notify-secret": Deno.env.get("NOTIFY_SLACK_SECRET") ?? "", apikey: Deno.env.get("SUPABASE_ANON_KEY") ?? "" }, body: JSON.stringify(body),
    });
    return await res.json();
  } catch (_e) { return { ok: false }; }
}
// deno-lint-ignore no-explicit-any
async function reply(sb: any, channelId: string, threadTs: string, msg: string, dmKey: string | null = null) {
  const key = dmKey ?? await ensureChannelKey(sb, channelId);
  if (!key) return;
  await sendSlack({ action: "send", channel_key: key, thread_ts: threadTs, text: msg, event: "hqtask_ai_reply", source: "ef:slack-events" });
}

// deno-lint-ignore no-explicit-any
export async function handleMention(body: any) {
  const ev = body.event;
  const sb = svc();
  const eventId = String(body.event_id ?? "");
  const channel = String(ev.channel ?? "");
  const isDm = String(ev.channel_type ?? "") === "im";   // 2026-11-19 アプリとの DM に直接書かれた依頼（チャンネルには何も残らない）
  let dmKey: string | null = null;
  const threadTs = String(ev.thread_ts ?? ev.ts ?? "");
  if (!eventId || !channel || !threadTs) return;
  // 同じイベントは 1 回だけ処理（再送・二重配信を防ぐ）
  const ins = await sb.from("hq_slack_ai_log").insert({ event_id: eventId, status: "started" });
  if (ins.error) return;
  const finish = (status: string, extra: Record<string, unknown> = {}) => sb.from("hq_slack_ai_log").update({ status, ...extra }).eq("event_id", eventId);

  const { data: s } = await sb.from("app_settings").select("value").eq("key", "hq_task_slack").maybeSingle();
  const set = s?.value ?? {};
  if (set.ai_enabled !== true) { await finish("rejected"); await reply(sb, channel, threadTs, "この機能は、まだ有効になっていません。", dmKey); return; }
  const { data: link } = await sb.from("user_slack").select("user_id").eq("slack_user_id", ev.user).maybeSingle();
  const { data: me } = link ? await sb.from("users").select("id,name,role,is_master,is_active").eq("id", link.user_id).maybeSingle() : { data: null };
  if (isDm && me?.id) dmKey = `user:${me.id}`;
  if (!me?.is_active) { await finish("rejected"); await reply(sb, channel, threadTs, "あなたの Slack は、管理システムに紐づいていません。本部に連絡してください。", dmKey); return; }
  if (!(me.is_master || ["CEO", "HQ", "TENCHO"].includes(me.role))) { await finish("rejected", { user_id: me.id }); await reply(sb, channel, threadTs, "タスクを作れるのは、本部・社長・店長だけです。", dmKey); return; }
  // 1 日の上限（日本時間）
  const cap = Number(set.ai_daily_cap) > 0 ? Number(set.ai_daily_cap) : 200;
  const dayStart = new Date(new Date(Date.now() + 9 * 3600_000).toISOString().slice(0, 10) + "T00:00:00+09:00").toISOString();
  const { count } = await sb.from("hq_slack_ai_log").select("event_id", { count: "exact", head: true }).in("status", ["ok", "failed"]).gte("created_at", dayStart);
  if ((count ?? 0) >= cap) { await finish("over_cap", { user_id: me.id }); await reply(sb, channel, threadTs, `今日の AI の利用回数の上限（${cap} 回）に達しました。管理システムの本部タスク画面か、「＋ タスクを作る」のボタンのフォームから作ってください。`, dmKey); return; }
  const apiKey = Deno.env.get("ANTHROPIC_API_KEY") ?? "";
  if (!apiKey) { await finish("failed", { user_id: me.id }); await reply(sb, channel, threadTs, "AI の設定が未完了です（本部に連絡してください）。", dmKey); return; }

  const botId: string | null = body.authorizations?.[0]?.user_id ?? null;
  const msg = stripBotMention(String(ev.text ?? ""), botId);
  if (msg.length < 4) { await finish("rejected", { user_id: me.id }); await reply(sb, channel, threadTs, "タスクの内容を書いてください。例：「@アプリ 田中さんに来週金曜までに請求書の確認をお願い」", dmKey); return; }

  const { data: ros } = await sb.from("user_slack").select("slack_user_id,user_id");
  const { data: us } = await sb.from("users").select("id,name,role").eq("is_active", true).in("id", (ros ?? []).map((r: any) => r.user_id));
  const byId = new Map((us ?? []).map((u: any) => [u.id, u]));
  const roster: RosterEntry[] = (ros ?? []).filter((r: any) => byId.has(r.user_id)).map((r: any) => ({ slack_user_id: r.slack_user_id, name: String((byId.get(r.user_id) as any).name ?? "").replace(/[\s　]+/g, ""), role: (byId.get(r.user_id) as any).role }));
  const today = jstToday();
  const out = await callModel({ apiKey, model: String(set.ai_model || "claude-haiku-5-5"), system: systemPrompt(today, roster), user: `次の文章から、本部タスクの下書きを作ってください。\n\n${msg}` });
  if (!out) { await finish("failed", { user_id: me.id }); await reply(sb, channel, threadTs, "うまく読み取れませんでした。「＋ タスクを作る」のボタンのフォームから作ってください。", dmKey); return; }
  const draft = toDraft(out.json, roster, today);
  const { data: row, error } = await sb.from("hq_slack_ai_draft").insert({ requester_id: me.id, channel_id: channel, thread_ts: threadTs, draft }).select("id").single();
  if (error || !row) { await finish("failed", { user_id: me.id, in_tokens: out.inTokens, out_tokens: out.outTokens }); return; }
  const names = new Map(roster.map((r) => [r.slack_user_id, r.name]));
  const card = draftCard(draft, row.id, names);
  const key = dmKey ?? await ensureChannelKey(sb, channel);
  const r = key ? await sendSlack({ action: "send", channel_key: key, thread_ts: threadTs, text: card.text, blocks: card.blocks, event: "hqtask_ai_draft", source: "ef:slack-events", dedupe_key: `hqtask_ai_draft:${row.id}` }) : null;
  if (r?.notification_id) await sb.from("hq_slack_ai_draft").update({ card_notification_id: r.notification_id }).eq("id", row.id);
  await finish("ok", { user_id: me.id, in_tokens: out.inTokens, out_tokens: out.outTokens });
}

