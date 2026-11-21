// 本部タスクの個人 DM（期限のリマインド・担当になった通知）のうち、工程が完了した（管理システムで完了・ほかの人が完了・タスクが削除された）あとも、
// 「今日が期限です」とボタンのまま残っているものを、「✅ 完了済み」に書き換える（2026-11-21 社長依頼）。
//   Slack のボタンで完了にした人のメッセージは今までも書き換わっていたが、管理システムで完了にした場合や、同じ工程の担当が複数いる場合のほかの人の DM は、残っていた。
//   定期的に（10 分おき）呼ばれ、ボタンが残っているメッセージだけを見て、工程が完了していれば書き換える。書き換えたあとはボタンが無くなるので、2 回目以降は対象外。
//   新しい通知は出さない（既存のメッセージの更新だけ）。
const EVENTS = ["hqtask_reminder", "hqtask_assigned"];
const DAYS = 7;

// deno-lint-ignore no-explicit-any
type Sb = any;
export type Notify = (body: Record<string, unknown>) => Promise<{ ok?: boolean; error?: string } | null>;

const jst = (iso: string | null | undefined) => {
  if (!iso) return "";
  const t = new Date(iso).getTime();
  if (!Number.isFinite(t)) return "";
  const j = new Date(t + 9 * 3600e3);
  return `${j.getUTCMonth() + 1}/${j.getUTCDate()} ${String(j.getUTCHours()).padStart(2, "0")}:${String(j.getUTCMinutes()).padStart(2, "0")}`;
};
const clean = (s: unknown, max = 100) => String(s ?? "").replace(/[\n\r|<>*_~`]/g, " ").trim().slice(0, max) || "—";

/** いま Slack に出ているブロック（更新されていれば更新後）から、操作ボタンが指している工程の id を取り出す。ボタンが無ければ null */
export function liveStepId(payload: unknown): string | null {
  // deno-lint-ignore no-explicit-any
  const p = (payload ?? {}) as any;
  const blocks = (Array.isArray(p.updated_blocks) ? p.updated_blocks : Array.isArray(p.blocks) ? p.blocks : []) as unknown[];
  for (const b of blocks as { type?: string; elements?: { action_id?: string; value?: string }[] }[]) {
    if (b?.type !== "actions") continue;
    for (const e of b.elements ?? []) {
      if (e?.action_id !== "hqtask.step.done" && e?.action_id !== "hqtask.step.ack") continue;   // ［完了にする］［対応中］が残っているものだけ（完了済みの［↩️ 取り消し］は触らない）
      try { const v = JSON.parse(String(e.value ?? "{}")); if (typeof v?.step_id === "string" && /^[0-9a-f-]{36}$/i.test(v.step_id)) return v.step_id; } catch { /* 次へ */ }
    }
  }
  return null;
}

/** 書き換え後の文面（ボタンなし） */
export function doneMessage(o: { title: string; stepTitle?: string | null; completedAt?: string | null; deleted?: boolean }): { text: string; blocks: unknown[] } {
  const title = clean(o.title);
  const step = o.stepTitle ? `　工程：${clean(o.stepTitle, 60)}` : "";
  const text = o.deleted ? `🗑 このタスクは削除されました：${title}` : `✅ 完了済み：${title}`;
  const lines = [o.deleted ? `🗑 *このタスクは削除されました*` : `✅ *完了済み*`, `*${title}*${step}`];
  if (!o.deleted && o.completedAt) lines.push(`完了：${jst(o.completedAt)}（このメッセージは、完了のあと自動で書き換えました）`);
  return { text, blocks: [{ type: "section", text: { type: "mrkdwn", text: lines.join("\n") } }] };
}

export async function refreshDoneCards(sb: Sb, notify: Notify, o: { dryRun?: boolean; max?: number } = {}): Promise<{ ok: boolean; checked: number; live: number; updated: number; failed: number; error?: string }> {
  const since = new Date(Date.now() - DAYS * 86400e3).toISOString();
  const { data: rows, error } = await sb.from("notification_deliveries").select("id,payload").in("event", EVENTS).like("channel_key", "user:%").in("delivery_status", ["sent", "updated"]).gte("created_at", since).order("created_at", { ascending: false }).limit(1000);
  if (error) return { ok: false, checked: 0, live: 0, updated: 0, failed: 0, error: String(error.message ?? error) };
  const live = ((rows ?? []) as { id: string; payload: unknown }[]).map((r) => ({ id: r.id, stepId: liveStepId(r.payload) })).filter((r): r is { id: string; stepId: string } => !!r.stepId);
  if (!live.length) return { ok: true, checked: (rows ?? []).length, live: 0, updated: 0, failed: 0 };
  const stepIds = [...new Set(live.map((r) => r.stepId))];
  const { data: steps } = await sb.from("hq_task_steps").select("id,task_id,title,completed_at").in("id", stepIds);
  const taskIds = [...new Set(((steps ?? []) as { task_id: string }[]).map((s) => s.task_id))];
  const { data: tasks } = taskIds.length ? await sb.from("hq_tasks").select("id,title,deleted_at").in("id", taskIds) : { data: [] };
  const stepOf = new Map<string, { task_id: string; title: string; completed_at: string | null }>(((steps ?? []) as { id: string; task_id: string; title: string; completed_at: string | null }[]).map((s) => [s.id, s]));
  const taskOf = new Map<string, { title: string; deleted_at: string | null }>(((tasks ?? []) as { id: string; title: string; deleted_at: string | null }[]).map((t) => [t.id, t]));
  let updated = 0, failed = 0, n = 0;
  for (const r of live) {
    const s = stepOf.get(r.stepId);
    const t = s ? taskOf.get(s.task_id) : null;
    if (!s || !t) continue;                       // 工程が見つからない（消えた）→ 触らない
    const deleted = !!t.deleted_at;
    if (!s.completed_at && !deleted) continue;    // まだ対応中 → そのまま
    if (n >= (o.max ?? 200)) break;
    n++;
    if (o.dryRun) { updated++; continue; }
    const m = doneMessage({ title: t.title, stepTitle: s.title, completedAt: s.completed_at, deleted });
    const res = await notify({ action: "update", notification_id: r.id, text: m.text, blocks: m.blocks });
    if (res?.ok) updated++; else failed++;
  }
  return { ok: true, checked: (rows ?? []).length, live: live.length, updated, failed };
}
