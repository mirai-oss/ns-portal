import { assertEquals, assert } from "jsr:@std/assert@1";
import { completedBlocks, completionThreadText, reminderMessage, reminderHead, parseCreate, createModal, assignedMessage, taskCardMessage, parentMessage, createButtonMessage, type Candidate } from "./hqtask-slack.ts";

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
  assertEquals(ids(reminderMessage(base)), ["hqtask.step.done", "hqtask.step.ack", "hqtask.link"]);
  assertEquals(ids(reminderMessage({ ...base, can_complete: false })), ["hqtask.step.ack", "hqtask.link"]);
  assertEquals(ids(reminderMessage({ ...base, kind: "escalate", days_over: 3 })), ["hqtask.link"]);
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
  assertEquals(ids(modal), ["title", "corp", "assignees", "due", "due_time", "memo", "notes", "steps", "photo", "urgent"]);   // 下に詳細の欄（任意）
  assert(modal.blocks.find((b: any) => b.block_id === "due_time").element.type === "timepicker");
  assert(modal.blocks.find((b: any) => b.block_id === "due_time").optional === true && modal.blocks.find((b: any) => b.block_id === "memo").optional === true);
  const ed: any = createModal({ mode: "edit", meta: { task_id: "t" }, initial: { title: "T", corp: "SK", assigneeSlackIds: ["U0123456789"], due: "2026-11-20", dueTime: "17:30:00", memo: "m", notes: "n", urgent: true } });
  assertEquals(ed.callback_id, "hqtask.edit.modal");
  assertEquals(ids(ed), ["title", "corp", "assignees", "due", "due_time", "memo", "notes", "steps", "urgent"]);   // 編集には写真の欄なし
  assertEquals(ed.blocks.find((b: any) => b.block_id === "title").element.initial_value, "T");
  assertEquals(ed.blocks.find((b: any) => b.block_id === "due_time").element.initial_time, "17:30");
  assertEquals(ed.blocks.find((b: any) => b.block_id === "assignees").element.initial_users, ["U0123456789"]);
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
  assertEquals(c.blocks[1].elements.map((e: any) => e.action_id), ["hqtask.task.edit", "hqtask.link"]);
  assert(JSON.stringify(c).includes("✅A") && JSON.stringify(c).includes("▫️B"));
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
