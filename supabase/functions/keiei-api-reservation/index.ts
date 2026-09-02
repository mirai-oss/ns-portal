// P-2a→W2②: 予約読み取りAPI（脱GAS Phase 2 先行第1号・レーンP専任）
// docs/実装指示書_脱GAS移行_Phase0-1_2026-09-02.md §1 P側
// docs/設計書_表示集計層kdと高速化実行計画_2026-09-02.md §3/§6/§10.1（W2②・本書が現在の正本）
// docs/設計書_予約データ基盤_食べログノート_2026-08-27.md §9
//
// 【2026-09-02 W2で3分割に書き換え（P-2aの`mode:'both'`は廃止）】軽量化ルール（§6）に従い、
// 「一覧」は期間・limitを必須にして全件返しを禁止。「キャンセル集計」「月次サマリ」は毎回
// rsv_reservationsの明細を全件スキャンする代わりに、事前集計テーブル`kd_reservation_daily_summary`
// （keiei-kd-refresh op=reservation_dailyが日次で作る）を読むことでSupabase側の負荷も下げた。
// A側はまだこのAPIに接続していないため、破壊的変更（mode必須化・both廃止）を行って問題ない
// （WORKLOGで宣言済みの旧仕様はまだ誰も使っていない）。
//
// 【権限チェック】経営D(dash-sync)と同じ判定基準: hub Supabaseのusers.role∈{CEO,HQ,TEAM}または
//   is_master。TENCHOは自店舗のみ（user_storesで判定。smaregi-shift-sync callerAllowed()と同じ
//   パターン）。認証はSupabase AuthのJWT（app.js側は既存のportalAccessToken()を流用できる想定。
//   詳細はWORKLOG「P-2a」エントリ参照）。
//
// 呼び出し方: POST { mode: 'list'|'cancel_summary'|'monthly_summary', ... }（mode必須）
//   ①list: { mode:'list', from, to, limit(必須・最大1000), offset?, store_id?, store?, includeCancelled?, includeSubBrand? }
//      → rsv_reservationsの明細行を1件ずつ返す（予約帳UI用）。期間・limitを必ず指定すること
//   ②cancel_summary: { mode:'cancel_summary', from, to, store_id?, store?, includeSubBrand? }
//      → kd_reservation_daily_summaryのcancel_breakdown/channel_breakdownを店舗×期間で合算して返す
//   ③monthly_summary: { mode:'monthly_summary', year_month:'YYYY-MM', store_id?, store?, includeSubBrand? }
//      → kd_reservation_daily_summaryのその月ぶんを店舗ごとに合算して返す（予約件数・当日率等）
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
const LIST_MAX_LIMIT = 1000;
const LIST_DEFAULT_LIMIT = 200;

function isDateStr(s: unknown): s is string {
  return typeof s === "string" && /^\d{4}-\d{2}-\d{2}$/.test(s);
}
function isYearMonth(s: unknown): s is string {
  return typeof s === "string" && /^\d{4}-\d{2}$/.test(s);
}

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

async function resolveStoreId(sb: ReturnType<typeof createClient>, body: any): Promise<{ storeId: string | null } | { error: string }> {
  if (typeof body.store_id === "string" && body.store_id) return { storeId: body.store_id };
  if (typeof body.store === "string" && body.store.trim()) {
    const name = body.store.trim();
    const { data: s } = await sb.from("stores").select("id").or(`name.eq.${name},dash_store_name.eq.${name}`).maybeSingle();
    if (!s) return { error: `店舗が見つかりません: ${name}` };
    return { storeId: s.id };
  }
  return { storeId: null };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const sb = svc();
    let body: any = {};
    try { body = await req.json(); } catch { return json({ ok: false, error: "リクエストボディが不正です" }, 400); }

    // ---------------- 権限チェック（service_role直呼びは内部ツール/バッチ用に許可） ----------------
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
    }

    const mode = body.mode;
    if (!["list", "cancel_summary", "monthly_summary"].includes(mode)) {
      return json({ ok: false, error: "modeは'list'|'cancel_summary'|'monthly_summary'のいずれかが必須です" }, 400);
    }

    const storeResolved = await resolveStoreId(sb, body);
    if ("error" in storeResolved) return json({ ok: false, error: storeResolved.error }, 400);
    const storeId = storeResolved.storeId;
    if (storeId && restrictedStoreIds && !restrictedStoreIds.includes(storeId)) {
      return json({ ok: false, error: "この店舗の予約を閲覧する権限がありません" }, 403);
    }
    if (!storeId && restrictedStoreIds && restrictedStoreIds.length === 0) {
      return json({ ok: true, mode, rows: [], scope: { role, restrictedStoreIds } });
    }
    const scopeStoreIds = storeId ? [storeId] : restrictedStoreIds;
    const includeSubBrand = body.includeSubBrand === true;

    // ---------------- ①list: rsv_reservations明細（期間・limit必須） ----------------
    if (mode === "list") {
      if (!isDateStr(body.from) || !isDateStr(body.to)) {
        return json({ ok: false, error: "from/toはYYYY-MM-DD形式で必須です（軽量化ルール: 全件返し禁止）" }, 400);
      }
      const limitNum = Number(body.limit);
      if (!Number.isFinite(limitNum) || limitNum <= 0) {
        return json({ ok: false, error: "limitは1以上の数値で必須です（軽量化ルール: 全件返し禁止）" }, 400);
      }
      const limit = Math.min(LIST_MAX_LIMIT, Math.floor(limitNum) || LIST_DEFAULT_LIMIT);
      const offset = Math.max(0, Math.floor(Number(body.offset)) || 0);
      const includeCancelled = body.includeCancelled === true;

      const cols = [
        "reservation_key", "store_id", "source", "store_account", "visit_date", "visit_time",
        "stay_duration_min", "party_size", "child_count", "status_raw", "status_normalized",
        "channel_raw", "channel_normalized", "table_no", "course", "menu", "attribute", "tag",
        "customer_no", "customer_name", "customer_name_kana", "created_at_source", "cancel_at",
      ];
      let q = sb.from("rsv_reservations").select(cols.join(","), { count: "exact" })
        .gte("visit_date", body.from).lte("visit_date", body.to);
      if (scopeStoreIds) q = q.in("store_id", scopeStoreIds);
      if (!includeSubBrand) q = q.not("store_account", "in", `(${EXCLUDE_ACCOUNTS_TEMP.map((n) => `"${n}"`).join(",")})`);
      if (!includeCancelled) q = q.not("status_normalized", "ilike", "cancelled%");
      q = q.order("visit_date", { ascending: true }).order("visit_time", { ascending: true }).range(offset, offset + limit - 1);

      const { data, error, count } = await q;
      if (error) return json({ ok: false, error: "予約データの取得に失敗しました: " + error.message }, 500);
      const { data: storeRows } = await sb.from("stores").select("id,name,dash_store_name");
      const storeNameOf = new Map<string, string>();
      (storeRows ?? []).forEach((s: any) => storeNameOf.set(s.id, s.dash_store_name || s.name || s.id));
      const rows = (data ?? []).map((r: any) => ({
        ...r,
        store_name: storeNameOf.get(r.store_id) || r.store_id,
        customer_name: r.source === "dinii" ? (r.customer_name || "") : null,
        customer_name_kana: r.source === "dinii" ? (r.customer_name_kana || "") : null,
      }));
      return json({ ok: true, mode, rows, limit, offset, totalCount: count ?? null, scope: { role, restrictedStoreIds } });
    }

    // ---------------- ②cancel_summary: kd_reservation_daily_summaryの合算（期間必須） ----------------
    if (mode === "cancel_summary") {
      if (!isDateStr(body.from) || !isDateStr(body.to)) {
        return json({ ok: false, error: "from/toはYYYY-MM-DD形式で必須です" }, 400);
      }
      let q = sb.from("kd_reservation_daily_summary")
        .select("store_id,period_date,reservation_count,cancel_breakdown,channel_breakdown")
        .gte("period_date", body.from).lte("period_date", body.to);
      if (scopeStoreIds) q = q.in("store_id", scopeStoreIds);
      const { data, error } = await q;
      if (error) return json({ ok: false, error: "キャンセル集計の取得に失敗しました: " + error.message }, 500);

      const { data: storeRows } = await sb.from("stores").select("id,name,dash_store_name");
      const storeNameOf = new Map<string, string>();
      (storeRows ?? []).forEach((s: any) => storeNameOf.set(s.id, s.dash_store_name || s.name || s.id));

      type Agg = { store_id: string; store_name: string; totalReservations: number; cancel: Record<string, { count: number; party: number }>; channel: Record<string, { count: number; party: number }> };
      const byStore = new Map<string, Agg>();
      for (const r of (data ?? []) as any[]) {
        const a = byStore.get(r.store_id) ?? {
          store_id: r.store_id, store_name: storeNameOf.get(r.store_id) || r.store_id,
          totalReservations: 0, cancel: {}, channel: {},
        };
        a.totalReservations += Number(r.reservation_count) || 0;
        for (const [k, v] of Object.entries((r.cancel_breakdown ?? {}) as Record<string, any>)) {
          const cur = a.cancel[k] ?? { count: 0, party: 0 };
          cur.count += Number(v?.count) || 0; cur.party += Number(v?.party) || 0;
          a.cancel[k] = cur;
        }
        for (const [k, v] of Object.entries((r.channel_breakdown ?? {}) as Record<string, any>)) {
          const cur = a.channel[k] ?? { count: 0, party: 0 };
          cur.count += Number(v?.count) || 0; cur.party += Number(v?.party) || 0;
          a.channel[k] = cur;
        }
        byStore.set(r.store_id, a);
      }
      const rows = [...byStore.values()].map((a) => {
        const cancelTotal = Object.values(a.cancel).reduce((s, v) => s + v.count, 0);
        const denom = a.totalReservations + cancelTotal; // 母数=非キャンセル+キャンセル
        return {
          store_id: a.store_id, store_name: a.store_name,
          totalReservations: a.totalReservations,
          cancelBreakdown: a.cancel, channelBreakdown: a.channel,
          cancelCount: cancelTotal,
          cancelRate: denom ? cancelTotal / denom : 0,
          noshowRate: denom ? (a.cancel["noshow"]?.count ?? 0) / denom : 0,
        };
      });
      return json({ ok: true, mode, rows, scope: { role, restrictedStoreIds } });
    }

    // ---------------- ③monthly_summary: kd_reservation_daily_summaryの月合算 ----------------
    if (!isYearMonth(body.year_month)) return json({ ok: false, error: "year_monthはYYYY-MM形式で必須です" }, 400);
    const monthFrom = `${body.year_month}-01`;
    const [yy, mm] = body.year_month.split("-").map(Number);
    const lastDay = new Date(yy, mm, 0).getDate();
    const monthTo = `${body.year_month}-${String(lastDay).padStart(2, "0")}`;

    let q2 = sb.from("kd_reservation_daily_summary")
      .select("store_id,reservation_count,party_size_sum,same_day_count,same_day_party,walkin_count,walkin_party,expected_sales")
      .gte("period_date", monthFrom).lte("period_date", monthTo);
    if (scopeStoreIds) q2 = q2.in("store_id", scopeStoreIds);
    const { data: mdata, error: merr } = await q2;
    if (merr) return json({ ok: false, error: "月次サマリの取得に失敗しました: " + merr.message }, 500);

    const { data: storeRows2 } = await sb.from("stores").select("id,name,dash_store_name");
    const storeNameOf2 = new Map<string, string>();
    (storeRows2 ?? []).forEach((s: any) => storeNameOf2.set(s.id, s.dash_store_name || s.name || s.id));

    type MAgg = { store_id: string; store_name: string; reservationCount: number; partySum: number; sameDayCount: number; sameDayParty: number; walkinCount: number; walkinParty: number; expectedSales: number };
    const byStore2 = new Map<string, MAgg>();
    for (const r of (mdata ?? []) as any[]) {
      const a = byStore2.get(r.store_id) ?? {
        store_id: r.store_id, store_name: storeNameOf2.get(r.store_id) || r.store_id,
        reservationCount: 0, partySum: 0, sameDayCount: 0, sameDayParty: 0, walkinCount: 0, walkinParty: 0, expectedSales: 0,
      };
      a.reservationCount += Number(r.reservation_count) || 0;
      a.partySum += Number(r.party_size_sum) || 0;
      a.sameDayCount += Number(r.same_day_count) || 0;
      a.sameDayParty += Number(r.same_day_party) || 0;
      a.walkinCount += Number(r.walkin_count) || 0;
      a.walkinParty += Number(r.walkin_party) || 0;
      a.expectedSales += Number(r.expected_sales) || 0;
      byStore2.set(r.store_id, a);
    }
    const rows2 = [...byStore2.values()].map((a) => ({
      ...a, sameDayRate: a.reservationCount ? a.sameDayCount / a.reservationCount : 0,
    }));
    return json({ ok: true, mode, year_month: body.year_month, rows: rows2, scope: { role, restrictedStoreIds } });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
