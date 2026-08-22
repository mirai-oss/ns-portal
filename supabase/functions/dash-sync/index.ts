// 2026-08-22 作成・未デプロイ（WIP）。GCPサービスアカウント鍵の発行が組織ポリシー
// （iam.disableServiceAccountKeyCreation）でブロックされたため、ユーザーが組織ポリシー管理者に
// 解除可否を確認中。解除できなければGCP_BQ_SA_JSON方式は使わず、代わりにGAS側へ軽量な
// BigQuery問い合わせ専用アクションを追加する方式に切替える。詳細はtori-dashboard/HANDOFF.md
// 「2026-08-22（続き6）」参照。デプロイ前に必ず本番の現行dash-syncをバイナリから復元してdiffすること。
import { createClient } from "npm:@supabase/supabase-js@2";
const INTAKE_SECRET = "4259598a7ce747d54e2bf84326131129f21eb77f54dfdcdd";
// tori-dashboardのGAS Web App URL（公開リポジトリのapp.jsに同じ値がある。秘密情報ではない）
const DASH_API_URL = "https://script.google.com/macros/s/AKfycbz9rd37EZa6X8WRMVEBrXobN8DbYWkHRlhFNYU5rd1UZ0V8j0-6shMQjEeoi4HDWZ0B/exec";
const cors = {
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

async function dashSecrets(sb: any) {
  const { data } = await sb.from("app_secrets").select("key,value").in("key", ["dash_id", "dash_pw"]);
  const m: Record<string, string> = {};
  (data ?? []).forEach((r: any) => { m[r.key] = (r.value ?? "").trim(); });
  return { id: m.dash_id ?? "", pw: m.dash_pw ?? "" };
}
async function dashCall(body: unknown) {
  const res = await fetch(DASH_API_URL, {
    method: "POST",
    headers: { "Content-Type": "text/plain;charset=utf-8" },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  try { return JSON.parse(text); }
  catch (_) { return { ok: false, error: "ダッシュボードの応答を読めませんでした: " + text.slice(0, 200) }; }
}

// ============== BigQuery直接クエリ（2026-08-22追加。GASを経由せず倉庫(BigQuery)へ直接読みに行く） ==============
// 「実績（daily）」はここでBigQueryのfact_daily_storeから直接取得する。
// 「目標/目標月次」は人が手で入力する管理シート側の値で、BigQueryミラーの対象外のまま
// （自動集計データではないため）→ 引き続きGAS経由（dashCall）で取得する。両者は完全に独立した経路。
const BQ_PROJECT = "tori-analytics";
const BQ_DATASET = "sales";

function b64url(bytes: Uint8Array): string {
  let str = "";
  bytes.forEach((b) => { str += String.fromCharCode(b); });
  return btoa(str).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function b64urlStr(s: string): string { return b64url(new TextEncoder().encode(s)); }

async function importSaKey(pem: string): Promise<CryptoKey> {
  const body = pem.replace(/-----BEGIN PRIVATE KEY-----/, "").replace(/-----END PRIVATE KEY-----/, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  return await crypto.subtle.importKey("pkcs8", der.buffer, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
}

let cachedToken: { token: string; exp: number } | null = null;
async function bqAccessToken(): Promise<string> {
  if (cachedToken && cachedToken.exp > Date.now() / 1000 + 60) return cachedToken.token;
  const saRaw = Deno.env.get("GCP_BQ_SA_JSON");
  if (!saRaw) throw new Error("GCP_BQ_SA_JSON が未設定です（サービスアカウントの鍵をSupabaseの秘密変数に登録してください）");
  const sa = JSON.parse(saRaw);
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "RS256", typ: "JWT" };
  const claim = {
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/bigquery.readonly",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  };
  const signingInput = `${b64urlStr(JSON.stringify(header))}.${b64urlStr(JSON.stringify(claim))}`;
  const key = await importSaKey(sa.private_key);
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(signingInput));
  const jwt = `${signingInput}.${b64url(new Uint8Array(sig))}`;

  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: "grant_type=" + encodeURIComponent("urn:ietf:params:oauth:grant-type:jwt-bearer") + "&assertion=" + encodeURIComponent(jwt),
  });
  const j = await res.json();
  if (!res.ok || !j.access_token) throw new Error("Google認証に失敗しました: " + JSON.stringify(j));
  cachedToken = { token: j.access_token, exp: now + (j.expires_in ?? 3600) };
  return j.access_token;
}

// SELECT文を投げて [ [列名,...], [値,...], ... ] の形（既存のsheets.dailyと同じ構造）で返す
async function bqQuery(sql: string): Promise<any[][]> {
  const token = await bqAccessToken();
  const res = await fetch(`https://bigquery.googleapis.com/bigquery/v2/projects/${BQ_PROJECT}/queries`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ query: sql, useLegacySql: false, timeoutMs: 30000 }),
  });
  const j = await res.json();
  if (!res.ok || j.jobComplete === false) throw new Error("BigQueryクエリに失敗しました: " + JSON.stringify(j).slice(0, 500));
  const fields = (j.schema?.fields ?? []).map((f: any) => f.name);
  const rows = (j.rows ?? []).map((r: any) => r.f.map((c: any) => c.v));
  return [fields, ...rows];
}

// ---- 列名のゆらぎに強い読み方（tori-dashboardのapp.js ingestDaily 等と同じ考え方。目標/目標月次はGAS経由のまま使う） ----
function colIdx(header: string[], candidates: string[]): number {
  for (const c of candidates) {
    const i = header.findIndex((h) => String(h ?? "").includes(c));
    if (i >= 0) return i;
  }
  return -1;
}
function num(v: unknown): number {
  const n = Number(String(v ?? "").replace(/[,¥\s]/g, ""));
  return isNaN(n) ? 0 : n;
}
function toDateStr(v: unknown): string | null {
  const s = String(v ?? "").trim();
  const m = s.match(/(\d{4})[\/\-](\d{1,2})[\/\-](\d{1,2})/);
  if (!m) return null;
  return `${m[1]}-${m[2].padStart(2, "0")}-${m[3].padStart(2, "0")}`;
}
function toYm(v: unknown): string | null {
  const s = String(v ?? "").trim();
  const m = s.match(/(\d{4})[\/\-](\d{1,2})/);
  if (!m) return null;
  return `${m[1]}-${m[2].padStart(2, "0")}-01`;
}
async function logRun(sb: any, ok: boolean, detail: string) {
  try { await sb.from("dash_sync_log").insert({ ok, detail: detail.slice(0, 2000) }); } catch (_e) {}
}

async function runSync(sb: any) {
  const { data: storeRows } = await sb.from("stores").select("id,name,dash_store_name");
  const nameMap = new Map<string, string>();
  (storeRows ?? []).forEach((s: any) => {
    if (s.dash_store_name) nameMap.set(String(s.dash_store_name).trim(), s.id);
    if (!nameMap.has(String(s.name).trim())) nameMap.set(String(s.name).trim(), s.id);
  });
  const unmatched = new Set<string>();

  // --- ① 分析_日別店舗（実績）: BigQueryから直接（GASを経由しない） ---
  const dailyUpserts: any[] = [];
  try {
    const cutoff = new Date(); cutoff.setMonth(cutoff.getMonth() - 2);
    const cutoffStr = cutoff.toISOString().slice(0, 10);
    const dailyRows = await bqQuery(
      `SELECT date, store_name, net_sales, cogs, labor_cost_total FROM \`${BQ_PROJECT}.${BQ_DATASET}.fact_daily_store\` WHERE date >= DATE('${cutoffStr}')`,
    );
    for (let r = 1; r < dailyRows.length; r++) {
      const row = dailyRows[r];
      const storeName = String(row[1] ?? "").trim();
      const dateStr = String(row[0] ?? "");
      if (!storeName || !dateStr) continue;
      const storeId = nameMap.get(storeName);
      if (!storeId) { unmatched.add(storeName); continue; }
      dailyUpserts.push({
        store_id: storeId,
        biz_date: dateStr,
        sales: num(row[2]),
        cost: num(row[3]),
        labor: num(row[4]),
        updated_at: new Date().toISOString(),
      });
    }
  } catch (e) {
    const msg = "BigQueryからの実績取得に失敗: " + String((e as Error)?.message ?? e);
    await logRun(sb, false, msg);
    return { ok: false, error: msg };
  }

  // --- ②③ 目標・目標月次: 手入力のためBigQueryミラー対象外。引き続きGAS経由で取得 ---
  const { id, pw } = await dashSecrets(sb);
  let targetUpserts: any[] = [];
  let targetMUpserts: any[] = [];
  let targetMExtra: any[] = [];
  let extraOk = true;
  if (id && pw) {
    const login = await dashCall({ action: "login", id, pw });
    if (login.ok) {
      const data = await dashCall({ action: "data", token: login.token, keys: "目標,目標月次", months: 2 });
      if (data.ok) {
        const sheets = data.sheets ?? {};
        const targetRows = sheets["目標"] ?? [];
        if (targetRows.length > 1) {
          const header = targetRows[0].map((h: any) => String(h ?? ""));
          const iD = colIdx(header, ["日付", "営業日"]);
          const iS = colIdx(header, ["店舗名", "店舗"]);
          const iV = colIdx(header, ["売上目標", "目標"]);
          for (let r = 1; r < targetRows.length; r++) {
            const row = targetRows[r];
            const storeName = String(row[iS] ?? "").trim();
            const dateStr = toDateStr(row[iD]);
            if (!storeName || !dateStr) continue;
            const storeId = nameMap.get(storeName);
            if (!storeId) { unmatched.add(storeName); continue; }
            targetUpserts.push({ store_id: storeId, biz_date: dateStr, sales_target: iV >= 0 ? num(row[iV]) : 0, updated_at: new Date().toISOString() });
          }
        }
        const targetMRows = sheets["目標月次"] ?? [];
        if (targetMRows.length > 1) {
          const header = targetMRows[0].map((h: any) => String(h ?? ""));
          const iM = colIdx(header, ["年月"]);
          const iS = colIdx(header, ["店舗名", "店舗"]);
          const iPA = colIdx(header, ["PA人件費率", "アルバイト人件費率"]);
          const iEmp = colIdx(header, ["社員人件費率"]);
          const iCost = colIdx(header, ["仕入原価率", "原価率"]);
          const iDinii = colIdx(header, ["ダイニー点数", "ダイニー"]);
          const iReview = colIdx(header, ["口コミ件数", "口コミ"]);
          for (let r = 1; r < targetMRows.length; r++) {
            const row = targetMRows[r];
            const storeName = String(row[iS] ?? "").trim();
            const ym = toYm(row[iM]);
            if (!storeName || !ym) continue;
            const storeId = nameMap.get(storeName);
            if (!storeId) { unmatched.add(storeName); continue; }
            targetMUpserts.push({
              store_id: storeId, ym,
              pa_rate: iPA >= 0 ? num(row[iPA]) : null,
              emp_rate: iEmp >= 0 ? num(row[iEmp]) : null,
              cost_rate: iCost >= 0 ? num(row[iCost]) : null,
              updated_at: new Date().toISOString(),
            });
            if (iDinii >= 0 || iReview >= 0) {
              targetMExtra.push({ store_id: storeId, ym, dinii_target: iDinii >= 0 ? num(row[iDinii]) : null, review_target: iReview >= 0 ? num(row[iReview]) : null });
            }
          }
        }
      }
    }
  }

  async function chunkUpsert(table: string, rows: any[], onConflict: string) {
    for (let i = 0; i < rows.length; i += 500) {
      const { error } = await sb.from(table).upsert(rows.slice(i, i + 500), { onConflict });
      if (error) throw new Error(`${table} への保存に失敗: ${error.message}`);
    }
  }
  await chunkUpsert("dash_sales_daily", dailyUpserts, "store_id,biz_date");
  await chunkUpsert("dash_sales_target_daily", targetUpserts, "store_id,biz_date");
  await chunkUpsert("dash_target_monthly", targetMUpserts, "store_id,ym");
  if (targetMExtra.length) {
    try { await chunkUpsert("dash_target_monthly", targetMExtra, "store_id,ym"); } catch (_e) { extraOk = false; }
  }

  const detail = `実績${dailyUpserts.length}件(BigQuery直読み)・売上目標${targetUpserts.length}件・FL目標${targetMUpserts.length}件` +
    (targetMExtra.length ? `・ダイニー/口コミ目標${extraOk ? targetMExtra.length + "件" : "反映失敗（SQL未適用の可能性）"}` : "") +
    (unmatched.size ? `／店舗名が対応表に無い: ${[...unmatched].join("、")}` : "");
  await logRun(sb, true, detail);
  return { ok: true, daily: dailyUpserts.length, target: targetUpserts.length, targetM: targetMUpserts.length, unmatched: [...unmatched] };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const raw = await req.text();
    let body: any = {};
    try { body = JSON.parse(raw || "{}"); } catch (_) { body = {}; }
    const sb = svc();
    // ---------------- GASから1日1回（合言葉で認証・ログイン不要） ----------------
    if (body.action === "daily") {
      if (body.secret !== INTAKE_SECRET) return json({ ok: false, error: "認証エラー" }, 403);
      const result = await runSync(sb);
      return json(result, result.ok ? 200 : 500);
    }
    // ---------------- ここから先はログイン必須 ----------------
    const uid = jwtUid(req);
    if (!uid) return json({ ok: false, error: "ログインが必要です" }, 401);
    const { data: u } = await sb.from("users").select("role").eq("id", uid).maybeSingle();
    if (!u || !["CEO", "HQ", "TEAM", "TENCHO"].includes(u.role)) {
      return json({ ok: false, error: "権限がありません（社長・本部・チーム長・店長のみ）" }, 403);
    }
    if (body.action === "test") {
      const { id, pw } = await dashSecrets(sb);
      if (!id || !pw) return json({ ok: false, error: "IDとパスワードを入力してください" }, 400);
      const login = await dashCall({ action: "login", id, pw });
      if (!login.ok) return json({ ok: false, error: "ログインできませんでした: " + (login.error ?? "不明なエラー") }, 400);
      return json({ ok: true, name: login.account?.name ?? "", role: login.account?.role ?? "" });
    }
    if (body.action === "sync_now") {
      const result = await runSync(sb);
      return json(result, result.ok ? 200 : 500);
    }
    return json({ ok: false, error: "unknown action" }, 400);
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
