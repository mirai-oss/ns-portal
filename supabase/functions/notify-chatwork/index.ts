// =============================================================
// notify-chatwork（本番からの完全復元・2026-10-29）
// 復元元: 本番 Edge Function notify-chatwork v13（supabase functions download で取得・無改変）
// 用途: ns-portal の tasks.html / expenses.html / requests.html が、本部タスク・経費・申請の
//       通知を Chatwork へ送るときの中継。Chatwork APIトークンは Edge Function の secret
//       CHATWORK_API_TOKEN にだけ置く（コードに書かない）。verify_jwt=true（ログイン必須）。
// 注意: Slack移行（docs/設計書_Slack通知基盤_Phase1_2026-10-29.md）では、この関数は変更せず
//       並行運用期間中そのまま残し、移行完了確認後に呼び出し側を notify-slack へ切り替える。
// =============================================================
// hq_ 本部タスクボード: Chatworkへの通知を中継するEdge Function。
// クライアントはroom_id/bodyだけを送り、Chatwork APIトークンはここ（サーバー側のsecret）
// にだけ置く。呼び出しはログイン中ユーザーのJWT必須（verify_jwt=true）。
const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "method not allowed" }), { status: 405, headers: CORS_HEADERS });
  }
  let payload: { room_id?: string; body?: string };
  try {
    payload = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "invalid json" }), { status: 400, headers: CORS_HEADERS });
  }
  const roomId = (payload.room_id || "").trim();
  const body = (payload.body || "").trim();
  if (!roomId || !body) {
    return new Response(JSON.stringify({ error: "room_id and body are required" }), { status: 400, headers: CORS_HEADERS });
  }
  const token = Deno.env.get("CHATWORK_API_TOKEN");
  if (!token) {
    return new Response(JSON.stringify({ error: "CHATWORK_API_TOKEN is not configured" }), { status: 500, headers: CORS_HEADERS });
  }
  const form = new URLSearchParams();
  form.set("body", body);
  const cwRes = await fetch(`https://api.chatwork.com/v2/rooms/${encodeURIComponent(roomId)}/messages`, {
    method: "POST",
    headers: {
      "X-ChatWorkToken": token,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: form.toString(),
  });
  const text = await cwRes.text();
  return new Response(text, {
    status: cwRes.status,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
});
