// ============================================================
// ai-gateway — AI窓口（Hermes等）専用の読み取り専用データ経路（フェーズC-1）
// 要件定義書§18準拠:
//  - AIにはこの関数の専用トークン(AI_GATEWAY_TOKEN)だけを渡す（service_roleは渡さない）
//  - 実行できるのは下のカタログに定義済みの照会だけ（自由SQL不可）
//  - 全呼び出しを ai_audit_logs に記録
//  - 機密（給与・口座・契約書・ID/PW金庫=infoスキーマ）へは一切アクセスしない
//  - 書き込み系は sales_backfill（自テーブルの履歴補充・管理用）のみ
// 2026-08-31 作成（D-8 Hermes試用・設計スレッド）
import { createClient } from "npm:@supabase/supabase-js@2";

const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json; charset=utf-8" } });
const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const DASH_API_URL = "https://script.google.com/macros/s/AKfycbz9rd37EZa6X8WRMVEBrXobN8DbYWkHRlhFNYU5rd1UZ0V8j0-6shMQjEeoi4HDWZ0B/exec";

function jstToday(): string {
  return new Date(Date.now() + 9 * 3600e3).toISOString().slice(0, 10);
}
function addDays(d: string, n: number): string {
  const t = new Date(d + "T00:00:00Z"); t.setUTCDate(t.getUTCDate() + n);
  return t.toISOString().slice(0, 10);
}

// ---------- 照会カタログ ----------
async function storeDirectory(sb: any) {
  const { data } = await sb.from("stores")
    .select("store_no,name,signs,is_active,seisan_target")
    .order("store_no");
  return data ?? [];
}

async function salesSummary(sb: any, p: any) {
  // 集計はDB側RPC（ai_sales_summary・service_roleのみ実行可）で行う。
  // PostgRESTの行数上限(1000行)の影響を受けず、転送も軽い。
  const { data, error } = await sb.rpc("ai_sales_summary", { p_store: p?.store ?? null });
  if (error) throw new Error(error.message);
  const r = data ?? {};
  const tm = Number(r.this_month_total ?? 0), ly = Number(r.last_year_same_period ?? 0);
  return {
    note: "金額は円。前年比は「今日と同じ日数まで」の比較。データ源=dash_sales_daily（BigQuery日次同期＋26ヶ月バックフィル済み）",
    ...r,
    yoy_pct: ly > 0 ? Math.round(tm / ly * 1000) / 10 : null,
  };
}

async function nippoStatus(sb: any, p: any) {
  const date = p?.date ?? jstToday();
  const [{ data: users }, { data: reps }] = await Promise.all([
    sb.from("users").select("id,name,role").eq("is_active", true).neq("role", "CEO"),
    sb.from("reports").select("author_id").eq("kind", "daily").eq("report_date", date),
  ]);
  const submitted = new Set((reps ?? []).map((r: any) => r.author_id));
  const out = { date, submitted: [] as string[], not_submitted: [] as string[] };
  for (const u of users ?? []) {
    (submitted.has(u.id) ? out.submitted : out.not_submitted).push(`${u.name}(${u.role})`);
  }
  return { ...out, note: "対象=有効ユーザー（社長除く）。日報の提出義務が無い人も含まれる場合があります" };
}

async function checklistStatus(sb: any, p: any) {
  const date = p?.date ?? jstToday();
  const [{ data: tpls }, { data: items }, { data: checks }, { data: alerts }] = await Promise.all([
    sb.from("checklist_templates").select("id,title,store_id,is_active").eq("is_active", true),
    sb.from("checklist_items").select("id,template_id,label,is_active").eq("is_active", true),
    sb.from("checklist_checks").select("item_id,store_id").eq("work_date", date),
    sb.from("checklist_overdue_alerts").select("store_id,work_date,resolved_at,item_id").is("resolved_at", null),
  ]);
  const { data: stores } = await sb.from("stores").select("id,name").eq("is_active", true);
  const sname = new Map((stores ?? []).map((s: any) => [s.id, s.name]));
  const itemsByTpl = new Map<string, any[]>();
  for (const i of items ?? []) {
    if (!itemsByTpl.has(i.template_id)) itemsByTpl.set(i.template_id, []);
    itemsByTpl.get(i.template_id)!.push(i);
  }
  const done = new Set((checks ?? []).map((c: any) => c.item_id + "|" + c.store_id));
  const perStore: any[] = [];
  for (const s of stores ?? []) {
    let total = 0, doneN = 0;
    for (const t of tpls ?? []) {
      if (t.store_id && t.store_id !== s.id) continue;
      for (const i of itemsByTpl.get(t.id) ?? []) {
        total++; if (done.has(i.id + "|" + s.id)) doneN++;
      }
    }
    if (total > 0) perStore.push({ store: s.name, done: doneN, total });
  }
  const openAlerts = (alerts ?? []).map((a: any) => ({ store: sname.get(a.store_id) ?? "?", work_date: a.work_date }));
  return { date, per_store: perStore, unresolved_overdue_alerts: openAlerts };
}

async function tasksStatus(sb: any) {
  const today = jstToday();
  const { data } = await sb.from("hq_tasks")
    .select("title,corp,status,due_date,target_date,memo")
    .is("deleted_at", null).eq("visibility", "all").neq("status", "done").limit(200);
  const overdue = (data ?? []).filter((t: any) => t.due_date && t.due_date < today);
  const dueToday = (data ?? []).filter((t: any) => t.due_date === today);
  return {
    note: "公開範囲=本部全員のタスクのみ（限定公開タスクは件数にも含めない）",
    open_count: (data ?? []).length,
    overdue: overdue.map((t: any) => ({ title: t.title, due: t.due_date, corp: t.corp, memo: t.memo })),
    due_today: dueToday.map((t: any) => ({ title: t.title, corp: t.corp })),
  };
}

async function postsLatest(sb: any) {
  const { data } = await sb.from("portal_posts")
    .select("title,body,pinned,created_at")
    .order("pinned", { ascending: false }).order("created_at", { ascending: false }).limit(5);
  return (data ?? []).map((p: any) => ({
    title: p.title, pinned: p.pinned, created_at: p.created_at,
    body: String(p.body ?? "").slice(0, 300),
  }));
}

async function expensesStatus(sb: any) {
  const monthStart = jstToday().slice(0, 8) + "01";
  const [{ data: pend }, { data: appr }] = await Promise.all([
    sb.from("expense_requests").select("amount,use_date,purpose,users!expense_requests_applicant_id_fkey(name)")
      .eq("status", "pending").limit(20),
    sb.from("expense_requests").select("amount").eq("status", "approved").gte("decided_at", monthStart),
  ]);
  return {
    pending: (pend ?? []).map((e: any) => ({ applicant: e.users?.name ?? "?", amount: e.amount, use_date: e.use_date, purpose: e.purpose })),
    approved_this_month_total: (appr ?? []).reduce((a: number, e: any) => a + Number(e.amount ?? 0), 0),
  };
}

// 管理用: dash_sales_daily の履歴バックフィル（GASのBQ軽量アクション経由・dash-syncと同じ形式でupsert）
async function salesBackfill(sb: any, p: any) {
  const months = Math.min(Number(p?.months) || 26, 36);
  const tk = Deno.env.get("BQ_LOAD_TOKEN");
  if (!tk) throw new Error("BQ_LOAD_TOKEN未設定");
  const url = new URL(DASH_API_URL);
  url.searchParams.set("action", "bqDailyStoreForSync");
  url.searchParams.set("token", tk);
  url.searchParams.set("months", String(months));
  const res = await fetch(url.toString());
  const j = await res.json();
  if (!j.ok) throw new Error("GAS/BQ取得失敗: " + (j.error ?? ""));
  const rows: any[][] = j.sheets?.daily ?? [];
  const { data: stores } = await sb.from("stores").select("id,name,dash_store_name");
  const nameMap = new Map<string, string>();
  for (const s of stores ?? []) {
    nameMap.set(String(s.name).trim(), s.id);
    if (s.dash_store_name) nameMap.set(String(s.dash_store_name).trim(), s.id);
  }
  const ups: any[] = []; const unmatched = new Set<string>();
  for (let r = 1; r < rows.length; r++) {
    const [d, store, sales, cost, labor] = rows[r];
    const sid = nameMap.get(String(store ?? "").trim());
    const dateStr = String(d ?? "").replace(/\//g, "-");
    if (!sid || !/^\d{4}-\d{2}-\d{2}$/.test(dateStr)) { if (store) unmatched.add(String(store)); continue; }
    ups.push({ store_id: sid, biz_date: dateStr, sales: Number(sales ?? 0), cost: Number(cost ?? 0), labor: Number(labor ?? 0), updated_at: new Date().toISOString() });
  }
  for (let i = 0; i < ups.length; i += 500) {
    const { error } = await sb.from("dash_sales_daily").upsert(ups.slice(i, i + 500), { onConflict: "store_id,biz_date" });
    if (error) throw new Error("upsert失敗: " + error.message);
  }
  return { fetched: rows.length - 1, upserted: ups.length, unmatched: [...unmatched] };
}

const CATALOG: Record<string, (sb: any, p: any) => Promise<any>> = {
  store_directory: (sb, _p) => storeDirectory(sb),
  sales_summary: salesSummary,
  nippo_status: nippoStatus,
  checklist_status: checklistStatus,
  tasks_status: (sb, _p) => tasksStatus(sb),
  posts_latest: (sb, _p) => postsLatest(sb),
  expenses_status: (sb, _p) => expensesStatus(sb),
  sales_backfill: salesBackfill, // 管理用（同トークン・読み取り経路の自テーブル補充のみ）
};

Deno.serve(async (req) => {
  let body: any = {};
  try { body = await req.json(); } catch (_) { /* noop */ }
  const token = Deno.env.get("AI_GATEWAY_TOKEN");
  if (!token || body.token !== token) return json({ ok: false, error: "認証エラー" }, 403);
  const key = String(body.query_key ?? "");
  const fn = CATALOG[key];
  const sb = svc();
  if (!fn) {
    await sb.from("ai_audit_logs").insert({ agent: body.agent ?? "hermes-line", query_key: key || "(空)", params: body.params ?? null, ok: false, error: "未定義の照会" });
    return json({ ok: false, error: "未定義の照会です", available: Object.keys(CATALOG).filter(k => k !== "sales_backfill") }, 400);
  }
  try {
    const result = await fn(sb, body.params ?? {});
    const rowCount = Array.isArray(result) ? result.length : (result && typeof result === "object" ? Object.keys(result).length : 1);
    await sb.from("ai_audit_logs").insert({ agent: body.agent ?? "hermes-line", query_key: key, params: body.params ?? null, row_count: rowCount, ok: true });
    return json({ ok: true, query_key: key, result });
  } catch (e) {
    const msg = String((e as Error)?.message ?? e);
    await sb.from("ai_audit_logs").insert({ agent: body.agent ?? "hermes-line", query_key: key, params: body.params ?? null, ok: false, error: msg });
    return json({ ok: false, error: msg }, 500);
  }
});
