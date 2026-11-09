// Slack 表示部品の描画テスト（Phase 6・2026-11-09）。deno test supabase/functions/_shared/onboarding-blocks.test.ts
import { assert, assertEquals } from "jsr:@std/assert@1";
import { parentMessage, taxSettingModal, postJoinSubmittedBlocks, postJoinLines, personContactTemplate, type WorkflowView } from "./onboarding-blocks.ts";

const wf: WorkflowView = { id: "11111111-1111-1111-1111-111111111111", user_id: "22222222-2222-2222-2222-222222222222", status: "registering", hire_date: "2026-11-09", role: "AL", contract_id: "sez093z1", contract_label: "トーホー", smaregi_staff_id: "380", hq_task_id: null, user_name: "テスト 太郎", store_names: "鳥一代 本店", items: { join_form: { state: "completed" } }, year_end: { status: "submitted", sync_status: "pending" }, dependents: { status: "submitted", count: 2, synced: 0, relationships: [1, 2] } };

Deno.test("親メッセージ: 入社後の提出 2 行と「🧾 源泉所得税」ボタンが出る。個人情報（氏名以外）は出ない", () => {
  const m = parentMessage(wf, "nid");
  const txt = JSON.stringify(m.blocks);
  assert(txt.includes("入社後の提出")); assert(txt.includes("年末調整の情報")); assert(txt.includes("扶養家族")); assert(txt.includes("配偶者・息子")); assert(txt.includes("2 人"));
  assert(txt.includes("hr.onboarding.tax")); assert(txt.includes("hr.onboarding.contact"));
  const lines = postJoinLines({ ...wf, year_end: { status: "synced" }, dependents: { status: "none" } });
  assert(lines[0].startsWith("✅")); assert(lines[1].includes("扶養なし"));
  const pend = postJoinLines({ ...wf, year_end: null, dependents: null });
  assert(pend[0].startsWith("⬜") && pend[1].startsWith("⬜"));
});
Deno.test("源泉所得税モーダル: スマレジと同じ 4 項目・同じ選択肢", () => {
  const m: any = taxSettingModal({ workflow_id: wf.id, notification_id: null }, { name: "テスト 太郎", application_ym: "2026/11", tax_category: "kou", spouse_division: 1, dependents_count: 2 });
  assertEquals(m.callback_id, "hr.onboarding.tax.modal"); assertEquals(m.title.text, "源泉所得税設定を追加");
  const ids = m.blocks.filter((b: any) => b.type === "input").map((b: any) => b.block_id);
  assertEquals(ids, ["ym", "type", "spouse", "dep"]);
  const spouse = m.blocks.find((b: any) => b.block_id === "spouse").element;
  assertEquals(spouse.options.map((o: any) => o.text.text), ["対象でない", "源泉控除対象(配偶者控除対象)", "源泉控除対象(配偶者特別控除対象)"]);
  assertEquals(spouse.initial_option.value, "1");
  assertEquals(m.blocks.find((b: any) => b.block_id === "dep").element.initial_value, "2");
  assertEquals(m.blocks.find((b: any) => b.block_id === "ym").element.initial_value, "2026/11");
});
Deno.test("提出のスレッド表示: 扶養は人数と続柄だけ・反映ボタン。扶養なしはボタンなし。年末調整は反映ボタン", () => {
  const b1 = JSON.stringify(postJoinSubmittedBlocks(wf, null, "dependents", { count: 2, relationships: [1, 3] }));
  assert(b1.includes("2 人") && b1.includes("配偶者・娘") && b1.includes("hr.onboarding.dependents.sync") && b1.includes("hr.onboarding.tax"));
  const b2 = JSON.stringify(postJoinSubmittedBlocks(wf, null, "dependents", { count: 0 }));
  assert(b2.includes("扶養家族なし") && !b2.includes("dependents.sync"));
  const b3 = JSON.stringify(postJoinSubmittedBlocks(wf, null, "year_end", { spouse_flag: true, student_flag: false }));
  assert(b3.includes("配偶者: あり") && b3.includes("hr.onboarding.yearend.sync"));
});
Deno.test("連絡文: 扶養・年末調整フォームのお願い", () => {
  const t = personContactTemplate("post_join_form", { name: "テスト 太郎" });
  assert(t.includes("テスト 太郎さん") && t.includes("page=settings#postjoin") && t.includes("扶養家族がいない場合"));
});
