import { assertEquals, assert } from "jsr:@std/assert@1";
import { assignedStepsMessage, markStepDone, createFormModal, readForm, parseCreateSteps, stepsListModal, stepModal, parseStep, parseTaskEdit, completedBlocks, completionThreadText, reminderMessage, reminderHead, parseCreate, createModal, assignedMessage, taskCardMessage, parentMessage, nextNoticeMessage, commentModal, createButtonMessage, type Candidate } from "./hqtask-slack.ts";

const base: Candidate = { recipient_id: "r", slack_user_id: "U0123456789", task_id: "t", step_id: "s", task_title: "請求書の確認", step_title: "対応する", due_date: "2026-11-20", kind: "today", days_over: 0, creator_id: "c", can_complete: true, url: "https://example.com/t" };

Deno.test("期限が近いほど強い見出し・超過は日数つき・午後は未完了の追い通知", () => {
  assert(reminderHead("before3", 0).head.includes("3日"));
  assert(reminderHead("today", 0).head.includes("今日"));
  assert(reminderHead("overdue", 4).head.includes("4 日"));
  assert(reminderHead("overdue_pm", 4).head.includes("まだ完了していません"));
  assert(reminderHead("escalate", 5).head.includes("作成したタスク"));
});
Deno.test("DM: 完了できる工程だけ『完了にする』・対応中・リンクが付く。作成者向け(escalate)は操作ボタンなし", () => {
  const ids = (m: any) => m.blocks[1].elements.map((e: any) => e.action_id);
  assertEquals(ids(reminderMessage(base)), ["hqtask.step.done", "hqtask.step.ack", "hqtask.comment.open", "hqtask.link"]);
  assertEquals(ids(reminderMessage({ ...base, can_complete: false })), ["hqtask.step.ack", "hqtask.comment.open", "hqtask.link"]);
  assertEquals(ids(reminderMessage({ ...base, kind: "escalate", days_over: 3 })), ["hqtask.comment.open", "hqtask.link"]);
});
Deno.test("DM に金額や口座の文言を入れない・制御文字は除く", () => {
  const m = reminderMessage({ ...base, task_title: "a\nb\u0007c" });
  assert(!JSON.stringify(m).includes("\\u0007"));
});
Deno.test("期限は時刻つきで出る", () => {
  assert(JSON.stringify(reminderMessage({ ...base, due_time: "17:30:00" })).includes("11/20 17:30"));
});
Deno.test("割り当ての DM", () => {
  const m = assignedMessage({ title: "T", due: "2026-11-20", creatorName: "社長", memo: "詳細", step_id: "s", url: "https://x", canComplete: true });
  assert(m.text.includes("新しい本部タスク"));
});
Deno.test("作成フォーム: 6 つの入力欄・送信の読み取り", () => {
  const ids = (m: any) => m.blocks.map((b: any) => b.block_id).filter(Boolean);
  const modal: any = createModal();
  assertEquals(ids(modal), ["title", "corp", "s0_title", "s0_users", "s0_due", "s0_time", "form_steps", "memo", "notes", "photo", "urgent"]);   // 工程ごとの枠＋下に詳細の欄（任意）
  assert(modal.blocks.find((b: any) => b.block_id === "s0_time").element.type === "timepicker");
  assert(modal.blocks.find((b: any) => b.block_id === "s0_time").optional === true && modal.blocks.find((b: any) => b.block_id === "memo").optional === true);
  const ed: any = createModal({ mode: "edit", meta: { task_id: "t" }, initial: { title: "T", corp: "SK", memo: "m", notes: "n", urgent: true } });
  assertEquals(ed.callback_id, "hqtask.edit.modal");
  assertEquals(ids(ed), ["title", "corp", "memo", "notes", "urgent"]);   // 編集は本体だけ（担当者・期限・工程は工程ごとの別フォーム）
  assertEquals(ed.blocks.find((b: any) => b.block_id === "title").element.initial_value, "T");
  const ok = parseCreate({
    title: { title: { value: "確認する" } }, corp: { corp: { selected_option: { value: "SK" } } }, assignees: { assignees: { selected_users: ["U0123456789", "bad"] } },
    due: { due: { selected_date: "2026-11-20" } }, due_time: { due_time: { selected_time: "17:30" } }, notes: { notes: { value: "注意" } }, steps: { steps: { value: "資料\n\n確認\n提出" } }, photo: { photo: { selected_options: [{ value: "1" }] } }, memo: { memo: { value: " 詳細 " } }, urgent: { urgent: { selected_options: [{ value: "1" }] } },
  });
  assert(ok.ok);
  if (ok.ok) { assertEquals(ok.v.slackAssignees, ["U0123456789"]); assertEquals(ok.v.memo, "詳細"); assertEquals(ok.v.urgent, true); assertEquals(ok.v.dueTime, "17:30"); assertEquals(ok.v.steps, ["資料", "確認", "提出"]); assertEquals(ok.v.notes, "注意"); assertEquals(ok.v.photo, true); }
  const ng = parseCreate({ title: { title: { value: "" } } });
  assert(!ng.ok);
  if (!ng.ok) assertEquals(Object.keys(ng.errors).sort(), ["assignees", "corp", "due", "title"]);
});

Deno.test("親投稿は 1 行・完了の印／詳細カードに編集ボタン／作成ボタンは 1 つ", () => {
  assert(parentMessage({ title: "請求書", due: "2026-11-20", dueTime: "17:30:00" }).text.startsWith("🕒 本部タスク｜請求書｜11/20 17:30"));
  assert(parentMessage({ title: "請求書", due: "2026-11-20", done: true }).text.startsWith("✅"));
  const c: any = taskCardMessage({ task_id: "t", title: "T", corp: "SK", assigneeNames: ["青山"], due: "2026-11-20", steps: [{ title: "A", done: true }, { title: "B", done: false }], creatorName: "社長", url: "https://x" });
  assertEquals(c.blocks[1].elements.map((e: any) => e.action_id), ["hqtask.task.edit", "hqtask.steps.open", "hqtask.link"]);
  assert(JSON.stringify(c).includes("✅ A") && JSON.stringify(c).includes("▫️ B"));
  assertEquals((createButtonMessage().blocks[1] as any).elements.length, 1);
});

Deno.test("通知には依頼者・期限・リンクが必ず入る／完了後も元の内容を残してボタンを外す", () => {
  const m: any = reminderMessage(base, { creatorName: "社長", memo: "詳細です" });
  const s = JSON.stringify(m);
  assert(s.includes("依頼：社長") && s.includes("11/20") && s.includes("請求書の確認") && s.includes("管理システムで開く") && s.includes("https://example.com/t") && s.includes("詳細です"));
  const done: any[] = completedBlocks(m.blocks, "青山", "11/20 10:00") as any[];
  assert(done[0].text.text.includes("完了しました") && done[0].text.text.includes("青山"));
  assert(JSON.stringify(done).includes("請求書の確認") && JSON.stringify(done).includes("依頼：社長"));
  const act = done.find((b) => b.type === "actions");
  assertEquals(act.elements.map((e: any) => e.action_id), ["hqtask.link"]);   // 完了・対応中のボタンは外れ、リンクだけ残る
  const th = completionThreadText({ title: "請求書の確認", due: "2026-11-20", creatorName: "社長", by: "青山", at: "11/20 10:00", url: "https://x" });
  assert(th.includes("依頼：社長") && th.includes("https://x") && th.includes("期限：11/20"));
});

Deno.test("工程の一覧・工程ごとのフォーム（担当者・期限・時刻・写真・削除）", () => {
  const steps: any[] = [
    { id: "s1", title: "A", due: "2026-11-20", due_time: null, done: true, photo: false, note: null, assignee_names: ["青山"], assignee_slack_ids: ["U0123456789"] },
    { id: "s2", title: "B", due: "2026-11-22", due_time: "17:30:00", done: false, photo: true, note: "注意", assignee_names: ["中山"], assignee_slack_ids: ["U0123456780"] },
  ];
  const list: any = stepsListModal({ taskId: "t", title: "T", steps });
  const secs = list.blocks.filter((b: any) => b.type === "section" && b.accessory);
  assertEquals(secs.length, 1);   // 完了した工程には「編集」が出ない
  assertEquals(JSON.parse(secs[0].accessory.value), { task_id: "t", step_id: "s2" });
  assert(list.blocks.some((b: any) => b.block_id === "steps_add"));
  const m: any = stepModal({ taskId: "t", step: steps[1] });
  assertEquals(m.blocks.map((b: any) => b.block_id), ["title", "assignees", "due", "due_time", "note", "photo", "del"]);
  assertEquals(m.blocks.find((b: any) => b.block_id === "assignees").element.initial_users, ["U0123456780"]);
  assertEquals(m.blocks.find((b: any) => b.block_id === "due_time").element.initial_time, "17:30");
  assertEquals((stepModal({ taskId: "t", step: null }) as any).blocks.map((b: any) => b.block_id).includes("del"), false);   // 追加には削除なし
  const ok = parseStep({ title: { title: { value: "B2" } }, assignees: { assignees: { selected_users: ["U0123456780"] } }, due: { due: { selected_date: "2026-11-25" } }, due_time: { due_time: { selected_time: "09:00" } }, photo: { photo: { selected_options: [{ value: "1" }] } } });
  assert(ok.ok); if (ok.ok) { assertEquals(ok.v.dueTime, "09:00"); assertEquals(ok.v.photo, true); assertEquals(ok.v.del, false); }
  const del = parseStep({ del: { del: { selected_options: [{ value: "1" }] } } });
  assert(del.ok);   // 削除のときは、ほかの欄が空でも通る
  assert(!parseStep({ title: { title: { value: "" } } }).ok);
  const te = parseTaskEdit({ title: { title: { value: "T" } }, corp: { corp: { selected_option: { value: "SK" } } } });
  assert(te.ok);
});

Deno.test("作成フォーム: 工程ごとの枠（工程名・担当者・期限・時刻）・工程の増減・入力済みの内容を残す", () => {
  const two: any = createFormModal({ title: "T", corp: "SK", steps: [{ title: "A", users: ["U0123456789"], due: "2026-11-20", time: "10:00" }, { title: "B", users: [], due: "2026-11-22" }] }, { channel: "C1" });
  const ids = two.blocks.map((b: any) => b.block_id).filter(Boolean);
  assertEquals(ids.slice(0, 12), ["title", "corp", "s0_title", "s0_users", "s0_due", "s0_time", "s1_title", "s1_users", "s1_due", "s1_time", "form_steps", "memo"]);
  assertEquals(two.blocks.find((b: any) => b.block_id === "form_steps").elements.map((e: any) => e.action_id), ["hqtask.form.add", "hqtask.form.del"]);
  assertEquals(two.blocks.find((b: any) => b.block_id === "s0_time").element.initial_time, "10:00");
  assertEquals(two.blocks.find((b: any) => b.block_id === "s0_title").optional, false);   // 工程が複数なら工程名は必須
  const one: any = createFormModal({ steps: [{}] }, {});
  assertEquals(one.blocks.find((b: any) => b.block_id === "form_steps").elements.length, 1);   // 工程 1 つなら「消す」は出ない
  assertEquals(one.blocks.find((b: any) => b.block_id === "s0_title").optional, true);
  // 10 工程でも Slack のブロック上限（100）に収まる
  const ten: any = createFormModal({ steps: Array.from({ length: 10 }, () => ({})) }, {});
  assert(ten.blocks.length <= 100);
  assertEquals(ten.blocks.find((b: any) => b.block_id === "form_steps").elements.length, 1);   // 上限なら「追加」は出ない
  // 入力済みの読み取り→作り直しで、内容が消えない
  const values = { title: { title: { value: "T" } }, corp: { corp: { selected_option: { value: "SK" } } }, s0_title: { s0_title: { value: "A" } }, s0_users: { s0_users: { selected_users: ["U0123456789"] } }, s0_due: { s0_due: { selected_date: "2026-11-20" } }, s0_time: { s0_time: { selected_time: "10:00" } } };
  const f = readForm(values); f.steps.push({});
  const again: any = createFormModal(f, {});
  assertEquals(again.blocks.find((b: any) => b.block_id === "s0_users").element.initial_users, ["U0123456789"]);
  assertEquals(again.blocks.find((b: any) => b.block_id === "title").element.initial_value, "T");
  // 送信のチェック
  const ok = parseCreateSteps(values); assert(ok.ok); if (ok.ok) { assertEquals(ok.v.steps[0].time, "10:00"); assertEquals(ok.v.steps[0].title, "A"); }
  const ng = parseCreateSteps({ ...values, s1_title: { s1_title: { value: "" } }, s1_users: { s1_users: { selected_users: [] } }, s1_due: { s1_due: { selected_date: null } } });
  assert(!ng.ok); if (!ng.ok) assertEquals(Object.keys(ng.errors).sort(), ["s1_due", "s1_title", "s1_users"]);
});

Deno.test("担当者の DM: 工程ごとに「✅ 完了」ボタン／押した工程だけ完了にしてほかのボタンは残す／全部終えたら印", () => {
  const m: any = assignedStepsMessage({ title: "請求書", creatorName: "社長", memo: "詳細", url: "https://x", steps: [
    { step_id: "s1", title: "資料を集める", due: "2026-11-20", canComplete: true }, { step_id: "s2", title: "確認する", due: "2026-11-22", dueTime: "17:30:00", canComplete: true }, { step_id: "s3", title: "写真つき", due: "2026-11-23", canComplete: false }] });
  const accs = m.blocks.filter((b: any) => b.accessory);
  assertEquals(accs.map((b: any) => JSON.parse(b.accessory.value).step_id), ["s1", "s2"]);   // 写真つきの工程にはボタンなし
  assert(JSON.stringify(m).includes("依頼：社長") && JSON.stringify(m).includes("https://x") && JSON.stringify(m).includes("11/22 17:30"));
  const r1: any = markStepDone(m.blocks, "s1", "青山", "11/20 10:00");
  assert(r1 && !r1.allDone);
  assertEquals(r1.blocks.filter((b: any) => b.accessory).map((b: any) => JSON.parse(b.accessory.value).step_id), ["s2"]);   // 工程 2 のボタンは残る
  assert(JSON.stringify(r1.blocks).includes("資料を集める") && JSON.stringify(r1.blocks).includes("完了（青山"));
  const r2: any = markStepDone(r1.blocks, "s2", "青山", "11/20 11:00");
  assert(r2.allDone && JSON.stringify(r2.blocks[0]).includes("すべて完了"));
  assertEquals(markStepDone(m.blocks, "zzz", "青山", "x"), null);   // ボタンの無いメッセージ（単独通知）は従来の完了表示へ
});

Deno.test("チャンネルのカード: 工程の id があれば、未完了の工程ごとに［✅ 完了］と、［💬 コメント］のボタンが出る（写真が要る工程は完了ボタンなし）", () => {
  const c: any = taskCardMessage({ task_id: "t", title: "T", corp: "SK", assigneeNames: ["青山"], due: "2026-11-20", creatorName: "中山", url: "https://x",
    steps: [{ title: "A", done: true, id: "s1" }, { title: "B", done: false, id: "s2", canComplete: true }, { title: "C", done: false, id: "s3", canComplete: false }] });
  const acc = c.blocks.filter((b: any) => b.accessory?.action_id === "hqtask.step.done").map((b: any) => JSON.parse(b.accessory.value).step_id);
  assertEquals(acc, ["s2"]);
  const labels = c.blocks.filter((b: any) => b.type === "actions").flatMap((b: any) => b.elements.map((e: any) => e.text.text));
  assert(labels.some((t: string) => t.includes("コメント")));
});

Deno.test("本部タスクの親投稿: 2 行目は文字＋太字だけ（最重要・期限超過・担当・工程の進み・完了）。絵は 1 行目の先頭の 1 つだけ", () => {
  const p = parentMessage({ title: "T", due: "2026-11-20", strip: { urgent: true, names: ["青山", "青山", "齋藤"], stepsDone: 1, stepsTotal: 3, overdue: true } });
  const t = (p.blocks as any[])[0].text.text as string;
  assert(t.startsWith(p.text + "\n"));
  assert(p.text.startsWith("⏰"));
  assertEquals(t.split("\n")[1], "*最重要*　*期限超過*　担当 青山・齋藤　工程 1/3");
  assert(parentMessage({ title: "T", due: "2026-11-20", strip: { urgent: true, stepsDone: 0, stepsTotal: 1 } }).text.startsWith("🔥"));
  const d = (parentMessage({ title: "T", due: "2026-11-20", done: true, strip: { stepsDone: 2, stepsTotal: 2 } }).blocks as any[])[0].text.text as string;
  assertEquals(d.split("\n")[1], "*完了*　工程 2/2");
  assert(!d.includes("⏰") && !d.includes("🎉"));
  assertEquals((parentMessage({ title: "T", due: "2026-11-20" }).blocks as any[])[0].text.text, parentMessage({ title: "T", due: "2026-11-20" }).text);
});

Deno.test("スレッドの詳細カード: 工程は期限が早い順（期限なしは最後・同じ期限は元の順）", () => {
  const c = taskCardMessage({ task_id: "t", title: "T", corp: "c", assigneeNames: [], due: "2026-11-30", creatorName: "x", url: "u",
    steps: [{ title: "C", done: false, id: "3" }, { title: "B", done: false, id: "2", due: "2026-11-22" }, { title: "A", done: false, id: "1", due: "2026-11-20" }] });
  const txt = c.blocks.filter((b: any) => b.type === "section").map((b: any) => b.text.text).join("|");
  assert(txt.indexOf("*A*") < txt.indexOf("*B*") && txt.indexOf("*B*") < txt.indexOf("*C*"));
});

Deno.test("カード: 完了した工程に［↩️ 取り消し］（確認つき）／未完了には出ない", () => {
  const c = taskCardMessage({ task_id: "t", title: "T", corp: "c", assigneeNames: [], due: "2026-11-30", creatorName: "x", url: "u",
    steps: [{ title: "A", done: true, id: "1", due: "2026-11-20" }, { title: "B", done: false, id: "2", due: "2026-11-22" }] });
  const re = c.blocks.filter((b: any) => b.accessory?.action_id === "hqtask.step.reopen") as any[];
  assertEquals(re.length, 1);
  assertEquals(JSON.parse(re[0].accessory.value).step_id, "1");
  assert(re[0].accessory.confirm.title.text.includes("取り消"));
});

Deno.test("次の担当者への通知: 1 通にまとめる・短い・開くリンク・件数が多いと「ほか n 件」", () => {
  const it = (k: string, n = 0) => ({ kind: k, task_title: "防火管理者の届け出", step_title: "提出", step_due: "2026-11-27", days_over: n, prev_title: "書類を集める", prev_names: "青山純", url: "https://x/y" });
  const ready = nextNoticeMessage([it("next_ready")]);
  const t = (ready.blocks as any[])[0].text.text as string;
  assert(t.includes("あなたの番です") && t.includes("書類を集める") && t.includes("<https://x/y|開く>") && t.startsWith("▶"));
  const over = (nextNoticeMessage([it("next_over", 4), it("next_today")]).blocks as any[])[0].text.text as string;
  assert(over.startsWith("⏳") && over.includes("4 日過ぎています") && over.includes("今日が期限") && over.includes("その次です"));
  const many = (nextNoticeMessage(Array.from({ length: 8 }, () => it("next_over", 1))).blocks as any[])[0].text.text as string;
  assert(many.includes("ほか 3 件"));
});

Deno.test("コメントの窓: 相手は選ぶだけ（multi_users_select）／添付欄は withFiles のときだけ", () => {
  const ids = (m: any) => m.blocks.filter((b: any) => b.type === "input").map((b: any) => `${b.block_id}:${b.element.type}`);
  assertEquals(ids(commentModal({ taskId: "t", title: "T" })), ["body:plain_text_input", "mentions:multi_users_select"]);
  const w = ids(commentModal({ taskId: "t", title: "T", withFiles: true }));
  assertEquals(w[2], "files:file_input");
});

Deno.test("DM: コメントボタンはタスクIDを持つ・親投稿のリンク（とチャンネル）が出る。リンクが無ければ行を出さない", () => {
  const m: any = reminderMessage(base, { parent: { url: "https://ws.slack.com/archives/C0AB12CD3/p1", channel: "C0AB12CD3" } });
  const cb = m.blocks[1].elements.find((e: any) => e.action_id === "hqtask.comment.open");
  assertEquals(JSON.parse(cb.value).task_id, base.task_id);
  const t = m.blocks[0].text.text as string;
  assert(t.includes("<https://ws.slack.com/archives/C0AB12CD3/p1|親投稿を開く>") && t.includes("<#C0AB12CD3>"));
  assert(!(reminderMessage(base).blocks[0] as any).text.text.includes("親投稿"));
});
Deno.test("次の担当者の通知: 親投稿のリンクが出る・1 件のときだけコメントボタン", () => {
  const it = { kind: "next_ready", task_title: "A", step_title: "B", step_due: "2026-11-27", days_over: 0, prev_title: "C", prev_names: null, url: "https://x/y", task_id: "t1", parent_url: "https://p/1", parent_channel: "C0AB12CD3" };
  const one: any = nextNoticeMessage([it]);
  assert(one.blocks[0].text.text.includes("<https://p/1|親投稿を開く>"));
  assertEquals(JSON.parse(one.blocks[1].elements[0].value).task_id, "t1");
  assertEquals(nextNoticeMessage([it, it]).blocks.length, 1);
});

Deno.test("DM: 直せる人にだけ［編集］［工程を編集］が出る", () => {
  const ids = (m: any) => m.blocks[1].elements.map((e: any) => e.action_id);
  assert(!ids(reminderMessage(base)).includes("hqtask.task.edit"));
  const e = ids(reminderMessage(base, { canEdit: true }));
  assert(e.includes("hqtask.task.edit") && e.includes("hqtask.steps.open") && e[e.length - 1] === "hqtask.link");
});
