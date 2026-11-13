// 採用管理の共通の操作（採用を決める）のテスト。DB・LINE・Slack は、にせものを渡す。
//   採用の処理そのもの（既存の hire_applicant）と、権限・雇用区分・社員採用は社長だけ・スイッチ・同じ鍵・古い値の照合は、SQL 側のテスト test_recruit_hire.sql で確かめる
//   ※ 氏名・LINE の宛先・招待リンクは、テスト用の作りもの
import { assert, assertEquals } from "jsr:@std/assert@1";
import { handleOp, hire, hireInfo, INVITE_BASE, type OpsDeps } from "./recruit-ops.ts";
import type { LineResult } from "./recruit-line.ts";

const A1 = "11111111-1111-4111-8111-111111111111", U1 = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1", S1 = "99999999-9999-4999-8999-999999999991", OP = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee1", O1 = "cccccccc-cccc-4ccc-8ccc-ccccccccccc1";
const actor = { user_id: U1, via: "slack" as const };
const TEXT = "試験 太郎さん\n\n採用が決まりました。\n\nhttps://mirai-oss.github.io/nippo/?invite=0123456789abcdef0123456789abcdef";
const DONE = { ok: true, code: "done", op_id: OP, applicant_name: "試験 太郎", actor_name: "担当 花子", role: "AL", kind: "part", linked: true, is_test: true, invite_text: TEXT };
type W = { rpc: { name: string; args: Record<string, unknown> }[]; lines: unknown[][]; notes: { key: string; text: string }[] };
// deno-lint-ignore no-explicit-any
function deps(o: { hire?: any; sendBegin?: any; line?: LineResult; info?: any } = {}) {
  const w: W = { rpc: [], lines: [], notes: [] };
  const d: OpsDeps = {
    rpc: (name, args) => { w.rpc.push({ name, args }); return Promise.resolve({ data: name === "recruit_hire" ? (o.hire ?? DONE) : name === "recruit_send_begin" ? (o.sendBegin ?? { ok: true, code: "dry", outbox_id: O1, actor_name: "担当 花子" }) : name === "recruit_hire_info" ? (o.info ?? null) : { ok: true }, error: null }); },
    lineToken: () => Promise.resolve("TOKEN"),
    linePush: (...a) => { w.lines.push(a); return Promise.resolve(o.line ?? { status: "sent", http: 200, error: null, requestId: "r1" }); },
    threadNote: (_id, key, text) => { w.notes.push({ key, text }); return Promise.resolve(); },
    bodyChars: () => Promise.resolve(200),
  };
  return { d, w };
}
const req = (x: Record<string, unknown> = {}) => ({ applicant_id: A1, role: "AL", store_ids: [S1], request_key: "slack:hire:V0TEST0001", expected: { status: "interviewed" }, notify: true, ...x });
const names = (w: W) => w.rpc.map((c) => c.name.replace("recruit_", ""));

Deno.test("採用: RPC recruit_hire を、押した人・役割・店舗・依頼の鍵・見ていた状態つきで 1 回 → 招待の LINE は送信箱へ（用途は招待・内容の鍵つき）。招待リンクは、返す値にもスレッドにも出さない", async () => {
  const { d, w } = deps();
  const r = await hire(d, actor, req());
  assertEquals([r.ok, r.code, (r.invite as { status: string }).status], [true, "done", "dry"]);
  assertEquals(names(w), ["hire", "send_begin"]);
  assertEquals(w.rpc[0].args, { p_applicant: A1, p_role: "AL", p_store_ids: [S1], p_request_key: "slack:hire:V0TEST0001", p_actor: U1, p_via: "slack", p_expected: { status: "interviewed" }, p_invite_base: INVITE_BASE });
  assertEquals(INVITE_BASE, "https://mirai-oss.github.io/nippo/");
  const sb = w.rpc[1].args;
  assertEquals([sb.p_body, sb.p_purpose, sb.p_request_key, String(sb.p_dedupe_key).startsWith(`invite:${A1}:`)], [TEXT, "invite", `hire:${OP}:invite`, true]);
  assert(!JSON.stringify(r).includes("0123456789abcdef") && !JSON.stringify(r).includes("invite="), "返す値に、招待リンクを入れない");
  assert(w.notes.length === 1 && !w.notes[0].text.includes("0123456789abcdef") && w.notes[0].text.includes("?invite=（省略）"), "試しの行でも、招待リンクの合言葉は伏せる");
  assertEquals(w.lines.length, 0);
});

Deno.test("採用: 本番モードで招待を送れたら、招待を送った印を付ける。失敗・結果不明は、印を付けない（自動では再送しない）", async () => {
  const live = { ok: true, code: "send", outbox_id: O1, mode: "live", retry_key: "dddddddd-dddd-4ddd-8ddd-ddddddddddd1", to: "Utest", text: TEXT, actor_name: "担当 花子" };
  const { d, w } = deps({ sendBegin: live });
  const r = await hire(d, actor, req());
  assertEquals([(r.invite as { status: string }).status, names(w)], ["sent", ["hire", "send_begin", "send_finish", "invite_sent"]]);
  assertEquals(w.rpc[3].args, { p_applicant: A1, p_actor: U1 });
  for (const status of ["failed", "unknown"] as const) {
    const x = deps({ sendBegin: live, line: { status, http: null, error: "e", requestId: null } });
    const rx = await hire(x.d, actor, req());
    assertEquals([rx.ok, rx.code, (rx.invite as { status: string }).status, names(x.w).includes("invite_sent")], [true, "done", status, false]);   // 採用そのものは済んでいる
  }
});

Deno.test("採用: 招待を送らない（選ばなかった・LINE 未連携・文面が無い）ときは、送信箱を呼ばない", async () => {
  const off = deps(); const r1 = await hire(off.d, actor, req({ notify: false }));
  assertEquals([(r1.invite as { status: string }).status, names(off.w)], ["skipped_off", ["hire"]]);
  const un = deps({ hire: { ...DONE, linked: false } }); const r2 = await hire(un.d, actor, req());
  assertEquals([(r2.invite as { status: string }).status, names(un.w)], ["skipped_unlinked", ["hire"]]);
  const nt = deps({ hire: { ...DONE, invite_text: null } }); const r3 = await hire(nt.d, actor, req());
  assertEquals([(r3.invite as { status: string }).status, names(nt.w)], ["no_text", ["hire"]]);
});

Deno.test("採用: 断られた（権限・社員採用は社長だけ・区分が分からない・スイッチ・古い値）／同じ鍵の 2 回目／すでに採用済み → 招待を送らない", async () => {
  for (const [h, code, ok] of [
    [{ ok: false, code: "denied", message: "社員採用の最終決定は、社長だけが行えます" }, "denied", false], [{ ok: false, code: "kind_unknown", message: "区分を先に決めてください" }, "kind_unknown", false],
    [{ ok: false, code: "disabled", message: "まだ使えません" }, "disabled", false], [{ ok: false, code: "conflict", message: "先に変更されています", current_status: "rejected" }, "conflict", false],
    [{ ok: true, code: "replayed", replayed: true, result: "done" }, "replayed", true], [{ ok: true, code: "noop", message: "すでに採用済みです" }, "noop", true], [{ ok: true, code: "done", op_id: "x" }, "error", false], [null, "error", false],
  ] as [unknown, string, boolean][]) {
    const { d, w } = deps({ hire: h ?? { nothing: 1 } });
    const r = await hire(d, actor, req());
    assertEquals([r.ok, r.code, names(w)], [ok, code, ["hire"]]);
  }
  assertEquals((await hire(deps({ hire: { ok: false, code: "conflict", current_status: "rejected" } }).d, actor, req())).current_status, "rejected");
});

Deno.test("採用: 入力の間違い → RPC を呼ばない。材料の確かめと振り分け", async () => {
  const { d, w } = deps({ info: { ok: true, can: true, code: "ok", name: "試験 太郎", kind: "part", status: "interviewed", default_role: "AL", roles: ["AL"], stores: [{ id: S1, name: "テスト本店" }], store_id: S1, linked: true, is_test: true, line_mode: "dry", invite_text: "x" } });
  for (const x of [{ applicant_id: "x" }, { role: "" }, { role: null }, { store_ids: [] }, { store_ids: ["x"] }, { store_ids: "s" }, { request_key: "short" }]) assertEquals((await hire(d, actor, req(x))).code, "bad_request");
  assertEquals(w.rpc.length, 0);
  const i = await hireInfo(d, actor, { applicant_id: A1 });
  assertEquals([i.ok, i.can, i.kind, i.default_role, i.roles, i.store_id, i.mode], [true, true, "part", "AL", ["AL"], S1, "dry"]);
  assert(!("invite_text" in i));
  assertEquals((await handleOp(d, actor, { op: "hire_info", applicant_id: A1 })).can, true);
  assertEquals((await handleOp(deps().d, actor, { op: "hire", ...req() })).code, "done");
});
