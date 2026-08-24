// D-4: Anthropic API費用の自動レポート（日次同期）Edge Function
// docs/実装指示書_担当D_勤怠給与監視_2026-08-24.md D-4
//
// 取得: 公式Usage & Cost Admin API（GET /v1/organizations/cost_report）。
//   bucketはUTC暦日単位で返る（Anthropic側の仕様）。amountはUSDセント建ての小数文字列
//   （例: "123.45" = $1.2345）。group_byは付けない＝日ごとに1件（複数返る場合は合算）。
// 円換算: 同じ日次バッチで、その日（UTC暦日）のUSD/JPYレートをFrankfurter
//   （https://api.frankfurter.dev・ECB公表レート・キー不要）の日付指定エンドポイントから取得し、
//   その時点のレートで換算した円額をレートごと固定保存する（2026-08-24ユーザー確定仕様。
//   再同期で同じ日を処理してもFrankfurterの過去日レートは不変のため、既存行の円換算がブレることはない）。
// 呼び出し方: { days?: number }  省略時は2（当日はまだ確定していないため対象外・UTC昨日から
//   さかのぼって2日分を毎回再同期し、Anthropic側の集計が遅れて反映されるケースに備える）
//   認可: CEO/HQ/マスターのユーザーJWT、またはservice_role直呼び（他のD担当関数と同じ方針）
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

async function fetchCostReport(startingAt: string, endingAt: string): Promise<Array<{ date: string; amountCents: number }>> {
  const key = Deno.env.get("ANTHROPIC_ADMIN_API_KEY");
  if (!key) throw new Error("ANTHROPIC_ADMIN_API_KEY が未設定です");

  const out: Array<{ date: string; amountCents: number }> = [];
  let page: string | null = null;
  for (let i = 0; i < 20; i++) { // 無限ループ防止（実際は数ページで収まる想定）
    const url = new URL("https://api.anthropic.com/v1/organizations/cost_report");
    url.searchParams.set("starting_at", startingAt);
    url.searchParams.set("ending_at", endingAt);
    url.searchParams.set("bucket_width", "1d");
    if (page) url.searchParams.set("page", page);
    const res = await fetch(url, {
      headers: { "x-api-key": key, "anthropic-version": "2023-06-01" },
    });
    if (!res.ok) throw new Error(`cost_report API error: ${res.status} ${await res.text()}`);
    const body = await res.json();
    for (const bucket of body.data ?? []) {
      const dateStr = String(bucket.starting_at).slice(0, 10);
      const sum = (bucket.results ?? []).reduce((s: number, r: any) => s + Number(r.amount ?? 0), 0);
      out.push({ date: dateStr, amountCents: sum });
    }
    if (!body.has_more || !body.next_page) break;
    page = body.next_page;
  }
  return out;
}

async function fetchJpyRate(dateStr: string): Promise<number | null> {
  try {
    const res = await fetch(`https://api.frankfurter.dev/v1/${dateStr}?base=USD&symbols=JPY`);
    if (!res.ok) return null;
    const body = await res.json();
    return Number(body?.rates?.JPY) || null;
  } catch (_) {
    return null;
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const sb = svc();
    let body: any = {};
    try { body = await req.json(); } catch { /* GET等ボディなし */ }

    const authHeader = req.headers.get("Authorization") ?? "";
    const isServiceRole = authHeader.includes(Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? " ");
    if (!isServiceRole) {
      const uid = jwtUid(req);
      const { data: u } = await sb.from("users").select("role,is_master,is_active").eq("id", uid).maybeSingle();
      if (!u?.is_active || !(u.is_master || ["CEO", "HQ"].includes(u.role))) {
        return json({ ok: false, error: "権限がありません（CEO/HQ/マスターのみ）" }, 403);
      }
    }

    // 対象期間: デフォルトはUTC昨日から2日分（当日はまだ確定していないため対象外）
    const days = Math.max(1, Number(body.days) || 2);
    const todayUtc = new Date().toISOString().slice(0, 10);
    const startingAt = new Date(new Date(todayUtc).getTime() - days * 86400000).toISOString();
    const endingAt = new Date(todayUtc).toISOString(); // 当日0時（exclusive）＝当日は含まない

    const rows = await fetchCostReport(startingAt, endingAt);

    const rateCache = new Map<string, number | null>();
    const upserts: any[] = [];
    for (const r of rows) {
      if (!rateCache.has(r.date)) rateCache.set(r.date, await fetchJpyRate(r.date));
      const rate = rateCache.get(r.date) ?? null;
      upserts.push({
        date: r.date,
        amount_cents: r.amountCents,
        jpy_rate: rate,
        amount_jpy: rate != null ? Math.round((r.amountCents / 100) * rate) : null,
        updated_at: new Date().toISOString(),
      });
    }

    if (upserts.length) {
      const { error } = await sb.from("api_cost_daily").upsert(upserts, { onConflict: "date" });
      if (error) return json({ ok: false, error: "保存に失敗: " + error.message }, 500);
    }

    return json({ ok: true, days, synced: upserts.length, rows: upserts });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
