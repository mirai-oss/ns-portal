// LINE送信数のモニタリング用・軽量チェックEdge Function
// docs/設計書_労務ワークフロー_労働条件通知書自動発行_2026-08-24.md §6
// 担当Cからの依頼（本WORKLOG 2026-08-24「担当Cへ: LINE送信数のモニタリング…」）に対応。
//
// 目的: tori-dashboard側の新規GitHub Actionsワークフロー（LINE見張り番）から、
//   「今月のLINE送信数が上限の何%か」だけを返す。認証はD-3(attendance-freshness-check)と
//   同じBQ_LOAD_TOKEN（tori-dashboard⇔ns-portal間で既に共有されている専用トークン）を流用し、
//   新しいシークレットは増やさない。
//
// データ取得: LINE Messaging API（実装時点の公式仕様。将来の仕様変更に注意）
//   GET https://api.line.me/v2/bot/message/quota            … 当月の送信上限
//   GET https://api.line.me/v2/bot/message/quota/consumption … 当月ここまでの使用数
//   認証はapp_secrets.line_channel_token（既存。smaregi-payroll-reconcile等が使っているのと同じ値）
//
// 呼び出し方: GET/POST { token: string }
import { createClient } from "npm:@supabase/supabase-js@2";

const cors: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });

const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const url = new URL(req.url);
    let body: any = {};
    try { body = await req.json(); } catch { /* GET等ボディなし */ }
    const token = body.token ?? url.searchParams.get("token") ?? "";

    const tk = Deno.env.get("BQ_LOAD_TOKEN");
    if (!tk || token !== tk) return json({ ok: false, error: "unauthorized" }, 401);

    const sb = svc();
    const { data: sec } = await sb.from("app_secrets").select("value").eq("key", "line_channel_token").maybeSingle();
    const lineToken = (sec?.value ?? "").trim();
    if (!lineToken) return json({ ok: false, error: "app_secretsにline_channel_token未設定" }, 500);

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
