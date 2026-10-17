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
const SCOPES = "timecard.staffs:read timecard.stores:read timecard.settings:read";

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
    // probe: 役割(roles)の一覧と、指定スタッフの所属(staff_stores)の持ち方を読むだけ（個人情報は返さない。役割ID・事業所IDのみ）
    //   スマレジの PUT /staffs/{id}/staff_stores/{store_id} が役割IDを要求するため、正しい値を調べる用（2026-10-17）
    if (body.action === "probe") {
      const contract = String(body.contract_id || DEFAULT_CONTRACT);
      const out: Record<string, unknown> = {};
      // 入社登録(smaregi-sync)が使う権限で取れるかを確認する（書き込み権限がアプリに許可されているか）
      const WRITE_SCOPES = "timecard.staffs:read timecard.staffs:write timecard.stores:read timecard.settings:read";
      for (const sc of [WRITE_SCOPES, "timecard.staffs:read timecard.stores:read", "timecard.staffs:write", "timecard.settings:read"]) {
        const tr = await fetch(`${ID_BASE}/app/${contract}/token`, { method: "POST", headers: { Authorization: "Basic " + btoa(`${CID}:${SECRET}`), "Content-Type": "application/x-www-form-urlencoded" }, body: "grant_type=client_credentials&scope=" + encodeURIComponent(sc) });
        const tj = await tr.json().catch(() => ({}));
        out["token:" + sc.replace(/timecard\./g, "").replace(/ /g, ",")] = { status: tr.status, ok: !!tj.access_token, scope: tj.scope ?? null, error: tj.access_token ? null : JSON.stringify(tj).slice(0, 200) };
      }
      const token = await getToken(contract);
      const stores = await pagedGet(contract, token, "/stores", "stores");
      const ids = stores.map((x: any) => String(x.storeId)).join(",");
      const paths = [`/roles?store_id=${ids}`, "/employee_classifications", ...(body.staff_id ? [`/staff_stores?staff_id=${encodeURIComponent(String(body.staff_id))}`, `/staffs/${encodeURIComponent(String(body.staff_id))}`] : [])];
      if (body.store_id) paths.push(`/staffs?store_id=${encodeURIComponent(String(body.store_id))}&limit=100`, `/staff_stores?store_id=${encodeURIComponent(String(body.store_id))}&limit=100`);
      for (const path of paths) {
        const r = await api(contract, token, path);
        const raw = await r.json().catch(() => null);
        const key = path.split("?")[0].replace(/\/\d+$/, "/{id}");
        // 個人情報（氏名・住所・電話・メール等）は絶対に返さない。ID・フラグだけに絞る（この関数の出力は公開リポジトリのActionsログに載るため）
        const slim = (x: any) => ({ staffId: x?.staffId ?? x?.staff?.staffId, storeId: x?.storeId, termination: x?.terminationFlag ?? x?.termination ?? x?.staff?.terminationFlag, active: x?.activeFlag ?? x?.staff?.activeFlag, admin: x?.adminFlag, classification: x?.employeeClassificationId, display: x?.displayFlag, appDisplay: x?.applicationDisplayFlag });
        let outBody: unknown;
        if (!r.ok) outBody = JSON.stringify(raw).slice(0, 200).replace(/"(staffName|staffKana|mail|phone|address|birthday)":"[^"]*"/g, "");
        else if (key === "/roles") outBody = raw;                                       // 役割（個人情報なし）
        else if (key === "/employee_classifications") outBody = Array.isArray(raw) ? raw.map((x: any) => ({ id: x.employeeClassificationId, name: x.employeeClassificationName })) : raw;
        else if (key === "/staffs/{id}") outBody = slim(raw);
        else if (Array.isArray(raw)) outBody = raw.map(slim);
        else if (Array.isArray(raw?.staffs)) outBody = { count: raw.count, staffs: raw.staffs.map(slim) };
        else outBody = "（個人情報を含むため省略）";
        const keyQ = path.includes("store_id=") && (key === "/staffs" || key === "/staff_stores") ? key + "?store" : key;
        out[keyQ] = { status: r.status, body: outBody };
      }
      return json({ ok: true, ...out });
    }
    if (body.action !== "snapshot") return json({ ok: false, error: "action は snapshot / probe のみ対応" }, 400);

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
        // 注意: /staffs?store_id= は所属者が0人の事業所だと全員を返すことがあるため使わない。/staff_stores?store_id= で読む
        const rows = await pagedGet(contract, token, `/staff_stores?store_id=${encodeURIComponent(st.store_id)}`, "staffStores");
        for (const s of rows) {
          if (String(s.staff?.terminationFlag ?? "0") === "1") continue;
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
