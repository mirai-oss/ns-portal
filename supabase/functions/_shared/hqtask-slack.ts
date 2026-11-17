// 本部タスクの Slack 連携（2026-11-17・第 1 段階）: DM の文面とボタン・作成フォーム（モーダル）・送信内容の読み取り。
//   DB の処理は supabase/2026-12-13_hq_slack_task.sql の関数（hq_slack_*）。ここは Slack に出す形だけ（金額・口座は扱わない）。
//   action_id: hqtask.create.open（フォームを開く）／hqtask.create.modal（フォームの送信）／hqtask.step.done（完了）／hqtask.step.ack（対応中）／hqtask.link（リンクだけ）

export const CORPS = ["トーホー", "N-Style", "SK", "LiveGate"] as const;
export const CREATE_OPEN = "hqtask.create.open";
export const CREATE_OPEN_DETAIL = "hqtask.create.open.detail";
export const CREATE_MODAL = "hqtask.create.modal";
export const STEP_DONE = "hqtask.step.done";
export const STEP_ACK = "hqtask.step.ack";
export const STEP_LINK = "hqtask.link";

export type Candidate = {
  recipient_id: string; slack_user_id: string; task_id: string; step_id: string; task_title: string; step_title: string; due_date: string;
  due_time?: string | null; kind: string; days_over: number; creator_id: string | null; can_complete: boolean; url: string;
};

const clean = (s: unknown, n: number) => String(s ?? "").replace(/[\u0000-\u001f]/g, " ").trim().slice(0, n);
const md = (d: string, time?: string | null) => { const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(d); const day = m ? `${Number(m[2])}/${Number(m[3])}` : d; const tm = /^(\d{2}):(\d{2})/.exec(String(time ?? "")); return tm ? `${day} ${Number(tm[1])}:${tm[2]}` : day; };

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
export function reminderMessage(c: Candidate, x: { creatorName?: string | null; memo?: string | null } = {}): { text: string; blocks: unknown[] } {
  const h = reminderHead(c.kind, c.days_over);
  const title = clean(c.task_title, 100);
  const lines = [`${h.mark} *${h.head}*`, `*${title}*`, `${x.creatorName ? `依頼：${clean(x.creatorName, 30)}　` : ""}期限：${md(c.due_date, c.due_time)}　工程：${clean(c.step_title, 60)}`];
  if (x.memo && clean(x.memo, 200)) lines.push(`詳細：${clean(x.memo, 200)}`);
  lines.push(`🔗 <${c.url}|管理システムで開く>`);
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
export function assignedMessage(o: { title: string; stepTitle?: string; due: string; dueTime?: string | null; steps?: number; creatorName: string; memo?: string | null; step_id: string; url: string; canComplete: boolean }): { text: string; blocks: unknown[] } {
  const lines = [`📌 *新しい本部タスクが割り当てられました*`, `*${clean(o.title, 100)}*`, `期限：${md(o.due, o.dueTime)}　依頼：${clean(o.creatorName, 30)}${o.steps && o.steps > 1 ? `　工程：${o.steps} 個` : ""}`];
  if (o.memo && clean(o.memo, 300)) lines.push(`詳細：${clean(o.memo, 300)}`);
  lines.push(`🔗 <${o.url}|管理システムで開く>`);
  const val = JSON.stringify({ step_id: o.step_id });
  const elements: unknown[] = [];
  if (o.canComplete) elements.push({ type: "button", style: "primary", text: { type: "plain_text", text: "✅ 完了にする", emoji: true }, action_id: STEP_DONE, value: val });
  elements.push({ type: "button", text: { type: "plain_text", text: "🕐 対応中", emoji: true }, action_id: STEP_ACK, value: val });
  elements.push({ type: "button", text: { type: "plain_text", text: "管理システムで開く", emoji: true }, url: o.url, action_id: STEP_LINK });
  return { text: `📌 新しい本部タスク：${clean(o.title, 100)}`, blocks: [{ type: "section", text: { type: "mrkdwn", text: lines.join("\n") } }, { type: "actions", block_id: "hqtask", elements }] };
}

/** チャンネルに置く「タスクを作る」ボタンのメッセージ（ボタンは 1 つ。下の欄に詳細も入れられる） */
export function createButtonMessage(): { text: string; blocks: unknown[] } {
  return {
    text: "本部タスクを作る",
    blocks: [
      { type: "section", text: { type: "mrkdwn", text: "📝 *本部タスクを作る*\nボタンを押すと入力フォームが開きます。上の 4 つ（やること・法人・担当者・期限）だけでも作れます。注意事項・工程・写真は、フォームの下の欄に入れられます。送信すると本部タスクが付き、担当者の Slack の DM に届きます。（作れるのは本部・社長・店長）" } },
      { type: "actions", block_id: "hqtask_create", elements: [{ type: "button", style: "primary", text: { type: "plain_text", text: "＋ タスクを作る", emoji: true }, action_id: CREATE_OPEN, value: "{}" }] },
    ],
  };
}

export const EDIT_ACTION = "hqtask.task.edit";
export const EDIT_MODAL = "hqtask.edit.modal";

export type Initial = { title?: string; corp?: string; assigneeSlackIds?: string[]; due?: string | null; dueTime?: string | null; memo?: string | null; notes?: string | null; urgent?: boolean };

/** 作成・編集のフォーム（モーダル）。上＝やること・法人・担当者・期限（日付＋時刻）。下＝詳細（任意）: 詳細・注意事項・工程・写真・最重要 */
export function createModal(o: { mode?: "create" | "edit"; initial?: Initial; meta?: Record<string, unknown> } = {}): unknown {
  const edit = o.mode === "edit";
  const ini = o.initial ?? {};
  const withInit = (el: any, key: string, val: unknown) => (val !== undefined && val !== null && val !== "" ? { ...el, [key]: val } : el);
  const blocks: unknown[] = [
    { type: "input", block_id: "title", label: { type: "plain_text", text: "やること" }, element: withInit({ type: "plain_text_input", action_id: "title", max_length: 120, placeholder: { type: "plain_text", text: "例：10月分の請求書を確認する" } }, "initial_value", ini.title) },
    { type: "input", block_id: "corp", label: { type: "plain_text", text: "法人" }, element: withInit({ type: "static_select", action_id: "corp", placeholder: { type: "plain_text", text: "選ぶ" }, options: CORPS.map((c) => ({ text: { type: "plain_text", text: c }, value: c })) }, "initial_option", ini.corp ? { text: { type: "plain_text", text: ini.corp }, value: ini.corp } : null) },
    { type: "input", block_id: "assignees", label: { type: "plain_text", text: "担当者（複数可）" }, element: withInit({ type: "multi_users_select", action_id: "assignees", placeholder: { type: "plain_text", text: "選ぶ" } }, "initial_users", ini.assigneeSlackIds?.length ? ini.assigneeSlackIds : null) },
    { type: "input", block_id: "due", label: { type: "plain_text", text: "期限（日付）" }, element: withInit({ type: "datepicker", action_id: "due" }, "initial_date", ini.due) },
    { type: "input", block_id: "due_time", optional: true, label: { type: "plain_text", text: "期限（時刻・任意）" }, element: withInit({ type: "timepicker", action_id: "due_time", placeholder: { type: "plain_text", text: "時刻を選ぶ" } }, "initial_time", ini.dueTime ? String(ini.dueTime).slice(0, 5) : null) },
    { type: "divider" },
    { type: "section", text: { type: "mrkdwn", text: "*▼ 詳細（すべて任意・入れなくても作れます）*" } },
    { type: "input", block_id: "memo", optional: true, label: { type: "plain_text", text: "詳細" }, element: withInit({ type: "plain_text_input", action_id: "memo", multiline: true, max_length: 500 }, "initial_value", ini.memo) },
    { type: "input", block_id: "notes", optional: true, label: { type: "plain_text", text: "注意事項" }, element: withInit({ type: "plain_text_input", action_id: "notes", multiline: true, max_length: 1000, placeholder: { type: "plain_text", text: "担当者に必ず守ってほしいこと" } }, "initial_value", ini.notes) },
    { type: "input", block_id: "steps", optional: true, label: { type: "plain_text", text: edit ? "工程を追加（1 行に 1 つ）" : "工程（1 行に 1 つ・最大 10）" }, hint: { type: "plain_text", text: edit ? "いまある工程は消えません。ここに書いたものが、後ろに追加されます。" : "書かなければ「対応する」の 1 工程になります。担当者と期限は全工程で共通です。" },
      element: { type: "plain_text_input", action_id: "steps", multiline: true, max_length: 900, placeholder: { type: "plain_text", text: "資料を集める\n内容を確認する\n提出する" } } },
  ];
  if (!edit) blocks.push({ type: "input", block_id: "photo", optional: true, label: { type: "plain_text", text: "写真" }, element: { type: "checkboxes", action_id: "photo", options: [{ text: { type: "plain_text", text: "各工程の完了に写真が必要" }, value: "1" }] } });
  const urgentOpt = { text: { type: "plain_text", text: "最重要のタスクにする" }, value: "1" };
  blocks.push({ type: "input", block_id: "urgent", optional: true, label: { type: "plain_text", text: "最重要" }, element: withInit({ type: "checkboxes", action_id: "urgent", options: [urgentOpt] }, "initial_options", ini.urgent ? [urgentOpt] : null) });
  return { type: "modal", callback_id: edit ? EDIT_MODAL : CREATE_MODAL, private_metadata: JSON.stringify(o.meta ?? {}),
    title: { type: "plain_text", text: edit ? "本部タスクを編集" : "本部タスクを作る" }, submit: { type: "plain_text", text: edit ? "保存" : "作成" }, close: { type: "plain_text", text: "やめる" }, blocks };
}

/** 親投稿（1 行）。状態の印・種別・タイトル・期限 */
export function parentMessage(o: { title: string; due: string; dueTime?: string | null; done?: boolean }): { text: string; blocks: unknown[] } {
  const text = `${o.done ? "✅" : "🕒"} 本部タスク｜${clean(o.title, 60)}｜${md(o.due, o.dueTime)}${o.done ? "｜完了" : ""}`;
  return { text, blocks: [{ type: "section", text: { type: "mrkdwn", text } }] };
}

/** スレッドの詳細カード。「編集」ボタンから Slack の中で直せる */
export function taskCardMessage(o: { task_id: string; title: string; corp: string; assigneeNames: string[]; due: string; dueTime?: string | null; memo?: string | null; notes?: string | null;
  steps: { title: string; done: boolean }[]; creatorName: string; urgent?: boolean; url: string }): { text: string; blocks: unknown[] } {
  const lines = [`${o.urgent ? "🔥 " : ""}*${clean(o.title, 100)}*`, `法人：${clean(o.corp, 20)}　担当：${o.assigneeNames.map((n) => clean(n, 20)).join("・") || "—"}`, `期限：${md(o.due, o.dueTime)}　依頼：${clean(o.creatorName, 30)}`];
  if (o.memo && clean(o.memo, 300)) lines.push(`詳細：${clean(o.memo, 300)}`);
  if (o.notes && clean(o.notes, 300)) lines.push(`⚠️ 注意事項：${clean(o.notes, 300)}`);
  if (o.steps.length > 1 || (o.steps[0] && o.steps[0].title !== "対応する")) lines.push("工程：" + o.steps.map((s) => `${s.done ? "✅" : "▫️"}${clean(s.title, 40)}`).join(" → "));
  return {
    text: `本部タスクの詳細：${clean(o.title, 100)}`,
    blocks: [
      { type: "section", text: { type: "mrkdwn", text: lines.join("\n") } },
      { type: "actions", block_id: "hqtask_card", elements: [
        { type: "button", text: { type: "plain_text", text: "✏️ 編集", emoji: true }, action_id: EDIT_ACTION, value: JSON.stringify({ task_id: o.task_id }) },
        { type: "button", text: { type: "plain_text", text: "管理システムで開く", emoji: true }, url: o.url, action_id: STEP_LINK },
      ] },
    ],
  };
}

export type CreateInput = { title: string; corp: string; slackAssignees: string[]; due: string; dueTime: string | null; memo: string; urgent: boolean; notes: string; steps: string[]; photo: boolean };
/** モーダル送信（view.state.values）を読む。足りないものは errors（入力欄の block_id → 文言） */
export function parseCreate(values: any): { ok: true; v: CreateInput } | { ok: false; errors: Record<string, string> } {
  const g = values ?? {};
  const title = clean(g.title?.title?.value, 120);
  const corp = String(g.corp?.corp?.selected_option?.value ?? "");
  const slackAssignees: string[] = Array.isArray(g.assignees?.assignees?.selected_users) ? g.assignees.assignees.selected_users.filter((x: unknown) => /^[UW][A-Z0-9]{6,}$/.test(String(x))).slice(0, 10) : [];
  const due = String(g.due?.due?.selected_date ?? "");
  const memo = String(g.memo?.memo?.value ?? "").trim().slice(0, 500);
  const tm = String(g.due_time?.due_time?.selected_time ?? "");
  const dueTime = /^\d{2}:\d{2}$/.test(tm) ? tm : null;
  const notes = String(g.notes?.notes?.value ?? "").trim().slice(0, 1000);
  const steps = String(g.steps?.steps?.value ?? "").split(/\r?\n/).map((x) => clean(x, 80)).filter((x) => x);
  const photo = Array.isArray(g.photo?.photo?.selected_options) && g.photo.photo.selected_options.length > 0;
  const urgent = Array.isArray(g.urgent?.urgent?.selected_options) && g.urgent.urgent.selected_options.length > 0;
  const errors: Record<string, string> = {};
  if (!title) errors.title = "やることを入れてください";
  if (!(CORPS as readonly string[]).includes(corp)) errors.corp = "法人を選んでください";
  if (!slackAssignees.length) errors.assignees = "担当者を選んでください";
  if (!/^\d{4}-\d{2}-\d{2}$/.test(due)) errors.due = "期限を選んでください";
  if (steps.length > 10) errors.steps = "工程は 10 個までです";
  if (Object.keys(errors).length) return { ok: false, errors };
  return { ok: true, v: { title, corp, slackAssignees, due, dueTime, memo, urgent, notes, steps, photo } };
}

/** RPC の失敗理由 → モーダルの入力欄のエラー */
export function errorField(reason: string | undefined): string {
  switch (reason) { case "title": return "title"; case "corp": return "corp"; case "due": return "due"; case "assignee": return "assignees"; case "steps": return "steps"; default: return "title"; }
}

/** 完了したあとのメッセージ。元の内容（依頼者・期限・タスク名・リンク）は残し、ボタンは外して（リンクのボタンだけ残す）先頭に完了の印を付ける */
// deno-lint-ignore no-explicit-any
export function completedBlocks(orig: any[] | undefined, by: string, at: string): unknown[] {
  const head = { type: "section", text: { type: "mrkdwn", text: `✅ *完了しました*（${clean(by, 30)}・${clean(at, 30)}）` } };
  const keep: unknown[] = [];
  for (const b of orig ?? []) {
    if (b?.type === "section") keep.push({ type: "section", text: b.text });
    else if (b?.type === "actions") {
      const links = (b.elements ?? []).filter((e: any) => e?.url);
      if (links.length) keep.push({ type: "actions", block_id: "hqtask_done_link", elements: links });
    }
  }
  return [head, ...keep];
}

/** 完了を、そのメッセージのスレッドにも 1 通残す（あとから「何のタスクか」が分かるように。依頼者・期限・リンクつき） */
export function completionThreadText(o: { title: string; due: string; dueTime?: string | null; creatorName?: string | null; by: string; at: string; url: string }): string {
  return [`✅ 完了しました：*${clean(o.title, 100)}*`, `${o.creatorName ? `依頼：${clean(o.creatorName, 30)}　` : ""}期限：${md(o.due, o.dueTime)}　完了：${clean(o.by, 30)}（${clean(o.at, 30)}）`, `🔗 <${o.url}|管理システムで開く>`].join("\n");
}
