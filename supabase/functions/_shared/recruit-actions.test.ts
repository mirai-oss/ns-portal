// 採用管理: Slack のカードからの操作（担当者を変更）のテスト。deno test supabase/functions/_shared/recruit-actions.test.ts
//   DB と設定は、にせものを渡す（RPC の中身＝権限・古い値の照合・二重防止は、SQL 側のテスト test_recruit_base.sql で確かめる）
//   ※ 氏名は、テスト用の作りもの
import { assert, assertEquals } from "jsr:@std/assert@1";
import { ASSIGNEE_ACTION, ASSIGNEE_MODAL, assigneeModal, assigneeOpen, assigneeSubmit, LINE_ACTION, LINE_CONFIRM, LINE_MODAL, lineConfirm, lineInput, lineOpen,
  INTERVIEW_ACTION, INTERVIEW_CANCEL_ACTION, INTERVIEW_CANCEL_MODAL, INTERVIEW_CONFIRM, INTERVIEW_MODAL, interviewCancelOpen, interviewCancelSubmit, interviewConfirmSubmit, interviewInput, interviewOpen, prefToIso,
  RETRY_CAL_ACTION, RETRY_CAL_MODAL, RETRY_SEND_ACTION, RETRY_SEND_MODAL, retryCalendarOpen, retryCalendarSubmit, retrySendOpen, retrySendSubmit,
  HIRE_ACTION, HIRE_MODAL, hireOpen, hireSubmit,
  type InterviewInfo, type Place, type RecruitDeps, type RecruitOutcome } from "./recruit-actions.ts";
import { interviewText } from "./recruit-interview-text.ts";

const A1 = "11111111-1111-4111-8111-111111111111", U1 = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1", U2 = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2", U3 = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3";
const N1 = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1";
const actor = { user_id: U1, name: "担当 花子" };
type Call = { name: string; args: Record<string, unknown> };
// deno-lint-ignore no-explicit-any
function deps(o: { enabled?: boolean; answer?: (c: Call) => any; error?: string } = {}) {
  const calls: Call[] = [];
  const d: RecruitDeps = {
    actionsEnabled: () => Promise.resolve(o.enabled !== false),
    rpc: (name, args) => { calls.push({ name, args }); return Promise.resolve(o.error ? { data: null, error: { message: o.error } } : { data: o.answer ? o.answer({ name, args }) : null, error: null }); },
  };
  return { d, calls };
}
const cands = { ok: true, applicant_id: A1, applicant_name: "試験 太郎", assignee_id: U2, assignee_name: "店長 次郎", candidates: [{ id: U1, name: "担当 花子" }, { id: U2, name: "店長 次郎" }, { id: U3, name: "本部 三郎" }] };
// deno-lint-ignore no-explicit-any
const view = (x: Record<string, unknown> = {}, sel: string | null = U3, reason: string | null = null): any => ({
  id: "V0TESTVIEW1", callback_id: ASSIGNEE_MODAL, private_metadata: JSON.stringify({ applicant_id: A1, expected_assignee: U2, notification_id: N1 }),
  state: { values: { assignee: { assignee: { selected_option: sel ? { value: sel } : null } }, reason: { reason: { value: reason } } } }, ...x,
});
const text = (o: RecruitOutcome) => (o.kind === "ephemeral" ? o.text : o.kind === "errors" ? o.errors.assignee : "");

Deno.test("ボタンと窓の名前（slack-interact の振り分けに使う）", () => {
  assertEquals([ASSIGNEE_ACTION, ASSIGNEE_MODAL], ["recruit.assignee.open", "recruit.assignee.modal"]);
});

Deno.test("ボタン: 設定が OFF なら、窓を開かない（RPC も呼ばない）", async () => {
  const { d, calls } = deps({ enabled: false });
  const o = await assigneeOpen(d, actor, { applicant_id: A1 });
  assertEquals(o.kind, "ephemeral");
  assert(text(o).includes("まだ使えません"));
  assertEquals(calls.length, 0);
});

Deno.test("ボタン: 権限の無い人が押したら、本人だけに「権限がありません」。窓は開かない", async () => {
  const { d, calls } = deps({ answer: () => ({ ok: false, code: "denied", message: "権限がありません" }) });
  const o = await assigneeOpen(d, { user_id: U3 }, { applicant_id: A1 });
  assertEquals(o.kind, "ephemeral");
  assert(text(o).startsWith("権限がありません"));
  assertEquals(calls, [{ name: "recruit_assignee_candidates", args: { p_applicant: A1, p_actor: U3 } }]);   // 権限は、押した人の id で、RPC（サーバー側）が確かめる
});

Deno.test("ボタン: 選ぶ窓を開く。選べるのは RPC が返した人だけ（いまの担当は除く）。見ていた担当を窓に控える", async () => {
  const { d } = deps({ answer: () => cands });
  const o = await assigneeOpen(d, actor, { applicant_id: A1, notification_id: N1 });
  assert(o.kind === "modal");
  // deno-lint-ignore no-explicit-any
  const v = o.view as any;
  assertEquals([v.type, v.callback_id, v.title.text, v.submit.text], ["modal", ASSIGNEE_MODAL, "担当者を変更", "変更する"]);
  assertEquals(JSON.parse(v.private_metadata), { applicant_id: A1, expected_assignee: U2, notification_id: N1 });
  assert(v.blocks[0].text.text.includes("試験 太郎") && v.blocks[0].text.text.includes("いまの担当：店長 次郎"));
  // deno-lint-ignore no-explicit-any
  assertEquals(v.blocks[1].element.options.map((x: any) => [x.value, x.text.text]), [[U1, "担当 花子"], [U3, "本部 三郎"]]);
  assert(v.title.text.length <= 24 && v.private_metadata.length < 3000);
  // 担当が未定のとき: 見ていた値は null。全員が選べる
  const { d: d2 } = deps({ answer: () => ({ ...cands, assignee_id: null, assignee_name: null }) });
  const o2 = await assigneeOpen(d2, actor, { applicant_id: A1 });
  assert(o2.kind === "modal");
  // deno-lint-ignore no-explicit-any
  const v2 = o2.view as any;
  assertEquals(JSON.parse(v2.private_metadata).expected_assignee, null);
  assertEquals(v2.blocks[1].element.options.length, 3);
  assert(v2.blocks[0].text.text.includes("いまの担当：未定"));
});

Deno.test("ボタン: 応募者の番号が壊れている・応募者がいない・選べる人がいない・読み込みの失敗 → 窓を開かず、本人だけに知らせる", async () => {
  const bad = deps({ answer: () => cands });
  assertEquals((await assigneeOpen(bad.d, actor, { applicant_id: "x" })).kind, "ephemeral");
  assertEquals(bad.calls.length, 0);
  assert(text(await assigneeOpen(deps({ answer: () => ({ ok: false, code: "not_found", message: "応募者が見つかりません" }) }).d, actor, { applicant_id: A1 })).includes("見つかりません"));
  assert(text(await assigneeOpen(deps({ answer: () => ({ ...cands, candidates: [{ id: U2, name: "店長 次郎" }] }) }).d, actor, { applicant_id: A1 })).includes("ほかに担当にできる人がいません"));
  assert(text(await assigneeOpen(deps({ error: "timeout" }).d, actor, { applicant_id: A1 })).includes("読み込めませんでした"));
});

Deno.test("窓の送信: RPC recruit_assignee_set を、押した人・見ていた担当・窓の番号（依頼の鍵）つきで 1 回だけ呼ぶ → 窓を閉じる", async () => {
  const { d, calls } = deps({ answer: () => ({ ok: true, code: "done" }) });
  const o = await assigneeSubmit(d, actor, view({}, U3, " 引き継ぎのため "));
  assertEquals(o, { kind: "clear" });
  assertEquals(calls, [{ name: "recruit_assignee_set", args: { p_applicant: A1, p_assignee: U3, p_expected_assignee: U2, p_request_key: "slack:view:V0TESTVIEW1", p_actor: U1, p_via: "slack", p_reason: "引き継ぎのため" } }]);
  // Slack が同じ送信をもう一度届けても、依頼の鍵は同じ（＝ RPC の側で 1 回だけになる）
  const again = deps({ answer: () => ({ ok: true, code: "done", replayed: true }) });
  assertEquals(await assigneeSubmit(again.d, actor, view({}, U3)), { kind: "clear" });
  assertEquals(again.calls[0].args.p_request_key, "slack:view:V0TESTVIEW1");
  assertEquals(again.calls[0].args.p_reason, null);
  // すでにその担当だった（noop）も、成功として閉じる
  assertEquals(await assigneeSubmit(deps({ answer: () => ({ ok: true, code: "noop" }) }).d, actor, view()), { kind: "clear" });
});

Deno.test("窓の送信: 先に変更されていた → 何も変えず、窓の中に「先に変更されています」（いまの担当つき）", async () => {
  const { d } = deps({ answer: () => ({ ok: false, code: "conflict", message: "先に変更されています", current_assignee: U1, current_name: "担当 花子" }) });
  const o = await assigneeSubmit(d, actor, view());
  assertEquals(o.kind, "errors");
  assertEquals(text(o), "先に変更されています（いまの担当：担当 花子）。この窓を閉じて、もう一度開いてください。");
  const o2 = await assigneeSubmit(deps({ answer: () => ({ ok: false, code: "conflict", current_name: null }) }).d, actor, view());
  assert(text(o2).includes("いまの担当：未定"));
});

Deno.test("窓の送信: 権限なし・設定 OFF・選んでいない・窓の情報が壊れている・RPC の失敗 → 窓の中にエラー（成功したようには見せない）", async () => {
  assert(text(await assigneeSubmit(deps({ answer: () => ({ ok: false, code: "denied", message: "権限がありません" }) }).d, actor, view())).startsWith("権限がありません"));
  const off = deps({ enabled: false });
  assert(text(await assigneeSubmit(off.d, actor, view())).includes("まだ使えません"));
  assertEquals(off.calls.length, 0);
  const none = deps();
  assert(text(await assigneeSubmit(none.d, actor, view({}, null))).includes("選んでください"));
  assert(text(await assigneeSubmit(none.d, actor, view({ private_metadata: "{" }))).includes("読めませんでした"));
  assert(text(await assigneeSubmit(none.d, actor, view({ id: "" }))).includes("読めませんでした"));
  assertEquals(none.calls.length, 0);
  assert(text(await assigneeSubmit(deps({ error: "db down" }).d, actor, view())).includes("変更できませんでした"));
  assert(text(await assigneeSubmit(deps({ answer: () => ({ ok: false, code: "invalid_assignee", message: "選んだ人は、この応募者の担当にできません" }) }).d, actor, view())).includes("担当にできません"));
  for (const o of [await assigneeSubmit(deps({ error: "x".repeat(500) }).d, actor, view())]) assert(text(o).length <= 180);
});

Deno.test("窓: 氏名に Slack の記法になる文字があっても、そのまま出さない", () => {
  // deno-lint-ignore no-explicit-any
  const v = assigneeModal({ applicant_id: A1, expected_assignee: null, notification_id: null }, { applicantName: "<!channel> 太郎", currentName: "<@U1>", candidates: [{ id: U1, name: "a|b<c>" }] }) as any;
  const all = JSON.stringify(v);
  assert(!all.includes("<!channel>") && !all.includes("<@U1>") && !all.includes("a|b<c>"));
});

// ---- 2026-11-27 ［応募者へ LINE 返信］: 入力 → 確認 → 送信（送るのは recruit-action。ここでは、にせものを渡す） ----
type Act = Record<string, unknown>;
// deno-lint-ignore no-explicit-any
function ldeps(o: { enabled?: boolean; check?: any; send?: any; sendThrows?: boolean } = {}) {
  const acts: Act[] = []; const tells: { place: Place; text: string }[] = [];
  const d: RecruitDeps = {
    actionsEnabled: () => Promise.resolve(o.enabled !== false),
    rpc: () => Promise.resolve({ data: null, error: { message: "rpc は使わない" } }),
    action: (body) => { acts.push(body); if (body.op === "message_send") { if (o.sendThrows) return Promise.reject(new Error("net")); return Promise.resolve(o.send ?? { ok: true, code: "dry", status: "dry_done", mode: "dry" }); } return Promise.resolve(o.check ?? CHECK_OK); },
    tell: (place, text) => { tells.push({ place, text }); return Promise.resolve(); },
  };
  return { d, acts, tells };
}
const CHECK_OK = { ok: true, can_send: true, code: "ok", applicant_name: "試験 太郎", linked: true, is_test: true, send_enabled: false, mode: "dry" };
const PLACE = { channel_id: "C0TEST", thread_ts: "1700000000.000100" };
const LMETA = { applicant_id: A1, notification_id: N1, name: "試験 太郎", channel_id: "C0TEST", thread_ts: "1700000000.000100" };
// deno-lint-ignore no-explicit-any
const inputView = (bodyText: string | null, x: Record<string, unknown> = {}): any => ({ id: "V0INPUT0001", root_view_id: "V0INPUT0001", callback_id: LINE_MODAL, private_metadata: JSON.stringify(LMETA), state: { values: { body: { body: { value: bodyText } } } }, ...x });
// deno-lint-ignore no-explicit-any
const confirmView = (bodyText = "ご連絡ありがとうございます。", x: Record<string, unknown> = {}): any => ({ id: "V0CONFIRM01", root_view_id: "V0INPUT0001", callback_id: LINE_CONFIRM, private_metadata: JSON.stringify({ ...LMETA, body: bodyText }), state: { values: {} }, ...x });
// deno-lint-ignore no-explicit-any
const texts = (view: any) => JSON.stringify(view.blocks);

Deno.test("LINE 返信: ボタンと窓の名前", () => assertEquals([LINE_ACTION, LINE_MODAL, LINE_CONFIRM], ["recruit.line.open", "recruit.line.modal", "recruit.line.confirm"]));

Deno.test("LINE 返信のボタン: 設定が OFF・権限なし・LINE 未連携・送信のスイッチが OFF → 窓を開かず、本人だけに理由", async () => {
  const off = ldeps({ enabled: false });
  assert(text(await lineOpen(off.d, actor, { applicant_id: A1 }, PLACE)).includes("まだ使えません"));
  assertEquals(off.acts.length, 0);
  assert(text(await lineOpen(ldeps({ check: { ok: false, code: "denied", message: "権限がありません" } }).d, actor, { applicant_id: A1 })).startsWith("権限がありません"));
  assertEquals(text(await lineOpen(ldeps({ check: { ok: true, can_send: false, code: "not_linked", message: "この応募者は LINE と連携していないため、ここからは送れません" } }).d, actor, { applicant_id: A1 })), "この応募者は LINE と連携していないため、ここからは送れません");
  assert(text(await lineOpen(ldeps({ check: { ok: true, can_send: false, code: "disabled", message: "応募者への送信は、まだ使えません（送信のスイッチが OFF です）" } }).d, actor, { applicant_id: A1 })).includes("送信のスイッチが OFF"));
  assertEquals((await lineOpen(ldeps().d, actor, { applicant_id: "x" })).kind, "ephemeral");
  const noAction: RecruitDeps = { actionsEnabled: () => Promise.resolve(true), rpc: () => Promise.resolve({ data: null, error: null }) };
  assertEquals((await lineOpen(noAction, actor, { applicant_id: A1 })).kind, "ephemeral");
});

Deno.test("LINE 返信のボタン: 入力の窓を開く（宛先・本文の欄）。試しモードのときは、そう書く。押した場所を控える。ここでは送らない", async () => {
  const { d, acts } = ldeps();
  const o = await lineOpen(d, actor, { applicant_id: A1, notification_id: N1 }, PLACE);
  assert(o.kind === "modal");
  // deno-lint-ignore no-explicit-any
  const v = o.view as any;
  assertEquals([v.callback_id, v.title.text, v.submit.text], [LINE_MODAL, "応募者へ LINE 返信", "確認へ"]);
  assertEquals(JSON.parse(v.private_metadata), LMETA);
  assert(texts(v).includes("宛先：*試験 太郎* さん（LINE）") && texts(v).includes("試しモード") && texts(v).includes("スレッドのふつうの返信は社内の連絡"));
  assertEquals(v.blocks.find((b: any) => b.block_id === "body").element.max_length, 1000);
  assertEquals(acts, [{ op: "message_check", applicant_id: A1 }]);
  const live = await lineOpen(ldeps({ check: { ...CHECK_OK, mode: "live" } }).d, actor, { applicant_id: A1 }, PLACE);
  // deno-lint-ignore no-explicit-any
  assert(live.kind === "modal" && !texts((live as any).view).includes("試しモード"));
  assert(v.title.text.length <= 24);
});

Deno.test("入力の窓の［確認へ］: 確認の窓を重ねる（「この文面を、応募者の LINE へ送ります」・宛先・本文そのまま）。まだ送らない", async () => {
  const { d, acts } = ldeps();
  const o = await lineInput(d, actor, inputView("  ご連絡ありがとうございます。\n<!channel> *太字*  "));
  assert(o.kind === "push");
  // deno-lint-ignore no-explicit-any
  const v = o.view as any;
  assertEquals([v.callback_id, v.title.text, v.submit.text, v.close.text], [LINE_CONFIRM, "送信の確認", "送信する", "もどる"]);
  assert(v.blocks[0].text.text.startsWith("*この文面を、応募者の LINE へ送ります。*") && v.blocks[0].text.text.includes("宛先：*試験 太郎* さん（LINE）"));
  const bodyBlock = v.blocks.find((b: any) => b.type === "section" && b.text.type === "plain_text");
  assertEquals(bodyBlock.text.text, "ご連絡ありがとうございます。\n<!channel> *太字*");   // 記法として解釈されない形で、そのまま見せる
  assertEquals(JSON.parse(v.private_metadata), { ...LMETA, body: "ご連絡ありがとうございます。\n<!channel> *太字*" });
  assert(texts(v).includes("試しモード"));
  assertEquals(acts.map((a) => a.op), ["message_check"]);   // 確認だけ。送信は呼んでいない
  assert(v.private_metadata.length < 3000);
  const live = await lineInput(ldeps({ check: { ...CHECK_OK, mode: "live" } }).d, actor, inputView("本文"));
  // deno-lint-ignore no-explicit-any
  assert(live.kind === "push" && texts((live as any).view).includes("取り消せません") && !texts((live as any).view).includes("試しモード"));
});

Deno.test("入力の窓の［確認へ］: 空・長すぎる・設定 OFF・送れなくなった → 窓の中にエラー（確認へ進まない）", async () => {
  const err = (o: RecruitOutcome) => (o.kind === "errors" ? o.errors.body : "");
  assert(err(await lineInput(ldeps().d, actor, inputView("   "))).includes("本文を入れてください"));
  assert(err(await lineInput(ldeps().d, actor, inputView(null))).includes("本文を入れてください"));
  assert(err(await lineInput(ldeps().d, actor, inputView("あ".repeat(1001)))).includes("長すぎます"));
  assert(err(await lineInput(ldeps({ enabled: false }).d, actor, inputView("本文"))).includes("まだ使えません"));
  assert(err(await lineInput(ldeps({ check: { ok: true, can_send: false, code: "not_linked", message: "この応募者は LINE と連携していないため、ここからは送れません" } }).d, actor, inputView("本文"))).includes("連携していない"));
  assert(err(await lineInput(ldeps().d, actor, inputView("本文", { private_metadata: "{" }))).includes("読めませんでした"));
});

Deno.test("確認の窓の［送信する］: 窓を閉じ、そのあとで message_send を 1 回だけ（依頼の鍵＝最初の窓の番号）。結果を、押した人だけに知らせる", async () => {
  const { d, acts, tells } = ldeps();
  const o = await lineConfirm(d, actor, confirmView());
  assert(o.kind === "clear" && typeof o.after === "function");
  assertEquals(acts.length, 0, "返事の前には、何も呼ばない");
  await o.after!();
  assertEquals(acts, [{ op: "message_send", applicant_id: A1, text: "ご連絡ありがとうございます。", request_key: "slack:line:V0INPUT0001", purpose: "reply" }]);
  assertEquals(tells, [{ place: PLACE, text: "🧪 試しモードのため、試験 太郎 さんへは送っていません（送信箱に「試し」と残しました）。" }]);
  // Slack が同じ送信をもう一度届けた: 依頼の鍵は同じ（送信箱が 1 回だけにする）
  const again = ldeps({ send: { ok: true, code: "replayed", replayed: true, status: "dry_done" } });
  const o2 = await lineConfirm(again.d, actor, confirmView());
  assert(o2.kind === "clear"); await o2.after!();
  assertEquals(again.acts[0].request_key, "slack:line:V0INPUT0001");
  assert(again.tells[0].text.startsWith("🧪"));
});

Deno.test("確認の窓の［送信する］の結果の知らせ: 送信成功・失敗・結果不明・断られた・入口が呼べない。成功したようには見せない", async () => {
  const run = async (send: unknown, throws = false) => { const x = ldeps({ send, sendThrows: throws }); const o = await lineConfirm(x.d, actor, confirmView()); assert(o.kind === "clear"); await o.after!(); return x.tells[0].text; };
  assertEquals(await run({ ok: true, code: "sent", status: "sent", mode: "live" }), "✅ 試験 太郎 さんへ、LINE で送りました。");
  assert((await run({ ok: false, code: "failed", message: "LINE を送れませんでした: LINE の応答: 400" })).startsWith("⚠️ 試験 太郎 さんへは送っていません: LINE を送れませんでした"));
  const u = await run({ ok: false, code: "unknown", message: "LINE を送れたか、確認できていません（自動では再送しません）" });
  assert(u.startsWith("⚠️ LINE を送れたか、確認できていません") && u.includes("もう一度送る前に"));
  assert((await run({ ok: false, code: "disabled", message: "応募者への送信は、まだ使えません（送信のスイッチが OFF です）" })).includes("送っていません: 応募者への送信は、まだ使えません"));
  assert((await run({ ok: false, code: "denied", message: "権限がありません" })).includes("送っていません: 権限がありません"));
  assert((await run({ ok: false, code: "duplicate_recent", message: "同じ文面を、直前（10 分以内）に送っています" })).includes("直前"));
  assert((await run(null, true)).includes("送っていません: 送信の入口を呼べませんでした"));
});

Deno.test("確認の窓: 窓の情報が壊れている → 何も送らずに閉じ、本人だけに知らせる", async () => {
  for (const v of [confirmView("ok", { private_metadata: "{" }), confirmView("   "), confirmView("ok", { id: "", root_view_id: "" })]) {
    const { d, acts, tells } = ldeps();
    const o = await lineConfirm(d, actor, v);
    assert(o.kind === "clear"); await o.after?.();
    assertEquals(acts.length, 0);
    assert(tells.length === 1 && tells[0].text.includes("応募者には送っていません"));
  }
});

// ---- 2026-11-29 ［面接を確定］［面接を変更］［面接を取り消す］: 入力 → 確認 → 確定（確定するのは recruit-action。ここでは、にせものを渡す） ----
const NOW = Date.parse("2026-11-16T03:00:00Z");
const INFO: InterviewInfo = {
  ok: true, name: "試験 太郎", is_test: true, linked: true, assignee_id: U2, interview_at: null, interview_mode: null, interview_place: null, interview_url: null,
  prefs: [{ mode: "exact", date: "2026-11-20", from: "14:00" }, { mode: "range", date: "2026-11-21", from: "9:30", to: "12:00" }, { mode: "any", note: "平日の夜" }, { mode: "exact", date: "2026-11-24", from: "18:00" }],
  format_wish: "online", places: [{ name: "テスト本店", address: "東京都テスト区1-2-3", note: "入口は裏側です。" }, { name: "テスト駅前店", address: "", note: "" }],
  enabled: false, line_mode: "dry", calendar_mode: "dry",
};
// deno-lint-ignore no-explicit-any
function vdeps(o: { enabled?: boolean; info?: InterviewInfo; result?: any; throws?: boolean } = {}) {
  const acts: Act[] = []; const tells: { place: Place; text: string }[] = []; let infoCalls = 0;
  const d: RecruitDeps = {
    actionsEnabled: () => Promise.resolve(o.enabled !== false),
    rpc: () => Promise.resolve({ data: null, error: { message: "rpc は使わない" } }),
    action: (body) => { acts.push(body); if (o.throws) return Promise.reject(new Error("net")); return Promise.resolve(o.result ?? { ok: true, code: "done", interview: { at: "2026-11-20T05:00:00.000Z", mode: "online", place: null }, calendar: { ok: true, mode: "dry" }, notice: { status: "dry" } }); },
    interviewInfo: () => { infoCalls++; return Promise.resolve(o.info ?? INFO); },
    tell: (place, text) => { tells.push({ place, text }); return Promise.resolve(); },
  };
  return { d, acts, tells, infoCalls: () => infoCalls };
}
const IVMETA = { ...LMETA, exp_at: null, exp_asg: U2, linked: true };
// deno-lint-ignore no-explicit-any
const ivView = (vals: Record<string, any>, meta: Record<string, unknown> = IVMETA, x: Record<string, unknown> = {}): any => ({
  id: "V0IVINPUT01", root_view_id: "V0IVINPUT01", callback_id: INTERVIEW_MODAL, private_metadata: JSON.stringify(meta),
  state: { values: {
    pick: { pick: { selected_option: vals.pick ? { value: vals.pick } : null } }, at: { at: { selected_date_time: vals.at ?? null } },
    mode: { mode: { selected_option: vals.mode ? { value: vals.mode } : null } }, place: { place: { selected_option: vals.place ? { value: vals.place } : null } },
    notify: { notify: { selected_options: vals.notify === false ? [] : [{ value: "yes" }] } },
  } }, ...x,
});
// deno-lint-ignore no-explicit-any
const blockOf = (view: any, id: string) => view.blocks.find((b: any) => b.block_id === id);
const errOf = (o: RecruitOutcome) => (o.kind === "errors" ? Object.entries(o.errors)[0] : ["", ""]);

Deno.test("面接: ボタンと窓の名前。希望日時を、確定できる日時（日本時間 → ISO）にする", () => {
  assertEquals([INTERVIEW_ACTION, INTERVIEW_CANCEL_ACTION, INTERVIEW_MODAL, INTERVIEW_CONFIRM, INTERVIEW_CANCEL_MODAL], ["recruit.interview.open", "recruit.interview.cancel", "recruit.interview.modal", "recruit.interview.confirm", "recruit.interview.cancel.modal"]);
  assertEquals(prefToIso({ mode: "exact", date: "2026-11-20", from: "14:00" }), "2026-11-20T05:00:00.000Z");
  assertEquals(prefToIso({ mode: "range", date: "2026-11-21", from: "9:30", to: "12:00" }), "2026-11-21T00:30:00.000Z");   // 時間帯は、始まりの時刻
  assertEquals(prefToIso({ mode: "exact", date: "2026-11-20", from: "00:15" }), "2026-11-19T15:15:00.000Z");
  for (const bad of [{ mode: "any" }, { mode: "exact", date: "2026-11-20" }, { mode: "exact", date: "11/20", from: "14:00" }, { mode: "exact", date: "2026-11-20", from: "25:00" }, null, "x"]) assertEquals(prefToIso(bad), null);
});

Deno.test("面接のボタン: 入力の窓（希望日時は最大 3 件から選べる・別の日時・やり方の初期値は本人の希望・場所の一覧・案内のチェック・試しモードの注意）", async () => {
  const { d, acts } = vdeps();
  const o = await interviewOpen(d, actor, { applicant_id: A1, notification_id: N1 }, PLACE);
  assert(o.kind === "modal");
  // deno-lint-ignore no-explicit-any
  const v = o.view as any;
  assertEquals([v.callback_id, v.title.text, v.submit.text], [INTERVIEW_MODAL, "面接を確定", "確認へ"]);
  assertEquals(JSON.parse(v.private_metadata), IVMETA);   // 見ていた値（面接日時＝なし・担当＝U2）を控える
  // deno-lint-ignore no-explicit-any
  assertEquals(blockOf(v, "pick").element.options.map((x: any) => [x.text.text, x.value]), [["11/20（金）14:00", "2026-11-20T05:00:00.000Z"], ["11/21（土）9:30〜12:00", "2026-11-21T00:30:00.000Z"]]);
  assert(texts(v).includes("そのほかの希望：いつでも（平日の夜）") && !texts(v).includes("11/24"), "4 件目は出さない。「いつでも」は選べないので、文字で見せる");
  assertEquals(blockOf(v, "at").element.type, "datetimepicker");
  assertEquals(blockOf(v, "mode").element.initial_option.value, "online");
  // deno-lint-ignore no-explicit-any
  assertEquals(blockOf(v, "place").element.options.map((x: any) => x.value), ["テスト本店", "テスト駅前店"]);
  assertEquals(blockOf(v, "notify").element.initial_options.length, 1);
  assert(texts(v).includes("カレンダーは試しモード") && texts(v).includes("LINE は試しモード") && texts(v).includes("いまの面接：未定"));
  assertEquals(acts.length, 0, "窓を開くだけでは、何も確定しない");
  assert(v.title.text.length <= 24 && v.private_metadata.length < 3000);
  // 変更のとき: いまの面接を見せ、やり方・場所の初期値は、いまの値。LINE 未連携なら、案内のチェックを出さない
  const ch = await interviewOpen(vdeps({ info: { ...INFO, linked: false, interview_at: "2026-11-20T05:00:00+00:00", interview_mode: "onsite", interview_place: "テスト本店" } }).d, actor, { applicant_id: A1 }, PLACE);
  assert(ch.kind === "modal");
  // deno-lint-ignore no-explicit-any
  const c = ch.view as any;
  assertEquals([c.title.text, blockOf(c, "mode").element.initial_option.value, blockOf(c, "place").element.initial_option.value, blockOf(c, "notify")], ["面接を変更", "onsite", "テスト本店", undefined]);
  assert(texts(c).includes("いまの面接：11/20（金）14:00・対面（テスト本店）") && texts(c).includes("LINE と連携していないため"));
  assertEquals(JSON.parse(c.private_metadata).exp_at, "2026-11-20T05:00:00+00:00");
});

Deno.test("面接のボタン: 設定が OFF・権限なし・実在の応募者でスイッチが閉じている → 窓を開かず、本人だけに理由", async () => {
  assert(text(await interviewOpen(vdeps({ enabled: false }).d, actor, { applicant_id: A1 })).includes("まだ使えません"));
  assert(text(await interviewOpen(vdeps({ info: { ok: false, code: "denied" } }).d, actor, { applicant_id: A1 })).startsWith("権限がありません"));
  assert(text(await interviewOpen(vdeps({ info: { ...INFO, is_test: false, enabled: false } }).d, actor, { applicant_id: A1 })).includes("面接の確定は、まだここからは使えません"));
  assertEquals((await interviewOpen(vdeps({ info: { ...INFO, is_test: false, enabled: true } }).d, actor, { applicant_id: A1 })).kind, "modal");
  assertEquals((await interviewOpen(vdeps().d, actor, { applicant_id: "x" })).kind, "ephemeral");
  assert(text(await interviewCancelOpen(vdeps().d, actor, { applicant_id: A1 })).includes("面接の日程は、入っていません"));
});

Deno.test("入力の窓の［確認へ］: 確認の窓（日時・やり方・カレンダー・案内の文面＝画面と同じ文面）。まだ確定しない", async () => {
  const { d, acts } = vdeps();
  const o = await interviewInput(d, actor, ivView({ pick: "2026-11-20T05:00:00.000Z", mode: "online" }), NOW);
  assert(o.kind === "push");
  // deno-lint-ignore no-explicit-any
  const v = o.view as any;
  assertEquals([v.callback_id, v.title.text, v.submit.text, v.close.text], [INTERVIEW_CONFIRM, "面接の確認", "確定する", "もどる"]);
  assertEquals(JSON.parse(v.private_metadata), { ...IVMETA, at: "2026-11-20T05:00:00.000Z", mode: "online", place: null, notify: true });
  const head = v.blocks[0].text.text as string;
  assert(head.includes("日時：*11/20（金）14:00*") && head.includes("やり方：オンライン") && head.includes("カレンダー：🧪 試しモード") && head.includes("応募者への案内：🧪 試しモード"));
  // deno-lint-ignore no-explicit-any
  const body = v.blocks.find((b: any) => b.type === "section" && b.text.type === "plain_text").text.text;
  assertEquals(body, interviewText({ name: "試験 太郎", interview_at: "2026-11-20T05:00:00.000Z", interview_mode: "online", interview_url: "（確定のときに発行します）" }, null));
  assertEquals(acts.length, 0);
  // 別の日時（入力）・対面・場所つき・案内を送らない
  const sec = Date.parse("2026-11-22T01:00:00Z") / 1000;
  const o2 = await interviewInput(vdeps({ info: { ...INFO, line_mode: "live", calendar_mode: "live" } }).d, actor, ivView({ at: sec, mode: "onsite", place: "テスト本店", notify: false }), NOW);
  assert(o2.kind === "push");
  // deno-lint-ignore no-explicit-any
  const v2 = o2.view as any;
  assertEquals(JSON.parse(v2.private_metadata), { ...IVMETA, at: "2026-11-22T01:00:00.000Z", mode: "onsite", place: "テスト本店", notify: false });
  assert(v2.blocks[0].text.text.includes("やり方：対面（テスト本店）") && v2.blocks[0].text.text.includes("カレンダー：予定を登録します") && v2.blocks[0].text.text.includes("応募者への案内：送りません"));
  assertEquals(v2.blocks.length, 1, "案内を送らないときは、文面を出さない");
});

Deno.test("入力の窓の［確認へ］: 日時なし・両方・過ぎた日時・やり方なし・対面で場所なし・設定が閉じた → 窓の中にエラー", async () => {
  const run = async (vals: Record<string, unknown>, o = {}) => errOf(await interviewInput(vdeps(o).d, actor, ivView(vals), NOW));
  assertEquals((await run({ mode: "online" }))[0], "at");
  assert((await run({ pick: "2026-11-20T05:00:00.000Z", at: 1795000000, mode: "online" }))[1].includes("どちらか 1 つ"));
  assert((await run({ pick: "2026-11-10T05:00:00.000Z", mode: "online" }))[1].includes("過ぎた日時"));
  assertEquals((await run({ pick: "2026-11-20T05:00:00.000Z" }))[0], "mode");
  assertEquals(await run({ pick: "2026-11-20T05:00:00.000Z", mode: "onsite" }), ["place", "対面のときは、面接場所を選んでください。"]);
  assertEquals((await run({ pick: "2026-11-20T05:00:00.000Z", mode: "onsite", place: "設定に無い店" }))[0], "place");
  assert((await run({ pick: "2026-11-20T05:00:00.000Z", mode: "online" }, { enabled: false }))[1].includes("まだ使えません"));
  assert((await run({ pick: "2026-11-20T05:00:00.000Z", mode: "online" }, { info: { ok: false, code: "denied" } }))[1].startsWith("権限がありません"));
});

Deno.test("確認の窓の［確定する］: 窓を閉じ、そのあとで interview_confirm を 1 回だけ（依頼の鍵＝最初の窓の番号・見ていた面接日時と担当つき）。結果を本人だけに知らせる", async () => {
  const meta = { ...IVMETA, at: "2026-11-20T05:00:00.000Z", mode: "online", place: null, notify: true };
  // deno-lint-ignore no-explicit-any
  const cv = (m: Record<string, unknown> = meta, x: Record<string, unknown> = {}): any => ({ id: "V0IVCONF001", root_view_id: "V0IVINPUT01", callback_id: INTERVIEW_CONFIRM, private_metadata: JSON.stringify(m), state: { values: {} }, ...x });
  const { d, acts, tells } = vdeps();
  const o = await interviewConfirmSubmit(d, actor, cv());
  assert(o.kind === "clear" && typeof o.after === "function");
  assertEquals(acts.length, 0);
  await o.after!();
  assertEquals(acts, [{ op: "interview_confirm", applicant_id: A1, at: "2026-11-20T05:00:00.000Z", mode: "online", place: null, notify: true, request_key: "slack:iv:V0IVINPUT01", expected: { interview_at: null, assignee_id: U2 } }]);
  assertEquals(tells[0].place, PLACE);
  assert(tells[0].text.startsWith("✅ 試験 太郎 さんの面接を確定しました（11/20（金）14:00・オンライン）。") && tells[0].text.includes("カレンダー：🧪 試しモード") && tells[0].text.includes("応募者への案内：🧪 試しモード"));
  const say = async (result: unknown, throws = false) => { const x = vdeps({ result, throws }); const r = await interviewConfirmSubmit(x.d, actor, cv()); assert(r.kind === "clear"); await r.after!(); return x.tells[0].text; };
  // 先に変更されていた → 何も変えていない、と知らせる
  const c = await say({ ok: false, code: "conflict", message: "先に変更されています", current_interview_at: "2026-11-19T05:00:00+00:00", current_assignee_name: "店長 次郎" });
  assert(c.includes("先に変更されています") && c.includes("11/19（木）14:00") && c.includes("担当：店長 次郎") && c.includes("何も変えていません"));
  assert((await say({ ok: false, code: "busy", message: "ほかの人が、この応募者の面接を操作しています" })).includes("確定していません: ほかの人が"));
  assert((await say({ ok: false, code: "denied", message: "社員採用の面接の確定・取り消しは、社長だけが行えます" })).includes("社長だけ"));
  // 予定の失敗・LINE の失敗 → 確定はしたが、と知らせる（成功したようには見せない）
  const p = await say({ ok: true, code: "partial", interview: { at: "2026-11-20T05:00:00.000Z", mode: "online" }, calendar: { ok: false, mode: "live", why: "GAS に届きませんでした" }, notice: { status: "failed" } });
  assert(p.startsWith("⚠️") && p.includes("カレンダー：登録できませんでした") && p.includes("LINE を送れませんでした"));
  // LINE 未連携 → 案内文を、本人にだけ見せる
  const u = await say({ ok: true, code: "done", interview: { at: "2026-11-20T05:00:00.000Z", mode: "online" }, calendar: { ok: true, mode: "live" }, notice: { status: "skipped_unlinked", text: "試験 太郎さん\n\n【面接日時】11月20日(金) 14:00" } });
  assert(u.includes("LINE 未連携") && u.includes("```試験 太郎さん") && u.includes("カレンダー：登録しました"));
  assert((await say(null, true)).includes("確定していません: 入口を呼べませんでした"));
  // LINE 未連携の応募者: 案内文を返してもらうために notify=true で呼ぶ（未連携なので、送られない）。連携ありで「送らない」を選んだら false
  const un = vdeps(); const ru = await interviewConfirmSubmit(un.d, actor, cv({ ...meta, linked: false, notify: false })); assert(ru.kind === "clear"); await ru.after!();
  assertEquals(un.acts[0].notify, true);
  const offv = vdeps(); const ro = await interviewConfirmSubmit(offv.d, actor, cv({ ...meta, notify: false })); assert(ro.kind === "clear"); await ro.after!();
  assertEquals(offv.acts[0].notify, false);
  // 窓の情報が壊れている → 何も呼ばない
  const b = vdeps(); const r = await interviewConfirmSubmit(b.d, actor, cv({ ...IVMETA, mode: "online" })); assert(r.kind === "clear"); await r.after?.();
  assertEquals([b.acts.length, b.tells[0].text.includes("確定していません")], [0, true]);
});

Deno.test("取り消し: 確かめの窓 →［取り消す］で interview_cancel を 1 回だけ（見ていた面接日時つき）。応募者へは連絡しない、と書く", async () => {
  const info = { ...INFO, interview_at: "2026-11-20T05:00:00+00:00", interview_mode: "online" };
  const { d, acts, tells } = vdeps({ info, result: { ok: true, code: "done" } });
  const o = await interviewCancelOpen(d, actor, { applicant_id: A1, notification_id: N1 }, PLACE);
  assert(o.kind === "modal");
  // deno-lint-ignore no-explicit-any
  const v = o.view as any;
  assertEquals([v.callback_id, v.title.text, v.submit.text], [INTERVIEW_CANCEL_MODAL, "面接を取り消す", "取り消す"]);
  assert(texts(v).includes("（11/20（金）14:00・オンライン）を取り消します") && texts(v).includes("応募者へは、連絡しません") && texts(v).includes("試しモード"));
  assertEquals(acts.length, 0);
  const s2 = await interviewCancelSubmit(d, actor, { id: "V0IVCANCEL1", root_view_id: "V0IVCANCEL1", private_metadata: v.private_metadata, state: { values: {} } });
  assert(s2.kind === "clear"); await s2.after!();
  assertEquals(acts, [{ op: "interview_cancel", applicant_id: A1, request_key: "slack:ivc:V0IVCANCEL1", expected: { interview_at: "2026-11-20T05:00:00+00:00", assignee_id: U2 } }]);
  assertEquals(tells[0].text, "✅ 試験 太郎 さんの面接の日程を取り消しました（応募者へは連絡していません）。");
  const ng = vdeps({ info, result: { ok: true, code: "partial" } });
  const s3 = await interviewCancelSubmit(ng.d, actor, { id: "V1", private_metadata: v.private_metadata }); assert(s3.kind === "clear"); await s3.after!();
  assert(ng.tells[0].text.includes("カレンダーの予定を消せませんでした"));
  const no = vdeps({ info, result: { ok: false, code: "conflict", current_interview_at: null } });
  const s4 = await interviewCancelSubmit(no.d, actor, { id: "V2", private_metadata: v.private_metadata }); assert(s4.kind === "clear"); await s4.after!();
  assert(no.tells[0].text.includes("先に変更されています"));
});

// ---- 2026-11-29 失敗の知らせの［もう一度］: 確かめの窓 → recruit-action（ここでは、にせものを渡す） ----
const O1 = "cccccccc-cccc-4ccc-8ccc-ccccccccccc1";
// deno-lint-ignore no-explicit-any
function rdeps(o: { enabled?: boolean; info?: any; result?: any; iv?: InterviewInfo } = {}) {
  const acts: Act[] = []; const tells: string[] = [];
  const d: RecruitDeps = {
    actionsEnabled: () => Promise.resolve(o.enabled !== false),
    rpc: () => Promise.resolve({ data: null, error: { message: "rpc は使わない" } }),
    action: (body) => { acts.push(body); return Promise.resolve(body.op === "message_retry_info" ? (o.info ?? { ok: true, can_retry: true, code: "ok", status: "failed", applicant_name: "試験 太郎", body: "元の本文\n<!channel>", mode: "live" }) : (o.result ?? { ok: true, code: "sent" })); },
    interviewInfo: () => Promise.resolve(o.iv ?? { ...INFO, interview_at: "2026-11-20T05:00:00+00:00", interview_mode: "online" }),
    tell: (_p, text) => { tells.push(text); return Promise.resolve(); },
  };
  return { d, acts, tells };
}

Deno.test("もう一度送る: 確かめの窓（宛先・元の本文そのまま）。結果不明のときは「やり取りを確かめました」のチェックが要る。ここでは送らない", async () => {
  assertEquals([RETRY_SEND_ACTION, RETRY_CAL_ACTION, RETRY_SEND_MODAL, RETRY_CAL_MODAL], ["recruit.retry.send", "recruit.retry.calendar", "recruit.retry.send.modal", "recruit.retry.calendar.modal"]);
  const { d, acts } = rdeps();
  const o = await retrySendOpen(d, actor, { applicant_id: A1, outbox_id: O1 }, PLACE);
  assert(o.kind === "modal");
  // deno-lint-ignore no-explicit-any
  const v = o.view as any;
  assertEquals([v.callback_id, v.title.text, v.submit.text], [RETRY_SEND_MODAL, "LINE を送り直す", "送り直す"]);
  assert(texts(v).includes("この文面が、応募者の LINE に届きます") && v.blocks.some((b: any) => b.type === "section" && b.text.type === "plain_text" && b.text.text === "元の本文\n<!channel>"));
  assertEquals([blockOf(v, "checked"), JSON.parse(v.private_metadata).outbox_id, JSON.parse(v.private_metadata).status], [undefined, O1, "failed"]);
  assertEquals(acts, [{ op: "message_retry_info", outbox_id: O1 }]);
  const u = await retrySendOpen(rdeps({ info: { ok: true, can_retry: true, status: "unknown", applicant_name: "試験 太郎", body: "元の本文", mode: "live" } }).d, actor, { applicant_id: A1, outbox_id: O1 }, PLACE);
  // deno-lint-ignore no-explicit-any
  assert(u.kind === "modal" && blockOf((u as any).view, "checked").element.options[0].text.text.includes("確かめました"));
  // 権限なし・送信済み・設定 OFF → 窓を開かず、本人だけに理由
  assert(text(await retrySendOpen(rdeps({ info: { ok: false, code: "denied", message: "権限がありません" } }).d, actor, { applicant_id: A1, outbox_id: O1 })).startsWith("権限がありません"));
  assert(text(await retrySendOpen(rdeps({ info: { ok: true, can_retry: false, code: "not_retryable", message: "この送信は、すでに送信済みです" } }).d, actor, { applicant_id: A1, outbox_id: O1 })).includes("送信済み"));
  assert(text(await retrySendOpen(rdeps({ enabled: false }).d, actor, { applicant_id: A1, outbox_id: O1 })).includes("まだ使えません"));
  assertEquals((await retrySendOpen(rdeps().d, actor, { applicant_id: A1, outbox_id: "x" })).kind, "ephemeral");
});

Deno.test("もう一度送る: ［送り直す］で message_retry を 1 回だけ（依頼の鍵＝窓の番号）。結果不明でチェックが無ければ、送らない", async () => {
  // deno-lint-ignore no-explicit-any
  const rv = (status: string, checked: boolean): any => ({ id: "V0RETRY0001", root_view_id: "V0RETRY0001", private_metadata: JSON.stringify({ ...LMETA, outbox_id: O1, status }), state: { values: { checked: { checked: { selected_options: checked ? [{ value: "yes" }] : [] } } } } });
  const { d, acts, tells } = rdeps();
  const o = await retrySendSubmit(d, actor, rv("failed", false));
  assert(o.kind === "clear"); assertEquals(acts.length, 0); await o.after!();
  assertEquals(acts, [{ op: "message_retry", outbox_id: O1, request_key: "slack:retry:V0RETRY0001" }]);
  assertEquals(tells, ["✅ 試験 太郎 さんへ、LINE を送り直しました。"]);
  const no = rdeps(); const e = await retrySendSubmit(no.d, actor, rv("unknown", false));
  assertEquals([e.kind, no.acts.length], ["errors", 0]);
  assertEquals((await retrySendSubmit(rdeps().d, actor, rv("unknown", true))).kind, "clear");
  const say = async (result: unknown) => { const x = rdeps({ result }); const r = await retrySendSubmit(x.d, actor, rv("failed", false)); assert(r.kind === "clear"); await r.after!(); return x.tells[0]; };
  assert((await say({ ok: true, code: "dry" })).startsWith("🧪"));
  assert((await say({ ok: false, code: "failed", message: "LINE を送れませんでした: LINE の応答: 400" })).includes("送っていません: LINE を送れませんでした"));
  assert((await say({ ok: false, code: "not_retryable", message: "この送信は、すでに送信済みです" })).includes("送信済み"));
  assert((await say({ ok: false, code: "unknown", message: "LINE を送れたか、確認できていません（自動では再送しません）" })).includes("もう一度送る前に"));
});

Deno.test("カレンダーにもう一度登録: 確かめの窓（面接の日時は変えない、と書く）→ ［登録する］で calendar_retry を 1 回だけ。面接が取り消されていれば、開かない", async () => {
  const NK = "recruit:iv:eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee1:calendar";
  const { d, acts, tells } = rdeps({ result: { ok: true, code: "done", notice: { status: "dry" } } });
  const o = await retryCalendarOpen(d, actor, { applicant_id: A1, note_key: NK }, PLACE);
  assert(o.kind === "modal");
  // deno-lint-ignore no-explicit-any
  const v = o.view as any;
  assertEquals([v.callback_id, v.title.text, v.submit.text, JSON.parse(v.private_metadata).note_key], [RETRY_CAL_MODAL, "カレンダーに登録", "登録する", NK]);
  assert(texts(v).includes("11/20（金）14:00・オンライン") && texts(v).includes("面接の日時・やり方は変えません"));
  assertEquals(blockOf(v, "notify").element.initial_options.length, 1, "URL がまだ無いオンライン面接は、案内を送る、が初期値");
  assertEquals(acts.length, 0);
  const s2 = await retryCalendarSubmit(d, actor, { id: "V0CALRETRY1", private_metadata: v.private_metadata, state: { values: { notify: { notify: { selected_options: [{ value: "yes" }] } } } } });
  assert(s2.kind === "clear"); await s2.after!();
  assertEquals(acts, [{ op: "calendar_retry", applicant_id: A1, request_key: "slack:calretry:V0CALRETRY1", notify: true, note_key: NK }]);
  assert(tells[0].startsWith("✅ 試験 太郎 さんの面接の予定を、カレンダーに登録しました。") && tells[0].includes("試しモード"));
  // URL がもうある・対面・LINE 未連携 → 案内のチェックは、初期値なし／出さない
  const has = await retryCalendarOpen(rdeps({ iv: { ...INFO, interview_at: "2026-11-20T05:00:00+00:00", interview_mode: "online", interview_url: "https://meet.example/x" } }).d, actor, { applicant_id: A1 }, PLACE);
  // deno-lint-ignore no-explicit-any
  assert(has.kind === "modal" && blockOf((has as any).view, "notify").element.initial_options === undefined);
  const on = await retryCalendarOpen(rdeps({ iv: { ...INFO, interview_at: "2026-11-20T05:00:00+00:00", interview_mode: "onsite", interview_place: "テスト本店" } }).d, actor, { applicant_id: A1, note_key: "x" }, PLACE);
  // deno-lint-ignore no-explicit-any
  assert(on.kind === "modal" && blockOf((on as any).view, "notify") === undefined && JSON.parse((on as any).view.private_metadata).note_key === null);
  assert(text(await retryCalendarOpen(rdeps({ iv: { ...INFO, interview_at: null } }).d, actor, { applicant_id: A1 })).includes("面接の日程が入っていません"));
  assert(text(await retryCalendarOpen(rdeps({ iv: { ok: false, code: "denied" } }).d, actor, { applicant_id: A1 })).startsWith("権限がありません"));
  const f = rdeps({ result: { ok: false, code: "failed", message: "カレンダーに登録できませんでした: GAS 側で失敗" } });
  const s3 = await retryCalendarSubmit(f.d, actor, { id: "V2", private_metadata: v.private_metadata, state: { values: {} } }); assert(s3.kind === "clear"); await s3.after!();
  assert(f.tells[0].includes("登録できていません") && f.acts[0].notify === false);
});

// ---- 2026-11-30 ［採用を決める］: 確認の窓（役割・所属店舗）→ recruit-action の hire（ここでは、にせものを渡す） ----
const S1 = "99999999-9999-4999-8999-999999999991", S2 = "99999999-9999-4999-8999-999999999992";
const HINFO = { ok: true, can: true, code: "ok", name: "試験 太郎", kind: "part", status: "interviewed", default_role: "AL", roles: ["AL"], stores: [{ id: S1, name: "テスト本店" }, { id: S2, name: "テスト駅前店" }], store_id: S1, linked: true, is_test: true, mode: "dry" };
// deno-lint-ignore no-explicit-any
function hdeps(o: { enabled?: boolean; info?: any; result?: any } = {}) {
  const acts: Act[] = []; const tells: string[] = [];
  const d: RecruitDeps = {
    actionsEnabled: () => Promise.resolve(o.enabled !== false),
    rpc: () => Promise.resolve({ data: null, error: { message: "rpc は使わない" } }),
    action: (body) => { acts.push(body); return Promise.resolve(body.op === "hire_info" ? (o.info ?? HINFO) : (o.result ?? { ok: true, code: "done", invite: { status: "dry" } })); },
    tell: (_p, text) => { tells.push(text); return Promise.resolve(); },
  };
  return { d, acts, tells };
}

Deno.test("採用のボタン: 確認の窓（区分・役割の初期値は区分から・所属店舗の初期値は応募店舗・招待を LINE で送るか）。ここでは採用にしない", async () => {
  assertEquals([HIRE_ACTION, HIRE_MODAL], ["recruit.hire.open", "recruit.hire.modal"]);
  const { d, acts } = hdeps();
  const o = await hireOpen(d, actor, { applicant_id: A1, notification_id: N1 }, PLACE);
  assert(o.kind === "modal");
  // deno-lint-ignore no-explicit-any
  const v = o.view as any;
  assertEquals([v.callback_id, v.title.text, v.submit.text], [HIRE_MODAL, "採用の確認", "採用にする"]);
  assert(texts(v).includes("*試験 太郎* さんを *採用* にします（区分：アルバイト・パート）") && texts(v).includes("不採用・辞退・採用の取り消しは、管理画面から"));
  // deno-lint-ignore no-explicit-any
  assertEquals([blockOf(v, "role").element.initial_option.value, blockOf(v, "role").element.options.map((x: any) => x.value), blockOf(v, "stores").element.initial_options.map((x: any) => x.value), blockOf(v, "stores").element.options.length], ["AL", ["AL"], [S1], 2]);
  assertEquals(blockOf(v, "notify").element.initial_options.length, 1);
  assertEquals(JSON.parse(v.private_metadata), { ...LMETA, exp_status: "interviewed", linked: true });
  assertEquals(acts, [{ op: "hire_info", applicant_id: A1 }]);
  // 社員（社長が開いたとき）: 役割は、社員の区分に合うものだけ。LINE 未連携なら、招待のチェックを出さず、管理画面から送る、と書く
  const e = await hireOpen(hdeps({ info: { ...HINFO, kind: "employee", default_role: "SHAIN", roles: ["SHAIN", "TENCHO", "TEAM", "HQ"], linked: false, store_id: null } }).d, actor, { applicant_id: A1 }, PLACE);
  assert(e.kind === "modal");
  // deno-lint-ignore no-explicit-any
  const ev = e.view as any;
  // deno-lint-ignore no-explicit-any
  assertEquals([blockOf(ev, "role").element.options.map((x: any) => x.text.text), blockOf(ev, "stores").element.initial_options, blockOf(ev, "notify")], [["社員", "店長", "チーム長", "本部"], undefined, undefined]);
  assert(texts(ev).includes("区分：社員") && texts(ev).includes("LINE と連携していないため"));
});

Deno.test("採用のボタン: 決められないとき（権限・社員採用は社長だけ・区分が分からない・スイッチ・採用済み・設定 OFF）は、窓を開かず、本人だけに理由", async () => {
  for (const [info, word] of [[{ ok: false, code: "denied", message: "権限がありません" }, "権限がありません"], [{ ok: true, can: false, code: "employee_ceo_only", message: "社員採用の最終決定は、社長だけが行えます" }, "社長だけ"],
    [{ ok: true, can: false, code: "kind_unknown", message: "雇用区分（アルバイト／社員）が決まっていません。管理画面で、区分を先に決めてください" }, "区分を先に決めてください"],
    [{ ok: true, can: false, code: "disabled", message: "採用の決定は、まだここからは使えません（スイッチが OFF です）。管理画面から操作してください" }, "スイッチが OFF"], [{ ok: true, can: false, code: "already_hired", message: "すでに採用済みです" }, "採用済み"]] as [unknown, string][]) {
    const o = await hireOpen(hdeps({ info }).d, actor, { applicant_id: A1 });
    assert(o.kind === "ephemeral" && o.text.includes(word), word);
  }
  const off = hdeps({ enabled: false });
  assert(text(await hireOpen(off.d, actor, { applicant_id: A1 })).includes("まだ使えません")); assertEquals(off.acts.length, 0);
  assertEquals((await hireOpen(hdeps().d, actor, { applicant_id: "x" })).kind, "ephemeral");
});

Deno.test("確認の窓の［採用にする］: 窓を閉じ、そのあとで hire を 1 回だけ（依頼の鍵＝窓の番号・見ていた状態つき）。結果を本人だけに知らせる。招待リンクは出さない", async () => {
  // deno-lint-ignore no-explicit-any
  const hv = (vals: { role?: string; stores?: string[]; notify?: boolean }, meta: Record<string, unknown> = { ...LMETA, exp_status: "interviewed", linked: true }): any => ({ id: "V0HIRE00001", root_view_id: "V0HIRE00001", callback_id: HIRE_MODAL, private_metadata: JSON.stringify(meta),
    state: { values: { role: { role: { selected_option: vals.role ? { value: vals.role } : null } }, stores: { stores: { selected_options: (vals.stores ?? []).map((value) => ({ value })) } }, notify: { notify: { selected_options: vals.notify === false ? [] : [{ value: "yes" }] } } } } });
  const { d, acts, tells } = hdeps();
  const o = await hireSubmit(d, actor, hv({ role: "AL", stores: [S1, S2] }));
  assert(o.kind === "clear" && typeof o.after === "function"); assertEquals(acts.length, 0); await o.after!();
  assertEquals(acts, [{ op: "hire", applicant_id: A1, role: "AL", store_ids: [S1, S2], notify: true, request_key: "slack:hire:V0HIRE00001", expected: { status: "interviewed" } }]);
  assertEquals(tells, ["🎉 試験 太郎 さんを採用にしました（役割：アルバイト）。🧪 招待リンクは試しモード（本人には届いていません）。"]);
  // 役割・店舗を選んでいない → 窓の中にエラー（採用にしない）
  const e1 = hdeps(); assertEquals([(await hireSubmit(e1.d, actor, hv({ stores: [S1] }))).kind, (await hireSubmit(e1.d, actor, hv({ role: "AL" }))).kind, (await hireSubmit(e1.d, actor, hv({ role: "CEO", stores: [S1] }))).kind, e1.acts.length], ["errors", "errors", "errors", 0]);
  // LINE 未連携・送らない、を選んだ → notify=false
  const un = hdeps({ result: { ok: true, code: "done", invite: { status: "skipped_unlinked" } } }); const ru = await hireSubmit(un.d, actor, hv({ role: "AL", stores: [S1] }, { ...LMETA, exp_status: "new", linked: false })); assert(ru.kind === "clear"); await ru.after!();
  assertEquals([un.acts[0].notify, un.acts[0].expected], [false, { status: "new" }]);
  assert(un.tells[0].includes("LINE 未連携") && un.tells[0].includes("リンクを送る"));
  const say = async (result: unknown) => { const x = hdeps({ result }); const r = await hireSubmit(x.d, actor, hv({ role: "AL", stores: [S1], notify: false })); assert(r.kind === "clear"); await r.after!(); return x.tells[0]; };
  assert((await say({ ok: true, code: "done", invite: { status: "sent" } })).includes("LINE で本人に送りました"));
  assert((await say({ ok: true, code: "done", invite: { status: "failed" } })).includes("招待リンクの LINE は送れていません"));
  assert((await say({ ok: false, code: "denied", message: "社員採用の最終決定は、社長だけが行えます" })).includes("採用にしていません: 社員採用の最終決定は、社長だけ"));
  assert((await say({ ok: false, code: "conflict", message: "先に変更されています", current_status: "rejected" })).includes("先に変更されています"));
  assert((await say({ ok: true, code: "noop", message: "すでに採用済みです" })).startsWith("ℹ️ すでに採用済みです"));
  assert((await say({ ok: false, code: "kind_unknown", message: "雇用区分（アルバイト／社員）が決まっていません。管理画面で、区分を先に決めてください" })).includes("区分を先に決めてください"));
});
