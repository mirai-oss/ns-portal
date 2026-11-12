// 採用管理の Slack 通知（親 1 件＋スレッド）のテスト。deno test supabase/functions/_shared/recruit-notice.test.ts
//   前半: 文面（DB にも Slack にも触らない）／後半: にせものの DB と送信で、親が 1 件だけになること・二重に書かないことを確かめる
//   ※ 氏名・電話・メールは、テスト用の作りもの
import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  cardMessage, excerpt, handleEvent, historyLines, maskPII, messageLine, openLine, parentMessage, shouldOpen, snapOf, stateOf, uuidFrom, viewOf, waitingOf,
  type Applicant, type Cfg, type Db, type Msg, type Onboarding, type Refs,
} from "./recruit-notice.ts";

const A1 = "11111111-1111-4111-8111-111111111111", A2 = "22222222-2222-4222-8222-222222222222", M1 = "33333333-3333-4333-8333-333333333333";
const NOW = Date.parse("2026-11-16T03:00:00Z");   // 日本時間 11/16 12:00
const cfg: Cfg = { enabled: true, since: "2026-11-15T00:00:00Z", channelKey: "hr.saiyo", bodyChars: 200 };
const appl = (x: Partial<Applicant> = {}): Applicant => ({
  id: A1, name: "試験 太郎", source: "indeed", job_type: "ホールスタッフ", status: "new", store_id: "s1", assignee_id: null, user_id: null, applied_at: "2026-11-16T01:30:00Z",
  interview_at: null, interview_prefs: null, last_msg_at: null, last_msg_dir: null, handled_at: null, answers: { "求人": "ホールスタッフ" },
  ...({ phone: "090-0000-0000", email: "taro@example.com" } as Record<string, unknown>), ...x,
});
const view = (x: Partial<Applicant> = {}, c: { onboarding?: Onboarding | null; onboardingLink?: string | null } = {}) =>
  viewOf(appl(x), { storeName: "テスト本店", names: { u1: "担当 花子", u2: "店長 次郎" }, now: NOW, ...c });
const btns = (blocks: unknown[]) => (blocks as any[]).filter((b) => b.type === "actions").flatMap((b) => b.elements.map((e: any) => e.text.text));
const body = (blocks: unknown[]) => (blocks as any[]).filter((b) => b.type === "section").map((b) => b.text.text).join("\n");

// ---- 文面 ----
Deno.test("親メッセージは 1 行。氏名・応募店舗と、短い状態だけ", () => {
  assertEquals(parentMessage(view()).text, "👤 採用管理｜試験 太郎｜テスト本店");
  assertEquals(parentMessage(view({ status: "contacted" })).text, "👤 採用管理｜試験 太郎｜テスト本店｜面接調整中");
  assertEquals(parentMessage(view({ status: "interview_set", interview_at: "2026-11-20T05:00:00Z" })).text, "👤 採用管理｜試験 太郎｜テスト本店｜面接確定");
  assertEquals(parentMessage(view({ status: "hired" })).text, "👤 採用管理｜試験 太郎｜テスト本店｜採用決定");
  assertEquals(parentMessage(view({ status: "hired", user_id: "x1" }, { onboarding: { id: "w1", user_id: "x1" } })).text, "👤 採用管理｜試験 太郎｜テスト本店｜採用決定・入社登録へ移行済み");
  assertEquals(parentMessage(view({ status: "declined" })).text, "👤 採用管理｜試験 太郎｜テスト本店｜辞退");
  assertEquals(parentMessage(view({ store_id: null }, {})).text.split("｜")[1], "試験 太郎");
  assertEquals(btns(parentMessage(view()).blocks), []);   // リンクが取れなければボタンなし
  assertEquals(btns(parentMessage(view(), { permalink: "https://x.slack.com/archives/C1/p1" }).blocks), ["詳細を確認"]);
});

Deno.test("未対応のとき、親に未対応と担当者が出る。返信するか対応済みにすると消える", () => {
  const w = { status: "contacted", last_msg_dir: "in", last_msg_at: "2026-11-16T02:00:00Z" };
  assertEquals(parentMessage(view({ ...w, assignee_id: "u1" })).text, "👤 採用管理｜試験 太郎｜テスト本店｜面接調整中｜🔴未対応（担当 担当 花子）");
  assert(parentMessage(view(w)).text.endsWith("🔴未対応（担当 未定）"));
  assertEquals(waitingOf(appl({ ...w, handled_at: "2026-11-16T02:30:00Z" })), false);          // 対応済み
  assertEquals(waitingOf(appl({ ...w, handled_at: "2026-11-16T01:00:00Z" })), true);           // 対応済みのあとに、また届いた
  assertEquals(waitingOf(appl({ ...w, last_msg_dir: "out" })), false);                          // こちらから返信した
  assertEquals(waitingOf(appl({ ...w, status: "rejected" })), false);                           // 選考が終わっている
  assert(parentMessage(view({ status: "interview_set", interview_at: "2026-11-15T00:00:00Z" })).text.includes("🔴面接結果の入力待ち"));
});

Deno.test("状態の言葉: 管理画面のステータスから決まる", () => {
  assertEquals(stateOf(appl(), false), { label: null, code: "todo", done: false });
  assertEquals(stateOf(appl({ interview_prefs: [{ d: "2026-11-20" }] }), false).label, "面接調整中");
  assertEquals(stateOf(appl({ status: "interviewed" }), false).label, "面接済み・結果待ち");
  assertEquals(stateOf(appl({ status: "noshow" }), false), { label: "連絡なし", code: "done", done: true });
  assertEquals(stateOf(appl({ status: "rejected" }), false).label, "不採用");
});

Deno.test("カード: 概要と状態と担当。押せるのはリンクだけ。電話・メール・回答は出さない", () => {
  const c = cardMessage(view({ status: "interview_set", interview_at: "2026-11-20T05:00:00Z", interview_mode: "onsite", interview_place: "テスト本店", assignee_id: "u1" }));
  const t = body(c.blocks);
  assert(t.includes("状態：面接確定") && t.includes("応募店舗：テスト本店") && t.includes("応募媒体：Indeed（ホールスタッフ）") && t.includes("応募日時：11/16 10:30"));
  assert(t.includes("面接：11/20（金）14:00・対面（テスト本店）") && t.includes("担当：担当 花子"));
  assertEquals(btns(c.blocks), ["管理画面で開く"]);
  const url = (c.blocks as any[]).find((b) => b.type === "actions").elements[0].url;
  assertEquals(url, `https://mirai-oss.github.io/nippo/?a=${A1}`);
  const all = JSON.stringify(c) + JSON.stringify(parentMessage(view()));
  assert(!all.includes("090") && !all.includes("example.com"), "電話・メールが入っていない");
  // 入社登録へ進んだあと: 「移行済み」と、入社登録のスレッド・従業員ページへのリンク
  const h = cardMessage(view({ status: "hired", user_id: "x1" }, { onboarding: { id: "w1", user_id: "x1" }, onboardingLink: "https://x.slack.com/archives/C2/p2" }));
  assert(body(h.blocks).includes("入社登録へ移行済み"));
  assertEquals(btns(h.blocks), ["管理画面で開く", "入社登録のスレッド", "従業員ページ"]);
});

Deno.test("メッセージ本文: 電話・メールらしい文字列を伏せ、長さを切り、Slack の記法を無効にする", () => {
  assertEquals(maskPII("電話は090-1234-5678です"), "電話は（電話番号）です");
  assertEquals(maskPII("０９０１２３４５６７８ か 03 1234 5678 へ"), "（電話番号） か （電話番号） へ");
  assertEquals(maskPII("+81 90 1234 5678"), "（電話番号）");
  assertEquals(maskPII("（03）1234－5678 または 090ー1234ー5678。メールで連絡ください"), "（電話番号） または （電話番号）。メールで連絡ください");   // 全角の区切り。カタカナの「ー」は変えない
  assertEquals(maskPII("連絡先 taro.yamada+1@example.co.jp まで"), "連絡先 （メールアドレス） まで");
  assertEquals(maskPII("11/20 14:00 と 2026-11-21 10:00-12:30 なら行けます"), "11/20 14:00 と 2026-11-21 10:00-12:30 なら行けます");   // 日時は伏せない
  assertEquals(excerpt("<!channel> こんにちは\n\nよろしく & お願いします"), "&lt;!channel&gt; こんにちは よろしく &amp; お願いします");
  const long = excerpt("あ".repeat(300), 200);
  assert(long.startsWith("あ".repeat(200) + "…") && !long.includes("あ".repeat(201)));
  assertEquals(excerpt("秘密", 0), "（本文は管理画面で確認してください）");
  const m: Msg = { id: M1, channel: "line", direction: "in", body: "明日の面接ですが 09012345678 に電話ください", sent_at: "2026-11-16T02:00:00Z" };
  assertEquals(messageLine(m, { bodyChars: 200 }), "💬 応募者から（LINE・11/16 11:00）\n> 明日の面接ですが （電話番号） に電話ください");
  assert(messageLine({ ...m, direction: "out" }, { bodyChars: 200, staffName: "担当 花子" }).startsWith("↩️ こちらから（LINE・担当 花子・11/16 11:00）"));
});

Deno.test("履歴: 前回から変わったところだけ。対応が要る出来事だけメンションする", () => {
  const prev = snapOf(view());
  assertEquals(historyLines(prev, view()), []);   // 変わっていなければ何も書かない
  const k = (x: Partial<Applicant>, c = {}) => historyLines(prev, view(x, c)).map((l) => `${l.kind}${l.mention ? "@" : ""}`);
  assertEquals(k({ status: "contacted" }), ["status"]);
  assertEquals(k({ status: "interview_set", interview_at: "2026-11-20T05:00:00Z" }), ["interview", "status"]);
  assertEquals(k({ interview_prefs: [{ d: 1 }, { d: 2 }] }), ["prefs@"]);
  assertEquals(k({ form_received_at: "2026-11-16T02:00:00Z" }), ["form@"]);
  assertEquals(k({ answers: { "求人": "キッチン" } }), ["reapply@"]);
  assertEquals(k({ assignee_id: "u1" }), ["assignee"]);
  assertEquals(k({ assignee_id: "u1", last_msg_dir: "in", last_msg_at: "2026-11-16T02:00:00Z" }), ["assignee@"]);   // 未対応のまま担当が替わった
  assertEquals(k({ status: "hired", user_id: "x1" }, { onboarding: { id: "w1" } }), ["status", "moved"]);
  assertEquals(k({ status: "declined", exit_reason: "declined_before_interview", exit_stage: "before_interview" }), ["status", "exit"]);
  const hired = historyLines(prev, view({ status: "hired", last_actor_id: "u2" }))[0].text;
  assert(hired.startsWith("🎉 採用が決まりました（操作: 店長 次郎）"));
  const iv = historyLines(prev, view({ interview_at: "2026-11-20T05:00:00Z", interview_mode: "online" }))[0].text;
  assertEquals(iv, "📅 面接の日程が決まりました：11/20（金）14:00・オンライン");
  const od = historyLines(snapOf(view({ status: "interview_set", interview_at: "2026-11-15T20:00:00Z" })), viewOf(appl({ status: "interview_set", interview_at: "2026-11-15T20:00:00Z" }), { storeName: "テスト本店", now: NOW + 24 * 3600e3 }));
  assertEquals(od.map((l) => `${l.kind}${l.mention ? "@" : ""}`), ["overdue@"]);
});

Deno.test("親を作る条件: 切り替え後の応募は作る。前からいる応募者は、動きがあったときだけ", () => {
  assertEquals(shouldOpen(appl(), cfg, NOW), true);
  assertEquals(shouldOpen(appl({ source: "csv" }), cfg, NOW), false);                                         // CSV の取り込みでは作らない
  const old = { applied_at: "2026-10-01T00:00:00Z" };
  assertEquals(shouldOpen(appl({ ...old, status: "rejected" }), cfg, NOW), false);                           // 昔の応募者の整理では作らない
  assertEquals(shouldOpen(appl({ ...old, status: "contacted", last_msg_dir: "in", last_msg_at: "2026-11-16T02:00:00Z" }), cfg, NOW), true);
  assertEquals(shouldOpen(appl({ ...old, status: "interview_set", interview_at: "2026-11-20T05:00:00Z" }), cfg, NOW), true);
  assertEquals(shouldOpen(appl({ ...old, status: "hired", hired_at: "2026-11-16T00:00:00Z" }), cfg, NOW), true);
  assertEquals(shouldOpen(appl(), { ...cfg, since: null }, NOW), false);
  assert(openLine(view(), true).startsWith("📥 応募受付｜Indeed｜11/16 10:30"));
  assert(openLine(view(old), false).startsWith("🗂 このスレッドで管理を始めます"));
});

Deno.test("台帳の番号は、鍵から決まる（やり直しても同じ）", async () => {
  const a = await uuidFrom(`recruit:parent:${A1}`);
  assertEquals(a, await uuidFrom(`recruit:parent:${A1}`));
  assert(a !== await uuidFrom(`recruit:card:${A1}`) && /^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(a));
});

// ---- 読んで・送る処理（にせものの DB と送信） ----
type World = {
  cfg: Cfg; applicants: Record<string, Applicant>; cases: Record<string, Refs>; msgs: Msg[]; onb: Record<string, Onboarding>;
  locked: Record<string, string>; dirty: Record<string, boolean>; claimAllowed: boolean; failSend: (b: Record<string, unknown>) => boolean;
  sent: Record<string, unknown>[]; ledger: Record<string, { ts: string; text: unknown }>; n: number; mentionCalls: unknown[]; mergeCalls: string[][];
};
function world(x: Partial<World> = {}): World {
  return { cfg: { ...cfg }, applicants: { [A1]: appl() }, cases: {}, msgs: [], onb: {}, locked: {}, dirty: {}, claimAllowed: true, failSend: () => false, sent: [], ledger: {}, n: 0, mentionCalls: [], mergeCalls: [], ...x };
}
function fake(w: World) {
  const db: Db = {
    settings: () => Promise.resolve(w.cfg),
    applicant: (id) => Promise.resolve(w.applicants[id] ? { ...w.applicants[id] } : null),
    caseOf: (id) => Promise.resolve(w.cases[id] ? { refs: JSON.parse(JSON.stringify(w.cases[id])) } : null),
    lock: (id, token) => { if (w.locked[id] && w.locked[id] !== token) { w.dirty[id] = true; return Promise.resolve(false); } w.cases[id] ??= {}; w.locked[id] = token; w.dirty[id] = false; return Promise.resolve(true); },
    unlock: (id, token) => { if (w.locked[id] !== token) return Promise.resolve(false); if (w.dirty[id]) { w.dirty[id] = false; return Promise.resolve(true); } delete w.locked[id]; return Promise.resolve(false); },
    claim: (id) => { const c = (w.cases[id] ??= {}) as Refs & { claim_at?: string }; if (!w.claimAllowed || c.ts || c.claim_at) return Promise.resolve(false); c.claim_at = "now"; return Promise.resolve(true); },
    // 統合の付け替え（本物は SQL の recruit_notice_merge）: 消える側の応募者がもういないときだけ、控えを残る側へ寄せる
    merge: (keep, merged) => {
      w.mergeCalls.push([keep, merged]);
      const m = w.cases[merged];
      if (w.applicants[merged] || !w.applicants[keep] || !m?.ts || m.merged_into) return Promise.resolve(false);
      if (!w.cases[keep]?.ts) { const { tombstone: _t, ...rest } = m; w.cases[keep] = { ...rest, merged_from: [...(m.merged_from ?? []), { id: merged, mode: "moved" }] }; delete w.cases[merged]; }
      else { delete m.tombstone; m.merged_into = keep; w.cases[keep].merged_from = [...(w.cases[keep].merged_from ?? []), { id: merged, mode: "closed" }]; }
      return Promise.resolve(true);
    },
    saveCase: (id, patch) => { w.cases[id] = { ...(w.cases[id] ?? {}), ...((patch.slack_refs ?? {}) as Refs) }; return Promise.resolve(null); },
    names: (ids) => Promise.resolve(Object.fromEntries(ids.map((i) => [i, i === "u1" ? "担当 花子" : "店長 次郎"]))),
    storeName: () => Promise.resolve("テスト本店"),
    onboarding: (id) => Promise.resolve(w.onb[id] ?? null),
    messages: (id, since, extra) => Promise.resolve(w.msgs.filter((m) => (m as any).applicant_id === id && (String(m.sent_at) >= since || m.id === extra))),
    delivered: (keys) => Promise.resolve(new Set(keys.filter((k) => w.ledger[k]))),
    mentions: (scene, store, asg) => { w.mentionCalls.push([scene, store, asg]); return Promise.resolve(scene === "assignee" ? ["U0ASSIGN1"] : scene === "open" ? ["U0TENCHO1"] : []); },
    permalink: (ch, ts) => Promise.resolve(`https://x.slack.com/archives/${ch}/p${ts.replace(".", "")}`),
  };
  // notify-slack のにせもの: 同じ重複防止の鍵は二度送らない（送信済みの ts を返す）
  const notify = (b: Record<string, unknown>) => {
    if (w.failSend(b)) return Promise.resolve({ ok: false, error: "not_in_channel" });
    if (b.action === "update") { w.sent.push(b); return Promise.resolve({ ok: true, notification_id: String(b.notification_id) }); }
    const k = String(b.dedupe_key ?? "");
    if (k && w.ledger[k]) return Promise.resolve({ ok: true, notification_id: String(b.notification_id), ts: w.ledger[k].ts, slack_channel_id: "C0TEST", status: "duplicate" });
    const ts = `1700000000.${String(++w.n).padStart(6, "0")}`;
    if (k) w.ledger[k] = { ts, text: b.text };
    w.sent.push(b);
    return Promise.resolve({ ok: true, notification_id: String(b.notification_id), ts, slack_channel_id: "C0TEST", status: "sent" });
  };
  return { db, notify };
}
const parents = (w: World) => w.sent.filter((b) => b.action === "send" && !b.thread_ts);
const threadTexts = (w: World) => w.sent.filter((b) => b.action === "send" && b.thread_ts).map((b) => String(b.text));
const lastParentText = (w: World) => { const id = parents(w)[0]?.notification_id; const u = w.sent.filter((b) => b.notification_id === id); return String(u[u.length - 1]?.text); };
const run = (w: World, id = A1, o: { kind?: string; ref?: string } = {}) => { const f = fake(w); return handleEvent(f.db, f.notify, id, { ...o, now: NOW }); };

Deno.test("スイッチが切れているあいだは、何もしない", async () => {
  const w = world({ cfg: { ...cfg, enabled: false } });
  assertEquals(await run(w), { ok: true, skipped: "disabled" });
  const w2 = world({ cfg: { ...cfg, since: null } });
  assertEquals((await run(w2)).skipped, "disabled");
  assertEquals([w.sent.length, w2.sent.length, Object.keys(w.cases).length], [0, 0, 0]);
});

Deno.test("新しい応募: 親 1 件 → スレッドにカード → 応募受付の行。もう一度呼んでも、親は増えず、何も書かない", async () => {
  const w = world();
  const r = await run(w, A1, { kind: "created" });
  assertEquals([r.ok, r.opened], [true, true]);
  assertEquals(parents(w).length, 1);
  assertEquals([parents(w)[0].channel_key, parents(w)[0].dedupe_key, parents(w)[0].text], ["hr.saiyo", `recruit:parent:${A1}`, "👤 採用管理｜試験 太郎｜テスト本店"]);
  const th = w.sent.filter((b) => b.action === "send" && b.thread_ts);
  assertEquals(th.map((b) => b.event), ["recruit_card", "recruit_open"]);
  assert(String(th[1].text).startsWith("<@U0TENCHO1>　📥 応募受付｜Indeed"), "担当者がいないので、応募店舗の担当へ");
  assertEquals(w.mentionCalls[0], ["open", "s1", null]);
  assert(w.cases[A1].ts && w.cases[A1].parent && w.cases[A1].card && w.cases[A1].snap, "控えに親の ts と台帳の番号が残る");
  // 親に「詳細を確認」が付く（スレッドの 1 通目へのリンク）
  const upd = w.sent.filter((b) => b.action === "update" && b.notification_id === w.cases[A1].parent);
  assertEquals(btns(upd[upd.length - 1].blocks as unknown[]), ["詳細を確認"]);
  // 同じ出来事がもう一度届いた／やり直した
  const before = w.sent.length;
  const r2 = await run(w, A1, { kind: "created" });
  assertEquals([r2.ok, r2.opened, r2.replies, r2.updated, w.sent.length - before, parents(w).length], [true, false, 0, 0, 0, 1]);
  assert(!JSON.stringify(w.sent).includes("090") && !JSON.stringify(w.sent).includes("example.com") && !JSON.stringify(w.cases).includes("example.com"), "電話・メールは、どの送信にも控えにも入っていない");
});

Deno.test("親を作る権利が取れなかった実行は、親を投稿しない", async () => {
  const w = world({ claimAllowed: false });
  const r = await run(w);
  assertEquals([r.ok, r.pending, w.sent.length], [true, "claimed_by_other", 0]);
});

Deno.test("同じ応募者を別の実行が処理中なら、やり直しの印だけ付けて終わる（処理中の実行がもう一周する）", async () => {
  const w = world({ locked: { [A1]: "other" } });
  assertEquals(await run(w), { ok: true, queued: true });
  assertEquals([w.sent.length, w.dirty[A1]], [0, true]);
});

Deno.test("親の送信に失敗 → 控えに ts を残さない。やり直しは同じ台帳の番号・同じ鍵で送る（親は 1 件）", async () => {
  const w = world({ failSend: (b) => b.action === "send" && !b.thread_ts });
  const r = await run(w);
  assertEquals([r.ok, w.cases[A1].ts, parents(w).length], [false, undefined, 0]);
  w.failSend = () => false; delete (w.cases[A1] as any).claim_at;   // 時間がたって、権利を取り直せるようになった
  const r2 = await run(w);
  assertEquals([r2.ok, r2.opened, parents(w).length], [true, true, 1]);
  assertEquals(parents(w)[0].notification_id, await uuidFrom(`recruit:parent:${A1}`));
});

Deno.test("親は出たがカードで止まった → やり直しでは、親は送信済みと分かり、カードから続ける（親は増えない）", async () => {
  const w = world({ failSend: (b) => b.event === "recruit_card" });
  assertEquals((await run(w)).ok, false);
  assertEquals([parents(w).length, w.cases[A1].ts], [1, undefined]);
  w.failSend = () => false; delete (w.cases[A1] as any).claim_at;
  const r2 = await run(w);
  assertEquals([r2.ok, parents(w).length, w.cases[A1].ts], [true, 1, w.ledger[`recruit:parent:${A1}`].ts]);
});

Deno.test("応募者からのメッセージ: スレッドに返信（本文は伏せて切る）・担当者にメンション・親に未対応。二度目は書かない", async () => {
  const w = world();
  await run(w, A1, { kind: "created" });
  w.applicants[A1] = appl({ status: "contacted", assignee_id: "u1", last_msg_dir: "in", last_msg_at: "2026-11-16T02:00:00Z" });
  w.msgs.push({ id: M1, channel: "line", direction: "in", body: "taro@example.com に資料をください。電話は 090-1234-5678 です", sent_at: "2026-11-16T02:00:00Z", ...({ applicant_id: A1 } as object) });
  const r = await run(w, A1, { kind: "message", ref: M1 });
  assertEquals(r.ok, true);
  const t = threadTexts(w);
  const msg = t.find((x) => x.includes("💬 応募者から"))!;
  assert(msg.startsWith("<@U0ASSIGN1>　💬 応募者から（LINE・11/16 11:00）"), "担当者がいるので担当者へ");
  assert(msg.includes("（メールアドレス） に資料をください。電話は （電話番号） です") && !msg.includes("090") && !msg.includes("example.com"));
  assertEquals(lastParentText(w), "👤 採用管理｜試験 太郎｜テスト本店｜面接調整中｜🔴未対応（担当 担当 花子）");
  assert(t.some((x) => x.startsWith("🔄 状態：新規 → 連絡済み")) && t.some((x) => x.startsWith("👤 担当：未定 → 担当 花子")), "メンションは、応募者からのメッセージの 1 通だけ");
  assertEquals(t.filter((x) => x.includes("<@")).length, 2);   // 応募受付（店舗の担当）と、このメッセージ（担当者）
  const before = w.sent.length;
  await run(w, A1, { kind: "message", ref: M1 });   // Webhook の重複受信
  assertEquals(w.sent.length, before);
  // こちらから返信 → 未対応が消える。返信の記録はメンションなし
  w.applicants[A1] = { ...w.applicants[A1], last_msg_dir: "out", last_msg_at: "2026-11-16T02:30:00Z" };
  w.msgs.push({ id: A2, channel: "line", direction: "out", body: "承知しました", sent_at: "2026-11-16T02:30:00Z", sent_by: "u1", ...({ applicant_id: A1 } as object) });
  await run(w, A1, { kind: "message", ref: A2 });
  assertEquals(lastParentText(w), "👤 採用管理｜試験 太郎｜テスト本店｜面接調整中");
  assert(threadTexts(w).some((x) => x.startsWith("↩️ こちらから（LINE・担当 花子・11/16 11:30）")));
  assertEquals(parents(w).length, 1);
});

Deno.test("採用 → 入社登録へ移行: 親の状態が変わり、スレッドに 1 回だけ「移行済み」とリンクが出る", async () => {
  const w = world();
  await run(w);
  w.applicants[A1] = appl({ status: "hired", hired_at: "2026-11-16T02:00:00Z" });
  await run(w, A1, { kind: "updated" });
  assertEquals(lastParentText(w), "👤 採用管理｜試験 太郎｜テスト本店｜採用決定");
  w.applicants[A1] = appl({ status: "hired", hired_at: "2026-11-16T02:00:00Z", user_id: "x1" });
  w.onb[A1] = { id: "w1", status: "registering", user_id: "x1", slack_channel_id: "C0JINJI", slack_parent_ts: "1700000001.000100" };
  await run(w, A1, { kind: "onboarding" });
  await run(w, A1, { kind: "onboarding" });
  assertEquals(lastParentText(w), "👤 採用管理｜試験 太郎｜テスト本店｜採用決定・入社登録へ移行済み");
  const moved = threadTexts(w).filter((x) => x.includes("入社登録へ移行済み"));
  assertEquals(moved.length, 1);
  assert(moved[0].includes("<https://x.slack.com/archives/C0JINJI/p1700000001000100|入社登録のスレッドを開く>"));
  assertEquals(parents(w).length, 1);
});

Deno.test("前からいる応募者の小さな変更では、親も控えも作らない", async () => {
  const w = world({ applicants: { [A1]: appl({ applied_at: "2026-10-01T00:00:00Z", status: "rejected" }) } });
  assertEquals(await run(w, A1, { kind: "updated" }), { ok: true, skipped: "not_opened" });
  assertEquals([w.sent.length, Object.keys(w.cases).length], [0, 0]);
});

Deno.test("統合（両方に親がある）: 残る側のスレッドにお知らせ、消える側は「統合済み」で閉じてリンクを出す", async () => {
  const w = world({ applicants: { [A1]: appl(), [A2]: appl({ id: A2, name: "試験 太郎", source: "form" }) } });
  await run(w, A1); await run(w, A2);
  assertEquals(parents(w).length, 2);
  // 管理画面の「まとめる」（merge_applicants）: 消える側の応募者の行が無くなる。削除の知らせが先に届くこともある
  delete w.applicants[A2];
  await run(w, A2, { kind: "deleted" });
  assertEquals(w.cases[A2].tombstone, true);
  const r = await run(w, A1, { kind: "merged", ref: A2 });   // ここで、消える側の控えを閉じて、残る側に印を付ける（recruit_notice_merge）
  assertEquals([r.ok, w.mergeCalls], [true, [[A1, A2]]]);
  assert(threadTexts(w).some((x) => x.startsWith("🔀 同じ方の別の応募を、この応募にまとめました") && x.includes("統合前のスレッド")));
  const mp = w.sent.filter((b) => b.action === "update" && b.notification_id === w.cases[A2].parent).pop()!;
  assertEquals(mp.text, "👤 採用管理｜試験 太郎｜テスト本店｜統合済み");
  assertEquals(btns(mp.blocks as unknown[]), ["統合先のスレッド"]);
  assertEquals([w.cases[A2].tombstone, w.cases[A2].merged_shown, w.cases[A2].merged_into, w.cases[A1].merged_done], [true, true, A1, [A2]]);
  const before = w.sent.length;
  await run(w, A1, { kind: "merged", ref: A2 }); await run(w, A2, { kind: "deleted" });
  assertEquals([w.sent.length, parents(w).length], [before, 2]);   // 二度は書かない・親は増えない
});

Deno.test("統合（残る側に親が無い）: 控えが残る側に付け替わり、同じ親をそのまま使う（新しい親は作らない）", async () => {
  const w = world({ applicants: { [A2]: appl({ id: A2, source: "form" }) } });
  await run(w, A2);
  // 残る側は、前からいる応募者（スレッドなし）。消える側の行が無くなったあとで、統合の知らせが届く → 控えの ref_id が残る側へ付け替わる
  w.applicants = { [A1]: appl({ status: "contacted", applied_at: "2026-10-01T00:00:00Z" }) };
  const r = await run(w, A1, { kind: "merged", ref: A2 });
  assertEquals([!!w.cases[A1]?.ts, w.cases[A2]], [true, undefined]);
  assertEquals([r.ok, r.opened, parents(w).length], [true, false, 1]);
  assertEquals(lastParentText(w), "👤 採用管理｜試験 太郎｜テスト本店｜面接調整中");
  assert(!threadTexts(w).some((x) => x.startsWith("🔄 状態")), "付け替えの直後は、別の応募の状態と比べた行を書かない");
  assert(threadTexts(w).some((x) => x.startsWith("🔀 同じ方の別の応募を")));
});

Deno.test("やり取りを 1 通だけ別の応募者へ付け替えた（元の応募者はまだいる）ときは、統合として扱わない", async () => {
  const w = world({ applicants: { [A1]: appl(), [A2]: appl({ id: A2, source: "form" }) } });
  await run(w, A1); await run(w, A2);
  const before = w.sent.length;
  await run(w, A1, { kind: "merged", ref: A2 });
  assertEquals([w.sent.length, w.cases[A2].merged_into, w.cases[A1].merged_from], [before, undefined, undefined]);
});

Deno.test("削除: 親とカードを「削除済み」にして閉じる（親は消さない）。親が無ければ何もしない", async () => {
  const w = world();
  await run(w);
  delete w.applicants[A1];
  const r = await run(w, A1, { kind: "deleted" });
  assertEquals(r.ok, true);
  assertEquals(lastParentText(w), "👤 採用管理｜試験 太郎｜テスト本店｜削除済み");
  assertEquals(w.cases[A1].tombstone, true);
  const w2 = world({ applicants: {} });
  assertEquals(await run(w2, A1, { kind: "deleted" }), { ok: true, skipped: "gone" });
});

Deno.test("スレッドへの返信に失敗したら、前回の状態を進めない → 次の実行で同じ行をもう一度出す（出せた行は二重にならない）", async () => {
  const w = world();
  await run(w);
  w.applicants[A1] = appl({ status: "contacted", assignee_id: "u1" });
  w.failSend = (b) => b.event === "recruit_assignee";
  const r = await run(w, A1, { kind: "updated" });
  assertEquals([r.ok, r.incomplete, w.cases[A1].retry], [false, true, true]);
  assertEquals(w.cases[A1].snap?.status, "new");
  w.failSend = () => false;
  const r2 = await run(w, A1, { kind: "sweep" });
  assertEquals([r2.ok, w.cases[A1].retry, w.cases[A1].snap?.status], [true, false, "contacted"]);
  const t = threadTexts(w);
  assertEquals([t.filter((x) => x.startsWith("🔄 状態")).length, t.filter((x) => x.startsWith("👤 担当")).length], [1, 1]);
});
