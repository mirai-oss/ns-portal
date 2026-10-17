// スマレジ複数契約対応の共通ヘルパー（担当D・2026-10-17）
// 設計: docs/設計メモ_スマレジ複数契約対応_2026-10-15.md §3／指示書_黒霧屋運営変更…§3
// クライアントID/シークレットは全契約で共通（1アプリ）。契約IDだけが契約ごとに違う。
// 契約マスタ(smaregi_contracts)が空・未作成の環境では、環境変数SMAREGI_CONTRACT_IDの1契約へ自動でフォールバックする（後方互換）。
export type Contract = { contract_id: string; corporation_id: string | null; label: string | null };

export const IS_PROD = Deno.env.get("SMAREGI_ENV") === "prod";
export const ID_BASE = IS_PROD ? "https://id.smaregi.jp" : "https://id.smaregi.dev";
export const API_BASE = IS_PROD ? "https://api.smaregi.jp" : "https://api.smaregi.dev";
const CID = Deno.env.get("SMAREGI_CLIENT_ID") ?? "";
const SECRET = Deno.env.get("SMAREGI_CLIENT_SECRET") ?? "";

// 有効な契約の一覧（only指定でその契約だけ）。マスタが使えない場合は環境変数の1契約
export async function loadContracts(sb: any, only?: string): Promise<Contract[]> {
  let list: Contract[] = [];
  try {
    const { data, error } = await sb.from("smaregi_contracts").select("contract_id,corporation_id,label").eq("is_active", true).order("created_at");
    if (!error && data) list = data as Contract[];
  } catch (_) { /* マスタ未作成 */ }
  if (!list.length) {
    const env = Deno.env.get("SMAREGI_CONTRACT_ID") ?? "";
    if (env) list = [{ contract_id: env, corporation_id: null, label: "環境変数の契約" }];
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
