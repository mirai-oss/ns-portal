// 本部タスクの Slack 操作（slack-interact から呼ぶ）。DB の処理は RPC hq_slack_*（service_role 専用・権限判定は DB 側）。
//   hqtask.create.open → フォーム／hqtask.create.modal → タスク作成＋担当者へ DM／hqtask.step.done → 完了／hqtask.step.ack → 対応中
import { createModal, parseCreate, errorField, assignedMessage, CREATE_OPEN, CREATE_OPEN_DETAIL, CREATE_MODAL, STEP_DONE, STEP_ACK, STEP_LINK } from "./hqtask-slack.ts";

// deno-lint-ignore no-explicit-any
type Ctx = { sb: any; payload: any; actor: { user_id: string; role: string; is_master: boolean; name: string }; notificationId: string | null; value: any };
type Deps = {
  text: (s: string) => Response; json: (o: unknown) => Response;
  ephemeral: (msg: string, responseUrl?: string) => Response; openModal: (triggerId: string, view: unknown) => Promise<Response>;
  waitUntil: (p: Promise<unknown>) => void; sendSlack: (b: Record<string, unknown>) => Promise<any>;
};
const canCreate = (a: Ctx["actor"]) => a.is_master || ["CEO", "HQ", "TENCHO"].includes(a.role);

export function hqtaskHandlers(d: Deps): Record<string, (c: Ctx) => Promise<Response>> {
  return {
    [CREATE_OPEN]: async ({ payload, actor }) => {
      if (!canCreate(actor)) return d.ephemeral("タスクを作れるのは、本部・社長・店長だけです。", payload.response_url);
      return await d.openModal(payload.trigger_id, createModal(false));
    },
    [CREATE_OPEN_DETAIL]: async ({ payload, actor }) => {
      if (!canCreate(actor)) return d.ephemeral("タスクを作れるのは、本部・社長・店長だけです。", payload.response_url);
      return await d.openModal(payload.trigger_id, createModal(true));
    },
    [CREATE_MODAL]: async ({ sb, payload, actor }) => {
      const p = parseCreate(payload.view?.state?.values);
      if (!p.ok) return d.json({ response_action: "errors", errors: p.errors });
      const v = p.v;
      // Slack の担当者 → 管理システムの人（紐づいていない人は選べない）
      const { data: links } = await sb.from("user_slack").select("user_id,slack_user_id").in("slack_user_id", v.slackAssignees);
      const ids: string[] = (links ?? []).map((l: any) => l.user_id);
      if (ids.length !== new Set(v.slackAssignees).size) return d.json({ response_action: "errors", errors: { assignees: "Slack と紐づいていない人が含まれています（本部に連絡してください）" } });
      const { data, error } = await sb.rpc("hq_slack_task_create", {
        p_slack_user_id: payload.user?.id, p_title: v.title, p_corp: v.corp, p_assignee_ids: ids, p_due: v.due, p_memo: v.memo, p_urgent: v.urgent, p_due_time: v.dueTime, p_notes: v.notes || null, p_steps: v.steps.length ? v.steps : null, p_photo: v.photo,
        p_dedupe: `modal:${payload.view?.id ?? crypto.randomUUID()}`, p_source: { via: "slack_modal", team: payload.team?.id ?? null },
      });
      if (error) return d.json({ response_action: "errors", errors: { title: "作成できませんでした: " + String(error.message).slice(0, 120) } });
      if (!data?.ok) return d.json({ response_action: "errors", errors: { [errorField(data?.reason)]: String(data?.message ?? "作成できませんでした") } });
      if (!data.duplicate) d.waitUntil((async () => {
        const url = `https://mirai-oss.github.io/ns-portal/tasks.html?task=${data.task_id}`;
        for (const uid of ids) {
          const m = assignedMessage({ title: v.title, due: v.due, dueTime: v.dueTime, steps: v.steps.length || 1, creatorName: String(data.creator_name ?? actor.name), memo: v.memo, step_id: String(data.step_id), url, canComplete: true });
          await d.sendSlack({ action: "send", channel_key: `user:${uid}`, text: m.text, blocks: m.blocks, event: "hqtask_assigned", source: "ef:slack-interact",
            dedupe_key: `hqtask_assigned:${data.task_id}:${uid}`, ref: { table: "hq_tasks", id: data.task_id } });
        }
        if (!ids.includes(actor.user_id)) {
          await d.sendSlack({ action: "send", channel_key: `user:${actor.user_id}`, text: `✅ 本部タスクを作りました：${v.title}（期限 ${v.due}・担当 ${ids.length} 名に DM しました）\n${url}`,
            event: "hqtask_created", source: "ef:slack-interact", dedupe_key: `hqtask_created:${data.task_id}`, ref: { table: "hq_tasks", id: data.task_id } });
        }
      })());
      return d.json({ response_action: "clear" });
    },
    [STEP_DONE]: async ({ sb, payload, value }) => {
      const { data, error } = await sb.rpc("hq_slack_step_complete", { p_slack_user_id: payload.user?.id, p_step: value?.step_id });
      if (error) return d.ephemeral("完了にできませんでした: " + String(error.message).slice(0, 120), payload.response_url);
      if (!data?.ok) return d.ephemeral(String(data?.message ?? "完了にできませんでした"), payload.response_url);
      if (payload.response_url) await fetch(payload.response_url, { method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ replace_original: true, text: data.already ? "✅ すでに完了しています" : "✅ 完了にしました" }) }).catch(() => {});
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
