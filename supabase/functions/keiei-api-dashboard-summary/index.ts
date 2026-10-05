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
const STORE_COLUMNS = "store_id,corporation_id,year_month,sales,cost,cost_rate,labor_pa,labor_emp,labor_other,labor_spot,labor_total,labor_rate,fl_rate,gross_profit,budget_sales,budget_diff,budget_rate,source_updated_at,computed_at,sync_run_id";
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
const DAILY_COLUMNS = "store_id,corporation_id,date,net_sales,guests_total,parties_total,parttime_labor_cost,fulltime_labor_cost,labor_cost_total,cogs,cash,employee_salary_bonus,statutory_welfare,commute_allowance,avg_check,prior_year_same_weekday_sales,prior_year_same_weekday_ratio,computed_at,sync_run_id";
const DEPOSIT_DAILY_COLUMNS = "store_id,date,cash_sales,deposit_amount,diff,deposit_count,entries";
const DEPOSIT_CARRY_COLUMNS = "store_id,year_month,month_start,cash_before,deposit_before,carry";
const AD_COLUMNS = "store_id,corporation_id,year_month,media_name,ad_cost,plan_breakdown,access_count,net_groups,net_people,tel_count,total_groups,total_people,total_sales,acquisition_fee,pl_excluded,source_updated_at,computed_at,sync_run_id";
const TARGET_V_COLUMNS = "store_id,year_month,ym,sales_target,target_days,pa_rate,emp_rate,cost_rate,dinii_target,review_target,updated_at";
const TARGET_DAILY_COLUMNS = "store_id,biz_date,sales_target";
// 2026-10-06追加（担当A依頼）: stg_* の行ミラー。GAS(bqGetMedia/bqGetPL/bqGetSpot/bqGetLoanPrincipal)なしで媒体別売上・PLを描く用
const MEDIA_DAILY_COLUMNS = "id,store_id,biz_date,media_raw,media_name,guests,parties,net_sales,computed_at";
const PL_ENTRIES_COLUMNS = "id,year_month,store_id,store_name,item,category,amount,memo,sub_item,computed_at";
const SPOT_COLUMNS = "id,spot_id,work_date,store_id,store_name,kind,amount,headcount,memo,entered_by,entered_at,computed_at";
const LOAN_COLUMNS = "id,year_month,store_id,store_name,corp_name,principal,memo,computed_at";
// periodKind: 'ym'=年月(text) / 'day'=日付(date)。dayの範囲指定は from月の1日〜to月の末日。
// tie: 並び順の最後に足す一意列（同日同店の行がページ境界で重複・欠落しないように）／commonVisible: 全社共通行(store_name='')を店長にも見せる（GASのbqGetPL/bqGetLoanPrincipalと同じ）
const KINDS: Record<string, { table: string; columns: string; periodCol: string; periodKind: "ym" | "day"; freshCol?: string; noStoreScope?: boolean; tie?: string; commonVisible?: boolean }> = {
  pl: { table: "kd_pl_monthly_summary", columns: PL_COLUMNS, periodCol: "year_month", periodKind: "ym" },
  media: { table: "kd_media_monthly_summary", columns: MEDIA_COLUMNS, periodCol: "year_month", periodKind: "ym" },
  deposit: { table: "kd_deposit_monthly_summary", columns: DEPOSIT_COLUMNS, periodCol: "year_month", periodKind: "ym" },
  store: { table: "kd_store_monthly_summary", columns: STORE_COLUMNS, periodCol: "year_month", periodKind: "ym" },
  // 2026-10-05追加（依頼_レーンP_経営D_F2用kd追加）
  daily: { table: "kd_daily_store_full", columns: DAILY_COLUMNS, periodCol: "date", periodKind: "day" },            // #1 fact_daily_store互換の日次
  deposit_daily: { table: "kd_deposit_daily_v", columns: DEPOSIT_DAILY_COLUMNS, periodCol: "date", periodKind: "day" }, // #2 店舗×日の現金売上・入金・差額
  deposit_carry: { table: "kd_deposit_carry_v", columns: DEPOSIT_CARRY_COLUMNS, periodCol: "year_month", periodKind: "ym" }, // #2 月初繰越
  ad: { table: "kd_ad_monthly", columns: AD_COLUMNS, periodCol: "year_month", periodKind: "ym" },                   // #3 店舗×媒体×月
  // #4 目標。kind:'target'は従来の列(ym含む)＋売上目標(sales_target=日別目標の月合計)。日別の元値はtarget_daily
  target: { table: "kd_target_monthly_v", columns: TARGET_V_COLUMNS, periodCol: "year_month", periodKind: "ym", freshCol: "updated_at" },
  target_daily: { table: "dash_sales_target_daily", columns: TARGET_DAILY_COLUMNS, periodCol: "biz_date", periodKind: "day" },
  // 2026-10-06 行ミラー（担当A依頼: 媒体別売上・広告管理・PLをGASなしで）
  media_daily: { table: "kd_media_daily", columns: MEDIA_DAILY_COLUMNS, periodCol: "biz_date", periodKind: "day", tie: "id" },
  pl_entries: { table: "kd_pl_entries", columns: PL_ENTRIES_COLUMNS, periodCol: "year_month", periodKind: "ym", tie: "id", commonVisible: true },
  spot: { table: "kd_spot_entries", columns: SPOT_COLUMNS, periodCol: "work_date", periodKind: "day", tie: "id" },
  loan: { table: "kd_loan_entries", columns: LOAN_COLUMNS, periodCol: "year_month", periodKind: "ym", tie: "id", commonVisible: true },
};
function addMonthFirst(ym: string): string {
  const [y, m] = ym.split("-").map(Number);
  return new Date(Date.UTC(y, m, 1)).toISOString().slice(0, 10);
}
function jstYm(offsetMonths = 0): string {
  const d = new Date(Date.now() + 9 * 3600 * 1000);
  const t = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + offsetMonths, 1));
  return t.toISOString().slice(0, 7);
}

// ---------------------------------------------------------------------
// 明細分析（2026-10-06・#5）: kind='detail'（一括）／'detail_items'／'detail_hours'／'detail_stores'／'detail_coverage'／'detail_delivery'
//   必須: from, to（YYYY-MM-DD・最大800日）。任意: store_ids[]（またはstore_id）, daypart('all'|'lunch'|'dinner'|'delivery'), basis('incl'|'excl'), limit(商品ランキング上限・既定3000・最大5000)
//   返り値(kind='detail'): { ok, from, to, daypart, items:[{item_name,category,qty,sales_incl,sales_excl,rank,share,cum_share,total_sales}], hours:[…], stores:[…],
//                           coverage:[{month,stores,days,item_rows}], delivery:{by_store:[{store_id,orders,net_sales}]}, meta:{logic_ver,computed_at}, scope }
//   - 商品別(items)はABC分析用に構成比・累計構成比まで返す。deliveryは商品なし（ランキング/ABC対象外）。daypart='delivery'ならitems/hours/storesは空。
//   - 店舗スコープは他kindと同じ判定。店舗指定が権限外なら無視（権限内の店舗に絞る）。ブラウザへ全行は返さない（集計はRPC）。
// ---------------------------------------------------------------------
const DETAIL_KINDS = ["detail", "detail_items", "detail_hours", "detail_stores", "detail_coverage", "detail_delivery"];
const isDay = (s: unknown): s is string => typeof s === "string" && /^\d{4}-\d{2}-\d{2}$/.test(s);
async function handleDetail(sb: ReturnType<typeof createClient>, body: any, role: string, restrictedStoreIds: string[] | null): Promise<Response> {
  const kind: string = body.kind;
  if (!isDay(body.from) || !isDay(body.to) || body.from > body.to) return json({ ok: false, error: "from・to（YYYY-MM-DD・from<=to）が必須です" }, 400);
  const spanDays = (Date.parse(body.to) - Date.parse(body.from)) / 86400000 + 1;
  if (spanDays > 800) return json({ ok: false, error: "期間は最大800日です" }, 400);
  const daypart: string = ["all", "lunch", "dinner", "delivery"].includes(body.daypart) ? body.daypart : "all";
  const basis: string = body.basis === "excl" ? "excl" : "incl";
  const limit = Math.min(5000, Math.max(1, Number(body.limit) || 3000));

  // 対象店舗: 権限内 ∩ 指定（指定なしは権限内すべて／権限制限なしなら有効店舗すべて）
  let stores: string[];
  const requested: string[] = Array.isArray(body.store_ids) ? body.store_ids.filter((x: unknown) => typeof x === "string")
    : (typeof body.store_id === "string" && body.store_id !== "all" ? [body.store_id] : []);
  if (restrictedStoreIds) stores = requested.length ? requested.filter((id) => restrictedStoreIds.includes(id)) : restrictedStoreIds;
  else if (requested.length) stores = requested;
  else {
    const { data } = await sb.from("stores").select("id").eq("is_active", true);
    stores = (data ?? []).map((r: any) => r.id);
  }
  const scope = { role, restrictedStoreIds };
  if (!stores.length) return json({ ok: true, kind, from: body.from, to: body.to, daypart, items: [], hours: [], stores: [], coverage: [], delivery: { by_store: [] }, meta: null, scope });

  const want = (k: string) => kind === "detail" || kind === `detail_${k}`;
  const noLunchDinner = daypart === "delivery";
  const args = { p_from: body.from, p_to: body.to, p_stores: stores, p_daypart: daypart };
  const rpc = async (fn: string, a: Record<string, unknown>) => {
    const { data, error } = await sb.rpc(fn, a);
    if (error) throw new Error(`${fn}: ${error.message}`);
    return data ?? [];
  };
  // 集合を返すRPCもPostgRESTの1リクエスト最大1000行で無言に切られる。商品別(最大5000件)は1000行ずつ取り直す
  // （並びはRPC内で売上降順＋商品名で確定しているのでページ間で重複・欠落しない）。
  const rpcPaged = async (fn: string, a: Record<string, unknown>, max: number) => {
    const out: any[] = [];
    for (let off = 0; off < max; off += 1000) {
      const end = Math.min(off + 999, max - 1);
      const { data, error } = await sb.rpc(fn, a).range(off, end);
      if (error) throw new Error(`${fn}: ${error.message}`);
      const got = (data ?? []) as any[];
      out.push(...got);
      if (got.length < end - off + 1) break;
    }
    return out;
  };
  const out: Record<string, unknown> = { ok: true, kind, from: body.from, to: body.to, daypart, basis, scope };
  const jobs: Promise<void>[] = [];
  if (want("items")) jobs.push((noLunchDinner ? Promise.resolve([]) : rpcPaged("kd_detail_items", { ...args, p_basis: basis, p_limit: limit }, limit)).then((d) => { out.items = d; }));
  if (want("hours")) jobs.push((noLunchDinner ? Promise.resolve([]) : rpc("kd_detail_hours", args)).then((d) => { out.hours = d; }));
  if (want("stores")) jobs.push((noLunchDinner ? Promise.resolve([]) : rpc("kd_detail_stores", args)).then((d) => { out.stores = d; }));
  if (want("coverage")) jobs.push(rpc("kd_detail_coverage", { p_from: body.from, p_to: body.to, p_stores: stores }).then((d) => { out.coverage = d; }));
  if (want("delivery") && (daypart === "all" || daypart === "delivery")) {
    jobs.push((async () => {
      const rows: any[] = [];
      for (let off = 0; off < 20000; off += 1000) {
        const { data, error } = await sb.from("kd_delivery_daily").select("store_id,biz_date,orders,net_sales")
          .gte("biz_date", body.from).lte("biz_date", body.to).in("store_id", stores)
          .order("biz_date").order("store_id").range(off, off + 999);
        if (error) throw new Error("kd_delivery_daily: " + error.message);
        rows.push(...(data ?? []));
        if (!data || data.length < 1000) break;
      }
      const by = new Map<string, { store_id: string; orders: number; net_sales: number }>();
      for (const r of rows) {
        const b = by.get(r.store_id) ?? { store_id: r.store_id, orders: 0, net_sales: 0 };
        b.orders += Number(r.orders) || 0; b.net_sales += Number(r.net_sales) || 0; by.set(r.store_id, b);
      }
      out.delivery = { by_store: [...by.values()].sort((a, b) => b.net_sales - a.net_sales) };
      if (body.daily === true) (out.delivery as any).daily = rows;
    })());
  } else if (kind === "detail") out.delivery = { by_store: [] };
  if (kind === "detail") {
    jobs.push((async () => {
      const { data } = await sb.from("kd_detail_item_daily").select("logic_ver,computed_at").order("computed_at", { ascending: false }).limit(1);
      out.meta = data?.[0] ?? null;
    })());
  }
  await Promise.all(jobs);
  if (kind === "detail") for (const k of ["items", "hours", "stores", "coverage"]) if (!(k in out)) out[k] = [];
  return json(out);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const sb = svc();
    let body: any = {};
    try { body = await req.json(); } catch (_) { /* ボディ必須（下のkindチェックで弾く） */ }

    if (typeof body.kind === "string" && DETAIL_KINDS.includes(body.kind)) {
      // 明細分析（期間は日付単位。年月単位の他kindとは入力が違うため別枠で認証・スコープ判定を行う）
      const ah = req.headers.get("Authorization") ?? "";
      if (ah.includes(Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? " ")) return await handleDetail(sb, body, "service_role", null);
      const uid0 = jwtUid(req);
      if (!uid0) return json({ ok: false, error: "ログインが必要です" }, 401);
      const sc0 = await resolveScope(sb, uid0);
      if (!sc0.allowed) return json({ ok: false, error: sc0.error }, 403);
      return await handleDetail(sb, body, sc0.role, sc0.restrictedStoreIds);
    }

    const kinds: string[] = Array.isArray(body.kinds) ? body.kinds : (body.kind ? [body.kind] : []);
    const multi = Array.isArray(body.kinds);
    if (!kinds.length || kinds.length > 4 || kinds.some((k) => !(k in KINDS))) {
      return json({ ok: false, error: "kind（またはkinds=最大4種）は'pl'|'media'|'deposit'|'store'|'target'|'daily'|'deposit_daily'|'deposit_carry'|'ad'|'target_daily'|'media_daily'|'pl_entries'|'spot'|'loan'のいずれかが必須です" }, 400);
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
    const limit = Math.min(5000, Math.max(1, Number(body.limit) || 500));
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

    // PostgRESTは1リクエスト最大1000行で打ち切るため、内部で1000行ずつ取り直して最大limit件まで集める
    // （limit最大5000。hasMoreは「まだ続きがあるか」を正しく返す＝呼び出し側が無言に欠落しない）。
    const fetchKind = async (kind: string) => {
      const def = KINDS[kind];
      const lo = def.periodKind === "day" ? `${from}-01` : from;
      const hiExclusive = def.periodKind === "day" ? addMonthFirst(to!) : null;   // dayは翌月1日未満
      const wantMax = limit + 1;
      const rows: any[] = [];
      for (let off = offset; rows.length < wantMax; off += 1000) {
        const pageEnd = off + Math.min(1000, wantMax - rows.length) - 1;
        let q = sb.from(def.table).select(def.columns).gte(def.periodCol, lo);
        q = def.periodKind === "day" ? q.lt(def.periodCol, hiExclusive!) : q.lte(def.periodCol, to!);
        q = q.order(def.periodCol, { ascending: false }).order("store_id", { ascending: true });
        if (def.tie) q = q.order(def.tie, { ascending: true });
        q = q.range(off, pageEnd);
        if (restrictedStoreIds) {
          // TENCHO（店長）は自店舗のみ。kd_pl_monthly_summaryの全社共通経費行(store_id is null)は
          // plAgg()の挙動（単一店舗表示では共通経費を含めない）と同じく店長には見せない。
          q = def.commonVisible
            ? q.or(`store_id.in.(${restrictedStoreIds.join(",")}),store_name.eq.`)
            : q.in("store_id", restrictedStoreIds);
        }
        if (body.store_id && typeof body.store_id === "string") q = q.eq("store_id", body.store_id);
        if (kind === "media" && typeof body.media_name === "string" && body.media_name) q = q.eq("media_name", body.media_name);
        if (kind === "ad" && typeof body.media_name === "string" && body.media_name) q = q.eq("media_name", body.media_name);
        const { data, error } = await q;
        if (error) throw new Error(`${kind}サマリの取得に失敗しました: ${error.message}`);
        const got = (data ?? []) as any[];
        rows.push(...got);
        if (got.length < Math.min(1000, pageEnd - off + 1)) break;   // 最後のページ
      }
      const out = rows.slice(0, limit);
      const fc = def.freshCol ?? "computed_at";
      const fresh = out.reduce((m: string | null, r: any) => (r[fc] && (!m || r[fc] > m)) ? r[fc] : m, null);
      return { kind, rows: out, hasMore: rows.length > limit, nextOffset: rows.length > limit ? offset + limit : null, fresh };
    };

    if (!multi) {
      const r = await fetchKind(kinds[0]);
      return json({ ok: true, kind: r.kind, from, to, rows: r.rows, hasMore: r.hasMore, nextOffset: r.nextOffset, fresh: r.fresh, scope: { role, restrictedStoreIds } });
    }
    const results: Record<string, unknown> = {};
    for (const r of await Promise.all(kinds.map(fetchKind))) results[r.kind] = r;
    return json({ ok: true, from, to, results, scope: { role, restrictedStoreIds } });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
