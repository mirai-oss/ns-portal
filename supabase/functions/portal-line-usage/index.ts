// F-1.5: ポータルの「システム利用状況」向け・LINE配信数/残高の表示専用エンドポイント
// WORKLOG「2026-08-24追記・担当Fへのユーザー追加要望」「今すぐ着手してください（2026-08-28）」に対応。
//
// 既存のline-quota-check（担当D・BQ_LOAD_TOKEN認証・GitHub Actions見張り番向け）とは別に、
// ブラウザ（portal.html）から直接呼べるようログイン中ユーザーのJWTで認証する版を新設した
// （BQ_LOAD_TOKENは他の用途と共有の秘密のためブラウザには渡さない設計にしている）。
//
// データ取得はline-quota-checkと同じLINE Messaging API・同じapp_secrets.line_channel_token:
//   GET https://api.line.me/v2/bot/message/quota            … 当月の送信上限
//   GET https://api.line.me/v2/bot/message/quota/consumption … 当月ここまでの使用数
//
// 権限: AI利用料ウィジェットと同じ「マスター・社長・本部のみ」に合わせる
import { createClient } from "npm:@supabase/supabase-js@2";

const cors: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });

const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

function jwtUid(req: Request): string {
  try {
    const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    return JSON.parse(atob(jwt.split(".")[1].replace(/-/g, "+").replace(/_/g, "/"))).sub ?? "";
  } catch (_) { return ""; }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const sb = svc();
    const uid = jwtUid(req);
    const { data: u } = await sb.from("users").select("role,is_master,is_active").eq("id", uid).maybeSingle();
    if (!u?.is_active) return json({ ok: false, error: "認証が必要です" }, 401);
    if (!(u.is_master || ["HQ", "CEO"].includes(u.role))) {
      return json({ ok: false, error: "この情報を見る権限がありません" }, 403);
    }

    const { data: sec } = await sb.from("app_secrets").select("value").eq("key", "line_channel_token").maybeSingle();
    const lineToken = (sec?.value ?? "").trim();
    if (!lineToken) return json({ ok: false, error: "app_secretsにline_channel_token未設定です" }, 500);

    const headers = { Authorization: `Bearer ${lineToken}` };
    const [quotaRes, consRes] = await Promise.all([
      fetch("https://api.line.me/v2/bot/message/quota", { headers }),
      fetch("https://api.line.me/v2/bot/message/quota/consumption", { headers }),
    ]);
    if (!quotaRes.ok || !consRes.ok) {
      return json({ ok: false, error: `LINE API error: quota=${quotaRes.status} consumption=${consRes.status}` }, 502);
    }
    const quota = await quotaRes.json();
    const consumption = await consRes.json();

    // quota.type: "none"(無制限) | "limited"（valueあり）
    const limit: number | null = quota?.type === "limited" ? Number(quota.value) : null;
    const used = Number(consumption?.totalUsage ?? 0);
    const ratio = limit && limit > 0 ? used / limit : null;

    return json({ ok: true, limitType: quota?.type ?? null, limit, used, ratio });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
