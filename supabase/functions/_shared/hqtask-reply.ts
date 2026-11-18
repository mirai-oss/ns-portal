// =============================================================
// hqtask-reply — Slack の DM スレッドへの返信 → 本部タスクのコメントとして書き込む（第2段階・2026-11-18 新規）
// 呼び出し元: EF slack-events（message イベント＝ DM のスレッド返信だけを渡す。署名検証は slack-events 側で済み）
// 処理本体は DB 関数 hqtask_comment_reply_post（二重処理の防止・スイッチ・対応表での照合・受け取り本人の確認・画面と同じ権限確認・コメント登録）
// ここでは: 返信した本人への結果の返信（同じスレッドに『コメントに投稿しました』／失敗の理由）だけを行う。本文は保存もログ出力もしない
// スイッチ: app_settings.hqtask_comment_reply（既定 OFF）。OFF・対応表に無いスレッド・受け取り本人以外の返信は、何も返さず無視する
// =============================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
async function sendSlack(body: Record<string, unknown>): Promise<unknown> {
  try {
    const res = await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/notify-slack`, {
      method: "POST", headers: { "Content-Type": "application/json", "x-notify-secret": Deno.env.get("NOTIFY_SLACK_SECRET") ?? "", apikey: Deno.env.get("SUPABASE_ANON_KEY") ?? "" },
      body: JSON.stringify(body),
    });
    return await res.json();
  } catch (_e) { return { ok: false }; }
}

// deno-lint-ignore no-explicit-any
export function isDmThreadReply(ev: any): boolean {
  return ev?.type === "message" && ev?.channel_type === "im" && typeof ev?.thread_ts === "string" && ev.thread_ts !== ev.ts
    && !ev?.bot_id && !ev?.subtype && typeof ev?.user === "string" && typeof ev?.text === "string" && !!ev?.channel;
}

// deno-lint-ignore no-explicit-any
export async function handleDmThreadReply(body: any) {
  const ev = body.event;
  const eventId = String(body.event_id ?? "");
  if (!eventId || !isDmThreadReply(ev)) return;
  const sb = svc();
  const { data, error } = await sb.rpc("hqtask_comment_reply_post", {
    p_event_id: eventId, p_channel: String(ev.channel), p_thread_ts: String(ev.thread_ts), p_slack_user: String(ev.user), p_body: String(ev.text),
  });
  if (error || !data) return;
  const code = String(data.code ?? "");
  const uid = typeof data.user_id === "string" ? data.user_id : null;
  const say = async (text: string) => { if (uid) await sendSlack({ action: "send", channel_key: `user:${uid}`, thread_ts: String(ev.thread_ts), text, event: "hqtask_comment_reply_result", source: "ef:slack-events" }); };
  if (code === "posted") await say(`✅ コメントに投稿しました（${String(data.title ?? "").slice(0, 60)}）`);
  else if (code === "denied") await say("⚠️ このタスクにコメントする権限がありません。投稿していません");
  else if (code === "too_long") await say("⚠️ 長すぎるため投稿していません（2000 文字まで）");
  // off / no_thread / not_owner / duplicate / empty / bad_args は、何も返さず無視する
}
