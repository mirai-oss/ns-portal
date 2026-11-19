// 本部タスクの「チャンネルの親投稿」へのリンクを集める（2026-11-19）。
//   個人DMの通知から、「どのチャンネルのタスクか」を辿れるようにする。リンクは Slack の chat.getPermalink で取る（取れなければ、リンクなし）
export type ParentLink = { url: string; channel: string };

export async function permalinkOf(channel: string, ts: string): Promise<string | null> {
  const token = Deno.env.get("SLACK_BOT_TOKEN");
  if (!token || !channel || !ts) return null;
  try {
    const r = await fetch(`https://slack.com/api/chat.getPermalink?channel=${encodeURIComponent(channel)}&message_ts=${encodeURIComponent(ts)}`, { headers: { Authorization: `Bearer ${token}` } });
    const j = await r.json().catch(() => ({}));
    return j?.ok && typeof j.permalink === "string" ? j.permalink : null;
  } catch { return null; }
}

/** タスク ID → 親投稿のリンク（親投稿がまだ無いタスクは入らない） */
// deno-lint-ignore no-explicit-any
export async function parentLinks(sb: any, taskIds: string[]): Promise<Map<string, ParentLink>> {
  const out = new Map<string, ParentLink>();
  const ids = [...new Set(taskIds)].filter(Boolean);
  if (!ids.length) return out;
  const { data } = await sb.from("hq_slack_task_log").select("task_id,card_channel,parent_ts").in("task_id", ids);
  // deno-lint-ignore no-explicit-any
  const rows = ((data ?? []) as any[]).filter((r) => r.card_channel && r.parent_ts);
  await Promise.all(rows.map(async (r) => {
    const url = await permalinkOf(String(r.card_channel), String(r.parent_ts));
    if (url) out.set(String(r.task_id), { url, channel: String(r.card_channel) });
  }));
  return out;
}
