// 勤怠申請の 2 段階承認の専用の操作のテスト（にせものの DB と Slack）。deno test supabase/functions/_shared/
import { assert, assertEquals } from "jsr:@std/assert@1";
import { actRequest, resubmitRequest, messageRequest, approverSet, reasonModal, reasonFromView, REQ_REASON_MODAL, REQ_ACTIONS } from "./attendance-request-actions.ts";

const RID = "11111111-1111-4111-8111-111111111111";
const U = { target: "aaaaaaaa-0000-4000-8000-000000000001", requester: "aaaaaaaa-0000-4000-8000-000000000002", first: "aaaaaaaa-0000-4000-8000-000000000003", boss: "aaaaaaaa-0000-4000-8000-000000000004" };
const REFS = { parent: "p-1", card: "c-1", ts: "100.1", channel_key: "kintai.check", permalink: "https://x.slack.com/archives/C1/p1" };
const rpcView = (over: Record<string, unknown> = {}) => ({
  request: {
    id: RID, kind: "fix", status: "pending", flow: "two_stage", stage: "first_wait", round: 1, work_date: "2026-11-14", store_id: "bbbbbbbb-0000-4000-8000-000000000001",
    user_id: U.target, requested_by: U.requester, requested_at: "2026-11-15T01:02:00Z", reason: "退勤の打刻を忘れた", first_approver_id: U.first,
    before: { clock_in: "2026-11-14T08:00:00+00:00", clock_out: "2026-11-14T13:00:00+00:00" }, clock_in: "2026-11-14T08:00:00+00:00", clock_out: "2026-11-14T14:30:00+00:00", ...over,
  },
  store_name: "鳥一代 本店", names: { [U.target]: "山田太郎", [U.requester]: "店長 花子", [U.first]: "チーム長 次郎", [U.boss]: "社長" },
  slack: { [U.target]: "U0TARGET01", [U.requester]: "U0REQUEST1", [U.first]: "U0FIRST001", [U.boss]: "U0BOSS0001" },
  masters: [{ user_id: U.boss, slack_user_id: "U0BOSS0001" }], presidents: [{ user_id: U.boss, slack_user_id: "U0BOSS0001" }], source: { state: "same" },
});
type Sent = Record<string, unknown>;
type Call = { name: string; args: Record<string, unknown> };
function fakes(o: { refs?: Record<string, unknown> | null; view?: unknown; rpc?: Record<string, (args: Record<string, unknown>) => unknown> } = {}) {
  const sent: Sent[] = []; const calls: Call[] = [];
  let current: unknown = o.view ?? rpcView();
  const refs = o.refs === undefined ? REFS : o.refs;
  const sb = {
    // deno-lint-ignore no-explicit-any
    from: (t: string): any => { const q = { select: () => q, eq: () => q, maybeSingle: () => Promise.resolve({ data: t === "app_settings" ? { value: { thread: true, two_stage: true } } : t === "notice_cases" ? (refs ? { slack_refs: refs } : null) : null }) }; return q; },
    rpc: (name: string, args: Record<string, unknown>) => {
      calls.push({ name, args });
      if (name === "sf_attendance_request_view") return Promise.resolve({ data: current, error: null });
      if (name === "notice_case_upsert") return Promise.resolve({ data: {}, error: null });
      const h = o.rpc?.[name];
      return Promise.resolve(h ? { data: h(args), error: null } : { data: null, error: { message: "unknown rpc " + name } });
    },
  };
  let n = 0;
  const notify = (b: Sent) => { sent.push(b); if (b.action === "update") return Promise.resolve({ ok: true }); n++; return Promise.resolve({ ok: true, notification_id: `auto-${n}`, ts: `200.${n}`, slack_channel_id: "C1" }); };
  const sends = () => sent.filter((s) => s.action === "send");
  const acts = () => calls.filter((c) => !["sf_attendance_request_view", "notice_case_upsert"].includes(c.name));
  return { sb, notify, sent, sends, calls, acts, set: (v: unknown) => { current = v; } };
}
const base = { requestId: RID, via: "slack" as const, source: "test" };
const noFix = () => { throw new Error("スマレジへ送ってはいけない"); };

Deno.test("形の違う id・知らない操作は、DB を呼ばずに断る", async () => {
  const f = fakes();
  assertEquals((await actRequest(f.sb, f.notify, { ...base, requestId: "x", actorId: U.first, action: "first_approve", smaregiFix: noFix })).code, "not_found");
  // deno-lint-ignore no-explicit-any
  assertEquals((await actRequest(f.sb, f.notify, { ...base, actorId: U.first, action: "approve" as any, smaregiFix: noFix })).code, "invalid");
  assertEquals([f.calls.length, f.sent.length], [0, 0]);
  assertEquals(REQ_ACTIONS.length, 7);
});

Deno.test("一次承認: DB の関数を呼ぶ → カードと親を書き換え → スレッドに一次承認の行 → 社長へスレッドでメンション＋リンクだけの DM。スマレジへは送らない", async () => {
  const f = fakes({ rpc: { sf_attendance_request_act: () => ({ ok: true, state: "final_wait", actor_name: "チーム長 次郎" }) } });
  const r = await actRequest(f.sb, f.notify, { ...base, actorId: U.first, action: "first_approve", smaregiFix: noFix });
  assertEquals([r.ok, r.state], [true, "final_wait"]);
  assertEquals(f.acts()[0], { name: "sf_attendance_request_act", args: { p_request_id: RID, p_actor: U.first, p_action: "first_approve", p_note: null, p_via: "slack" } });
  assertEquals(f.sent.length, 0);   // 返事の前には、Slack に何も送らない（3 秒の制限）
  f.set(rpcView({ stage: "final_wait", first_decided_by: U.first, first_decided_at: "2026-11-15T02:20:00Z" }));
  await r.after();
  assertEquals(f.sent.filter((s) => s.action === "update" && s.notification_id === "p-1")[0].text, "📝 勤怠修正｜山田太郎｜11/14｜最終承認待ち");
  const s = f.sends();
  assertEquals(s.map((x) => x.event), ["attendance_request_event", "attendance_request_ask", "attendance_request_dm"]);
  assert(String(s[0].text).startsWith("✅ 一次承認（チーム長 次郎・"));
  assert(String(s[1].text).startsWith("<@U0BOSS0001>　一次承認が済みました。最終承認をお願いします。"));
  assertEquals([s[0].thread_ts, s[1].thread_ts, s[2].thread_ts, s[2].channel_key, s[2].blocks], ["100.1", "100.1", undefined, `user:${U.boss}`, undefined]);
  assertEquals(f.acts().length, 1);   // 札（スマレジへ送る準備）は取らない
});

Deno.test("最終承認: 行を出す → 札を取れたときだけスマレジへ 1 回送る → 結果の行。札を取れなければ送らない（二重反映を防ぐ）", async () => {
  let fixed = 0;
  const f = fakes({ rpc: { sf_attendance_request_act: () => ({ ok: true, state: "sync_wait", actor_name: "社長" }), sf_attendance_request_sync_claim: () => ({ ok: true }) } });
  const r = await actRequest(f.sb, f.notify, { ...base, actorId: U.boss, action: "final_approve", smaregiFix: (id) => { fixed++; assertEquals(id, RID); f.set(rpcView({ status: "approved", stage: null, decided_by: U.boss, smaregi_sync_status: "synced" })); return Promise.resolve({ ok: true }); } });
  f.set(rpcView({ status: "approved", stage: null, decided_by: U.boss }));
  await r.after();
  assertEquals(fixed, 1);
  assertEquals(f.acts().map((c) => [c.name, c.args.p_actor]), [["sf_attendance_request_act", U.boss], ["sf_attendance_request_sync_claim", null]]);
  const texts = f.sends().map((x) => String(x.text));
  assert(texts[0].startsWith("✅ 最終承認（社長・") && texts[0].endsWith("→ スマレジへ反映します"));
  assertEquals(texts[1], "🔄 スマレジへ反映しました");
  assertEquals(f.sent.filter((s) => s.action === "update" && s.notification_id === "p-1").map((s) => s.text), ["📝 勤怠修正｜山田太郎｜11/14｜承認済み・スマレジ反映待ち", "✅ 勤怠修正｜山田太郎｜11/14｜同期済み"]);
  // 札を取れない（ほかで送っている最中）
  const g = fakes({ view: rpcView({ status: "approved", stage: null, decided_by: U.boss }), rpc: { sf_attendance_request_act: () => ({ ok: true, state: "sync_wait", actor_name: "社長" }), sf_attendance_request_sync_claim: () => ({ ok: false, code: "busy" }) } });
  await (await actRequest(g.sb, g.notify, { ...base, actorId: U.boss, action: "final_approve", smaregiFix: noFix })).after();
  assertEquals(g.sends().length, 1);
});

Deno.test("断られた操作（権限なし・理由なし・二重）: DB の言葉をそのまま返し、Slack は何も変えない", async () => {
  for (const [code, message] of [["forbidden", "いまは最終承認の段階です。操作できるのは社長だけです（マスター権限では代行できません）"], ["reason_required", "理由を 300 字以内で入れてください"], ["wrong_stage", "いまの状態では、この操作はできません"], ["self", "自分の勤怠の申請は、自分では最終承認できません"]]) {
    const f = fakes({ rpc: { sf_attendance_request_act: () => ({ ok: false, code, message }) } });
    const r = await actRequest(f.sb, f.notify, { ...base, actorId: U.first, action: "final_approve", smaregiFix: noFix });
    assertEquals([r.ok, r.code, r.message], [false, code, message]);
    await r.after();
    assertEquals(f.sent.length, 0);
  }
});

Deno.test("差戻し・却下: 理由を DB の関数へ渡す。差戻しのあとは、申請した人へスレッドで知らせる（DM は送らない）。却下は行だけ", async () => {
  const f = fakes({ rpc: { sf_attendance_request_act: () => ({ ok: true, state: "returned", actor_name: "チーム長 次郎" }) } });
  const r = await actRequest(f.sb, f.notify, { ...base, actorId: U.first, action: "return", note: "  退勤は 23:00 のはず  ", smaregiFix: noFix });
  assertEquals(f.acts()[0].args.p_note, "退勤は 23:00 のはず");
  f.set(rpcView({ stage: "returned", returned_by: U.first, return_note: "退勤は 23:00 のはず" }));
  await r.after();
  const s = f.sends();
  assertEquals(s.map((x) => x.event), ["attendance_request_event", "attendance_request_ask"]);
  assert(String(s[0].text).startsWith("↩️ 差戻し（チーム長 次郎・") && String(s[0].text).endsWith("理由：退勤は 23:00 のはず"));
  assert(String(s[1].text).startsWith("<@U0REQUEST1>　差戻しになりました。"));
  const g = fakes({ rpc: { sf_attendance_request_act: () => ({ ok: true, state: "rejected", actor_name: "社長" }) } });
  const r2 = await actRequest(g.sb, g.notify, { ...base, actorId: U.boss, action: "reject", note: "この日は出勤していない", via: "portal", smaregiFix: noFix });
  assertEquals(g.acts()[0].args.p_via, "portal");
  g.set(rpcView({ status: "rejected", stage: "final_wait", decided_by: U.boss, decision_note: "この日は出勤していない" }));
  await r2.after();
  assertEquals(g.sends().length, 1);
  assert(String(g.sends()[0].text).startsWith("❌ 却下（社長・"));
  assertEquals(g.sent.filter((x) => x.action === "update" && x.notification_id === "p-1")[0].text, "✅ 勤怠修正｜山田太郎｜11/14｜却下");
});

Deno.test("元データが変わっていた: 承認されず、差戻しの知らせがスレッドに出る（申請した人にメンション）。スマレジへは送らない", async () => {
  const f = fakes({ rpc: { sf_attendance_request_act: () => ({ ok: false, code: "source_changed", message: "申請のあとに、元の打刻が変わりました。", state: "returned" }) } });
  const r = await actRequest(f.sb, f.notify, { ...base, actorId: U.boss, action: "final_approve", smaregiFix: noFix });
  assertEquals([r.ok, r.code, r.state], [false, "source_changed", "returned"]);
  f.set(rpcView({ stage: "returned", return_note: "申請のあとに、元の打刻が変わりました。" }));
  await r.after();
  const s = f.sends();
  assert(String(s[0].text).startsWith("⚠️ 申請のあとに元の打刻が変わったため、差戻しにしました"));
  assert(String(s[1].text).startsWith("<@U0REQUEST1>"));
  assertEquals(s.filter((x) => x.event === "attendance_request_dm").length, 0);
  assertEquals(f.acts().length, 1);
});

Deno.test("スマレジへの再実行: 札を取れたときだけ送る。権限なし・送信中は送らない", async () => {
  let fixed = 0;
  const f = fakes({ view: rpcView({ status: "approved", stage: null, smaregi_sync_status: "pending" }), rpc: { sf_attendance_request_sync_claim: () => ({ ok: true }) } });
  const r = await actRequest(f.sb, f.notify, { ...base, actorId: U.first, action: "retry_sync", smaregiFix: () => { fixed++; f.set(rpcView({ status: "approved", stage: null, smaregi_sync_status: "failed", smaregi_error: "HTTP 409" })); return Promise.resolve({ ok: false, error: "HTTP 409" }); } });
  assertEquals(f.acts()[0], { name: "sf_attendance_request_sync_claim", args: { p_request_id: RID, p_actor: U.first } });
  await r.after();
  assertEquals(fixed, 1);
  assertEquals(f.sends().map((x) => x.text), ["🔁 スマレジへもう一度送ります", "<@U0FIRST001>　🔴 スマレジへ反映できませんでした：HTTP 409"]);
  for (const code of ["forbidden", "busy", "already_synced", "not_failed"]) {
    const g = fakes({ rpc: { sf_attendance_request_sync_claim: () => ({ ok: false, code, message: "だめ" }) } });
    const r2 = await actRequest(g.sb, g.notify, { ...base, actorId: U.first, action: "retry_sync", smaregiFix: noFix });
    await r2.after();
    assertEquals([r2.ok, r2.code, g.sent.length], [false, code, 0]);
  }
});

Deno.test("控えの無い申請（Slack に出していない申請）: 状態は DB で変わるが、Slack には何も送らない", async () => {
  const f = fakes({ refs: null, rpc: { sf_attendance_request_act: () => ({ ok: true, state: "final_wait", actor_name: "x" }) } });
  const r = await actRequest(f.sb, f.notify, { ...base, actorId: U.first, action: "first_approve", smaregiFix: noFix });
  await r.after();
  assertEquals([r.ok, f.sent.length], [true, 0]);
});

Deno.test("出し直し: 時刻と理由を DB の関数へ → スレッドに出し直しの行 → 一次承認者へ知らせる", async () => {
  const f = fakes({ rpc: { sf_attendance_request_resubmit: () => ({ ok: true, state: "first_wait", round: 2, actor_name: "店長 花子" }) } });
  const r = await resubmitRequest(f.sb, f.notify, { requestId: RID, actorId: U.requester, times: { clock_in: "2026-11-14T17:00:00+09:00", clock_out: "2026-11-14T23:00:00+09:00" }, reason: "直しました", via: "form", source: "test" });
  assertEquals(f.acts()[0].args, { p_request_id: RID, p_actor: U.requester, p_clock_in: "2026-11-14T17:00:00+09:00", p_clock_out: "2026-11-14T23:00:00+09:00", p_reason: "直しました",
    p_break_start_1: null, p_break_end_1: null, p_break_start_2: null, p_break_end_2: null, p_via: "form" });
  f.set(rpcView({ round: 2 }));
  await r.after();
  const s = f.sends();
  assert(String(s[0].text).startsWith("✏️ 出し直し（店長 花子・"));
  assert(String(s[1].text).startsWith("<@U0FIRST001>　一次承認をお願いします。"));
  assertEquals(s[1].dedupe_key, `attendance_req_ask:${RID}:r2:first_wait`);
  const g = fakes({ rpc: { sf_attendance_request_resubmit: () => ({ ok: false, code: "no_change", message: "修正前から変わっていません。" }) } });
  assertEquals((await resubmitRequest(g.sb, g.notify, { requestId: RID, actorId: U.requester, times: { clock_in: null, clock_out: null }, reason: "", via: "form", source: "test" })).code, "no_change");
});

Deno.test("質問と回答: 同じ申請のスレッドに出る。回答は一次承認者にメンション（気付けるように）。質問は、本人が Slack にいればメンション", async () => {
  const f = fakes({ rpc: { sf_attendance_request_message: () => ({ ok: true, kind: "answer", state: "first_wait", actor_name: "山田太郎" }) } });
  const r = await messageRequest(f.sb, f.notify, { requestId: RID, actorId: U.target, body: " 23 時に退勤しました ", via: "nippo", source: "test" });
  assertEquals(f.acts()[0].args, { p_request_id: RID, p_actor: U.target, p_body: "23 時に退勤しました", p_via: "nippo" });
  await r.after();
  assertEquals(r.kind, "answer");
  assert(String(f.sends()[0].text).startsWith("<@U0FIRST001>　💬 回答（山田太郎・") && String(f.sends()[0].text).endsWith("：23 時に退勤しました"));
  assertEquals(f.sends()[0].thread_ts, "100.1");
  // 質問: 本人が Slack と紐付いていない（アルバイト）ときは、だれにもメンションしない
  const v = rpcView({ stage: "asking" }); v.slack = { [U.first]: "U0FIRST001" } as never;
  const g = fakes({ view: v, rpc: { sf_attendance_request_message: () => ({ ok: true, kind: "question", state: "asking", actor_name: "チーム長 次郎" }) } });
  await (await messageRequest(g.sb, g.notify, { requestId: RID, actorId: U.first, body: "退勤は何時でしたか", via: "portal", source: "test" })).after();
  assert(String(g.sends()[0].text).startsWith("💬 質問（チーム長 次郎・"));
});

Deno.test("一次承認者の設定: 形の違う値は断る。動き出した「確認待ち」の申請は、カードを書き換えて一次承認者へ知らせる", async () => {
  const f = fakes({ rpc: { sf_attendance_first_approver_set: () => ({ ok: true, moved_request_ids: [RID], slack_linked: true }) } });
  assertEquals((await approverSet(f.sb, f.notify, { storeId: "x", userId: U.first, actorId: U.boss, source: "test" })).code, "invalid");
  const r = await approverSet(f.sb, f.notify, { storeId: "bbbbbbbb-0000-4000-8000-000000000001", userId: U.first, actorId: U.boss, source: "test" });
  assertEquals([r.ok, r.moved, r.slackLinked], [true, 1, true]);
  await r.after();
  assert(String(f.sends()[0].text).startsWith("<@U0FIRST001>　一次承認をお願いします。"));
  const g = fakes({ rpc: { sf_attendance_first_approver_set: () => ({ ok: false, code: "forbidden", message: "一次承認者を設定できるのは社長だけです" }) } });
  assertEquals((await approverSet(g.sb, g.notify, { storeId: "bbbbbbbb-0000-4000-8000-000000000001", userId: null, actorId: U.first, source: "test" })).message, "一次承認者を設定できるのは社長だけです");
});

Deno.test("理由の窓: 差戻しと却下で言葉が変わる。理由が空なら読めない（＝送れない）", () => {
  const m = reasonModal({ requestId: RID, notificationId: "c-1", op: "return" });
  assertEquals([m.callback_id, m.title.text, m.submit.text], [REQ_REASON_MODAL, "勤怠申請の差戻し", "差戻しにする"]);
  assertEquals(JSON.parse(m.private_metadata), { request_id: RID, notification_id: "c-1", op: "return" });
  assertEquals(reasonModal({ requestId: RID, notificationId: null, op: "reject" }).title.text, "勤怠申請の却下");
  const view = (reason: string, meta = m.private_metadata) => ({ private_metadata: meta, state: { values: { reason: { reason: { value: reason } } } } });
  assertEquals(reasonFromView(view(" 退勤は 23:00 ")), { requestId: RID, notificationId: "c-1", op: "return", reason: "退勤は 23:00" });
  assertEquals(reasonFromView(view("   ")), null);
  assertEquals(reasonFromView(view("x", JSON.stringify({ request_id: RID, op: "approve" }))), null);
  assertEquals(reasonFromView(view("x", "{")), null);
});

Deno.test("2026-11-16 質問: 本人が Slack にいないときは、申請した人（店長など）にメンション＋管理画面で答えてもらう案内。従業員本人へは何も送らない", async () => {
  const v = rpcView({ stage: "asking" }); v.slack = { [U.first]: "U0FIRST001", [U.requester]: "U0REQST001" } as never;
  const g = fakes({ view: v, rpc: { sf_attendance_request_message: () => ({ ok: true, kind: "question", state: "asking", actor_name: "チーム長 次郎" }) } });
  await (await messageRequest(g.sb, g.notify, { requestId: RID, actorId: U.first, body: "退勤は何時でしたか", via: "portal", source: "test" })).after();
  const t = String(g.sends()[0].text);
  assert(t.startsWith("<@U0REQST001>　💬 質問（チーム長 次郎・"));
  assert(t.includes("本人は Slack を使っていません") && t.includes("確認の質問が届いています"));
  assertEquals(g.sends().length, 1);   // 本人への DM などは出さない
});
