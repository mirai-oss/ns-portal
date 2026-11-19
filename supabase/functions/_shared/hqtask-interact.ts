// 本部タスクの Slack 操作（slack-interact から呼ぶ）。DB の処理は RPC hq_slack_*（service_role 専用・権限判定は DB 側）。
//   hqtask.create.open → フォーム／hqtask.create.modal → タスク作成＋担当者へ DM＋（ボタンを押したチャンネルに）親投稿とスレッドの詳細カード
//   hqtask.task.edit → 編集フォーム（いまの値が入る）／hqtask.edit.modal → 保存＋スレッドに変更の記録・親とカードの更新・新しい担当者へ DM
//   hqtask.step.done → 完了／hqtask.step.ack → 対応中
import { AI_CREATE, AI_EDIT, AI_CANCEL, AI_CORP, draftCard, toDraft, toForm, isComplete, ensureChannelKey, type Draft } from "./hqtask-ai.ts";
import { permalinkOf } from "./hqtask-parent-link.ts";
import { CORPS, COMMENT_OPEN, COMMENT_MODAL, COMMENT_DELETE, commentModal, createModal, parseCreate, errorField, assignedMessage, assignedStepsMessage, markStepDone, parentMessage, taskCardMessage, completedBlocks, completionThreadText, stepsListModal, stepModal, parseStep, parseTaskEdit, parseCreateSteps, readForm, createFormModal, FORM_ADD, FORM_DEL, MAX_STEPS, STEPS_OPEN, STEP_PICK, STEP_ADD, STEP_MODAL, type StepRow, CREATE_OPEN, CREATE_OPEN_DETAIL, CREATE_MODAL, EDIT_ACTION, EDIT_MODAL, STEP_DONE, STEP_REOPEN, STEP_ACK, STEP_LINK } from "./hqtask-slack.ts";

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
async function afterCreate(d: Deps, sb: any, actor: { user_id: string; name: string }, v: any, data: any, meta: any): Promise<{ channel: string; ts: string } | null> {
    let parentRef: { channel: string; ts: string } | null = null;
    const url = urlOf(data.task_id);
    const made = (data.steps ?? []) as { step_id: string; title: string; assignee_ids: string[]; due: string; due_time: string | null }[];
    // 担当者ごとに DM（その人の最初の工程。複数あれば件数も）
    const per = new Map<string, typeof made>();
    for (const s of made) for (const uid of s.assignee_ids) per.set(uid, [...(per.get(uid) ?? []), s]);
    //   2026-11-19 DM には［💬 コメント］と「チャンネルの親投稿へのリンク」を付けるため、親投稿を出したあとに送る（下の sendAssignedDms）
    const sendAssignedDms = async (parent: { url: string; channel: string } | null) => {
      for (const [uid, mine] of per) {
        // その人の工程を 1 つずつ並べ、工程ごとに「✅ 完了」ボタンを付ける
        const m = assignedStepsMessage({ title: v.title, creatorName: String(data.creator_name ?? actor.name), memo: v.memo, notes: v.notes, url, taskId: data.task_id, parent,
          steps: mine.map((s) => ({ step_id: s.step_id, title: s.title || "対応する", due: s.due, dueTime: s.due_time, canComplete: !v.photo })) });
        await d.sendSlack({ action: "send", channel_key: `user:${uid}`, text: m.text, blocks: m.blocks, event: "hqtask_assigned", source: "ef:slack-interact",
          dedupe_key: `hqtask_assigned:${data.task_id}:${uid}`, ref: { table: "hq_tasks", id: data.task_id } });
      }
    };
    // ボタンを押したチャンネルに、親投稿（1 行）とスレッドの詳細カード（編集ボタンつき）
    // 2026-11-19 @アプリ のメンションから作ったときも、ふつうのタスクと同じく「表紙の親投稿」を新しく作り、詳細はその親投稿のスレッドにまとめる（メンションの元の投稿のスレッドには、下書きカードが「作成しました＋表紙へのリンク」に変わる）
    const threadTs: string | undefined = meta.thread_ts;
    // アプリとの DM から作ったとき（チャンネル ID が D で始まる）は、既定の置き場（設定 hq_task_slack.parent_channel_key・なければ hq.chat＝#本部-チャット）に表紙の親投稿を出す
    const fromDm = String(meta.channel ?? "").startsWith("D");
    let key: string | null;
    if (fromDm) {
      const { data: st } = await sb.from("app_settings").select("value").eq("key", "hq_task_slack").maybeSingle();
      const want = String(st?.value?.parent_channel_key ?? "hq.chat");
      const { data: ch } = await sb.from("slack_channels").select("channel_key").eq("channel_key", want).eq("is_active", true).maybeSingle();
      key = ch?.channel_key ?? null;
    } else key = threadTs ? await ensureChannelKey(sb, meta.channel) : await channelKeyOf(sb, meta.channel);
    if (key) {
      let r1: any = null;
      {
        const pm = parentMessage({ title: v.title, due: data.due, dueTime: data.due_time, strip: { urgent: v.urgent, names: [...new Set(made.flatMap((x) => x.assignee_ids))].length ? (await namesOf(sb, [...new Set(made.flatMap((x) => x.assignee_ids))])) : [], stepsDone: 0, stepsTotal: made.length } });
        r1 = await d.sendSlack({ action: "send", channel_key: key, text: pm.text, blocks: pm.blocks, event: "hqtask_parent", source: "ef:slack-interact", dedupe_key: `hqtask_parent:${data.task_id}`, ref: { table: "hq_tasks", id: data.task_id } });
      }
      if (r1?.ok && r1.ts) {
        parentRef = { channel: String(r1.slack_channel_id ?? meta.channel ?? ""), ts: String(r1.ts) };
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
    {
      const pu = parentRef ? await permalinkOf(parentRef.channel, parentRef.ts) : null;
      await sendAssignedDms(pu && parentRef ? { url: pu, channel: parentRef.channel } : null);
    }
    return parentRef;
}

// @メンションの下書きカードを「作成しました」に書き換え、下書きの状態を更新する
// deno-lint-ignore no-explicit-any
async function markDraftCreated(d: Deps, sb: any, draftId: string, taskId: string, title: string, parent?: { channel: string; ts: string } | null): Promise<void> {
  const { data: dr } = await sb.from("hq_slack_ai_draft").update({ status: "created", task_id: taskId }).eq("id", draftId).select("card_notification_id").maybeSingle();
  // 表紙の親投稿へのリンク（取れなければ、リンクなしで「作成しました」だけ）
  let link: string | null = null;
  if (parent?.channel && parent.ts) {
    try {
      const r = await fetch(`https://slack.com/api/chat.getPermalink?channel=${encodeURIComponent(parent.channel)}&message_ts=${encodeURIComponent(parent.ts)}`, { headers: { Authorization: `Bearer ${Deno.env.get("SLACK_BOT_TOKEN")}` } });
      const j = await r.json().catch(() => ({})); if (j?.ok && typeof j.permalink === "string") link = j.permalink;
    } catch { /* リンクなし */ }
  }
  if (dr?.card_notification_id) await d.sendSlack({ action: "update", notification_id: dr.card_notification_id, text: `✅ 本部タスクを作成しました：${title}`, blocks: [{ type: "section", text: { type: "mrkdwn", text: `✅ *本部タスクを作成しました*\n${title}${link ? `\n<${link}|表紙の投稿を開く（詳細はそのスレッドにあります）>` : ""}` } }] });
}

// Bot Token の権限に files:read があるか（コメントの添付の入力欄を出すかの判断）。10 分だけ覚える
let _scopeCache: { at: number; ok: boolean } | null = null;
async function hasFilesScope(): Promise<boolean> {
  if (_scopeCache && Date.now() - _scopeCache.at < 600_000) return _scopeCache.ok;
  let ok = false;
  try {
    const r = await fetch("https://slack.com/api/auth.test", { method: "POST", headers: { Authorization: `Bearer ${Deno.env.get("SLACK_BOT_TOKEN")}` } });
    ok = String(r.headers.get("x-oauth-scopes") ?? "").split(",").map((x) => x.trim()).includes("files:read");
  } catch { ok = false; }
  _scopeCache = { at: Date.now(), ok };
  return ok;
}
// Slack に上げられた写真・PDF を、管理システムのコメントの添付として保存する（写真と同じ置き場 report-photos・本人のフォルダ）。保存できたものを返す
// deno-lint-ignore no-explicit-any
async function saveCommentFiles(sb: any, o: { files: any[]; commentId: string; taskId: string; userId: string }): Promise<{ id: string; path: string; name: string; mime: string }[]> {
  const saved: { id: string; path: string; name: string; mime: string }[] = [];
  for (const f of o.files) {
    try {
      const mime = String(f?.mimetype ?? "");
      if (!(mime.startsWith("image/") || mime === "application/pdf")) continue;
      const url = String(f?.url_private_download ?? f?.url_private ?? "");
      if (!url.startsWith("https://files.slack.com/")) continue;
      if (Number(f?.size ?? 0) > 15 * 1024 * 1024) continue;
      const res = await fetch(url, { headers: { Authorization: `Bearer ${Deno.env.get("SLACK_BOT_TOKEN")}` } });
      if (!res.ok || !(res.headers.get("content-type") ?? "").match(/^(image\/|application\/pdf)/)) continue;
      const bytes = new Uint8Array(await res.arrayBuffer());
      if (bytes.length > 15 * 1024 * 1024) continue;
      const ext = (String(f?.name ?? "").split(".").pop() ?? "").toLowerCase().replace(/[^a-z0-9]/g, "") || (mime === "application/pdf" ? "pdf" : "jpg");
      const path = `${o.userId}/hqtask_slack_${Date.now()}_${Math.random().toString(36).slice(2, 7)}.${ext}`;
      const up = await sb.storage.from("report-photos").upload(path, bytes, { contentType: mime, upsert: false });
      if (up.error) continue;
      const ins = await sb.from("hq_task_comment_files").insert({ comment_id: o.commentId, task_id: o.taskId, storage_path: path, file_name: String(f?.name ?? "").slice(0, 120), created_by: o.userId }).select("id").single();
      if (!ins.error && ins.data?.id) saved.push({ id: String(ins.data.id), path, name: String(f?.name ?? "").slice(0, 120), mime });
    } catch { /* 1 件ずつ。失敗した分は数えない */ }
  }
  return saved;
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
      d.waitUntil((async () => { const pr = data.duplicate ? null : await afterCreate(d, sb, actor, v, data, { channel: dr.channel_id, thread_ts: dr.thread_ts }); await markDraftCreated(d, sb, dr.id, data.task_id, dd.title, pr); })());
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
      d.waitUntil((async () => { const pr = data.duplicate ? null : await afterCreate(d, sb, actor, v, data, meta); if (meta.draft_id) await markDraftCreated(d, sb, meta.draft_id, data.task_id, v.title, pr); })());
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
          const pu = g?.card_channel && g?.parent_ts ? await permalinkOf(String(g.card_channel), String(g.parent_ts)) : null;
          const m = assignedMessage({ title: `${data.title}（工程：${data.step_title}）`, due: v.due, dueTime: v.dueTime, creatorName: String(data.editor_name ?? actor.name), memo: v.note, step_id: String(data.step_id), url: urlOf(meta.task_id), canComplete: !v.photo, taskId: meta.task_id, parent: pu ? { url: pu, channel: String(g.card_channel) } : null });
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
      return await d.openModal(payload.trigger_id, commentModal({ taskId: value.task_id, title: data.title, withFiles: await hasFilesScope() }));
    },
    // 2026-11-19 送信を押したら、すぐ窓を閉じる（Slack は 3 秒以内の返事を待つ。重い処理を待つと「Slack になかなか接続できません」と出て、実際は送れているのに何度も送ってしまっていた）。
    //   中身が空のときだけ、その場でエラー。ほかの処理は裏で行い、失敗したときは本人に DM で知らせる。同じ内容を 30 秒以内に同じ人が同じタスクへ送っていたら、二重に入れない
    [COMMENT_MODAL]: async ({ sb, payload, actor }) => {
      const taskId = metaOf(payload).task_id;
      const vals = payload.view?.state?.values ?? {};
      const body0 = String(vals?.body?.body?.value ?? "").trim();
      if (!body0) return d.json({ response_action: "errors", errors: { body: "コメントを入力してください" } });
      const slackUser = payload.user?.id;
      d.waitUntil((async () => {
        const fail = async (why: string) => { await d.sendSlack({ action: "send", channel_key: `user:${actor.user_id}`, text: `⚠️ コメントを送れませんでした：${why}`, event: "hqtask_comment_failed", source: "ef:slack-interact" }); };
        try {
          let body = body0;
          // 選んだ相手（Slack の人）→ 管理システムの名前の「@名前」を頭に付ける（すでに本文にあれば足さない）。管理システムに紐づいていない人は付けられない
          const picked = ((vals?.mentions?.mentions?.selected_users ?? []) as string[]).filter((u) => /^[UW][A-Z0-9]+$/.test(u)).slice(0, 10);
          if (picked.length) {
            const { data: links } = await sb.from("user_slack").select("user_id,slack_user_id").in("slack_user_id", picked);
            const { data: us } = await sb.from("users").select("id,name").eq("is_active", true).in("id", (links ?? []).map((l: any) => l.user_id));
            const nm = new Map((us ?? []).map((u: any) => [u.id, String(u.name ?? "").replace(/[\s\u3000]+/g, "")]));
            const names: string[] = [];
            for (const sid of picked) { const l = (links ?? []).find((x: any) => x.slack_user_id === sid); const n = l ? nm.get(l.user_id) : null; if (n && !body.includes("@" + n)) names.push("@" + n); }
            if (names.length) body = `${names.join(" ")} ${body}`.slice(0, 2000);
          }
          // 二重送信の防止（同じ人・同じタスク・同じ内容を 30 秒以内）
          const since = new Date(Date.now() - 30_000).toISOString();
          const { data: dup } = await sb.from("hq_task_comments").select("id").eq("task_id", taskId).eq("created_by", actor.user_id).eq("body", body).gte("created_at", since).limit(1);
          if ((dup ?? []).length) return;
          const { data, error } = await sb.rpc("hq_slack_comment_add", { p_slack_user_id: slackUser, p_task: taskId, p_body: body });
          if (error) return await fail(String(error.message).slice(0, 120));
          if (!data?.ok) return await fail(String(data?.message ?? "送信できませんでした"));
          const files = ((vals?.files?.files?.files ?? []) as any[]).slice(0, 5);
          const saved = files.length ? await saveCommentFiles(sb, { files, commentId: data.comment_id, taskId, userId: actor.user_id }) : [];
          const { data: g } = await sb.rpc("hq_slack_task_get", { p_task: taskId });
          const key = await channelKeyOf(sb, g?.card_channel);
          // スレッドにも写真を出す（画像はその場で表示・クリックで大きく開く）。各ファイルの名前のリンクは「ずっと使える」管理システム経由（ログインして開く）。画像の表示用の 24 時間リンクは、その場の表示にだけ使う
          const imgs: unknown[] = []; const links: string[] = [];
          for (const f of saved) {
            const nm = (f.name || "添付").replace(/[<>|]/g, " ").slice(0, 50);
            links.push(`<${urlOf(taskId)}&file=${f.id}|${f.mime.startsWith("image/") ? "🖼" : "📄"} ${nm}>`);
            if (!f.mime.startsWith("image/")) continue;
            const { data: su } = await sb.storage.from("report-photos").createSignedUrl(f.path, 86400);
            if (su?.signedUrl) imgs.push({ type: "image", image_url: su.signedUrl, alt_text: nm, title: { type: "plain_text", text: nm } });
          }
          const head = `💬 ${actor.name}：${body.slice(0, 300)}${body.length > 300 ? "…" : ""}`;
          const tail = `${saved.length ? `\n📎 添付 ${saved.length} 件　${links.join("　")}` : ""}${files.length > saved.length ? `\n⚠️ 添付 ${files.length - saved.length} 件は保存できませんでした` : ""}`;
          const elements: unknown[] = [];
          if (saved.length) elements.push({ type: "button", text: { type: "plain_text", text: "管理システムで開く", emoji: true }, url: urlOf(taskId), action_id: STEP_LINK });
          // ［🗑 削除］: 押すと、このコメントを管理システムからも消し、このメッセージも消す（書いた本人・本部・マスターだけ。確認つき）
          elements.push({ type: "button", text: { type: "plain_text", text: "🗑 削除", emoji: true }, action_id: COMMENT_DELETE, value: JSON.stringify({ comment_id: data.comment_id }),
            confirm: { title: { type: "plain_text", text: "このコメントを削除しますか？" }, text: { type: "mrkdwn", text: "管理システムのコメントも一緒に消えます（元に戻せません）。" }, confirm: { type: "plain_text", text: "削除する" }, deny: { type: "plain_text", text: "やめる" } } });
          const blocksOut: unknown[] = [{ type: "section", text: { type: "mrkdwn", text: head + tail } }, ...imgs.slice(0, 5), { type: "actions", block_id: "hqtask_comment_actions", elements }];
          if (key && g?.parent_ts) await d.sendSlack({ action: "send", channel_key: key, thread_ts: g.parent_ts, text: head + (saved.length ? `（添付 ${saved.length} 件）` : ""), blocks: blocksOut, event: "hqtask_comment_thread", source: "ef:slack-interact",
            dedupe_key: `hqtask_comment_thread:${data.comment_id}`, ref: { table: "hq_tasks", id: taskId } });
        } catch (e) { await fail(String(e).slice(0, 100)); }
      })());
      return d.json({ response_action: "clear" });
    },
    // 2026-11-19 スレッドのコメントの［🗑 削除］: 管理システムのコメントを消す（権限は DB 側 hq_slack_comment_delete が判定）→ 成功したら、この Slack のメッセージも消す
    [COMMENT_DELETE]: async ({ sb, payload, value }) => {
      const { data, error } = await sb.rpc("hq_slack_comment_delete", { p_slack_user_id: payload.user?.id, p_comment: value?.comment_id });
      if (error) return d.ephemeral("削除できませんでした: " + String(error.message).slice(0, 120), payload.response_url);
      if (!data?.ok) return d.ephemeral(String(data?.message ?? "削除できませんでした"), payload.response_url);
      const ch = payload.channel?.id ?? payload.container?.channel_id; const ts = payload.message?.ts ?? payload.container?.message_ts;
      if (ch && ts) d.waitUntil((async () => { await fetch("https://slack.com/api/chat.delete", { method: "POST", headers: { "Content-Type": "application/json; charset=utf-8", Authorization: `Bearer ${Deno.env.get("SLACK_BOT_TOKEN")}` }, body: JSON.stringify({ channel: ch, ts }) }).catch(() => {}); })());
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
