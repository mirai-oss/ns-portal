// D-3: 朝の見張り番（tori-dashboard側の新規GitHub Actionsワークフロー）用の軽量チェック
// docs/実装指示書_担当D_勤怠給与監視_2026-08-24.md D-3
//
// 目的: 「指定日のlabor_cost_dailyに実績が入っているか」だけを返す。tori-dashboardリポジトリは
//   Postgresの認証情報を持たないため、既存のbqDailyStoreForSync等と同じ「軽量トークン認証・
//   ログイン不要」の考え方をns-portal側にも作り、tori-dashboardのworkflowから直接叩けるようにする。
//   認証は既存のBQ_LOAD_TOKEN（tori-dashboard⇔ns-portal間で既に共有されている専用トークン。
//   dash-syncが同トークンでGAS側を呼んでいるのと逆方向）を流用し、新しいシークレットは増やさない。
//
// 呼び出し方: GET/POST { date?: 'YYYY-MM-DD', token: string }  date省略時は昨日（JST）
import { createClient } from "npm:@supabase/supabase-js@2";

const cors: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });

const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

function yesterdayJst(): string {
  const nowJst = new Date(Date.now() + 9 * 3600 * 1000);
  const y = new Date(nowJst.getTime() - 86400000);
  return y.toISOString().slice(0, 10);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const url = new URL(req.url);
    let body: any = {};
    try { body = await req.json(); } catch { /* GET等ボディなし */ }
    const token = body.token ?? url.searchParams.get("token") ?? "";

    const tk = Deno.env.get("BQ_LOAD_TOKEN");
    if (!tk || token !== tk) return json({ ok: false, error: "unauthorized" }, 401);

    const dateParam = body.date ?? url.searchParams.get("date") ?? "";
    const date = /^\d{4}-\d{2}-\d{2}$/.test(dateParam) ? dateParam : yesterdayJst();

    const sb = svc();
    const { count, error } = await sb
      .from("labor_cost_daily")
      .select("id", { count: "exact", head: true })
      .eq("work_date", date);
    if (error) return json({ ok: false, error: error.message }, 500);

    return json({ ok: true, date, rowCount: count ?? 0, hasData: (count ?? 0) > 0 });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
