// Edge Function の入口で「だれが呼んだか」を確かめる共通の部品（2026-11-15 セキュリティ修正）
//
// 背景: verify_jwt=false で配置している関数に、Authorization のトークンの「中身（sub）」を base64 で読むだけ
//   （署名・期限を確かめない）の書き方があった。利用者の id を知っている人が、にせのトークンを作って、その利用者になりすませる。
//
// この部品:
//   verifiedUid(req, sb)        … トークンを Supabase Auth に渡して検証し、検証できたときだけ利用者の id を返す（だめなら ""）。
//                                  line-webhook の verifiedUid・smaregi-sync の callerRole・recruit-action の resolveActor と同じ確かめ方。
//   isServiceRoleRequest(req)   … Authorization が「サービス用の鍵」と完全に一致するか。
//                                  これまでの includes（部分一致）をやめる。鍵が未設定・空のときは、必ず false（これまでの `?? " "` は、鍵が未設定だと誰でも通る書き方だった）。
//   safeEqual(a, b)             … 鍵・合言葉の比較（長さと中身を、途中で打ち切らずに比べる）。
//   bearerToken(req)            … Authorization から「Bearer 」を外した中身。
//
// 約束: 鍵・トークンの値は、ログにもエラーにも出さない。検証に失敗した理由も返さない（"" か false だけ）。

/** Supabase のクライアントのうち、この部品が使う所だけ（テストでは、にせものを渡せる） */
export interface AuthUserClient {
  auth: {
    // deno-lint-ignore no-explicit-any
    getUser(jwt?: string): Promise<{ data: any; error: unknown }>;
  };
}

/** 文字列の比較（長さと中身を、途中で打ち切らずに比べる） */
export function safeEqual(a: unknown, b: unknown): boolean {
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}

/** Authorization ヘッダから「Bearer 」を外した中身（無ければ ""） */
export function bearerToken(req: Request): string {
  return (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
}

/**
 * サービス用の鍵での呼び出しか（完全一致）。
 * serviceKey を渡さなければ、環境変数 SUPABASE_SERVICE_ROLE_KEY を使う。鍵が未設定・空なら false。
 */
export function isServiceRoleRequest(req: Request, serviceKey?: string): boolean {
  const key = (serviceKey ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "").trim();
  if (!key) return false;
  const token = bearerToken(req);
  return !!token && safeEqual(token, key);
}

/**
 * ログインのトークンを Supabase Auth で検証して、利用者の id を返す。検証できなければ ""。
 * （署名が違う・期限が切れている・ログアウト済み・形がトークンでない・Auth に届かない → どれも ""）
 */
export async function verifiedUid(req: Request, sb: AuthUserClient): Promise<string> {
  try {
    const jwt = bearerToken(req);
    if (!jwt || jwt.split(".").length !== 3) return "";
    const { data, error } = await sb.auth.getUser(jwt);
    const id = data?.user?.id;
    if (error || typeof id !== "string" || !id) return "";
    return id;
  } catch (_) {
    return "";
  }
}
