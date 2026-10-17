// スマレジ・タイムカードの「事業所ごとの所属スタッフ」を読み取り、スナップショット表へ保存する Edge Function
// （2026-10-17・担当D・設計メモ_スマレジ複数契約対応 §11-4「初回の一致」の棚卸し用）
//
// 【読み取り専用】スマレジへはGETしか行わない（PUT/DELETEは一切しない）。管理システム側の`user_stores`も触らない。
// 書き込み先は新設のスナップショット表（smaregi_stores_snapshot / smaregi_staff_stores_snapshot）だけ。
// 契約は複数対応を見据え、契約IDを引数で受ける（省略時は環境変数SMAREGI_CONTRACT_ID＝トーホー）。
//
// 呼び出し: POST { action: "snapshot", contract_id?: string }
// 認可: service_roleキー直呼び（GitHub Actions等の内部バッチ）または CEO/HQ のJWT。
// 注意: 個人名などは応答に含めない（件数のみ返す。公開リポジトリのActionsログに名前を残さないため）。
import { createClient } from "npm:@supabase/supabase-js@2";

const IS_PROD = Deno.env.get("SMAREGI_ENV") === "prod";
const ID_BASE = IS_PROD ? "https://id.smaregi.jp" : "https://id.smaregi.dev";
const API_BASE = IS_PROD ? "https://api.smaregi.jp" : "https://api.smaregi.dev";
const DEFAULT_CONTRACT = Deno.env.get("SMAREGI_CONTRACT_ID") ?? "";
const CID = Deno.env.get("SMAREGI_CLIENT_ID") ?? "";
const SECRET = Deno.env.get("SMAREGI_CLIENT_SECRET") ?? "";
const SCOPES = "timecard.staffs:read timecard.stores:read";

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

async function getToken(contract: string): Promise<string> {
  const res = await fetch(`${ID_BASE}/app/${contract}/token`, {
    method: "POST",
    headers: { Authorization: "Basic " + btoa(`${CID}:${SECRET}`), "Content-Type": "application/x-www-form-urlencoded" },
    body: "grant_type=client_credentials&scope=" + encodeURIComponent(SCOPES),
  });
  const j = await res.json().catch(() => ({}));
  if (!res.ok || !j.access_token) throw new Error("スマレジ認証に失敗しました（契約 " + contract + "）: " + JSON.stringify(j).slice(0, 200));
  return j.access_token;
}

const api = (contract: string, token: string, path: string) =>
  fetch(`${API_BASE}/${contract}/timecard${path}`, { headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" } });

async function pagedGet(contract: string, token: string, path: string, listKey: string): Promise<any[]> {
  const out: any[] = [];
  for (let page = 1; page <= 30; page++) {
    const sep = path.includes("?") ? "&" : "?";
    const r = await api(contract, token, `${path}${sep}limit=100&page=${page}`);
    const raw = await r.json().catch(() => null);
    if (!r.ok) throw new Error(`GET ${path} ${r.status}: ${JSON.stringify(raw).slice(0, 200)}`);
    const arr = Array.isArray(raw) ? raw : (raw?.[listKey] ?? []);
    out.push(...arr);
    const pageCount = Array.isArray(raw) ? (arr.length < 100 ? page : page + 1) : (raw?.pageCount ?? page);
    if (page >= Number(pageCount) || arr.length === 0) break;
  }
  return out;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const sb = svc();
    const body = await req.json().catch(() => ({}));
    const authHeader = req.headers.get("Authorization") ?? "";
    const isServiceRole = authHeader.includes(Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? " ");
    if (!isServiceRole) {
      const uid = jwtUid(req);
      const { data: u } = await sb.from("users").select("role,is_active,is_master").eq("id", uid).maybeSingle();
      if (!u?.is_active || !(u.is_master || ["CEO", "HQ"].includes(u.role))) return json({ ok: false, error: "権限がありません（CEO/HQのみ）" }, 403);
    }
    if (body.action !== "snapshot") return json({ ok: false, error: "action は snapshot のみ対応" }, 400);

    const contract = String(body.contract_id || DEFAULT_CONTRACT);
    if (!contract) return json({ ok: false, error: "契約IDが未設定です" }, 400);
    const token = await getToken(contract);

    // 1) 事業所一覧（全件。管理システムに対応が無い事業所も含めて把握する）
    const stores = await pagedGet(contract, token, "/stores", "stores");
    const storeRows = stores.map((s: any) => ({
      store_id: String(s.storeId), store_code: s.storeCode ?? null, store_name: s.storeName ?? null,
    }));

    // 2) 事業所ごとの所属スタッフ（/staffs?store_id=…。退職者(termination=1)は除外）
    const staffRows: any[] = [];
    const failed: string[] = [];
    for (const st of storeRows) {
      try {
        const staffs = await pagedGet(contract, token, `/staffs?store_id=${encodeURIComponent(st.store_id)}`, "staffs");
        for (const s of staffs) {
          if (String(s.termination ?? "0") === "1") continue;
          staffRows.push({ smaregi_store_id: st.store_id, smaregi_staff_id: String(s.staffId) });
        }
      } catch (e) { failed.push(`${st.store_id}: ${String((e as Error).message ?? e).slice(0, 120)}`); }
    }

    // 3) 保存（同じ契約の前回スナップショットは置き換え。履歴は run_id 単位で最新のみ保持）
    const runId = crypto.randomUUID();
    const fetchedAt = new Date().toISOString();
    await sb.from("smaregi_stores_snapshot").delete().eq("contract_id", contract);
    await sb.from("smaregi_staff_stores_snapshot").delete().eq("contract_id", contract);
    if (storeRows.length) {
      const { error } = await sb.from("smaregi_stores_snapshot").insert(storeRows.map((r) => ({ ...r, contract_id: contract, run_id: runId, fetched_at: fetchedAt })));
      if (error) throw new Error("smaregi_stores_snapshot保存失敗: " + error.message);
    }
    for (let i = 0; i < staffRows.length; i += 500) {
      const { error } = await sb.from("smaregi_staff_stores_snapshot").insert(staffRows.slice(i, i + 500).map((r) => ({ ...r, contract_id: contract, run_id: runId, fetched_at: fetchedAt })));
      if (error) throw new Error("smaregi_staff_stores_snapshot保存失敗: " + error.message);
    }
    return json({
      ok: failed.length === 0, contract_id_suffix: contract.slice(-3), run_id: runId,
      stores: storeRows.length, staff_store_rows: staffRows.length,
      distinct_staffs: new Set(staffRows.map((r) => r.smaregi_staff_id)).size,
      failed_stores: failed.length, failed,
    });
  } catch (e) {
    return json({ ok: false, error: String((e as Error).message ?? e) }, 500);
  }
});
