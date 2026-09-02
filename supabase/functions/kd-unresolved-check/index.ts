// D-checkの続き（2026-09-02）: 朝の見張り番（tori-dashboard側のGitHub Actionsワークフロー）用の
// 軽量チェック。kd_unresolved_names（レーンP所有・店舗名ズレ根絶=設計書_表示集計層kdと
// 高速化実行計画_2026-09-02.md §5・§10.2-5）のopen件数を返すだけ。
//
// attendance-freshness-checkと全く同じ設計方針（tori-dashboardリポジトリはPostgres認証情報を
// 持たないため、既存のBQ_LOAD_TOKEN＝tori-dashboard⇔ns-portal間で既に共有されている専用トークン
// を流用し、新しいシークレットは増やさない・ログイン不要・読み取り専用）。
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
    const { count, error } = await sb
      .from("kd_unresolved_names")
      .select("id", { count: "exact", head: true })
      .eq("status", "open");
    if (error) {
      // kd_unresolved_names自体がまだ無い環境（レーンPの作業前）でも見張り番全体を落とさない
      return json({ ok: true, openCount: 0, note: "kd_unresolved_names未作成またはクエリ失敗: " + error.message });
    }

    return json({ ok: true, openCount: count ?? 0 });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
