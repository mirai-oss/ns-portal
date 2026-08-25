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
    if (!["pl_monthly", "pl_annual_trend"].includes(reportKey)) {
      return json({ ok: false, error: "report_keyはpl_monthly/pl_annual_trendのいずれかです" }, 400);
    }

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

    // --- GASブリッジ経由でBQ(stg_pl・fact_daily_store)を取得しフィルタ ---
    const login = await dashLogin(sb);
    if (!login.ok) return json({ ok: false, error: login.error }, 500);
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
