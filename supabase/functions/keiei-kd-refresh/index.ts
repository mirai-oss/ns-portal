// W2③④: kd_サマリ系の日次/毎時リフレッシュジョブ（レーンP専任・service_role限定）
// docs/設計書_表示集計層kdと高速化実行計画_2026-09-02.md §3/§6/§10.1
//
// 呼び出し方: POST { op: 'reservation_daily'|'dashboard_daily'|'home_kpi'|'unresolved_notify' }（service_roleのみ）
//   運用: .github/workflows/keiei-kd-hourly.yml（dashboard_daily・home_kpiを日中毎時）
//        .github/workflows/keiei-perflog-daily.yml（reservation_daily・unresolved_notifyを日次で追加実行）
//
// 各opの実行内容はkd_sync_runsに記録する（start→success/failed）。画面側（app.js）はkd_sync_runsの
// 最新finished_atが変わった時だけ再取得すればよい設計（§7）。
//
// 【データ出典についての注記・2026-09-03修正】net_sales/guests/parties等はtori-dashboard GASの
// `bqDailyStore`アクション（login必須・labor-allocation-compareと全く同じ呼び出し方=dash_id/dash_pw
// でログイン→token付きで呼ぶ。GASコード自体は無変更）から取得する。
// 【誤りの記録】初版では軽量アクション`bqDailyStoreForSync`（dash-syncが使う、ログイン不要・
// BQ_LOAD_TOKEN認証）を使っていたが、このアクションは[date,store_name,net_sales,cogs,labor_cost_total]
// の5列しか返さない（tori-dashboard/gas/Code.gs:2465 bqDailyStoreForSync()参照）。guests_total/
// parties_total列が存在しないため、実際にはrow[3]=cogsをguestsとして、存在しないrow[12]を
// partiesとして読んでいて0/桁違いの値になっていた（担当AのTK-60報告=kd_dashboard_daily_summaryが
// 空、を受けたレーンPの調査で発覚。あわせて、失敗時にHTTP 200を返してしまいkd_sync_runsの
// failedがGitHub Actions側から見えなくなるバグも同時発見・修正済み）。
import { createClient } from "npm:@supabase/supabase-js@2";

const cors: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });

const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

// tori-dashboardのGAS Web App URL（公開リポジトリのapp.jsに同じ値がある。秘密情報ではない。dash-sync/
// labor-allocation-compareと同じ定数）
const DASH_API_URL = "https://script.google.com/macros/s/AKfycbwW0qhyEr0-uQWTaLg7MkQhurHq6wMoaOKL7uCCnI_bgnAsGB5-auqG_dm_Q9uJc3Kc/exec";
const EXCLUDE_ACCOUNTS_TEMP = ["鶏武者 川崎店", "鶏武者 新横浜", "黒霧屋 新横浜"];

function jstToday(): string {
  return new Date(Date.now() + 9 * 3600 * 1000).toISOString().slice(0, 10);
}
function addDays(dateStr: string, days: number): string {
  const d = new Date(dateStr + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}
function toDateStr(v: unknown): string | null {
  const s = String(v ?? "").trim();
  const m = s.match(/(\d{4})[\/\-](\d{1,2})[\/\-](\d{1,2})/);
  if (!m) return null;
  return `${m[1]}-${m[2].padStart(2, "0")}-${m[3].padStart(2, "0")}`;
}
function num(v: unknown): number {
  const n = Number(String(v ?? "").replace(/[,¥\s]/g, ""));
  return isNaN(n) ? 0 : n;
}

async function startRun(sb: any, job: string, periodFrom?: string, periodTo?: string) {
  const { data, error } = await sb.from("kd_sync_runs")
    .insert({ job, period_from: periodFrom ?? null, period_to: periodTo ?? null, status: "running" })
    .select("id").single();
  if (error) throw new Error("kd_sync_runs開始記録に失敗: " + error.message);
  return data.id as string;
}
async function finishRun(sb: any, runId: string, ok: boolean, rows: number, error?: string) {
  await sb.from("kd_sync_runs").update({
    finished_at: new Date().toISOString(), status: ok ? "success" : "failed", rows, error: error ?? null,
  }).eq("id", runId);
}

async function sendLark(sb: any, text: string) {
  const { data: sec } = await sb.from("app_secrets").select("value").eq("key", "lark_webhook_url").maybeSingle();
  const url = (sec?.value ?? "").trim();
  if (!url) return { ok: false, reason: "app_secretsにlark_webhook_url未設定" };
  const res = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ msg_type: "text", content: { text } }) });
  return { ok: res.ok, status: res.status };
}

async function loadStoreMaps(sb: any) {
  const { data: storeRows } = await sb.from("stores").select("id,name,dash_store_name,corporation_id");
  const idByName = new Map<string, string>();
  const corpByStoreId = new Map<string, string | null>();
  (storeRows ?? []).forEach((s: any) => {
    if (s.dash_store_name) idByName.set(String(s.dash_store_name).trim(), s.id);
    if (!idByName.has(String(s.name).trim())) idByName.set(String(s.name).trim(), s.id);
    corpByStoreId.set(s.id, s.corporation_id ?? null);
  });
  return { idByName, corpByStoreId };
}

// ============== op=reservation_daily: kd_reservation_daily_summary ==============
async function refreshReservationDaily(sb: any, body: any) {
  const from = typeof body.from === "string" ? body.from : addDays(jstToday(), -1); // 既定=前日分（当日分の後追い変化も拾うため翌回で上書きされる）
  const to = typeof body.to === "string" ? body.to : jstToday();
  const runId = await startRun(sb, "kd_reservation_daily_summary", from, to);
  try {
    const { corpByStoreId } = await loadStoreMaps(sb);
    let q = sb.from("rsv_reservations")
      .select("store_id,visit_date,visit_time,party_size,status_normalized,channel_raw,created_at_source,imported_at,store_account")
      .gte("visit_date", from).lte("visit_date", to)
      .not("store_account", "in", `(${EXCLUDE_ACCOUNTS_TEMP.map((n) => `"${n}"`).join(",")})`);
    const { data, error } = await q;
    if (error) throw new Error(error.message);

    type Day = {
      store_id: string; period_date: string; reservation_count: number; party_size_sum: number;
      same_day_count: number; same_day_party: number; walkin_count: number; walkin_party: number;
      cancel: Record<string, { count: number; party: number }>; channel: Record<string, { count: number; party: number }>;
      maxImportedAt: string | null; sourceCount: number;
    };
    const byKey = new Map<string, Day>();
    for (const r of (data ?? []) as any[]) {
      const key = `${r.store_id}|${r.visit_date}`;
      const d = byKey.get(key) ?? {
        store_id: r.store_id, period_date: r.visit_date, reservation_count: 0, party_size_sum: 0,
        same_day_count: 0, same_day_party: 0, walkin_count: 0, walkin_party: 0, cancel: {}, channel: {},
        maxImportedAt: null, sourceCount: 0,
      };
      d.sourceCount++;
      const party = Number(r.party_size) || 0;
      const status = String(r.status_normalized || "");
      if (r.imported_at && (!d.maxImportedAt || r.imported_at > d.maxImportedAt)) d.maxImportedAt = r.imported_at;

      if (status.startsWith("cancelled")) {
        const kind = status.replace(/^cancelled_/, "") || "other"; // user/other/store/noshow
        const cur = d.cancel[kind] ?? { count: 0, party: 0 };
        cur.count++; cur.party += party; d.cancel[kind] = cur;
      } else {
        d.reservation_count++;
        d.party_size_sum += party;
        const createdDate = r.created_at_source ? String(r.created_at_source).slice(0, 10) : null;
        if (createdDate && createdDate === r.visit_date) { d.same_day_count++; d.same_day_party += party; }
        const channel = String(r.channel_raw || "").trim();
        if (channel) {
          const cur = d.channel[channel] ?? { count: 0, party: 0 };
          cur.count++; cur.party += party; d.channel[channel] = cur;
          if (channel.includes("ウォークイン")) { d.walkin_count++; d.walkin_party += party; }
        }
      }
      byKey.set(key, d);
    }

    // 客単価（avg_check）が既にkd_dashboard_daily_summaryにあれば予約売上見込を計算する
    // （.or()のクエリ長対策で日数が多いバックフィル実行時はスキップ＝expected_salesはnullのまま）
    const days = [...byKey.values()];
    const storeDatePairs = days.map((d) => `and(store_id.eq.${d.store_id},period_date.eq.${d.period_date})`);
    const avgCheckMap = new Map<string, number>();
    if (storeDatePairs.length && storeDatePairs.length <= 200) {
      const { data: dashRows } = await sb.from("kd_dashboard_daily_summary")
        .select("store_id,period_date,avg_check").or(storeDatePairs.join(","));
      (dashRows ?? []).forEach((r: any) => { if (r.avg_check != null) avgCheckMap.set(`${r.store_id}|${r.period_date}`, Number(r.avg_check)); });
    }

    const upserts = days.map((d) => {
      const avgCheck = avgCheckMap.get(`${d.store_id}|${d.period_date}`);
      return {
        store_id: d.store_id, corporation_id: corpByStoreId.get(d.store_id) ?? null, period_date: d.period_date,
        reservation_count: d.reservation_count, party_size_sum: d.party_size_sum,
        same_day_count: d.same_day_count, same_day_party: d.same_day_party,
        walkin_count: d.walkin_count, walkin_party: d.walkin_party,
        cancel_breakdown: d.cancel, channel_breakdown: d.channel,
        expected_sales: avgCheck != null ? Math.round(d.party_size_sum * avgCheck) : null,
        source_updated_at: d.maxImportedAt, computed_at: new Date().toISOString(),
        source_count: d.sourceCount, sync_run_id: runId,
      };
    });
    for (let i = 0; i < upserts.length; i += 500) {
      const { error: upErr } = await sb.from("kd_reservation_daily_summary").upsert(upserts.slice(i, i + 500), { onConflict: "store_id,period_date" });
      if (upErr) throw new Error("upsert失敗: " + upErr.message);
    }
    await finishRun(sb, runId, true, upserts.length);
    return { ok: true, job: "reservation_daily", from, to, rows: upserts.length, sync_run_id: runId };
  } catch (e) {
    await finishRun(sb, runId, false, 0, String(e));
    return { ok: false, error: String(e) };
  }
}

// ============== op=dashboard_daily: kd_dashboard_daily_summary ==============
// dash_id/dash_pw（app_secrets）でログイン→token付きでbqDailyStoreを呼ぶ。labor-allocation-compareの
// dashSecrets()/dashCall()と全く同じ方式（GAS変更なし・既存のログイン経由アクションを叩くだけ）。
async function dashSecrets(sb: any) {
  const { data } = await sb.from("app_secrets").select("key,value").in("key", ["dash_id", "dash_pw"]);
  const m: Record<string, string> = {};
  (data ?? []).forEach((r: any) => { m[r.key] = (r.value ?? "").trim(); });
  return { id: m.dash_id ?? "", pw: m.dash_pw ?? "" };
}
async function dashCall(body: unknown) {
  const res = await fetch(DASH_API_URL, {
    method: "POST", headers: { "Content-Type": "text/plain;charset=utf-8" }, body: JSON.stringify(body),
  });
  const text = await res.text();
  try { return JSON.parse(text); }
  catch (_) { return { ok: false, error: "ダッシュボードの応答を読めませんでした: " + text.slice(0, 200) }; }
}
async function bqDailyStoreFull(sb: any, months: number) {
  const { id, pw } = await dashSecrets(sb);
  if (!id || !pw) throw new Error("app_secretsにdash_id/dash_pwが未設定です");
  const login = await dashCall({ action: "login", id, pw });
  if (!login.ok) throw new Error("ダッシュボードへのログインに失敗: " + (login.error ?? ""));
  const res = await dashCall({ action: "bqDailyStore", token: login.token, months: months + 1 });
  if (!res.ok) throw new Error("bqDailyStore取得に失敗: " + (res.error ?? ""));
  return (res.sheets?.daily ?? []) as any[][];
}

async function refreshDashboardDaily(sb: any, body: any) {
  const months = Math.max(1, Number(body.months) || 2);
  const runId = await startRun(sb, "kd_dashboard_daily_summary");
  try {
    const { idByName, corpByStoreId } = await loadStoreMaps(sb);
    const rawRows = await bqDailyStoreFull(sb, months);
    const unmatched = new Set<string>();
    type Row = { store_id: string; period_date: string; net_sales: number; guests: number; parties: number };
    const parsed: Row[] = [];
    for (let r = 1; r < rawRows.length; r++) {
      const row = rawRows[r];
      const storeName = String(row[1] ?? "").trim();
      const dateStr = toDateStr(row[0]);
      if (!storeName || !dateStr) continue;
      const storeId = idByName.get(storeName);
      if (!storeId) { unmatched.add(storeName); continue; }
      // 列順（bqDailyStore・tori-dashboard/gas/Code.gs:1523 BQ_DAILY_STORE_HEADER参照）: date,store_name,
      // net_sales,guests_total,parttime_labor,fulltime_labor,labor_total,cogs,cash,employee_salary_bonus,
      // statutory_welfare,commute_allowance,parties_total
      parsed.push({ store_id: storeId, period_date: dateStr, net_sales: num(row[2]), guests: num(row[3]), parties: num(row[12]) });
    }

    // 前年同曜日比較: 同じ店舗の364日前（同曜日）の行を自テーブルから引く（蓄積が浅いうちはnullのまま）
    const priorDates = [...new Set(parsed.map((p) => addDays(p.period_date, -364)))];
    const storeIds = [...new Set(parsed.map((p) => p.store_id))];
    const priorMap = new Map<string, number>();
    if (priorDates.length && storeIds.length) {
      const { data: priorRows } = await sb.from("kd_dashboard_daily_summary")
        .select("store_id,period_date,net_sales").in("store_id", storeIds).in("period_date", priorDates);
      (priorRows ?? []).forEach((r: any) => priorMap.set(`${r.store_id}|${r.period_date}`, Number(r.net_sales) || 0));
    }

    const upserts = parsed.map((p) => {
      const priorDate = addDays(p.period_date, -364);
      const priorSales = priorMap.get(`${p.store_id}|${priorDate}`);
      return {
        store_id: p.store_id, corporation_id: corpByStoreId.get(p.store_id) ?? null, period_date: p.period_date,
        net_sales: p.net_sales, guests: p.guests, parties: p.parties,
        avg_check: p.guests ? Math.round(p.net_sales / p.guests) : null,
        prior_year_same_weekday_sales: priorSales ?? null,
        prior_year_same_weekday_ratio: priorSales ? (p.net_sales / priorSales) : null,
        source_updated_at: new Date().toISOString(), computed_at: new Date().toISOString(),
        source_count: 1, sync_run_id: runId,
      };
    });
    for (let i = 0; i < upserts.length; i += 500) {
      const { error: upErr } = await sb.from("kd_dashboard_daily_summary").upsert(upserts.slice(i, i + 500), { onConflict: "store_id,period_date" });
      if (upErr) throw new Error("upsert失敗: " + upErr.message);
    }
    await finishRun(sb, runId, true, upserts.length, unmatched.size ? `店舗名未対応: ${[...unmatched].join("、")}` : undefined);
    return { ok: true, job: "dashboard_daily", rows: upserts.length, unmatched: [...unmatched], sync_run_id: runId };
  } catch (e) {
    await finishRun(sb, runId, false, 0, String(e));
    return { ok: false, error: String(e) };
  }
}

// ============== op=home_kpi: kd_home_kpi_snapshot ==============
async function refreshHomeKpi(sb: any) {
  const today = jstToday();
  const monthStart = today.slice(0, 7) + "-01";
  const runId = await startRun(sb, "kd_home_kpi_snapshot", monthStart, today);
  try {
    const { data: storeRows } = await sb.from("stores").select("id,corporation_id");
    const stores = (storeRows ?? []) as { id: string; corporation_id: string | null }[];

    // 当日実績（今日ぶんのkd_dashboard_daily_summary。dashboard_dailyのリフレッシュ後に呼ぶ想定）
    const { data: todayRows } = await sb.from("kd_dashboard_daily_summary")
      .select("store_id,net_sales,guests,parties").eq("period_date", today);
    const todayMap = new Map<string, any>();
    (todayRows ?? []).forEach((r: any) => todayMap.set(r.store_id, r));

    // 月累計売上
    const { data: mtdRows } = await sb.from("kd_dashboard_daily_summary")
      .select("store_id,net_sales").gte("period_date", monthStart).lte("period_date", today);
    const mtdMap = new Map<string, number>();
    (mtdRows ?? []).forEach((r: any) => mtdMap.set(r.store_id, (mtdMap.get(r.store_id) ?? 0) + (Number(r.net_sales) || 0)));

    // 月初〜当日ぶんの日別売上目標を積み上げ（dash_sales_target_daily。dash-syncが既に日次で維持）
    const { data: targetRows } = await sb.from("dash_sales_target_daily")
      .select("store_id,sales_target").gte("biz_date", monthStart).lte("biz_date", today);
    const targetMap = new Map<string, number>();
    (targetRows ?? []).forEach((r: any) => targetMap.set(r.store_id, (targetMap.get(r.store_id) ?? 0) + (Number(r.sales_target) || 0)));

    // 本部タスク滞留数（法人単位。hq_tasks.corp ⇔ corporations.name の名称一致でひも付け）
    const { data: corpRows } = await sb.from("corporations").select("id,name");
    const corpIdByName = new Map<string, string>();
    (corpRows ?? []).forEach((c: any) => corpIdByName.set(c.name, c.id));
    const { data: overdueTasks } = await sb.from("hq_tasks").select("corp")
      .neq("status", "done").lt("due_date", today).is("deleted_at", null);
    const overdueByCorpId = new Map<string, number>();
    (overdueTasks ?? []).forEach((t: any) => {
      const cid = corpIdByName.get(t.corp);
      if (!cid) return; // 名称不一致は静かにスキップ（4法人のみで既知の値のため。将来kd_unresolved_names化を検討）
      overdueByCorpId.set(cid, (overdueByCorpId.get(cid) ?? 0) + 1);
    });

    const upserts = stores.map((s) => ({
      store_id: s.id, corporation_id: s.corporation_id, period_date: today,
      today_sales: todayMap.get(s.id)?.net_sales ?? null,
      today_guests: todayMap.get(s.id)?.guests ?? null,
      today_parties: todayMap.get(s.id)?.parties ?? null,
      mtd_sales: mtdMap.get(s.id) ?? 0,
      budget_achievement_rate: targetMap.get(s.id) ? (mtdMap.get(s.id) ?? 0) / (targetMap.get(s.id) as number) : null,
      daily_report_submission_rate: null, // TODO: 出典テーブル未特定（nippo日報の提出状況）。司令塔確認後に実装
      checklist_completion_rate: null,    // TODO: 出典テーブル未特定（checklist_checks等）。司令塔確認後に実装
      hq_task_overdue_count: s.corporation_id ? (overdueByCorpId.get(s.corporation_id) ?? 0) : null,
      source_updated_at: new Date().toISOString(), computed_at: new Date().toISOString(),
      source_count: 1, sync_run_id: runId,
    }));
    for (let i = 0; i < upserts.length; i += 500) {
      const { error: upErr } = await sb.from("kd_home_kpi_snapshot").upsert(upserts.slice(i, i + 500), { onConflict: "store_id,period_date" });
      if (upErr) throw new Error("upsert失敗: " + upErr.message);
    }
    await finishRun(sb, runId, true, upserts.length);
    return { ok: true, job: "home_kpi", rows: upserts.length, sync_run_id: runId };
  } catch (e) {
    await finishRun(sb, runId, false, 0, String(e));
    return { ok: false, error: String(e) };
  }
}

// ============== op=unresolved_notify: kd_unresolved_namesの日次Lark digest ==============
async function notifyUnresolved(sb: any) {
  const { data, error } = await sb.from("kd_unresolved_names").select("source_table,kind,raw_name,occurrences,last_seen")
    .eq("status", "open").order("occurrences", { ascending: false }).limit(20);
  if (error) return { ok: false, error: error.message };
  if (!data || !data.length) return { ok: true, count: 0, sent: { skipped: true } };
  const lines = [`🏷️ 未解決の店舗名/媒体名（${data.length}件・上位20件）`];
  data.forEach((r: any, i: number) => lines.push(`${i + 1}. [${r.kind}] "${r.raw_name}"（${r.source_table}・${r.occurrences}回・最終${String(r.last_seen).slice(0, 10)}）`));
  lines.push("→ store_aliases/media_aliasに正式名を登録すると次回から自動で解消します");
  const sent = await sendLark(sb, lines.join("\n"));
  return { ok: true, count: data.length, sent };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const sb = svc();
    const authHeader = req.headers.get("Authorization") ?? "";
    const isServiceRole = authHeader.includes(Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? " ");
    if (!isServiceRole) return json({ ok: false, error: "権限がありません（service_roleのみ）" }, 403);

    let body: any = {};
    try { body = await req.json(); } catch { /* ボディなし */ }

    let result: any;
    switch (body.op) {
      case "reservation_daily": result = await refreshReservationDaily(sb, body); break;
      case "dashboard_daily": result = await refreshDashboardDaily(sb, body); break;
      case "home_kpi": result = await refreshHomeKpi(sb); break;
      case "unresolved_notify": result = await notifyUnresolved(sb); break;
      default: return json({ ok: false, error: "opは'reservation_daily'|'dashboard_daily'|'home_kpi'|'unresolved_notify'のいずれかが必須です" }, 400);
    }
    // 2026-09-03修正: ok:falseの結果をHTTP 200で返してしまうとGitHub Actions側のHTTP_CODEチェックを
    // すり抜けて「success」表示のまま失敗が握りつぶされる（実際にdashboard_dailyの失敗がこれで見逃されていた）。
    // 失敗時は必ず500を返す。
    return json(result, result?.ok ? 200 : 500);
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
