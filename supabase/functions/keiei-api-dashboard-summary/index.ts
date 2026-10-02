// W3②: PL/売上分析(媒体別)/入金のkd_月次サマリを返す軽量読み取りAPI（レーンP・2026-09-06新設）
// docs/設計書_表示集計層kdと高速化実行計画_2026-09-02.md §3/§6/§10.2-1
//
// 目的: PL・媒体別売上分析・入金確認の各画面が、GAS(bqGetPL/bqGetMedia/bqGetDeposit)を待たずに
// Supabaseの集計済みテーブル（kd_pl_monthly_summary/kd_media_monthly_summary/kd_deposit_monthly_summary）
// を直接読めるようにする。明細行(stg_pl等)は返さない・kind/期間/limitを必須にする（§6の軽量化規約）。
// 書き込みはkeiei-kd-refresh（別Function・service_role限定）のみ。本Functionは読み取り専用。
//
// 呼び出し: POST { kind: 'pl'|'media'|'deposit'|'store'|'target'（2026-10-03追加: 'store'/'target'／months／kinds[]／offset／fresh。下記拡張コメント参照）, year_month?: 'YYYY-MM', from?: 'YYYY-MM', to?: 'YYYY-MM',
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
const STORE_COLUMNS = "store_id,corporation_id,year_month,sales,cost,cost_rate,labor_pa,labor_emp,labor_spot,labor_total,labor_rate,fl_rate,gross_profit,budget_sales,budget_diff,budget_rate,source_updated_at,computed_at,sync_run_id";
// 目標（dash_target_monthly＝dash-syncが日次でDB_目標月次から同期済み。売上目標の月合計はstore側のbudget_sales）
const TARGET_COLUMNS = "store_id,ym,pa_rate,emp_rate,cost_rate,dinii_target,review_target,updated_at";
const DEPOSIT_COLUMNS = "store_id,corporation_id,year_month,deposit_total,deposit_count,sales_total,diff,source_breakdown,source_updated_at,computed_at,sync_run_id";

// 2026-10-03拡張（ラウンド6§7 P③・R7「kd_月次24か月一括取得」）。既存の呼び方（kind＋year_month|from/to＋
// limit/store_id/media_name）の返り値は一切変えない。追加分は全て任意:
//   - kind に 'store'（kd_store_monthly_summary=F率/L率/FL・予算比）と 'target'（dash_target_monthly）を追加
//   - months:N（1〜36）… from/toの代わりに「当月から遡ってNか月」をサーバー側で計算（JST基準）
//   - kinds:[...]（最大4種）… 同じ期間で複数種を1往復で取得 → { results:{<kind>:{rows,hasMore,fresh}}, ... }
//   - offset … ページング（limit最大2000）。hasMoreがtrueなら次のoffsetで続きを取る
//   - fresh … その種別の computed_at 最大値（SWR用: 前回値と同じなら再描画不要の目印）
const KINDS: Record<string, { table: string; columns: string; periodCol: string; isDate?: boolean; freshCol?: string }> = {
  pl: { table: "kd_pl_monthly_summary", columns: PL_COLUMNS, periodCol: "year_month" },
  media: { table: "kd_media_monthly_summary", columns: MEDIA_COLUMNS, periodCol: "year_month" },
  deposit: { table: "kd_deposit_monthly_summary", columns: DEPOSIT_COLUMNS, periodCol: "year_month" },
  store: { table: "kd_store_monthly_summary", columns: STORE_COLUMNS, periodCol: "year_month" },
  // dash_target_monthly.ymはdate型（月初日）。範囲指定は月初日に直し、返り値にはyear_month(YYYY-MM)を足して他の種別と揃える
  target: { table: "dash_target_monthly", columns: TARGET_COLUMNS, periodCol: "ym", isDate: true, freshCol: "updated_at" },
};
function jstYm(offsetMonths = 0): string {
  const d = new Date(Date.now() + 9 * 3600 * 1000);
  const t = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + offsetMonths, 1));
  return t.toISOString().slice(0, 7);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const sb = svc();
    let body: any = {};
    try { body = await req.json(); } catch (_) { /* ボディ必須（下のkindチェックで弾く） */ }

    const kinds: string[] = Array.isArray(body.kinds) ? body.kinds : (body.kind ? [body.kind] : []);
    const multi = Array.isArray(body.kinds);
    if (!kinds.length || kinds.length > 4 || kinds.some((k) => !(k in KINDS))) {
      return json({ ok: false, error: "kind（またはkinds=最大4種）は'pl'|'media'|'deposit'|'store'|'target'のいずれかが必須です" }, 400);
    }
    let from: string | null, to: string | null;
    const monthsN = Number(body.months);
    if (Number.isFinite(monthsN) && monthsN >= 1) {
      const n = Math.min(36, Math.floor(monthsN));
      from = jstYm(-(n - 1)); to = jstYm(0);
    } else {
      from = isYm(body.year_month) ? body.year_month : (isYm(body.from) ? body.from : null);
      to = isYm(body.year_month) ? body.year_month : (isYm(body.to) ? body.to : null);
    }
    if (!from || !to) {
      return json({ ok: false, error: "year_month、from+to、またはmonths（YYYY-MM形式／1〜36）の期間指定が必須です（明細の全件返しを防ぐため）" }, 400);
    }
    const limit = Math.min(2000, Math.max(1, Number(body.limit) || 500));
    const offset = Math.max(0, Math.floor(Number(body.offset) || 0));

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
        const empty = (k: string) => ({ rows: [], hasMore: false, fresh: null, kind: k });
        return multi
          ? json({ ok: true, from, to, results: Object.fromEntries(kinds.map((k) => [k, empty(k)])), scope: { role, restrictedStoreIds } })
          : json({ ok: true, kind: kinds[0], from, to, rows: [], scope: { role, restrictedStoreIds } });
      }
    }

    const fetchKind = async (kind: string) => {
      const def = KINDS[kind];
      // limit+1件取って「まだ続きがあるか」を判定する（余分な1件は返さない）
      let q = sb.from(def.table).select(def.columns).gte(def.periodCol, def.isDate ? `${from}-01` : from).lte(def.periodCol, def.isDate ? `${to}-01` : to)
        .order(def.periodCol, { ascending: false }).range(offset, offset + limit);
      if (restrictedStoreIds) {
        // TENCHO（店長）は自店舗のみ。kd_pl_monthly_summaryの全社共通経費行(store_id is null)は
        // plAgg()の挙動（単一店舗表示では共通経費を含めない）と同じく店長には見せない。
        q = q.in("store_id", restrictedStoreIds);
      }
      if (body.store_id && typeof body.store_id === "string") q = q.eq("store_id", body.store_id);
      if (kind === "media" && typeof body.media_name === "string" && body.media_name) q = q.eq("media_name", body.media_name);
      const { data, error } = await q;
      if (error) throw new Error(`${kind}サマリの取得に失敗しました: ${error.message}`);
      const all = (data ?? []) as any[];
      const rows = all.slice(0, limit);
      if (def.isDate) for (const r of rows) r.year_month = String(r.ym).slice(0, 7);
      const fc = def.freshCol ?? "computed_at";
      const fresh = rows.reduce((m: string | null, r: any) => (r[fc] && (!m || r[fc] > m)) ? r[fc] : m, null);
      return { kind, rows, hasMore: all.length > limit, fresh };
    };

    if (!multi) {
      const r = await fetchKind(kinds[0]);
      return json({ ok: true, kind: r.kind, from, to, rows: r.rows, hasMore: r.hasMore, fresh: r.fresh, scope: { role, restrictedStoreIds } });
    }
    const results: Record<string, unknown> = {};
    for (const r of await Promise.all(kinds.map(fetchKind))) results[r.kind] = r;
    return json({ ok: true, from, to, results, scope: { role, restrictedStoreIds } });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
