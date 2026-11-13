// 面接の予定（GAS）を呼ぶ部品のテスト（GAS は呼ばない。にせものの fetch を渡す）。deno test supabase/functions/_shared/recruit-calendar.test.ts
import { assert, assertEquals } from "jsr:@std/assert@1";
import { gasDelete, gasMeet, type FetchLike } from "./recruit-calendar.ts";

const CFG = { url: "https://gas.example/exec", key: "test-key", cal: "test-cal" };
const fake = (body: string, status = 200) => { const calls: { url: string; init: RequestInit }[] = []; const f: FetchLike = (url, init) => { calls.push({ url, init }); return Promise.resolve(new Response(body, { status })); }; return { f, calls }; };
const ARGS = { name: "試験 太郎", start: "2026-11-20T05:00:00.000Z", eventId: "", mode: "online" as const, place: "", address: "", interviewer: "担当 花子" };

Deno.test("予定を作る: 画面と同じ中身で GAS を 1 回呼ぶ。URL と予定の番号が返る", async () => {
  const { f, calls } = fake('{"ok":true,"url":"https://meet.example/abc","event_id":"ev1"}');
  assertEquals(await gasMeet(CFG, ARGS, f), { ok: true, url: "https://meet.example/abc", event_id: "ev1", updated: false, why: null });
  assertEquals([calls.length, calls[0].url, calls[0].init.method, (calls[0].init.headers as Record<string, string>)["Content-Type"]], [1, CFG.url, "POST", "text/plain;charset=utf-8"]);
  const b = JSON.parse(String(calls[0].init.body));
  assertEquals([b.key, b.action, b.name, b.start, b.minutes, b.event_id, b.calendar_id, b.mode, b.interviewer], ["test-key", "meet", "試験 太郎", ARGS.start, 30, "", "test-cal", "online", "担当 花子"]);
});

Deno.test("予定を直す（予定の番号つき）・対面（URL なしが正常）", async () => {
  const u = fake('{"ok":true,"url":"https://meet.example/abc","event_id":"ev1","updated":true}');
  const r = await gasMeet(CFG, { ...ARGS, eventId: "ev1" }, u.f);
  assertEquals([r.ok, r.updated, JSON.parse(String(u.calls[0].init.body)).event_id], [true, true, "ev1"]);
  const o = fake('{"ok":true,"event_id":"ev2"}');
  assertEquals(await gasMeet(CFG, { ...ARGS, mode: "onsite", place: "テスト本店", address: "東京都テスト区1-2-3" }, o.f), { ok: true, url: null, event_id: "ev2", updated: false, why: null });
  const ob = JSON.parse(String(o.calls[0].init.body));
  assertEquals([ob.mode, ob.place, ob.address], ["onsite", "テスト本店", "東京都テスト区1-2-3"]);
});

Deno.test("失敗の見分け: GAS 側の失敗・ログイン画面などの読めない返事・URL が空・届かない・設定なし。やり直しは、ここではしない", async () => {
  assertEquals((await gasMeet(CFG, ARGS, fake('{"ok":false,"error":"calendar not found"}').f)).why, "GAS 側で失敗: calendar not found");
  assertEquals((await gasMeet(CFG, ARGS, fake("<html>login</html>").f)).why, "GAS の返事が読めませんでした");
  const noUrl = await gasMeet(CFG, ARGS, fake('{"ok":true,"event_id":"ev3"}').f);
  assertEquals([noUrl.ok, noUrl.event_id], [false, "ev3"]);   // 予定は出来ている: 番号は返す（やり直しで、同じ予定を使うため）
  let n = 0; const boom: FetchLike = () => { n++; return Promise.reject(new DOMException("timed out", "TimeoutError")); };
  const t = await gasMeet(CFG, ARGS, boom);
  assert(!t.ok && t.why!.startsWith("GAS に届きませんでした") && n === 1);
  const none = fake("{}");
  assertEquals((await gasMeet({ url: "", key: "", cal: "" }, ARGS, none.f)).ok, false);
  assertEquals(none.calls.length, 0);
});

Deno.test("予定を消す: 番号が無ければ呼ばない。GAS の返事が ok でなくても、はっきり失敗と分かるときだけ失敗", async () => {
  const none = fake("{}");
  assertEquals(await gasDelete(CFG, "", none.f), { ok: true, why: null });
  assertEquals(none.calls.length, 0);
  const d = fake('{"ok":true}');
  assertEquals(await gasDelete(CFG, "ev1", d.f), { ok: true, why: null });
  const b = JSON.parse(String(d.calls[0].init.body));
  assertEquals([b.action, b.event_id, b.calendar_id, b.key], ["delete_event", "ev1", "test-cal", "test-key"]);
  assertEquals((await gasDelete(CFG, "ev1", fake('{"ok":false,"error":"x"}').f)).ok, false);
  assertEquals((await gasDelete(CFG, "ev1", fake("<html>").f)).ok, false);
});
