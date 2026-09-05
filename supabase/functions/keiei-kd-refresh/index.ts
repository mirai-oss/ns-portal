// W2③④+W3①: kd_サマリ系の日次/毎時/月次リフレッシュジョブ（レーンP専任・service_role限定）
// docs/設計書_表示集計層kdと高速化実行計画_2026-09-02.md §3/§6/§10.1/§10.2-1
//
// 呼び出し方: POST { op: 'reservation_daily'|'dashboard_daily'|'home_kpi'|'unresolved_notify'
//                    |'pl_monthly'|'media_monthly'|'deposit_monthly' }（service_roleのみ）
//   運用: .github/workflows/keiei-kd-hourly.yml（dashboard_daily・home_kpiを日中毎時）
//        .github/workflows/keiei-perflog-daily.yml（reservation_daily・unresolved_notify・
//        pl_monthly・media_monthly・deposit_monthlyを日次で追加実行。月次サマリだが当月分の
//        反映を翌日まで待たせたくないので日次リフレッシュに含める）
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
// 2026-09-06追加（担当D・監視タスク）: 失敗時はkd_sync_runsへの記録だけでなく、当日中にLarkへも
// 通知する（今まではfinishRun(ok:false)がkd_sync_runsに書くだけで、誰も見ていなければ何日も
// 気づかれない状態だった。実際に9/2〜9/5で5回のdashboard_daily失敗がLark無通知のまま記録されていた）。
// job名も渡してもらい、どのサマリの更新が止まっているか一目で分かるメッセージにする。
async function finishRun(sb: any, runId: string, ok: boolean, rows: number, error?: string, job?: string) {
  await sb.from("kd_sync_runs").update({
    finished_at: new Date().toISOString(), status: ok ? "success" : "failed", rows, error: error ?? null,
  }).eq("id", runId);
  if (!ok) {
    try {
      await sendLark(sb, `⚠️ kd_サマリ更新に失敗しました（${job ?? "job不明"}）\n${(error ?? "").slice(0, 300)}\nrun_id=${runId}\n※次回の自動リフレッシュで再試行されます。繰り返す場合はkd_sync_runsを確認してください。`);
    } catch (_) { /* Lark通知自体の失敗でジョブ本体は止めない */ }
  }
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
    await finishRun(sb, runId, false, 0, String(e), "kd_reservation_daily_summary");
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
    type Row = { store_id: string; period_date: string; net_sales: number; guests: number; parties: number; cost: number; labor: number };
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
      // 2026-09-06追加: cost(cogs=row[7])/labor(labor_total=row[6])。kd_pl_monthly_summary(op=pl_monthly)の
      // 自動売上/原価/人件費の元データとして使う（既に取得していたのに保存していなかった列）。
      parsed.push({
        store_id: storeId, period_date: dateStr, net_sales: num(row[2]), guests: num(row[3]), parties: num(row[12]),
        cost: num(row[7]), labor: num(row[6]),
      });
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
        net_sales: p.net_sales, guests: p.guests, parties: p.parties, cost: p.cost, labor: p.labor,
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
    // 2026-09-06追加（担当D・監視タスク）: 未対応の店舗名はkd_sync_runs.errorに埋めるだけでなく、
    // kd_unresolved_namesへも隔離登録する（既存RPC・(source_table,kind,raw_name)でupsert・
    // 再出現のたびoccurrences+1）。こうしないとmorning-watchdogのkd_unresolved件数チェック（担当D実装）
    // からは見えないまま埋もれてしまう。
    for (const nm of unmatched) {
      try { await sb.rpc("kd_report_unresolved_name", { p_source_table: "kd_dashboard_daily_summary", p_kind: "store", p_raw_name: nm }); }
      catch (_) { /* 隔離登録の失敗でリフレッシュ本体は止めない */ }
    }
    await finishRun(sb, runId, true, upserts.length, unmatched.size ? `店舗名未対応: ${[...unmatched].join("、")}` : undefined);
    return { ok: true, job: "dashboard_daily", rows: upserts.length, unmatched: [...unmatched], sync_run_id: runId };
  } catch (e) {
    await finishRun(sb, runId, false, 0, String(e), "kd_dashboard_daily_summary");
    return { ok: false, error: String(e) };
  }
}

// ============== op=pl_monthly: kd_pl_monthly_summary ==============
// app.jsのplCatOf()と全く同じ判定ルール（Code.gs/app.js自体は無変更・ここに移植しただけ）。
function plCatOf(v: unknown): "F" | "L" | "A" | "R" | "O" {
  const s = String(v ?? "").trim().toUpperCase().replace(/[Ａ-Ｚ]/g, (c) => String.fromCharCode(c.charCodeAt(0) - 0xFEE0));
  if (!s) return "O";
  if (s[0] === "F" || /仕入|原価/.test(s)) return "F";
  if (s[0] === "L" || /人件/.test(s)) return "L";
  if (s[0] === "A" || /広告/.test(s)) return "A";
  if (s[0] === "R" || /家賃|賃料/.test(s)) return "R";
  return "O";
}
// 業務委託精算書由来のPL反映（2026-09-06追加・司令塔指示）。tori-dashboard/gas/Code.gs:2970の
// PL_SEISAN_CAT_MEMO/PL_SEISAN_ACCOUNT_CAT_/plSeisanGuessCat_と全く同じ判定（GAS側は無変更・移植のみ）。
// syncSeisanCategoriesToPlがDB_PLへ書き込む際にこのmemoを付けるため、bqGetPLの結果からこのmemoの
// 行だけを抜き出せば「業務委託精算書経由で実際にDB_PLへ届いた金額」を裏付けできる。
const PL_SEISAN_CAT_MEMO = "自動｜精算書";
const PL_SEISAN_ACCOUNT_CAT: Record<string, "S" | "F" | "L" | "A" | "R" | "O" | "X"> = {
  "役員報酬": "L", "法定福利費": "L", "通勤手当": "L", "旅費交通費": "L", "賞与積立": "L", "退職金等": "L",
  "家賃": "R", "リース料": "R", "家賃更新按分": "R", "広告宣伝費": "A", "販売促進費": "A",
  "水道光熱費": "O", "通信費": "O", "消耗品・備品費": "O", "修繕費": "O", "衛生管理費": "O", "カード手数料": "O",
  "支払手数料": "O", "支払報酬料": "O", "採用教育費": "O", "接待交際費": "O", "会議費": "O", "慶弔見舞費": "O",
  "保険料": "O", "租税公課": "O", "減価償却費": "O", "福利厚生費": "O", "諸会費": "O", "雑費": "O", "本部経費（按分）": "O",
  "その他売上": "S", "銀行返済": "X", "仕入（食材・飲料）": "F", "運営委託費": "O",
};
function plSeisanGuessCat(name: string): "S" | "F" | "L" | "A" | "R" | "O" | "X" {
  if (PL_SEISAN_ACCOUNT_CAT[name]) return PL_SEISAN_ACCOUNT_CAT[name];
  if (/給料|雑給|人件費|法定福利|通勤/.test(name)) return "L";
  if (/広告|販促/.test(name)) return "A";
  if (/家賃|賃料/.test(name)) return "R";
  if (/仕入/.test(name)) return "F";
  if (/売上/.test(name)) return "S";
  return "O";
}

async function bqGetPLRows(sb: any): Promise<any[][]> {
  const { id, pw } = await dashSecrets(sb);
  if (!id || !pw) throw new Error("app_secretsにdash_id/dash_pwが未設定です");
  const login = await dashCall({ action: "login", id, pw });
  if (!login.ok) throw new Error("ダッシュボードへのログインに失敗: " + (login.error ?? ""));
  const res = await dashCall({ action: "bqGetPL", token: login.token });
  if (!res.ok) throw new Error("bqGetPL取得に失敗: " + (res.error ?? ""));
  return (res.sheets?.PL ?? []) as any[][];
}
const COMMON_STORE_KEY = "00000000-0000-0000-0000-000000000000"; // 全社共通経費行（store_id=NULL）のupsertキー用センチネル

async function refreshPlMonthly(sb: any) {
  const runId = await startRun(sb, "kd_pl_monthly_summary");
  try {
    const { idByName, corpByStoreId } = await loadStoreMaps(sb);
    const rawRows = await bqGetPLRows(sb);
    const unmatched = new Set<string>();
    type Bucket = {
      store_id: string | null; year_month: string;
      cost_manual: number; labor_manual: number; ad_manual: number; rent: number; other: number;
      breakdown: Record<string, Record<string, number>>; // {F:{勘定科目:金額},...}
      seisanSynced: Record<string, number>; // {F:n,L:n,...}（bqGetPLのmemo=自動｜精算書だけの内訳。裏付け用・加算禁止）
      seisanPending: number; seisanPendingBreakdown: Record<string, number>; // invoice_pl_reflectionsのDB_PL未反映分（後段で合流）
    };
    const newBucket = (storeId: string | null, ym: string): Bucket => ({
      store_id: storeId, year_month: ym, cost_manual: 0, labor_manual: 0, ad_manual: 0, rent: 0, other: 0,
      breakdown: {}, seisanSynced: {}, seisanPending: 0, seisanPendingBreakdown: {},
    });
    const byKey = new Map<string, Bucket>();
    for (let r = 1; r < rawRows.length; r++) {
      const row = rawRows[r];
      const ym = String(row[0] ?? "").trim().replace(/\//g, "-").slice(0, 7);
      if (!/^\d{4}-\d{2}$/.test(ym)) continue;
      const storeName = String(row[1] ?? "").trim();
      const item = String(row[2] ?? "").trim() || "(未分類)";
      const cat = plCatOf(row[3]);
      const amount = num(row[4]);
      const memo = String(row[5] ?? "").trim();
      let storeId: string | null = null;
      if (storeName) {
        storeId = idByName.get(storeName) ?? null;
        if (!storeId) { unmatched.add(storeName); continue; } // 店舗名が解決できない行は集計に混ぜない（原則5）
      }
      const key = `${storeId ?? COMMON_STORE_KEY}|${ym}`;
      const b = byKey.get(key) ?? newBucket(storeId, ym);
      if (cat === "F") b.cost_manual += amount;
      else if (cat === "L") b.labor_manual += amount;
      else if (cat === "A") b.ad_manual += amount;
      else if (cat === "R") b.rent += amount;
      else b.other += amount;
      (b.breakdown[cat] ??= {})[item] = (b.breakdown[cat][item] ?? 0) + amount;
      if (memo === PL_SEISAN_CAT_MEMO) b.seisanSynced[cat] = (b.seisanSynced[cat] ?? 0) + amount;
      byKey.set(key, b);
    }

    // 業務委託精算書のうち、まだDB_PL/stg_plに反映されていない分（振込確定待ち/PL同期待ち）を
    // 別枠で加算（cost_manual等には含めない＝新旧突合の対象外・部分反映として表示する）。
    // 2026-09-06追加（司令塔指示: PL本番切替の条件＝この分がkd_pl_monthly_summaryで見える化されること）。
    {
      const { data: pendingRows, error: pendingErr } = await sb.from("invoice_pl_reflections")
        .select("account_name,year_month,allocations,pl_status")
        .eq("reflection_route", "seisan").in("pl_status", ["振込確定待ち", "PL同期待ち"]);
      if (pendingErr) throw new Error("invoice_pl_reflections取得に失敗: " + pendingErr.message);
      for (const r of (pendingRows ?? []) as any[]) {
        const ym = String(r.year_month ?? "").slice(0, 7);
        if (!/^\d{4}-\d{2}$/.test(ym)) continue;
        const cat = plSeisanGuessCat(String(r.account_name ?? ""));
        if (cat === "S" || cat === "X") continue; // 売上・借入返済はPL費用ではないので対象外
        for (const a of (Array.isArray(r.allocations) ? r.allocations : [])) {
          const storeId: string | null = a?.store_id ?? null;
          const amount = num(a?.amount);
          if (!storeId || !amount) continue;
          const key = `${storeId}|${ym}`;
          const b = byKey.get(key) ?? newBucket(storeId, ym);
          b.seisanPending += amount;
          b.seisanPendingBreakdown[cat] = (b.seisanPendingBreakdown[cat] ?? 0) + amount;
          byKey.set(key, b);
        }
      }
    }

    // 自動売上/原価/人件費: kd_dashboard_daily_summaryを月合計（対象年月＋店舗のみ）
    const yms = [...new Set([...byKey.values()].map((b) => b.year_month))];
    const storeIds = [...new Set([...byKey.values()].map((b) => b.store_id).filter((v): v is string => !!v))];
    type Auto = { sales: number; cost: number; labor: number };
    const autoByKey = new Map<string, Auto>();
    if (yms.length && storeIds.length) {
      const minYm = yms.sort()[0], maxYm = yms.sort()[yms.length - 1];
      const { data: dashRows } = await sb.from("kd_dashboard_daily_summary")
        .select("store_id,period_date,net_sales,cost,labor")
        .in("store_id", storeIds).gte("period_date", `${minYm}-01`).lt("period_date", addDays(`${maxYm}-01`, 32));
      (dashRows ?? []).forEach((r: any) => {
        const ym = String(r.period_date).slice(0, 7);
        const key = `${r.store_id}|${ym}`;
        const a = autoByKey.get(key) ?? { sales: 0, cost: 0, labor: 0 };
        a.sales += Number(r.net_sales) || 0; a.cost += Number(r.cost) || 0; a.labor += Number(r.labor) || 0;
        autoByKey.set(key, a);
      });
    }

    const upserts = [...byKey.values()].map((b) => {
      // 注意: kd_dashboard_daily_summaryはop=dashboard_dailyのmonthsパラメータ分（既定2〜3ヶ月）しか
      // 保持していないため、それより古い年月はauto=undefined（sales/cost_auto/labor_autoは全てnull
      // ＝「データが無い」を正しく表す。0円だったと誤解させない）。DB_PL手入力分（cost_manual等）は
      // 何年前でも取得できるため、古い月でもF/L/A/R/O自体は正しく集計される。
      const auto = b.store_id ? autoByKey.get(`${b.store_id}|${b.year_month}`) : undefined;
      const sales = auto ? auto.sales : null;
      const costAuto = auto ? auto.cost : null;
      const laborAuto = auto ? auto.labor : null;
      const costTotal = b.store_id && costAuto != null ? costAuto + b.cost_manual : null;
      const laborTotal = b.store_id && laborAuto != null ? laborAuto + b.labor_manual : null;
      const grossProfit = sales != null && costTotal != null ? sales - costTotal : null;
      // laborTotalがnull（自動人件費データ未保持の古い月）のときはsga自体もnullにする
      // （労務費を0円扱いで販管費計を過小表示しないため）
      const sga = laborTotal != null ? laborTotal + b.ad_manual + b.rent + b.other : null;
      const operatingProfit = sales != null && costTotal != null && sga != null ? sales - costTotal - sga : null;
      return {
        store_id: b.store_id, corporation_id: b.store_id ? corpByStoreId.get(b.store_id) ?? null : null,
        year_month: b.year_month, sales,
        cost_auto: costAuto, cost_manual: b.cost_manual, cost_total: costTotal,
        labor_auto: laborAuto, labor_manual: b.labor_manual, labor_total: laborTotal,
        ad_manual: b.ad_manual, rent: b.rent, other: b.other,
        gross_profit: grossProfit, sga, operating_profit: operatingProfit,
        pl_item_breakdown: b.breakdown,
        seisan_synced_breakdown: b.seisanSynced,
        seisan_pending_total: b.seisanPending || null,
        seisan_pending_breakdown: b.seisanPendingBreakdown,
        source_updated_at: new Date().toISOString(), computed_at: new Date().toISOString(),
        source_count: 1, sync_run_id: runId,
      };
    });
    for (let i = 0; i < upserts.length; i += 500) {
      // store_id is null（全社共通経費）はNULLを含む複合キーのためPostgRESTのupsert(onConflict)で
      // 正しく扱えず、店舗ありと分けて処理する（店舗ありはstore_id,year_monthの通常ユニーク
      // インデックスでupsert。詳細はsupabase/2026-09-06_kd_pl_media_deposit_monthly.sqlのコメント参照）。
      const withStore = upserts.slice(i, i + 500).filter((u) => u.store_id);
      const common = upserts.slice(i, i + 500).filter((u) => !u.store_id);
      if (withStore.length) {
        const { error: upErr } = await sb.from("kd_pl_monthly_summary").upsert(withStore, { onConflict: "store_id,year_month" });
        if (upErr) throw new Error("upsert失敗(店舗別): " + upErr.message);
      }
      for (const row of common) {
        // 共通経費行はstore_id is null で1年月1行。matchで既存行を探して更新、無ければ挿入。
        const { data: existing } = await sb.from("kd_pl_monthly_summary").select("id").is("store_id", null).eq("year_month", row.year_month).maybeSingle();
        if (existing) { const { error } = await sb.from("kd_pl_monthly_summary").update(row).eq("id", existing.id); if (error) throw new Error("update失敗(共通経費): " + error.message); }
        else { const { error } = await sb.from("kd_pl_monthly_summary").insert(row); if (error) throw new Error("insert失敗(共通経費): " + error.message); }
      }
    }
    for (const nm of unmatched) {
      try { await sb.rpc("kd_report_unresolved_name", { p_source_table: "kd_pl_monthly_summary", p_kind: "store", p_raw_name: nm }); }
      catch (_) { /* 隔離登録の失敗でリフレッシュ本体は止めない */ }
    }
    await finishRun(sb, runId, true, upserts.length, unmatched.size ? `店舗名未対応: ${[...unmatched].join("、")}` : undefined);
    return { ok: true, job: "pl_monthly", rows: upserts.length, unmatched: [...unmatched], sync_run_id: runId };
  } catch (e) {
    await finishRun(sb, runId, false, 0, String(e), "kd_pl_monthly_summary");
    return { ok: false, error: String(e) };
  }
}

// ============== op=media_monthly: kd_media_monthly_summary ==============
async function bqGetMediaRows(sb: any, months: number): Promise<any[][]> {
  const { id, pw } = await dashSecrets(sb);
  if (!id || !pw) throw new Error("app_secretsにdash_id/dash_pwが未設定です");
  const login = await dashCall({ action: "login", id, pw });
  if (!login.ok) throw new Error("ダッシュボードへのログインに失敗: " + (login.error ?? ""));
  const res = await dashCall({ action: "bqGetMedia", token: login.token, months: months + 1 });
  if (!res.ok) throw new Error("bqGetMedia取得に失敗: " + (res.error ?? ""));
  return (res.sheets?.media ?? res.sheets?.["媒体別"] ?? Object.values(res.sheets ?? {})[0] ?? []) as any[][];
}
async function resolveMediaName(sb: any, cache: Map<string, string>, raw: string): Promise<string> {
  if (cache.has(raw)) return cache.get(raw)!;
  const { data } = await sb.from("tpl_media_alias").select("canonical_media").eq("raw_media", raw).maybeSingle();
  // 注記③のとおりtpl_media_aliasは既知の表記ゆれ「修正表」であって全媒体名の正本ではないため、
  // 見つからない場合はstore名と違って隔離せず、そのままの表記を正規名として使う。
  const canonical = (data?.canonical_media ?? raw).trim() || raw;
  cache.set(raw, canonical);
  return canonical;
}
async function refreshMediaMonthly(sb: any, body: any) {
  const months = Math.max(1, Number(body.months) || 3);
  const runId = await startRun(sb, "kd_media_monthly_summary");
  try {
    const { idByName, corpByStoreId } = await loadStoreMaps(sb);
    const rawRows = await bqGetMediaRows(sb, months);
    const unmatched = new Set<string>();
    const aliasCache = new Map<string, string>();
    type Bucket = { store_id: string; year_month: string; media_name: string; net_sales: number; guests: number; parties: number; count: number };
    const byKey = new Map<string, Bucket>();
    for (let r = 1; r < rawRows.length; r++) {
      const row = rawRows[r];
      const storeName = String(row[0] ?? "").trim();
      const dateStr = toDateStr(row[1]);
      const mediaRaw = String(row[2] ?? "").trim() || "(不明)";
      if (!storeName || !dateStr) continue;
      const storeId = idByName.get(storeName);
      if (!storeId) { unmatched.add(storeName); continue; }
      const mediaName = await resolveMediaName(sb, aliasCache, mediaRaw);
      const ym = dateStr.slice(0, 7);
      const key = `${storeId}|${ym}|${mediaName}`;
      const b = byKey.get(key) ?? { store_id: storeId, year_month: ym, media_name: mediaName, net_sales: 0, guests: 0, parties: 0, count: 0 };
      b.net_sales += num(row[5]); b.guests += num(row[3]); b.parties += num(row[4]); b.count++;
      byKey.set(key, b);
    }
    const upserts = [...byKey.values()].map((b) => ({
      store_id: b.store_id, corporation_id: corpByStoreId.get(b.store_id) ?? null,
      year_month: b.year_month, media_name: b.media_name,
      net_sales: b.net_sales, guests: b.guests, parties: b.parties,
      source_updated_at: new Date().toISOString(), computed_at: new Date().toISOString(),
      source_count: b.count, sync_run_id: runId,
    }));
    for (let i = 0; i < upserts.length; i += 500) {
      const { error: upErr } = await sb.from("kd_media_monthly_summary").upsert(upserts.slice(i, i + 500), { onConflict: "store_id,year_month,media_name" });
      if (upErr) throw new Error("upsert失敗: " + upErr.message);
    }
    for (const nm of unmatched) {
      try { await sb.rpc("kd_report_unresolved_name", { p_source_table: "kd_media_monthly_summary", p_kind: "store", p_raw_name: nm }); }
      catch (_) { /* noop */ }
    }
    await finishRun(sb, runId, true, upserts.length, unmatched.size ? `店舗名未対応: ${[...unmatched].join("、")}` : undefined);
    return { ok: true, job: "media_monthly", rows: upserts.length, unmatched: [...unmatched], sync_run_id: runId };
  } catch (e) {
    await finishRun(sb, runId, false, 0, String(e), "kd_media_monthly_summary");
    return { ok: false, error: String(e) };
  }
}

// ============== op=deposit_monthly: kd_deposit_monthly_summary ==============
async function bqGetDepositRows(sb: any): Promise<any[][]> {
  const { id, pw } = await dashSecrets(sb);
  if (!id || !pw) throw new Error("app_secretsにdash_id/dash_pwが未設定です");
  const login = await dashCall({ action: "login", id, pw });
  if (!login.ok) throw new Error("ダッシュボードへのログインに失敗: " + (login.error ?? ""));
  const res = await dashCall({ action: "bqGetDeposit", token: login.token });
  if (!res.ok) throw new Error("bqGetDeposit取得に失敗: " + (res.error ?? ""));
  return (res.sheets?.deposit ?? []) as any[][];
}
async function refreshDepositMonthly(sb: any) {
  const runId = await startRun(sb, "kd_deposit_monthly_summary");
  try {
    const { idByName, corpByStoreId } = await loadStoreMaps(sb);
    const rawRows = await bqGetDepositRows(sb);
    const unmatched = new Set<string>();
    type Bucket = { store_id: string; year_month: string; total: number; count: number };
    const byKey = new Map<string, Bucket>();
    for (let r = 1; r < rawRows.length; r++) {
      const row = rawRows[r];
      const storeName = String(row[0] ?? "").trim();
      const dateStr = toDateStr(row[1]);
      if (!storeName || !dateStr) continue;
      const storeId = idByName.get(storeName);
      if (!storeId) { unmatched.add(storeName); continue; }
      const ym = dateStr.slice(0, 7);
      const key = `${storeId}|${ym}`;
      const b = byKey.get(key) ?? { store_id: storeId, year_month: ym, total: 0, count: 0 };
      b.total += num(row[2]); b.count++;
      byKey.set(key, b);
    }

    const yms = [...new Set([...byKey.values()].map((b) => b.year_month))];
    const storeIds = [...new Set([...byKey.values()].map((b) => b.store_id))];
    const salesByKey = new Map<string, number>();
    if (yms.length && storeIds.length) {
      const minYm = yms.sort()[0], maxYm = yms.sort()[yms.length - 1];
      const { data: dashRows } = await sb.from("kd_dashboard_daily_summary")
        .select("store_id,period_date,net_sales")
        .in("store_id", storeIds).gte("period_date", `${minYm}-01`).lt("period_date", addDays(`${maxYm}-01`, 32));
      (dashRows ?? []).forEach((r: any) => {
        const key = `${r.store_id}|${String(r.period_date).slice(0, 7)}`;
        salesByKey.set(key, (salesByKey.get(key) ?? 0) + (Number(r.net_sales) || 0));
      });
    }

    const upserts = [...byKey.values()].map((b) => {
      const salesTotal = salesByKey.get(`${b.store_id}|${b.year_month}`) ?? null;
      return {
        store_id: b.store_id, corporation_id: corpByStoreId.get(b.store_id) ?? null, year_month: b.year_month,
        deposit_total: b.total, deposit_count: b.count, sales_total: salesTotal,
        diff: salesTotal != null ? b.total - salesTotal : null,
        source_updated_at: new Date().toISOString(), computed_at: new Date().toISOString(),
        source_count: b.count, sync_run_id: runId,
      };
    });
    for (let i = 0; i < upserts.length; i += 500) {
      const { error: upErr } = await sb.from("kd_deposit_monthly_summary").upsert(upserts.slice(i, i + 500), { onConflict: "store_id,year_month" });
      if (upErr) throw new Error("upsert失敗: " + upErr.message);
    }
    for (const nm of unmatched) {
      try { await sb.rpc("kd_report_unresolved_name", { p_source_table: "kd_deposit_monthly_summary", p_kind: "store", p_raw_name: nm }); }
      catch (_) { /* noop */ }
    }
    await finishRun(sb, runId, true, upserts.length, unmatched.size ? `店舗名未対応: ${[...unmatched].join("、")}` : undefined);
    return { ok: true, job: "deposit_monthly", rows: upserts.length, unmatched: [...unmatched], sync_run_id: runId };
  } catch (e) {
    await finishRun(sb, runId, false, 0, String(e), "kd_deposit_monthly_summary");
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
    await finishRun(sb, runId, false, 0, String(e), "kd_home_kpi_snapshot");
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
      case "pl_monthly": result = await refreshPlMonthly(sb); break;
      case "media_monthly": result = await refreshMediaMonthly(sb, body); break;
      case "deposit_monthly": result = await refreshDepositMonthly(sb); break;
      default: return json({ ok: false, error: "opは'reservation_daily'|'dashboard_daily'|'home_kpi'|'unresolved_notify'|'pl_monthly'|'media_monthly'|'deposit_monthly'のいずれかが必須です" }, 400);
    }
    // 2026-09-03修正: ok:falseの結果をHTTP 200で返してしまうとGitHub Actions側のHTTP_CODEチェックを
    // すり抜けて「success」表示のまま失敗が握りつぶされる（実際にdashboard_dailyの失敗がこれで見逃されていた）。
    // 失敗時は必ず500を返す。
    return json(result, result?.ok ? 200 : 500);
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
