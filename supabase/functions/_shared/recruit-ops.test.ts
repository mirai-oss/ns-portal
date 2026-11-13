// 採用管理の共通の操作（応募者へ 1 通送る）のテスト。DB・LINE・Slack は、にせものを渡す。deno test supabase/functions/_shared/recruit-ops.test.ts
//   RPC の中身（権限・スイッチ・試しモード・二重の確認）は、SQL 側のテスト test_recruit_outbox.sql で確かめる。ここは「RPC の答えどおりに動くか」と「LINE を呼ぶ条件」
//   ※ 氏名・LINE の宛先は、テスト用の作りもの
import { assert, assertEquals } from "jsr:@std/assert@1";
import { handleOp, messageCheck, messageSend, type OpsDeps } from "./recruit-ops.ts";
import type { LineResult } from "./recruit-line.ts";

const A1 = "11111111-1111-4111-8111-111111111111", U1 = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1", O1 = "cccccccc-cccc-4ccc-8ccc-ccccccccccc1", RK = "dddddddd-dddd-4ddd-8ddd-ddddddddddd1";
const actor = { user_id: U1, via: "slack" as const };
const TO = "Utest-not-a-real-line-id";
type W = { rpcCalls: { name: string; args: Record<string, unknown> }[]; lineCalls: unknown[][]; notes: { id: string; key: string; text: string }[]; tokenReads: number };
// deno-lint-ignore no-explicit-any
function deps(o: { begin?: any; finish?: any; check?: any; line?: LineResult | (() => Promise<LineResult>); rpcError?: string; finishError?: string; bodyChars?: number; noteFails?: boolean } = {}) {
  const w: W = { rpcCalls: [], lineCalls: [], notes: [], tokenReads: 0 };
  const d: OpsDeps = {
    rpc: (name, args) => {
      w.rpcCalls.push({ name, args });
      if (o.rpcError) return Promise.resolve({ data: null, error: { message: o.rpcError } });
      if (name === "recruit_send_begin") return Promise.resolve({ data: o.begin ?? null, error: null });
      if (name === "recruit_send_finish") return Promise.resolve(o.finishError ? { data: null, error: { message: o.finishError } } : { data: o.finish ?? { ok: true }, error: null });
      if (name === "recruit_send_check") return Promise.resolve({ data: o.check ?? null, error: null });
      return Promise.resolve({ data: null, error: { message: "unexpected rpc " + name } });
    },
    lineToken: () => { w.tokenReads++; return Promise.resolve("TOKEN"); },
    linePush: (...a) => { w.lineCalls.push(a); return typeof o.line === "function" ? o.line() : Promise.resolve(o.line ?? { status: "sent", http: 200, error: null, requestId: "r1" }); },
    threadNote: (id, key, text) => { if (o.noteFails) return Promise.reject(new Error("slack down")); w.notes.push({ id, key, text }); return Promise.resolve(); },
    bodyChars: () => Promise.resolve(o.bodyChars ?? 200),
  };
  return { d, w };
}
const req = (x: Record<string, unknown> = {}) => ({ applicant_id: A1, text: " ご連絡ありがとうございます。 ", request_key: "slack:view:V0TEST0001", ...x });
const SEND = { ok: true, code: "send", outbox_id: O1, mode: "live", status: "sending", retry_key: RK, to: TO, text: "ご連絡ありがとうございます。", applicant_name: "試験 太郎", actor_name: "担当 花子" };
const DRY = { ok: true, code: "dry", outbox_id: O1, mode: "dry", status: "dry_done", applicant_name: "試験 太郎", actor_name: "担当 花子" };

Deno.test("試しモード: LINE を呼ばない（トークンも読まない）。スレッドに「試し」と分かる 1 行。結果の記録の RPC も呼ばない", async () => {
  const { d, w } = deps({ begin: DRY });
  const r = await messageSend(d, actor, req());
  assertEquals([r.ok, r.code, r.mode, r.status], [true, "dry", "dry", "dry_done"]);
  assertEquals([w.lineCalls.length, w.tokenReads], [0, 0]);
  assertEquals(w.rpcCalls.map((c) => c.name), ["recruit_send_begin"]);
  assertEquals(w.rpcCalls[0].args, { p_applicant: A1, p_body: "ご連絡ありがとうございます。", p_purpose: "reply", p_request_key: "slack:view:V0TEST0001", p_actor: U1, p_via: "slack", p_dedupe_key: null });
  assertEquals(w.notes, [{ id: A1, key: `recruit:outbox:${O1}:dry`, text: "🧪 試しモード：LINE は送っていません（操作: 担当 花子）\n> ご連絡ありがとうございます。" }]);
});

Deno.test("断られた（スイッチ OFF・LINE 未連携・権限なし・二重など）: LINE を呼ばない。スレッドにも書かない。理由を返す", async () => {
  for (const [code, message] of [["disabled", "応募者への送信は、まだ使えません"], ["not_linked", "LINE と連携していない"], ["denied", "権限がありません"], ["duplicate", "同じ内容"], ["duplicate_recent", "直前"], ["not_found", "見つかりません"]]) {
    const { d, w } = deps({ begin: { ok: false, code, message } });
    const r = await messageSend(d, actor, req());
    assertEquals([r.ok, r.code, r.message], [false, code, message]);
    assertEquals([w.lineCalls.length, w.tokenReads, w.notes.length, w.rpcCalls.length], [0, 0, 0, 1]);
  }
});

Deno.test("同じ依頼の 2 回目（replayed）: LINE を呼ばない。前の状態を返すだけ（送信中・結果不明でも、送り直さない）", async () => {
  for (const [status, ok] of [["sent", true], ["dry_done", true], ["sending", false], ["unknown", false], ["failed", false]] as [string, boolean][]) {
    const { d, w } = deps({ begin: { ok, code: "replayed", replayed: true, outbox_id: O1, status, mode: "live", message: "m" } });
    const r = await messageSend(d, actor, req());
    assertEquals([r.ok, r.code, r.replayed, r.status], [ok, "replayed", true, status]);
    assertEquals([w.lineCalls.length, w.notes.length, w.rpcCalls.length], [0, 0, 1]);
  }
});

Deno.test("本番モード・送信成功: LINE を、送信箱の再送の鍵つきで 1 回だけ → 結果を記録。スレッドには書かない（既存の通知が「こちらから」を出す）", async () => {
  const { d, w } = deps({ begin: SEND });
  const r = await messageSend(d, actor, req());
  assertEquals([r.ok, r.code, r.status, r.mode, r.outbox_id], [true, "sent", "sent", "live", O1]);
  assertEquals(w.lineCalls, [["TOKEN", TO, "ご連絡ありがとうございます。", RK]]);
  assertEquals(w.rpcCalls.map((c) => c.name), ["recruit_send_begin", "recruit_send_finish"]);
  assertEquals(w.rpcCalls[1].args, { p_outbox: O1, p_status: "sent", p_error: null, p_response: { http: 200, request_id: "r1" } });
  assertEquals(w.notes.length, 0);
  assert(!JSON.stringify(r).includes(TO) && !JSON.stringify(r).includes("ご連絡"), "返す値に、LINE の宛先・本文を入れない");
});

Deno.test("本番モード・送信失敗: 記録して、スレッドに「送れませんでした」。成功したようには返さない。再送しない", async () => {
  const { d, w } = deps({ begin: SEND, line: { status: "failed", http: 400, error: "LINE の応答: 400 invalid <to>", requestId: null } });
  const r = await messageSend(d, actor, req());
  assertEquals([r.ok, r.code, r.status], [false, "failed", "failed"]);
  assertEquals([w.lineCalls.length, w.rpcCalls[1].args.p_status, w.rpcCalls[1].args.p_error], [1, "failed", "LINE の応答: 400 invalid <to>"]);
  assertEquals(w.notes.length, 1);
  assertEquals(w.notes[0].key, `recruit:outbox:${O1}:failed`);
  assert(w.notes[0].text.startsWith("⚠️ LINE を送れませんでした（操作: 担当 花子）。応募者には届いていません。") && !w.notes[0].text.includes("<to>") && !w.notes[0].text.includes(TO));
});

Deno.test("本番モード・結果不明（返事が来ない・送る処理が止まった）: 記録して、スレッドに知らせる。自動では再送しない", async () => {
  const a = deps({ begin: SEND, line: { status: "unknown", http: null, error: "LINE から返事がありません: TimeoutError", requestId: null } });
  const r = await messageSend(a.d, actor, req());
  assertEquals([r.ok, r.code, a.w.lineCalls.length, a.w.rpcCalls[1].args.p_status], [false, "unknown", 1, "unknown"]);
  assert(a.w.notes[0].text.includes("確認できていません") && a.w.notes[0].text.includes("自動では再送しません"));
  const b = deps({ begin: SEND, line: () => Promise.reject(new Error("boom")) });
  const r2 = await messageSend(b.d, actor, req());
  assertEquals([r2.code, b.w.lineCalls.length, b.w.rpcCalls[1].args.p_status], ["unknown", 1, "unknown"]);
});

Deno.test("LINE は送れたが、記録に失敗: 成功とは返さず、「もう一度は送らないで」とはっきり知らせる", async () => {
  const { d, w } = deps({ begin: SEND, finishError: "db down" });
  const r = await messageSend(d, actor, req());
  assertEquals([r.ok, r.code, w.lineCalls.length], [false, "sent_unrecorded", 1]);
  assert(w.notes[0].text.includes("記録に失敗") && w.notes[0].text.includes("もう一度は送らないで"));
});

Deno.test("入力の間違い・RPC の失敗・RPC の答えが足りない → LINE を呼ばない", async () => {
  const { d, w } = deps({ begin: SEND });
  assertEquals((await messageSend(d, actor, req({ applicant_id: "x" }))).code, "bad_request");
  assertEquals((await messageSend(d, actor, req({ text: "   " }))).code, "bad_request");
  assertEquals((await messageSend(d, actor, req({ request_key: "short" }))).code, "bad_request");
  assertEquals([w.rpcCalls.length, w.lineCalls.length], [0, 0]);
  const e = deps({ rpcError: "timeout" });
  assertEquals([(await messageSend(e.d, actor, req())).code, e.w.lineCalls.length], ["error", 0]);
  for (const begin of [{ ...SEND, to: "" }, { ...SEND, retry_key: null }, { ...SEND, outbox_id: "x" }, { ok: true, code: "something" }, null]) {
    const x = deps({ begin });
    assertEquals([(await messageSend(x.d, actor, req())).ok, x.w.lineCalls.length], [false, 0]);
  }
});

Deno.test("スレッドへの記録に失敗しても、結果は返る。本文の長さは設定（body_chars）に合わせる。面接の案内は、用途と内容の鍵を渡す", async () => {
  const a = deps({ begin: DRY, noteFails: true });
  assertEquals((await messageSend(a.d, actor, req())).code, "dry");
  const b = deps({ begin: DRY, bodyChars: 0 });
  await messageSend(b.d, actor, req({ text: "090-1234-5678 に電話ください" }));
  assert(b.w.notes[0].text.endsWith("> （本文は管理画面で確認してください）"));
  const c = deps({ begin: DRY });
  await messageSend(c.d, actor, req({ text: "090-1234-5678 に電話ください" }));
  assert(c.w.notes[0].text.endsWith("> （電話番号） に電話ください"), "スレッドに出す本文は、電話らしい文字を伏せる");
  const e = deps({ begin: DRY });
  await messageSend(e.d, { user_id: U1, via: "web" }, req({ purpose: "interview_notice", dedupe_key: "interview:abc:1" }));
  assertEquals([e.w.rpcCalls[0].args.p_purpose, e.w.rpcCalls[0].args.p_dedupe_key, e.w.rpcCalls[0].args.p_via], ["interview_notice", "interview:abc:1", "web"]);
});

Deno.test("確認（message_check）と振り分け", async () => {
  const { d, w } = deps({ check: { ok: true, can_send: false, code: "not_linked", message: "この応募者は LINE と連携していないため、ここからは送れません", applicant_name: "試験 太郎", linked: false, is_test: true, send_enabled: false, line_mode: "dry" } });
  const r = await messageCheck(d, actor, { applicant_id: A1 });
  assertEquals([r.ok, r.can_send, r.code, r.linked, r.mode, r.applicant_name], [true, false, "not_linked", false, "dry", "試験 太郎"]);
  assertEquals(w.rpcCalls, [{ name: "recruit_send_check", args: { p_applicant: A1, p_actor: U1 } }]);
  assertEquals((await handleOp(d, actor, { op: "message_check", applicant_id: A1 })).code, "not_linked");
  assertEquals((await handleOp(d, actor, { op: "nope" })).code, "unknown_op");
  assertEquals((await handleOp(deps({ begin: DRY }).d, actor, { op: "message_send", ...req() })).code, "dry");
  assertEquals([w.lineCalls.length, w.notes.length], [0, 0]);
});
