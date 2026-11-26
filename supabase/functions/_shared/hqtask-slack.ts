// 本部タスクの Slack 連携（2026-11-17・第 1 段階）: DM の文面とボタン・作成フォーム（モーダル）・送信内容の読み取り。
//   DB の処理は supabase/2026-12-13_hq_slack_task.sql の関数（hq_slack_*）。ここは Slack に出す形だけ（金額・口座は扱わない）。
//   action_id: hqtask.create.open（フォームを開く）／hqtask.create.modal（フォームの送信）／hqtask.step.done（完了）／hqtask.step.ack（対応中）／hqtask.link（リンクだけ）

export const CORPS = ["トーホー", "N-Style", "SK", "LiveGate"] as const;
export const CREATE_OPEN = "hqtask.create.open";
export const CREATE_OPEN_DETAIL = "hqtask.create.open.detail";
export const CREATE_MODAL = "hqtask.create.modal";
export const STEP_DONE = "hqtask.step.done";
export const STEP_REOPEN = "hqtask.step.reopen";   // 完了にした工程の［↩️ 取り消し］（2026-11-19）
export const STEP_ACK = "hqtask.step.ack";
export const STEP_LINK = "hqtask.link";
export const COMMENT_OPEN = "hqtask.comment.open";   // チャンネルのカードの［💬 コメント］（2026-11-18）
export const COMMENT_MODAL = "hqtask.comment.modal";
export const COMMENT_DELETE = "hqtask.comment.delete";   // スレッドのコメントの［🗑 削除］（2026-11-19）

export type Candidate = {
  recipient_id: string; slack_user_id: string; task_id: string; step_id: string; task_title: string; step_title: string; due_date: string;
  due_time?: string | null; kind: string; days_over: number; creator_id: string | null; can_complete: boolean; url: string;
};

const clean = (s: unknown, n: number) => String(s ?? "").replace(/[\u0000-\u001f]/g, " ").trim().slice(0, n);
const md = (d: string, time?: string | null) => { const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(d); const day = m ? `${Number(m[2])}/${Number(m[3])}` : d; const tm = /^(\d{2}):(\d{2})/.exec(String(time ?? "")); return tm ? `${day} ${Number(tm[1])}:${tm[2]}` : day; };

/** 親投稿（チャンネル）へのリンク行。どのチャンネルのタスクか分かるよう、チャンネル名も添える（2026-11-19） */
export type ParentRef = { url: string; channel?: string | null };
const parentLine = (p?: ParentRef | null) => (p?.url ? `📍 <${p.url}|親投稿を開く>${p.channel && /^[CG][A-Z0-9]+$/.test(p.channel) ? `（<#${p.channel}>）` : ""}` : null);
/** DM から直せる人（作った人・本部・社長）だけに出す［✏️ 編集］［🧩 工程を編集］。画面で作ったタスクでも使える（2026-11-20） */
const editBtns = (taskId?: string | null, can?: boolean) => (taskId && can ? [
  { type: "button", text: { type: "plain_text", text: "✏️ 編集", emoji: true }, action_id: EDIT_ACTION, value: JSON.stringify({ task_id: taskId }) },
  { type: "button", text: { type: "plain_text", text: "🧩 工程を編集", emoji: true }, action_id: STEPS_OPEN, value: JSON.stringify({ task_id: taskId }) },
] : []);
const commentBtn = (taskId?: string | null) => (taskId ? [{ type: "button", text: { type: "plain_text", text: "💬 コメント", emoji: true }, action_id: COMMENT_OPEN, value: JSON.stringify({ task_id: taskId }) }] : []);

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
export function reminderMessage(c: Candidate, x: { creatorName?: string | null; memo?: string | null; parent?: ParentRef | null; canEdit?: boolean } = {}): { text: string; blocks: unknown[] } {
  const h = reminderHead(c.kind, c.days_over);
  const title = clean(c.task_title, 100);
  const lines = [`${h.mark} *${h.head}*`, `*${title}*`, `${x.creatorName ? `依頼：${clean(x.creatorName, 30)}　` : ""}期限：${md(c.due_date, c.due_time)}　工程：${clean(c.step_title, 60)}`];
  if (x.memo && clean(x.memo, 200)) lines.push(`詳細：${clean(x.memo, 200)}`);
  lines.push(`🔗 <${c.url}|管理システムで開く>`);
  const pl = parentLine(x.parent); if (pl) lines.push(pl);
  const blocks: unknown[] = [{ type: "section", text: { type: "mrkdwn", text: lines.join("\n") } }];
  const elements: unknown[] = [];
  if (c.kind !== "escalate") {
    const val = JSON.stringify({ step_id: c.step_id });
    if (c.can_complete) elements.push({ type: "button", style: "primary", text: { type: "plain_text", text: "✅ 完了にする", emoji: true }, action_id: STEP_DONE, value: val });
    elements.push({ type: "button", text: { type: "plain_text", text: "🕐 対応中", emoji: true }, action_id: STEP_ACK, value: val });
  }
  elements.push(...commentBtn(c.task_id), ...editBtns(c.task_id, x.canEdit));
  elements.push({ type: "button", text: { type: "plain_text", text: "管理システムで開く", emoji: true }, url: c.url, action_id: STEP_LINK });
  blocks.push({ type: "actions", block_id: "hqtask", elements });
  return { text: `${h.mark} ${h.head}：${title}`, blocks };
}

/** 新しく割り当てられたときの DM */
export function assignedMessage(o: { title: string; stepTitle?: string; due: string; dueTime?: string | null; steps?: number; creatorName: string; memo?: string | null; step_id: string; url: string; canComplete: boolean; taskId?: string; parent?: ParentRef | null }): { text: string; blocks: unknown[] } {
  const lines = [`📌 *新しい本部タスクが割り当てられました*`, `*${clean(o.title, 100)}*`, `期限：${md(o.due, o.dueTime)}　依頼：${clean(o.creatorName, 30)}${o.steps && o.steps > 1 ? `　工程：${o.steps} 個` : ""}`];
  if (o.memo && clean(o.memo, 300)) lines.push(`詳細：${clean(o.memo, 300)}`);
  lines.push(`🔗 <${o.url}|管理システムで開く>`);
  { const pl = parentLine(o.parent); if (pl) lines.push(pl); }
  const val = JSON.stringify({ step_id: o.step_id });
  const elements: unknown[] = [];
  if (o.canComplete) elements.push({ type: "button", style: "primary", text: { type: "plain_text", text: "✅ 完了にする", emoji: true }, action_id: STEP_DONE, value: val });
  elements.push({ type: "button", text: { type: "plain_text", text: "🕐 対応中", emoji: true }, action_id: STEP_ACK, value: val });
  elements.push(...commentBtn(o.taskId));
  elements.push({ type: "button", text: { type: "plain_text", text: "管理システムで開く", emoji: true }, url: o.url, action_id: STEP_LINK });
  return { text: `📌 新しい本部タスク：${clean(o.title, 100)}`, blocks: [{ type: "section", text: { type: "mrkdwn", text: lines.join("\n") } }, { type: "actions", block_id: "hqtask", elements }] };
}

/** チャンネルに置く「タスクを作る」ボタンのメッセージ（ボタンは 1 つ。下の欄に詳細も入れられる） */
export function createButtonMessage(): { text: string; blocks: unknown[] } {
  return {
    text: "本部タスクを作る",
    blocks: [
      { type: "section", text: { type: "mrkdwn", text: "📝 *本部タスクを作る*\nボタンを押すと入力フォームが開きます。工程ごとに「工程名・担当者・期限（日付と時刻）」を入れられ、「＋ 工程を追加」で枠が増えます。工程が 1 つなら、タスク名・法人・担当者・期限だけで作れます。送信すると本部タスクが付き、担当者の Slack の DM に届きます。（作れるのは本部・社長・チーム長・店長）" } },
      { type: "actions", block_id: "hqtask_create", elements: [{ type: "button", style: "primary", text: { type: "plain_text", text: "＋ タスクを作る", emoji: true }, action_id: CREATE_OPEN, value: "{}" }] },
    ],
  };
}

export const FORM_ADD = "hqtask.form.add";
export const FORM_DEL = "hqtask.form.del";
export const EDIT_ACTION = "hqtask.task.edit";
export const STEPS_OPEN = "hqtask.steps.open";
export const STEP_PICK = "hqtask.step.pick";
export const STEP_ADD = "hqtask.step.add";
export const STEPS_MODAL = "hqtask.steps.modal";
export const STEP_MODAL = "hqtask.step.modal";
export const EDIT_MODAL = "hqtask.edit.modal";

export type Initial = { title?: string; corp?: string; assigneeSlackIds?: string[]; due?: string | null; dueTime?: string | null; memo?: string | null; notes?: string | null; urgent?: boolean };

/** 作成・編集のフォーム（モーダル）。上＝やること・法人・担当者・期限（日付＋時刻）。下＝詳細（任意）: 詳細・注意事項・工程・写真・最重要 */
export function createModal(o: { mode?: "create" | "edit"; initial?: Initial; meta?: Record<string, unknown>; form?: CreateForm } = {}): unknown {
  if (o.mode !== "edit") return createFormModal(o.form ?? { steps: [{}] }, o.meta ?? {});
  const edit = true;
  const ini = o.initial ?? {};
  const withInit = (el: any, key: string, val: unknown) => (val !== undefined && val !== null && val !== "" ? { ...el, [key]: val } : el);
  const blocks: unknown[] = [
    { type: "input", block_id: "title", label: { type: "plain_text", text: "やること" }, element: withInit({ type: "plain_text_input", action_id: "title", max_length: 120, placeholder: { type: "plain_text", text: "例：10月分の請求書を確認する" } }, "initial_value", ini.title) },
    { type: "input", block_id: "corp", label: { type: "plain_text", text: "法人" }, element: withInit({ type: "static_select", action_id: "corp", placeholder: { type: "plain_text", text: "選ぶ" }, options: CORPS.map((c) => ({ text: { type: "plain_text", text: c }, value: c })) }, "initial_option", ini.corp ? { text: { type: "plain_text", text: ini.corp }, value: ini.corp } : null) },
    ...(edit ? [] : [
      { type: "input", block_id: "assignees", label: { type: "plain_text", text: "担当者（複数可）" }, element: withInit({ type: "multi_users_select", action_id: "assignees", placeholder: { type: "plain_text", text: "選ぶ" } }, "initial_users", ini.assigneeSlackIds?.length ? ini.assigneeSlackIds : null) },
      { type: "input", block_id: "due", label: { type: "plain_text", text: "期限（日付）" }, element: withInit({ type: "datepicker", action_id: "due" }, "initial_date", ini.due) },
      { type: "input", block_id: "due_time", optional: true, label: { type: "plain_text", text: "期限（時刻・任意）" }, element: withInit({ type: "timepicker", action_id: "due_time", placeholder: { type: "plain_text", text: "時刻を選ぶ" } }, "initial_time", ini.dueTime ? String(ini.dueTime).slice(0, 5) : null) },
    ]),
    { type: "divider" },
    { type: "section", text: { type: "mrkdwn", text: edit ? "*▼ 詳細*\n担当者・期限・工程は、カードの「🧩 工程を編集」から、工程ごとに直せます。" : "*▼ 詳細（すべて任意・入れなくても作れます）*\n工程ごとの担当者・期限は、作ったあとにカードの「🧩 工程を編集」で設定できます。" } },
    { type: "input", block_id: "memo", optional: true, label: { type: "plain_text", text: "詳細" }, element: withInit({ type: "plain_text_input", action_id: "memo", multiline: true, max_length: 500 }, "initial_value", ini.memo) },
    { type: "input", block_id: "notes", optional: true, label: { type: "plain_text", text: "注意事項" }, element: withInit({ type: "plain_text_input", action_id: "notes", multiline: true, max_length: 1000, placeholder: { type: "plain_text", text: "担当者に必ず守ってほしいこと" } }, "initial_value", ini.notes) },
    ...(edit ? [] : [{ type: "input", block_id: "steps", optional: true, label: { type: "plain_text", text: "工程（1 行に 1 つ・最大 10）" }, hint: { type: "plain_text", text: "書かなければ「対応する」の 1 工程になります。最初は全工程が同じ担当者・期限です。" },
      element: { type: "plain_text_input", action_id: "steps", multiline: true, max_length: 900, placeholder: { type: "plain_text", text: "資料を集める\n内容を確認する\n提出する" } } }]),
  ];
  if (!edit) blocks.push({ type: "input", block_id: "photo", optional: true, label: { type: "plain_text", text: "写真" }, element: { type: "checkboxes", action_id: "photo", options: [{ text: { type: "plain_text", text: "各工程の完了に写真が必要" }, value: "1" }] } });
  const urgentOpt = { text: { type: "plain_text", text: "最重要のタスクにする" }, value: "1" };
  blocks.push({ type: "input", block_id: "urgent", optional: true, label: { type: "plain_text", text: "最重要" }, element: withInit({ type: "checkboxes", action_id: "urgent", options: [urgentOpt] }, "initial_options", ini.urgent ? [urgentOpt] : null) });
  return { type: "modal", callback_id: edit ? EDIT_MODAL : CREATE_MODAL, private_metadata: JSON.stringify(o.meta ?? {}),
    title: { type: "plain_text", text: edit ? "本部タスクを編集" : "本部タスクを作る" }, submit: { type: "plain_text", text: edit ? "保存" : "作成" }, close: { type: "plain_text", text: "やめる" }, blocks };
}

/** 親投稿（1 行）。状態の印・種別・タイトル・期限 */
export type ParentStrip = { urgent?: boolean; names?: string[]; stepsDone: number; stepsTotal: number; overdue?: boolean };
/** 親投稿の 2 行目（2026-11-18・同日シンプル化）: 絵は 1 行目の先頭の 1 つだけ。2 行目は文字＋太字で「目立たせたいもの」だけを強調する。
 *  例: *最重要*　*期限超過*　担当 齋藤・青山　工程 1/3 ／ 完了: *完了*　工程 3/3（工程が 1 つだけのときは「工程」を出さない） */
export function parentStrip(x: ParentStrip, done: boolean): string {
  const n = Math.min(10, Math.max(0, x.stepsTotal)), d = Math.min(n, Math.max(0, x.stepsDone));
  const parts: string[] = [];
  if (done) parts.push("*完了*");
  else {
    if (x.urgent) parts.push("*最重要*");
    if (x.overdue) parts.push("*期限超過*");
    const names = [...new Set(x.names ?? [])].slice(0, 3).map((nm) => clean(nm, 12));
    if (names.length) parts.push(`担当 ${names.join("・")}`);
  }
  if (n > 1) parts.push(`工程 ${d}/${n}`);
  return parts.join("　");
}
export function parentMessage(o: { title: string; due: string; dueTime?: string | null; done?: boolean; strip?: ParentStrip }): { text: string; blocks: unknown[] } {
  // 1 行目の先頭の印は 1 つだけ: ✅完了／⏰期限超過／🔥最重要／🕒ふつう（優先はこの順）。strip が無い呼び出しは従来どおり ✅／🕒
  const mark = o.done ? "✅" : o.strip?.overdue ? "⏰" : o.strip?.urgent ? "🔥" : "🕒";
  const text = `${mark} 本部タスク｜${clean(o.title, 60)}｜${md(o.due, o.dueTime)}${o.done ? "｜完了" : ""}`;
  const line = o.strip ? parentStrip(o.strip, !!o.done) : "";
  return { text, blocks: [{ type: "section", text: { type: "mrkdwn", text: line ? `${text}\n${line}` : text } }] };
}

/** スレッドの詳細カード。「編集」ボタンから Slack の中で直せる */
export function taskCardMessage(o: { task_id: string; title: string; corp: string; assigneeNames: string[]; due: string; dueTime?: string | null; memo?: string | null; notes?: string | null;
  steps: { title: string; done: boolean; names?: string[]; due?: string | null; dueTime?: string | null; id?: string; canComplete?: boolean }[]; creatorName: string; urgent?: boolean; url: string }): { text: string; blocks: unknown[] } {
  // 2026-11-18 工程は期限が早い順（期限なしは最後）。画面（tasks.html の sortedSteps）と同じ並び
  const dueKey = (s: { due?: string | null; dueTime?: string | null }) => s.due ? `${s.due} ${s.dueTime ? String(s.dueTime).slice(0, 8) : "23:59:59"}` : "9999-99-99 99";
  o = { ...o, steps: o.steps.map((s, i) => ({ s, i })).sort((x, y) => { const a = dueKey(x.s), b = dueKey(y.s); return a < b ? -1 : a > b ? 1 : x.i - y.i; }).map((x) => x.s) };
  const lines = [`${o.urgent ? "🔥 " : ""}*${clean(o.title, 100)}*`, `法人：${clean(o.corp, 20)}　担当：${o.assigneeNames.map((n) => clean(n, 20)).join("・") || "—"}`, `期限：${md(o.due, o.dueTime)}　依頼：${clean(o.creatorName, 30)}`];
  if (o.memo && clean(o.memo, 300)) lines.push(`詳細：${clean(o.memo, 300)}`);
  if (o.notes && clean(o.notes, 300)) lines.push(`⚠️ 注意事項：${clean(o.notes, 300)}`);
  // 2026-11-18 工程の id が分かるとき: 工程ごとに［✅ 完了］ボタン（担当者だけが押せる。権限は DB 側 hq_slack_step_complete が判定）を出す
  const perStep = o.steps.length > 0 && o.steps.every((s) => !!s.id);
  if (!perStep && (o.steps.length > 1 || (o.steps[0] && o.steps[0].title !== "対応する"))) {
    lines.push("工程：");
    for (const s of o.steps) lines.push(`${s.done ? "✅" : "▫️"} ${clean(s.title, 40)}${s.names?.length || s.due ? `（${(s.names ?? []).map((n) => clean(n, 12)).join("・")}${s.due ? `・${md(s.due, s.dueTime)}` : ""}）` : ""}`);
  }
  const stepBlocks: unknown[] = [];
  if (perStep) {
    for (const st of o.steps.slice(0, 10)) {
      const who = `${(st.names ?? []).map((n) => clean(n, 12)).join("・")}${st.due ? `${st.names?.length ? "・" : ""}${md(st.due, st.dueTime)}` : ""}`;
      if (st.done) {
        // 2026-11-19 間違えて完了にした工程を取り消せる（確認の窓つき）
        stepBlocks.push({ type: "section", text: { type: "mrkdwn", text: `✅ ~${clean(st.title, 60)}~${who ? `　（${who}）` : ""}` },
          accessory: { type: "button", text: { type: "plain_text", text: "↩️ 取り消し", emoji: true }, action_id: STEP_REOPEN, value: JSON.stringify({ step_id: st.id }),
            confirm: { title: { type: "plain_text", text: "完了を取り消しますか？" }, text: { type: "mrkdwn", text: `「${clean(st.title, 40)}」を未完了に戻します。` }, confirm: { type: "plain_text", text: "取り消す" }, deny: { type: "plain_text", text: "やめる" } } } });
        continue;
      }
      const sec: any = { type: "section", text: { type: "mrkdwn", text: `▫️ *${clean(st.title, 60)}*${who ? `\n担当・期限：${who}` : ""}${st.canComplete === false ? "\n📷 写真などが必要な工程です（管理システムの画面で完了）" : ""}` } };
      if (st.canComplete !== false) sec.accessory = { type: "button", style: "primary", text: { type: "plain_text", text: "✅ 完了", emoji: true }, action_id: STEP_DONE, value: JSON.stringify({ step_id: st.id }) };
      stepBlocks.push(sec);
    }
  }
  return {
    text: `本部タスクの詳細：${clean(o.title, 100)}`,
    blocks: [
      { type: "section", text: { type: "mrkdwn", text: lines.join("\n") } },
      ...stepBlocks,
      { type: "actions", block_id: "hqtask_card", elements: [
        ...(perStep ? [{ type: "button", text: { type: "plain_text", text: "💬 コメント", emoji: true }, action_id: COMMENT_OPEN, value: JSON.stringify({ task_id: o.task_id }) }] : []),
        { type: "button", text: { type: "plain_text", text: "✏️ 編集", emoji: true }, action_id: EDIT_ACTION, value: JSON.stringify({ task_id: o.task_id }) },
        { type: "button", text: { type: "plain_text", text: "🧩 工程を編集", emoji: true }, action_id: STEPS_OPEN, value: JSON.stringify({ task_id: o.task_id }) },
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
export function completedBlocks(orig: any[] | undefined, by: string, at: string, stepTitle?: string | null): unknown[] {
  const head = { type: "section", text: { type: "mrkdwn", text: `✅ *${stepTitle ? `工程「${clean(stepTitle, 40)}」を` : ""}完了しました*（${clean(by, 30)}・${clean(at, 30)}）` } };
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
export function completionThreadText(o: { stepTitle?: string | null; title: string; due: string; dueTime?: string | null; creatorName?: string | null; by: string; at: string; url: string }): string {
  return [`✅ ${o.stepTitle ? `工程「${clean(o.stepTitle, 40)}」を` : ""}完了しました：*${clean(o.title, 100)}*`, `${o.creatorName ? `依頼：${clean(o.creatorName, 30)}　` : ""}期限：${md(o.due, o.dueTime)}　完了：${clean(o.by, 30)}（${clean(o.at, 30)}）`, `🔗 <${o.url}|管理システムで開く>`].join("\n");
}

export type StepRow = { id: string; title: string; due: string | null; due_time: string | null; done: boolean; photo: boolean; note: string | null; assignee_names: string[]; assignee_slack_ids: string[] };

/** 工程の一覧（モーダル）。工程ごとに「編集」。いちばん下に「＋ 工程を追加」 */
export function stepsListModal(o: { taskId: string; title: string; steps: StepRow[] }): unknown {
  const blocks: unknown[] = [{ type: "section", text: { type: "mrkdwn", text: `*${clean(o.title, 100)}*\n直したい工程の「編集」を押してください。工程ごとに、担当者・期限・写真の要否を決められます。` } }, { type: "divider" }];
  for (const s of o.steps.slice(0, 10)) {
    const text = `${s.done ? "✅" : "▫️"} *${clean(s.title, 60)}*\n担当：${s.assignee_names.map((n) => clean(n, 20)).join("・") || "—"}　期限：${s.due ? md(s.due, s.due_time) : "—"}${s.photo ? "　📷写真が必要" : ""}${s.done ? "　（完了）" : ""}`;
    const sec: any = { type: "section", text: { type: "mrkdwn", text } };
    if (!s.done) sec.accessory = { type: "button", text: { type: "plain_text", text: "編集", emoji: true }, action_id: STEP_PICK, value: JSON.stringify({ task_id: o.taskId, step_id: s.id }) };
    blocks.push(sec);
  }
  blocks.push({ type: "divider" });
  if (o.steps.length < 10) blocks.push({ type: "actions", block_id: "steps_add", elements: [{ type: "button", style: "primary", text: { type: "plain_text", text: "＋ 工程を追加", emoji: true }, action_id: STEP_ADD, value: JSON.stringify({ task_id: o.taskId }) }] });
  return { type: "modal", callback_id: STEPS_MODAL, private_metadata: JSON.stringify({ task_id: o.taskId }), title: { type: "plain_text", text: "工程の編集" }, close: { type: "plain_text", text: "閉じる" }, blocks };
}

/** 1 つの工程の編集（または追加）フォーム */
export function stepModal(o: { taskId: string; step?: StepRow | null; defaultDue?: string | null }): unknown {
  const s = o.step ?? null;
  const withInit = (el: any, key: string, val: unknown) => (val !== undefined && val !== null && val !== "" ? { ...el, [key]: val } : el);
  const photoOpt = { text: { type: "plain_text", text: "この工程の完了に写真が必要" }, value: "1" };
  const blocks: unknown[] = [
    { type: "input", block_id: "title", label: { type: "plain_text", text: "工程名" }, element: withInit({ type: "plain_text_input", action_id: "title", max_length: 80 }, "initial_value", s?.title) },
    { type: "input", block_id: "assignees", label: { type: "plain_text", text: "担当者（複数可）" }, element: withInit({ type: "multi_users_select", action_id: "assignees", placeholder: { type: "plain_text", text: "選ぶ" } }, "initial_users", s?.assignee_slack_ids?.length ? s.assignee_slack_ids : null) },
    { type: "input", block_id: "due", label: { type: "plain_text", text: "期限（日付）" }, element: withInit({ type: "datepicker", action_id: "due" }, "initial_date", s?.due ?? o.defaultDue ?? null) },
    { type: "input", block_id: "due_time", optional: true, label: { type: "plain_text", text: "期限（時刻・任意）" }, element: withInit({ type: "timepicker", action_id: "due_time", placeholder: { type: "plain_text", text: "時刻を選ぶ" } }, "initial_time", s?.due_time ? String(s.due_time).slice(0, 5) : null) },
    { type: "input", block_id: "note", optional: true, label: { type: "plain_text", text: "この工程のメモ・注意（任意）" }, element: withInit({ type: "plain_text_input", action_id: "note", multiline: true, max_length: 500 }, "initial_value", s?.note) },
    { type: "input", block_id: "photo", optional: true, label: { type: "plain_text", text: "写真" }, element: withInit({ type: "checkboxes", action_id: "photo", options: [photoOpt] }, "initial_options", s?.photo ? [photoOpt] : null) },
  ];
  if (s) blocks.push({ type: "input", block_id: "del", optional: true, label: { type: "plain_text", text: "削除" }, element: { type: "checkboxes", action_id: "del", options: [{ text: { type: "plain_text", text: "この工程を削除する（最後の 1 つは消せません）" }, value: "1" }] } });
  return { type: "modal", callback_id: STEP_MODAL, private_metadata: JSON.stringify({ task_id: o.taskId, step_id: s?.id ?? null }),
    title: { type: "plain_text", text: s ? "工程を編集" : "工程を追加" }, submit: { type: "plain_text", text: s ? "保存" : "追加" }, close: { type: "plain_text", text: "やめる" }, blocks };
}

export type StepInput = { title: string; slackAssignees: string[]; due: string; dueTime: string | null; note: string; photo: boolean; del: boolean };
// deno-lint-ignore no-explicit-any
export function parseStep(values: any): { ok: true; v: StepInput } | { ok: false; errors: Record<string, string> } {
  const g = values ?? {};
  const del = Array.isArray(g.del?.del?.selected_options) && g.del.del.selected_options.length > 0;
  const title = clean(g.title?.title?.value, 80);
  const slackAssignees: string[] = Array.isArray(g.assignees?.assignees?.selected_users) ? g.assignees.assignees.selected_users.filter((x: unknown) => /^[UW][A-Z0-9]{6,}$/.test(String(x))).slice(0, 10) : [];
  const due = String(g.due?.due?.selected_date ?? "");
  const tm = String(g.due_time?.due_time?.selected_time ?? "");
  const errors: Record<string, string> = {};
  if (!del) {
    if (!title) errors.title = "工程名を入れてください";
    if (!slackAssignees.length) errors.assignees = "担当者を選んでください";
    if (!/^\d{4}-\d{2}-\d{2}$/.test(due)) errors.due = "期限を選んでください";
  }
  if (Object.keys(errors).length) return { ok: false, errors };
  return { ok: true, v: { title, slackAssignees, due, dueTime: /^\d{2}:\d{2}$/.test(tm) ? tm : null, note: String(g.note?.note?.value ?? "").trim().slice(0, 500), photo: Array.isArray(g.photo?.photo?.selected_options) && g.photo.photo.selected_options.length > 0, del } };
}

/** タスク本体の編集（担当者・期限・工程は工程ごとに別のフォーム）の読み取り */
// deno-lint-ignore no-explicit-any
export function parseTaskEdit(values: any): { ok: true; v: { title: string; corp: string; memo: string; notes: string; urgent: boolean } } | { ok: false; errors: Record<string, string> } {
  const g = values ?? {};
  const title = clean(g.title?.title?.value, 120);
  const corp = String(g.corp?.corp?.selected_option?.value ?? "");
  const errors: Record<string, string> = {};
  if (!title) errors.title = "やることを入れてください";
  if (!(CORPS as readonly string[]).includes(corp)) errors.corp = "法人を選んでください";
  if (Object.keys(errors).length) return { ok: false, errors };
  return { ok: true, v: { title, corp, memo: String(g.memo?.memo?.value ?? "").trim().slice(0, 500), notes: String(g.notes?.notes?.value ?? "").trim().slice(0, 1000), urgent: Array.isArray(g.urgent?.urgent?.selected_options) && g.urgent.urgent.selected_options.length > 0 } };
}

// ===== 作成フォーム（工程ごとに「工程名・担当者・期限（日付＋時刻）」の枠。「＋ 工程を追加」で枠が増える） =====
export type StepForm = { title?: string; users?: string[]; due?: string | null; time?: string | null };
export type CreateForm = { title?: string; corp?: string; memo?: string; notes?: string; urgent?: boolean; photo?: boolean; steps: StepForm[] };
export const MAX_STEPS = 10;

export function createFormModal(form: CreateForm, meta: Record<string, unknown>): unknown {
  const withInit = (el: any, key: string, val: unknown) => (val !== undefined && val !== null && val !== "" ? { ...el, [key]: val } : el);
  const steps = form.steps.length ? form.steps.slice(0, MAX_STEPS) : [{}];
  const blocks: unknown[] = [
    { type: "input", block_id: "title", label: { type: "plain_text", text: "やること（タスク名）" }, element: withInit({ type: "plain_text_input", action_id: "title", max_length: 120, placeholder: { type: "plain_text", text: "例：10月分の請求書を確認する" } }, "initial_value", form.title) },
    { type: "input", block_id: "corp", label: { type: "plain_text", text: "法人" }, element: withInit({ type: "static_select", action_id: "corp", placeholder: { type: "plain_text", text: "選ぶ" }, options: CORPS.map((c) => ({ text: { type: "plain_text", text: c }, value: c })) }, "initial_option", form.corp ? { text: { type: "plain_text", text: form.corp }, value: form.corp } : null) },
    { type: "divider" },
  ];
  steps.forEach((s, i) => {
    blocks.push({ type: "section", text: { type: "mrkdwn", text: steps.length > 1 ? `*▼ 工程 ${i + 1}*` : "*▼ 工程*（1 つだけなら、工程名は空でも作れます）" } });
    blocks.push({ type: "input", block_id: `s${i}_title`, optional: steps.length === 1, label: { type: "plain_text", text: "工程名" }, element: withInit({ type: "plain_text_input", action_id: `s${i}_title`, max_length: 80, placeholder: { type: "plain_text", text: "例：資料を集める" } }, "initial_value", s.title) });
    blocks.push({ type: "input", block_id: `s${i}_users`, label: { type: "plain_text", text: "担当者（複数可）" }, element: withInit({ type: "multi_users_select", action_id: `s${i}_users`, placeholder: { type: "plain_text", text: "選ぶ" } }, "initial_users", s.users?.length ? s.users : null) });
    blocks.push({ type: "input", block_id: `s${i}_due`, label: { type: "plain_text", text: "期限（日付）" }, element: withInit({ type: "datepicker", action_id: `s${i}_due` }, "initial_date", s.due) });
    blocks.push({ type: "input", block_id: `s${i}_time`, optional: true, label: { type: "plain_text", text: "期限（時刻・任意）" }, element: withInit({ type: "timepicker", action_id: `s${i}_time`, placeholder: { type: "plain_text", text: "時刻を選ぶ" } }, "initial_time", s.time ? String(s.time).slice(0, 5) : null) });
  });
  const btns: unknown[] = [];
  if (steps.length < MAX_STEPS) btns.push({ type: "button", style: "primary", text: { type: "plain_text", text: "＋ 工程を追加", emoji: true }, action_id: FORM_ADD, value: "{}" });
  if (steps.length > 1) btns.push({ type: "button", text: { type: "plain_text", text: "－ 最後の工程を消す", emoji: true }, action_id: FORM_DEL, value: "{}" });
  if (btns.length) blocks.push({ type: "actions", block_id: "form_steps", elements: btns });
  const photoOpt = { text: { type: "plain_text", text: "各工程の完了に写真が必要" }, value: "1" };
  const urgentOpt = { text: { type: "plain_text", text: "最重要のタスクにする" }, value: "1" };
  blocks.push(
    { type: "divider" },
    { type: "section", text: { type: "mrkdwn", text: "*▼ 詳細（すべて任意）*" } },
    { type: "input", block_id: "memo", optional: true, label: { type: "plain_text", text: "詳細" }, element: withInit({ type: "plain_text_input", action_id: "memo", multiline: true, max_length: 500 }, "initial_value", form.memo) },
    { type: "input", block_id: "notes", optional: true, label: { type: "plain_text", text: "注意事項" }, element: withInit({ type: "plain_text_input", action_id: "notes", multiline: true, max_length: 1000, placeholder: { type: "plain_text", text: "担当者に必ず守ってほしいこと" } }, "initial_value", form.notes) },
    { type: "input", block_id: "photo", optional: true, label: { type: "plain_text", text: "写真" }, element: withInit({ type: "checkboxes", action_id: "photo", options: [photoOpt] }, "initial_options", form.photo ? [photoOpt] : null) },
    { type: "input", block_id: "urgent", optional: true, label: { type: "plain_text", text: "最重要" }, element: withInit({ type: "checkboxes", action_id: "urgent", options: [urgentOpt] }, "initial_options", form.urgent ? [urgentOpt] : null) },
  );
  return { type: "modal", callback_id: CREATE_MODAL, private_metadata: JSON.stringify(meta), title: { type: "plain_text", text: "本部タスクを作る" }, submit: { type: "plain_text", text: "作成" }, close: { type: "plain_text", text: "やめる" }, blocks };
}

/** いまの入力（view.state.values）をそのまま読む（入力のチェックはしない）。「＋ 工程を追加」で作り直すとき、入力済みの内容を残すために使う */
// deno-lint-ignore no-explicit-any
export function readForm(values: any): CreateForm {
  const g = values ?? {};
  const steps: StepForm[] = [];
  for (let i = 0; i < MAX_STEPS && (g[`s${i}_users`] || g[`s${i}_title`] || g[`s${i}_due`]); i++) {
    steps.push({ title: g[`s${i}_title`]?.[`s${i}_title`]?.value ?? "", users: g[`s${i}_users`]?.[`s${i}_users`]?.selected_users ?? [], due: g[`s${i}_due`]?.[`s${i}_due`]?.selected_date ?? null, time: g[`s${i}_time`]?.[`s${i}_time`]?.selected_time ?? null });
  }
  return { title: g.title?.title?.value ?? "", corp: g.corp?.corp?.selected_option?.value ?? "", memo: g.memo?.memo?.value ?? "", notes: g.notes?.notes?.value ?? "",
    urgent: Array.isArray(g.urgent?.urgent?.selected_options) && g.urgent.urgent.selected_options.length > 0, photo: Array.isArray(g.photo?.photo?.selected_options) && g.photo.photo.selected_options.length > 0, steps: steps.length ? steps : [{}] };
}

export type CreateStepsInput = { title: string; corp: string; memo: string; notes: string; urgent: boolean; photo: boolean; steps: { title: string; slackUsers: string[]; due: string; time: string | null }[] };
/** 送信の読み取り（チェックつき）。工程が 2 つ以上のときは、すべての工程名が必要 */
// deno-lint-ignore no-explicit-any
export function parseCreateSteps(values: any): { ok: true; v: CreateStepsInput } | { ok: false; errors: Record<string, string> } {
  const f = readForm(values);
  const errors: Record<string, string> = {};
  const title = clean(f.title, 120);
  if (!title) errors.title = "やること（タスク名）を入れてください";
  if (!(CORPS as readonly string[]).includes(String(f.corp))) errors.corp = "法人を選んでください";
  const steps = f.steps.map((s, i) => {
    const users = (s.users ?? []).filter((x) => /^[UW][A-Z0-9]{6,}$/.test(String(x))).slice(0, 10);
    if (!users.length) errors[`s${i}_users`] = "担当者を選んでください";
    if (!/^\d{4}-\d{2}-\d{2}$/.test(String(s.due ?? ""))) errors[`s${i}_due`] = "期限を選んでください";
    const st = clean(s.title, 80);
    if (f.steps.length > 1 && !st) errors[`s${i}_title`] = "工程名を入れてください";
    return { title: st, slackUsers: users, due: String(s.due ?? ""), time: /^\d{2}:\d{2}$/.test(String(s.time ?? "")) ? String(s.time) : null };
  });
  if (Object.keys(errors).length) return { ok: false, errors };
  return { ok: true, v: { title, corp: String(f.corp), memo: String(f.memo ?? "").trim().slice(0, 500), notes: String(f.notes ?? "").trim().slice(0, 1000), urgent: !!f.urgent, photo: !!f.photo, steps } };
}

export type MyStep = { step_id: string; title: string; due: string; dueTime?: string | null; done?: boolean; canComplete: boolean };

/** 担当者への割り当て DM。自分の工程を 1 つずつ並べ、工程ごとに「✅ 完了」ボタンを付ける（工程 1 を終えても、工程 2 を完了する場所がある） */
export function assignedStepsMessage(o: { title: string; creatorName: string; memo?: string | null; notes?: string | null; url: string; steps: MyStep[]; taskId?: string; parent?: ParentRef | null }): { text: string; blocks: unknown[] } {
  const head = [`📌 *新しい本部タスクが割り当てられました*`, `*${clean(o.title, 100)}*`, `依頼：${clean(o.creatorName, 30)}`];
  if (o.memo && clean(o.memo, 300)) head.push(`詳細：${clean(o.memo, 300)}`);
  if (o.notes && clean(o.notes, 300)) head.push(`⚠️ 注意事項：${clean(o.notes, 300)}`);
  head.push(`🔗 <${o.url}|管理システムで開く>`);
  { const pl = parentLine(o.parent); if (pl) head.push(pl); }
  const blocks: unknown[] = [{ type: "section", text: { type: "mrkdwn", text: head.join("\n") } }, { type: "divider" }];
  for (const s of o.steps.slice(0, 10)) {
    const sec: any = { type: "section", text: { type: "mrkdwn", text: `▫️ *${clean(s.title, 60)}*\n期限：${md(s.due, s.dueTime)}${s.canComplete ? "" : "　📷写真が必要（管理システムの画面で完了）"}` } };
    if (s.canComplete) sec.accessory = { type: "button", style: "primary", text: { type: "plain_text", text: "✅ 完了", emoji: true }, action_id: STEP_DONE, value: JSON.stringify({ step_id: s.step_id }) };
    blocks.push(sec);
  }
  blocks.push({ type: "actions", block_id: "hqtask_link", elements: [...commentBtn(o.taskId), { type: "button", text: { type: "plain_text", text: "管理システムで開く", emoji: true }, url: o.url, action_id: STEP_LINK }] });
  return { text: `📌 新しい本部タスク：${clean(o.title, 100)}`, blocks };
}

/** 工程ごとの完了ボタンのあるメッセージで、押された工程だけを「✅ 完了」にする。ほかの工程のボタンは残す。全部完了したら先頭に印 */
// deno-lint-ignore no-explicit-any
export function markStepDone(orig: any[] | undefined, stepId: string, by: string, at: string): { blocks: unknown[]; allDone: boolean } | null {
  let hit = false; let remaining = 0;
  const out: unknown[] = [];
  for (const b of orig ?? []) {
    if (b?.type === "section" && b.accessory?.action_id === STEP_DONE) {
      let v: any = null; try { v = JSON.parse(b.accessory.value ?? "null"); } catch { v = null; }
      if (v?.step_id === stepId) {
        hit = true;
        const title = String(b.text?.text ?? "").split("\n")[0].replace(/^▫️\s*/, "").replace(/\*/g, "");
        out.push({ type: "section", text: { type: "mrkdwn", text: `✅ ~${clean(title, 60)}~　完了（${clean(by, 30)}・${clean(at, 30)}）` } });
        continue;
      }
      remaining++;
    }
    out.push(b?.type === "section" ? (b.accessory ? { type: "section", text: b.text, accessory: b.accessory } : { type: "section", text: b.text }) : b);
  }
  if (!hit) return null;
  const allDone = remaining === 0;
  if (allDone) out.unshift({ type: "section", text: { type: "mrkdwn", text: "🎉 *あなたの工程は、すべて完了しました*" } });
  return { blocks: out, allDone };
}

/** チャンネルのカードの［💬 コメント］で開く入力窓（送信するとタスクのコメントに入る。@名前 を書くとその人に通知） */
export function commentModal(o: { taskId: string; title: string; withFiles?: boolean }): unknown {
  return {
    type: "modal", callback_id: COMMENT_MODAL, private_metadata: JSON.stringify({ task_id: o.taskId }),
    title: { type: "plain_text", text: "コメントを入れる" }, submit: { type: "plain_text", text: "送信" }, close: { type: "plain_text", text: "閉じる" },
    blocks: [
      { type: "section", text: { type: "mrkdwn", text: `*${clean(o.title, 100)}*` } },
      { type: "input", block_id: "body", label: { type: "plain_text", text: "コメント" }, element: { type: "plain_text_input", action_id: "body", multiline: true, max_length: 1500 } },
      // 2026-11-19 相手は文字で書かずに「選ぶ」だけ（選んだ人の名前を、管理システムの名前で「@名前」としてコメントの頭に付ける。書き間違いでメンションが外れない）
      { type: "input", block_id: "mentions", optional: true, label: { type: "plain_text", text: "相手に知らせる（選ぶだけ・複数可）" }, element: { type: "multi_users_select", action_id: "mentions", placeholder: { type: "plain_text", text: "知らせたい人を選ぶ" } } },
      // 添付（写真・PDF）。Slack アプリに files:read の権限があるときだけ出す
      ...(o.withFiles ? [{ type: "input", block_id: "files", optional: true, label: { type: "plain_text", text: "添付（写真・PDF・5 つまで）" }, element: { type: "file_input", action_id: "files", max_files: 5, filetypes: ["jpg", "jpeg", "png", "gif", "heic", "pdf"] } }] : []),
    ],
  };
}

/** 次の担当者への通知（2026-11-19）。1 人に 1 通へまとめる。items＝その人の「次の番」の一覧（hq_slack_next_candidates の行）。短く・何が止まっていて・自分の工程がどれか・を出す */
export type NextItem = { kind: string; task_title: string; step_title: string; step_due: string | null; days_over: number; prev_title: string | null; prev_names: string | null; url: string; task_id?: string; parent_url?: string | null; parent_channel?: string | null };
export function nextNoticeMessage(items: NextItem[]): { text: string; blocks: unknown[] } {
  const line = (x: NextItem) => {
    const prev = `「${clean(x.prev_title, 30)}」${x.prev_names ? `（${clean(x.prev_names, 20)}）` : ""}`;
    const mine = `あなたの「${clean(x.step_title, 30)}」${x.step_due ? `（期限 ${md(x.step_due)}）` : ""}は、その次です。`;
    const head = x.kind === "next_ready" ? `前の工程${prev}が完了しました。あなたの番です：「${clean(x.step_title, 30)}」${x.step_due ? `（期限 ${md(x.step_due)}）` : ""}`
      : x.kind === "next_today" ? `前の工程${prev}が、今日が期限です（まだ完了していません）。${mine}`
      : `前の工程${prev}が、期限を ${Math.max(1, x.days_over)} 日過ぎています。${mine}`;
    return `• *${clean(x.task_title, 50)}*\n　${head}　<${x.url}|開く>${x.parent_url ? `　${parentLine({ url: x.parent_url, channel: x.parent_channel })}` : ""}`;
  };
  const shown = items.slice(0, 5);
  const allReady = items.every((x) => x.kind === "next_ready");
  const title = allReady ? "あなたの番になった工程があります" : "前の工程が止まっています（次はあなたの工程）";
  const text = `${allReady ? "▶" : "⏳"} *${title}*\n${shown.map(line).join("\n")}${items.length > shown.length ? `\nほか ${items.length - shown.length} 件` : ""}`;
  const blocks: unknown[] = [{ type: "section", text: { type: "mrkdwn", text } }];
  // 1 件だけのときは、そのまま［💬 コメント］を押せる（複数件のときは、親投稿のリンクから）
  if (items.length === 1 && items[0].task_id) blocks.push({ type: "actions", block_id: "hqtask_next", elements: commentBtn(items[0].task_id) });
  return { text: `${title}（${items.length} 件）`, blocks };
}
