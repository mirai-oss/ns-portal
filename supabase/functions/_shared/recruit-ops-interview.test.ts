// 採用管理の共通の操作（面接の確定・変更・取り消し）のテスト。DB・カレンダー・LINE・Slack は、にせものを渡す。
//   RPC の中身（権限・スイッチ・同じ鍵・同時の操作・古い値の照合）は、SQL 側のテスト test_recruit_interview.sql で確かめる。ここは「順番」と「外を呼ぶ条件」
//   ※ 氏名・住所・URL は、テスト用の作りもの
import { assert, assertEquals } from "jsr:@std/assert@1";
import { handleOp, interviewCancel, interviewConfirm, type OpsDeps } from "./recruit-ops.ts";
import { interviewText } from "./recruit-interview-text.ts";
import type { MeetResult } from "./recruit-calendar.ts";
import type { LineResult } from "./recruit-line.ts";

const A1 = "11111111-1111-4111-8111-111111111111", U1 = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1", OP = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee1", O1 = "cccccccc-cccc-4ccc-8ccc-ccccccccccc1";
const actor = { user_id: U1, via: "slack" as const };
const AT = "2026-11-20T05:00:00.000Z";
const GO = { ok: true, code: "go", op_id: OP, kind: "confirm", is_test: true, calendar_mode: "dry", line_mode: "dry", applicant_name: "試験 太郎", linked: true, event_id: null, mode_changed: false,
  current_url: null, interviewer_name: "担当 花子", actor_name: "担当 花子", at: AT, mode: "online", place: null, address: null, place_note: null, notify: true };
type Rec = { order: string[]; rpc: { name: string; args: Record<string, unknown> }[]; meets: unknown[]; removes: string[]; lines: unknown[][]; notes: { key: string; text: string }[] };
// deno-lint-ignore no-explicit-any
function ideps(o: { begin?: any; save?: any; saveError?: string; sendBegin?: any; meet?: MeetResult | "throw"; removeOk?: boolean; line?: LineResult; noCalendar?: boolean; noGasConfig?: boolean } = {}) {
  const w: Rec = { order: [], rpc: [], meets: [], removes: [], lines: [], notes: [] };
  const d: OpsDeps = {
    rpc: (name, args) => {
      w.rpc.push({ name, args }); w.order.push(name === "recruit_interview_step" ? `step:${args.p_step}` : name.replace("recruit_", ""));
      if (name === "recruit_interview_begin") return Promise.resolve({ data: o.begin ?? GO, error: null });
      if (name === "recruit_interview_step") return Promise.resolve({ data: true, error: null });
      if (name === "recruit_interview_save") {
        if (o.saveError) return Promise.resolve({ data: null, error: { message: o.saveError } });
        const b = o.begin ?? GO;
        return Promise.resolve({ data: o.save ?? { ok: true, code: "saved", kind: b.kind, applicant_name: "試験 太郎", interview_at: "2026-11-20T05:00:00+00:00", interview_mode: b.mode, interview_place: b.place, interview_address: b.address, interview_url: args.p_url ?? b.current_url ?? null }, error: null });
      }
      if (name === "recruit_interview_finish") return Promise.resolve({ data: { ok: true, code: args.p_result }, error: null });
      if (name === "recruit_send_begin") return Promise.resolve({ data: o.sendBegin ?? { ok: true, code: "dry", outbox_id: O1, mode: "dry", status: "dry_done", actor_name: "担当 花子" }, error: null });
      if (name === "recruit_send_finish") return Promise.resolve({ data: { ok: true }, error: null });
      return Promise.resolve({ data: null, error: { message: "unexpected rpc " + name } });
    },
    lineToken: () => Promise.resolve("TOKEN"),
    linePush: (...a) => { w.lines.push(a); w.order.push("line"); return Promise.resolve(o.line ?? { status: "sent", http: 200, error: null, requestId: "r1" }); },
    threadNote: (_id, key, text) => { w.notes.push({ key, text }); return Promise.resolve(); },
    bodyChars: () => Promise.resolve(200),
    ...(o.noCalendar ? {} : { calendar: {
      config: () => Promise.resolve(o.noGasConfig ? null : { url: "https://gas.example/exec", key: "k", cal: "c" }),
      meet: (_c, a) => { w.meets.push(a); w.order.push("gas:meet"); if (o.meet === "throw") return Promise.reject(new Error("boom")); return Promise.resolve(o.meet ?? { ok: true, url: "https://meet.example/new", event_id: "ev-new", updated: false, why: null }); },
      remove: (_c, id) => { w.removes.push(id); w.order.push("gas:remove"); return Promise.resolve({ ok: o.removeOk !== false, why: o.removeOk === false ? "x" : null }); },
    } }),
  };
  return { d, w };
}
const req = (x: Record<string, unknown> = {}) => ({ applicant_id: A1, at: AT, mode: "online", notify: true, request_key: "slack:iv:V0TEST0001", expected: { interview_at: null, assignee_id: null }, ...x });
const stepOf = (w: Rec, name: string) => w.rpc.find((c) => c.name === "recruit_interview_step" && c.args.p_step === name)?.args.p_data as Record<string, unknown>;
const finishOf = (w: Rec) => w.rpc.find((c) => c.name === "recruit_interview_finish")?.args;

Deno.test("試しモード（既定）: カレンダーも LINE も呼ばない。順番は 始まり → 予定の記録 → 保存 → 案内（送信箱） → 終わり。予定の番号は、応募者の行に入れない", async () => {
  const { d, w } = ideps();
  const r = await interviewConfirm(d, actor, req());
  assertEquals([r.ok, r.code], [true, "done"]);
  assertEquals([w.meets.length, w.removes.length, w.lines.length], [0, 0, 0]);
  assertEquals(w.order, ["interview_begin", "step:calendar", "interview_save", "send_begin", "step:notice", "interview_finish"]);
  assertEquals(w.rpc[0].args, { p_applicant: A1, p_kind: "confirm", p_request_key: "slack:iv:V0TEST0001", p_actor: U1, p_via: "slack", p_at: AT, p_mode: "online", p_place: null, p_notify: true, p_expected: { interview_at: null, assignee_id: null } });
  assertEquals(stepOf(w, "calendar"), { ok: true, mode: "dry", event_id: `dry-${OP}`, updated: false, why: null, deleted_old: false });   // にせの番号は、記録にだけ
  assertEquals(w.rpc.find((c) => c.name === "recruit_interview_save")!.args, { p_op: OP, p_url: null, p_event_id: null, p_event_clear: false });
  assertEquals(stepOf(w, "notice"), { status: "dry", outbox_id: O1 });
  assertEquals([finishOf(w)!.p_result, finishOf(w)!.p_error], ["done", null]);
});

Deno.test("本番モード・全部成功: 予定と Meet → 保存（URL と予定の番号を同じ 1 回で）→ 案内の LINE（画面と同じ文面・用途は面接の案内・内容の鍵つき）", async () => {
  const { d, w } = ideps({ begin: { ...GO, calendar_mode: "live", line_mode: "live" }, sendBegin: { ok: true, code: "send", outbox_id: O1, mode: "live", retry_key: "dddddddd-dddd-4ddd-8ddd-ddddddddddd1", to: "Utest", text: "x", actor_name: "担当 花子" } });
  const r = await interviewConfirm(d, actor, req());
  assertEquals([r.ok, r.code, (r.notice as { status: string }).status], [true, "done", "sent"]);
  assertEquals(w.order, ["interview_begin", "gas:meet", "step:calendar", "interview_save", "send_begin", "line", "send_finish", "step:notice", "interview_finish"]);
  assertEquals(w.meets, [{ name: "試験 太郎", start: AT, eventId: "", mode: "online", place: "", address: "", interviewer: "担当 花子" }]);
  assertEquals(w.rpc.find((c) => c.name === "recruit_interview_save")!.args, { p_op: OP, p_url: "https://meet.example/new", p_event_id: "ev-new", p_event_clear: false });
  const sb = w.rpc.find((c) => c.name === "recruit_send_begin")!.args;
  assertEquals(sb.p_body, interviewText({ name: "試験 太郎", interview_at: "2026-11-20T05:00:00+00:00", interview_mode: "online", interview_url: "https://meet.example/new" }, null));
  assertEquals([sb.p_purpose, sb.p_request_key, sb.p_via, String(sb.p_dedupe_key).startsWith(`interview:${A1}:`)], ["interview_notice", `iv:${OP}:notice`, "slack", true]);
  assertEquals(w.notes.length, 0);
  assert(!JSON.stringify(r).includes("Utest"));
});

Deno.test("日時だけの変更: いまの予定の番号を渡して、同じ予定を直す（予定は増えない）", async () => {
  const { d, w } = ideps({ begin: { ...GO, calendar_mode: "live", event_id: "ev-old" }, meet: { ok: true, url: "https://meet.example/same", event_id: "ev-old", updated: true, why: null } });
  await interviewConfirm(d, actor, req());
  assertEquals([(w.meets[0] as { eventId: string }).eventId, w.removes.length], ["ev-old", 0]);
  assertEquals(w.rpc.find((c) => c.name === "recruit_interview_save")!.args.p_event_id, "ev-old");
});

Deno.test("オンライン⇔対面の切り替え: 古い予定を消してから、新しく作る。新しい予定が作れなかったら、予定の番号を空にする", async () => {
  const on = { ...GO, calendar_mode: "live", event_id: "ev-old", mode_changed: true, mode: "onsite", place: "テスト本店", address: "東京都テスト区1-2-3", place_note: "入口は裏側です。" };
  const a = ideps({ begin: on, meet: { ok: true, url: null, event_id: "ev-new", updated: false, why: null } });
  const r = await interviewConfirm(a.d, actor, req({ mode: "onsite", place: "テスト本店" }));
  assertEquals(a.w.order.slice(0, 4), ["interview_begin", "gas:remove", "gas:meet", "step:calendar"]);
  assertEquals([a.w.removes, (a.w.meets[0] as { eventId: string; mode: string; place: string }).eventId, (a.w.meets[0] as { mode: string }).mode], [["ev-old"], "", "onsite"]);
  assertEquals(a.w.rpc.find((c) => c.name === "recruit_interview_save")!.args, { p_op: OP, p_url: null, p_event_id: "ev-new", p_event_clear: false });
  assertEquals(a.w.rpc.find((c) => c.name === "recruit_send_begin")!.args.p_body,
    interviewText({ name: "試験 太郎", interview_at: "2026-11-20T05:00:00+00:00", interview_mode: "onsite", interview_place: "テスト本店", interview_address: "東京都テスト区1-2-3" }, { name: "テスト本店", address: "東京都テスト区1-2-3", note: "入口は裏側です。" }));
  assertEquals(r.code, "done");
  const b = ideps({ begin: on, meet: { ok: false, url: null, event_id: null, updated: false, why: "GAS 側で失敗: x" } });
  await interviewConfirm(b.d, actor, req({ mode: "onsite", place: "テスト本店" }));
  assertEquals(b.w.rpc.find((c) => c.name === "recruit_interview_save")!.args, { p_op: OP, p_url: null, p_event_id: null, p_event_clear: true });
});

Deno.test("カレンダーの失敗: 確定は保存する（partial）。スレッドに知らせる。自動ではやり直さない。設定が無い・部品が無い・止まった、も同じ", async () => {
  for (const o of [{ meet: { ok: false, url: null, event_id: null, updated: false, why: "GAS に届きませんでした: TimeoutError" } as MeetResult }, { meet: "throw" as const }, { noGasConfig: true }, { noCalendar: true }]) {
    const { d, w } = ideps({ begin: { ...GO, calendar_mode: "live" }, ...o });
    const r = await interviewConfirm(d, actor, req());
    assertEquals([r.ok, r.code, (r.calendar as { ok: boolean }).ok], [true, "partial", false]);
    assertEquals(w.meets.length <= 1, true);
    assert(w.order.includes("interview_save") && w.order.indexOf("interview_save") > w.order.indexOf("step:calendar"));
    assertEquals(w.rpc.find((c) => c.name === "recruit_interview_save")!.args, { p_op: OP, p_url: null, p_event_id: null, p_event_clear: false });
    assertEquals(finishOf(w)!.p_result, "partial");
    assertEquals(w.notes.filter((n) => n.key === `recruit:iv:${OP}:calendar`).length, 1);
    assert(w.notes.find((n) => n.key.endsWith(":calendar"))!.text.includes("面接の確定は保存されています"));
  }
});

Deno.test("LINE の失敗・結果不明: 確定は残る（partial）。記録して、自動では再送しない", async () => {
  const live = { ok: true, code: "send", outbox_id: O1, mode: "live", retry_key: "dddddddd-dddd-4ddd-8ddd-ddddddddddd1", to: "Utest", text: "x", actor_name: "担当 花子" };
  for (const status of ["failed", "unknown"] as const) {
    const { d, w } = ideps({ sendBegin: live, line: { status, http: status === "failed" ? 400 : null, error: "e", requestId: null } });
    const r = await interviewConfirm(d, actor, req());
    assertEquals([r.ok, r.code, (r.notice as { status: string }).status, w.lines.length, finishOf(w)!.p_result], [true, "partial", status, 1, "partial"]);
    assertEquals(stepOf(w, "notice").status, status);
  }
  // 同じ内容を、すでに送っている（送信箱が断った）→ 失敗ではない
  const dup = ideps({ sendBegin: { ok: false, code: "duplicate", message: "同じ内容を、すでに送っています" } });
  assertEquals((await interviewConfirm(dup.d, actor, req())).code, "done");
});

Deno.test("案内を送らない（notify=false）・LINE 未連携: 送信箱を呼ばない。未連携のときは、文面を返す（人が Indeed などで送るため）", async () => {
  const off = ideps({ begin: { ...GO, notify: false } });
  const r1 = await interviewConfirm(off.d, actor, req({ notify: false }));
  assertEquals([r1.code, (r1.notice as { status: string }).status, off.w.order.includes("send_begin"), off.w.rpc[0].args.p_notify], ["done", "skipped_off", false, false]);
  const un = ideps({ begin: { ...GO, linked: false } });
  const r2 = await interviewConfirm(un.d, actor, req());
  const n = r2.notice as { status: string; text: string };
  assertEquals([r2.code, n.status, un.w.order.includes("send_begin"), un.w.lines.length], ["done", "skipped_unlinked", false, 0]);
  assert(n.text.startsWith("試験 太郎さん\n\nこの度はご応募いただきありがとうございます。") && n.text.includes("【面接日時】11月20日(金) 14:00"));
});

Deno.test("始まりで断られた（古い値・同時の操作・権限・スイッチ・同じ鍵の 2 回目・すでにその内容）: カレンダーも LINE も保存も呼ばない", async () => {
  for (const [begin, code, ok] of [
    [{ ok: false, code: "conflict", message: "先に変更されています", current_interview_at: "2026-11-19T05:00:00+00:00", current_assignee_name: "店長 次郎" }, "conflict", false],
    [{ ok: false, code: "busy", message: "ほかの人が操作しています" }, "busy", false], [{ ok: false, code: "denied", message: "権限がありません" }, "denied", false],
    [{ ok: false, code: "disabled", message: "まだ使えません" }, "disabled", false], [{ ok: false, code: "replayed", replayed: true, result: "processing", message: "処理中です" }, "replayed", false],
    [{ ok: true, code: "replayed", replayed: true, result: "done" }, "replayed", true], [{ ok: true, code: "noop", message: "すでに、その内容で確定しています" }, "noop", true],
    [{ ok: true, code: "go", op_id: "x" }, "go", false], [null, "error", false],
  ] as [unknown, string, boolean][]) {
    const { d, w } = ideps({ begin: begin ?? { nothing: true } });
    const r = await interviewConfirm(d, actor, req());
    assertEquals([r.ok, r.code], [ok, code]);
    assertEquals([w.rpc.length, w.meets.length, w.lines.length, w.notes.length], [1, 0, 0, 0]);
  }
  const c = await interviewConfirm(ideps({ begin: { ok: false, code: "conflict", message: "先に変更されています", current_interview_at: "2026-11-19T05:00:00+00:00", current_assignee_name: "店長 次郎" } }).d, actor, req());
  assertEquals([c.current_interview_at, c.current_assignee_name], ["2026-11-19T05:00:00+00:00", "店長 次郎"]);
});

Deno.test("保存の失敗: 失敗で終わる（案内は送らない）。予定が作れていたら、スレッドに「同じ予定を使います」と知らせる", async () => {
  const { d, w } = ideps({ begin: { ...GO, calendar_mode: "live" }, saveError: "db down" });
  const r = await interviewConfirm(d, actor, req());
  assertEquals([r.ok, r.code, w.order.includes("send_begin"), w.lines.length, finishOf(w)!.p_result], [false, "failed", false, 0, "failed"]);
  assertEquals(stepOf(w, "calendar").event_id, "ev-new");   // 予定の番号は、記録に残っている（次の確定が引き継ぐ）
  assert(w.notes[0].text.includes("同じ予定を使います"));
});

Deno.test("入力の間違い → 何も呼ばない。手で貼った URL（https）は、Meet を発行せずに使う", async () => {
  const { d, w } = ideps();
  for (const x of [{ applicant_id: "x" }, { at: "いつか" }, { at: null }, { mode: "phone" }, { request_key: "short" }]) assertEquals((await interviewConfirm(d, actor, req(x))).code, "bad_request");
  assertEquals(w.rpc.length, 0);
  const m = ideps({ begin: { ...GO, calendar_mode: "live" } });
  await interviewConfirm(m.d, actor, req({ manual_url: " https://meet.example/pasted " }));
  assertEquals([m.w.meets.length, m.w.rpc.find((c) => c.name === "recruit_interview_save")!.args.p_url, stepOf(m.w, "calendar").mode], [0, "https://meet.example/pasted", "manual"]);
  const bad = ideps({ begin: { ...GO, calendar_mode: "live" } });
  await interviewConfirm(bad.d, actor, req({ manual_url: "javascript:alert(1)" }));
  assertEquals(bad.w.meets.length, 1, "https でない文字は、手で貼った URL として扱わない");
});

Deno.test("取り消し: 予定を消す（本番モードで、予定の番号があるときだけ）→ 保存 → 終わり。応募者へは何も送らない", async () => {
  const dry = ideps({ begin: { ...GO, kind: "cancel", event_id: "ev-old" } });
  const r1 = await interviewCancel(dry.d, actor, { applicant_id: A1, request_key: "slack:ivc:V0TEST0002", expected: { interview_at: "2026-11-20T05:00:00+00:00" } });
  assertEquals([r1.ok, r1.code, dry.w.removes.length, dry.w.lines.length], [true, "done", 0, 0]);
  assertEquals(dry.w.order, ["interview_begin", "step:calendar", "interview_save", "interview_finish"]);
  assertEquals(dry.w.rpc[0].args, { p_applicant: A1, p_kind: "cancel", p_request_key: "slack:ivc:V0TEST0002", p_actor: U1, p_via: "slack", p_expected: { interview_at: "2026-11-20T05:00:00+00:00" } });
  const live = ideps({ begin: { ...GO, kind: "cancel", calendar_mode: "live", event_id: "ev-old" } });
  const r2 = await interviewCancel(live.d, actor, { applicant_id: A1, request_key: "slack:ivc:V0TEST0003" });
  assertEquals([r2.code, live.w.removes, live.w.order.includes("send_begin")], ["done", ["ev-old"], false]);
  // 予定を消せなかった: 取り消しは保存する（partial）。スレッドに「手で消してください」
  const ng = ideps({ begin: { ...GO, kind: "cancel", calendar_mode: "live", event_id: "ev-old" }, removeOk: false });
  const r3 = await interviewCancel(ng.d, actor, { applicant_id: A1, request_key: "slack:ivc:V0TEST0004" });
  assertEquals([r3.ok, r3.code, finishOf(ng.w)!.p_result], [true, "partial", "partial"]);
  assert(ng.w.notes[0].text.includes("手で消してください") && ng.w.order.includes("interview_save"));
  // 断られたら、何も呼ばない
  const no = ideps({ begin: { ok: false, code: "conflict", message: "先に変更されています" } });
  assertEquals([(await interviewCancel(no.d, actor, { applicant_id: A1, request_key: "slack:ivc:V0TEST0005" })).code, no.w.rpc.length, no.w.removes.length], ["conflict", 1, 0]);
});

Deno.test("振り分け: interview_confirm / interview_cancel", async () => {
  assertEquals((await handleOp(ideps().d, actor, { op: "interview_confirm", ...req() })).code, "done");
  assertEquals((await handleOp(ideps({ begin: { ...GO, kind: "cancel" } }).d, actor, { op: "interview_cancel", applicant_id: A1, request_key: "slack:ivc:V0TEST0006" })).code, "done");
});
