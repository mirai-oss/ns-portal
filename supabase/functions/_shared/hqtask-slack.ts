// 本部タスクの Slack 連携（2026-11-17・第 1 段階）: DM の文面とボタン・作成フォーム（モーダル）・送信内容の読み取り。
//   DB の処理は supabase/2026-12-13_hq_slack_task.sql の関数（hq_slack_*）。ここは Slack に出す形だけ（金額・口座は扱わない）。
//   action_id: hqtask.create.open（フォームを開く）／hqtask.create.modal（フォームの送信）／hqtask.step.done（完了）／hqtask.step.ack（対応中）／hqtask.link（リンクだけ）

export const CORPS = ["トーホー", "N-Style", "SK", "LiveGate"] as const;
export const CREATE_OPEN = "hqtask.create.open";
export const CREATE_MODAL = "hqtask.create.modal";
export const STEP_DONE = "hqtask.step.done";
export const STEP_ACK = "hqtask.step.ack";
export const STEP_LINK = "hqtask.link";

export type Candidate = {
  recipient_id: string; slack_user_id: string; task_id: string; step_id: string; task_title: string; step_title: string; due_date: string;
  kind: string; days_over: number; creator_id: string | null; can_complete: boolean; url: string;
};

const clean = (s: unknown, n: number) => String(s ?? "").replace(/[\u0000-\u001f]/g, " ").trim().slice(0, n);
const md = (d: string) => { const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(d); return m ? `${Number(m[2])}/${Number(m[3])}` : d; };

/** 種類ごとの見出し。「見逃さない」ため、期限が近いほど強い言い方にする */
export function reminderHead(kind: string, daysOver: number): { mark: string; head: string } {
  const pm = kind.endsWith("_pm");
  const base = pm ? kind.slice(0, -3) : kind;
  const tail = pm ? "（まだ完了していません）" : "";
  switch (base) {
    case "before3": return { mark: "📌", head: `期限まであと3日${tail}` };
    case "before1": return { mark: "⏰", head: `明日が期限です${tail}` };
    case "today": return { mark: "🔴", head: `今日が期限です${tail}` };
    case "overdue": return { mark: "🚨", head: `期限を ${Math.max(1, daysOver)} 日過ぎています${tail}` };
    case "escalate": return { mark: "⚠️", head: `担当者が期限を ${Math.max(1, daysOver)} 日過ぎています（作成したタスク）` };
    default: return { mark: "📌", head: "本部タスク" };
  }
}

/** DM のメッセージ（親 1 通）。完了できる工程だけ「完了にする」を出す。escalate（作成者向け）は操作ボタンなし */
export function reminderMessage(c: Candidate): { text: string; blocks: unknown[] } {
  const h = reminderHead(c.kind, c.days_over);
  const title = clean(c.task_title, 100);
  const lines = [`${h.mark} *${h.head}*`, `*${title}*`, `工程：${clean(c.step_title, 60)}　期限：${md(c.due_date)}`];
  const blocks: unknown[] = [{ type: "section", text: { type: "mrkdwn", text: lines.join("\n") } }];
  const elements: unknown[] = [];
  if (c.kind !== "escalate") {
    const val = JSON.stringify({ step_id: c.step_id });
    if (c.can_complete) elements.push({ type: "button", style: "primary", text: { type: "plain_text", text: "✅ 完了にする", emoji: true }, action_id: STEP_DONE, value: val });
    elements.push({ type: "button", text: { type: "plain_text", text: "🕐 対応中", emoji: true }, action_id: STEP_ACK, value: val });
  }
  elements.push({ type: "button", text: { type: "plain_text", text: "管理システムで開く", emoji: true }, url: c.url, action_id: STEP_LINK });
  blocks.push({ type: "actions", block_id: "hqtask", elements });
  return { text: `${h.mark} ${h.head}：${title}`, blocks };
}

/** 新しく割り当てられたときの DM */
export function assignedMessage(o: { title: string; stepTitle?: string; due: string; creatorName: string; memo?: string | null; step_id: string; url: string; canComplete: boolean }): { text: string; blocks: unknown[] } {
  const lines = [`📌 *新しい本部タスクが割り当てられました*`, `*${clean(o.title, 100)}*`, `期限：${md(o.due)}　依頼：${clean(o.creatorName, 30)}`];
  if (o.memo && clean(o.memo, 300)) lines.push(`詳細：${clean(o.memo, 300)}`);
  const val = JSON.stringify({ step_id: o.step_id });
  const elements: unknown[] = [];
  if (o.canComplete) elements.push({ type: "button", style: "primary", text: { type: "plain_text", text: "✅ 完了にする", emoji: true }, action_id: STEP_DONE, value: val });
  elements.push({ type: "button", text: { type: "plain_text", text: "🕐 対応中", emoji: true }, action_id: STEP_ACK, value: val });
  elements.push({ type: "button", text: { type: "plain_text", text: "管理システムで開く", emoji: true }, url: o.url, action_id: STEP_LINK });
  return { text: `📌 新しい本部タスク：${clean(o.title, 100)}`, blocks: [{ type: "section", text: { type: "mrkdwn", text: lines.join("\n") } }, { type: "actions", block_id: "hqtask", elements }] };
}

/** チャンネルに置く「タスクを作る」ボタンのメッセージ */
export function createButtonMessage(): { text: string; blocks: unknown[] } {
  return {
    text: "本部タスクを作る",
    blocks: [
      { type: "section", text: { type: "mrkdwn", text: "📝 *本部タスクを作る*\nボタンを押すと入力フォームが開きます。送信すると本部タスクが付き、担当者の Slack の DM に届きます。（作れるのは本部・社長・店長）" } },
      { type: "actions", block_id: "hqtask_create", elements: [{ type: "button", style: "primary", text: { type: "plain_text", text: "＋ タスクを作る", emoji: true }, action_id: CREATE_OPEN, value: "{}" }] },
    ],
  };
}

/** 作成フォーム（モーダル）。入力: 内容・法人・担当者（複数）・期限・詳細・最重要 */
export function createModal(): unknown {
  return {
    type: "modal", callback_id: CREATE_MODAL,
    title: { type: "plain_text", text: "本部タスクを作る" }, submit: { type: "plain_text", text: "作成" }, close: { type: "plain_text", text: "やめる" },
    blocks: [
      { type: "input", block_id: "title", label: { type: "plain_text", text: "やること" }, element: { type: "plain_text_input", action_id: "title", max_length: 120, placeholder: { type: "plain_text", text: "例：10月分の請求書を確認する" } } },
      { type: "input", block_id: "corp", label: { type: "plain_text", text: "法人" }, element: { type: "static_select", action_id: "corp", placeholder: { type: "plain_text", text: "選ぶ" }, options: CORPS.map((c) => ({ text: { type: "plain_text", text: c }, value: c })) } },
      { type: "input", block_id: "assignees", label: { type: "plain_text", text: "担当者（複数可）" }, element: { type: "multi_users_select", action_id: "assignees", placeholder: { type: "plain_text", text: "選ぶ" } } },
      { type: "input", block_id: "due", label: { type: "plain_text", text: "期限" }, element: { type: "datepicker", action_id: "due" } },
      { type: "input", block_id: "memo", optional: true, label: { type: "plain_text", text: "詳細（任意）" }, element: { type: "plain_text_input", action_id: "memo", multiline: true, max_length: 500 } },
      { type: "input", block_id: "urgent", optional: true, label: { type: "plain_text", text: "最重要" }, element: { type: "checkboxes", action_id: "urgent", options: [{ text: { type: "plain_text", text: "最重要のタスクにする" }, value: "1" }] } },
    ],
  };
}

export type CreateInput = { title: string; corp: string; slackAssignees: string[]; due: string; memo: string; urgent: boolean };
/** モーダル送信（view.state.values）を読む。足りないものは errors（入力欄の block_id → 文言） */
export function parseCreate(values: any): { ok: true; v: CreateInput } | { ok: false; errors: Record<string, string> } {
  const g = values ?? {};
  const title = clean(g.title?.title?.value, 120);
  const corp = String(g.corp?.corp?.selected_option?.value ?? "");
  const slackAssignees: string[] = Array.isArray(g.assignees?.assignees?.selected_users) ? g.assignees.assignees.selected_users.filter((x: unknown) => /^[UW][A-Z0-9]{6,}$/.test(String(x))).slice(0, 10) : [];
  const due = String(g.due?.due?.selected_date ?? "");
  const memo = String(g.memo?.memo?.value ?? "").trim().slice(0, 500);
  const urgent = Array.isArray(g.urgent?.urgent?.selected_options) && g.urgent.urgent.selected_options.length > 0;
  const errors: Record<string, string> = {};
  if (!title) errors.title = "やることを入れてください";
  if (!(CORPS as readonly string[]).includes(corp)) errors.corp = "法人を選んでください";
  if (!slackAssignees.length) errors.assignees = "担当者を選んでください";
  if (!/^\d{4}-\d{2}-\d{2}$/.test(due)) errors.due = "期限を選んでください";
  if (Object.keys(errors).length) return { ok: false, errors };
  return { ok: true, v: { title, corp, slackAssignees, due, memo, urgent } };
}

/** RPC の失敗理由 → モーダルの入力欄のエラー */
export function errorField(reason: string | undefined): string {
  switch (reason) { case "title": return "title"; case "corp": return "corp"; case "due": return "due"; case "assignee": return "assignees"; default: return "title"; }
}
