// 本部タスクの Slack 操作（slack-interact から呼ぶ）。DB の処理は RPC hq_slack_*（service_role 専用・権限判定は DB 側）。
//   hqtask.create.open → フォーム／hqtask.create.modal → タスク作成＋担当者へ DM＋（ボタンを押したチャンネルに）親投稿とスレッドの詳細カード
//   hqtask.task.edit → 編集フォーム（いまの値が入る）／hqtask.edit.modal → 保存＋スレッドに変更の記録・親とカードの更新・新しい担当者へ DM
//   hqtask.step.done → 完了／hqtask.step.ack → 対応中
import { AI_CREATE, AI_EDIT, AI_CANCEL, AI_CORP, draftCard, toDraft, toForm, isComplete, ensureChannelKey, type Draft } from "./hqtask-ai.ts";
import { CORPS, COMMENT_OPEN, COMMENT_MODAL, commentModal, createModal, parseCreate, errorField, assignedMessage, assignedStepsMessage, markStepDone, parentMessage, taskCardMessage, completedBlocks, completionThreadText, stepsListModal, stepModal, parseStep, parseTaskEdit, parseCreateSteps, readForm, createFormModal, FORM_ADD, FORM_DEL, MAX_STEPS, STEPS_OPEN, STEP_PICK, STEP_ADD, STEP_MODAL, type StepRow, CREATE_OPEN, CREATE_OPEN_DETAIL, CREATE_MODAL, EDIT_ACTION, EDIT_MODAL, STEP_DONE, STEP_REOPEN, STEP_ACK, STEP_LINK } from "./hqtask-slack.ts";

// deno-lint-ignore no-explicit-any
type Ctx = { sb: any; payload: any; actor: { user_id: string; role: string; is_master: boolean; name: string }; notificationId: string | null; value: any };
type Deps = {
  text: (s: string) => Response; json: (o: unknown) => Response;
  ephemeral: (msg: string, responseUrl?: string) => Response; openModal: (triggerId: string, view: unknown) => Promise<Response>;
  waitUntil: (p: Promise<unknown>) => void; sendSlack: (b: Record<string, unknown>) => Promise<any>;
};
// ボタンを押した場所が DM（D で始まる）ではなくチャンネルか
// deno-lint-ignore no-explicit-any
const inChannel = (payload: any) => { const id = String(payload?.channel?.id ?? payload?.container?.channel_id ?? ""); return id !== "" && !id.startsWith("D"); };
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

// Slack の画面（モーダル）を操作する（開く・差し替える）。トークンはサーバーの秘密情報（slack-interact と同じ）
async function slackView(method: "views.open" | "views.update" | "views.push", body: Record<string, unknown>) {
  const token = Deno.env.get("SLACK_BOT_TOKEN");
  const res = await fetch(`https://slack.com/api/${method}`, { method: "POST", headers: { "Content-Type": "application/json; charset=utf-8", Authorization: `Bearer ${token}` }, body: JSON.stringify(body) });
  return await res.json().catch(() => ({ ok: false }));
}

// 親投稿とスレッドの詳細カードを、いまの内容に更新する（編集のあと）
// deno-lint-ignore no-explicit-any
async function refreshCard(sb: any, send: Deps["sendSlack"], taskId: string, editorName: string) {
  const { data: g } = await sb.rpc("hq_slack_task_get", { p_task: taskId });
  const { data: sg } = await sb.rpc("hq_slack_steps_get", { p_task: taskId });
  if (!g?.ok) return null;
  if (g.parent_notification_id) {
    const sl = ((sg?.steps ?? []) as StepRow[]);
    const allDone = sl.length > 0 && sl.every((x) => x.done);
    const pm = parentMessage({ title: g.title, due: g.due, dueTime: g.due_time, done: allDone, strip: { urgent: g.urgent, names: sl.filter((x) => !x.done).flatMap((x) => x.assignee_names), stepsDone: sl.filter((x) => x.done).length, stepsTotal: sl.length,
      overdue: !allDone && String(g.due ?? "") !== "" && String(g.due) < new Date(Date.now() + 9 * 3600_000).toISOString().slice(0, 10) } });
    await send({ action: "update", notification_id: g.parent_notification_id, text: pm.text, blocks: pm.blocks });
  }
  const steps = ((sg?.steps ?? []) as StepRow[]).map((s) => ({ title: s.title, done: s.done, names: s.assignee_names, due: s.due, dueTime: s.due_time, id: s.id, canComplete: !s.photo }));
  if (g.card_notification_id) {
    const { data: cr } = await sb.from("users").select("name").eq("id", g.creator_id).maybeSingle();
    const cm = taskCardMessage({ task_id: taskId, title: g.title, corp: g.corp, assigneeNames: [...new Set(((sg?.steps ?? []) as StepRow[]).filter((s) => !s.done).flatMap((s) => s.assignee_names))], due: g.due, dueTime: g.due_time, memo: g.memo, notes: g.notes,
      steps, creatorName: String(cr?.name ?? editorName).replace(/[\s\u3000]+/g, ""), urgent: g.urgent, url: urlOf(taskId) });
    await send({ action: "update", notification_id: g.card_notification_id, text: cm.text, blocks: cm.blocks });
  }
  return g;
}

// タスクを作ったあとの通知（担当者ごとの DM・チャンネルの親投稿とスレッドの詳細カード・@メンションの下書きの更新）
// deno-lint-ignore no-explicit-any
async function afterCreate(d: Deps, sb: any, actor: { user_id: string; name: string }, v: any, data: any, meta: any): Promise<void> {
    const url = urlOf(data.task_id);
    const made = (data.steps ?? []) as { step_id: string; title: string; assignee_ids: string[]; due: string; due_time: string | null }[];
    // 担当者ごとに DM（その人の最初の工程。複数あれば件数も）
    const per = new Map<string, typeof made>();
    for (const s of made) for (const uid of s.assignee_ids) per.set(uid, [...(per.get(uid) ?? []), s]);
    for (const [uid, mine] of per) {
      // その人の工程を 1 つずつ並べ、工程ごとに「✅ 完了」ボタンを付ける
      const m = assignedStepsMessage({ title: v.title, creatorName: String(data.creator_name ?? actor.name), memo: v.memo, notes: v.notes, url,
        steps: mine.map((s) => ({ step_id: s.step_id, title: s.title || "対応する", due: s.due, dueTime: s.due_time, canComplete: !v.photo })) });
      await d.sendSlack({ action: "send", channel_key: `user:${uid}`, text: m.text, blocks: m.blocks, event: "hqtask_assigned", source: "ef:slack-interact",
        dedupe_key: `hqtask_assigned:${data.task_id}:${uid}`, ref: { table: "hq_tasks", id: data.task_id } });
    }
    // ボタンを押したチャンネルに、親投稿（1 行）とスレッドの詳細カード（編集ボタンつき）
    const threadTs: string | undefined = meta.thread_ts;   // @アプリ のメンションから作ったときは、そのスレッドに詳細カードを出す（親投稿は作らない）
    const key = threadTs ? await ensureChannelKey(sb, meta.channel) : await channelKeyOf(sb, meta.channel);
    if (key) {
      let r1: any = null;
      if (threadTs) r1 = { ok: true, ts: threadTs, notification_id: null, slack_channel_id: meta.channel };
      else {
        const pm = parentMessage({ title: v.title, due: data.due, dueTime: data.due_time, strip: { urgent: v.urgent, names: [...new Set(made.flatMap((x) => x.assignee_ids))].length ? (await namesOf(sb, [...new Set(made.flatMap((x) => x.assignee_ids))])) : [], stepsDone: 0, stepsTotal: made.length } });
        r1 = await d.sendSlack({ action: "send", channel_key: key, text: pm.text, blocks: pm.blocks, event: "hqtask_parent", source: "ef:slack-interact", dedupe_key: `hqtask_parent:${data.task_id}`, ref: { table: "hq_tasks", id: data.task_id } });
      }
      if (r1?.ok && r1.ts) {
        const allIds = [...per.keys()];
        const nameMap = new Map<string, string>(); (await namesOf(sb, allIds)).forEach((n, i) => nameMap.set(allIds[i], n));
        const steps = made.map((s) => ({ title: s.title, done: false, names: s.assignee_ids.map((u) => nameMap.get(u) ?? "—"), due: s.due, dueTime: s.due_time, id: s.step_id, canComplete: !v.photo }));
        const cm = taskCardMessage({ task_id: data.task_id, title: v.title, corp: v.corp, assigneeNames: allIds.map((u) => nameMap.get(u) ?? "—"), due: data.due, dueTime: data.due_time, memo: v.memo, notes: v.notes, steps, creatorName: String(data.creator_name ?? actor.name), urgent: v.urgent, url });
        const r2 = await d.sendSlack({ action: "send", channel_key: key, thread_ts: r1.ts, text: cm.text, blocks: cm.blocks, event: "hqtask_card", source: "ef:slack-interact", dedupe_key: `hqtask_card:${data.task_id}`, ref: { table: "hq_tasks", id: data.task_id } });
        await sb.rpc("hq_slack_task_card_set", { p_task: data.task_id, p_channel: r1.slack_channel_id ?? meta.channel ?? "", p_ts: r1.ts, p_parent: r1.notification_id, p_card: r2?.notification_id ?? null });
      }
    } else if (!per.has(actor.user_id)) {
      await d.sendSlack({ action: "send", channel_key: `user:${actor.user_id}`, text: `✅ 本部タスクを作りました：${v.title}（工程 ${made.length} 個）\n🔗 <${url}|管理システムで開く>`,
        event: "hqtask_created", source: "ef:slack-interact", dedupe_key: `hqtask_created:${data.task_id}`, ref: { table: "hq_tasks", id: data.task_id } });
    }
}

// @メンションの下書きカードを「作成しました」に書き換え、下書きの状態を更新する
// deno-lint-ignore no-explicit-any
async function markDraftCreated(d: Deps, sb: any, draftId: string, taskId: string, title: string): Promise<void> {
  const { data: dr } = await sb.from("hq_slack_ai_draft").update({ status: "created", task_id: taskId }).eq("id", draftId).select("card_notification_id").maybeSingle();
  if (dr?.card_notification_id) await d.sendSlack({ action: "update", notification_id: dr.card_notification_id, text: `✅ 本部タスクを作成しました：${title}`, blocks: [{ type: "section", text: { type: "mrkdwn", text: `✅ *本部タスクを作成しました*：${title}` } }] });
}

export function hqtaskHandlers(d: Deps): Record<string, (c: Ctx) => Promise<Response>> {
  const openCreate = async ({ payload, actor }: Ctx) => {
    if (!canCreate(actor)) return d.ephemeral("タスクを作れるのは、本部・社長・店長だけです。", payload.response_url);
    const channel = payload.container?.channel_id ?? payload.channel?.id ?? null;
    return await d.openModal(payload.trigger_id, createModal({ mode: "create", meta: { channel } }));
  };
  return {
    // ===== @アプリ のメンションから作った下書き（AI が作った下書きを、本人が確認して作成） =====
    [AI_CREATE]: async ({ sb, payload, value, actor }) => {
      const { data: dr } = await sb.from("hq_slack_ai_draft").select("*").eq("id", value?.draft_id).maybeSingle();
      if (!dr || dr.status !== "open") return d.ephemeral("この下書きは、すでに使われたか、やめられています。", payload.response_url);
      if (dr.requester_id !== actor.user_id) return d.ephemeral("作成できるのは、@アプリ にメンションした本人だけです。", payload.response_url);
      const dd = dr.draft as Draft;
      if (!isComplete(dd)) return d.ephemeral("決まっていない項目があります。「フォームで直す」で入れてください。", payload.response_url);
      const allSlack = [...new Set(dd.steps.flatMap((s) => s.users))];
      const { data: links } = await sb.from("user_slack").select("user_id,slack_user_id").in("slack_user_id", allSlack);
      const idOf = new Map((links ?? []).map((l: any) => [l.slack_user_id, l.user_id]));
      if (allSlack.some((u) => !idOf.has(u))) return d.ephemeral("Slack と紐づいていない担当者がいます。「フォームで直す」で選び直してください。", payload.response_url);
      const stepsArg = dd.steps.map((s) => ({ title: s.title, assignee_ids: s.users.map((u) => idOf.get(u)), due: s.due, due_time: s.time }));
      const { data, error } = await sb.rpc("hq_slack_task_create_steps", { p_slack_user_id: payload.user?.id, p_title: dd.title, p_corp: dd.corp, p_memo: dd.memo, p_notes: dd.notes || null, p_urgent: dd.urgent, p_photo: false, p_steps: stepsArg, p_dedupe: `ai:${dr.id}`, p_source: { via: "slack_ai_draft" } });
      if (error || !data?.ok) return d.ephemeral("作成できませんでした：" + String(data?.message ?? error?.message ?? "").slice(0, 120), payload.response_url);
      const v = { title: dd.title, corp: dd.corp, memo: dd.memo, notes: dd.notes, urgent: dd.urgent, photo: false, steps: dd.steps.map((s) => ({ title: s.title, slackUsers: s.users, due: s.due, time: s.time })) };
      if (!data.duplicate) d.waitUntil(afterCreate(d, sb, actor, v, data, { channel: dr.channel_id, thread_ts: dr.thread_ts }));
      d.waitUntil(markDraftCreated(d, sb, dr.id, data.task_id, dd.title));
      return d.text("");
    },
    [AI_EDIT]: async ({ sb, payload, value, actor }) => {
      const { data: dr } = await sb.from("hq_slack_ai_draft").select("*").eq("id", value?.draft_id).maybeSingle();
      if (!dr || dr.status !== "open") return d.ephemeral("この下書きは、すでに使われたか、やめられています。", payload.response_url);
      if (dr.requester_id !== actor.user_id) return d.ephemeral("直せるのは、@アプリ にメンションした本人だけです。", payload.response_url);
      return await d.openModal(payload.trigger_id, createModal({ mode: "create", form: toForm(dr.draft as Draft), meta: { channel: dr.channel_id, thread_ts: dr.thread_ts, draft_id: dr.id } }));
    },
    // 下書きカードの［法人を選ぶ］: 選んだ法人を下書きに入れ、カードを書き換える（そろえば［この内容で作成する］が出る）
    [AI_CORP]: async ({ sb, payload, actor }) => {
      let sel: { draft_id?: string; corp?: string } = {};
      try { sel = JSON.parse(payload.actions?.[0]?.selected_option?.value ?? "{}"); } catch { /* 下の確認で止まる */ }
      const { data: dr } = await sb.from("hq_slack_ai_draft").select("*").eq("id", sel.draft_id).maybeSingle();
      if (!dr || dr.status !== "open") return d.ephemeral("この下書きは、すでに使われたか、やめられています。", payload.response_url);
      if (dr.requester_id !== actor.user_id) return d.ephemeral("選べるのは、@アプリ にメンションした本人だけです。", payload.response_url);
      if (!(CORPS as readonly string[]).includes(String(sel.corp))) return d.ephemeral("法人を選び直してください。", payload.response_url);
      const dd = { ...(dr.draft as Draft), corp: String(sel.corp) }; dd.missing = (dd.missing ?? []).filter((m: string) => m !== "法人");
      await sb.from("hq_slack_ai_draft").update({ draft: dd }).eq("id", dr.id);
      const slackIds = [...new Set(dd.steps.flatMap((s) => s.users))];
      const { data: links } = await sb.from("user_slack").select("user_id,slack_user_id").in("slack_user_id", slackIds.length ? slackIds : ["_"]);
      const { data: us } = await sb.from("users").select("id,name").in("id", (links ?? []).map((l: any) => l.user_id));
      const nm = new Map((us ?? []).map((u: any) => [u.id, String(u.name ?? "").replace(/[\s　]+/g, "")]));
      const names = new Map((links ?? []).map((l: any) => [l.slack_user_id, nm.get(l.user_id) ?? "—"]));
      const card = draftCard(dd, dr.id, names as Map<string, string>);
      if (dr.card_notification_id) await d.sendSlack({ action: "update", notification_id: dr.card_notification_id, text: card.text, blocks: card.blocks });
      return d.text("");
    },
    [AI_CANCEL]: async ({ sb, payload, value, actor }) => {
      const { data: dr } = await sb.from("hq_slack_ai_draft").select("*").eq("id", value?.draft_id).maybeSingle();
      if (!dr || dr.status !== "open") return d.ephemeral("この下書きは、すでに使われたか、やめられています。", payload.response_url);
      if (dr.requester_id !== actor.user_id) return d.ephemeral("やめられるのは、@アプリ にメンションした本人だけです。", payload.response_url);
      await sb.from("hq_slack_ai_draft").update({ status: "canceled" }).eq("id", dr.id);
      if (dr.card_notification_id) await d.sendSlack({ action: "update", notification_id: dr.card_notification_id, text: "下書きをやめました", blocks: [{ type: "section", text: { type: "mrkdwn", text: "下書きをやめました。" } }] });
      return d.text("");
    },
    [CREATE_OPEN]: openCreate,
    [CREATE_OPEN_DETAIL]: openCreate,   // 古いカードの「詳細つきで作る」も、同じフォーム（下に詳細の欄がある）を開く
    // 作成フォームの「＋ 工程を追加」「－ 最後の工程を消す」: 入力済みの内容を残したまま、工程の枠を 1 つ増減する
    [FORM_ADD]: async ({ payload }) => {
      const f = readForm(payload.view?.state?.values);
      if (f.steps.length < MAX_STEPS) { const last = f.steps[f.steps.length - 1]; f.steps.push({ due: last?.due ?? null, time: last?.time ?? null, users: last?.users ?? [] }); }
      await slackView("views.update", { view_id: payload.view?.id, hash: payload.view?.hash, view: createFormModal(f, metaOf(payload)) });
      return d.text("");
    },
    [FORM_DEL]: async ({ payload }) => {
      const f = readForm(payload.view?.state?.values);
      if (f.steps.length > 1) f.steps.pop();
      await slackView("views.update", { view_id: payload.view?.id, hash: payload.view?.hash, view: createFormModal(f, metaOf(payload)) });
      return d.text("");
    },
    [CREATE_MODAL]: async ({ sb, payload, actor }) => {
      const p = parseCreateSteps(payload.view?.state?.values);
      if (!p.ok) return d.json({ response_action: "errors", errors: p.errors });
      const v = p.v;
      const meta = metaOf(payload);
      // Slack の担当者 → 管理システムの人（紐づいていない人は選べない）
      const allSlack = [...new Set(v.steps.flatMap((s) => s.slackUsers))];
      const { data: links } = await sb.from("user_slack").select("user_id,slack_user_id").in("slack_user_id", allSlack);
      const idOf = new Map((links ?? []).map((l: any) => [l.slack_user_id, l.user_id]));
      const errs: Record<string, string> = {};
      v.steps.forEach((s, i) => { if (s.slackUsers.some((u) => !idOf.has(u))) errs[`s${i}_users`] = "Slack と紐づいていない人が含まれています（本部に連絡してください）"; });
      if (Object.keys(errs).length) return d.json({ response_action: "errors", errors: errs });
      const stepsArg = v.steps.map((s) => ({ title: s.title, assignee_ids: s.slackUsers.map((u) => idOf.get(u)), due: s.due, due_time: s.time }));
      const { data, error } = await sb.rpc("hq_slack_task_create_steps", {
        p_slack_user_id: payload.user?.id, p_title: v.title, p_corp: v.corp, p_memo: v.memo, p_notes: v.notes || null, p_urgent: v.urgent, p_photo: v.photo, p_steps: stepsArg,
        p_dedupe: `modal:${payload.view?.id ?? crypto.randomUUID()}`, p_source: { via: "slack_modal", team: payload.team?.id ?? null },
      });
      if (error) return d.json({ response_action: "errors", errors: { title: "作成できませんでした: " + String(error.message).slice(0, 120) } });
      if (!data?.ok) return d.json({ response_action: "errors", errors: { [errorField(data?.reason)]: String(data?.message ?? "作成できませんでした") } });
      if (!data.duplicate) d.waitUntil(afterCreate(d, sb, actor, v, data, meta));
      if (meta.draft_id) d.waitUntil(markDraftCreated(d, sb, meta.draft_id, data.task_id, v.title));
      return d.json({ response_action: "clear" });
    },
    // 編集: いまの値が入ったフォームを開く
    [EDIT_ACTION]: async ({ sb, payload, value }) => {
      const { data, error } = await sb.rpc("hq_slack_task_get", { p_task: value?.task_id });
      if (error || !data?.ok) return d.ephemeral(String(data?.message ?? "開けませんでした"), payload.response_url);
      if (data.status === "done") return d.ephemeral("完了したタスクは直せません。", payload.response_url);
      return await d.openModal(payload.trigger_id, createModal({ mode: "edit", meta: { task_id: value.task_id }, initial: {
        title: data.title, corp: data.corp, memo: data.memo, notes: data.notes, urgent: data.urgent } }));
    },
    [EDIT_MODAL]: async ({ sb, payload, actor }) => {
      const p = parseTaskEdit(payload.view?.state?.values);
      if (!p.ok) return d.json({ response_action: "errors", errors: p.errors });
      const v = p.v;
      const taskId = metaOf(payload).task_id;
      const { data, error } = await sb.rpc("hq_slack_task_update", {
        p_slack_user_id: payload.user?.id, p_task: taskId, p_title: v.title, p_corp: v.corp, p_assignee_ids: null, p_due: null, p_due_time: null, p_memo: v.memo, p_notes: v.notes || null, p_urgent: v.urgent, p_add_steps: null,
      });
      if (error) return d.json({ response_action: "errors", errors: { title: "保存できませんでした: " + String(error.message).slice(0, 120) } });
      if (!data?.ok) return d.json({ response_action: "errors", errors: { [errorField(data?.reason)]: String(data?.message ?? "保存できませんでした") } });
      if ((data.changes ?? []).length) d.waitUntil((async () => {
        const g = await refreshCard(sb, d.sendSlack, taskId, String(data.editor_name ?? actor.name));
        const key = await channelKeyOf(sb, g?.card_channel);
        if (key && g?.parent_ts) await d.sendSlack({ action: "send", channel_key: key, thread_ts: g.parent_ts, text: `✏️ ${data.editor_name ?? actor.name} さんが変更しました：${(data.changes as string[]).join("・")}`, event: "hqtask_edited", source: "ef:slack-interact",
          dedupe_key: `hqtask_edited:${taskId}:${payload.view?.id ?? crypto.randomUUID()}`, ref: { table: "hq_tasks", id: taskId } });
      })());
      return d.json({ response_action: "clear" });
    },
    // 工程の一覧（モーダル）
    [STEPS_OPEN]: async ({ sb, payload, value }) => {
      const { data } = await sb.rpc("hq_slack_steps_get", { p_task: value?.task_id });
      if (!data?.ok) return d.ephemeral(String(data?.message ?? "開けませんでした"), payload.response_url);
      if (data.status === "done") return d.ephemeral("完了したタスクは直せません。", payload.response_url);
      return await d.openModal(payload.trigger_id, stepsListModal({ taskId: value.task_id, title: data.title, steps: data.steps }));
    },
    // 一覧の「編集」→ その工程のフォームに差し替える
    [STEP_PICK]: async ({ sb, payload, value }) => {
      const { data } = await sb.rpc("hq_slack_steps_get", { p_task: value?.task_id });
      const step = (data?.steps ?? []).find((s: StepRow) => s.id === value?.step_id);
      if (!data?.ok || !step) return d.text("");
      await slackView("views.update", { view_id: payload.view?.id, view: stepModal({ taskId: value.task_id, step }) });
      return d.text("");
    },
    [STEP_ADD]: async ({ sb, payload, value }) => {
      const { data } = await sb.rpc("hq_slack_steps_get", { p_task: value?.task_id });
      const last = ((data?.steps ?? []) as StepRow[]).filter((s) => s.due).slice(-1)[0];
      await slackView("views.update", { view_id: payload.view?.id, view: stepModal({ taskId: value.task_id, step: null, defaultDue: last?.due ?? null }) });
      return d.text("");
    },
    // 工程の保存（追加・変更・削除）→ 一覧に戻す／カード・スレッド・DM を更新
    [STEP_MODAL]: async ({ sb, payload, actor }) => {
      const p = parseStep(payload.view?.state?.values);
      if (!p.ok) return d.json({ response_action: "errors", errors: p.errors });
      const v = p.v;
      const meta = metaOf(payload);
      let ids: string[] = [];
      if (!v.del) {
        const { data: links } = await sb.from("user_slack").select("user_id,slack_user_id").in("slack_user_id", v.slackAssignees);
        ids = (links ?? []).map((l: any) => l.user_id);
        if (ids.length !== new Set(v.slackAssignees).size) return d.json({ response_action: "errors", errors: { assignees: "Slack と紐づいていない人が含まれています（本部に連絡してください）" } });
      }
      const { data, error } = await sb.rpc("hq_slack_step_update", { p_slack_user_id: payload.user?.id, p_task: meta.task_id, p_step: meta.step_id ?? null, p_title: v.title, p_assignee_ids: v.del ? null : ids,
        p_due: v.del ? null : v.due, p_due_time: v.del ? null : v.dueTime, p_photo: v.photo, p_note: v.note || null, p_delete: v.del });
      if (error) return d.json({ response_action: "errors", errors: { title: "保存できませんでした: " + String(error.message).slice(0, 120) } });
      if (!data?.ok) return d.json({ response_action: "errors", errors: { [errorField(data?.reason)]: String(data?.message ?? "保存できませんでした") } });
      d.waitUntil((async () => {
        const g = await refreshCard(sb, d.sendSlack, meta.task_id, String(data.editor_name ?? actor.name));
        const key = await channelKeyOf(sb, g?.card_channel);
        const what = (data.changes as string[]).join("・");
        if (key && g?.parent_ts && what) await d.sendSlack({ action: "send", channel_key: key, thread_ts: g.parent_ts, text: `✏️ ${data.editor_name ?? actor.name} さんが工程「${data.step_title}」を変更しました：${what}`, event: "hqtask_edited", source: "ef:slack-interact",
          dedupe_key: `hqtask_step_edited:${meta.task_id}:${payload.view?.id ?? crypto.randomUUID()}`, ref: { table: "hq_tasks", id: meta.task_id } });
        for (const uid of (data.new_assignees ?? []) as string[]) {
          const m = assignedMessage({ title: `${data.title}（工程：${data.step_title}）`, due: v.due, dueTime: v.dueTime, creatorName: String(data.editor_name ?? actor.name), memo: v.note, step_id: String(data.step_id), url: urlOf(meta.task_id), canComplete: !v.photo });
          await d.sendSlack({ action: "send", channel_key: `user:${uid}`, text: m.text, blocks: m.blocks, event: "hqtask_assigned", source: "ef:slack-interact", dedupe_key: `hqtask_assigned_step:${data.step_id}:${uid}`, ref: { table: "hq_tasks", id: meta.task_id } });
        }
      })());
      // 保存できたら、工程の一覧（最新）に戻す
      const { data: sg } = await sb.rpc("hq_slack_steps_get", { p_task: meta.task_id });
      if (sg?.ok) return d.json({ response_action: "update", view: stepsListModal({ taskId: meta.task_id, title: sg.title, steps: sg.steps }) });
      return d.json({ response_action: "clear" });
    },
    [STEP_DONE]: async ({ sb, payload, value, actor }) => {
      const { data, error } = await sb.rpc("hq_slack_step_complete", { p_slack_user_id: payload.user?.id, p_step: value?.step_id });
      if (error) return d.ephemeral("完了にできませんでした: " + String(error.message).slice(0, 120), payload.response_url);
      if (!data?.ok) return d.ephemeral(String(data?.message ?? "完了にできませんでした"), payload.response_url);
      const at = new Date().toLocaleString("ja-JP", { timeZone: "Asia/Tokyo", month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit", hour12: false });
      const { data: st } = await sb.from("hq_task_steps").select("title").eq("id", value?.step_id).maybeSingle();
      // 2026-11-18 チャンネルのカードから押されたとき（DM ではない）: カードは DB の最新から作り直し、完了の記録はチャンネルのスレッドへ
      if (inChannel(payload)) {
        if (data.already) return d.ephemeral("この工程はすでに完了しています。", payload.response_url);
        if (data.task_id) d.waitUntil((async () => {
          const { data: tk } = await sb.from("hq_tasks").select("title,due_date,due_time,created_by").eq("id", data.task_id).maybeSingle();
          const key = await channelKeyOf(sb, payload.channel?.id);
          const threadTs = payload.message?.thread_ts ?? payload.message?.ts;
          if (tk && key && threadTs) {
            const cn = tk.created_by ? (await namesOf(sb, [tk.created_by]))[0] : null;
            await d.sendSlack({ action: "send", channel_key: key, thread_ts: threadTs, text: completionThreadText({ stepTitle: st?.title ?? null, title: tk.title, due: tk.due_date, dueTime: tk.due_time, creatorName: cn, by: actor.name, at, url: urlOf(data.task_id) }),
              event: "hqtask_step_done_thread", source: "ef:slack-interact", dedupe_key: `hqtask_done_thread:${value?.step_id}:${threadTs}`, ref: { table: "hq_tasks", id: data.task_id } });
          }
          await refreshCard(sb, d.sendSlack, data.task_id, actor.name);
        })());
        return d.ephemeral(`✅ 「${st?.title ?? "工程"}」を完了にしました。`, payload.response_url);
      }
      // 工程ごとのボタンがあるメッセージ: 押された工程だけを「✅ 完了」にして、ほかの工程のボタンは残す。1 つだけのメッセージ: 内容は残して完了の印を付けボタンを外す
      if (payload.response_url && !data.already) {
        const per = markStepDone(payload.message?.blocks, String(value?.step_id), actor.name, at);
        const blocks = per ? per.blocks : completedBlocks(payload.message?.blocks, actor.name, at, st?.title ?? null);
        await fetch(payload.response_url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ replace_original: true, text: `✅ ${st?.title ?? "工程"}を完了しました`, blocks }) }).catch(() => {});
      }
      // スレッドにも、どの工程か・何のタスクだったかを残す／チャンネルのカードの工程の印も更新する
      if (!data.already && data.task_id) d.waitUntil((async () => {
        const { data: tk } = await sb.from("hq_tasks").select("title,due_date,due_time,created_by").eq("id", data.task_id).maybeSingle();
        if (tk && payload.message?.ts) {
          const cn = tk.created_by ? (await namesOf(sb, [tk.created_by]))[0] : null;
          await d.sendSlack({ action: "send", channel_key: `user:${actor.user_id}`, thread_ts: payload.message.ts, text: completionThreadText({ stepTitle: st?.title ?? null, title: tk.title, due: tk.due_date, dueTime: tk.due_time, creatorName: cn, by: actor.name, at, url: urlOf(data.task_id) }),
            event: "hqtask_step_done_thread", source: "ef:slack-interact", dedupe_key: `hqtask_done_thread:${value?.step_id}:${payload.message.ts}`, ref: { table: "hq_tasks", id: data.task_id } });
        }
        await refreshCard(sb, d.sendSlack, data.task_id, actor.name);
      })());
      return d.text("");
    },
    // 2026-11-19 チャンネルのカードの［↩️ 取り消し］: 完了にした工程を未完了に戻す（権限は DB 側 hq_slack_step_reopen が判定）。記録はスレッドへ・カードは作り直し
    [STEP_REOPEN]: async ({ sb, payload, value, actor }) => {
      const { data, error } = await sb.rpc("hq_slack_step_reopen", { p_slack_user_id: payload.user?.id, p_step: value?.step_id });
      if (error) return d.ephemeral("取り消せませんでした: " + String(error.message).slice(0, 120), payload.response_url);
      if (!data?.ok) return d.ephemeral(String(data?.message ?? "取り消せませんでした"), payload.response_url);
      if (data.already) return d.ephemeral(String(data.message ?? "まだ完了していません"), payload.response_url);
      d.waitUntil((async () => {
        const key = await channelKeyOf(sb, payload.channel?.id);
        const threadTs = payload.message?.thread_ts ?? payload.message?.ts;
        if (key && threadTs) await d.sendSlack({ action: "send", channel_key: key, thread_ts: threadTs, text: `↩️ ${actor.name} が「${String(data.step_title ?? "工程").slice(0, 40)}」の完了を取り消しました（未完了に戻りました）`,
          event: "hqtask_step_reopen_thread", source: "ef:slack-interact", dedupe_key: `hqtask_reopen_thread:${value?.step_id}:${threadTs}:${Date.now()}`, ref: { table: "hq_tasks", id: data.task_id } });
        await refreshCard(sb, d.sendSlack, data.task_id, actor.name);
      })());
      return d.ephemeral(`↩️ 「${data.step_title ?? "工程"}」の完了を取り消しました。`, payload.response_url);
    },
    // 2026-11-18 チャンネルのカードの［💬 コメント］: 入力窓を開く → 送信でタスクのコメントに入れる（本人の権限で。見えないタスクには入れられない）
    [COMMENT_OPEN]: async ({ sb, payload, value }) => {
      const { data, error } = await sb.rpc("hq_slack_task_get", { p_task: value?.task_id });
      if (error || !data?.ok) return d.ephemeral(String(data?.message ?? "開けませんでした"), payload.response_url);
      return await d.openModal(payload.trigger_id, commentModal({ taskId: value.task_id, title: data.title }));
    },
    [COMMENT_MODAL]: async ({ sb, payload, actor }) => {
      const taskId = metaOf(payload).task_id;
      const body = String(payload.view?.state?.values?.body?.body?.value ?? "").trim();
      if (!body) return d.json({ response_action: "errors", errors: { body: "コメントを入力してください" } });
      const { data, error } = await sb.rpc("hq_slack_comment_add", { p_slack_user_id: payload.user?.id, p_task: taskId, p_body: body });
      if (error) return d.json({ response_action: "errors", errors: { body: "送信できませんでした: " + String(error.message).slice(0, 120) } });
      if (!data?.ok) return d.json({ response_action: "errors", errors: { body: String(data?.message ?? "送信できませんでした") } });
      d.waitUntil((async () => {
        const { data: g } = await sb.rpc("hq_slack_task_get", { p_task: taskId });
        const key = await channelKeyOf(sb, g?.card_channel);
        if (key && g?.parent_ts) await d.sendSlack({ action: "send", channel_key: key, thread_ts: g.parent_ts, text: `💬 ${actor.name}：${body.slice(0, 300)}${body.length > 300 ? "…" : ""}`, event: "hqtask_comment_thread", source: "ef:slack-interact",
          dedupe_key: `hqtask_comment_thread:${data.comment_id}`, ref: { table: "hq_tasks", id: taskId } });
      })());
      return d.json({ response_action: "clear" });
    },
    [STEP_ACK]: async ({ sb, payload, value }) => {
      const { data, error } = await sb.rpc("hq_slack_step_ack", { p_slack_user_id: payload.user?.id, p_step: value?.step_id });
      if (error || !data?.ok) return d.ephemeral(String(data?.message ?? "記録できませんでした"), payload.response_url);
      return d.ephemeral("🕐 対応中にしました。今日の午後の追い通知は止めます（明日、期限を過ぎていればまた通知します）。", payload.response_url);
    },
    [STEP_LINK]: async () => d.text(""),
  };
}
