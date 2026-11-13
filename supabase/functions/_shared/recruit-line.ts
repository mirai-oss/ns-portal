// =============================================================
// 採用管理: 応募者へ LINE を 1 通送る（2026-11-27 下書き・本番未適用）
//   呼ぶのは recruit-action だけ。しかも、送信箱（applicant_outbox）が「送ってよい（本番モード）」と答えたときだけ。
//   line-webhook は変えていない（同じ LINE の API・同じトークンを、ここから直接呼ぶ）。
//
//   再送の鍵（X-Line-Retry-Key）: 同じ鍵の送信は、LINE の側で 1 回だけになる（2 回目は 409 が返る＝すでに受け付け済み）。
//     ★ 実装時に、LINE の公式の説明で、鍵の有効な時間と対象の API を確かめること（このファイルは、その前提で書いてある）
//   結果は 3 つに分ける:
//     sent    … LINE が受け付けた（200。または、同じ鍵をすでに受け付け済み＝409）
//     failed  … LINE が断った（4xx。宛先が無効・月の上限など）。応募者には届いていない
//     unknown … 返事が来なかった・LINE 側の障害（5xx・時間切れ・通信エラー）。届いたかどうか分からない。★ 自動では再送しない
// =============================================================
export type LineResult = { status: "sent" | "failed" | "unknown"; http: number | null; error: string | null; requestId: string | null };
export type FetchLike = (url: string, init: RequestInit) => Promise<Response>;

export async function linePushOnce(token: string, to: string, text: string, retryKey: string, fetchFn: FetchLike = fetch, timeoutMs = 10000): Promise<LineResult> {
  if (!token) return { status: "failed", http: null, error: "LINE のチャネルアクセストークンが未設定です", requestId: null };
  if (!to || !text.trim()) return { status: "failed", http: null, error: "宛先または本文が空です", requestId: null };
  try {
    const res = await fetchFn("https://api.line.me/v2/bot/message/push", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}`, "X-Line-Retry-Key": retryKey },
      body: JSON.stringify({ to, messages: [{ type: "text", text: text.slice(0, 4900) }] }),
      signal: AbortSignal.timeout(timeoutMs),
    });
    const requestId = res.headers.get("x-line-accepted-request-id") ?? res.headers.get("x-line-request-id");
    if (res.ok) { await res.body?.cancel().catch(() => {}); return { status: "sent", http: res.status, error: null, requestId }; }
    const body = (await res.text().catch(() => "")).slice(0, 200);
    if (res.status === 409) return { status: "sent", http: 409, error: null, requestId };                       // 同じ再送の鍵を、すでに受け付け済み
    if (res.status >= 500) return { status: "unknown", http: res.status, error: `LINE の応答: ${res.status}`, requestId };
    const hint = res.status === 429 ? "（送信数の上限・回数の制限）" : "";
    return { status: "failed", http: res.status, error: `LINE の応答: ${res.status}${hint} ${body}`.trim(), requestId };
  } catch (e) {
    return { status: "unknown", http: null, error: "LINE から返事がありません: " + String((e as Error)?.name ?? e).slice(0, 60), requestId: null };
  }
}
