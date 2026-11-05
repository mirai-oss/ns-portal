// =============================================================
// daily-report-card — Slack 画像日報の「データ出し」と「画像の保存」だけを担う Edge Function（2026-11-05）
//   vm     : 店舗×日付の ViewModel（RPC daily_report_card_vm。正本＝経営ダッシュボードの日次集計・予算）
//   upload : 描画済み PNG（base64）を Storage バケット daily-report に保存し、公開 URL を返す
//   health : 疎通
// 認証: notify-slack と同じ合言葉 x-notify-secret（secrets NOTIFY_SLACK_SECRET）か service_role。
// 描画（HTML→PNG）は GitHub Actions 側（tori-dashboard scripts/daily-report-card.mjs）。Deno では Chromium が動かないため。
// デプロイ: supabase functions deploy daily-report-card --no-verify-jwt --project-ref uuvsxzhpxtghojoubjcc --yes
// =============================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const BUCKET = "daily-report";
const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json" } });

function authorized(req: Request): boolean {
  const secret = (Deno.env.get("NOTIFY_SLACK_SECRET") ?? "").trim();
  const given = (req.headers.get("x-notify-secret") ?? "").trim();
  if (secret && given && secret === given) return true;
  const auth = req.headers.get("Authorization") ?? "";
  const sr = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  return !!sr && auth.includes(sr);
}

function b64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64.replace(/^data:image\/png;base64,/, ""));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ ok: false, error: "POST のみ" }, 405);
  if (!authorized(req)) return json({ ok: false, error: "unauthorized" }, 401);
  let b: any = {};
  try { b = await req.json(); } catch { return json({ ok: false, error: "JSON ボディが必要です" }, 400); }
  const sb = svc();
  const action = String(b.action ?? "");
  try {
    if (action === "health") return json({ ok: true, bucket: BUCKET });

    if (action === "vm") {
      const date = String(b.date ?? "").trim();
      if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) return json({ ok: false, error: "date は YYYY-MM-DD" }, 400);
      let res;
      if (b.store_id) res = await sb.rpc("daily_report_card_vm", { p_store: b.store_id, p_date: date });
      else if (b.store_name) res = await sb.rpc("daily_report_card_vm_by_name", { p_store_name: String(b.store_name), p_date: date });
      else return json({ ok: false, error: "store_id か store_name が必要です" }, 400);
      if (res.error) return json({ ok: false, error: res.error.message }, 500);
      if (!res.data) return json({ ok: false, error: "店舗が見つかりません" }, 404);
      return json({ ok: true, vm: res.data });
    }

    if (action === "upload") {
      const date = String(b.date ?? "").trim();
      const key = String(b.store_key ?? b.store_no ?? "").trim().replace(/[^a-zA-Z0-9_-]/g, "");
      if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || !key) return json({ ok: false, error: "date と store_key が必要です" }, 400);
      if (!b.png_base64) return json({ ok: false, error: "png_base64 が必要です" }, 400);
      const bytes = b64ToBytes(String(b.png_base64));
      if (bytes.length < 1000 || bytes.length > 5 * 1024 * 1024) return json({ ok: false, error: `PNG のサイズが不正です (${bytes.length} bytes)` }, 400);
      const path = `${date}/${key}.png`;
      const up = await sb.storage.from(BUCKET).upload(path, bytes, { contentType: "image/png", upsert: true, cacheControl: "300" });
      if (up.error) return json({ ok: false, error: "保存に失敗: " + up.error.message }, 500);
      const { data: pub } = sb.storage.from(BUCKET).getPublicUrl(path);
      // 同じパスを上書きしても Slack 側のキャッシュが残らないよう、URL に版（秒）を付ける
      const url = `${pub.publicUrl}?v=${Math.floor(Date.now() / 1000)}`;
      return json({ ok: true, path, url, bytes: bytes.length });
    }

    return json({ ok: false, error: `不明な action: ${action}` }, 400);
  } catch (e) {
    return json({ ok: false, error: String(e).slice(0, 300) }, 500);
  }
});
