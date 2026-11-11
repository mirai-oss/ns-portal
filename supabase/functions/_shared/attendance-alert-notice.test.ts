// 勤怠確認の新しい形（親 1 行＋スレッド）の文面のテスト。deno test supabase/functions/_shared/
import { assert, assertEquals } from "jsr:@std/assert@1";
import { parentMessage, cardMessage, diffLines, punchLine, hm, dateLabel, parentState, approvalAskText, reminderText, renderAlert, afterDecide, afterRequest, remindInThread, postAlert, type AlertView } from "./attendance-alert-notice.ts";

const base: AlertView = {
  alertId: "11111111-1111-4111-8111-111111111111", status: "open", requestKind: "fix", kind: "no_clock_out", reasons: ["退勤打刻なし"],
  workDate: "2026-11-10", storeName: "鳥一代 本店", userName: "山田太郎",
  detected: { clock_in: "2026-11-10T06:00:00Z", clock_out: null }, before: null, proposed: {},
  fixReason: null, requestedByName: null, requestedAt: null, confirmedByName: null, confirmedAt: null, decidedByName: null, decidedAt: null, decisionNote: null,
  smaregi: null, smaregiError: null, test: false,
};
const btns = (blocks: unknown[]) => (blocks as any[]).filter((b) => b.type === "actions").flatMap((b) => b.elements.map((e: any) => e.action_id));
const body = (blocks: unknown[]) => (blocks as any[]).filter((b) => b.type === "section").map((b) => b.text.text).join("\n");

Deno.test("日付と時刻の書き方", () => {
  assertEquals(dateLabel("2026-11-10"), { md: "11/10", mdw: "11/10（火）" });
  assertEquals(hm("2026-11-10T06:00:00Z", "2026-11-10"), "15:00");
  assertEquals(hm("2026-11-10T15:30:00Z", "2026-11-10"), "翌00:30");
  assertEquals(hm(null, "2026-11-10"), null);
  assertEquals(punchLine(base.detected, "2026-11-10"), "出勤 15:00／退勤 未登録／休憩 なし");
});

Deno.test("親メッセージは 1 行だけ。種類・時刻・理由・承認や修正のボタンは出さない", () => {
  const p = parentMessage(base, { permalink: "https://x.slack.com/archives/C1/p1?thread_ts=1" });
  assertEquals(p.text, "🕒 勤怠確認｜山田太郎｜11/10");
  assertEquals(btns(p.blocks), ["attendance.alert.open"]);
  assert(!p.text.includes("打刻") && !p.text.includes("15:00") && !p.text.includes("鳥一代"));
  assertEquals(btns(parentMessage(base).blocks), []);   // リンクが取れなければボタンなし
});

Deno.test("親メッセージで、完了・未完了が分かる", () => {
  assertEquals(parentMessage({ ...base, status: "fix_requested" }).text, "📝 勤怠確認｜山田太郎｜11/10｜承認待ち");
  assertEquals(parentMessage({ ...base, status: "approved", smaregi: "synced" }).text, "✅ 勤怠確認｜山田太郎｜11/10｜完了");
  assertEquals(parentMessage({ ...base, status: "approved", smaregi: "failed" }).text, "🔴 勤怠確認｜山田太郎｜11/10｜要対応");
  assertEquals(parentMessage({ ...base, status: "confirmed" }).text, "✅ 勤怠確認｜山田太郎｜11/10｜完了");
  assertEquals(parentMessage({ ...base, status: "rejected" }).text, "✅ 勤怠確認｜山田太郎｜11/10｜完了（却下）");
  // 完了したら「詳細を確認」ボタンも外す
  assertEquals(btns(parentMessage({ ...base, status: "confirmed" }, { permalink: "https://x.slack.com/a" }).blocks), []);
  assertEquals(parentState({ status: "approved", smaregi: "failed", test: false }).done, false);
});

Deno.test("申請が無いあいだは、承認ボタンを出さない", () => {
  const c = cardMessage(base, { notificationId: "n1" });
  assertEquals(btns(c.blocks), ["attendance.alert.confirm", "attendance.alert.fix", "attendance.alert.delete"]);
  const t = body(c.blocks);
  assert(t.includes("【勤怠確認｜打刻漏れ】") && t.includes("店舗：鳥一代 本店") && t.includes("対象者：山田太郎") && t.includes("対象日：11/10（火）"));
  assert(t.includes("⚠️ 退勤打刻なし") && !t.includes("修正内容"));
  // 「修正する」はフォームを開く url 付きボタン（対象のアラートを引き継ぐ）
  const fix = (c.blocks as any[])[1].elements[1];
  assert(fix.url.endsWith("kintai.html?alert=" + base.alertId));
  assertEquals(JSON.parse(fix.value).form, 1);
});

Deno.test("申請があるとき: 変わった項目だけの差分・理由・申請者を出し、承認と却下を出す", () => {
  const v: AlertView = { ...base, status: "fix_requested", before: { clock_in: "2026-11-10T06:00:00Z", clock_out: null },
    proposed: { clock_in: "2026-11-10T06:00:00Z", clock_out: "2026-11-10T14:30:00Z", break_start_1: "2026-11-10T10:00:00Z", break_end_1: "2026-11-10T11:00:00Z" },
    fixReason: "退勤時の打刻忘れ", requestedByName: "店長 花子", requestedAt: "2026-11-11T10:40:00Z" };
  const c = cardMessage(v, { notificationId: "n1" });
  assertEquals(btns(c.blocks), ["attendance.fix.approve", "attendance.fix.reject"]);
  const t = body(c.blocks);
  assert(t.includes("*【修正内容】*\n退勤：未登録 → 23:30\n休憩：なし → 19:00−20:00"));
  assert(!t.includes("出勤："), "変わっていない出勤は出さない");
  assert(t.includes("理由：退勤時の打刻忘れ") && t.includes("申請：店長 花子（11/11 19:40）") && t.includes("状況：🟡 承認待ち"));
});

Deno.test("承認・却下・確認のあとは、ボタンを出さない（二重に押せない）", () => {
  const req = { ...base, before: base.detected, proposed: { clock_in: "2026-11-10T06:00:00Z", clock_out: "2026-11-10T14:30:00Z" }, fixReason: "打刻忘れ", requestedByName: "店長", requestedAt: "2026-11-11T10:40:00Z", decidedByName: "社長", decidedAt: "2026-11-11T10:45:00Z" };
  for (const v of [{ ...req, status: "approved", smaregi: "pending" }, { ...req, status: "approved", smaregi: "synced" }, { ...req, status: "approved", smaregi: "failed", smaregiError: "HTTP 409" }, { ...req, status: "rejected" }, { ...base, status: "confirmed", confirmedByName: "店長", confirmedAt: "2026-11-11T10:45:00Z" }]) {
    assertEquals(btns(cardMessage(v as AlertView, { notificationId: "n1" }).blocks), []);
  }
  assert(body(cardMessage({ ...req, status: "approved", smaregi: "synced" } as AlertView, { notificationId: "n" }).blocks).includes("状況：✅ 承認（社長・11/11 19:45）\nスマレジ：✅ 反映済み"));
  assert(body(cardMessage({ ...req, status: "approved", smaregi: "failed", smaregiError: "HTTP 409" } as AlertView, { notificationId: "n" }).blocks).includes("スマレジ：⚠️ 反映に失敗（HTTP 409）"));
  assert(body(cardMessage({ ...req, status: "approved", smaregi: "skipped", test: true } as AlertView, { notificationId: "n" }).blocks).includes("テストのため反映していません"));
});

Deno.test("打刻削除の申請", () => {
  const v: AlertView = { ...base, status: "fix_requested", requestKind: "delete", fixReason: "出勤していない", requestedByName: "店長", requestedAt: "2026-11-11T10:40:00Z" };
  const c = cardMessage(v, { notificationId: "n1" });
  assert(body(c.blocks).includes("打刻の削除（この日の勤務を取り消す）"));
  assertEquals((c.blocks as any[])[1].elements[0].text.text, "✅ 承認して削除");
});

Deno.test("差分: 変更なしは空・休憩 2 があるときは番号つき", () => {
  const t = { clock_in: "2026-11-10T06:00:00Z", clock_out: "2026-11-10T14:30:00Z" };
  assertEquals(diffLines(t, { ...t }, "2026-11-10"), []);
  assertEquals(diffLines(t, { ...t, clock_in: "2026-11-10T06:00:30Z" }, "2026-11-10"), []);   // 秒の違いは無視
  assertEquals(diffLines({ ...t, break_start_1: "2026-11-10T08:00:00Z", break_end_1: "2026-11-10T08:30:00Z" }, { ...t, break_start_1: "2026-11-10T08:00:00Z", break_end_1: "2026-11-10T08:30:00Z", break_start_2: "2026-11-10T10:00:00Z", break_end_2: "2026-11-10T10:15:00Z" }, "2026-11-10"), ["休憩2：なし → 19:00−19:15"]);
});

Deno.test("メンションは Slack の ID だけ・同じ人は 1 回", () => {
  assertEquals(approvalAskText(["U0123456", "U0123456", "", null, "bad"], false), "<@U0123456>　修正の申請があります。上の内容を確認して、［承認］か［却下］を押してください。");
  assert(reminderText([], { n: 2, age: "1日", approval: false }).startsWith("⏰ リマインド（2回目）"));
});

// ---- 読んで・書き換える処理（にせものの DB と送信で確かめる） ----
function fake(o: { caseRefs?: Record<string, unknown> | null; alert?: Record<string, unknown>; labor?: Record<string, unknown> }) {
  const sent: Record<string, unknown>[] = []; const upd: Record<string, unknown>[] = []; const rpcs: { fn: string; args: any }[] = [];
  const q = (table: string) => {
    const b: any = {
      select: () => b, eq: () => b, in: () => b, limit: () => b,
      update: (x: Record<string, unknown>) => { upd.push({ table, ...x }); if (table === "sf_attendance_alerts" && o.alert) Object.assign(o.alert, x); return b; },
      maybeSingle: () => Promise.resolve({ data: table === "notice_cases" ? (o.caseRefs ? { slack_refs: o.caseRefs } : null) : table === "sf_attendance_alerts" ? (o.alert ?? null) : table === "labor_cost_daily" ? (o.labor ?? null) : table === "stores" ? { name: "鳥一代 本店" } : null }),
      then: (res: (v: unknown) => void) => res({ data: table === "users" ? [{ id: "u1", name: "テスト 立会い" }, { id: "m1", name: "社長" }] : table === "user_slack" ? [{ slack_user_id: "U0MASTER1" }] : [] }),
    };
    return b;
  };
  const sb = { from: q, rpc: (fn: string, args: unknown) => { rpcs.push({ fn, args }); if (fn === "notice_case_upsert" && o.caseRefs) Object.assign(o.caseRefs, (args as any).p_patch?.slack_refs ?? {}); return Promise.resolve({ data: fn === "notice_mention_targets" ? { targets: [{ slack_user_id: "U0STAFF01" }] } : {}, error: null }); } };
  const notify = (b: Record<string, unknown>) => { sent.push(b); return Promise.resolve({ ok: true, notification_id: String(b.notification_id ?? "nid-" + sent.length), ts: "1700000000.00" + sent.length, slack_channel_id: "C1" }); };
  return { sb, notify, sent, upd, rpcs };
}
const alertRow = () => ({ id: base.alertId, status: "open", request_kind: "fix", kind: "no_clock_out", reasons: ["退勤打刻なし"], user_id: "u1", store_id: "s1", work_date: "2026-11-10", labor_cost_daily_id: "l1",
  clock_in: "2026-11-10T06:00:00Z", clock_out: null, requested_by: null, requested_at: null, confirmed_by: null, decided_by: null } as Record<string, unknown>);

Deno.test("古い形のアラート（控えなし）には何もしない", async () => {
  const f = fake({ caseRefs: null, alert: alertRow() });
  assertEquals(await renderAlert(f.sb, f.notify, base.alertId), { v2: false });
  assertEquals((await afterRequest(f.sb, f.notify, base.alertId, "t")).v2, false);
  assertEquals(await afterDecide(f.sb, f.notify, base.alertId, true, () => { throw new Error("呼ばれてはいけない"); }), false);
  assertEquals((await remindInThread(f.sb, f.notify, { alertId: base.alertId, approval: false, n: 1, since: new Date().toISOString() })).v2, false);
  assertEquals(f.sent.length, 0);
});

Deno.test("申請のあと: 申請の時点の打刻を控え、カードを書き換え、承認者へスレッドで知らせる", async () => {
  const a = { ...alertRow(), status: "fix_requested", requested_by: "m1", requested_at: "2026-11-11T10:40:00Z", fix_reason: "打刻忘れ", proposed_clock_in: "2026-11-10T06:00:00Z", proposed_clock_out: "2026-11-10T14:30:00Z" };
  const refs: Record<string, unknown> = { parent: "p1", card: "c1", ts: "1.1", channel_key: "kintai.check", permalink: "https://x.slack.com/a" };
  const f = fake({ caseRefs: refs, alert: a, labor: { clock_in: "2026-11-10T06:05:00Z", clock_out: null } });
  const r = await afterRequest(f.sb, f.notify, base.alertId, "t");
  assertEquals(r, { v2: true, approvers: 1 });
  const card = f.sent.find((x) => x.action === "update" && x.notification_id === "c1")!;
  assert(body(card.blocks as unknown[]).includes("出勤：15:05 → 15:00") && body(card.blocks as unknown[]).includes("退勤：未登録 → 23:30"), "差分の左側は、勤怠実績の今の値");
  assertEquals(f.sent.find((x) => x.notification_id === "p1")!.text, "📝 勤怠確認｜テスト 立会い｜11/10｜承認待ち");
  const ask = f.sent.find((x) => x.action === "send")!;
  assertEquals([ask.thread_ts, ask.channel_key], ["1.1", "kintai.check"]);
  assert(String(ask.text).startsWith("<@U0MASTER1>"));
  assertEquals((refs.before as any).clock_in, "2026-11-10T06:05:00Z");
});

Deno.test("承認のあと: テスト用はスマレジへ送らない／通常は送って結果で書き換える", async () => {
  const mk = (test: boolean) => fake({ caseRefs: { parent: "p1", card: "c1", ts: "1.1", channel_key: "kintai.check", test, before: { clock_in: "2026-11-10T06:00:00Z", clock_out: null }, before_key: "2026-11-11T10:40:00Z" },
    alert: { ...alertRow(), status: "approved", requested_by: "m1", requested_at: "2026-11-11T10:40:00Z", decided_by: "m1", decided_at: "2026-11-11T10:45:00Z", proposed_clock_in: "2026-11-10T06:00:00Z", proposed_clock_out: "2026-11-10T14:30:00Z" } });
  const t = mk(true); let called = 0;
  assertEquals(await afterDecide(t.sb, t.notify, base.alertId, true, () => { called++; return Promise.resolve({ ok: true }); }), true);
  assertEquals(called, 0);
  assert(body(t.sent.filter((x) => x.notification_id === "c1").pop()!.blocks as unknown[]).includes("テストのため反映していません"));
  assertEquals(t.sent.filter((x) => x.notification_id === "p1").pop()!.text, "✅ 勤怠確認｜テスト 立会い｜11/10｜完了");
  const n = mk(false);
  await afterDecide(n.sb, n.notify, base.alertId, true, () => { called++; return Promise.resolve({ ok: true }); });
  assertEquals(called, 1);
  assertEquals(n.sent.filter((x) => x.notification_id === "c1").length, 2);   // 反映中 → 結果
});

Deno.test("リマインドはスレッドへの返信（親を増やさない）。未確認＝店舗の担当／承認待ち・テスト＝承認者", async () => {
  const refs = { parent: "p1", card: "c1", ts: "1.1", channel_key: "kintai.check" };
  const f = fake({ caseRefs: refs, alert: alertRow() });
  const since = new Date(Date.now() - 13 * 3600e3).toISOString();
  await remindInThread(f.sb, f.notify, { alertId: base.alertId, approval: false, n: 1, since });
  assertEquals(f.sent.length, 1);
  assertEquals(f.sent[0].thread_ts, "1.1");
  assert(String(f.sent[0].text).startsWith("<@U0STAFF01>　⏰ リマインド（1回目）　まだ確認されていません（13時間）"));
  const g = fake({ caseRefs: { ...refs, test: true }, alert: alertRow() });
  await remindInThread(g.sb, g.notify, { alertId: base.alertId, approval: false, n: 1, since });
  assert(String(g.sent[0].text).startsWith("<@U0MASTER1>"));
  const h = fake({ caseRefs: refs, alert: alertRow() });
  assertEquals(await remindInThread(h.sb, h.notify, { alertId: base.alertId, approval: true, n: 2, since, dryRun: true }), { v2: true, ok: true, mentions: 1 });
  assertEquals(h.sent.length, 0);
});

Deno.test("投稿: 親 1 通 → スレッドにカード 1 通 → 控えを残す", async () => {
  const f = fake({ caseRefs: null });
  const r = await postAlert(f.sb, f.notify, { alertId: base.alertId, userId: "u1", storeId: "s1", workDate: "2026-11-10", userName: "テスト 立会い", storeName: "鳥一代 本店", kind: "no_clock_out", reasons: ["退勤打刻なし"], times: base.detected },
    { channelKey: "kintai.check", test: true, detailButton: false, source: "t" });
  assertEquals([r.ok, r.format], [true, "v2"]);
  assertEquals(f.sent.length, 2);
  assertEquals(f.sent[0].text, "🕒 勤怠確認｜テスト 立会い｜11/10");
  assertEquals(f.sent[0].thread_ts, undefined);
  assertEquals(f.sent[1].thread_ts, "1700000000.001");
  const up = f.rpcs.find((x) => x.fn === "notice_case_upsert")!.args.p_patch;
  assertEquals([up.slack_refs.test, up.slack_refs.channel_key, up.status_code], [true, "kintai.check", "todo"]);
  assertEquals(f.upd.find((x) => x.table === "sf_attendance_alerts")!.notification_ids, [up.slack_refs.parent]);
});
