// 経営ダッシュボード系の Edge Function で「法人を限定された人」に、他法人のデータを返さないための共通の部品（2026-11-28）
//
// 背景: Edge Function はサービス用の鍵で DB を読むため、DB の RLS（行の制限）を通らない。
//   本番の DB 側（kd_deposit_daily・kd_deposit_monthly_summary・ar_*）は、法人の限定を RLS で守るようにした
//   （public.dep_unrestricted() / public.dep_allowed_corp_ids()＝呼び出しユーザーの auth.uid() 基準）。
//   ところが Edge Function は auth.uid() が無い（サービス接続）ので、その関数は使えない。→ 同じ意味の判定をここで行う。
//
// 判定（public.dep_unrestricted() / dep_allowed_corp_ids() と同じ意味）:
//   ・マスターは全法人（制限なし）。
//   ・info.user_corporations（個人の許可）に 1 行でもあれば、その法人だけ（役職の許可は見ない）。
//   ・個人の許可が無ければ、info.profiles（有効なもの）の role_id の info.role_corporations（役職の許可）。1 行でもあれば、その法人だけ。
//   ・どちらも無ければ制限なし（＝従来どおり全法人。ここは変えない）。
//   ・許可された info の法人 id は、public.corporations.legacy_info_id で public.corporations.id に読み替える（kd_* の corporation_id はこちら）。
//     対応する public の法人が無ければ、その許可は何も見せない（許可の設定が有るのに全部見える、は起こさない）。
//
// 戻り値 CorpScope:
//   corporationIds … 見てよい public.corporations.id。null＝制限なし（全法人）。[]＝何も見せない。
//   storeIds       … 見てよい法人に属する public.stores.id（有効・無効を問わない）。null＝制限なし。
//
// 失敗したら例外を投げる（呼び出し側は 500 を返す）。許可の設定を読めないときに「制限なし」へ倒れて全法人を返すことは、しない。
// 値（鍵・トークン・個人情報）はログにもエラーにも出さない。

/** Supabase クライアントのうち、この部品が使う所だけ（テストでは、にせものを渡せる） */
// deno-lint-ignore no-explicit-any
export interface CorpScopeClient {
  // deno-lint-ignore no-explicit-any
  from(table: string): any;
  // deno-lint-ignore no-explicit-any
  schema(name: string): { from(table: string): any };
}

export interface CorpScope {
  /** 見てよい public.corporations.id。null＝制限なし */
  corporationIds: string[] | null;
  /** 見てよい法人に属する public.stores.id。null＝制限なし */
  storeIds: string[] | null;
}

export const NO_CORP_RESTRICTION: CorpScope = Object.freeze({ corporationIds: null, storeIds: null }) as CorpScope;
/** 何も見せない（許可の設定が有るのに読み替え先が無い／uid が無い、など） */
const DENY_ALL = (): CorpScope => ({ corporationIds: [], storeIds: [] });

// deno-lint-ignore no-explicit-any
function must<T extends { data: any; error: any }>(r: T, what: string): any[] {
  if (r.error) throw new Error(`法人の許可設定を読めませんでした（${what}）`);
  return (r.data ?? []) as any[];
}

/**
 * 呼び出し元（検証済みの uid）が見てよい法人・店舗を返す。
 * - isMaster（users.is_master）なら DB を読まずに制限なし。
 * - 呼び出し元がサービス用の鍵（isServiceRoleRequest）なら、この関数を呼ばずに NO_CORP_RESTRICTION を使うこと。
 */
export async function resolveCorpScope(sb: CorpScopeClient, uid: string, opts: { isMaster?: boolean } = {}): Promise<CorpScope> {
  if (opts.isMaster) return NO_CORP_RESTRICTION;
  if (!uid) return DENY_ALL();

  const info = sb.schema("info");
  // 個人の許可と、本人の役職（profile）は同時に読む
  const [ucRes, profRes] = await Promise.all([
    info.from("user_corporations").select("corporation_id").eq("user_id", uid),
    info.from("profiles").select("role_id,is_active").eq("id", uid).maybeSingle(),
  ]);
  const ucRows = must(ucRes, "user_corporations");
  if (profRes.error) throw new Error("法人の許可設定を読めませんでした（profiles）");

  let allowedInfoIds: string[] | null = null; // info.corporations.id
  if (ucRows.length > 0) {
    allowedInfoIds = ucRows.map((r) => String(r.corporation_id));
  } else {
    const p = profRes.data;
    if (p && p.is_active && p.role_id) {
      const rcRows = must(await info.from("role_corporations").select("corporation_id").eq("role_id", p.role_id), "role_corporations");
      if (rcRows.length > 0) allowedInfoIds = rcRows.map((r) => String(r.corporation_id));
    }
  }
  if (allowedInfoIds === null) return NO_CORP_RESTRICTION; // 限定の設定が無い＝従来どおり全法人

  const corpRows = must(await sb.from("corporations").select("id,legacy_info_id").in("legacy_info_id", allowedInfoIds), "corporations");
  const corporationIds = [...new Set(corpRows.map((r) => String(r.id)))];
  if (corporationIds.length === 0) return DENY_ALL();
  const storeRows = must(await sb.from("stores").select("id,corporation_id").in("corporation_id", corporationIds), "stores");
  return { corporationIds, storeIds: [...new Set(storeRows.map((r) => String(r.id)))] };
}

/** クエリ（supabase-js の絞り込み）に、法人の制限を足す。制限なしなら何もしない（クエリは従来と同一）。 */
export function applyCorpFilter<Q extends { in(col: string, values: string[]): Q }>(
  q: Q, corp: CorpScope, cols: { storeCol?: string | null; corpCol?: string | null },
): Q {
  if (corp.corporationIds === null) return q;
  if (cols.corpCol) q = q.in(cols.corpCol, corp.corporationIds);   // 法人の列がある表: 法人の列で絞る（DB の RLS と同じ。法人が空の行は出ない）
  else if (cols.storeCol) q = q.in(cols.storeCol, corp.storeIds ?? []); // 法人の列が無い表: 店舗→法人で絞る
  return q;
}

/** 返り値の scope に足す（制限が有るときだけ。制限なしなら何も足さない＝従来と同じ形） */
export function corpScopeEcho(corp: CorpScope): { corporationIds?: string[] } {
  return corp.corporationIds === null ? {} : { corporationIds: corp.corporationIds };
}
