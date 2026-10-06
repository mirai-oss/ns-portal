// PL入力(表)で正本pl_entriesを保存した直後に、kd_pl_monthly_summary / kd_pl_entries を作り直す起動口（レーンP・2026-10-06）。
// 呼び出し: POST（ログイン済みユーザーのJWT）。master/CEO/HQ のみ。即202で返し、裏で keiei-kd-refresh の op=pl_monthly（skipAuto=true=GASを呼ばない手入力の即時反映）を実行。
// 二重起動の防止: 直近3分以内に同じjobが実行中ならstarted:falseを返す（並行実行は洗い替えが互いの行を消しかねないため）。画面側は数秒後に再度呼べばよい。
// 注意: このFunctionは --no-verify-jwt を付けずにデプロイする（ゲートウェイでJWT署名を検証。署名未検証のuid読み取りを権限判定に使わない）。
import { createClient } from "npm:@supabase/supabase-js@2";

const cors: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
};
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });

function jwtUid(req: Request): string {
  try {
    const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    return JSON.parse(atob(jwt.split(".")[1].replace(/-/g, "+").replace(/_/g, "/"))).sub ?? "";
  } catch (_) { return ""; }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const uid = jwtUid(req);
    if (!uid) return json({ ok: false, error: "ログインが必要です" }, 401);
    const { data: u } = await sb.from("users").select("id,role,is_master,is_active").eq("id", uid).maybeSingle();
    if (!u || !u.is_active || !(u.is_master || ["CEO", "HQ"].includes(u.role))) return json({ ok: false, error: "権限がありません（社長・本部のみ）" }, 403);

    const since = new Date(Date.now() - 3 * 60000).toISOString();
    const { data: running } = await sb.from("kd_sync_runs").select("id").eq("job", "kd_pl_monthly_summary").eq("status", "running").gte("started_at", since).limit(1);
    if (running?.length) return json({ ok: true, started: false, reason: "更新中です。数秒後にもう一度呼んでください" }, 202);

    const url = `${Deno.env.get("SUPABASE_URL")}/functions/v1/keiei-kd-refresh`;
    const call = fetch(url, {
      method: "POST",
      headers: { Authorization: `Bearer ${Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")}`, "Content-Type": "application/json" },
      body: JSON.stringify({ op: "pl_monthly", skipAuto: true }),
    }).then((r) => r.text()).catch(() => "");
    // deno-lint-ignore no-explicit-any
    (globalThis as any).EdgeRuntime?.waitUntil(call);
    return json({ ok: true, started: true }, 202);
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
