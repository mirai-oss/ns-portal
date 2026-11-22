import { assert, assertEquals } from "jsr:@std/assert@1";
import { statusModal, statusOpen, statusSubmit, STATUS_CHOICES, STATUS_MODAL } from "./recruit-actions.ts";

const A = "11111111-1111-4111-8111-111111111111", ACTOR = { user_id: "22222222-2222-4222-8222-222222222222" };
const deps = (o: { on?: boolean; info?: unknown; set?: unknown; calls?: { fn: string; args: any }[] } = {}) => ({
  actionsEnabled: async () => o.on !== false,
  rpc: async (fn: string, args: any) => { o.calls?.push({ fn, args }); return { data: fn === "recruit_status_info" ? o.info : o.set, error: null }; },
}) as any;
const view = (status: string | null, extra: Record<string, unknown> = {}) => ({
  id: "V12345678", private_metadata: JSON.stringify({ applicant_id: A, expected_status: "contacted" }),
  state: { values: { status: { status: status ? { selected_option: { value: status } } : {} }, exit_stage: { exit_stage: { selected_option: extra.stage ? { value: extra.stage } : null } }, exit_reason: { exit_reason: { selected_option: extra.why ? { value: extra.why } : null } }, reason: { reason: { value: extra.memo ?? "" } } } },
});

Deno.test("窓: いまの状態は選べる一覧から除く。採用・退職は一覧に無い。送信ボタンあり", () => {
  const v: any = statusModal({ applicant_id: A, expected_status: "contacted", notification_id: null }, { applicantName: "山田 太郎", status: "contacted" });
  assertEquals([v.callback_id, v.submit.text], [STATUS_MODAL, "変更する"]);
  const vals = v.blocks.find((b: any) => b.block_id === "status").element.options.map((o: any) => o.value);
  assert(!vals.includes("contacted") && !vals.includes("hired") && !vals.includes("retired") && vals.includes("declined") && vals.includes("rejected") && vals.includes("noshow"));
  assertEquals(STATUS_CHOICES.filter((c) => c.exit).map((c) => c.value), ["rejected", "declined", "noshow"]);
});
Deno.test("開く: 設定 OFF・権限なし・採用済み（locked）は窓を出さない／そろえば窓（いまの状態が見ていた値になる）", async () => {
  assertEquals((await statusOpen(deps({ on: false }), ACTOR, { applicant_id: A })).kind, "ephemeral");
  assertEquals((await statusOpen(deps(), ACTOR, { applicant_id: "bad" })).kind, "ephemeral");
  assertEquals((await statusOpen(deps({ info: { ok: false, code: "denied" } }), ACTOR, { applicant_id: A })).kind, "ephemeral");
  assertEquals((await statusOpen(deps({ info: { ok: true, status: "hired", locked: true, applicant_name: "x" } }), ACTOR, { applicant_id: A })).kind, "ephemeral");
  const r: any = await statusOpen(deps({ info: { ok: true, status: "contacted", applicant_name: "山田 太郎" } }), ACTOR, { applicant_id: A, notification_id: "33333333-3333-4333-8333-333333333333" });
  assertEquals(r.kind, "modal");
  assertEquals(JSON.parse(r.view.private_metadata).expected_status, "contacted");
});
Deno.test("送信: 状態を RPC へ（見ていた状態・窓の番号が鍵）。終了の状態のときだけ離脱の段階・理由を渡す。成功なら窓を閉じる", async () => {
  const calls: any[] = [];
  const r = await statusSubmit(deps({ set: { ok: true, code: "done" }, calls }), ACTOR, view("declined", { stage: "before_interview", why: "declined_before_interview", memo: "本人から連絡" }));
  assertEquals(r.kind, "clear");
  const a = calls[0].args;
  assertEquals([calls[0].fn, a.p_applicant, a.p_status, a.p_expected_status, a.p_exit_stage, a.p_exit_reason, a.p_request_key, a.p_via, a.p_reason], ["recruit_status_set", A, "declined", "contacted", "before_interview", "declined_before_interview", "slack:view:V12345678", "slack", "本人から連絡"]);
  const c2: any[] = [];
  await statusSubmit(deps({ set: { ok: true }, calls: c2 }), ACTOR, view("interviewed", { stage: "interview", why: "other" }));
  assertEquals([c2[0].args.p_exit_stage, c2[0].args.p_exit_reason], [null, null]);   // 選考中の状態には、離脱は付けない
});
Deno.test("送信の失敗: 状態が未選択・設定 OFF・先に変更されている・権限なし・その他は、窓にエラーを出す", async () => {
  assertEquals((await statusSubmit(deps(), ACTOR, view(null))).kind, "errors");
  assertEquals((await statusSubmit(deps(), ACTOR, view("hired"))).kind, "errors");   // 採用は選べない
  assertEquals((await statusSubmit(deps({ on: false }), ACTOR, view("declined"))).kind, "errors");
  const conflict: any = await statusSubmit(deps({ set: { ok: false, code: "conflict", current_status: "rejected" } }), ACTOR, view("declined"));
  assert(conflict.errors.status.includes("先に変更されています") && conflict.errors.status.includes("不採用"));
  assertEquals((await statusSubmit(deps({ set: { ok: false, code: "denied" } }), ACTOR, view("declined")) as any).errors.status.includes("権限"), true);
  assertEquals((await statusSubmit(deps({ set: { ok: false, code: "locked", message: "採用・退職になっている" } }), ACTOR, view("declined")) as any).errors.status, "採用・退職になっている");
});
