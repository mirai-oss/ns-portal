// Slack 表示部品の描画テスト（Phase 6 v2・2026-11-09）。deno test supabase/functions/_shared/onboarding-blocks.test.ts
import { assert, assertEquals } from "jsr:@std/assert@1";
import { yen, wageLine, AMOUNT_HIDDEN, wageFailedBlocks, wageApprovalMark, wageApprovalText, wageApprovalBlocks, wageModal, setHideAmounts, commuteCheckBlocks, autoApprovedBlocks, parentMessage, taxSettingModal, postJoinSubmittedBlocks, postJoinLines, postJoinPolicyText, personContactTemplate, yearEndCompareText, uiJobResultBlocks, type WorkflowView } from "./onboarding-blocks.ts";

const wf: WorkflowView = { id: "11111111-1111-1111-1111-111111111111", user_id: "22222222-2222-2222-2222-222222222222", status: "registering", hire_date: "2026-11-09", role: "SHAIN", contract_id: "sez093z1", contract_label: "トーホー", smaregi_staff_id: "380", hq_task_id: null, user_name: "テスト 太郎", store_names: "鳥一代 本店", items: { join_form: { state: "completed" } },
  year_end: { status: "submitted", target_year: 2026, required: true, deadline: "2026-11-30", source_of_required: "rule", class: "SHAIN" },
  dependents: { status: "submitted", required: true, deadline: "2026-11-23", source_of_required: "override", count: 2, synced: 0, relationships: [1, 2] } };

Deno.test("親メッセージ: 入社後の提出 2 行（必須・期限・状態・人数・続柄）と「🧾 源泉所得税」ボタン。氏名以外の個人情報は出ない", () => {
  const m = parentMessage(wf, "nid");
  const txt = JSON.stringify(m.blocks);
  assert(txt.includes("入社後の提出")); assert(txt.includes("年末調整 2026 年度: 必須・社内期限 11/30")); assert(txt.includes("扶養家族: 必須・社内期限 11/23（個別設定）")); assert(txt.includes("配偶者・息子")); assert(txt.includes("2 人"));
  assert(txt.includes("税法上の義務を免除するものではありません"));
  assert(txt.includes("hr.onboarding.tax")); assert(txt.includes("hr.onboarding.contact"));
  assert(!txt.includes("1990"), "生年月日は出ない");
});
Deno.test("postJoinLines / postJoinPolicyText: 任意・対象外・反映済み・扶養なし・承認待ち", () => {
  assertEquals(postJoinPolicyText({ status: "pending", required: false }), "任意");
  assertEquals(postJoinPolicyText({ status: "not_target", target: false }), "対象外");
  assertEquals(postJoinPolicyText({ status: "pending", required: true, deadline: "2026-12-09", source_of_required: "override" }), "必須・社内期限 12/09（個別設定）");
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
  assert(b1.includes("必須・社内期限 11/23"));
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

Deno.test("期限の表示: 社内期限と法定期限（目安）を分けて出す", () => {
  assertEquals(postJoinPolicyText({ status: "pending", required: true, deadline: "2026-11-30", legal_deadline: "2026-12-14" }), "必須・社内期限 11/30（法定の目安 12/14）");
  assertEquals(postJoinPolicyText({ status: "pending", required: false, deadline: null, legal_deadline: "2026-12-14" }), "任意・法定の目安 12/14");
  assertEquals(postJoinPolicyText({ status: "pending", required: false }), "任意");
});

Deno.test("情報変更→交通費の再確認の通知: 項目名だけ出す（住所などの値は出さない）・旧交通費は「変更していません」・さかのぼりの注意", async () => {
  const m = await import("./onboarding-blocks.ts");
  const base = { id: "e1", user_id: "u1", user_name: "テスト 立会い", store_names: "鳥一代 本店", reasons: ["住所", "最寄り駅・通勤手段"], change_date: "2026-09-20", retroactive: true, suggested_effective_date: "2026-11-01",
    date_note: "変更日が締め済みの月です。2026/09〜前月分の差額は自動では直しません（精算するかは本部が判断）", snapshot: { has_commute_record: true, approved_fare: 349, home_station: "中目黒", route_text: "中目黒→田町", latest_setting: { pay_type: "per_day", amount: 500, cap_amount: 6000 } }, has_workflow: true, workflow_id: "w1" };
  const txt = JSON.stringify(m.changeEffectBlocks(base as any));
  for (const need of ["住所・最寄り駅・通勤手段", "変更していません", "¥349", "勤務日数ごと", "¥6,000", "過去にさかのぼる変更", "2026-11-01", "hr.onboarding.commute.research", "page=admin&u=u1"]) if (!txt.includes(need)) throw new Error("無い: " + need);
  if (txt.includes("中目黒")) throw new Error("旧経路・駅名（値）が通知に出ています");
  const t2 = JSON.stringify(m.changeEffectBlocks({ ...base, has_workflow: false, workflow_id: null, change_date: null, retroactive: false, date_note: null, snapshot: { has_commute_record: false } } as any));
  if (t2.includes("hr.onboarding.commute.research") || !t2.includes("管理システムに未登録") || !t2.includes("変更日: 未入力")) throw new Error("ワークフロー無し・未登録の表示");
  if (!m.changeEffectText(base as any).includes("交通費の再確認が必要")) throw new Error("text");
});

Deno.test("口座・賃金の変更申請の通知: 口座の中身・金額は出さない／競合は対応の選択肢／振込データからの除外は氏名だけ", async () => {
  const m = await import("./onboarding-blocks.ts");
  const base = { id: "r1", user_id: "u1", user_name: "テスト 立会い", store_names: "鳥一代 本店", field: "bank_account", event: "requested", requested_by_name: "テスト 立会い", by_self: true, year_month: "2026-11", pay_date: "2026-12-15", run_state: "open", effective_date: null };
  const txt = JSON.stringify(m.payChangeBlocks(base as any));
  for (const need of ["給与振込口座の変更申請", "申請: 本人", "2026-11 月分の給与（2026-12-15 支給）", "この人の振込データは確定しません", "別の人が承認", "page=admin&u=u1", "口座番号・金額はここには表示しません", "通常の給与振込に追加の承認はありません"]) if (!txt.includes(need)) throw new Error("不足: " + need);
  if (/account_number|bank_code|branch|\d{7}/.test(txt)) throw new Error("口座の中身が出ている");
  const t2 = JSON.stringify(m.payChangeBlocks({ ...base, by_self: false, requested_by_name: "本部 太郎", year_month: null, pay_date: null, run_state: null } as any));
  for (const need of ["申請: 本部 太郎", "指定なし（承認する人が選びます）"]) if (!t2.includes(need)) throw new Error("不足: " + need);
  const t3 = JSON.stringify(m.payChangeBlocks({ ...base, run_state: "exported" } as any));
  if (!t3.includes("振込データを出力済み") || !t3.includes("個別の確認・承認")) throw new Error("出力済みの注意");
  const t4 = JSON.stringify(m.payChangeBlocks({ ...base, event: "conflict" } as any));
  for (const need of ["振込データと競合", "自動では反映していません", "選び直す", "個別の確認・承認", "出し直す"]) if (!t4.includes(need)) throw new Error("不足: " + need);
  if (!m.payChangeText(base as any).includes("確認・承認が必要") || !m.payChangeText({ ...base, event: "conflict" } as any).includes("未反映")) throw new Error("text");
  // 賃金: 適用開始日は出すが、金額は型に無い＝出ない
  const w = { ...base, field: "wage", by_self: false, requested_by_name: "本部 太郎", year_month: null, pay_date: null, run_state: null, effective_date: "2027-03-01" };
  const tw = JSON.stringify(m.payChangeBlocks(w as any));
  for (const need of ["賃金の変更申請", "申請: 本部 太郎", "適用開始日: 2027-03-01", "賃金は変わりません", "別の人が承認"]) if (!tw.includes(need)) throw new Error("不足: " + need);
  if (/¥|円|\d{4,}円|wage"/.test(tw)) throw new Error("金額が出ている");
  const twc = JSON.stringify(m.payChangeBlocks({ ...w, event: "conflict" } as any));
  for (const need of ["賃金変更が未反映", "給与が確定済み", "マスターが理由を入れて承認"]) if (!twc.includes(need)) throw new Error("不足: " + need);
  if (!m.payChangeText(w as any).includes("賃金の変更申請")) throw new Error("wage text");
  // 振込データからの除外
  const h = { year_month: "2026-11", pay_date: "2026-12-15", names: ["テスト 立会い", "テスト 太郎"] };
  const th = JSON.stringify(m.transferHoldBlocks(h));
  for (const need of ["振込漏れ注意", "2026-11 月分（2026-12-15 支給）", "除外", "テスト 立会いさん", "テスト 太郎さん", "除外していた人の分を出力", "通常どおり"]) if (!th.includes(need)) throw new Error("不足: " + need);
  if (!m.transferHoldText(h).includes("2 名を振込データから除外")) throw new Error("hold text");
});

// ---- 2026-11-12: 金額を出さない表示（賃金額・交通費額は管理画面で確認。Slack には処理状況だけ） ----
const wfAmt: WorkflowView = { ...wf, items: {
  wage: { state: "completed", completion_source: "smaregi_verified", payload: { rows: [{ division: 0, wage: 1234, holiday_wage: 1500, effective_date: "2026-11-10", store_name: null }] } },
  commute_check: { state: "pending" }, commute_set: { state: "completed" } } } as any;
const commuteArg = { judgement: "hq_review", reasons: ["申請額 ¥500 が最安 ¥420 より高い"], claimed: 500, computed: { fare: 420, summary: "A線", time_min: 30, transfers: 1 },
  reasonable: [{ fare: 420, summary: "A線 → B線", time_min: 30, transfers: 1, uses_bus: false, teiki1: 12340 }], from: "X駅", to: "Y駅", store_name: "テスト店", pay_plan: { text: "1 日 ¥840（上限 ¥6,000）", policy: "daily_cap", over_cap: false } };
const actionIds = (blocks: any[]) => blocks.flatMap((b) => b.type === "actions" ? b.elements.map((e: any) => e.action_id) : []);
Deno.test("金額を出さない表示: 親メッセージは 賃金設定済み／交通費確認待ち／交通費設定済み だけ（金額なし）。既定の表示は変わらない", () => {
  setHideAmounts(false);
  const before = JSON.stringify(parentMessage(wfAmt, "nid").blocks);
  assert(before.includes("¥1,234") && before.includes("スマレジ照合済み"), "既定はこれまでどおり金額つき");
  assert(!before.includes("賃金設定済み"));
  setHideAmounts(true);
  try {
    const m = parentMessage(wfAmt, "nid"); const txt = JSON.stringify(m.blocks);
    assert(!/[¥￥]|\d円/.test(txt), "金額が残っている: " + txt.slice(0, 300));
    assert(txt.includes("賃金設定済み") && txt.includes("スマレジ照合済み") && txt.includes("交通費確認待ち") && txt.includes("交通費設定済み"));
    assertEquals(actionIds(m.blocks as any[]).sort(), actionIds(JSON.parse(before)).sort(), "ボタンは同じ");
  } finally { setHideAmounts(false); }
});
Deno.test("金額を出さない表示: 交通費の確認カード・自動承認の文面に金額・候補・理由を出さない。ボタンの名前は同じ＋管理画面へのリンク", () => {
  setHideAmounts(false);
  const normal = commuteCheckBlocks(wfAmt, "nid", commuteArg as any) as any[];
  assert(JSON.stringify(normal).includes("¥420"));
  setHideAmounts(true);
  try {
    const b = commuteCheckBlocks(wfAmt, "nid", commuteArg as any) as any[]; const txt = JSON.stringify(b);
    assert(!/[¥￥]|\d円|420|500|12340|12,340/.test(txt.replace(/"value":"[^"]*(\\"[^"]*)*"/g, "")), "金額が残っている: " + txt.slice(0, 400));
    assert(txt.includes("交通費確認待ち") && txt.includes("管理画面") && txt.includes("本部の確認が必要") && !txt.includes("X駅"));
    const ids = actionIds(b);
    for (const id of actionIds(normal)) assert(ids.includes(id), "ボタンが無い: " + id);
    assert(ids.includes("hr.onboarding.link.nippo") && txt.includes("?page=admin&u=" + wf.user_id));
    assertEquals(b[1].elements[0].value, normal[2].elements[0].value, "value は同じ（操作はそのまま）");
    const a = JSON.stringify(autoApprovedBlocks(wfAmt, "nid", { fare: 420, reasons: ["¥420 以下"], from: "X駅", to: "Y駅", computed_fare: 420 }));
    assert(!/[¥￥]|420/.test(a.replace(/"value":"[^"]*(\\"[^"]*)*"/g, "")) && a.includes("自動承認しました") && a.includes("hr.onboarding.commute.undo"));
  } finally { setHideAmounts(false); }
});

import { findAmountLeaks, maskAmountsDeep, maskAmountsText } from "./amount-mask.ts";
Deno.test("金額を出さない表示: 金額の項目そのものを数字にしない（yen・賃金の 1 行）。日付・対象は残る。出口の検査でも消し残りなし", () => {
  setHideAmounts(false);
  assertEquals(yen(1200), "¥1,200");
  const line0 = wageLine({ division: 0, wage: 1234, holiday_wage: 1500, effective_date: "2026-11-09", store_name: null });
  assert(line0.includes("¥1,234") && line0.includes("2026/11/09"));
  setHideAmounts(true);
  try {
    assertEquals(yen(1200), AMOUNT_HIDDEN); assertEquals(yen(null), "");
    const line = wageLine({ division: 0, wage: 1234, holiday_wage: 1500, effective_date: "2026-11-09", store_name: null });
    assert(!/1234|1,234|1500|1,500|[¥￥]/.test(line) && line.includes("時給") && line.includes("2026/11/09から") && line.includes("全事業所共通"), line);
    // 金額を出さない表示で作った 親メッセージ・交通費の確認カード・自動承認の文面は、出口の置き換えをかけても変わらず、消し残りの検査も通る
    for (const blocks of [parentMessage(wfAmt, "nid").blocks, commuteCheckBlocks(wfAmt, "nid", commuteArg as any), autoApprovedBlocks(wfAmt, "nid", { fare: 420, reasons: ["¥420 以下"], from: "X駅", to: "Y駅", computed_fare: 420 })]) {
      assertEquals(findAmountLeaks("", maskAmountsDeep(blocks)), []);
    }
    const t = `✅ 賃金をスマレジに反映しました（本部 花子・11/9 17:01）\n・${line}　スマレジ賃金設定ID 890`;
    assertEquals(findAmountLeaks(maskAmountsText(t), null), []);
  } finally { setHideAmounts(false); }
  // これまでの表示（金額つき）が出口を通ったとき: 置き換えで消え、検査も通る（親メッセージ・交通費の確認カード）
  for (const blocks of [parentMessage(wfAmt, "nid").blocks, commuteCheckBlocks(wfAmt, "nid", commuteArg as any)]) {
    const m = maskAmountsDeep(blocks); assert(!/[¥￥]/.test(JSON.stringify(m).replace(/"value":"[^"]*(\\"[^"]*)*"/g, "")));
    assertEquals(findAmountLeaks("", m), []);
  }
});

// 2026-11-18 入社時の賃金の承認: 承認待ち・却下・承認済みの表示。金額はどこにも出ない・承認のボタンは Slack に無い
Deno.test("入社時の賃金の承認: 親メッセージとスレッドの表示（金額なし・承認は管理システムで）", () => {
  const item = (state: string, payload: unknown, last_error: string | null = null) => ({ ...wf, items: { ...(wf.items ?? {}), wage: { state, payload, last_error } } }) as WorkflowView;
  // 印が無ければ今までどおり（何も変わらない）
  assertEquals(wageApprovalMark({ state: "manual_required", payload: { date_adjusted: [] } } as any), null);
  assertEquals(wageApprovalMark({ state: "pending" } as any), null);
  assertEquals(JSON.stringify(parentMessage(item("pending", null), "nid").blocks).includes("社長の承認待ち"), false);
  // 承認待ち
  const pend = item("manual_required", { approval: "pending", request_id: "r1", rule: "president", reason: "社員の賃金は、社長の最終承認が必要です" }, "社長の承認待ち");
  const pm = parentMessage(pend, "nid"); const ptxt = JSON.stringify(pm.blocks);
  assert(ptxt.includes("⏳ 賃金（時給・日給・月給）")); assert(ptxt.includes("*社長の承認待ち*")); assert(ptxt.includes("止まっています")); assert(pm.text.includes("社長の承認待ち"));
  assert(!/[¥￥]/.test(ptxt), "金額は出ない");
  // 確認待ち（食い違い）は理由を出す
  const hold = item("manual_required", { approval: "pending", rule: "hold", reason: "アルバイトなのに月給です（雇用区分と給与形態が合いません）" }, "確認待ち（社長の承認が必要）: アルバイトなのに月給です");
  assert(JSON.stringify(parentMessage(hold, "nid").blocks).includes("確認待ち: アルバイトなのに月給です"));
  // 却下・承認済み（反映中）
  assert(JSON.stringify(parentMessage(item("manual_required", { approval: "rejected" }, "社長が却下しました（賃金を入れ直してください）"), "nid").blocks).includes("却下（入れ直し待ち）"));
  assert(JSON.stringify(parentMessage(item("running", { approval: "approved" }), "nid").blocks).includes("承認済み（スマレジへ反映中）"));
  // 金額を出さない設定のときも同じ言葉（「賃金設定待ち」ではなく「社長の承認待ち」）
  setHideAmounts(true);
  try { const h = JSON.stringify(parentMessage(pend, "nid").blocks); assert(h.includes("*社長の承認待ち*")); assert(!h.includes("賃金設定待ち")); } finally { setHideAmounts(false); }
  // スレッド: 承認待ち＝従業員ページへのリンクだけ（承認・却下のボタンは無い）／却下＝入れ直しのボタン
  const pb = JSON.stringify(wageApprovalBlocks(pend, "nid", "pending", { actor: "本部 花子", rule: "president", reason: "社員の賃金は、社長の最終承認が必要です" }));
  assert(pb.includes("社長の承認待ち")); assert(pb.includes("スマレジには反映しません")); assert(pb.includes("hr.onboarding.link.nippo")); assert(pb.includes("page=admin&u=" + wf.user_id));
  assert(!pb.includes("approve") && !pb.includes("hr.onboarding.wage.confirm"), "Slack に承認のボタンは置かない"); assert(!/[¥￥]|\d円/.test(pb), "金額は出ない");
  const hb = JSON.stringify(wageApprovalBlocks(hold, null, "pending", { actor: "本部 花子", rule: "hold", reason: "アルバイトなのに月給です" }));
  assert(hb.includes("確認待ち（社長の承認が必要）")); assert(hb.includes("理由: アルバイトなのに月給です"));
  const rb = JSON.stringify(wageApprovalBlocks(pend, "nid", "rejected", { actor: "社長" }));
  assert(rb.includes("却下しました")); assert(rb.includes('"action_id":"hr.onboarding.wage"')); assert(rb.includes("スマレジには反映していません"));
  assert(JSON.stringify(wageApprovalBlocks(pend, "nid", "approved", { actor: "社長" })).includes("承認しました"));
  assert(wageApprovalText("pending", { actor: "本部 花子" }).includes("承認されるまでスマレジには反映しません"));
  assert(wageApprovalText("pending", { actor: "本部 花子", rule: "hold" }).includes("確認待ち"));
  // モーダル: 承認が有効のときだけ案内と「登録する」。無効なら今までどおり
  const m0: any = wageModal({ workflow_id: wf.id, user_id: wf.user_id!, notification_id: null }, { name: "テスト 太郎", hire_date: "2026-11-09", contracts: [] });
  assertEquals(m0.submit.text, "登録してスマレジに反映"); assert(!JSON.stringify(m0.blocks).includes("社長が管理システムで承認"));
  const m1: any = wageModal({ workflow_id: wf.id, user_id: wf.user_id!, notification_id: null, approval: true }, { name: "テスト 太郎", hire_date: "2026-11-09", contracts: [], approval: true });
  assertEquals(m1.submit.text, "登録する"); assert(JSON.stringify(m1.blocks).includes("社長が管理システムで承認")); assertEquals(JSON.parse(m1.private_metadata).approval, true);
});
