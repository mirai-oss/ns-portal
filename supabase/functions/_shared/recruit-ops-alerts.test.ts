// 採用管理の知らせ（24 時間の未対応 → 予備の担当／失敗の行の［もう一度］）のテスト。DB・LINE・カレンダー・Slack は、にせものを渡す。
//   RPC の中身（1 日 1 回・対応済みは出ない・社員採用は対象外・権限・スイッチ）は、SQL 側のテスト test_recruit_alerts.sql で確かめる
//   ※ 氏名・LINE の宛先は、テスト用の作りもの
import { assert, assertEquals } from "jsr:@std/assert@1";
import { alertsScan, calendarRetry, handleOp, interviewConfirm, messageRetry, messageRetryInfo, messageSend, RETRY_CAL_ACTION, RETRY_SEND_ACTION, type OpsDeps } from "./recruit-ops.ts";
import type { MeetResult } from "./recruit-calendar.ts";
import type { LineResult } from "./recruit-line.ts";

const A1 = "11111111-1111-4111-8111-111111111111", A2 = "22222222-2222-4222-8222-222222222222", U1 = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1", U2 = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2";
const O1 = "cccccccc-cccc-4ccc-8ccc-ccccccccccc1", RK = "dddddddd-dddd-4ddd-8ddd-ddddddddddd1", OP = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee1";
const actor = { user_id: U1, via: "slack" as const };
const NOW = Date.parse("2026-11-29T03:00:00Z");
type W = { rpc: { name: string; args: Record<string, unknown> }[]; lines: unknown[][]; meets: unknown[]; notes: { id: string; key: string; text: string; blocks?: unknown[] }[]; posts: { id: string; key: string; text: string }[]; updates: { key: string; text: string }[] };
// deno-lint-ignore no-explicit-any
function deps(o: { answers?: Record<string, any>; line?: LineResult; meet?: MeetResult; post?: (id: string) => "sent" | "duplicate" | "no_thread" | "failed"; people?: Record<string, { name: string | null; slack: string | null }>; noPost?: boolean } = {}) {
  const w: W = { rpc: [], lines: [], meets: [], notes: [], posts: [], updates: [] };
  const d: OpsDeps = {
    rpc: (name, args) => { w.rpc.push({ name, args }); const a = o.answers?.[name]; return Promise.resolve({ data: typeof a === "function" ? a(args) : a ?? (name.endsWith("_finish") || name.endsWith("_step") || name.endsWith("_mark") ? { ok: true } : null), error: null }); },
    lineToken: () => Promise.resolve("TOKEN"),
    linePush: (...a) => { w.lines.push(a); return Promise.resolve(o.line ?? { status: "sent", http: 200, error: null, requestId: "r1" }); },
    threadNote: (id, key, text, blocks) => { w.notes.push({ id, key, text, blocks }); return Promise.resolve(); },
    ...(o.noPost ? {} : { threadPost: (id: string, key: string, text: string) => { w.posts.push({ id, key, text }); return Promise.resolve(o.post ? o.post(id) : "sent" as const); } }),
    noteUpdate: (key, text) => { w.updates.push({ key, text }); return Promise.resolve(); },
    people: () => Promise.resolve(o.people ?? { [U2]: { name: "予備 三郎", slack: "U0BACKUP1" }, [U1]: { name: "担当 花子", slack: "U0MAIN001" } }),
    bodyChars: () => Promise.resolve(200),
    calendar: { config: () => Promise.resolve({ url: "https://gas.example/exec", key: "k", cal: "c" }), meet: (_c, a) => { w.meets.push(a); return Promise.resolve(o.meet ?? { ok: true, url: "https://meet.example/new", event_id: "ev-new", updated: false, why: null }); }, remove: () => Promise.resolve({ ok: true, why: null }) },
  };
  return { d, w };
}
const names = (w: W) => w.rpc.map((c) => c.name.replace("recruit_", ""));
const TARGETS = [{ applicant_id: A1, assignee_id: U1, backup_user_id: U2, waiting_since: "2026-11-27T21:00:00+00:00", kind: "part" }, { applicant_id: A2, assignee_id: null, backup_user_id: U2, waiting_since: "2026-11-28T01:00:00+00:00", kind: "unknown" }];
// deno-lint-ignore no-explicit-any
const btn = (blocks: unknown[] | undefined) => (blocks as any[] | undefined)?.find((b) => b.type === "actions")?.elements?.[0];

Deno.test("24 時間の未対応: スイッチが閉じていれば、何も読まない・何も出さない", async () => {
  for (const on of [false, null, "true"]) {
    const { d, w } = deps({ answers: { recruit_alerts_on: on, recruit_unhandled_targets: TARGETS } });
    assertEquals(await alertsScan(d, { now: NOW }), { ok: true, code: "off", sent: 0 });
    assertEquals([names(w), w.posts.length], [["alerts_on"], 0]);
  }
});

Deno.test("24 時間の未対応: 対象ごとに、スレッドに 1 行（予備の担当へメンション）→ 出せたら「知らせた印」。担当を変える処理は呼ばない。本文・LINE の ID は出さない", async () => {
  const { d, w } = deps({ answers: { recruit_alerts_on: true, recruit_unhandled_targets: TARGETS } });
  const r = await alertsScan(d, { now: NOW });
  assertEquals([r.ok, r.code, r.sent, r.skipped, r.failed, r.targets], [true, "scanned", 2, 0, 0, 2]);
  assertEquals(names(w), ["alerts_on", "unhandled_targets", "unhandled_mark", "unhandled_mark"]);
  assertEquals(w.rpc[1].args, { p_now: "2026-11-29T03:00:00.000Z", p_include_test: false });
  assertEquals(w.posts[0], { id: A1, key: `recruit:unhandled:${A1}:20261129`,
    text: "<@U0BACKUP1>　⏰ 応募者からのメッセージに、24 時間以上 返信していません（最初の未返信：11/28 06:00・担当：担当 花子）。対応をお願いします。\n※ 予備の担当へのお知らせです。担当者は変えていません。" });
  assert(w.posts[1].text.includes("担当：未定"));
  assert(!w.rpc.some((c) => c.name.includes("assignee")), "担当者を変える RPC は、呼ばない");
  assertEquals(w.rpc[2].args, { p_applicant: A1, p_now: "2026-11-29T03:00:00.000Z" });
  assert(!JSON.stringify(r).includes("花子") && !JSON.stringify(r).includes(A1), "返す値は、件数だけ");
});

Deno.test("24 時間の未対応: スレッドの無い応募者は、出さない・印も付けない。同じ日にもう出してあれば、行は増えない（印だけ付け直す）。失敗は、次の回にもう一度", async () => {
  const res: Record<string, "sent" | "duplicate" | "no_thread" | "failed"> = { [A1]: "no_thread", [A2]: "duplicate" };
  const a = deps({ answers: { recruit_alerts_on: true, recruit_unhandled_targets: TARGETS }, post: (id) => res[id] });
  const r = await alertsScan(a.d, { now: NOW });
  assertEquals([r.sent, r.skipped, r.failed], [0, 2, 0]);
  assertEquals(a.w.rpc.filter((c) => c.name === "recruit_unhandled_mark").map((c) => c.args.p_applicant), [A2]);
  const f = deps({ answers: { recruit_alerts_on: true, recruit_unhandled_targets: TARGETS }, post: () => "failed" });
  const r2 = await alertsScan(f.d, { now: NOW });
  assertEquals([r2.sent, r2.failed, f.w.rpc.filter((c) => c.name === "recruit_unhandled_mark").length], [0, 2, 0]);
  // 予備の担当が Slack と紐づいていない: メンションはできないが、行は出す（氏名つき）
  const n = deps({ answers: { recruit_alerts_on: true, recruit_unhandled_targets: TARGETS.slice(0, 1) }, people: { [U2]: { name: "予備 三郎", slack: null } } });
  await alertsScan(n.d, { now: NOW });
  assert(n.w.posts[0].text.startsWith("（予備の担当：予備 三郎 さん・Slack 未連携のためメンションできません）"));
  // 1 回に出すのは、上限まで。テスト用の応募者を含めるのは、指定したときだけ。部品が無ければ、何もしない
  const many = Array.from({ length: 30 }, (_x, i) => ({ ...TARGETS[0], applicant_id: `11111111-1111-4111-8111-${String(i).padStart(12, "0")}` }));
  const m = deps({ answers: { recruit_alerts_on: true, recruit_unhandled_targets: many } });
  const r3 = await alertsScan(m.d, { now: NOW, include_test: true });
  assertEquals([m.w.posts.length, r3.more, m.w.rpc[1].args.p_include_test], [20, true, true]);
  assertEquals((await alertsScan(deps({ answers: { recruit_alerts_on: true }, noPost: true }).d, { now: NOW })).ok, false);
});

Deno.test("失敗の行に［もう一度］が付く: LINE の送信失敗・結果不明（同じ鍵＝同じ失敗に 1 行）／カレンダー登録の失敗。文面は、第 2 弾のまま", async () => {
  const SEND = { ok: true, code: "send", outbox_id: O1, mode: "live", retry_key: RK, to: "Utest", text: "本文", actor_name: "担当 花子" };
  const f = deps({ answers: { recruit_send_begin: SEND }, line: { status: "failed", http: 400, error: "LINE の応答: 400", requestId: null } });
  await messageSend(f.d, actor, { applicant_id: A1, text: "本文", request_key: "slack:line:V0TEST0001" });
  assertEquals([f.w.notes.length, f.w.notes[0].key], [1, `recruit:outbox:${O1}:failed`]);
  assert(f.w.notes[0].text.startsWith("⚠️ LINE を送れませんでした（操作: 担当 花子）。応募者には届いていません。"));
  assertEquals([btn(f.w.notes[0].blocks).action_id, btn(f.w.notes[0].blocks).value, btn(f.w.notes[0].blocks).text.text], [RETRY_SEND_ACTION, JSON.stringify({ applicant_id: A1, outbox_id: O1 }), "もう一度送る（確かめてから）"]);
  assert(!JSON.stringify(f.w.notes[0].blocks).includes("Utest") && !JSON.stringify(f.w.notes[0].blocks).includes("本文\""), "ボタンの値に、LINE の宛先・本文を入れない");
  const u = deps({ answers: { recruit_send_begin: SEND }, line: { status: "unknown", http: null, error: "x", requestId: null } });
  await messageSend(u.d, actor, { applicant_id: A1, text: "本文", request_key: "slack:line:V0TEST0002" });
  assertEquals([u.w.notes[0].key, btn(u.w.notes[0].blocks).action_id], [`recruit:outbox:${O1}:unknown`, RETRY_SEND_ACTION]);
  const GO = { ok: true, code: "go", op_id: OP, calendar_mode: "live", applicant_name: "試験 太郎", linked: false, event_id: null, mode_changed: false, actor_name: "担当 花子", mode: "online", notify: false };
  const c = deps({ answers: { recruit_interview_begin: GO, recruit_interview_save: { ok: true, interview_at: "2026-12-05T05:00:00+00:00" } }, meet: { ok: false, url: null, event_id: null, updated: false, why: "GAS に届きませんでした" } });
  await interviewConfirm(c.d, actor, { applicant_id: A1, at: "2026-12-05T05:00:00Z", mode: "online", notify: false, request_key: "slack:iv:V0TEST0003" });
  const cn = c.w.notes.find((n) => n.key === `recruit:iv:${OP}:calendar`)!;
  assertEquals([btn(cn.blocks).action_id, btn(cn.blocks).value], [RETRY_CAL_ACTION, JSON.stringify({ applicant_id: A1, note_key: `recruit:iv:${OP}:calendar` })]);
});

Deno.test("LINE の送り直し: 同じ行・同じ再送の鍵で 1 回だけ送る → 成功したら、元の行を書き換える（ボタンが外れる）。試しモード・断られたときは、LINE を呼ばない", async () => {
  const SEND = { ok: true, code: "send", outbox_id: O1, applicant_id: A1, mode: "live", retry_key: RK, to: "Utest", text: "元の本文", actor_name: "担当 花子" };
  const { d, w } = deps({ answers: { recruit_send_retry_begin: SEND } });
  const r = await messageRetry(d, actor, { outbox_id: O1, request_key: "slack:retry:V0TEST0001" });
  assertEquals([r.ok, r.code], [true, "sent"]);
  assertEquals(w.lines, [["TOKEN", "Utest", "元の本文", RK]]);
  assertEquals(w.rpc[0], { name: "recruit_send_retry_begin", args: { p_outbox: O1, p_request_key: "slack:retry:V0TEST0001", p_actor: U1, p_via: "slack" } });
  assertEquals(w.rpc[1].args, { p_outbox: O1, p_status: "sent", p_error: null, p_response: { http: 200, request_id: "r1" } });
  assertEquals(w.updates, [{ key: `recruit:outbox:${O1}:failed`, text: "✅ LINE を送り直しました（操作: 担当 花子）。" }, { key: `recruit:outbox:${O1}:unknown`, text: "✅ LINE を送り直しました（操作: 担当 花子）。" }]);
  assert(!JSON.stringify(r).includes("Utest") && !JSON.stringify(r).includes("元の本文"));
  for (const begin of [{ ok: true, code: "dry", outbox_id: O1, status: "failed" }, { ok: false, code: "not_retryable", status: "sent", message: "この送信は、すでに送信済みです" }, { ok: false, code: "denied", message: "権限がありません" },
    { ok: false, code: "disabled", message: "まだ使えません" }, { ok: false, code: "replayed", replayed: true, status: "sending", message: "受け付けています" }, { ...SEND, to: "" }]) {
    const x = deps({ answers: { recruit_send_retry_begin: begin } });
    const rr = await messageRetry(x.d, actor, { outbox_id: O1, request_key: "slack:retry:V0TEST0002" });
    assertEquals([x.w.lines.length, x.w.updates.length, x.w.notes.length, rr.code === "sent"], [0, 0, 0, false]);
  }
  // もう一度失敗: 記録する。同じ鍵の行（＝増えない）にボタンつきで出し直すだけ。自動では再送しない
  const f = deps({ answers: { recruit_send_retry_begin: SEND }, line: { status: "failed", http: 400, error: "LINE の応答: 400", requestId: null } });
  const rf = await messageRetry(f.d, actor, { outbox_id: O1, request_key: "slack:retry:V0TEST0003" });
  assertEquals([rf.ok, rf.code, f.w.lines.length, f.w.notes[0].key, f.w.updates.length], [false, "failed", 1, `recruit:outbox:${O1}:failed`, 0]);
  assertEquals((await messageRetry(d, actor, { outbox_id: "x", request_key: "slack:retry:V0TEST0004" })).code, "bad_request");
});

Deno.test("送り直しの窓の材料: RPC の答えを、LINE の宛先なしで渡す", async () => {
  const { d } = deps({ answers: { recruit_send_retry_info: { ok: true, can_retry: true, code: "ok", status: "unknown", purpose: "reply", applicant_id: A1, applicant_name: "試験 太郎", body: "元の本文", line_mode: "live", to: "Utest" } } });
  const r = await messageRetryInfo(d, actor, { outbox_id: O1 });
  assertEquals([r.ok, r.can_retry, r.status, r.applicant_name, r.body, r.mode], [true, true, "unknown", "試験 太郎", "元の本文", "live"]);
  assert(!JSON.stringify(r).includes("Utest"));
  assertEquals((await handleOp(d, actor, { op: "message_retry_info", outbox_id: O1 })).ok, true);
});

Deno.test("カレンダーのやり直し: 試しモードなら GAS を呼ばない。本番モードは、いまの予定の番号で 1 回 → 保存 → 元の行を書き換える。失敗しても、スレッドの行は増やさない", async () => {
  const GO = { ok: true, code: "go", op_id: OP, kind: "calendar_retry", calendar_mode: "live", line_mode: "dry", applicant_name: "試験 太郎", linked: true, event_id: "ev-old", actor_name: "担当 花子",
    interviewer_name: "担当 花子", at: "2026-12-05T05:00:00+00:00", mode: "online", place: null, address: null, place_note: null, notify: false };
  const SAVED = { ok: true, code: "saved", applicant_name: "試験 太郎", interview_at: "2026-12-05T05:00:00+00:00", interview_mode: "online", interview_place: null, interview_address: null, interview_url: "https://meet.example/new" };
  const NK = `recruit:iv:${OP}:calendar`;
  const dry = deps({ answers: { recruit_calendar_retry_begin: { ...GO, calendar_mode: "dry" } } });
  assertEquals([(await calendarRetry(dry.d, actor, { applicant_id: A1, request_key: "slack:calretry:V0TEST0001" })).code, dry.w.meets.length, dry.w.updates.length], ["dry", 0, 0]);
  const { d, w } = deps({ answers: { recruit_calendar_retry_begin: GO, recruit_calendar_retry_save: SAVED } });
  const r = await calendarRetry(d, actor, { applicant_id: A1, request_key: "slack:calretry:V0TEST0002", note_key: NK });
  assertEquals([r.ok, r.code, r.has_url], [true, "done", true]);
  assertEquals(w.meets, [{ name: "試験 太郎", start: "2026-12-05T05:00:00.000Z", eventId: "ev-old", mode: "online", place: "", address: "", interviewer: "担当 花子" }]);
  assertEquals(names(w), ["calendar_retry_begin", "interview_step", "calendar_retry_save", "interview_step", "interview_finish"]);
  assertEquals(w.rpc[2].args, { p_op: OP, p_url: "https://meet.example/new", p_event_id: "ev-new" });
  assertEquals([w.updates, w.lines.length, w.rpc.some((c) => c.name === "recruit_send_begin")], [[{ key: NK, text: "✅ カレンダーに登録しました（操作: 担当 花子）。" }], 0, false]);
  // 案内を送る、を選んだとき: 送信箱を通す（用途は面接の案内）
  const n = deps({ answers: { recruit_calendar_retry_begin: { ...GO, notify: true }, recruit_calendar_retry_save: SAVED, recruit_send_begin: { ok: true, code: "dry", outbox_id: O1, actor_name: "担当 花子" } } });
  const rn = await calendarRetry(n.d, actor, { applicant_id: A1, request_key: "slack:calretry:V0TEST0003", notify: true });
  const sb = n.w.rpc.find((c) => c.name === "recruit_send_begin")!.args;
  assertEquals([(rn.notice as { status: string }).status, sb.p_purpose, String(sb.p_body).includes("【面接URL】https://meet.example/new"), n.w.rpc[0].args.p_notify], ["dry", "interview_notice", true, true]);
  // もう一度失敗: 保存しない・スレッドに新しい行を出さない・元の行も書き換えない
  const f = deps({ answers: { recruit_calendar_retry_begin: GO }, meet: { ok: false, url: null, event_id: null, updated: false, why: "GAS 側で失敗: x" } });
  const rf = await calendarRetry(f.d, actor, { applicant_id: A1, request_key: "slack:calretry:V0TEST0004", note_key: NK });
  assertEquals([rf.ok, rf.code, f.w.notes.length, f.w.updates.length, f.w.rpc.some((c) => c.name === "recruit_calendar_retry_save")], [false, "failed", 0, 0, false]);
  assertEquals(f.w.rpc.find((c) => c.name === "recruit_interview_finish")!.args.p_result, "failed");
  // 断られたら、何も呼ばない
  const no = deps({ answers: { recruit_calendar_retry_begin: { ok: false, code: "busy", message: "ほかの人が操作しています" } } });
  assertEquals([(await calendarRetry(no.d, actor, { applicant_id: A1, request_key: "slack:calretry:V0TEST0005" })).code, no.w.meets.length, no.w.rpc.length], ["busy", 0, 1]);
});
