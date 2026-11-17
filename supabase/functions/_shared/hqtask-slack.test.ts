import { assertEquals, assert } from "jsr:@std/assert@1";
import { reminderMessage, reminderHead, parseCreate, createModal, assignedMessage, type Candidate } from "./hqtask-slack.ts";

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
  const modal: any = createModal();
  assertEquals(modal.blocks.map((b: any) => b.block_id), ["title", "corp", "assignees", "due", "due_time", "memo", "urgent"]);
  const det: any = createModal(true);
  assertEquals(det.blocks.map((b: any) => b.block_id), ["title", "corp", "assignees", "due", "due_time", "memo", "notes", "steps", "photo", "urgent"]);
  assert(det.blocks.find((b: any) => b.block_id === "due_time").element.type === "timepicker");
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
