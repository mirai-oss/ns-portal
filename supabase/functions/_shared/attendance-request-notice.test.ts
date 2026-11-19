// フォームの勤怠申請の新しい形（親 1 行＋スレッド＋修正前後のカード）のテスト。deno test supabase/functions/_shared/
import { assert, assertEquals } from "jsr:@std/assert@1";
import { parseFlow, compareTimes, compareLines, durText, minutesOf, requestState, viewFromRpc, requestParent, requestCard, nextActors, askText, eventLine, requestReminderText, dmLinkText,
  postRequest, renderRequest, afterRequestDecide, remindRequestInThread, requestCase, flowSettings, type RequestView } from "./attendance-request-notice.ts";

const RID = "11111111-1111-4111-8111-111111111111";
const U = { target: "aaaaaaaa-0000-4000-8000-000000000001", requester: "aaaaaaaa-0000-4000-8000-000000000002", first: "aaaaaaaa-0000-4000-8000-000000000003", boss: "aaaaaaaa-0000-4000-8000-000000000004" };
// 11/14（土）17:00−22:00・休憩なし → 退勤 23:30・休憩 20:00−20:30
const rpc = (over: Record<string, unknown> = {}, extra: Record<string, unknown> = {}) => ({
  request: {
    id: RID, kind: "fix", status: "pending", work_date: "2026-11-14", store_id: "bbbbbbbb-0000-4000-8000-000000000001", user_id: U.target, requested_by: U.requester, requested_at: "2026-11-15T01:02:00Z",
    reason: "退勤の打刻を忘れた", before: { clock_in: "2026-11-14T08:00:00+00:00", clock_out: "2026-11-14T13:00:00+00:00", break_start_1: null, break_end_1: null, break_start_2: null, break_end_2: null, worked_minutes: 300, break_minutes: 0 },
    clock_in: "2026-11-14T08:00:00+00:00", clock_out: "2026-11-14T14:30:00+00:00", break_start_1: "2026-11-14T11:00:00+00:00", break_end_1: "2026-11-14T11:30:00+00:00", break_start_2: null, break_end_2: null,
    decided_by: null, decided_at: null, decision_note: null, smaregi_sync_status: null, smaregi_error: null, ...over,
  },
  store_name: "鳥一代 本店",
  names: { [U.target]: "山田太郎", [U.requester]: "店長 花子", [U.first]: "チーム長 次郎", [U.boss]: "社長" },
  slack: { [U.requester]: "U0REQUEST1", [U.first]: "U0FIRST001", [U.boss]: "U0BOSS0001" },
  masters: [{ user_id: U.boss, slack_user_id: "U0BOSS0001" }], presidents: [{ user_id: U.boss, slack_user_id: "U0BOSS0001" }],
  source: { state: "same" }, ...extra,
});
const view = (over: Record<string, unknown> = {}, extra: Record<string, unknown> = {}): RequestView => viewFromRpc(rpc(over, extra))!;
// deno-lint-ignore no-explicit-any
const btns = (blocks: unknown[]) => (blocks as any[]).filter((b) => b.type === "actions").flatMap((b) => b.elements.map((e: any) => e.action_id));
// deno-lint-ignore no-explicit-any
const body = (blocks: unknown[]) => (blocks as any[]).filter((b) => b.type === "section").map((b) => b.text.text).join("\n");

Deno.test("スイッチ: はっきり true のときだけ ON。2 段階は、スレッドが ON のときだけ働く", () => {
  assertEquals(parseFlow(null), { thread: false, twoStage: false, presidentDm: true });
  assertEquals(parseFlow({ thread: "true", two_stage: 1 }), { thread: false, twoStage: false, presidentDm: true });
  assertEquals(parseFlow({ thread: false, two_stage: true }), { thread: false, twoStage: false, presidentDm: true });
  assertEquals(parseFlow({ thread: true, two_stage: false, president_dm: false }), { thread: true, twoStage: false, presidentDm: false });
  assertEquals(parseFlow({ thread: true, two_stage: true }), { thread: true, twoStage: true, presidentDm: true });
});

Deno.test("比較: 出勤・退勤・休憩・実働を並べ、変わった項目だけに印。変わらない項目は短く", () => {
  const v = view();
  const c = compareTimes(v.before, v.after, v.workDate);
  assertEquals(c.rows.map((r) => [r.label, r.before, r.after, r.changed]), [
    ["出勤", "17:00", "17:00", false], ["退勤", "22:00", "23:30", true], ["休憩", "なし", "30分", true], ["実働", "5時間00分", "6時間00分", true]]);
  assertEquals(c.delta, "+1時間00分");
  assertEquals(compareLines(c), ["出勤：17:00（変更なし）", "🔸 *退勤：22:00 → 23:30*", "🔸 *休憩：なし → 30分*", "　└ 修正後 20:00−20:30", "🔸 *実働：5時間00分 → 6時間00分*", "実働の増減：+1時間00分"]);
});

Deno.test("比較: 打刻漏れは「未打刻」。勤怠追加は、修正前が全部「未打刻」", () => {
  const miss = view({ before: { clock_in: "2026-11-14T08:00:00+00:00", clock_out: null } });
  const c = compareTimes(miss.before, miss.after, miss.workDate);
  assertEquals(c.rows[1], { key: "out", label: "退勤", before: "未打刻", after: "23:30", changed: true, detail: [] });
  assertEquals([c.rows[3].before, c.rows[3].after, c.delta], ["—", "6時間00分", "—（修正前が未打刻）"]);
  const add = view({ kind: "add", before: null });
  assertEquals(add.before, null);
  const lines = compareLines(compareTimes(add.before, add.after, add.workDate));
  assertEquals(lines[0], "🔸 *出勤：未打刻 → 17:00*");
  assertEquals(lines[1], "🔸 *退勤：未打刻 → 23:30*");
});

Deno.test("比較: 休憩が複数あるときは内訳が出る。実働が減るとき・翌日の退勤・秒だけの違い", () => {
  const two = view({ break_start_2: "2026-11-14T13:00:00+00:00", break_end_2: "2026-11-14T13:15:00+00:00" });
  const c = compareTimes(two.before, two.after, two.workDate);
  assertEquals(c.rows[2].after, "45分");
  assertEquals(c.rows[2].detail, ["修正後 ①20:00−20:30 ②22:00−22:15"]);
  // 休憩 2 回のまま変わらない申請（退勤だけ変える）でも、内訳は見える
  const b2 = { clock_in: "2026-11-14T08:00:00Z", clock_out: "2026-11-14T13:00:00Z", break_start_1: "2026-11-14T09:00:00Z", break_end_1: "2026-11-14T09:30:00Z", break_start_2: "2026-11-14T11:00:00Z", break_end_2: "2026-11-14T11:15:00Z" };
  const same = compareTimes(b2, { ...b2, clock_out: "2026-11-14T12:00:00Z" }, "2026-11-14");
  assertEquals([same.rows[2].changed, same.rows[2].detail], [false, ["①18:00−18:30 ②20:00−20:15"]]);
  assertEquals(same.delta, "−1時間00分");
  // 翌日の退勤は「翌」
  assertEquals(compareTimes(b2, { ...b2, clock_out: "2026-11-14T16:30:00Z" }, "2026-11-14").rows[1].after, "翌01:30");
  // 秒だけの違いは、変更なし
  assertEquals(compareTimes(b2, { ...b2, clock_out: "2026-11-14T13:00:40Z" }, "2026-11-14").anyChange, false);
  assertEquals([durText(45), durText(60), durText(-90)], ["45分", "1時間00分", "1時間30分"]);
  assertEquals(minutesOf({ clock_in: "2026-11-14T08:00:00Z", clock_out: null }).work, null);
});

Deno.test("状態: 社長の指示の 8 つの言葉（＋一次承認者が未設定の確認待ち・今までの承認待ち）", () => {
  const s = (o: Record<string, unknown>) => { const r = requestState({ status: "pending", ...o } as never); return [r.code, r.label, r.mark, r.done]; };
  assertEquals(s({}), ["pending", "承認待ち", "📝", false]);
  assertEquals(s({ flow: "two_stage", stage: "first_wait" }), ["first_wait", "一次承認待ち", "📝", false]);
  assertEquals(s({ flow: "two_stage", stage: "asking" }), ["asking", "本人確認中", "📝", false]);
  assertEquals(s({ flow: "two_stage", stage: "returned" }), ["returned", "差戻し", "📝", false]);
  assertEquals(s({ flow: "two_stage", stage: "final_wait" }), ["final_wait", "最終承認待ち", "📝", false]);
  assertEquals(s({ flow: "two_stage", stage: "hold" }), ["hold", "確認待ち（一次承認者が未設定）", "🕒", false]);
  assertEquals(s({ status: "approved" }), ["sync_wait", "承認済み・スマレジ反映待ち", "📝", false]);
  assertEquals(s({ status: "approved", smaregi: "pending" }), ["sync_wait", "承認済み・スマレジ反映待ち", "📝", false]);
  assertEquals(s({ status: "approved", smaregi: "synced" }), ["synced", "同期済み", "✅", true]);
  assertEquals(s({ status: "approved", smaregi: "failed" }), ["sync_error", "同期エラー", "🔴", false]);
  assertEquals(s({ status: "rejected" }), ["rejected", "却下", "✅", true]);
  // stage が入っていても、flow が無ければ今までの 1 段階の扱い
  assertEquals(s({ stage: "first_wait" })[0], "pending");
});

Deno.test("親メッセージは 1 行だけ。店舗は出す。時刻・理由・承認のボタンは出さない。完了したら「詳細を確認」を外す", () => {
  const p = requestParent(view(), { permalink: "https://x.slack.com/archives/C1/p1" });
  assertEquals(p.text, "📝 勤怠修正｜山田太郎｜鳥一代 本店｜11/14｜承認待ち");
  assertEquals(btns(p.blocks), ["attendance.alert.open"]);
  assert(!p.text.includes("17:00") && !p.text.includes("打刻") && p.text.includes("鳥一代 本店"));   // 2026-11-19 どの店舗かは出す
  assertEquals(btns(requestParent(view()).blocks), []);
  assertEquals(requestParent(view({ kind: "add", before: null })).text, "📝 勤怠追加｜山田太郎｜鳥一代 本店｜11/14｜承認待ち");
  assertEquals(requestParent(view({ flow: "two_stage", stage: "final_wait" })).text, "📝 勤怠修正｜山田太郎｜鳥一代 本店｜11/14｜最終承認待ち");
  assertEquals(requestParent(view({ status: "approved", smaregi_sync_status: "failed" })).text, "🔴 勤怠修正｜山田太郎｜鳥一代 本店｜11/14｜同期エラー");
  const done = requestParent(view({ status: "approved", smaregi_sync_status: "synced" }), { permalink: "https://x.slack.com/a" });
  assertEquals([done.text, btns(done.blocks)], ["✅ 勤怠修正｜山田太郎｜鳥一代 本店｜11/14｜同期済み", []]);
});

Deno.test("カード（今までの 1 段階）: 店舗・対象・勤務日・申請者・理由・比較・状況。ボタンは今ある承認と却下", () => {
  const c = requestCard(view(), { notificationId: "n1" });
  const t = body(c.blocks);
  for (const x of ["【勤怠修正の申請】", "店舗：鳥一代 本店", "対象：山田太郎", "勤務日：11/14（土）", "申請：店長 花子（11/15 10:02）", "理由：退勤の打刻を忘れた", "*修正前 → 修正後*", "🔸 *退勤：22:00 → 23:30*", "実働の増減：+1時間00分", "状況：🟡 承認待ち"]) assert(t.includes(x), x);
  assert(!t.includes("一次承認者"));
  assertEquals(btns(c.blocks), ["attendance.request.approve", "attendance.request.reject"]);
  // deno-lint-ignore no-explicit-any
  assertEquals(JSON.parse((c.blocks as any[])[1].elements[0].value), { request_id: RID, notification_id: "n1" });
  // 1 行は短く（スマートフォンで折り返しにくい）: 比較の行は 30 文字以内
  for (const line of compareLines(compareTimes(view().before, view().after, "2026-11-14"))) assert([...line].length <= 30, line);
});

Deno.test("カード: 承認・却下・スマレジの結果では、ボタンを外して結果を出す。承認済みと同期済みを区別する", () => {
  const ap = requestCard(view({ status: "approved", decided_by: U.boss, decided_at: "2026-11-15T04:05:00Z" }), { notificationId: "n1" });
  assert(body(ap.blocks).includes("状況：🟡 承認済み・スマレジ反映待ち") && body(ap.blocks).includes("承認：社長・11/15 13:05"));
  assertEquals(btns(ap.blocks), []);
  const ok = body(requestCard(view({ status: "approved", decided_by: U.boss, smaregi_sync_status: "synced" }), { notificationId: "n1" }).blocks);
  assert(ok.includes("状況：✅ 同期済み") && ok.includes("スマレジ：✅ 反映済み"));
  const ng = requestCard(view({ status: "approved", decided_by: U.boss, smaregi_sync_status: "failed", smaregi_error: "HTTP 409 締め済み" }), { notificationId: "n1" });
  assert(body(ng.blocks).includes("状況：🔴 同期エラー") && body(ng.blocks).includes("反映に失敗（HTTP 409 締め済み）"));
  assertEquals(btns(ng.blocks), []);   // 今までの 1 段階には、再実行のボタンは無い
  const rj = body(requestCard(view({ status: "rejected", decided_by: U.boss, decided_at: "2026-11-15T04:05:00Z", decision_note: "時刻が違う" }), { notificationId: "n1" }).blocks);
  assert(rj.includes("状況：✅ 却下（社長・11/15 13:05）") && rj.includes("却下の理由：時刻が違う"));
});

Deno.test("カード: 元データが変わっていたら、注意を出す（承認待ちのあいだだけ）", () => {
  assert(body(requestCard(view({}, { source: { state: "changed" } }), { notificationId: "n1" }).blocks).includes("⚠️ 申請のあとに、元の打刻が変わっています"));
  assert(body(requestCard(view({}, { source: { state: "gone" } }), { notificationId: "n1" }).blocks).includes("元の勤怠が無くなっています"));
  assert(body(requestCard(view({ kind: "add", before: null }, { source: { state: "appeared" } }), { notificationId: "n1" }).blocks).includes("この日の打刻が登録されています"));
  assert(!body(requestCard(view({ status: "approved" }, { source: { state: "changed" } }), { notificationId: "n1" }).blocks).includes("⚠️ 申請のあとに"));
});

Deno.test("カード（2 段階）: 状態ごとに、いま押せるボタンだけ。一次承認者と状況を出す", () => {
  const two = (o: Record<string, unknown>) => requestCard(view({ flow: "two_stage", first_approver_id: U.first, ...o }), { notificationId: "n1" });
  const f = two({ stage: "first_wait" });
  assertEquals(btns(f.blocks), ["attendance.req.first.approve", "attendance.req.return", "attendance.req.reject", "attendance.req.ask", "attendance.req.open"]);
  assert(body(f.blocks).includes("一次承認者：チーム長 次郎") && body(f.blocks).includes("状況：🟡 一次承認待ち"));
  assertEquals(btns(two({ stage: "asking" }).blocks), ["attendance.req.first.approve", "attendance.req.return", "attendance.req.reject", "attendance.req.open"]);
  const fin = two({ stage: "final_wait", first_decided_by: U.first, first_decided_at: "2026-11-15T02:20:00Z" });
  assertEquals(btns(fin.blocks), ["attendance.req.final.approve", "attendance.req.return", "attendance.req.reject", "attendance.req.open"]);
  assert(body(fin.blocks).includes("（一次承認 チーム長 次郎・11/15 11:20）") && body(fin.blocks).includes("状況：🟡 最終承認待ち"));
  const ret = two({ stage: "returned", returned_by: U.first, returned_at: "2026-11-15T02:20:00Z", return_note: "退勤は 23:00 のはず" });
  assertEquals(btns(ret.blocks), ["attendance.req.open"]);
  // deno-lint-ignore no-explicit-any
  const open = (ret.blocks as any[])[1].elements[0];
  assert(open.url.endsWith("kintai.html?req=" + RID) && open.text.text === "✏️ 直して出し直す");
  assert(body(ret.blocks).includes("差戻しの理由：退勤は 23:00 のはず"));
  const hold = two({ stage: "hold", first_approver_id: null });
  assertEquals(btns(hold.blocks), []);
  assert(body(hold.blocks).includes("一次承認者：未設定") && body(hold.blocks).includes("状況：🕒 確認待ち（一次承認者が未設定）"));
  assert(body(two({ stage: "final_wait", first_skipped: true }).blocks).includes("一次承認者：省略（一次承認者 本人の申請）"));
  assertEquals(btns(two({ status: "approved", stage: null, smaregi_sync_status: "failed" }).blocks), ["attendance.req.sync.retry"]);
  assertEquals(btns(two({ status: "approved", stage: null, smaregi_sync_status: "synced" }).blocks), []);
  assertEquals(btns(two({ status: "rejected", stage: "first_wait" }).blocks), []);
});

Deno.test("知らせる相手: 状態ごとに「次に動く人」だけ。Slack 未連携でも相手を広げない。社長への DM はリンクだけ", () => {
  assertEquals(askText(view()), "<@U0BOSS0001>　承認をお願いします。上のカードの［承認］か［却下］を押してください。");
  const f = view({ flow: "two_stage", stage: "first_wait", first_approver_id: U.first });
  assertEquals([nextActors(f).slackIds, nextActors(f).dmUserIds], [["U0FIRST001"], []]);
  const fin = view({ flow: "two_stage", stage: "final_wait", first_approver_id: U.first });
  assertEquals([nextActors(fin).slackIds, nextActors(fin).dmUserIds], [["U0BOSS0001"], [U.boss]]);
  assert(askText(fin).startsWith("<@U0BOSS0001>　一次承認が済みました。最終承認をお願いします。"));
  assertEquals(nextActors(view({ flow: "two_stage", stage: "returned" })).slackIds, ["U0REQUEST1"]);
  // 一次承認者が Slack 未連携: だれにもメンションしない（ほかの人へ広げない）
  const un = viewFromRpc({ ...rpc({ flow: "two_stage", stage: "first_wait", first_approver_id: U.first }), slack: {} })!;
  assertEquals(nextActors(un).slackIds, []);
  assert(askText(un).includes("Slack と紐付いていない") && !askText(un).includes("<@"));
  assertEquals(askText(view({ status: "approved", smaregi_sync_status: "synced" })), "");
  const dm = dmLinkText(fin, "https://x.slack.com/archives/C1/p1");
  assert(dm.includes("最終承認の依頼") && dm.includes("<https://x.slack.com/archives/C1/p1|スレッドを開く>") && dm.includes("山田太郎・11/14"));
  assert(requestReminderText(fin, { n: 2, age: "13時間" }).includes("⏰ リマインド（2回目）　最終承認待ちのままです（13時間）"));
});

Deno.test("スレッドの行: だれが・いつ・何を・理由", () => {
  assertEquals(eventLine("approved", { actor: "社長", at: "2026-11-15T04:05:00Z" }), "✅ 承認（社長・11/15 13:05）→ スマレジへ反映します");
  assertEquals(eventLine("rejected", { actor: "社長", at: "2026-11-15T04:05:00Z", note: "時刻が違う" }), "❌ 却下（社長・11/15 13:05）　理由：時刻が違う");
  assertEquals(eventLine("returned", { actor: "チーム長 次郎", note: "退勤は 23:00" }), "↩️ 差戻し（チーム長 次郎）　理由：退勤は 23:00");
  assertEquals(eventLine("sync_ok"), "🔄 スマレジへ反映しました");
  assertEquals(eventLine("sync_failed", { note: "HTTP 409" }), "🔴 スマレジへ反映できませんでした：HTTP 409");
  assert(eventLine("final_approved", { actor: "社長" }).startsWith("✅ 最終承認（社長）"));
});

// ---- 送る処理（にせものの DB と Slack で確かめる） ----
type Sent = Record<string, unknown>;
function fakes(o: { view?: unknown; refs?: Record<string, unknown> | null; flow?: unknown; failCard?: boolean } = {}) {
  const sent: Sent[] = []; const upserts: Record<string, unknown>[] = [];
  let current: unknown = o.view ?? rpc();
  const state = { refs: o.refs ?? null as Record<string, unknown> | null };
  const sb = {
    // deno-lint-ignore no-explicit-any
    from: (t: string): any => {
      const q = { select: () => q, eq: () => q, maybeSingle: () => Promise.resolve({ data: t === "app_settings" ? { value: o.flow ?? { thread: true } } : t === "notice_cases" ? (state.refs ? { slack_refs: state.refs } : null) : null }) };
      return q;
    },
    rpc: (name: string, args: Record<string, unknown>) => {
      if (name === "sf_attendance_request_view") return Promise.resolve({ data: current, error: null });
      if (name === "notice_case_upsert") { upserts.push(args); const p = (args.p_patch as Record<string, unknown>).slack_refs as Record<string, unknown> | undefined; if (p) state.refs = { ...(state.refs ?? {}), ...p }; return Promise.resolve({ data: {}, error: null }); }
      return Promise.resolve({ data: null, error: { message: "unknown rpc " + name } });
    },
  };
  let n = 0;
  const notify = (b: Sent) => {
    sent.push(b);
    if (b.action === "update") return Promise.resolve({ ok: true });
    if (o.failCard && b.event === "attendance_request_card") return Promise.resolve({ ok: false, error: "x" });
    n++;
    return Promise.resolve({ ok: true, notification_id: (b.notification_id as string) ?? `auto-${n}`, ts: `100.${n}`, slack_channel_id: "C1" });
  };
  return { sb, notify, sent, upserts, set: (v: unknown) => { current = v; }, refs: () => state.refs };
}
const REFS = { parent: "p-1", card: "c-1", ts: "100.1", channel_key: "kintai.check", permalink: "https://x.slack.com/archives/C1/p1" };

Deno.test("出す: 親 1 つ → スレッドにカード → 控え → 承認者へスレッドで知らせる＋リンクだけの DM。親には申請 id の鍵（2 回目は作らない）", async () => {
  const f = fakes();
  const r = await postRequest(f.sb, f.notify, RID, { source: "test" });
  assertEquals(r.ok, true);
  const sends = f.sent.filter((s) => s.action === "send");
  assertEquals(sends.map((s) => s.event), ["attendance_request_parent", "attendance_request_card", "attendance_request_ask", "attendance_request_dm"]);
  assertEquals([sends[0].channel_key, sends[0].thread_ts, sends[0].dedupe_key, sends[0].text], ["kintai.check", undefined, `attendance_req_parent:${RID}`, "📝 勤怠修正｜山田太郎｜鳥一代 本店｜11/14｜承認待ち"]);
  assertEquals([sends[1].thread_ts, sends[1].dedupe_key], ["100.1", `attendance_req_card:${RID}`]);
  assertEquals([sends[2].thread_ts, sends[2].channel_key], ["100.1", "kintai.check"]);
  assert(String(sends[2].text).startsWith("<@U0BOSS0001>"));
  // DM は社長あて・リンクだけ（ボタンのブロックは無い）
  assertEquals([sends[3].channel_key, sends[3].blocks, sends[3].thread_ts], [`user:${U.boss}`, undefined, undefined]);
  // 控え: 親・カード・スレッドの場所
  const refs = f.refs()!;
  assertEquals([refs.ts, refs.channel_key, typeof refs.parent, typeof refs.card], ["100.1", "kintai.check", "string", "string"]);
  assertEquals((f.upserts[0].p_patch as Record<string, unknown>).status_code, "waiting");
  // 親 1 つだけ（スレッド外への send は、親と DM だけ）
  assertEquals(sends.filter((s) => !s.thread_ts && String(s.channel_key) === "kintai.check").length, 1);
});

Deno.test("出す: DM を止める設定のとき、DM は送らない。カードを送れなかったら失敗を返す（呼び出し側が今までの通知へ進む）", async () => {
  const f = fakes({ flow: { thread: true, president_dm: false } });
  await postRequest(f.sb, f.notify, RID, { source: "test" });
  assertEquals(f.sent.filter((s) => s.event === "attendance_request_dm").length, 0);
  const g = fakes({ failCard: true });
  const r = await postRequest(g.sb, g.notify, RID, { source: "test" });
  assertEquals([r.ok, g.refs()], [false, null]);
});

Deno.test("今までの形の申請（控えなし）: 何も送らず false を返す＝呼び出し側の今までの処理が動く", async () => {
  const f = fakes({ refs: null });
  assertEquals(await requestCase(f.sb, RID), null);
  assertEquals((await renderRequest(f.sb, f.notify, RID)).v2, false);
  assertEquals(await afterRequestDecide(f.sb, f.notify, RID, { approve: true, source: "test", smaregiFix: () => { throw new Error("呼ばれてはいけない"); } }), false);
  assertEquals((await remindRequestInThread(f.sb, f.notify, { requestId: RID, n: 1, since: new Date().toISOString() })).v2, false);
  assertEquals(f.sent.length, 0);
  assertEquals(await requestCase(f.sb, "x"), null);
});

Deno.test("承認のあと: スレッドに承認の行 → スマレジへ送る → 親とカードを書き換え → 結果の行。親は増えない", async () => {
  const f = fakes({ refs: REFS, view: rpc({ status: "approved", decided_by: U.boss, decided_at: "2026-11-15T04:05:00Z" }) });
  let called = 0;
  const done = await afterRequestDecide(f.sb, f.notify, RID, { approve: true, source: "test", smaregiFix: (id) => { called++; assertEquals(id, RID); f.set(rpc({ status: "approved", decided_by: U.boss, decided_at: "2026-11-15T04:05:00Z", smaregi_sync_status: "synced" })); return Promise.resolve({ ok: true }); } });
  assertEquals([done, called], [true, 1]);
  const sends = f.sent.filter((s) => s.action === "send");
  assertEquals(sends.map((s) => s.text), ["✅ 承認（社長・11/15 13:05）→ スマレジへ反映します", "🔄 スマレジへ反映しました"]);
  assert(sends.every((s) => s.thread_ts === "100.1"));
  const parents = f.sent.filter((s) => s.action === "update" && s.notification_id === "p-1").map((s) => s.text);
  assertEquals(parents, ["📝 勤怠修正｜山田太郎｜鳥一代 本店｜11/14｜承認済み・スマレジ反映待ち", "✅ 勤怠修正｜山田太郎｜鳥一代 本店｜11/14｜同期済み"]);
});

Deno.test("承認のあと、スマレジに失敗: 親は「同期エラー」・スレッドに失敗の行（担当にメンション）。却下のときはスマレジへ送らない", async () => {
  const f = fakes({ refs: REFS, view: rpc({ status: "approved", decided_by: U.boss }) });
  await afterRequestDecide(f.sb, f.notify, RID, { approve: true, source: "test", smaregiFix: () => { f.set(rpc({ status: "approved", decided_by: U.boss, smaregi_sync_status: "failed", smaregi_error: "HTTP 409" })); return Promise.resolve({ ok: false, error: "HTTP 409" }); } });
  const last = f.sent.filter((s) => s.action === "send").pop()!;
  assertEquals(last.text, "<@U0BOSS0001>　🔴 スマレジへ反映できませんでした：HTTP 409");
  assertEquals(f.sent.filter((s) => s.action === "update" && s.notification_id === "p-1").pop()!.text, "🔴 勤怠修正｜山田太郎｜鳥一代 本店｜11/14｜同期エラー");
  const g = fakes({ refs: REFS, view: rpc({ status: "rejected", decided_by: U.boss, decision_note: "時刻が違う" }) });
  await afterRequestDecide(g.sb, g.notify, RID, { approve: false, source: "test", smaregiFix: () => { throw new Error("呼ばれてはいけない"); } });
  assertEquals(g.sent.filter((s) => s.action === "send").map((s) => s.text), ["❌ 却下（社長）　理由：時刻が違う"]);
});

Deno.test("リマインド: スレッドへの返信 1 行（親・DM を増やさない）。試し実行では送らない", async () => {
  const f = fakes({ refs: REFS });
  const r = await remindRequestInThread(f.sb, f.notify, { requestId: RID, n: 2, since: new Date(Date.now() - 13 * 3600e3).toISOString() });
  assertEquals([r.v2, r.ok, r.mentions], [true, true, 1]);
  assertEquals(f.sent.length, 1);
  assertEquals([f.sent[0].thread_ts, f.sent[0].channel_key, f.sent[0].dedupe_key], ["100.1", "kintai.check", `remind:sf_attendance_requests:${RID}:2`]);
  assert(String(f.sent[0].text).includes("⏰ リマインド（2回目）　承認待ちのままです（13時間）"));
  const g = fakes({ refs: REFS });
  assertEquals((await remindRequestInThread(g.sb, g.notify, { requestId: RID, n: 1, since: new Date().toISOString(), dryRun: true })).ok, true);
  assertEquals(g.sent.length, 0);
});

Deno.test("スイッチの読み取り: 設定が無い・読めないときは OFF", async () => {
  const none = { from: () => { const q = { select: () => q, eq: () => q, maybeSingle: () => Promise.resolve({ data: null }) }; return q; } };
  assertEquals((await flowSettings(none)).thread, false);
  const broken = { from: () => { throw new Error("x"); } };
  assertEquals(await flowSettings(broken), { thread: false, twoStage: false, presidentDm: true });
});
