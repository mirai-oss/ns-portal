// 第 1 段階（マネーフォワードの総額照合）の判定のテスト。作り物のデータだけ（実在の人・口座・金額は使わない）
import { assert, assertEquals } from "jsr:@std/assert@1";
import { depositAccountFromSummary, isWebSofuri, judgeMfTotal, type MfOutflow, normRemark, reasonText, scanRange, toMfOutflows } from "./payroll-mf-total.ts";

const DEP = "普通預金/テスト銀行 本店";
const batch = { batch_id: "b-1", scheduled_date: "2031-10-15", expected_total: 1234567, expected_count: 10 };
const out = (id: string, o: Partial<MfOutflow> = {}): MfOutflow => ({ journal_id: id, branch_no: 0, transaction_date: "2031-10-15", amount: 1234567, deposit_account: DEP, remark: "WEB総振", ...o });
const opts = { depositAccounts: [DEP], windowDays: 3 };

Deno.test("摘要のゆれ: 全角・半角・小文字・空白があっても「WEB総振」と分かる。ほかの言葉は拾わない", () => {
  for (const r of ["WEB総振", "ＷＥＢ総振", "Web 総振", "ｗｅｂ　総振", "振込 WEB総振 10/15", "ＷＥＢ総振　給与"]) assert(isWebSofuri(r), r);
  for (const r of ["総合振込", "振込 テスト", "WEB一括振込", "", null, undefined]) assert(!isWebSofuri(r), String(r));
  assertEquals(normRemark(" ｗｅｂ 総振 "), "WEB総振");
});

Deno.test("ぴったり同じ出金がちょうど 1 件 → 記録してよい（登録名の書き方で渡す）", () => {
  const j = judgeMfTotal(batch, [out("J1", { remark: "ＷＥＢ総振", deposit_account: "普通預金/テスト銀行　本店" }), out("J2", { remark: "振込 テスト" }), out("J3", { amount: 500 })], opts);
  assertEquals(j.decision, "record"); assertEquals(j.reason, "matched_one");
  assertEquals(j.pick?.journal_id, "J1"); assertEquals(j.pick?.registered_account, DEP);
  assertEquals(j.counts, { webSofuri: 2, accountOk: 2, exact: 1 });
});

Deno.test("0 件: 「WEB総振」の出金が無い・期間の外にしか無い → 記録しない", () => {
  assertEquals(judgeMfTotal(batch, [], opts).reason, "no_candidate");
  assertEquals(judgeMfTotal(batch, [out("J1", { remark: "振込 テスト" })], opts).reason, "no_candidate");
  const far = judgeMfTotal(batch, [out("J1", { transaction_date: "2031-10-19" })], opts);
  assertEquals(far.decision, "none"); assertEquals(far.reason, "no_candidate");
});

Deno.test("2 件以上: ぴったり同じ出金が 2 件 → 記録しない（同じ日でも、日付が違っても）", () => {
  const a = judgeMfTotal(batch, [out("J1"), out("J2")], opts);
  assertEquals(a.decision, "none"); assertEquals(a.reason, "multiple_candidates"); assertEquals(a.pick, null);
  const b = judgeMfTotal(batch, [out("J1"), out("J2", { transaction_date: "2031-10-17" })], opts);
  assertEquals(b.reason, "multiple_candidates");
  const c = judgeMfTotal(batch, [out("J1", { branch_no: 0 }), out("J1", { branch_no: 1 })], opts);   // 同じ仕訳の 2 行でも 2 件と数える
  assertEquals(c.reason, "multiple_candidates");
});

Deno.test("出金口座が未登録 → 記録しない（空・配列でない・空文字だけ、も未登録）", () => {
  for (const d of [undefined, [], "普通預金", [""], [null], {}]) {
    const j = judgeMfTotal(batch, [out("J1")], { depositAccounts: d });
    assertEquals(j.decision, "none"); assertEquals(j.reason, "deposit_account_not_configured");
  }
});

Deno.test("出金口座が違う・預金の名前が取れない → 記録しない", () => {
  assertEquals(judgeMfTotal(batch, [out("J1", { deposit_account: "普通預金/べつの銀行" })], opts).reason, "deposit_account_mismatch");
  assertEquals(judgeMfTotal(batch, [out("J1", { deposit_account: "" })], opts).reason, "deposit_account_mismatch");
  // 別の口座のぴったりの出金は数えない: 登録した口座の 1 件だけが候補
  const j = judgeMfTotal(batch, [out("J1"), out("J2", { deposit_account: "普通預金/べつの銀行" })], opts);
  assertEquals(j.decision, "record"); assertEquals(j.pick?.journal_id, "J1");
});

Deno.test("手数料が混ざって合わない → 記録しない（少しだけ多いときは「手数料の疑い」）", () => {
  const fee = judgeMfTotal(batch, [out("J1", { amount: 1234567 + 3300 })], opts);
  assertEquals(fee.decision, "none"); assertEquals(fee.reason, "amount_mismatch_fee_suspected");
  assertEquals(judgeMfTotal(batch, [out("J1", { amount: 1234567 - 1 })], opts).reason, "amount_mismatch");            // 少ない
  assertEquals(judgeMfTotal(batch, [out("J1", { amount: 1234567 + 500000 })], opts).reason, "amount_mismatch");       // 大きくちがう
  assertEquals(judgeMfTotal({ ...batch, expected_count: undefined }, [out("J1", { amount: 1234567 + 3300 })], opts).reason, "amount_mismatch_fee_suspected");
  // 1 円でも違えば記録しない
  assertEquals(judgeMfTotal(batch, [out("J1", { amount: 1234568 })], opts).decision, "none");
});

Deno.test("日付: 金額がぴったりの 1 件でも、取引日が振込指定日と違えば記録しない", () => {
  const j = judgeMfTotal(batch, [out("J1", { transaction_date: "2031-10-16" })], opts);
  assertEquals(j.decision, "none"); assertEquals(j.reason, "date_mismatch"); assertEquals(j.candidates[0].day_diff, 1);
});

Deno.test("バッチが読めない・出金の行がこわれている → 記録しない（落ちない）", () => {
  assertEquals(judgeMfTotal({ batch_id: "x", scheduled_date: "2031-10", expected_total: 100 }, [out("J1")], opts).reason, "invalid_batch");
  assertEquals(judgeMfTotal({ batch_id: "x", scheduled_date: "2031-10-15", expected_total: 0 }, [out("J1")], opts).reason, "invalid_batch");
  const bad = [out("", {}), out("J2", { amount: NaN }), out("J3", { transaction_date: "x" }), out("J4", { amount: -5 })];
  assertEquals(judgeMfTotal(batch, bad, opts).reason, "no_candidate");
  // 数字が文字で来ても比べられる（DB の numeric が文字で返る場合）
  // deno-lint-ignore no-explicit-any
  assertEquals(judgeMfTotal({ ...batch, expected_total: "1234567" as any }, [out("J1")], opts).decision, "record");
});

Deno.test("fetchOutflows の summary から、預金側の「科目名/補助科目名」を取り出す", () => {
  assertEquals(depositAccountFromSummary("未払金/給料 1,234,567円 ／ 普通預金/テスト銀行 本店 1,234,567円"), "普通預金/テスト銀行 本店");
  assertEquals(depositAccountFromSummary("未払金 1,000円 ／ 普通預金 1,000円"), "普通預金");
  assertEquals(depositAccountFromSummary("— ／ 当座預金/A 5円"), "当座預金/A");
  assertEquals(depositAccountFromSummary("未払金 1,000円"), "");
  assertEquals(depositAccountFromSummary(null), "");
});

Deno.test("toMfOutflows: 同じ仕訳の中の順番（0 始まり）を付ける。もとの配列は変えない", () => {
  const src = [
    { journal_id: "J1", transaction_date: "2031-10-15", amount: 100, remark: "WEB総振", summary: "未払金 100円 ／ 普通預金/テスト銀行 本店 100円", account: "未払金", sub: "", partner: "" },
    { journal_id: "J1", transaction_date: "2031-10-15", amount: 200, remark: "WEB総振", summary: "未払金 200円 ／ 普通預金/テスト銀行 本店 200円", account: "未払金", sub: "", partner: "" },
    { journal_id: "J2", transaction_date: "2031-10-15", amount: 300, remark: "", summary: "x", account: "", sub: "", partner: "" },
  ];
  const copy = JSON.stringify(src);
  const r = toMfOutflows(src);
  assertEquals(r.map((x) => [x.journal_id, x.branch_no, x.deposit_account]), [["J1", 0, DEP], ["J1", 1, DEP], ["J2", 0, ""]]);
  assertEquals(JSON.stringify(src), copy);
});

Deno.test("期間と、理由の言葉（金額を含まない）", () => {
  assertEquals(scanRange("2031-10-15", 3), { start: "2031-10-12", end: "2031-10-18" });
  assertEquals(scanRange("2031-11-01", 3), { start: "2031-10-29", end: "2031-11-04" });
  for (const r of ["matched_one", "no_candidate", "deposit_account_not_configured", "deposit_account_mismatch", "amount_mismatch", "amount_mismatch_fee_suspected", "multiple_candidates", "date_mismatch", "invalid_batch", "mf_journal_used_by_other_batch", "tenant_unknown", "mf_fetch_failed", "db_error"]) {
    const t = reasonText(r); assert(t !== r && t.length > 5, r); assert(!/[0-9]{4,}/.test(t), r);
  }
  assertEquals(reasonText("なにか"), "なにか");
});
