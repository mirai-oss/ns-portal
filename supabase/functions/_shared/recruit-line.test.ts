// LINE を 1 通送る部品のテスト（LINE は呼ばない。にせものの fetch を渡す）。deno test supabase/functions/_shared/recruit-line.test.ts
import { assert, assertEquals } from "jsr:@std/assert@1";
import { linePushOnce, type FetchLike } from "./recruit-line.ts";

const KEY = "11111111-1111-4111-8111-111111111111";
type Call = { url: string; init: RequestInit };
const fake = (status: number, body = "{}", headers: Record<string, string> = {}) => {
  const calls: Call[] = [];
  const f: FetchLike = (url, init) => { calls.push({ url, init }); return Promise.resolve(new Response(body, { status, headers })); };
  return { f, calls };
};

Deno.test("送信: push の API に、再送の鍵つきで 1 回だけ呼ぶ。200 は送信成功", async () => {
  const { f, calls } = fake(200, "{}", { "x-line-request-id": "req-1" });
  const r = await linePushOnce("TOKEN", "Uxxxx", "こんにちは", KEY, f);
  assertEquals(r, { status: "sent", http: 200, error: null, requestId: "req-1" });
  assertEquals(calls.length, 1);
  assertEquals(calls[0].url, "https://api.line.me/v2/bot/message/push");
  const h = calls[0].init.headers as Record<string, string>;
  assertEquals([h["X-Line-Retry-Key"], h.Authorization, calls[0].init.method], [KEY, "Bearer TOKEN", "POST"]);
  assertEquals(JSON.parse(String(calls[0].init.body)), { to: "Uxxxx", messages: [{ type: "text", text: "こんにちは" }] });
});

Deno.test("同じ再送の鍵を、LINE がすでに受け付け済み（409）→ 送信成功として扱う（二重には届かない）", async () => {
  const { f } = fake(409, '{"message":"The retry key is already accepted"}', { "x-line-accepted-request-id": "req-0" });
  assertEquals(await linePushOnce("T", "U1", "a", KEY, f), { status: "sent", http: 409, error: null, requestId: "req-0" });
});

Deno.test("LINE が断った（4xx）→ 送信失敗。月の上限（429）は、そうと分かる文にする", async () => {
  const a = await linePushOnce("T", "U1", "a", KEY, fake(400, '{"message":"The property, to, in the request body is invalid"}').f);
  assertEquals([a.status, a.http], ["failed", 400]);
  assert(a.error!.startsWith("LINE の応答: 400"));
  const q = await linePushOnce("T", "U1", "a", KEY, fake(429, '{"message":"You have reached your monthly limit."}').f);
  assertEquals(q.status, "failed");
  assert(q.error!.includes("送信数の上限"));
});

Deno.test("LINE 側の障害（5xx）・時間切れ・通信エラー → 結果不明（送れたか分からない。ここでは再送しない）", async () => {
  const s = fake(503, "busy");
  assertEquals((await linePushOnce("T", "U1", "a", KEY, s.f)).status, "unknown");
  assertEquals(s.calls.length, 1, "やり直しを、ここではしない");
  let n = 0;
  const boom: FetchLike = () => { n++; return Promise.reject(new DOMException("timed out", "TimeoutError")); };
  const t = await linePushOnce("T", "U1", "a", KEY, boom);
  assertEquals([t.status, t.http, n], ["unknown", null, 1]);
  assert(t.error!.includes("返事がありません"));
});

Deno.test("トークン・宛先・本文が無ければ、LINE を呼ばずに失敗。本文は 4,900 文字で切る", async () => {
  const { f, calls } = fake(200);
  assertEquals((await linePushOnce("", "U1", "a", KEY, f)).status, "failed");
  assertEquals((await linePushOnce("T", "", "a", KEY, f)).status, "failed");
  assertEquals((await linePushOnce("T", "U1", "   ", KEY, f)).status, "failed");
  assertEquals(calls.length, 0);
  await linePushOnce("T", "U1", "あ".repeat(6000), KEY, f);
  assertEquals(JSON.parse(String(calls[0].init.body)).messages[0].text.length, 4900);
});
