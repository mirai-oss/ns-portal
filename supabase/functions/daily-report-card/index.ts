// =============================================================
// daily-report-card — Slack 画像日報の「データ出し」と「画像の保存」だけを担う Edge Function（2026-11-05）
//   vm     : 店舗×日付の ViewModel（RPC daily_report_card_vm。正本＝経営ダッシュボードの日次集計・予算）
//   all_stores : 全12店舗日報（TK-255）用データ（RPC all_stores_report_vm）
//   upload : 描画済み PNG（base64）を Storage バケット daily-report（非公開）に保存し、期限付き署名 URL を返す（同日2回目以降は別名保存＝上書きしない・vm を渡すと配信時スナップショットも保存／TK-252）
//   prune  : 保存から一定日数（既定 400 日）を過ぎた日付フォルダの画像を削除する（週1回程度、GitHub Actions から）
//   health : 疎通
// 認証: --no-verify-jwt でデプロイするが「認証不要」ではない。関数側で以下だけを通す（それ以外は 401）。
//   ・x-notify-secret が secrets NOTIFY_SLACK_SECRET と一致（GitHub Actions / 内部システム用。固定時間比較）
//   ・Authorization: Bearer <service_role>（内部用）
//   secret や service_role はレスポンス・ログに一切出さない。store_id は uuid 形式、date は YYYY-MM-DD のみ受け付け、
//   データ取得は security definer の RPC（店舗の売上 KPI だけを返す）に限定する。
// Storage: バケット daily-report は非公開。画像は署名 URL（既定 1 年＝DAILY_REPORT_SIGNED_TTL 秒）でのみ取得できる。
// 描画（HTML→PNG）は GitHub Actions 側（tori-dashboard scripts/daily-report-card.mjs）。Deno では Chromium が動かないため。
// デプロイ: supabase functions deploy daily-report-card --no-verify-jwt --project-ref uuvsxzhpxtghojoubjcc --yes
// =============================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const BUCKET = "daily-report";
const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json" } });

const SIGNED_TTL = Math.max(3600, Number(Deno.env.get("DAILY_REPORT_SIGNED_TTL") ?? 0) || 365 * 24 * 3600); // 署名 URL の有効期限（秒）
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

// 固定時間比較（長さが違っても早期 return しない）
function safeEqual(a: string, b: string): boolean {
  const ea = new TextEncoder().encode(a), eb = new TextEncoder().encode(b);
  let diff = ea.length ^ eb.length;
  for (let i = 0; i < Math.max(ea.length, eb.length); i++) diff |= (ea[i] ?? 0) ^ (eb[i] ?? 0);
  return diff === 0;
}

function authorized(req: Request): boolean {
  const secret = (Deno.env.get("NOTIFY_SLACK_SECRET") ?? "").trim();
  const given = (req.headers.get("x-notify-secret") ?? "").trim();
  if (secret.length >= 16 && given && safeEqual(secret, given)) return true;
  const auth = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  const sr = (Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "").trim();
  return sr.length >= 16 && !!auth && safeEqual(auth, sr);
}

async function signedUrl(sb: any, path: string): Promise<string | null> {
  const { data, error } = await sb.storage.from(BUCKET).createSignedUrl(path, SIGNED_TTL);
  if (error || !data?.signedUrl) return null;
  return data.signedUrl as string;
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
      if (!DATE_RE.test(date)) return json({ ok: false, error: "date は YYYY-MM-DD" }, 400);
      let res;
      if (b.store_id !== undefined && b.store_id !== null && b.store_id !== "") {
        const sid = String(b.store_id).trim();
        if (!UUID_RE.test(sid)) return json({ ok: false, error: "store_id は uuid 形式" }, 400);
        res = await sb.rpc("daily_report_card_vm", { p_store: sid, p_date: date });
      } else if (b.store_name) {
        const name = String(b.store_name).trim();
        if (!name || name.length > 60) return json({ ok: false, error: "store_name が不正です" }, 400);
        res = await sb.rpc("daily_report_card_vm_by_name", { p_store_name: name, p_date: date });
      } else return json({ ok: false, error: "store_id か store_name が必要です" }, 400);
      if (res.error) return json({ ok: false, error: "データ取得に失敗しました" }, 500);
      if (!res.data) return json({ ok: false, error: "店舗が見つかりません" }, 404);
      return json({ ok: true, vm: res.data });
    }

    if (action === "all_stores") {
      // 全12店舗日報（TK-255）: 店舗別日報と同じ daily_report_card_vm を12店分並べた読み取り専用データ（RPC all_stores_report_vm）
      const date = String(b.date ?? "").trim();
      if (!DATE_RE.test(date)) return json({ ok: false, error: "date は YYYY-MM-DD" }, 400);
      const res = await sb.rpc("all_stores_report_vm", { p_date: date });
      if (res.error) return json({ ok: false, error: "データ取得に失敗しました: " + String(res.error.message).slice(0, 120) }, 500);
      return json({ ok: true, data: res.data });
    }

    if (action === "upload") {
      const date = String(b.date ?? "").trim();
      const key = String(b.store_key ?? b.store_no ?? "").trim().replace(/[^a-zA-Z0-9_-]/g, "");
      if (!DATE_RE.test(date) || !key || key.length > 40) return json({ ok: false, error: "date と store_key が必要です" }, 400);
      if (!b.png_base64) return json({ ok: false, error: "png_base64 が必要です" }, 400);
      const bytes = b64ToBytes(String(b.png_base64));
      if (bytes.length < 1000 || bytes.length > 5 * 1024 * 1024) return json({ ok: false, error: `PNG のサイズが不正です (${bytes.length} bytes)` }, 400);
      // 配信済み画像は上書きしない（TK-252）: 同じ日・同じ店の2回目以降は `<key>_2.png`, `_3.png` … の別名で保存する（1回目は従来どおり `<key>.png`）
      const { data: existing } = await sb.storage.from(BUCKET).list(date, { limit: 1000 });
      const names = new Set((existing ?? []).map((x: any) => String(x.name)));
      let deliveryNo = 1, path = `${date}/${key}.png`;
      while (names.has(`${key}${deliveryNo === 1 ? "" : "_" + deliveryNo}.png`) && deliveryNo < 50) {
        deliveryNo++; path = `${date}/${key}_${deliveryNo}.png`;
      }
      const up = await sb.storage.from(BUCKET).upload(path, bytes, { contentType: "image/png", upsert: false, cacheControl: "300" });
      if (up.error) return json({ ok: false, error: "保存に失敗: " + up.error.message }, 500);
      // 配信時の VM（評価基準・評価結果込み）を保存して、過去日報を当時の基準で再現できるようにする。失敗しても画像の保存は成功扱い
      let snapshot = false;
      try {
        const vm = b.vm && typeof b.vm === "object" ? b.vm : null;
        const sid = vm && typeof vm.store_id === "string" && UUID_RE.test(vm.store_id) ? vm.store_id : null;
        if (vm && sid) {
          const { error: se } = await sb.from("daily_report_card_snapshots").insert({ store_id: sid, date, vm, delivery_no: deliveryNo });
          snapshot = !se;
        }
      } catch { /* noop */ }
      // 非公開バケットなので署名 URL で返す（発行ごとにトークンが変わるため、同じパスを上書きしても Slack 側のキャッシュは混ざらない）
      const url = await signedUrl(sb, path);
      if (!url) return json({ ok: false, error: "署名 URL を発行できません" }, 500);
      return json({ ok: true, path, url, expires_in: SIGNED_TTL, bytes: bytes.length, delivery_no: deliveryNo, snapshot });
    }

    if (action === "sign") {
      // 既存画像の署名 URL を再発行（再送・再生成用）
      const path = String(b.path ?? "").trim();
      if (!/^\d{4}-\d{2}-\d{2}\/[a-zA-Z0-9_-]{1,40}\.png$/.test(path)) return json({ ok: false, error: "path は <date>/<key>.png" }, 400);
      const url = await signedUrl(sb, path);
      if (!url) return json({ ok: false, error: "署名 URL を発行できません（存在しない可能性）" }, 404);
      return json({ ok: true, path, url, expires_in: SIGNED_TTL });
    }

    if (action === "prune") {
      // 日付フォルダ名（YYYY-MM-DD）が保持日数より古いものを削除する
      const days = Math.min(3650, Math.max(30, Number(b.days ?? 400) || 400));
      const cutoff = new Date(Date.now() - days * 86400 * 1000).toISOString().slice(0, 10);
      const { data: folders, error: lerr } = await sb.storage.from(BUCKET).list("", { limit: 1000 });
      if (lerr) return json({ ok: false, error: "一覧に失敗: " + lerr.message }, 500);
      const removed: string[] = [];
      for (const f of folders ?? []) {
        if (!DATE_RE.test(f.name) || f.name >= cutoff) continue;
        const { data: files } = await sb.storage.from(BUCKET).list(f.name, { limit: 1000 });
        const paths = (files ?? []).map((x: any) => `${f.name}/${x.name}`);
        if (paths.length) {
          const { error } = await sb.storage.from(BUCKET).remove(paths);
          if (!error) removed.push(...paths);
        }
      }
      return json({ ok: true, cutoff, removed: removed.length, days });
    }

    return json({ ok: false, error: `不明な action: ${action}` }, 400);
  } catch (e) {
    return json({ ok: false, error: String(e).slice(0, 300) }, 500);
  }
});
