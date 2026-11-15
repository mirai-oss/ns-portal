import { assert, assertEquals } from "jsr:@std/assert@1";
import { type AuthUserClient, bearerToken, isServiceRoleRequest, safeEqual, verifiedUid } from "./auth-verify.ts";

// テスト用の値（本物の鍵・トークンではない）
const UID = "11111111-2222-4333-8444-555555555555";
const b64u = (o: unknown) => btoa(JSON.stringify(o)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
/** 署名が正しくない、にせのトークン（中身の sub に、実在する利用者の id を入れた形） */
const forged = (sub: string) => `${b64u({ alg: "none", typ: "JWT" })}.${b64u({ sub, role: "authenticated", exp: 4102444800 })}.`;
const forgedSigned = (sub: string) => `${b64u({ alg: "HS256", typ: "JWT" })}.${b64u({ sub, role: "authenticated", exp: 4102444800 })}.${b64u("not-a-real-signature")}`;
const GOOD = "good.header.signature"; // にせの Auth が「本物」と答えるトークン
const SERVICE_KEY = "svc.test-key.value";

const req = (auth?: string, extra: Record<string, string> = {}) =>
  new Request("https://example.invalid/fn", { method: "POST", headers: { ...(auth === undefined ? {} : { Authorization: auth }), ...extra } });

/** にせの Supabase Auth: GOOD だけを本物と認める。呼ばれた回数と、渡されたトークンを覚える */
function fakeAuth(mode: "normal" | "throws" | "no_id" = "normal") {
  const calls: string[] = [];
  const sb: AuthUserClient = {
    auth: {
      getUser(jwt?: string) {
        calls.push(String(jwt));
        if (mode === "throws") return Promise.reject(new Error("network"));
        if (jwt === GOOD) return Promise.resolve({ data: { user: mode === "no_id" ? {} : { id: UID } }, error: null });
        return Promise.resolve({ data: { user: null }, error: { message: "invalid JWT" } });
      },
    },
  };
  return { sb, calls };
}

Deno.test("verifiedUid: にせのトークン（署名なし・実在の利用者の id 入り）は、利用者として扱わない", async () => {
  const { sb, calls } = fakeAuth();
  assertEquals(await verifiedUid(req(`Bearer ${forged(UID)}`), sb), "");
  assertEquals(await verifiedUid(req(`Bearer ${forgedSigned(UID)}`), sb), "");
  assertEquals(calls.length, 2, "中身を読んで決めずに、Auth に確かめている");
});

Deno.test("verifiedUid: にせのトークンの中身（sub）は読まない＝これまでの書き方なら通っていた形", async () => {
  // これまでの jwtUid と同じ読み方をすると、にせのトークンから利用者の id が取れてしまうことの確認
  const legacy = (r: Request) => { try { const j = (r.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, ""); return JSON.parse(atob(j.split(".")[1].replace(/-/g, "+").replace(/_/g, "/"))).sub ?? ""; } catch (_) { return ""; } };
  const r = req(`Bearer ${forged(UID)}`);
  assertEquals(legacy(r), UID, "これまでの読み方は、にせのトークンを信じてしまう");
  assertEquals(await verifiedUid(r, fakeAuth().sb), "", "新しい確かめ方は信じない");
});

Deno.test("verifiedUid: 本物のトークンは、Auth が返した利用者の id", async () => {
  const { sb, calls } = fakeAuth();
  assertEquals(await verifiedUid(req(`Bearer ${GOOD}`), sb), UID);
  assertEquals(await verifiedUid(req(`bearer   ${GOOD}  `), sb), UID, "Bearer の大文字小文字・空白のゆれ");
  assertEquals(calls, [GOOD, GOOD]);
});

Deno.test("verifiedUid: トークンなし・形がトークンでないものは、Auth に聞かずに断る", async () => {
  const { sb, calls } = fakeAuth();
  assertEquals(await verifiedUid(req(), sb), "");
  assertEquals(await verifiedUid(req(""), sb), "");
  assertEquals(await verifiedUid(req("Bearer "), sb), "");
  assertEquals(await verifiedUid(req("Bearer sb_publishable_xxxxxxxx"), sb), "", "公開用の鍵（点が 2 つ無い）");
  assertEquals(await verifiedUid(req("Bearer a.b"), sb), "");
  assertEquals(await verifiedUid(req("Bearer a.b.c.d"), sb), "");
  assertEquals(calls.length, 0);
});

Deno.test("verifiedUid: Auth がエラー・id なし・届かない → どれも断る（例外を外に出さない）", async () => {
  assertEquals(await verifiedUid(req("Bearer x.y.z"), fakeAuth().sb), "");
  assertEquals(await verifiedUid(req(`Bearer ${GOOD}`), fakeAuth("no_id").sb), "");
  assertEquals(await verifiedUid(req(`Bearer ${GOOD}`), fakeAuth("throws").sb), "");
  // data が null でも落ちない
  const sb: AuthUserClient = { auth: { getUser: () => Promise.resolve({ data: null, error: null }) } };
  assertEquals(await verifiedUid(req(`Bearer ${GOOD}`), sb), "");
  // error があれば、user が入っていても断る
  const sb2: AuthUserClient = { auth: { getUser: () => Promise.resolve({ data: { user: { id: UID } }, error: { message: "x" } }) } };
  assertEquals(await verifiedUid(req(`Bearer ${GOOD}`), sb2), "");
});

Deno.test("isServiceRoleRequest: サービス用の鍵と完全に一致するときだけ true", () => {
  assert(isServiceRoleRequest(req(`Bearer ${SERVICE_KEY}`), SERVICE_KEY));
  assert(isServiceRoleRequest(req(`bearer ${SERVICE_KEY}`), SERVICE_KEY), "Bearer の大文字小文字");
  assert(isServiceRoleRequest(req(`Bearer  ${SERVICE_KEY} `), SERVICE_KEY), "前後の空白");
  assert(isServiceRoleRequest(req(SERVICE_KEY), SERVICE_KEY), "Bearer なし（これまでの includes でも通っていた形）");
  assert(isServiceRoleRequest(req(`Bearer ${SERVICE_KEY}`), ` ${SERVICE_KEY}\n`), "環境変数の側の前後の空白・改行");
});

Deno.test("isServiceRoleRequest: 部分一致・鍵を含むだけ・別の値は false", () => {
  assert(!isServiceRoleRequest(req(`Bearer x${SERVICE_KEY}`), SERVICE_KEY), "前に余計な文字");
  assert(!isServiceRoleRequest(req(`Bearer ${SERVICE_KEY}x`), SERVICE_KEY), "後ろに余計な文字");
  assert(!isServiceRoleRequest(req(`Bearer ${SERVICE_KEY.slice(0, -1)}`), SERVICE_KEY), "1 文字足りない");
  assert(!isServiceRoleRequest(req(`Bearer ${forged(UID)}`), SERVICE_KEY));
  assert(!isServiceRoleRequest(req(), SERVICE_KEY), "ヘッダなし");
  assert(!isServiceRoleRequest(req(""), SERVICE_KEY));
  assert(!isServiceRoleRequest(req("Bearer "), SERVICE_KEY));
  // 鍵がほかのヘッダにあっても通さない（Authorization だけを見る）
  assert(!isServiceRoleRequest(req("Bearer nope", { apikey: SERVICE_KEY }), SERVICE_KEY));
});

Deno.test("isServiceRoleRequest: 鍵が未設定・空のときは、だれも通さない（これまでの `?? \" \"` は通していた）", () => {
  // これまでの書き方: 環境変数が無いと " " を探す → 「Bearer xxx」には空白があるので true になっていた
  const legacy = (r: Request, key: string | undefined) => (r.headers.get("Authorization") ?? "").includes(key ?? " ");
  assert(legacy(req("Bearer anything"), undefined), "これまでの書き方は、鍵が未設定だと通してしまう");
  assert(legacy(req("Bearer anything"), ""), "これまでの書き方は、鍵が空でも通してしまう");
  assert(!isServiceRoleRequest(req("Bearer anything"), ""));
  assert(!isServiceRoleRequest(req("Bearer anything"), "   "));
  assert(!isServiceRoleRequest(req(""), ""));
  assert(!isServiceRoleRequest(req(), ""));
});

Deno.test("isServiceRoleRequest: 鍵を渡さなければ、環境変数 SUPABASE_SERVICE_ROLE_KEY を使う", () => {
  const before = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  try {
    Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", SERVICE_KEY);
    assert(isServiceRoleRequest(req(`Bearer ${SERVICE_KEY}`)));
    assert(!isServiceRoleRequest(req(`Bearer ${SERVICE_KEY}x`)));
    Deno.env.delete("SUPABASE_SERVICE_ROLE_KEY");
    assert(!isServiceRoleRequest(req(`Bearer ${SERVICE_KEY}`)), "未設定なら通さない");
    assert(!isServiceRoleRequest(req("Bearer anything")));
  } finally {
    if (before === undefined) Deno.env.delete("SUPABASE_SERVICE_ROLE_KEY"); else Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", before);
  }
});

Deno.test("safeEqual: 同じ文字列だけ true（長さ違い・型違いは false）", () => {
  assert(safeEqual("abc", "abc"));
  assert(safeEqual("", ""));
  assert(!safeEqual("abc", "abd"));
  assert(!safeEqual("abc", "ab"));
  assert(!safeEqual("abc", "abcd"));
  assert(!safeEqual("abc", undefined));
  assert(!safeEqual(null, null));
  assert(!safeEqual(123, 123));
});

Deno.test("bearerToken: Bearer を外した中身", () => {
  assertEquals(bearerToken(req("Bearer abc")), "abc");
  assertEquals(bearerToken(req("bearer abc")), "abc");
  assertEquals(bearerToken(req("abc")), "abc");
  assertEquals(bearerToken(req()), "");
});

// ---- 入口の判定の組み合わせ（15 本の関数が、この順で使う） ----------------------------------------
// 「サービス用の鍵なら通す → そうでなければ、検証済みのログインで権限を見る」の形を、そのまま小さく書いたもの
async function gate(r: Request, sb: AuthUserClient, roleOf: (uid: string) => string | null, allowed: string[]): Promise<"service" | "user" | "denied"> {
  if (isServiceRoleRequest(r, SERVICE_KEY)) return "service";
  const uid = await verifiedUid(r, sb);
  const role = uid ? roleOf(uid) : null;
  return role && allowed.includes(role) ? "user" : "denied";
}
Deno.test("入口の組み合わせ: にせのトークン・トークンなしは断る／サービス用の鍵・本物のログインは通す", async () => {
  const roleOf = (uid: string) => (uid === UID ? "CEO" : null);
  const { sb } = fakeAuth();
  assertEquals(await gate(req(`Bearer ${forged(UID)}`), sb, roleOf, ["CEO", "HQ"]), "denied", "社長の id を入れた、にせのトークン");
  assertEquals(await gate(req(), sb, roleOf, ["CEO", "HQ"]), "denied", "トークンなし");
  assertEquals(await gate(req("Bearer sb_publishable_xxxxxxxx"), sb, roleOf, ["CEO", "HQ"]), "denied", "公開用の鍵だけ");
  assertEquals(await gate(req(`Bearer ${SERVICE_KEY}`), sb, roleOf, ["CEO", "HQ"]), "service", "定期実行（サービス用の鍵）");
  assertEquals(await gate(req(`Bearer ${GOOD}`), sb, roleOf, ["CEO", "HQ"]), "user", "画面からの本物のログイン");
  assertEquals(await gate(req(`Bearer ${GOOD}`), sb, () => "AL", ["CEO", "HQ"]), "denied", "本物のログインでも、権限が無ければ断る");
});
