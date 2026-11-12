// 入社登録の通知の新しい形（親 1 行＋状況カード）の文面のテスト。deno test supabase/functions/_shared/
//   ① 今までの形（v1）の親メッセージは、変更前の控え（fixtures/onboarding-parent-v1-golden.json）と同じ出力のまま
//   ② 新しい形（v2）: 親は 1 行・状況カードに一覧とボタン・金額と個人情報は出さない・承認ボタンは無い・完了と中止のあとは操作ボタンなし
//   ③ スレッドに返信を足すか（自動処理の成功は足さない／人の対応が要るもの・人の操作の記録だけ）
import { assert, assertEquals } from "jsr:@std/assert@1";
import { parentMessage, setHideAmounts, ITEM_ORDER, type WorkflowView } from "./onboarding-blocks.ts";
import { pickFormat, rowFormat, noticeState, monthDay, parentLine, statusCard, cardActions, threadWording, wageSyncedNote, commuteDecidedNote, commuteSettingNote, taxSettingNote, accountCheckNote, uiJobNeedsPost, UI_JOB_SUMMARY_V2 } from "./onboarding-notice.ts";
import { findAmountLeaks, maskAmountsDeep } from "./amount-mask.ts";
import golden from "./fixtures/onboarding-parent-v1-golden.json" with { type: "json" };

const W = "11111111-1111-4111-8111-111111111111", U = "22222222-2222-4222-8222-222222222222", T = "33333333-3333-4333-8333-333333333333";
const done = { state: "completed" } as const;
const wageRows = [{ division: 0, wage: 1234, holiday_wage: 1500, effective_date: "2026-11-20", store_name: null, wageApplyId: "55" }];
const base: WorkflowView = { id: W, user_id: U, status: "registering", hire_date: "2026-11-20", role: "AL", contract_id: "c-test", contract_label: "テスト契約", smaregi_staff_id: "901", hq_task_id: T, user_name: "テスト 花子", store_names: "テスト店",
  items: { join_form: done, smaregi_staff: done, slack_link: { state: "pending" } }, year_end: null, dependents: null };
const withItems = (items: Record<string, unknown>, more: Partial<WorkflowView> = {}) => ({ ...base, ...more, items: { ...(base.items ?? {}), ...items } }) as WorkflowView;
const allDone = Object.fromEntries(ITEM_ORDER.map(({ key }) => [key, done]));
const btns = (blocks: unknown[]) => (blocks as any[]).filter((b) => b.type === "actions").flatMap((b) => b.elements.map((e: any) => e.action_id as string));
const words = (blocks: unknown[]) => (blocks as any[]).flatMap((b) => b.type === "section" ? [b.text.text as string] : b.type === "context" ? b.elements.map((e: any) => e.text as string) : b.type === "actions" ? b.elements.map((e: any) => e.text.text as string) : []).join("\n");
const sha = async (x: unknown) => [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(x))))].map((b) => b.toString(16).padStart(2, "0")).join("");
const noTime = (x: unknown) => JSON.parse(JSON.stringify(x).replace(/更新 [0-9/]+ [0-9:]+/g, "更新 <時刻>"));

// ---- ① 今までの形は変わっていない ----
Deno.test("今までの形（v1）: 親メッセージは、変更前の控えと同じ出力のまま（金額あり・金額なしの両方）", async () => {
  assertEquals(golden.cases.length, 16);
  for (const c of golden.cases) {
    setHideAmounts(c.hide);
    try {
      const m = noTime(parentMessage(c.wf as unknown as WorkflowView, c.nid));
      assertEquals(m.text, c.text, c.name);
      assertEquals(m.blocks.length, c.blocks_count, c.name);
      assertEquals(await sha(m.blocks), c.blocks_sha256, `${c.name}: ブロックが変更前と違います\n${JSON.stringify(m.blocks).slice(0, 600)}`);
    } finally { setHideAmounts(false); }
  }
});

// ---- 形の決め方 ----
Deno.test("形の決め方: 設定が無い・v1 は今までの形。v2 は設定か呼び出しの指定のときだけ。列が無ければ必ず今までの形。控えの無い入社登録は今までの形", () => {
  assertEquals(pickFormat({ setting: null, columnsReady: true }), "v1");
  assertEquals(pickFormat({ setting: { enabled: true, legacy_wage_text: false, channel_key: "hq.jinji" }, columnsReady: true }), "v1");
  assertEquals(pickFormat({ setting: { format: "v1" }, columnsReady: true }), "v1");
  assertEquals(pickFormat({ setting: { format: "V2" }, columnsReady: true }), "v1");          // 書き間違いは今までの形
  assertEquals(pickFormat({ setting: { format: "v2" }, columnsReady: true }), "v2");
  assertEquals(pickFormat({ setting: { format: "v2" }, columnsReady: false }), "v1");         // SQL 未適用
  assertEquals(pickFormat({ body: "v2", setting: { format: "v2" }, columnsReady: false }), "v1");
  assertEquals(pickFormat({ body: "v2", setting: null, columnsReady: true }), "v2");          // テスト用の入社登録だけ新しい形
  assertEquals(pickFormat({ body: "v1", setting: { format: "v2" }, columnsReady: true }), "v1");
  assertEquals(pickFormat({ body: "x", setting: { format: "v2" }, columnsReady: true }), "v2");
  assertEquals(rowFormat(null), "v1"); assertEquals(rowFormat({}), "v1"); assertEquals(rowFormat({ slack_notice_format: null }), "v1");
  assertEquals(rowFormat({ slack_notice_format: "v1" }), "v1"); assertEquals(rowFormat({ slack_notice_format: "v2" }), "v2");
});

// ---- ② 親メッセージ（1 行） ----
Deno.test("親メッセージ: 1 行だけ（印・入社登録・氏名・入社日）。入社日のあとに状態（進行中／要対応／完了／中止）。入社日が無ければ日付だけ省く", () => {
  assertEquals(monthDay("2026-11-20"), "11/20"); assertEquals(monthDay("2026-01-05"), "1/5"); assertEquals(monthDay(null), null); assertEquals(monthDay("未定"), null);
  assertEquals(parentLine(base, "nid").text, "🟢 入社登録｜テスト 花子｜入社 11/20｜進行中");
  assertEquals(parentLine({ ...base, hire_date: null }, "nid").text, "🟢 入社登録｜テスト 花子｜進行中");
  assertEquals(parentLine(withItems({ wage: { state: "failed", last_error: "x" } }), "nid").text, "🛑 入社登録｜テスト 花子｜入社 11/20｜要対応");
  assertEquals(parentLine(withItems({ wage: { state: "manual_required", payload: { approval: "pending" } } }), "nid").text, "🛑 入社登録｜テスト 花子｜入社 11/20｜要対応");
  assertEquals(parentLine({ ...base, status: "completed", items: allDone }, "nid").text, "✅ 入社登録｜テスト 花子｜入社 11/20｜完了");
  assertEquals(parentLine({ ...base, status: "cancelled" }, "nid").text, "⛔ 入社登録｜テスト 花子｜入社 11/20｜中止");
  assertEquals(parentLine({ ...base, user_name: null }, "nid").text, "🟢 入社登録｜（氏名不明）｜入社 11/20｜進行中");
  // 自動のやり直し待ち（retry_wait）・処理中は、人の対応が要らないので「要対応」にしない
  assertEquals(noticeState(withItems({ email: { state: "retry_wait" }, commute_set: { state: "running" } })).code, "progress");
  // 氏名に区切りの記号や改行が入っていても 1 行のまま
  assert(!parentLine({ ...base, user_name: "テスト｜花子\n二行目" }, "nid").text.includes("\n"));
});
Deno.test("親メッセージ: 区分・所属・項目の一覧・操作ボタンは出さない。ボタンは［詳細を確認］（リンク）だけ。完了・中止のあとも残す", () => {
  const link = "https://example.slack.com/archives/C000/p1?thread_ts=1";
  const p = parentLine(withItems({ wage: { state: "completed", completion_source: "smaregi_verified", payload: { rows: wageRows } } }), "nid-p", { permalink: link });
  assertEquals(p.blocks.length, 2);
  assertEquals((p.blocks[0] as any).text.text, p.text);
  assertEquals(btns(p.blocks), ["hr.onboarding.link.open"]);          // slack-interact の hr.onboarding.link*（何もしない）が受ける
  const b = (p.blocks[1] as any).elements[0];
  assertEquals(b.url, link); assertEquals(JSON.parse(b.value), { workflow_id: W, notification_id: "nid-p" });
  for (const ng of ["アルバイト", "テスト店", "賃金", "交通費", "1234", "1,234", "901", "スマレジ"]) assert(!JSON.stringify(p.blocks[0]).includes(ng), "親に出ている: " + ng);
  assertEquals(btns(parentLine(base, "nid").blocks), []);             // リンクが取れなければボタンなし
  // 完了・中止のあとも［詳細を確認］は残す（2026-11-12 ユーザー決定）。操作ボタンは出さない
  assertEquals(btns(parentLine({ ...base, status: "completed", items: allDone }, "nid", { permalink: link }).blocks), ["hr.onboarding.link.open"]);
  assertEquals(btns(parentLine({ ...base, status: "cancelled" }, "nid", { permalink: link }).blocks), ["hr.onboarding.link.open"]);
});

// ---- ② 状況カード ----
Deno.test("状況カード: 10 項目の一覧・氏名と区分・所属・入社日・入社後の提出。金額と個人情報は出さない（金額を出す設定でも）", () => {
  const wf = withItems({
    wage: { state: "completed", completion_source: "smaregi_verified", payload: { rows: wageRows, verified: true } },
    commute_check: { state: "completed", payload: { approved_fare: 420 } }, commute_set: { state: "running", payload: { verify: "pending", amount: 840 } },
    email: { state: "completed", payload: { mail_masked: "t***@example.com" } }, withholding_tax: { state: "completed", payload: { withholding: [{ type: 1, dependent: 2 }] } },
  }, { year_end: { status: "submitted", target_year: 2026, required: true, deadline: "2026-11-30" }, dependents: { status: "submitted", required: true, deadline: "2026-11-23", source_of_required: "override", count: 2, synced: 0, relationships: [1, 2] } });
  for (const hide of [false, true]) {
    setHideAmounts(hide);
    try {
      const c = statusCard(wf, "nid-p"); const txt = words(c.blocks);
      for (const { label } of ITEM_ORDER) assert(txt.includes(label), "項目が無い: " + label);
      for (const need of ["【入社登録】", "氏名：テスト 花子（アルバイト）", "所属：テスト店", "入社日：2026/11/20", "テスト契約／従業員ID 901", "🟢 進行中（6/10 完了）", "賃金設定済み（スマレジ照合済み）", "交通費確認済み", "交通費設定待ち（スマレジに入力済み・照合待ち）",
        "【入社後の提出】", "年末調整 2026 年度：必須・社内期限 11/30・提出済み（本部の承認待ち）", "扶養家族：必須・社内期限 11/23（個別設定）・提出済み（本部の承認待ち）", "page=admin&u=" + U, "tasks.html?task=" + T]) assert(txt.includes(need), "無い: " + need + "\n" + txt);
      for (const ng of ["1234", "1,234", "1500", "420", "840", "¥", "円", "example.com", "配偶者", "息子", "2 人", "甲", "乙"]) assert(!txt.includes(ng), "出てはいけないもの: " + ng);
      assertEquals(findAmountLeaks(c.text, c.blocks), []);                      // 出口の検査（消し残りがあれば送信を止める）にかからない
      assertEquals(JSON.stringify(maskAmountsDeep(c.blocks)), JSON.stringify(c.blocks));   // 出口の置き換えをかけても変わらない
      assert(c.text.startsWith("【入社登録】テスト 花子") && !c.text.includes("\n"));
    } finally { setHideAmounts(false); }
  }
});
Deno.test("状況カード: ボタンは今までの親と同じ名前・同じ value。いま必要なものだけ。承認のボタンは無い", () => {
  const v1 = parentMessage(base, "nid-p").blocks as any[];
  const v1Ids = btns(v1), v1Value = v1.find((b) => b.type === "actions").elements[0].value;
  const all = [base, withItems({ wage: done, commute_check: done }), withItems({ wage: done, commute_check: done, commute_set: done, withholding_tax: done }), withItems({ wage: { state: "failed", last_error: "x" } })];
  for (const wf of all) {
    const c = statusCard(wf, "nid-p");
    for (const b of (c.blocks as any[]).filter((x) => x.type === "actions")) {
      assertEquals(new Set(b.elements.map((e: any) => e.action_id)).size, b.elements.length);     // 同じ行の中でボタンの名前が重ならない
      for (const e of b.elements) { assert(v1Ids.includes(e.action_id), "今までに無いボタン: " + e.action_id); assertEquals(e.value, v1Value); assert(!e.url); }
    }
    for (const id of btns(c.blocks)) assert(!/approve|confirm|reject|\.sync$|retry/.test(id), "承認・確定・再実行のボタンはカードに出さない: " + id);
  }
  // 始まったばかり: 賃金・源泉（交通費の設定は、経路の承認の前は出さない）
  const a0 = cardActions(base, "nid-p");
  assertEquals(a0.need.map((e: any) => e.action_id), ["hr.onboarding.wage", "hr.onboarding.tax"]); assertEquals((a0.need[0] as any).style, "primary");
  assertEquals(a0.more.map((e: any) => e.action_id), ["hr.onboarding.contact", "hr.onboarding.account.check", "hr.onboarding.refresh", "hr.onboarding.cancel"]);
  assert((a0.more[3] as any).confirm, "中止は確認つき");
  // 交通費の経路を承認したあと: 交通費の設定が出る。賃金が済んだら賃金は消える
  assertEquals(cardActions(withItems({ wage: done, commute_check: done }), "n").need.map((e: any) => e.action_id), ["hr.onboarding.commute.set", "hr.onboarding.tax"]);
  // ぜんぶ設定済み（進行中）: 必要なボタンの行は無い。交通費の入れ直しだけ「その他」に残る
  const a2 = cardActions(withItems({ wage: done, commute_check: done, commute_set: done, withholding_tax: done }), "n");
  assertEquals(a2.need, []); assert(a2.more.some((e: any) => e.action_id === "hr.onboarding.commute.set" && e.text.text.includes("入れ直す")));
  // 反映の途中（処理中・照合待ち）は、同じ設定のボタンを出さない
  const a3 = cardActions(withItems({ wage: { state: "running" }, commute_check: done, commute_set: { state: "running", payload: { verify: "pending" } }, withholding_tax: { state: "manual_running" } }), "n");
  assertEquals(a3.need, []); assert(!a3.more.some((e: any) => e.action_id === "hr.onboarding.commute.set"));
});
Deno.test("状況カード: 完了・中止のあとは操作ボタンを出さない（リンクと一覧だけ）。中止は理由を言葉で出す", () => {
  const c1 = statusCard({ ...base, status: "completed", items: allDone }, "nid-p");
  assertEquals(btns(c1.blocks), []); assert(words(c1.blocks).includes("✅ 完了（10/10）")); assert(words(c1.blocks).includes("【入社後の提出】"));
  const c2 = statusCard({ ...base, status: "cancelled", cancelled_reason: "declined_by_person", items: { join_form: done, wage: { state: "cancelled" } } }, "nid-p");
  assertEquals(btns(c2.blocks), []); assert(words(c2.blocks).includes("⛔ 中止（本人から入社辞退）")); assert(!words(c2.blocks).includes("declined_by_person")); assert(!words(c2.blocks).includes("【入社後の提出】"));
});
Deno.test("状況カード: 賃金の承認（社長の承認待ち＝賃金ボタンなし／却下＝入れ直しのボタンあり）。承認のボタンは Slack に出さない", () => {
  const pend = withItems({ wage: { state: "manual_required", payload: { approval: "pending", rule: "president" }, last_error: "社長の承認待ち" } }, { role: "SHAIN" });
  const c = statusCard(pend, "n"); const t = words(c.blocks);
  assert(t.includes("⏳ 賃金（時給・日給・月給）：社長の承認待ち") && t.includes("🛑 要対応（2/10 完了）: 賃金（時給・日給・月給）"));
  assert(!btns(c.blocks).includes("hr.onboarding.wage")); assert(!btns(c.blocks).some((id) => /approve/.test(id)));
  const rej = withItems({ wage: { state: "manual_required", payload: { approval: "rejected" }, last_error: "却下" } });
  assert(words(statusCard(rej, "n").blocks).includes("↩️ 賃金（時給・日給・月給）：却下（入れ直し待ち）")); assert(btns(statusCard(rej, "n").blocks).includes("hr.onboarding.wage"));
  const run = withItems({ wage: { state: "running", payload: { approval: "approved" } } });
  assert(words(statusCard(run, "n").blocks).includes("🔄 賃金（時給・日給・月給）：承認済み（スマレジへ反映中）")); assert(!btns(statusCard(run, "n").blocks).includes("hr.onboarding.wage"));
});
Deno.test("状況カード: 失敗の理由は出す。理由に金額らしいものが混ざっていたら、理由を出さない（送信が止まらないように）", () => {
  const ok = statusCard(withItems({ wage: { state: "failed", last_error: "スマレジへの反映に失敗しました（HTTP 503）" }, email: { state: "retry_wait" } }), "n");
  assert(words(ok.blocks).includes("⚠️ 賃金（時給・日給・月給）：賃金設定待ち（スマレジへの反映に失敗しました（HTTP 503））")); assert(words(ok.blocks).includes("⏳ メールアドレス登録（スマレジ）：再試行待ち"));
  assertEquals(findAmountLeaks(ok.text, ok.blocks), []);
  for (const err of ["時給 ¥1,234 は保存できません", "上限 6000 を超えています", "金額 1234円 が不正", "交通費 420 の登録に失敗"]) {
    const c = statusCard(withItems({ commute_set: { state: "failed", last_error: err }, commute_check: done }), "n"); const t = words(c.blocks);
    assert(t.includes("⚠️ 交通費の設定：交通費設定待ち（理由は管理システムで確認）"), err + "\n" + t);
    for (const ng of ["1,234", "1234", "6000", "420"]) assert(!t.includes(ng), "金額が残っている: " + ng);
    assertEquals(findAmountLeaks(c.text, c.blocks), []);
  }
});

// ---- ③ スレッドに返信を足すか ----
Deno.test("スレッドの返信: 賃金の反映＝自動の成功は足さない／人が操作したら 1 行の記録／照合できないときは確認のお願い。金額は出さない", () => {
  const a = { who: "テスト 本部", when: "11/20 10:00", verifyNote: "" };
  assertEquals(wageSyncedNote({ ...a, verified: true, human: false }), null);
  assertEquals(wageSyncedNote({ ...a, verified: true, human: true, recorded: true }), null);            // 社長の承認の記録を出したあと
  const rec = wageSyncedNote({ ...a, verified: true, human: true })!;
  assert(rec.includes("賃金をスマレジに反映しました（テスト 本部・11/20 10:00）") && !rec.includes("\n"));
  const ng = wageSyncedNote({ ...a, verified: false, verifyNote: "照合で一致しない行があります（1 件）。時給 ¥1,234", human: false })!;
  assert(ng.startsWith("⚠️") && ng.includes("読み直した値が一致しません") && ng.includes("スマレジ管理画面で確認") && !ng.includes("1,234"));
  assert(wageSyncedNote({ ...a, verified: null, verifyNote: "照合できませんでした: timeout", human: true, recorded: true })!.includes("照合ができていません"));
});
Deno.test("スレッドの返信: 交通費の承認・設定・源泉・スマレジ照合は、人の操作の記録だけ（金額・税の内容・メールなし）", () => {
  const a = { who: "テスト 本部", when: "11/20 10:00" };
  const ap = commuteDecidedNote({ ...a, decision: "approved", note: "検索の最安額で承認", oneStep: "saved" });
  assert(ap.startsWith("✅ 交通費の経路と片道額を承認しました（テスト 本部・11/20 10:00）") && ap.includes("設定も登録しました") && !/[¥￥]|\d円/.test(ap) && !ap.includes("親メッセージ"));
  assert(commuteDecidedNote({ ...a, decision: "approved", oneStep: null }).includes("状況カード（スレッドの先頭）の「🚌 交通費を設定」"));
  assert(commuteDecidedNote({ ...a, decision: "approved", oneStep: "no_teiki" }).includes("定期代が検索で取れていない"));
  assert(!commuteDecidedNote({ ...a, decision: "approved", oneStep: "already_set" }).includes("▶"));
  assert(commuteDecidedNote({ ...a, decision: "person_review" }).startsWith("🙋 本人に経路と金額を確認"));
  const rj = commuteDecidedNote({ ...a, decision: "rejected", note: "片道 420円 は高い" });
  assert(rj.startsWith("↩️ 交通費を差し戻しました") && rj.includes("理由: ") && !rj.includes("420"));
  assertEquals(commuteSettingNote({ ...a, manual: false, oneStep: true }), null);                        // 承認と同時の自動登録は足さない
  assert(commuteSettingNote({ ...a, manual: false, oneStep: false })!.startsWith("🚌 交通費の設定を登録しました（テスト 本部・11/20 10:00）"));
  for (const one of [true, false]) assert(commuteSettingNote({ ...a, manual: true, oneStep: one })!.includes("スマレジ管理画面に入力"));   // 手で入力が要るときは必ず出す
  const tx = taxSettingNote({ ...a, manual: false });
  assert(tx.startsWith("🧾 源泉所得税の設定を登録しました（テスト 本部・11/20 10:00）") && !/甲|乙|配偶者|親族/.test(tx));
  assert(taxSettingNote({ ...a, manual: true }).includes("源泉所得税設定を追加") && !/甲|乙|配偶者|親族の数/.test(taxSettingNote({ ...a, manual: true })));
  const ac = accountCheckNote({ ...a, done: ["メールアドレス", "源泉所得税"], warnings: ["⚠️ 本人アカウント登録: 読み取りジョブを作れません（x）"] });
  assert(ac.includes("メールアドレス・源泉所得税 の登録を確認しました") && ac.includes("⚠️ 本人アカウント登録") && !ac.includes("@"));
  assert(accountCheckNote({ ...a, done: [] }).includes("新しく確認できた項目はありません"));
});
Deno.test("スレッドの返信: スマレジ画面の自動操作の結果は、人の対応が要るときだけ足す", () => {
  const j = { dryRun: false, escalated: false, snapshot: false };
  assertEquals(uiJobNeedsPost({ ...j, status: "success", verified: true }), false);                    // 成功（照合一致）
  assertEquals(uiJobNeedsPost({ ...j, status: "success", verified: null }), false);                    // 照合待ち（途中経過）
  assertEquals(uiJobNeedsPost({ ...j, status: "pending", verified: null }), false);                    // 失敗して、あとで再試行
  assertEquals(uiJobNeedsPost({ ...j, status: "success", verified: null, dryRun: true }), false);      // 定期の読み取り（本人アカウントの確認など）
  assertEquals(uiJobNeedsPost({ ...j, status: "success", verified: false }), true);                    // 照合が一致しない
  assertEquals(uiJobNeedsPost({ ...j, status: "success", verified: null, escalated: true }), true);    // 5 回読み直せず、確認の工程を足した
  assertEquals(uiJobNeedsPost({ ...j, status: "failed", verified: null }), true);                      // 手動対応が必要
  assertEquals(uiJobNeedsPost({ ...j, status: "success", verified: null, dryRun: true, snapshot: true }), true);   // 人が頼んだ読み取り（扶養の比較）
  assert(!/[0-9¥円甲乙@]/.test(UI_JOB_SUMMARY_V2));
});
Deno.test("今までの文面を返信に使うときの言い換え: 親メッセージ → 状況カード。ボタンの value・名前・リンクは変えない", () => {
  assertEquals(threadWording("▶ 次: 親メッセージの「🚌 交通費を設定」"), "▶ 次: 状況カード（スレッドの先頭）の「🚌 交通費を設定」");
  assert(threadWording("担当の方は親メッセージのボタンから進めるか").includes("状況カード（スレッドの先頭）のボタンから"));
  assert(threadWording("結果はこのスレッドに届きます（既に待機中）").includes("うまくいかなかったときだけ、ここに届きます"));
  const blocks = [{ type: "section", text: { type: "mrkdwn", text: "親メッセージの「🚌 交通費を設定」" } }, { type: "actions", block_id: "b", elements: [{ type: "button", text: { type: "plain_text", text: "親メッセージのボタン" }, action_id: "hr.onboarding.commute.undo", value: "{\"x\":\"親メッセージの「\"}", url: "https://example.com/親メッセージのボタン" }] }];
  const out = threadWording(blocks) as any[];
  assert(out[0].text.text.startsWith("状況カード")); assert(out[1].elements[0].text.text.startsWith("状況カード"));
  assertEquals(out[1].elements[0].value, (blocks[1] as any).elements[0].value); assertEquals(out[1].elements[0].url, (blocks[1] as any).elements[0].url); assertEquals(out[1].elements[0].action_id, "hr.onboarding.commute.undo");
  assertEquals(threadWording("変わらない文"), "変わらない文"); assertEquals(threadWording(undefined), undefined);
});
