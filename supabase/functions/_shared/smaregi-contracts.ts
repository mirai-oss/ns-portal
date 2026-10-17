// スマレジ複数契約対応の共通ヘルパー（担当D・2026-10-17）
// 設計: docs/設計メモ_スマレジ複数契約対応_2026-10-15.md §3／指示書_黒霧屋運営変更…§3
// クライアントID/シークレットは全契約で共通（1アプリ）。契約IDだけが契約ごとに違う。
// 契約マスタ(smaregi_contracts)が空・未作成の環境では、環境変数SMAREGI_CONTRACT_IDの1契約へ自動でフォールバックする（後方互換）。
export type Contract = { contract_id: string; corporation_id: string | null; label: string | null; corporation_hint: string | null; is_default: boolean };

export const IS_PROD = Deno.env.get("SMAREGI_ENV") === "prod";
export const ID_BASE = IS_PROD ? "https://id.smaregi.jp" : "https://id.smaregi.dev";
export const API_BASE = IS_PROD ? "https://api.smaregi.jp" : "https://api.smaregi.dev";
const CID = Deno.env.get("SMAREGI_CLIENT_ID") ?? "";
const SECRET = Deno.env.get("SMAREGI_CLIENT_SECRET") ?? "";

// 有効な契約の一覧（only指定でその契約だけ）。マスタが使えない場合は環境変数の1契約
export async function loadContracts(sb: any, only?: string): Promise<Contract[]> {
  let list: Contract[] = [];
  try {
    const { data, error } = await sb.from("smaregi_contracts").select("contract_id,corporation_id,label,corporation_hint,is_default").eq("is_active", true).order("created_at");
    if (!error && data) list = data as Contract[];
  } catch (_) { /* マスタ未作成 */ }
  if (!list.length) {
    const env = Deno.env.get("SMAREGI_CONTRACT_ID") ?? "";
    if (env) list = [{ contract_id: env, corporation_id: null, label: "環境変数の契約", corporation_hint: null, is_default: true }];
  }
  return only ? list.filter((c) => c.contract_id === only) : list;
}

export async function getContractToken(contractId: string, scopes: string): Promise<string> {
  const res = await fetch(`${ID_BASE}/app/${contractId}/token`, {
    method: "POST",
    headers: { Authorization: "Basic " + btoa(`${CID}:${SECRET}`), "Content-Type": "application/x-www-form-urlencoded" },
    body: "grant_type=client_credentials&scope=" + encodeURIComponent(scopes),
  });
  const j = await res.json().catch(() => ({}));
  if (!res.ok || !j.access_token) throw new Error(`スマレジ認証に失敗しました（契約…${contractId.slice(-3)}）: ` + JSON.stringify(j).slice(0, 200));
  return j.access_token;
}

// その契約で、指定期間(from〜to・YYYY-MM-DD)に有効な 従業員×スマレジのスタッフID
export async function loadLinks(sb: any, contractId: string, from: string, to: string) {
  const { data, error } = await sb.from("employee_smaregi_links")
    .select("user_id,smaregi_staff_id,effective_from,effective_to,users(name,is_active)")
    .eq("contract_id", contractId)
    .lte("effective_from", to)
    .or(`effective_to.is.null,effective_to.gte.${from}`);
  if (error) throw new Error("employee_smaregi_links取得失敗: " + error.message);
  return (data ?? []) as any[];
}

// その契約の「スマレジの事業所ID → 管理システムの店舗ID」。店舗IDは契約ごとに採番される（別契約で同じ番号が別店舗を指しうる）ため、
// store_external_mappings(smaregi_timecard)を契約で絞る。corporation_hintが空の既存マッピングは既定の契約のもの。
// 既定の契約だけ、互換のためstores.smaregi_store_idも併用する。
export async function loadStoreMap(sb: any, c: Contract): Promise<Record<string, string>> {
  const map: Record<string, string> = {};
  if (c.is_default) {
    const { data: stores } = await sb.from("stores").select("id,smaregi_store_id").not("smaregi_store_id", "is", null);
    (stores ?? []).forEach((s: any) => { map[String(s.smaregi_store_id)] = s.id; });
  }
  const { data: maps } = await sb.from("store_external_mappings")
    .select("external_store_id,store_id,corporation_hint,is_active,effective_from,effective_to")
    .eq("source_system", "smaregi_timecard");
  const today = new Date().toISOString().slice(0, 10);
  for (const m of maps ?? []) {
    if (m.is_active === false) continue;
    if (m.effective_to && m.effective_to < today) continue;
    if (m.effective_from && m.effective_from > today) continue;
    const mine = m.corporation_hint ? m.corporation_hint === c.corporation_hint : c.is_default;
    if (mine) map[String(m.external_store_id)] = m.store_id;
  }
  return map;
}

// 店舗→（その日に有効な）契約とスマレジの事業所ID。シフト等は店舗単位の操作のため、店舗の運営（＝契約）で送り先を決める。
// 店舗の対応（store_external_mappings smaregi_timecard）の有効期間(effective_from/to)で引くので、運営変更の前後で
// 別契約・別の事業所IDに切り替わる。corporation_hintが空の既存行は既定の契約。対応が無ければ既定の契約のstores.smaregi_store_id。
export async function resolveStoreContract(sb: any, storeId: string, onDate: string): Promise<{ contract: Contract; smaregiStoreId: string } | null> {
  const contracts = await loadContracts(sb);
  const { data: maps } = await sb.from("store_external_mappings")
    .select("external_store_id,corporation_hint,is_active,effective_from,effective_to")
    .eq("source_system", "smaregi_timecard").eq("store_id", storeId);
  for (const m of maps ?? []) {
    if (m.is_active === false) continue;
    if (m.effective_to && m.effective_to < onDate) continue;
    if (m.effective_from && m.effective_from > onDate) continue;
    const contract = m.corporation_hint ? contracts.find((c) => c.corporation_hint === m.corporation_hint) : contracts.find((c) => c.is_default);
    if (contract) return { contract, smaregiStoreId: String(m.external_store_id) };
  }
  const def = contracts.find((c) => c.is_default);
  if (def) {
    const { data: st } = await sb.from("stores").select("smaregi_store_id").eq("id", storeId).maybeSingle();
    if (st?.smaregi_store_id) return { contract: def, smaregiStoreId: String(st.smaregi_store_id) };
  }
  return null;
}

// 指定した従業員たちの、その契約・その日に有効なスマレジのスタッフID（user_id → staff_id）
export async function staffIdsByUser(sb: any, contractId: string, userIds: string[], onDate: string): Promise<Record<string, string>> {
  const out: Record<string, string> = {};
  if (!userIds.length) return out;
  const { data } = await sb.from("employee_smaregi_links")
    .select("user_id,smaregi_staff_id,effective_from,effective_to")
    .eq("contract_id", contractId).in("user_id", userIds).lte("effective_from", onDate)
    .or(`effective_to.is.null,effective_to.gte.${onDate}`);
  for (const r of data ?? []) out[r.user_id] = String(r.smaregi_staff_id);
  return out;
}
