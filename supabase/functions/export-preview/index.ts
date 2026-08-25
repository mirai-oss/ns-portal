// 担当G: データ出力センター Export Service — プレビュー
// 実装指示書_担当G_データ出力センター_2026-08-25.md §8「出力前に簡易プレビュー」
//
// 目的: 実際のファイル生成をせず、対象店舗数・対象データ件数・売上高合計等を返す
//   （誤った法人・店舗・期間での大量出力事故を防ぐ）。
//
// データ取得方式（調査レポート§6の推奨方針）: BigQueryへ新規サービスアカウントを作らず、
//   既存tori-dashboard GAS WebAppのbqGetPLアクションをHTTP fetchで呼ぶ
//   （labor-allocation-compare/index.tsと同じ方式・dash_id/dash_pwはapp_secrets共有）。
//
// 権限: RLSではなくアプリ層でチェック（BigQueryにはRLSが掛からないため。調査レポート§8-2）。
//   export_allowed_store_ids()で「このユーザーが見てよい店舗ID」を確定させてから、
//   GASブリッジの返却行（全店舗分）をこちら側でフィルタする。GASセッション自体は
//   共有アカウント(dash_id)のものなので、GAS側の店舗制限は信用しない。
import { createClient } from "npm:@supabase/supabase-js@2";

const DASH_API_URL = "https://script.google.com/macros/s/AKfycbz9rd37EZa6X8WRMVEBrXobN8DbYWkHRlhFNYU5rd1UZ0V8j0-6shMQjEeoi4HDWZ0B/exec";

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

async function dashCall(body: unknown) {
  const res = await fetch(DASH_API_URL, {
    method: "POST",
    headers: { "Content-Type": "text/plain;charset=utf-8" },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  try { return JSON.parse(text); }
  catch (_) { return { ok: false, error: "ダッシュボードの応答を読めませんでした: " + text.slice(0, 200) }; }
}

// deno-lint-ignore no-explicit-any
async function dashLogin(sb: any): Promise<{ ok: boolean; token?: string; error?: string }> {
  const { data: sec } = await sb.from("app_secrets").select("key,value").in("key", ["dash_id", "dash_pw"]);
  const secMap: Record<string, string> = {};
  (sec ?? []).forEach((r: any) => { secMap[r.key] = (r.value ?? "").trim(); });
  if (!secMap.dash_id || !secMap.dash_pw) return { ok: false, error: "app_secretsにdash_id/dash_pwが未設定です" };
  const login = await dashCall({ action: "login", id: secMap.dash_id, pw: secMap.dash_pw });
  if (!login.ok) return { ok: false, error: "ダッシュボードへのログインに失敗: " + (login.error ?? "") };
  return { ok: true, token: login.token };
}

// 'YYYY-MM-DD...' や 'YYYY/MM/DD' 等ゆるい表記から 'YYYY-MM' を取り出す
function normalizeYm(v: unknown): string | null {
  const m = String(v ?? "").trim().match(/(\d{4})[-\/](\d{2})/);
  return m ? `${m[1]}-${m[2]}` : null;
}

type PlRow = { ym: string; storeName: string; item: string; category: string; amount: number; memo: string; subItem: string };

async function fetchPlRows(token: string): Promise<PlRow[]> {
  const res = await dashCall({ action: "bqGetPL", token });
  if (!res.ok) throw new Error("bqGetPL取得に失敗: " + (res.error ?? ""));
  const rows: any[] = (res.sheets?.PL ?? []).slice(1); // ヘッダー行を除く
  const out: PlRow[] = [];
  for (const r of rows) {
    const ym = normalizeYm(r[0]);
    if (!ym) continue;
    out.push({
      ym,
      storeName: String(r[1] ?? "").trim(),
      item: String(r[2] ?? "").trim(),
      category: String(r[3] ?? "").trim(),
      amount: Number(r[4] ?? 0),
      memo: String(r[5] ?? ""),
      subItem: String(r[6] ?? ""),
    });
  }
  return out;
}

// 売上高・原価（自動）はstg_pl（bqGetPL）には無くfact_daily_store（bqDailyStore）側にある
// （2026-08-25ユーザー指摘で判明。export-run/index.tsと同じ理由）。プレビューの「売上高合計」用に取得。
type DailyAgg = { ym: string; storeName: string; netSales: number };
async function fetchDailyNetSales(token: string): Promise<DailyAgg[]> {
  const res = await dashCall({ action: "bqDailyStore", token });
  if (!res.ok) throw new Error("bqDailyStore取得に失敗: " + (res.error ?? ""));
  const rows: any[] = (res.sheets?.daily ?? []).slice(1);
  const map = new Map<string, DailyAgg>();
  for (const r of rows) {
    const ym = normalizeYm(r[0]);
    if (!ym) continue;
    const storeName = String(r[1] ?? "").trim();
    const key = `${ym}__${storeName}`;
    const cur = map.get(key) ?? { ym, storeName, netSales: 0 };
    cur.netSales += Number(r[2] ?? 0);
    map.set(key, cur);
  }
  return [...map.values()];
}

// 媒体名の正規化（export-run/index.tsのcanonMedia()と同じ。tori-dashboard/app.js 3196行目を移植）
function canonMedia(m: unknown): string {
  const s = String(m ?? "").trim();
  if (!s) return "";
  const u = s.toUpperCase();
  if (u.indexOf("RETTY") >= 0 || /RT$/.test(u)) return "Retty";
  if (u.indexOf("ホットペッパー") >= 0 || u.indexOf("HP") >= 0) return "ホットペッパー";
  if (u.indexOf("ぐるなび") >= 0 || u.indexOf("GN") >= 0) return "ぐるなび";
  if (u.indexOf("食べログ") >= 0 || u.indexOf("TL") >= 0) return "食べログ";
  if (u.indexOf("LP") >= 0) return "自社LP";
  if (u.indexOf("インスタ") >= 0 || u.indexOf("INSTAGRAM") >= 0) return "Instagram";
  if (u.indexOf("GOOGLE") >= 0 || u.indexOf("グーグル") >= 0 || u.indexOf("マップ") >= 0) return "Google";
  return s;
}
type AdCostRow = { ym: string; storeName: string; media: string; cost: number };
function colIndexOf(header: string[], name: string): number {
  return header.findIndex((h) => String(h ?? "").indexOf(name) >= 0);
}
async function fetchAdCostRows(token: string): Promise<AdCostRow[]> {
  const res = await dashCall({ action: "data", token, keys: "ad" });
  if (!res.ok) throw new Error("広告DB取得に失敗: " + (res.error ?? ""));
  const rows: any[][] = res.sheets?.ad ?? [];
  if (!rows.length) return [];
  let hi = -1;
  for (let i = 0; i < Math.min(rows.length, 12); i++) {
    const line = rows[i].map((x) => String(x ?? "")).join(",");
    if (/広告費|広告|費用|金額/.test(line) && /年月|日付|店舗/.test(line)) { hi = i; break; }
  }
  if (hi < 0) hi = 0;
  const header = rows[hi].map((h) => String(h ?? "").trim());
  const iD = colIndexOf(header, "日付") >= 0 ? colIndexOf(header, "日付") : colIndexOf(header, "年月");
  const iS = colIndexOf(header, "店舗");
  const iM = colIndexOf(header, "媒体");
  let iC = colIndexOf(header, "広告費");
  if (iC < 0) iC = colIndexOf(header, "広告");
  if (iC < 0) iC = colIndexOf(header, "費用");
  if (iC < 0) iC = colIndexOf(header, "金額");
  if (iD < 0 || iC < 0) return [];
  const out: AdCostRow[] = [];
  for (let i = hi + 1; i < rows.length; i++) {
    const r = rows[i];
    const ym = normalizeYm(r[iD]);
    if (!ym) continue;
    const cost = Number(r[iC] ?? 0);
    if (!cost) continue;
    out.push({ ym, storeName: String(iS >= 0 ? r[iS] ?? "" : "").trim(), media: canonMedia(iM >= 0 ? r[iM] : ""), cost });
  }
  return out;
}
type AdSalesRow = { ym: string; storeName: string; media: string; netSales: number };
async function fetchMediaSales(token: string): Promise<AdSalesRow[]> {
  const res = await dashCall({ action: "bqGetMedia", token });
  if (!res.ok) throw new Error("bqGetMedia取得に失敗: " + (res.error ?? ""));
  const rows: any[] = (res.sheets?.media ?? []).slice(1);
  const out: AdSalesRow[] = [];
  for (const r of rows) {
    const ym = normalizeYm(r[1]);
    if (!ym) continue;
    out.push({ ym, storeName: String(r[0] ?? "").trim(), media: canonMedia(r[2]), netSales: Number(r[5] ?? 0) });
  }
  return out;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const sb = svc();
    let body: any = {};
    try { body = await req.json(); } catch { /* ボディなし */ }

    const uid = jwtUid(req);
    const { data: u } = await sb.from("users").select("role,is_master,is_active").eq("id", uid).maybeSingle();
    if (!u?.is_active) return json({ ok: false, error: "認証が必要です" }, 401);

    // 注: export_can_access()はauth.uid()前提のSQL関数だが、この呼び出しはservice_roleクライアント
    // （PostgRESTのユーザーJWTコンテキストを持たない）のためauth.uid()が解決しない。
    // RPCには頼らずexport_allowed_store_ids(p_uid=...)と同じロール判定をここで直接行う
    // （p_uidを明示的に渡すexport_allowed_store_idsは正しく動く＝下のRPC呼び出しは問題ない）。
    const canAccess = !!(u.is_master || ["CEO", "HQ", "TEAM", "TENCHO"].includes(u.role));
    if (!canAccess) return json({ ok: false, error: "データ出力センターへのアクセス権限がありません" }, 403);

    const reportKey = String(body.report_key ?? "");
    const VALID_KEYS = ["pl_monthly", "pl_annual_trend", "ad_media"];
    if (!VALID_KEYS.includes(reportKey)) {
      return json({ ok: false, error: `report_keyは${VALID_KEYS.join("/")}のいずれかです` }, 400);
    }
    const isAd = reportKey === "ad_media";

    const periodFrom = String(body.period_from ?? "").slice(0, 7);
    const periodTo = String(body.period_to ?? "").slice(0, 7);
    if (!/^\d{4}-\d{2}$/.test(periodFrom) || !/^\d{4}-\d{2}$/.test(periodTo) || periodFrom > periodTo) {
      return json({ ok: false, error: "対象期間が不正です（YYYY-MM形式・from<=to）" }, 400);
    }

    // --- 許可店舗の確定（アプリ層。RLSではなくこちらが権限境界の実体） ---
    const { data: allowedIds } = await sb.rpc("export_allowed_store_ids", { p_uid: uid });
    const allowedIdSet = new Set<string>((allowedIds ?? []) as string[]);
    if (allowedIdSet.size === 0) {
      return json({ ok: false, error: "出力可能な店舗がありません" }, 403);
    }
    const requestedIds: string[] = Array.isArray(body.store_ids) ? body.store_ids : [];
    const targetIds = requestedIds.length
      ? requestedIds.filter((id) => allowedIdSet.has(id))
      : [...allowedIdSet];
    if (targetIds.length === 0) {
      return json({ ok: false, error: "指定された店舗はいずれも出力権限がありません" }, 403);
    }

    const { data: storeRows } = await sb.from("stores").select("id,name,dash_store_name").in("id", targetIds);
    const targetNames = new Set<string>();
    (storeRows ?? []).forEach((s: any) => {
      targetNames.add(String(s.dash_store_name || s.name).trim());
    });
    if (targetNames.size === 0) {
      return json({ ok: false, error: "店舗名を解決できませんでした" }, 500);
    }

    // --- GASブリッジ経由でBQ(stg_pl・fact_daily_store・stg_media)/広告DBを取得しフィルタ ---
    const login = await dashLogin(sb);
    if (!login.ok) return json({ ok: false, error: login.error }, 500);

    if (isAd) {
      const [allCost, allSales] = await Promise.all([fetchAdCostRows(login.token!), fetchMediaSales(login.token!)]);
      const costMatched = allCost.filter((r) => r.ym >= periodFrom && r.ym <= periodTo && targetNames.has(r.storeName));
      const salesMatched = allSales.filter((r) => r.ym >= periodFrom && r.ym <= periodTo && targetNames.has(r.storeName));
      const costTotal = costMatched.reduce((s, r) => s + r.cost, 0);
      const salesTotal = costMatched.length || salesMatched.length ? salesMatched.reduce((s, r) => s + r.netSales, 0) : 0;
      const mediaSet = new Set([...costMatched.map((r) => r.media), ...salesMatched.map((r) => r.media)]);
      const yms = new Set([...costMatched.map((r) => r.ym), ...salesMatched.map((r) => r.ym)]);
      return json({
        ok: true,
        report_key: reportKey,
        period: { from: periodFrom, to: periodTo, months: yms.size },
        store_count: targetNames.size,
        store_names: [...targetNames],
        row_count: costMatched.length + salesMatched.length,
        media_count: mediaSet.size,
        ad_cost_total: costTotal,
        sales_total: salesTotal,
        roas: costTotal > 0 ? salesTotal / costTotal : null,
        note: (costMatched.length === 0 && salesMatched.length === 0) ? "指定条件に一致するデータがありません（広告DB未設定、またはBQミラー未反映の可能性）" : undefined,
      });
    }

    const [allRows, allDaily] = await Promise.all([fetchPlRows(login.token!), fetchDailyNetSales(login.token!)]);

    const matched = allRows.filter((r) => r.ym >= periodFrom && r.ym <= periodTo && targetNames.has(r.storeName));
    const companyWide = allRows.filter((r) => r.ym >= periodFrom && r.ym <= periodTo && r.storeName === "");
    const dailyMatched = allDaily.filter((d) => d.ym >= periodFrom && d.ym <= periodTo && targetNames.has(d.storeName));

    const salesTotal = dailyMatched.reduce((s, d) => s + d.netSales, 0);
    const yms = new Set([...matched.map((r) => r.ym), ...dailyMatched.map((d) => d.ym)]);

    return json({
      ok: true,
      report_key: reportKey,
      period: { from: periodFrom, to: periodTo, months: yms.size },
      store_count: targetNames.size,
      store_names: [...targetNames],
      row_count: matched.length + dailyMatched.length,
      company_wide_row_count: companyWide.length,
      sales_total: salesTotal,
      note: (matched.length === 0 && dailyMatched.length === 0) ? "指定条件に一致するデータがありません（BQミラー未反映の可能性）" : undefined,
    });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
