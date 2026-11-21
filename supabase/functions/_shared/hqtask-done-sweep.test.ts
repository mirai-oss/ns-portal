import { assert, assertEquals } from "jsr:@std/assert@1";
import { doneMessage, liveStepId, refreshDoneCards } from "./hqtask-done-sweep.ts";

const S1 = "11111111-1111-4111-8111-111111111111", S2 = "22222222-2222-4222-8222-222222222222", S3 = "33333333-3333-4333-8333-333333333333";
const btns = (stepId: string) => [{ type: "section", text: { type: "mrkdwn", text: "x" } }, { type: "actions", elements: [
  { type: "button", action_id: "hqtask.step.done", value: JSON.stringify({ step_id: stepId }) }, { type: "button", action_id: "hqtask.step.ack", value: JSON.stringify({ step_id: stepId }) }, { type: "button", action_id: "hqtask.link", url: "https://x" }] }];

Deno.test("操作ボタンが残っているメッセージだけ、工程の id を取り出す（更新後のブロックがあればそちらを見る）", () => {
  assertEquals(liveStepId({ blocks: btns(S1) }), S1);
  assertEquals(liveStepId({ blocks: btns(S1), updated_blocks: [{ type: "section", text: { type: "mrkdwn", text: "✅" } }] }), null);
  assertEquals(liveStepId({ blocks: [{ type: "section" }] }), null);
  assertEquals(liveStepId({ blocks: [{ type: "actions", elements: [{ action_id: "hqtask.step.done", value: "壊れた" }] }] }), null);
  assertEquals(liveStepId({ blocks: [{ type: "actions", elements: [{ action_id: "hqtask.step.reopen", value: JSON.stringify({ step_id: S1 }) }] }] }), null);   // 完了済みの［↩️ 取り消し］は残す
  assertEquals(liveStepId(null), null);
});
Deno.test("書き換え後の文面: 完了済み（完了日時つき）／削除。ボタンは付けない", () => {
  const m = doneMessage({ title: "テンポス請求書(匠味・黒霧)", stepTitle: "請求書処理", completedAt: "2026-11-20T07:53:46Z" });
  assertEquals(m.text, "✅ 完了済み：テンポス請求書(匠味・黒霧)");
  const body = JSON.stringify(m.blocks);
  assert(body.includes("工程：請求書処理") && body.includes("完了：11/20 16:53") && !body.includes("actions"));
  assert(doneMessage({ title: "T", deleted: true }).text.startsWith("🗑"));
});
Deno.test("掃除: 完了・削除になった工程の DM だけ書き換える。対応中・ボタンなし・工程が見つからないものは触らない。試し実行は書き換えない", async () => {
  const tbl: Record<string, unknown[]> = {
    notification_deliveries: [
      { id: "d1", payload: { blocks: btns(S1) } },   // 完了
      { id: "d2", payload: { blocks: btns(S1) } },   // 同じ工程の別の人の DM
      { id: "d3", payload: { blocks: btns(S2) } },   // 対応中
      { id: "d4", payload: { blocks: [{ type: "section" }] } },   // ボタンなし
      { id: "d5", payload: { blocks: btns(S3) } },   // タスク削除
      { id: "d6", payload: { blocks: btns("99999999-9999-4999-8999-999999999999") } },   // 工程が無い
    ],
    hq_task_steps: [{ id: S1, task_id: "t1", title: "請求書処理", completed_at: "2026-11-20T07:53:46Z" }, { id: S2, task_id: "t2", title: "確認", completed_at: null }, { id: S3, task_id: "t3", title: "確認", completed_at: null }],
    hq_tasks: [{ id: "t1", title: "テンポス", deleted_at: null }, { id: "t2", title: "別", deleted_at: null }, { id: "t3", title: "消えた", deleted_at: "2026-11-20T00:00:00Z" }],
  };
  const sb = { from: (t: string) => { const b: any = { select: () => b, in: () => b, like: () => b, gte: () => b, order: () => b, limit: () => b, then: (res: (v: unknown) => void) => res({ data: tbl[t] ?? [], error: null }) }; return b; } };
  const sent: any[] = [];
  const notify = (b: Record<string, unknown>) => { sent.push(b); return Promise.resolve({ ok: true }); };
  const r = await refreshDoneCards(sb, notify);
  assertEquals([r.ok, r.checked, r.live, r.updated, r.failed], [true, 6, 5, 3, 0]);
  assertEquals(sent.map((x) => x.notification_id), ["d1", "d2", "d5"]);
  assert(sent.every((x) => x.action === "update" && !JSON.stringify(x.blocks).includes("actions")));
  assert(String(sent[2].text).startsWith("🗑"));
  const d = await refreshDoneCards(sb, notify, { dryRun: true });
  assertEquals([d.updated, sent.length], [3, 3]);
  const bad = await refreshDoneCards(sb, () => Promise.resolve({ ok: false }));
  assertEquals([bad.updated, bad.failed], [0, 3]);
});
