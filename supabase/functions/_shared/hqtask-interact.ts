// 本部タスクの Slack 操作（slack-interact から呼ぶ）。DB の処理は RPC hq_slack_*（service_role 専用・権限判定は DB 側）。
//   hqtask.create.open → フォーム／hqtask.create.modal → タスク作成＋担当者へ DM＋（ボタンを押したチャンネルに）親投稿とスレッドの詳細カード
//   hqtask.task.edit → 編集フォーム（いまの値が入る）／hqtask.edit.modal → 保存＋スレッドに変更の記録・親とカードの更新・新しい担当者へ DM
//   hqtask.step.done → 完了／hqtask.step.ack → 対応中
import { createModal, parseCreate, errorField, assignedMessage, parentMessage, taskCardMessage, completedBlocks, completionThreadText, CREATE_OPEN, CREATE_OPEN_DETAIL, CREATE_MODAL, EDIT_ACTION, EDIT_MODAL, STEP_DONE, STEP_ACK, STEP_LINK } from "./hqtask-slack.ts";

// deno-lint-ignore no-explicit-any
type Ctx = { sb: any; payload: any; actor: { user_id: string; role: string; is_master: boolean; name: string }; notificationId: string | null; value: any };
type Deps = {
  text: (s: string) => Response; json: (o: unknown) => Response;
  ephemeral: (msg: string, responseUrl?: string) => Response; openModal: (triggerId: string, view: unknown) => Promise<Response>;
  waitUntil: (p: Promise<unknown>) => void; sendSlack: (b: Record<string, unknown>) => Promise<any>;
};
const canCreate = (a: Ctx["actor"]) => a.is_master || ["CEO", "HQ", "TENCHO"].includes(a.role);
const urlOf = (taskId: string) => `https://mirai-oss.github.io/ns-portal/tasks.html?task=${taskId}`;
// deno-lint-ignore no-explicit-any
const metaOf = (payload: any) => { try { return JSON.parse(payload.view?.private_metadata ?? "{}"); } catch { return {}; } };

// deno-lint-ignore no-explicit-any
async function namesOf(sb: any, ids: string[]): Promise<string[]> {
  if (!ids.length) return [];
  const { data } = await sb.from("users").select("id,name").in("id", ids);
  const m = new Map((data ?? []).map((u: any) => [u.id, String(u.name ?? "").replace(/[\s　]+/g, "")]));
  return ids.map((i) => String(m.get(i) ?? "—"));
}
// Slack のチャンネル ID → 通知の宛先名（登録のあるチャンネルだけ。無ければ親投稿は出さない）
// deno-lint-ignore no-explicit-any
async function channelKeyOf(sb: any, channelId: string | null | undefined): Promise<string | null> {
  if (!channelId) return null;
  const { data } = await sb.from("slack_channels").select("channel_key").eq("slack_channel_id", channelId).eq("is_active", true).limit(1).maybeSingle();
  return data?.channel_key ?? null;
}

export function hqtaskHandlers(d: Deps): Record<string, (c: Ctx) => Promise<Response>> {
  const openCreate = async ({ payload, actor }: Ctx) => {
    if (!canCreate(actor)) return d.ephemeral("タスクを作れるのは、本部・社長・店長だけです。", payload.response_url);
    const channel = payload.container?.channel_id ?? payload.channel?.id ?? null;
    return await d.openModal(payload.trigger_id, createModal({ mode: "create", meta: { channel } }));
  };
  return {
    [CREATE_OPEN]: openCreate,
    [CREATE_OPEN_DETAIL]: openCreate,   // 古いカードの「詳細つきで作る」も、同じフォーム（下に詳細の欄がある）を開く
    [CREATE_MODAL]: async ({ sb, payload, actor }) => {
      const p = parseCreate(payload.view?.state?.values);
      if (!p.ok) return d.json({ response_action: "errors", errors: p.errors });
      const v = p.v;
      const meta = metaOf(payload);
      // Slack の担当者 → 管理システムの人（紐づいていない人は選べない）
      const { data: links } = await sb.from("user_slack").select("user_id,slack_user_id").in("slack_user_id", v.slackAssignees);
      const ids: string[] = (links ?? []).map((l: any) => l.user_id);
      if (ids.length !== new Set(v.slackAssignees).size) return d.json({ response_action: "errors", errors: { assignees: "Slack と紐づいていない人が含まれています（本部に連絡してください）" } });
      const { data, error } = await sb.rpc("hq_slack_task_create", {
        p_slack_user_id: payload.user?.id, p_title: v.title, p_corp: v.corp, p_assignee_ids: ids, p_due: v.due, p_memo: v.memo, p_urgent: v.urgent, p_due_time: v.dueTime,
        p_notes: v.notes || null, p_steps: v.steps.length ? v.steps : null, p_photo: v.photo,
        p_dedupe: `modal:${payload.view?.id ?? crypto.randomUUID()}`, p_source: { via: "slack_modal", team: payload.team?.id ?? null },
      });
      if (error) return d.json({ response_action: "errors", errors: { title: "作成できませんでした: " + String(error.message).slice(0, 120) } });
      if (!data?.ok) return d.json({ response_action: "errors", errors: { [errorField(data?.reason)]: String(data?.message ?? "作成できませんでした") } });
      if (!data.duplicate) d.waitUntil((async () => {
        const url = urlOf(data.task_id);
        const stepsN = v.steps.length || 1;
        for (const uid of ids) {
          const m = assignedMessage({ title: v.title, due: v.due, dueTime: v.dueTime, steps: stepsN, creatorName: String(data.creator_name ?? actor.name), memo: v.memo, step_id: String(data.step_id), url, canComplete: !v.photo });
          await d.sendSlack({ action: "send", channel_key: `user:${uid}`, text: m.text, blocks: m.blocks, event: "hqtask_assigned", source: "ef:slack-interact",
            dedupe_key: `hqtask_assigned:${data.task_id}:${uid}`, ref: { table: "hq_tasks", id: data.task_id } });
        }
        // ボタンを押したチャンネルに、親投稿（1 行）とスレッドの詳細カード（編集ボタンつき）
        const key = await channelKeyOf(sb, meta.channel);
        if (key) {
          const pm = parentMessage({ title: v.title, due: v.due, dueTime: v.dueTime });
          const r1 = await d.sendSlack({ action: "send", channel_key: key, text: pm.text, blocks: pm.blocks, event: "hqtask_parent", source: "ef:slack-interact", dedupe_key: `hqtask_parent:${data.task_id}`, ref: { table: "hq_tasks", id: data.task_id } });
          if (r1?.ok && r1.ts) {
            const names = await namesOf(sb, ids);
            const steps = v.steps.length ? v.steps.map((s) => ({ title: s, done: false })) : [{ title: "対応する", done: false }];
            const cm = taskCardMessage({ task_id: data.task_id, title: v.title, corp: v.corp, assigneeNames: names, due: v.due, dueTime: v.dueTime, memo: v.memo, notes: v.notes, steps, creatorName: String(data.creator_name ?? actor.name), urgent: v.urgent, url });
            const r2 = await d.sendSlack({ action: "send", channel_key: key, thread_ts: r1.ts, text: cm.text, blocks: cm.blocks, event: "hqtask_card", source: "ef:slack-interact", dedupe_key: `hqtask_card:${data.task_id}`, ref: { table: "hq_tasks", id: data.task_id } });
            await sb.rpc("hq_slack_task_card_set", { p_task: data.task_id, p_channel: r1.slack_channel_id ?? meta.channel ?? "", p_ts: r1.ts, p_parent: r1.notification_id, p_card: r2?.notification_id ?? null });
          }
        } else if (!ids.includes(actor.user_id)) {
          await d.sendSlack({ action: "send", channel_key: `user:${actor.user_id}`, text: `✅ 本部タスクを作りました：${v.title}（期限 ${v.due}・担当 ${ids.length} 名に DM しました）\n${url}`,
            event: "hqtask_created", source: "ef:slack-interact", dedupe_key: `hqtask_created:${data.task_id}`, ref: { table: "hq_tasks", id: data.task_id } });
        }
      })());
      return d.json({ response_action: "clear" });
    },
    // 編集: いまの値が入ったフォームを開く
    [EDIT_ACTION]: async ({ sb, payload, value }) => {
      const { data, error } = await sb.rpc("hq_slack_task_get", { p_task: value?.task_id });
      if (error || !data?.ok) return d.ephemeral(String(data?.message ?? "開けませんでした"), payload.response_url);
      if (data.status === "done") return d.ephemeral("完了したタスクは直せません。", payload.response_url);
      return await d.openModal(payload.trigger_id, createModal({ mode: "edit", meta: { task_id: value.task_id }, initial: {
        title: data.title, corp: data.corp, assigneeSlackIds: data.assignee_slack_ids, due: data.due, dueTime: data.due_time, memo: data.memo, notes: data.notes, urgent: data.urgent } }));
    },
    [EDIT_MODAL]: async ({ sb, payload, actor }) => {
      const p = parseCreate(payload.view?.state?.values);
      if (!p.ok) return d.json({ response_action: "errors", errors: p.errors });
      const v = p.v;
      const taskId = metaOf(payload).task_id;
      const { data: links } = await sb.from("user_slack").select("user_id,slack_user_id").in("slack_user_id", v.slackAssignees);
      const ids: string[] = (links ?? []).map((l: any) => l.user_id);
      if (ids.length !== new Set(v.slackAssignees).size) return d.json({ response_action: "errors", errors: { assignees: "Slack と紐づいていない人が含まれています（本部に連絡してください）" } });
      const { data, error } = await sb.rpc("hq_slack_task_update", {
        p_slack_user_id: payload.user?.id, p_task: taskId, p_title: v.title, p_corp: v.corp, p_assignee_ids: ids, p_due: v.due, p_due_time: v.dueTime, p_memo: v.memo, p_notes: v.notes || null,
        p_urgent: v.urgent, p_add_steps: v.steps.length ? v.steps : null,
      });
      if (error) return d.json({ response_action: "errors", errors: { title: "保存できませんでした: " + String(error.message).slice(0, 120) } });
      if (!data?.ok) return d.json({ response_action: "errors", errors: { [errorField(data?.reason)]: String(data?.message ?? "保存できませんでした") } });
      if ((data.changes ?? []).length) d.waitUntil((async () => {
        const url = urlOf(taskId);
        const { data: g } = await sb.rpc("hq_slack_task_get", { p_task: taskId });
        // 新しく担当になった人へ DM
        for (const uid of (data.new_assignees ?? []) as string[]) {
          const m = assignedMessage({ title: v.title, due: v.due, dueTime: v.dueTime, creatorName: String(data.editor_name ?? actor.name), memo: v.memo, step_id: String(data.step_id), url, canComplete: true });
          await d.sendSlack({ action: "send", channel_key: `user:${uid}`, text: m.text, blocks: m.blocks, event: "hqtask_assigned", source: "ef:slack-interact", dedupe_key: `hqtask_assigned:${taskId}:${uid}`, ref: { table: "hq_tasks", id: taskId } });
        }
        if (g?.ok && g.parent_notification_id) {
          // 親と詳細カードを新しい内容に更新し、スレッドに変更の記録を 1 行
          const names = await namesOf(sb, ids);
          const pm = parentMessage({ title: g.title, due: g.due, dueTime: g.due_time });
          await d.sendSlack({ action: "update", notification_id: g.parent_notification_id, text: pm.text, blocks: pm.blocks });
          if (g.card_notification_id) {
            const cm = taskCardMessage({ task_id: taskId, title: g.title, corp: g.corp, assigneeNames: names, due: g.due, dueTime: g.due_time, memo: g.memo, notes: g.notes, steps: g.steps ?? [], creatorName: String(data.editor_name ?? actor.name), urgent: g.urgent, url });
            await d.sendSlack({ action: "update", notification_id: g.card_notification_id, text: cm.text, blocks: cm.blocks });
          }
          const key = await channelKeyOf(sb, g.card_channel);
          if (key && g.parent_ts) await d.sendSlack({ action: "send", channel_key: key, thread_ts: g.parent_ts, text: `✏️ ${data.editor_name ?? actor.name} さんが変更しました：${(data.changes as string[]).join("・")}`, event: "hqtask_edited", source: "ef:slack-interact",
            dedupe_key: `hqtask_edited:${taskId}:${payload.view?.id ?? crypto.randomUUID()}`, ref: { table: "hq_tasks", id: taskId } });
        }
      })());
      return d.json({ response_action: "clear" });
    },
    [STEP_DONE]: async ({ sb, payload, value, actor }) => {
      const { data, error } = await sb.rpc("hq_slack_step_complete", { p_slack_user_id: payload.user?.id, p_step: value?.step_id });
      if (error) return d.ephemeral("完了にできませんでした: " + String(error.message).slice(0, 120), payload.response_url);
      if (!data?.ok) return d.ephemeral(String(data?.message ?? "完了にできませんでした"), payload.response_url);
      const at = new Date().toLocaleString("ja-JP", { timeZone: "Asia/Tokyo", month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit", hour12: false });
      // 元のメッセージの内容（依頼者・期限・タスク名・リンク）は残したまま、完了の印だけ付けてボタンを外す
      if (payload.response_url && !data.already) await fetch(payload.response_url, { method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ replace_original: true, text: "✅ 完了しました", blocks: completedBlocks(payload.message?.blocks, actor.name, at) }) }).catch(() => {});
      // スレッドにも、何のタスクだったかを残す
      if (!data.already && data.task_id && payload.message?.ts) d.waitUntil((async () => {
        const { data: tk } = await sb.from("hq_tasks").select("title,due_date,due_time,created_by").eq("id", data.task_id).maybeSingle();
        if (!tk) return;
        const cn = tk.created_by ? (await namesOf(sb, [tk.created_by]))[0] : null;
        await d.sendSlack({ action: "send", channel_key: `user:${actor.user_id}`, thread_ts: payload.message.ts, text: completionThreadText({ title: tk.title, due: tk.due_date, dueTime: tk.due_time, creatorName: cn, by: actor.name, at, url: urlOf(data.task_id) }),
          event: "hqtask_step_done_thread", source: "ef:slack-interact", dedupe_key: `hqtask_done_thread:${value?.step_id}:${payload.message.ts}`, ref: { table: "hq_tasks", id: data.task_id } });
      })());
      return d.text("");
    },
    [STEP_ACK]: async ({ sb, payload, value }) => {
      const { data, error } = await sb.rpc("hq_slack_step_ack", { p_slack_user_id: payload.user?.id, p_step: value?.step_id });
      if (error || !data?.ok) return d.ephemeral(String(data?.message ?? "記録できませんでした"), payload.response_url);
      return d.ephemeral("🕐 対応中にしました。今日の午後の追い通知は止めます（明日、期限を過ぎていればまた通知します）。", payload.response_url);
    },
    [STEP_LINK]: async () => d.text(""),
  };
}
