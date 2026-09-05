// W3②: PL/売上分析(媒体別)/入金のkd_月次サマリを返す軽量読み取りAPI（レーンP・2026-09-06新設）
// docs/設計書_表示集計層kdと高速化実行計画_2026-09-02.md §3/§6/§10.2-1
//
// 目的: PL・媒体別売上分析・入金確認の各画面が、GAS(bqGetPL/bqGetMedia/bqGetDeposit)を待たずに
// Supabaseの集計済みテーブル（kd_pl_monthly_summary/kd_media_monthly_summary/kd_deposit_monthly_summary）
// を直接読めるようにする。明細行(stg_pl等)は返さない・kind/期間/limitを必須にする（§6の軽量化規約）。
// 書き込みはkeiei-kd-refresh（別Function・service_role限定）のみ。本Functionは読み取り専用。
//
// 呼び出し: POST { kind: 'pl'|'media'|'deposit', year_month?: 'YYYY-MM', from?: 'YYYY-MM', to?: 'YYYY-MM',
//                  store_id?: uuid, media_name?: string, limit?: number(既定500・最大2000) }
//   year_monthのみ指定＝単月。from+to指定＝期間（両方省略はエラー）。
// 返り値: { ok:true, kind, from, to, rows:[...], scope:{role,restrictedStoreIds} }
//
// 【既知の制約（v1）】kd_pl_monthly_summaryの広告費(自動component)・簡易CF・kd_media_monthly_summaryの
// 広告費/ROAS/キャンセル率は元データ未対応のためこのAPIの返り値にも含まれない
// （詳細はsupabase/2026-09-06_kd_pl_media_deposit_monthly.sqlの冒頭コメント参照）。
//
// 【業務委託精算書由来のPL反映（2026-09-06追加・司令塔指示。新旧突合パネルの材料）】
// kind='pl'の各行にseisan_synced_breakdown（既にDB_PL/stg_plへ反映済みの精算書由来分の内訳。
// cost_total等に既に含まれている＝加算禁止・裏付け表示用）とseisan_pending_total/breakdown
// （まだDB_PL未反映＝振込確定待ち/PL同期待ち。cost_total等には含まれていない「処理中」の金額）を
// 追加した。詳細はsupabase/2026-09-06_kd_pl_monthly_seisan.sqlのコメント参照。
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
function isYm(s: unknown): s is string { return typeof s === "string" && /^\d{4}-\d{2}$/.test(s); }

// keiei-api-homeのresolveScope()と同じ判定（経営Dと同じ役職ゲート）。
async function resolveScope(sb: ReturnType<typeof createClient>, uid: string) {
  const { data: u } = await sb.from("users").select("id,role,is_master,is_active").eq("id", uid).maybeSingle();
  if (!u || !u.is_active) return { allowed: false as const, error: "ログインが必要です（アカウントが無効です）" };
  if (u.is_master || ["CEO", "HQ", "TEAM"].includes(u.role)) {
    return { allowed: true as const, role: u.role, restrictedStoreIds: null as string[] | null };
  }
  if (u.role === "TENCHO") {
    const { data: us } = await sb.from("user_stores").select("store_id").eq("user_id", uid);
    return { allowed: true as const, role: u.role, restrictedStoreIds: (us ?? []).map((r: any) => r.store_id) };
  }
  return { allowed: false as const, error: "権限がありません（社長・本部・チーム長・店長のみ。経営Dと同じ判定）" };
}

const PL_COLUMNS = "store_id,corporation_id,year_month,sales,cost_auto,cost_manual,cost_total,labor_auto,labor_manual,labor_total,ad_manual,rent,other,gross_profit,sga,operating_profit,pl_item_breakdown,seisan_synced_breakdown,seisan_pending_total,seisan_pending_breakdown,source_updated_at,computed_at,sync_run_id";
const MEDIA_COLUMNS = "store_id,corporation_id,year_month,media_name,net_sales,guests,parties,source_updated_at,computed_at,sync_run_id";
const DEPOSIT_COLUMNS = "store_id,corporation_id,year_month,deposit_total,deposit_count,sales_total,diff,source_breakdown,source_updated_at,computed_at,sync_run_id";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const sb = svc();
    let body: any = {};
    try { body = await req.json(); } catch (_) { /* ボディ必須（下のkindチェックで弾く） */ }

    const kind = body.kind;
    if (!["pl", "media", "deposit"].includes(kind)) {
      return json({ ok: false, error: "kindは'pl'|'media'|'deposit'のいずれかが必須です" }, 400);
    }
    const from = isYm(body.year_month) ? body.year_month : (isYm(body.from) ? body.from : null);
    const to = isYm(body.year_month) ? body.year_month : (isYm(body.to) ? body.to : null);
    if (!from || !to) {
      return json({ ok: false, error: "year_month、またはfrom+to（YYYY-MM形式）の期間指定が必須です（明細の全件返しを防ぐため）" }, 400);
    }
    const limit = Math.min(2000, Math.max(1, Number(body.limit) || 500));

    const authHeader = req.headers.get("Authorization") ?? "";
    const isServiceRole = authHeader.includes(Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? " ");
    let restrictedStoreIds: string[] | null = null;
    let role = "service_role";
    if (!isServiceRole) {
      const uid = jwtUid(req);
      if (!uid) return json({ ok: false, error: "ログインが必要です" }, 401);
      const scope = await resolveScope(sb, uid);
      if (!scope.allowed) return json({ ok: false, error: scope.error }, 403);
      role = scope.role;
      restrictedStoreIds = scope.restrictedStoreIds;
      if (restrictedStoreIds && restrictedStoreIds.length === 0) {
        return json({ ok: true, kind, from, to, rows: [], scope: { role, restrictedStoreIds } });
      }
    }

    const table = kind === "pl" ? "kd_pl_monthly_summary" : kind === "media" ? "kd_media_monthly_summary" : "kd_deposit_monthly_summary";
    const columns = kind === "pl" ? PL_COLUMNS : kind === "media" ? MEDIA_COLUMNS : DEPOSIT_COLUMNS;

    let q = sb.from(table).select(columns).gte("year_month", from).lte("year_month", to)
      .order("year_month", { ascending: false }).limit(limit);
    if (restrictedStoreIds) {
      // TENCHO（店長）は自店舗のみ。kd_pl_monthly_summaryの全社共通経費行(store_id is null)は
      // plAgg()の挙動（単一店舗表示では共通経費を含めない）と同じく店長には見せない。
      q = q.in("store_id", restrictedStoreIds);
    }
    if (body.store_id && typeof body.store_id === "string") q = q.eq("store_id", body.store_id);
    if (kind === "media" && typeof body.media_name === "string" && body.media_name) q = q.eq("media_name", body.media_name);

    const { data, error } = await q;
    if (error) return json({ ok: false, error: `${kind}サマリの取得に失敗しました: ${error.message}` }, 500);

    return json({ ok: true, kind, from, to, rows: data ?? [], scope: { role, restrictedStoreIds } });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
