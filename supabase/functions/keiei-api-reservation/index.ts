// P-2a: 予約読み取りAPI（脱GAS Phase 2 先行第1号・レーンP専任・2026-09-02新設）
// docs/実装指示書_脱GAS移行_Phase0-1_2026-09-02.md §1 P側 / 設計書_予約データ基盤_食べログノート_2026-08-27.md §9
//
// 目的: 予約帳・予約分析タブの読み取りを「ブラウザ→GAS→BigQuery」の2ホップから
//   「ブラウザ→Supabase直読み」へ差し替える。予約の正本はもともとSupabase(rsv_reservations)に
//   あるため、GAS・BQを表示経路から完全に外す（BQミラーは分析専用として引き続き残る）。
//
// 【権限チェック】経営D(dash-sync)と同じ判定基準を使う: hub Supabaseのusers.role∈{CEO,HQ,TEAM,TENCHO}
//   または is_master。TENCHOは自店舗のみ（user_storesで判定。smaregi-shift-sync callerAllowed()と同じ
//   パターン）。認証はSupabase AuthのJWT（Authorization: Bearer <access_token>）。
//   【重要・A差し替え時の注意】tori-dashboardは独自のGASセッション(login/supalogin)を持つが、
//   supalogin採用済みの統合アカウントであれば、app.js側に既にある portalAccessToken()
//   （app.js:1831〜。ポータルSupabaseログインのaccess_token取得・失効時リフレッシュ込み）を
//   そのままAuthorizationヘッダーに使える＝GAS/app.jsを一切変更せずに繋げる想定。
//   まだ統合アカウント化していないダッシュボード専用アカウント（GAS独自ID/PW）はこのAPIを直接
//   呼べない。予約タブ差し替え時にA側で対象アカウントの統合ログイン移行が必要な場合はWORKLOGで
//   相談してください（このAPI自体はGAS非依存の設計を優先し、旧セッション方式には合わせていません）。
//
// 【一時的な絞り込み】GAS側bqGetReservation()と同じ「サブブランド重複除外」を踏襲（設計書§8.8 R1
//   「初回突合必須」がまだ未実施のため）。新旧の数字を突合してから外す想定＝includeSubBrand=trueで
//   一時的に含める切替も用意。EXCLUDE_ACCOUNTSの値はGAS側と必ず同期させること（tori-dashboard/
//   gas/Code.gs bqGetReservation()参照。ここを変えるときはA側にも同じ変更を依頼する）。
//
// 呼び出し方: POST
//   { from: 'YYYY-MM-DD', to: 'YYYY-MM-DD',
//     store_id?: string(uuid), store?: string(表示名。store_idが無い時のみ使う),
//     includeCancelled?: boolean(既定false), includeSubBrand?: boolean(既定false),
//     mode?: 'list' | 'cancel_summary' | 'both'(既定) }
// 返り値: { ok:true, rows?, cancelSummary?, scope:{ role, restrictedStoreIds? } }
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

// GAS bqGetReservation()と同じ一時的サブブランド除外（設計書§8.8 R1・初回突合が済むまでの措置）。
// 変更する場合はtori-dashboard/gas/Code.gs側の同名リストとA担当を通じて必ず同期させること。
const EXCLUDE_ACCOUNTS_TEMP = ["鶏武者 川崎店", "鶏武者 新横浜", "黒霧屋 新横浜"];

const CANCELLED_PREFIX = "cancelled";
const RESERVATION_COLS = [
  "reservation_key", "store_id", "source", "store_account", "source_month",
  "visit_date", "visit_time", "stay_duration_min", "party_size", "child_count",
  "status_raw", "status_normalized", "channel_raw", "channel_normalized",
  "table_no", "course", "menu", "attribute", "tag", "memo",
  "customer_no", "customer_name", "customer_name_kana",
  "created_at_source", "cancel_at", "cancel_detected_at",
];

function isDateStr(s: unknown): s is string {
  return typeof s === "string" && /^\d{4}-\d{2}-\d{2}$/.test(s);
}

async function resolveScope(sb: ReturnType<typeof createClient>, uid: string) {
  const { data: u } = await sb.from("users").select("id,role,is_master,is_active").eq("id", uid).maybeSingle();
  if (!u || !u.is_active) return { allowed: false as const, error: "ログインが必要です（アカウントが無効です）" };
  if (u.is_master || ["CEO", "HQ", "TEAM"].includes(u.role)) {
    return { allowed: true as const, role: u.role, restrictedStoreIds: null as string[] | null };
  }
  if (u.role === "TENCHO") {
    const { data: us } = await sb.from("user_stores").select("store_id").eq("user_id", uid);
    const ids = (us ?? []).map((r: any) => r.store_id);
    return { allowed: true as const, role: u.role, restrictedStoreIds: ids };
  }
  return { allowed: false as const, error: "権限がありません（社長・本部・チーム長・店長のみ。経営Dと同じ判定）" };
}

function daysBetween(fromIso: string | null, toIso: string | null): number | null {
  if (!fromIso || !toIso) return null;
  const a = new Date(fromIso).getTime(), b = new Date(toIso).getTime();
  if (!Number.isFinite(a) || !Number.isFinite(b)) return null;
  return Math.max(0, (b - a) / 86400000);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const sb = svc();
    let body: any = {};
    try { body = await req.json(); } catch { /* ボディなしは400にする（GET未対応） */ }

    // ---------------- 権限チェック（service_role直呼びは内部ツール/バッチ用に許可。他の関数と同じ方針） ----------------
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
        return json({ ok: true, rows: [], cancelSummary: [], scope: { role, restrictedStoreIds } }); // 担当店舗未設定
      }
    }

    // ---------------- パラメータ ----------------
    const from = body.from, to = body.to;
    if (!isDateStr(from) || !isDateStr(to)) return json({ ok: false, error: "from/toはYYYY-MM-DD形式で必須です" }, 400);
    const includeCancelled = body.includeCancelled === true;
    const includeSubBrand = body.includeSubBrand === true;
    const mode = ["list", "cancel_summary", "both"].includes(body.mode) ? body.mode : "both";

    // store指定の解決（store_id優先。無ければstore=表示名をstoresから引く）
    let storeId: string | null = typeof body.store_id === "string" && body.store_id ? body.store_id : null;
    if (!storeId && typeof body.store === "string" && body.store.trim()) {
      const name = body.store.trim();
      const { data: s } = await sb.from("stores").select("id,name,dash_store_name")
        .or(`name.eq.${name},dash_store_name.eq.${name}`).maybeSingle();
      if (!s) return json({ ok: false, error: `店舗が見つかりません: ${name}` }, 400);
      storeId = s.id;
    }
    if (storeId && restrictedStoreIds && !restrictedStoreIds.includes(storeId)) {
      return json({ ok: false, error: "この店舗の予約を閲覧する権限がありません" }, 403);
    }
    // 有効な店舗スコープ（絞り込み用）: 個別指定があればそれ1件、無ければTENCHOの担当店舗すべて
    const scopeStoreIds = storeId ? [storeId] : restrictedStoreIds;

    // 店舗名解決用マップ（表示名はdash_store_name優先。labor-allocation-compare/dash-syncと同じ考え方）
    const { data: storeRows } = await sb.from("stores").select("id,name,dash_store_name");
    const storeNameOf = new Map<string, string>();
    (storeRows ?? []).forEach((s: any) => storeNameOf.set(s.id, (s.dash_store_name || s.name || s.id)));

    function applyCommonFilters(q: any, forSummary: boolean) {
      q = q.gte("visit_date", from).lte("visit_date", to);
      if (scopeStoreIds) q = q.in("store_id", scopeStoreIds);
      if (!includeSubBrand) q = q.not("store_account", "in", `(${EXCLUDE_ACCOUNTS_TEMP.map((n) => `"${n}"`).join(",")})`);
      if (!forSummary && !includeCancelled) q = q.not("status_normalized", "ilike", `${CANCELLED_PREFIX}%`);
      return q;
    }

    const out: any = { ok: true, scope: { role, restrictedStoreIds, storeId } };

    if (mode === "list" || mode === "both") {
      let q = sb.from("rsv_reservations").select(RESERVATION_COLS.join(","));
      q = applyCommonFilters(q, false);
      q = q.order("visit_date", { ascending: true }).order("visit_time", { ascending: true });
      const { data, error } = await q;
      if (error) return json({ ok: false, error: "予約データの取得に失敗しました: " + error.message }, 500);
      out.rows = (data ?? []).map((r: any) => ({
        ...r,
        store_name: storeNameOf.get(r.store_id) || r.store_id,
        // ダイニー台帳(source='dinii')以外は元データに氏名列が無いため常にnull（設計書§8.4・§8.7・§8.8 R3）
        customer_name: r.source === "dinii" ? (r.customer_name || "") : null,
        customer_name_kana: r.source === "dinii" ? (r.customer_name_kana || "") : null,
      }));
    }

    if (mode === "cancel_summary" || mode === "both") {
      // キャンセル分析は常に全ステータス（キャンセル含む）を対象にする（設計書§8.6）
      let q = sb.from("rsv_reservations").select(
        "store_id,source_month,channel_raw,status_normalized,party_size,created_at_source,cancel_at,cancel_detected_at",
      );
      q = applyCommonFilters(q, true);
      const { data, error } = await q;
      if (error) return json({ ok: false, error: "キャンセル分析データの取得に失敗しました: " + error.message }, 500);

      type Agg = {
        store_id: string; store_name: string; ym: string; channel: string;
        total: number; totalParty: number;
        cancelled_user: number; cancelled_other: number; cancelled_store: number; cancelled_noshow: number;
        cancelDaySum: number; cancelDayCount: number;
      };
      const byKey = new Map<string, Agg>();
      for (const r of (data ?? []) as any[]) {
        const ym = String(r.source_month || "").slice(0, 7); // 'YYYY-MM-01' -> 'YYYY-MM'
        const key = `${r.store_id}|${ym}|${r.channel_raw || ""}`;
        const a = byKey.get(key) ?? {
          store_id: r.store_id, store_name: storeNameOf.get(r.store_id) || r.store_id, ym, channel: r.channel_raw || "",
          total: 0, totalParty: 0, cancelled_user: 0, cancelled_other: 0, cancelled_store: 0, cancelled_noshow: 0,
          cancelDaySum: 0, cancelDayCount: 0,
        };
        a.total++;
        a.totalParty += Number(r.party_size) || 0;
        const status = String(r.status_normalized || "");
        if (status === "cancelled_user") a.cancelled_user++;
        else if (status === "cancelled_other") a.cancelled_other++;
        else if (status === "cancelled_store") a.cancelled_store++;
        else if (status === "cancelled_noshow") a.cancelled_noshow++;
        if (status.startsWith(CANCELLED_PREFIX)) {
          // 正確な値(cancel_at)があればそれを優先、無ければ日次検知(cancel_detected_at)を使う（設計書§8.3-4・§8.7）
          const cancelAt = r.cancel_at || r.cancel_detected_at;
          const days = daysBetween(r.created_at_source, cancelAt);
          if (days != null) { a.cancelDaySum += days; a.cancelDayCount++; }
        }
        byKey.set(key, a);
      }
      out.cancelSummary = [...byKey.values()].map((a) => {
        const cancelledTotal = a.cancelled_user + a.cancelled_other + a.cancelled_store + a.cancelled_noshow;
        return {
          store_id: a.store_id, store_name: a.store_name, ym: a.ym, channel: a.channel,
          totalReservations: a.total, totalParty: a.totalParty,
          cancelledUser: a.cancelled_user, cancelledOther: a.cancelled_other,
          cancelledStore: a.cancelled_store, cancelledNoshow: a.cancelled_noshow,
          cancelRate: a.total ? cancelledTotal / a.total : 0,
          noshowRate: a.total ? a.cancelled_noshow / a.total : 0,
          avgDaysToCancel: a.cancelDayCount ? a.cancelDaySum / a.cancelDayCount : null,
        };
      }).sort((a, b) => a.ym.localeCompare(b.ym) || a.store_name.localeCompare(b.store_name));
    }

    return json(out);
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
