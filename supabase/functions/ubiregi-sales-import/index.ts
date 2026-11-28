// =============================================================
// ubiregi-sales-import — ユビレジの日ごとの売上を、売上DB「支払いDB」へ書き込む（担当D・2026-11-29・社長依頼）
//
// 書き込みの鍵（BQ_LOAD_TOKEN）はこの関数の秘密変数にある既存のものを使う（PC へ鍵を置かない）。
// 呼び先はダッシュボードの GAS の paymentDailyReplace（店舗×日の1行を追加・書き換え。修正ログ付き）と bqSyncSales。
// 「分析_日別店舗」の作り直しは別の GAS の朝の自動処理（ここからは呼ばない）。
//
// body: { rows: [{store,date,values[16]}], apply?: boolean（省略＝試し実行・何も書かない）, allow_replace?: boolean }
//   apply でも、先に試し実行をして、重複行がある・既存の行を書き換える（allow_replace なし）ときは書かない。
// 対象の店舗と開始日: app_settings.ubiregi_import = { stores: { "<正式な店舗名>": "YYYY-MM-DD" } }。ここに無い店舗は書けない。
// 認証: service_role（Bearer）か x-notify-secret。
// デプロイ: supabase functions deploy ubiregi-sales-import --no-verify-jwt --project-ref uuvsxzhpxtghojoubjcc --yes
// =============================================================
import { createClient } from "npm:@supabase/supabase-js@2";
import { checkRows, type SalesRow } from "../_shared/ubiregi-sales.ts";

const GAS_URL = "https://script.google.com/macros/s/AKfycbwW0qhyEr0-uQWTaLg7MkQhurHq6wMoaOKL7uCCnI_bgnAsGB5-auqG_dm_Q9uJc3Kc/exec";
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json" } });

function timingSafeEqual(a: string, b: string) {
  if (a.length !== b.length) return false;
  let r = 0; for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}
function authorized(req: Request): boolean {
  const key = (Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "").trim();
  const auth = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (key && auth && timingSafeEqual(auth, key)) return true;
  const secret = (Deno.env.get("NOTIFY_SLACK_SECRET") ?? "").trim();
  const hdr = (req.headers.get("x-notify-secret") ?? "").trim();
  return !!(secret && hdr && timingSafeEqual(secret, hdr));
}

/** GAS を呼ぶ。一時的な unauthorized と、読むだけの呼び出しの壊れた応答は、少し待って再試行する（書き込みは同じ内容なら二重にならない）。 */
async function gas(payload: Record<string, unknown>): Promise<any> {
  const token = Deno.env.get("BQ_LOAD_TOKEN");
  if (!token) throw new Error("BQ_LOAD_TOKEN が未設定です");
  let last: any = { ok: false, error: "未実行" };
  for (let i = 1; i <= 4; i++) {
    const res = await fetch(GAS_URL, { method: "POST", headers: { "Content-Type": "text/plain;charset=utf-8" }, body: JSON.stringify({ token, ...payload }), redirect: "follow" });
    const text = await res.text();
    try { last = JSON.parse(text); } catch (_) { last = { ok: false, error: `GAS の応答を読めません（HTTP ${res.status}）` }; }
    const retry = last.ok === false && (last.error === "unauthorized" || (payload.dryRun === true && String(last.error).startsWith("GAS の応答")));
    if (!retry) break;
    await new Promise((r) => setTimeout(r, i * 5000));
  }
  return last;
}
const summary = (r: any) => ({ appended: r.appended, replaced: r.replaced, unchanged: r.unchanged, duplicates: (r.duplicates ?? []).length });

Deno.serve(async (req) => {
  if (!authorized(req)) return json({ ok: false, error: "認証がありません" }, 401);
  try {
    const body = await req.json().catch(() => ({}));
    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: st, error } = await sb.from("app_settings").select("value").eq("key", "ubiregi_import").maybeSingle();
    if (error) throw new Error(error.message);
    const allowed = ((st?.value as { stores?: Record<string, string> })?.stores ?? {});
    const errors = checkRows(body.rows, allowed, new Date());
    if (errors.length) return json({ ok: false, error: "書き込めない行があります", errors }, 400);
    const rows = (body.rows as SalesRow[]).map((r) => ({ store: r.store, date: r.date, values: r.values }));

    const dry = await gas({ action: "paymentDailyReplace", rows: JSON.stringify(rows), dryRun: true, operator: "ubiregi-import" });
    if (!dry.ok) return json({ ok: false, stage: "dry_run", error: dry.error }, 502);
    const changes = (dry.details ?? []).filter((d: any) => d.result === "replaced").map((d: any) => ({ store: d.store, date: d.date, before: d.before, after: d.after }));
    if (body.apply !== true) return json({ ok: true, applied: false, ...summary(dry), changes });
    if ((dry.duplicates ?? []).length) return json({ ok: false, stage: "check", error: "同じ店舗と日の行が複数あるため、書きませんでした", ...summary(dry) }, 409);
    if (dry.replaced > 0 && body.allow_replace !== true) return json({ ok: false, stage: "check", error: "既存の行を書き換えることになるため、書きませんでした", ...summary(dry), changes }, 409);

    const done = await gas({ action: "paymentDailyReplace", rows: JSON.stringify(rows), dryRun: false, operator: "ubiregi-import" });
    if (!done.ok) return json({ ok: false, stage: "write", error: done.error }, 502);
    const bq = await gas({ action: "bqSyncSales" });
    return json({ ok: true, applied: true, ...summary(done), bq_synced: bq.ok === true, bq_error: bq.ok === true ? null : String(bq.error ?? "").slice(0, 200) });
  } catch (e) {
    console.error("ubiregi-sales-import", e);
    return json({ ok: false, error: e instanceof Error ? e.message : String(e) }, 500);
  }
});
