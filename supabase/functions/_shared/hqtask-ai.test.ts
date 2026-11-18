import { assertEquals, assert } from "jsr:@std/assert@1";
import { toDraft, isComplete, draftCard, stripBotMention, weekdayOf, systemPrompt, SCHEMA, toForm, jstToday } from "./hqtask-ai.ts";

const roster = [{ slack_user_id: "U0000000001", name: "青山" }, { slack_user_id: "U0000000002", name: "田中" }];
const today = "2026-11-17";

Deno.test("今日の日付・曜日・メンションの除去", () => {
  assertEquals(weekdayOf("2026-11-17"), "火");
  assertEquals(jstToday(new Date("2026-11-16T16:00:00Z")), "2026-11-17");   // 日本時間では 17 日
  assertEquals(stripBotMention("<@UBOT> <@U0000000001> に 来週金曜までに\n請求書", "UBOT"), "<@U0000000001> に 来週金曜までに\n請求書");
});
Deno.test("下書き: 名簿にない担当者・過去や形の悪い日付・時刻は取り除き、足りない項目を missing に", () => {
  const d = toDraft({ title: "請求書の確認", corp: "SK", memo: "", notes: "", urgent: false, missing: [], steps: [{ title: "", assignee_slack_ids: ["UXXXXXXXXXX"], due: "2026-11-01", time: "25:99" }] }, roster, today);
  assertEquals(d.steps[0].users, []);
  assertEquals(d.steps[0].due, null);
  assertEquals(d.steps[0].time, null);
  assert(d.missing.includes("担当者") && d.missing.includes("期限"));
  assert(!isComplete(d));
});
Deno.test("下書き: 全部そろえば作成できる／工程が複数のとき工程名が必要／未知の法人は null", () => {
  const ok = toDraft({ title: "T", corp: "SK", memo: "m", notes: "", urgent: true, missing: [], steps: [{ title: "", assignee_slack_ids: ["U0000000001"], due: "2026-11-20", time: "17:30" }] }, roster, today);
  assert(isComplete(ok)); assertEquals(ok.steps[0].time, "17:30"); assertEquals(ok.urgent, true);
  const two = toDraft({ title: "T", corp: "SK", memo: "", notes: "", urgent: false, missing: [], steps: [
    { title: "A", assignee_slack_ids: ["U0000000001"], due: "2026-11-20", time: null }, { title: "", assignee_slack_ids: ["U0000000002"], due: "2026-11-22", time: null }] }, roster, today);
  assert(!isComplete(two) && two.missing.includes("工程名"));
  const nocorp = toDraft({ title: "T", corp: "不明な法人", memo: "", notes: "", urgent: false, missing: [], steps: [{ title: "", assignee_slack_ids: ["U0000000001"], due: "2026-11-20", time: null }] }, roster, today);
  assertEquals(nocorp.corp, null); assert(nocorp.missing.includes("法人") && !isComplete(nocorp));
  assert(!toDraft({ title: "T", corp: "SK", missing: ["時刻（完了の時刻）", "担当者"], steps: [] }, roster, today).missing.some((m: string) => m.includes("時刻")));   // 時刻は任意＝足りない項目に出さない
  assertEquals(toDraft({}, roster, today).steps.length, 1);   // 壊れた返答でも落ちない
});
Deno.test("下書きカード: 作成ボタンは全部そろったときだけ／直す・やめるは常に", () => {
  const names = new Map(roster.map((r) => [r.slack_user_id, r.name]));
  const ids = (c: any) => c.blocks[1].elements.map((e: any) => e.action_id);
  const ok = toDraft({ title: "T", corp: "SK", memo: "", notes: "", urgent: false, missing: [], steps: [{ title: "", assignee_slack_ids: ["U0000000001"], due: "2026-11-20", time: null }] }, roster, today);
  assertEquals(ids(draftCard(ok, "d1", names)), ["hqtask.ai.create", "hqtask.ai.edit", "hqtask.ai.cancel"]);
  const ng = toDraft({ title: "T" }, roster, today);
  assertEquals(ids(draftCard(ng, "d1", names)), ["hqtask.ai.corp", "hqtask.ai.edit", "hqtask.ai.cancel"]);   // 法人が未決のときだけ［法人を選ぶ］が先頭に付く
  assert(JSON.stringify(draftCard(ng, "d1", names)).includes("決められなかった項目"));
  assertEquals(toForm(ok).steps[0].users, ["U0000000001"]);
});
Deno.test("プロンプト: 日付・名簿・指示への非従属／スキーマは厳密", () => {
  const p = systemPrompt(today, roster);
  assert(p.includes("2026-11-17（火曜日）") && p.includes("U0000000001: 青山") && p.includes("従わない"));
  assertEquals((SCHEMA as any).additionalProperties, false);
  assertEquals((SCHEMA as any).required.includes("steps"), true);
});
