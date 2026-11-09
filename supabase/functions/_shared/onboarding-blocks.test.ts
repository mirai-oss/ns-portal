// Slack 表示部品の描画テスト（Phase 6 v2・2026-11-09）。deno test supabase/functions/_shared/onboarding-blocks.test.ts
import { assert, assertEquals } from "jsr:@std/assert@1";
import { parentMessage, taxSettingModal, postJoinSubmittedBlocks, postJoinLines, postJoinPolicyText, personContactTemplate, yearEndCompareText, uiJobResultBlocks, type WorkflowView } from "./onboarding-blocks.ts";

const wf: WorkflowView = { id: "11111111-1111-1111-1111-111111111111", user_id: "22222222-2222-2222-2222-222222222222", status: "registering", hire_date: "2026-11-09", role: "SHAIN", contract_id: "sez093z1", contract_label: "トーホー", smaregi_staff_id: "380", hq_task_id: null, user_name: "テスト 太郎", store_names: "鳥一代 本店", items: { join_form: { state: "completed" } },
  year_end: { status: "submitted", target_year: 2026, required: true, deadline: "2026-11-30", source_of_required: "rule", class: "SHAIN" },
  dependents: { status: "submitted", required: true, deadline: "2026-11-23", source_of_required: "override", count: 2, synced: 0, relationships: [1, 2] } };

Deno.test("親メッセージ: 入社後の提出 2 行（必須・期限・状態・人数・続柄）と「🧾 源泉所得税」ボタン。氏名以外の個人情報は出ない", () => {
  const m = parentMessage(wf, "nid");
  const txt = JSON.stringify(m.blocks);
  assert(txt.includes("入社後の提出")); assert(txt.includes("年末調整 2026 年度: 必須・期限 11/30")); assert(txt.includes("扶養家族: 必須・期限 11/23（個別設定）")); assert(txt.includes("配偶者・息子")); assert(txt.includes("2 人"));
  assert(txt.includes("税法上の義務を免除するものではありません"));
  assert(txt.includes("hr.onboarding.tax")); assert(txt.includes("hr.onboarding.contact"));
  assert(!txt.includes("1990"), "生年月日は出ない");
});
Deno.test("postJoinLines / postJoinPolicyText: 任意・対象外・反映済み・扶養なし・承認待ち", () => {
  assertEquals(postJoinPolicyText({ status: "pending", required: false }), "任意");
  assertEquals(postJoinPolicyText({ status: "not_target", target: false }), "対象外");
  assertEquals(postJoinPolicyText({ status: "pending", required: true, deadline: "2026-12-09", source_of_required: "override" }), "必須・期限 12/09（個別設定）");
  const l = postJoinLines({ ...wf, year_end: { status: "synced", target_year: 2026, required: true }, dependents: { status: "none", required: false } });
  assert(l[0].startsWith("✅") && l[0].includes("スマレジ反映済み")); assert(l[1].startsWith("✅") && l[1].includes("扶養なし") && l[1].includes("任意"));
  const p = postJoinLines({ ...wf, year_end: null, dependents: null });
  assert(p[0].startsWith("▫️") && p[0].includes("任意") && p[0].includes("未提出"));
  const a = postJoinLines({ ...wf, year_end: { status: "approved", required: true }, dependents: { status: "pending", required: true } });
  assert(a[0].startsWith("⏳") && a[0].includes("承認済み")); assert(a[1].startsWith("⬜"));
});
Deno.test("源泉所得税モーダル: スマレジと同じ 4 項目・同じ選択肢（社員・アルバイト共通）", () => {
  const m: any = taxSettingModal({ workflow_id: wf.id, notification_id: null }, { name: "テスト 太郎", application_ym: "2026/11", tax_category: "kou", spouse_division: 1, dependents_count: 2 });
  assertEquals(m.callback_id, "hr.onboarding.tax.modal"); assertEquals(m.title.text, "源泉所得税設定を追加");
  assertEquals(m.blocks.filter((b: any) => b.type === "input").map((b: any) => b.block_id), ["ym", "type", "spouse", "dep"]);
  const spouse = m.blocks.find((b: any) => b.block_id === "spouse").element;
  assertEquals(spouse.options.map((o: any) => o.text.text), ["対象でない", "源泉控除対象(配偶者控除対象)", "源泉控除対象(配偶者特別控除対象)"]);
  assertEquals(spouse.initial_option.value, "1");
});
Deno.test("提出のスレッド表示: 提出済み＝承認／差し戻し／比較ボタン。承認済み＝反映ボタン。扶養なし＝ボタンなし。個人情報なし", () => {
  const b1 = JSON.stringify(postJoinSubmittedBlocks(wf, null, "dependents", { count: 2, relationships: [1, 3], status: "submitted", policy: wf.dependents }));
  assert(b1.includes("2 人") && b1.includes("配偶者・娘") && b1.includes("hr.onboarding.dependents.approve") && b1.includes("hr.onboarding.dependents.reject") && b1.includes("hr.onboarding.dependents.compare") && !b1.includes("dependents.sync"));
  assert(b1.includes("必須・期限 11/23"));
  const b2 = JSON.stringify(postJoinSubmittedBlocks(wf, null, "dependents", { count: 0, status: "none" }));
  assert(b2.includes("扶養家族なし") && !b2.includes("approve") && b2.includes("反映はありません"));
  const b3 = JSON.stringify(postJoinSubmittedBlocks(wf, null, "year_end", { spouse_flag: true, student_flag: false, target_year: 2026, status: "approved" }));
  assert(b3.includes("配偶者: あり") && b3.includes("hr.onboarding.yearend.sync") && !b3.includes("yearend.approve"));
  const b4 = JSON.stringify(postJoinSubmittedBlocks(wf, null, "year_end", { spouse_flag: false, target_year: 2026, status: "submitted" }));
  assert(b4.includes("hr.onboarding.yearend.approve") && b4.includes("target_year") && b4.includes("2026"));
});
Deno.test("年末調整の比較文: 一致は「・」・違いは「⚠️」。氏名は出ない", () => {
  const t = yearEndCompareText({ spouse_flag: true, estimate_income: 1200000, retirement_income: 0, handicapped_division: 1, widow_division2: 1, student_flag: false, household_header_relationship: 0, household_header_name: "山田 太郎" },
    { spouseFlag: false, estimateIncome: 1200000, retirementIncome: 0, handicappedDivision: 1, widowDivision2: 1, studentFlag: false, householdHeaderRelationship: 0, householdHeaderName: "山***" });
  assert(t.includes("⚠️ 配偶者の有無: 提出 あり ／ スマレジ なし")); assert(t.includes("・ 合計所得見積額")); assert(!t.includes("山田"));
  assertEquals(yearEndCompareText({}, null), "スマレジ側の値を読めませんでした");
});
Deno.test("連絡文: 対象のフォームと期限が入る", () => {
  const t = personContactTemplate("post_join_form", { name: "テスト 太郎", stale_items: ["扶養家族", "年末調整 2026 年度"], deadline: "2026/11/23" });
  assert(t.includes("扶養家族・年末調整 2026 年度の情報の登録") && t.includes("期限は 2026/11/23") && t.includes("page=settings#postjoin"));
});
Deno.test("UI ジョブ結果: 書き込み前の確認で中止したときは 🛑 で再試行ボタンなし。通常の失敗は再試行ボタンあり", () => {
  const a = JSON.stringify(uiJobResultBlocks(wf, null, { id: "j", kind: "smaregi_dependents", status: "failed", attempts: 1, max_attempts: 3, error: "事前確認: 画面の所属事業所（本店）が期待（鳥一代 本店）と一致しません", error_kind: "screen_changed" }, null, ""));
  assert(a.includes("書き込み前の確認で中止") && !a.includes("hr.onboarding.ui.retry") && a.includes("扶養家族"));
  const b = JSON.stringify(uiJobResultBlocks(wf, null, { id: "j", kind: "smaregi_year_end", status: "failed", attempts: 3, max_attempts: 3, error: "SAVE_FAILED", error_kind: "save_failed" }, null, ""));
  assert(b.includes("hr.onboarding.ui.retry") && b.includes("年末調整"));
});
