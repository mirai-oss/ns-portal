// W2③④+W3①+ラウンド6§1: kd_サマリ系の日次/毎時/月次リフレッシュジョブ（レーンP専任・service_role限定）
// docs/設計書_表示集計層kdと高速化実行計画_2026-09-02.md §3/§6/§10.1/§10.2-1
// docs/実装指示書_ラウンド6_2026-09-18.md §1（kd_pl毎時化・kd_store_monthly=TK-63・ds_sessions掃除）
//
// 呼び出し方: POST { op: 'reservation_daily'|'dashboard_daily'|'home_kpi'|'unresolved_notify'
//                    |'pl_monthly'|'media_monthly'|'deposit_monthly'|'store_monthly'
//                    |'sessions_cleanup' }（service_roleのみ）
//   運用: .github/workflows/keiei-kd-hourly.yml（dashboard_daily・home_kpi・store_monthly・
//        pl_monthly・sessions_cleanupを日中毎時。2026-09-18: pl_monthlyはA-12前倒し切替支援のため
//        日次から毎時に格上げ）
//        .github/workflows/keiei-perflog-daily.yml（reservation_daily・unresolved_notify・
//        media_monthly・deposit_monthlyを日次実行のまま）
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

// PostgRESTは1リクエスト最大1000行で「無言に」打ち切る。集計の元データ読み出しは必ずこれでページングして全件読む。
// （2026-10-03: 未ページングのままkd_store_monthly/kd_pl_monthly/kd_deposit_monthlyが日次テーブルを
// 先頭1000行だけで集計していた＝売上・原価・人件費が過少になる欠陥を修正。順序は(period_date,store_id)等
// ユニークな組で固定すること＝ページ間で重複・欠落しない）
async function fetchAll(build: (from: number, to: number) => PromiseLike<{ data: any[] | null; error: any }>, pageSize = 1000, maxRows = 300000): Promise<any[]> {
  const out: any[] = [];
  for (let offset = 0; offset < maxRows; offset += pageSize) {
    const { data, error } = await build(offset, offset + pageSize - 1);
    if (error) throw new Error(error.message ?? String(error));
    if (!data || !data.length) break;
    out.push(...data);
    if (data.length < pageSize) break;
  }
  return out;
}

// 洗い替え（2026-10-03）: 派生テーブル(kd_)は毎回「元データの今の姿」で作り直すのが正。元データから消えた行
// （例: DB_PLの経費行が精算書同期で置き換わった月）が古い数字のまま残らないよう、今回のrunで書かれなかった行を削除する。
// 安全装置: 古い行が今回の行数の半分を超えるときは、取得の不調・部分応答の可能性があるため削除せず警告だけ返す。
async function sweepStale(sb: any, table: string, runId: string, newCount: number): Promise<{ deleted: number; skipped?: string }> {
  const { count: staleCount, error: cErr } = await sb.from(table).select("id", { count: "exact", head: true })
    .or(`sync_run_id.is.null,sync_run_id.neq.${runId}`);
  if (cErr) return { deleted: 0, skipped: "count失敗: " + cErr.message };
  if (!staleCount) return { deleted: 0 };
  if (newCount < 10 || staleCount > newCount * 0.5) return { deleted: 0, skipped: `古い行${staleCount}件が今回${newCount}件の半分超のため削除せず（取得の部分応答の疑い）` };
  const { error: dErr } = await sb.from(table).delete().or(`sync_run_id.is.null,sync_run_id.neq.${runId}`);
  if (dErr) return { deleted: 0, skipped: "delete失敗: " + dErr.message };
  return { deleted: staleCount };
}

async function startRun(sb: any, job: string, periodFrom?: string, periodTo?: string) {
  // 2026-10-03追加: Edge Function側のタイムアウト等で強制終了されると finishRun が呼ばれず、
  // kd_sync_runs に 'running' のまま永久に残る（長期バックフィルで実際に発生）。同じjobの古い
  // 'running'（15分超）は打ち切られたものとして failed に確定させる（鮮度表示が「更新中」のまま固まらないように）。
  try {
    await sb.from("kd_sync_runs").update({
      status: "failed", finished_at: new Date().toISOString(),
      error: "実行が途中で打ち切られました（Edge Functionのタイムアウト等）",
    }).eq("job", job).eq("status", "running").lt("started_at", new Date(Date.now() - 15 * 60000).toISOString());
  } catch (_) { /* 掃除の失敗で本処理は止めない */ }
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

// 店舗名の表記ゆれ吸収用の正規化: 全角/半角の括弧・スペースを揃える（「鳥一代（本店）」→「鳥一代 本店」）
function normStoreName(s: string): string {
  return String(s ?? "").replace(/[（(]/g, " ").replace(/[）)]/g, " ").replace(/[\u3000\s]+/g, " ").trim();
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
  // 店舗名ゲートウェイ(store_aliases): kind='name'=同一店舗の別表記→idByNameへ。kind='listing'=2枚看板等の別掲載名
  // →listingByName（親店舗のidを返し、看板名は呼び出し側がbrandとして保持する）
  const listingByName = new Map<string, string>();
  const { data: aliasRows } = await sb.from("store_aliases").select("alias,store_id,kind");
  (aliasRows ?? []).forEach((a: any) => {
    const al = String(a.alias ?? "").trim(); if (!al || !a.store_id) return;
    if (a.kind === "listing") listingByName.set(al, a.store_id);
    else if (!idByName.has(al)) idByName.set(al, a.store_id);
  });
  return { idByName, corpByStoreId, listingByName };
}
// 生の名前→正規化した名前の順に引く。見つからなければnull（呼び出し側がkd_unresolved_namesへ隔離）
function lookupStore(maps: { idByName: Map<string, string>; listingByName: Map<string, string> }, raw: string): { store_id: string; brand: string } | null {
  const r = String(raw ?? "").trim(); const n = normStoreName(r);
  const id = maps.idByName.get(r) ?? maps.idByName.get(n);
  if (id) return { store_id: id, brand: "" };
  const lid = maps.listingByName.get(r) ?? maps.listingByName.get(n);
  if (lid) return { store_id: lid, brand: n };
  return null;
}

// ============== op=reservation_daily: kd_reservation_daily_summary ==============
async function refreshReservationDaily(sb: any, body: any) {
  const from = typeof body.from === "string" ? body.from : addDays(jstToday(), -1); // 既定=前日分（当日分の後追い変化も拾うため翌回で上書きされる）
  const to = typeof body.to === "string" ? body.to : jstToday();
  const runId = await startRun(sb, "kd_reservation_daily_summary", from, to);
  try {
    const { corpByStoreId } = await loadStoreMaps(sb);
    // 2026-10-03修正: PostgRESTは1リクエスト最大1000行で打ち切るため、過去分のバックフィル
    // （from/to指定で数万行）では無言で欠落する。visit_date,idの安定順でページングして全件読む。
    // （既定の「前日〜当日」だけなら従来どおり1ページで済む）
    const data: any[] = [];
    const PAGE = 1000;
    for (let offset = 0; offset < 400000; offset += PAGE) {
      const { data: page, error: pageErr } = await sb.from("rsv_reservations")
        .select("store_id,visit_date,visit_time,party_size,status_normalized,channel_raw,created_at_source,imported_at,store_account")
        .gte("visit_date", from).lte("visit_date", to)
        .not("store_account", "in", `(${EXCLUDE_ACCOUNTS_TEMP.map((n) => `"${n}"`).join(",")})`)
        .order("visit_date", { ascending: true }).order("id", { ascending: true })
        .range(offset, offset + PAGE - 1);
      if (pageErr) throw new Error(pageErr.message);
      if (!page || !page.length) break;
      data.push(...page);
      if (page.length < PAGE) break;
    }

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
// 2026-09-18追加（ラウンド6§1・実装指示書の背景記述より）: GAS Webアプリは一時的にGoogleの
// ボット判定ページ（HTML・404/405相当）を返すことがあると担当Aが特定・対症療法済み（tori-dashboard
// 側のsupalogin等にリトライを追加）。keiei-kd-refresh側も同じDASH_API_URLへログイン経由で呼んでおり、
// 実際に直近24時間でdashboard_dailyが3/17回この症状で失敗していた（kd_sync_runsで確認）。
// 毎時リフレッシュなので次の回で自然に復旧するとはいえ、担当A側の対策と同じ考え方で軽いリトライを
// 入れておく（最大3回・指数バックオフ）。JSON以外（HTML等）が返ってきた回だけ再試行し、
// 正常なJSONエラー応答（{ok:false,error:...}）は再試行しない（無限ループ防止・本当のエラーを隠さない）。
async function dashCall(body: unknown, attempt = 1): Promise<any> {
  const res = await fetch(DASH_API_URL, {
    method: "POST", headers: { "Content-Type": "text/plain;charset=utf-8" }, body: JSON.stringify(body),
  });
  const text = await res.text();
  try {
    return JSON.parse(text);
  } catch (_) {
    if (attempt < 3) {
      await new Promise((r) => setTimeout(r, attempt * 1500)); // 1.5秒→3秒
      return dashCall(body, attempt + 1);
    }
    return { ok: false, error: `ダッシュボードの応答を読めませんでした（${attempt}回試行・Googleボット判定等の一時的な不調の可能性）: ` + text.slice(0, 200) };
  }
}
// ---- GASログインの使い回し（2026-10-03・ラウンド6§7 P① 実測で発覚した不具合の修正）----
// 従来は各opが毎回action:'login'を呼んでいたため、連携用アカウント(dash_id)のセッションが
// 1日約48件×14日=約670件ds_sessionsに溜まっていた（毎時×3op。GAS側のPropertiesServiceにも
// tok_*が二重書きされるため、設計書§2-4「tok_が溜まって満杯→セッション切れ」の一因になっていた）。
// 本来セッションは14日のスライディング期限なので、1つを使い回せば足りる。トークンはapp_secrets
// (service_role専用・dash_pwと同じ置き場)に保存し、unauthorizedが返った時だけ取り直す。
const DASH_TOKEN_KEY = "kd_refresh_dash_token";
let dashTokenMemo: string | null = null; // 同一isolate内の再利用（app_secrets読み出しも省く）
async function dashLoginAndStore(sb: any): Promise<string> {
  const { id, pw } = await dashSecrets(sb);
  if (!id || !pw) throw new Error("app_secretsにdash_id/dash_pwが未設定です");
  const login = await dashCall({ action: "login", id, pw });
  if (!login.ok || !login.token) throw new Error("ダッシュボードへのログインに失敗: " + (login.error ?? ""));
  await sb.from("app_secrets").upsert({ key: DASH_TOKEN_KEY, value: login.token, updated_at: new Date().toISOString() }, { onConflict: "key" });
  dashTokenMemo = login.token;
  return login.token;
}
async function dashAuthed(sb: any, action: string, extra: Record<string, unknown> = {}): Promise<any> {
  let token = dashTokenMemo;
  if (!token) {
    const { data } = await sb.from("app_secrets").select("value").eq("key", DASH_TOKEN_KEY).maybeSingle();
    token = (data?.value ?? "").trim() || null;
  }
  if (!token) token = await dashLoginAndStore(sb);
  const isUnauth = (r: any) => r && r.ok === false && /unauthorized/i.test(String(r.error ?? ""));
  let res = await dashCall({ action, token, ...extra });
  if (isUnauth(res)) {
    // 2026-10-03実測: 発行直後の有効なセッションでもunauthorizedが返ることがある。GAS側sessionGet_が
    // Supabase読み取りの一時失敗(非200/例外)を「セッション無し」と同じnull扱いにし、Properties側が
    // 掃除済みだとunauthorizedになるため（tori-dashboard gas/Code.gs sessionSupaGet_/sessionGet）。
    // そこで①同じトークンを2秒後に1回だけ再試行 ②それでもダメなら取り直し（無駄なセッション量産を避ける）
    await new Promise((r) => setTimeout(r, 2000));
    res = await dashCall({ action, token, ...extra });
    if (isUnauth(res)) {
      token = await dashLoginAndStore(sb);
      res = await dashCall({ action, token, ...extra });
    }
  }
  return res;
}

async function bqDailyStoreFull(sb: any, months: number) {
  const res = await dashAuthed(sb, "bqDailyStore", { months: months + 1 });
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
    type Row = {
      store_id: string; period_date: string; net_sales: number; guests: number; parties: number;
      cost: number; labor: number; labor_pa: number; labor_emp: number;
      cash: number; employee_salary_bonus: number; statutory_welfare: number; commute_allowance: number;
    };
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
      // 2026-09-06追加: cost(cogs=row[7])/labor(labor_total=row[6])。2026-09-18追加: labor_pa(row[4])/
      // labor_emp(row[5])——kd_store_monthly_summary(TK-63)のF率/L率カード用の内訳（既に取得していたのに
      // 保存していなかった列。cost/laborと同じ経緯）。
      parsed.push({
        store_id: storeId, period_date: dateStr, net_sales: num(row[2]), guests: num(row[3]), parties: num(row[12]),
        cost: num(row[7]), labor: num(row[6]), labor_pa: num(row[4]), labor_emp: num(row[5]),
        // 2026-10-05追加（F2・依頼_レーンP_経営D_F2用kd追加 #1）: 現金売上・社員給与賞与・法定福利・通勤手当（fact_daily_store互換）
        cash: num(row[8]), employee_salary_bonus: num(row[9]), statutory_welfare: num(row[10]), commute_allowance: num(row[11]),
      });
    }

    // 前年同曜日比較: 同じ店舗の364日前（同曜日）の行を自テーブルから引く（蓄積が浅いうちはnullのまま）
    const priorDates = [...new Set(parsed.map((p) => addDays(p.period_date, -364)))];
    const storeIds = [...new Set(parsed.map((p) => p.store_id))];
    const priorMap = new Map<string, number>();
    if (priorDates.length && storeIds.length) {
      const priorRows: any[] = [];
      for (let i = 0; i < priorDates.length; i += 60) {   // URLが長くなりすぎないよう日付は60件ずつ
        const chunk = priorDates.slice(i, i + 60);
        priorRows.push(...await fetchAll((f, t) => sb.from("kd_dashboard_daily_summary")
          .select("store_id,period_date,net_sales").in("store_id", storeIds).in("period_date", chunk)
          .order("period_date").order("store_id").range(f, t)));
      }
      priorRows.forEach((r: any) => priorMap.set(`${r.store_id}|${r.period_date}`, Number(r.net_sales) || 0));
    }

    const upserts = parsed.map((p) => {
      const priorDate = addDays(p.period_date, -364);
      const priorSales = priorMap.get(`${p.store_id}|${priorDate}`);
      return {
        store_id: p.store_id, corporation_id: corpByStoreId.get(p.store_id) ?? null, period_date: p.period_date,
        net_sales: p.net_sales, guests: p.guests, parties: p.parties, cost: p.cost, labor: p.labor,
        labor_pa: p.labor_pa, labor_emp: p.labor_emp,
        cash: p.cash, employee_salary_bonus: p.employee_salary_bonus, statutory_welfare: p.statutory_welfare, commute_allowance: p.commute_allowance,
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

// ============== op=store_monthly: kd_store_monthly_summary（TK-63・2026-09-18） ==============
async function bqGetSpotRows(sb: any): Promise<any[][]> {
  const res = await dashAuthed(sb, "bqGetSpot");
  if (!res.ok) throw new Error("bqGetSpot取得に失敗: " + (res.error ?? ""));
  return (res.sheets?.["スポット人件費"] ?? Object.values(res.sheets ?? {})[0] ?? []) as any[][];
}

async function refreshStoreMonthly(sb: any) {
  const runId = await startRun(sb, "kd_store_monthly_summary");
  try {
    const { idByName, corpByStoreId } = await loadStoreMaps(sb);

    // ①売上/原価/PA/社員人件費: kd_dashboard_daily_summaryの月合計（dashboard_dailyのmonths窓の範囲内のみ）
    const dashRows = await fetchAll((f, t) => sb.from("kd_dashboard_daily_summary")
      .select("store_id,period_date,net_sales,cost,labor,labor_pa,labor_emp")
      .order("period_date").order("store_id").range(f, t));
    type Bucket = {
      store_id: string; year_month: string; sales: number; cost: number; labor: number; labor_pa: number; labor_emp: number; labor_spot: number;
    };
    const byKey = new Map<string, Bucket>();
    for (const r of (dashRows ?? []) as any[]) {
      const ym = String(r.period_date).slice(0, 7);
      const key = `${r.store_id}|${ym}`;
      const b = byKey.get(key) ?? { store_id: r.store_id, year_month: ym, sales: 0, cost: 0, labor: 0, labor_pa: 0, labor_emp: 0, labor_spot: 0 };
      b.sales += Number(r.net_sales) || 0; b.cost += Number(r.cost) || 0; b.labor += Number(r.labor) || 0;
      b.labor_pa += Number(r.labor_pa) || 0; b.labor_emp += Number(r.labor_emp) || 0;
      byKey.set(key, b);
    }

    // ②スポット人件費（stg_spot・bqGetSpot経由）を月合計してマージ
    const unmatched = new Set<string>();
    const spotRows = await bqGetSpotRows(sb);
    // 列: 日付,店舗名,区分,金額,人数,メモ,入力者,入力日時,ID（tori-dashboard/gas/Code.gs:2601 bqGetSpot参照）
    for (let r = 1; r < spotRows.length; r++) {
      const row = spotRows[r];
      const storeName = String(row[1] ?? "").trim();
      const dateStr = toDateStr(row[0]);
      if (!storeName || !dateStr) continue;
      const storeId = idByName.get(storeName);
      if (!storeId) { unmatched.add(storeName); continue; }
      const ym = dateStr.slice(0, 7);
      const key = `${storeId}|${ym}`;
      const b = byKey.get(key) ?? { store_id: storeId, year_month: ym, sales: 0, cost: 0, labor: 0, labor_pa: 0, labor_emp: 0, labor_spot: 0 };
      b.labor_spot += num(row[3]);
      byKey.set(key, b);
    }

    // ③売上目標: dash_sales_target_dailyの月合計
    const yms = [...new Set([...byKey.values()].map((b) => b.year_month))];
    const storeIds = [...new Set([...byKey.values()].map((b) => b.store_id))];
    const budgetByKey = new Map<string, number>();
    if (yms.length && storeIds.length) {
      const minYm = yms.sort()[0], maxYm = yms.sort()[yms.length - 1];
      const targetRows = await fetchAll((f, t) => sb.from("dash_sales_target_daily")
        .select("store_id,biz_date,sales_target")
        .in("store_id", storeIds).gte("biz_date", `${minYm}-01`).lt("biz_date", addDays(`${maxYm}-01`, 32))
        .order("biz_date").order("store_id").range(f, t));
      targetRows.forEach((r: any) => {
        const key = `${r.store_id}|${String(r.biz_date).slice(0, 7)}`;
        budgetByKey.set(key, (budgetByKey.get(key) ?? 0) + (Number(r.sales_target) || 0));
      });
    }

    const upserts = [...byKey.values()].map((b) => {
      // 人件費合計はapp.js stat()と同じ定義＝fact_daily_store.labor_cost_total(日次のlabor列の和)+スポット。
      // PA+社員の和ではない（API切替前の月は賞与・法定福利・通勤手当等を含むため和の2倍超になる月がある）。
      const laborTotal = b.labor + b.labor_spot;
      const costRate = b.sales ? b.cost / b.sales : null;
      const laborRate = b.sales ? laborTotal / b.sales : null;
      const budgetSales = budgetByKey.get(`${b.store_id}|${b.year_month}`) ?? null;
      return {
        store_id: b.store_id, corporation_id: corpByStoreId.get(b.store_id) ?? null, year_month: b.year_month,
        sales: b.sales, cost: b.cost, cost_rate: costRate,
        labor_pa: b.labor_pa, labor_emp: b.labor_emp, labor_other: b.labor - b.labor_pa - b.labor_emp, labor_spot: b.labor_spot, labor_total: laborTotal, labor_rate: laborRate,
        fl_rate: costRate != null && laborRate != null ? costRate + laborRate : null,
        gross_profit: b.sales - b.cost,
        budget_sales: budgetSales, budget_diff: budgetSales != null ? b.sales - budgetSales : null,
        budget_rate: budgetSales ? b.sales / budgetSales : null,
        source_updated_at: new Date().toISOString(), computed_at: new Date().toISOString(),
        source_count: 1, sync_run_id: runId,
      };
    });
    for (let i = 0; i < upserts.length; i += 500) {
      const { error: upErr } = await sb.from("kd_store_monthly_summary").upsert(upserts.slice(i, i + 500), { onConflict: "store_id,year_month" });
      if (upErr) throw new Error("upsert失敗: " + upErr.message);
    }
    for (const nm of unmatched) {
      try { await sb.rpc("kd_report_unresolved_name", { p_source_table: "kd_store_monthly_summary", p_kind: "store", p_raw_name: nm }); }
      catch (_) { /* noop */ }
    }
    await finishRun(sb, runId, true, upserts.length, unmatched.size ? `店舗名未対応: ${[...unmatched].join("、")}` : undefined);
    return { ok: true, job: "store_monthly", rows: upserts.length, unmatched: [...unmatched], sync_run_id: runId };
  } catch (e) {
    await finishRun(sb, runId, false, 0, String(e), "kd_store_monthly_summary");
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
  const res = await dashAuthed(sb, "bqGetPL");
  if (!res.ok) throw new Error("bqGetPL取得に失敗: " + (res.error ?? ""));
  return (res.sheets?.PL ?? []) as any[][];
}
// 年月セルの揺れ吸収（"2026/09"・"2026-09"・"2026/9/1"・Date型セルのtoString "Tue Sep 01 2026 00:00:00 GMT+0900 ..."）。
// stg_loan_principal.year_monthはSTRINGで、シートのDateセルがそのまま文字列化されることがある（9/2にfact_daily_storeで
// 発生したのと同種）ため、単純な先頭7文字では拾えない。
function ymOf(v: unknown): string | null {
  const s = String(v ?? "").trim();
  const m = s.match(/^(\d{4})\s*[年\/\-\.]\s*(\d{1,2})/);
  if (m) return `${m[1]}-${m[2].padStart(2, "0")}`;
  const d = new Date(s);
  if (isNaN(d.getTime())) return null;
  return new Date(d.getTime() + 9 * 3600 * 1000).toISOString().slice(0, 7);
}
// 借入返済元金（stg_loan_principal）。列: 年月,店舗,法人,元金額,メモ（tori-dashboard/gas/Code.gs bqGetLoanPrincipal）
async function bqGetLoanRows(sb: any): Promise<any[][]> {
  const res = await dashAuthed(sb, "bqGetLoanPrincipal");
  if (!res.ok) throw new Error("bqGetLoanPrincipal取得に失敗: " + (res.error ?? ""));
  return (res.sheets?.["借入返済元金"] ?? Object.values(res.sheets ?? {})[0] ?? []) as any[][];
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
      loan: number; // 借入返済元金（PL費用ではない・後段で合流）
    };
    const newBucket = (storeId: string | null, ym: string): Bucket => ({
      store_id: storeId, year_month: ym, cost_manual: 0, labor_manual: 0, ad_manual: 0, rent: 0, other: 0,
      breakdown: {}, seisanSynced: {}, seisanPending: 0, seisanPendingBreakdown: {}, loan: 0,
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

    // 借入返済元金（2026-10-03追加・F2。簡易CFの返済元金欄をkd_で持つため）。取得に失敗したらこの列だけ
    // 更新しない（0で上書きして誤った数字にしない）。PL本体の更新は止めない。
    let loanOk = true; let loanRowCount = 0; let loanBadYm = 0; const loanSample: string[] = [];
    try {
      const loanRows = await bqGetLoanRows(sb);
      loanRowCount = Math.max(0, loanRows.length - 1);
      for (let r = 1; r < loanRows.length; r++) {
        const row = loanRows[r];
        if (loanSample.length < 3) loanSample.push(String(row[0]).slice(0, 40));
        const ym = ymOf(row[0]);
        if (!ym) { loanBadYm++; continue; }
        const storeName = String(row[1] ?? "").trim();
        const amount = num(row[3]);
        let storeId: string | null = null;
        if (storeName) {
          storeId = idByName.get(storeName) ?? null;
          if (!storeId) { unmatched.add(storeName); continue; }
        }
        const key = `${storeId ?? COMMON_STORE_KEY}|${ym}`;
        const b = byKey.get(key) ?? newBucket(storeId, ym);
        b.loan += amount;
        byKey.set(key, b);
      }
    } catch (_) { loanOk = false; }

    // 自動売上/原価/人件費: kd_dashboard_daily_summaryを月合計。
    // 2026-10-03変更: 以前は「DB_PLに行がある店舗×月」だけを対象にしていたため、(1)DB_PL行の無い店舗×月
    // （売上はあるが手入力経費が無い月）にkd_plの行自体が作られず、(2)DB_PLから行が消えた店舗×月は
    // 古い数字のまま残り続けた。日次データがある店舗×月は必ず行を作る（手入力0円として）。
    type Auto = { sales: number; cost: number; labor: number };
    const autoByKey = new Map<string, Auto>();
    const dashRows = await fetchAll((f, t) => sb.from("kd_dashboard_daily_summary")
      .select("store_id,period_date,net_sales,cost,labor")
      .order("period_date").order("store_id").range(f, t));
    dashRows.forEach((r: any) => {
      const ym = String(r.period_date).slice(0, 7);
      const key = `${r.store_id}|${ym}`;
      const a = autoByKey.get(key) ?? { sales: 0, cost: 0, labor: 0 };
      a.sales += Number(r.net_sales) || 0; a.cost += Number(r.cost) || 0; a.labor += Number(r.labor) || 0;
      autoByKey.set(key, a);
      if (!byKey.has(key)) byKey.set(key, newBucket(r.store_id, ym));
    });

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
        ...(loanOk ? { loan_principal: b.loan || null } : {}),
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
    const sweep = await sweepStale(sb, "kd_pl_monthly_summary", runId, upserts.length);
    for (const nm of unmatched) {
      try { await sb.rpc("kd_report_unresolved_name", { p_source_table: "kd_pl_monthly_summary", p_kind: "store", p_raw_name: nm }); }
      catch (_) { /* 隔離登録の失敗でリフレッシュ本体は止めない */ }
    }
    const plNote = [unmatched.size ? `店舗名未対応: ${[...unmatched].join("、")}` : "", sweep.deleted ? `古い行${sweep.deleted}件を洗い替え削除` : "", sweep.skipped ? `洗い替え見送り: ${sweep.skipped}` : "", loanOk ? "" : "借入元金の取得に失敗(列は更新せず)"].filter(Boolean).join(" / ");
    await finishRun(sb, runId, true, upserts.length, plNote || undefined);
    return { ok: true, job: "pl_monthly", rows: upserts.length, unmatched: [...unmatched], swept: sweep, loan_ok: loanOk, loan_rows: loanRowCount, loan_bad_ym: loanBadYm, loan_ym_sample: loanSample, sync_run_id: runId };
  } catch (e) {
    await finishRun(sb, runId, false, 0, String(e), "kd_pl_monthly_summary");
    return { ok: false, error: String(e) };
  }
}

// ============== op=media_monthly: kd_media_monthly_summary ==============
async function bqGetMediaRows(sb: any, months: number): Promise<any[][]> {
  const res = await dashAuthed(sb, "bqGetMedia", { months: months + 1 });
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
  const res = await dashAuthed(sb, "bqGetDeposit");
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
    // 2026-10-05追加（F2 #2）: 店舗×日の入金（kd_deposit_daily）。明細(金額・メモ)もjsonbで持つ
    type DayBucket = { store_id: string; deposit_date: string; amount: number; count: number; entries: { a: number; m: string }[] };
    const dayMap = new Map<string, DayBucket>();
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
      const dk = `${storeId}|${dateStr}`;
      const db = dayMap.get(dk) ?? { store_id: storeId, deposit_date: dateStr, amount: 0, count: 0, entries: [] };
      db.amount += num(row[2]); db.count++;
      if (db.entries.length < 50) db.entries.push({ a: num(row[2]), m: String(row[3] ?? "").slice(0, 80) });
      dayMap.set(dk, db);
    }

    const yms = [...new Set([...byKey.values()].map((b) => b.year_month))];
    const storeIds = [...new Set([...byKey.values()].map((b) => b.store_id))];
    const salesByKey = new Map<string, number>();
    if (yms.length && storeIds.length) {
      const minYm = yms.sort()[0], maxYm = yms.sort()[yms.length - 1];
      const dashRows = await fetchAll((f, t) => sb.from("kd_dashboard_daily_summary")
        .select("store_id,period_date,net_sales")
        .in("store_id", storeIds).gte("period_date", `${minYm}-01`).lt("period_date", addDays(`${maxYm}-01`, 32))
        .order("period_date").order("store_id").range(f, t));
      dashRows.forEach((r: any) => {
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
    const dayUpserts = [...dayMap.values()].map((d) => ({
      store_id: d.store_id, corporation_id: corpByStoreId.get(d.store_id) ?? null, deposit_date: d.deposit_date,
      amount: d.amount, deposit_count: d.count, entries: d.entries,
      source_updated_at: new Date().toISOString(), computed_at: new Date().toISOString(), source_count: d.count, sync_run_id: runId,
    }));
    for (let i = 0; i < dayUpserts.length; i += 500) {
      const { error: upErr } = await sb.from("kd_deposit_daily").upsert(dayUpserts.slice(i, i + 500), { onConflict: "store_id,deposit_date" });
      if (upErr) throw new Error("upsert失敗(日次): " + upErr.message);
    }
    // 入金DBから消えた行（重複削除・取消等）は古い数字のまま残さない（洗い替え・安全装置付き）
    const sweepM = await sweepStale(sb, "kd_deposit_monthly_summary", runId, upserts.length);
    const sweepD = await sweepStale(sb, "kd_deposit_daily", runId, dayUpserts.length);
    for (const nm of unmatched) {
      try { await sb.rpc("kd_report_unresolved_name", { p_source_table: "kd_deposit_monthly_summary", p_kind: "store", p_raw_name: nm }); }
      catch (_) { /* noop */ }
    }
    const note = [unmatched.size ? `店舗名未対応: ${[...unmatched].join("、")}` : "", sweepM.deleted || sweepD.deleted ? `古い行を洗い替え削除(月次${sweepM.deleted}/日次${sweepD.deleted})` : "", sweepM.skipped ? `月次洗い替え見送り: ${sweepM.skipped}` : "", sweepD.skipped ? `日次洗い替え見送り: ${sweepD.skipped}` : ""].filter(Boolean).join(" / ");
    await finishRun(sb, runId, true, upserts.length, note || undefined);
    return { ok: true, job: "deposit_monthly", rows: upserts.length, daily_rows: dayUpserts.length, unmatched: [...unmatched], swept: { monthly: sweepM, daily: sweepD }, sync_run_id: runId };
  } catch (e) {
    await finishRun(sb, runId, false, 0, String(e), "kd_deposit_monthly_summary");
    return { ok: false, error: String(e) };
  }
}

// ============== op=ad_monthly: kd_ad_monthly（F2 #3・2026-10-05） ==============
// 3つの元データを店舗×媒体×月に合成する（app.jsのingestAd/ingestAdFx/ingestAdExcludeと同じ解釈）:
//  ①広告費DB=stg_ad_cost（BQミラー。GAS bqGetAdCost・BQ_LOAD_TOKEN認証・ログイン不要）
//  ②広告効果シート（アクセス/ネット予約/電話/総売上/集客手数料。GAS action:data の keys 指定で当該シートだけ取得）
//  ③広告除外設定シート（店舗×月。PLの「媒体販促費(自動)」をゼロ扱いにする月）
// ②③の取得（action:data）が失敗しても①は更新する（失敗した側の列は更新せず前回値を残す・洗い替えも見送る）。
// 注意: app.jsの広告費DBは「確認」列が使われている時だけ確認済み行に絞る仕様。stg_ad_costのミラーが同じ絞り込みを
// しているかは未検証＝担当Aの新旧突合で差異があれば報告されたい。
const colOf = (H: string[], kw: string) => H.findIndex((h) => String(h).indexOf(kw) >= 0);
const colAny = (H: string[], kws: string[]) => { for (const kw of kws) { const i = colOf(H, kw); if (i >= 0) return i; } return -1; };

async function bqGetAdCostRows(): Promise<any[][]> {
  const tk = Deno.env.get("BQ_LOAD_TOKEN");
  if (!tk) throw new Error("BQ_LOAD_TOKENが未設定です（Supabaseのシークレット）");
  const url = new URL(DASH_API_URL);
  url.searchParams.set("action", "bqGetAdCost"); url.searchParams.set("token", tk);
  let lastText = "";
  for (let attempt = 1; attempt <= 3; attempt++) {
    const res = await fetch(url.toString());
    lastText = await res.text();
    let j: any = null;
    try { j = JSON.parse(lastText); } catch (_) { /* GASの一時不調(HTML)→再試行 */ }
    if (j) {
      if (!j.ok) throw new Error("bqGetAdCost取得に失敗: " + (j.error ?? ""));
      return (j.sheets?.["広告費"] ?? Object.values(j.sheets ?? {})[0] ?? []) as any[][];
    }
    if (attempt < 3) await new Promise((r) => setTimeout(r, attempt * 1500));
  }
  throw new Error("bqGetAdCostの応答を読めませんでした: " + lastText.slice(0, 120));
}

async function refreshAdMonthly(sb: any) {
  const runId = await startRun(sb, "kd_ad_monthly");
  try {
    const maps = await loadStoreMaps(sb);
    const { corpByStoreId } = maps;
    const unmatched = new Set<string>();
    const aliasCache = new Map<string, string>();
    type Fx = { access: number; net_groups: number; net_people: number; tel: number; tGrp: number; tPpl: number; tSales: number; fee: number };
    type B = { store_id: string; ym: string; media: string; brand: string; cost: number | null; plan: Record<string, number>; fx: Fx | null; n: number };
    const byKey = new Map<string, B>();
    const getB = (storeId: string, ym: string, media: string, brand = ""): B => {
      const key = `${storeId}|${ym}|${media}|${brand}`;
      let b = byKey.get(key);
      if (!b) { b = { store_id: storeId, ym, media, brand, cost: null, plan: {}, fx: null, n: 0 }; byKey.set(key, b); }
      return b;
    };

    // ① 広告費
    const adRows = await bqGetAdCostRows();
    let noStore = 0;
    for (let r = 1; r < adRows.length; r++) {
      const row = adRows[r];
      const ym = ymOf(row[0]); const storeName = String(row[1] ?? "").trim();
      if (!ym) continue;
      if (!storeName) { noStore++; continue; }            // 店舗未指定(全体)の広告費は店舗キーを持てないため対象外(件数のみ報告)
      const hit = lookupStore(maps, storeName);
      if (!hit) { unmatched.add(storeName); continue; }
      const media = await resolveMediaName(sb, aliasCache, String(row[2] ?? "").trim() || "（媒体未指定）");
      const b = getB(hit.store_id, ym, media, hit.brand);
      const amt = num(row[4]);
      b.cost = (b.cost ?? 0) + amt; b.n++;
      const plan = String(row[3] ?? "").trim();
      if (plan) b.plan[plan] = (b.plan[plan] ?? 0) + amt;
    }

    // ② 広告効果 ③ 広告除外設定（action:data でこの2シートだけ）
    let fxOk = false, exclOk = false; const excluded = new Set<string>();
    let fxErr = "";
    try {
      const res = await dashAuthed(sb, "data", { keys: "広告効果,広告除外設定" });
      if (!res.ok) throw new Error(res.error ?? "data取得失敗");
      const fxSheet: any[][] | undefined = res.sheets?.["広告効果"];
      const exSheet: any[][] | undefined = res.sheets?.["広告除外設定"];
      if (fxSheet && fxSheet.length) {
        let hi = -1;
        for (let i = 0; i < Math.min(fxSheet.length, 12); i++) {
          const line = fxSheet[i].map((x: unknown) => String(x ?? "")).join(",");
          if (/アクセス/.test(line) && /予約|組数/.test(line)) { hi = i; break; }
        }
        if (hi < 0) hi = 0;
        const H = fxSheet[hi].map((h: unknown) => String(h).trim());
        const iD = colAny(H, ["年月", "日付"]), iS = colOf(H, "店舗"), iM = colOf(H, "媒体"), iA = colOf(H, "アクセス");
        const iG = colAny(H, ["ネット予約組数", "予約組数", "NET件数", "NET組数", "ネット予約件数", "予約件数", "組数"]);
        let iP = colAny(H, ["ネット予約人数", "予約人数", "NET人数"]); if (iP < 0) { const x = colOf(H, "人数"); if (x >= 0 && x !== iG) iP = x; }
        const iT = colAny(H, ["電話数", "電話"]), iTG = colAny(H, ["総組数"]), iTP = colAny(H, ["総人数"]), iTS = colAny(H, ["総売上"]), iFee = colAny(H, ["集客手数料"]);
        if (iD >= 0 && (iA >= 0 || iG >= 0)) {
          for (let i = hi + 1; i < fxSheet.length; i++) {
            const c = fxSheet[i];
            const ym = ymOf(c[iD]); if (!ym) continue;
            const g = (ix: number) => ix >= 0 ? num(c[ix]) : 0;
            const fx: Fx = { access: g(iA), net_groups: g(iG), net_people: g(iP), tel: g(iT), tGrp: g(iTG), tPpl: g(iTP), tSales: g(iTS), fee: g(iFee) };
            if (!Object.values(fx).some((v) => v)) continue;
            const storeName = String(iS >= 0 ? c[iS] ?? "" : "").trim();
            if (!storeName) continue;
            const hit = lookupStore(maps, storeName);
            if (!hit) { unmatched.add(storeName); continue; }
            const media = await resolveMediaName(sb, aliasCache, String(iM >= 0 ? c[iM] ?? "" : "").trim() || "（媒体未指定）");
            const b = getB(hit.store_id, ym, media, hit.brand);
            const cur = b.fx ?? { access: 0, net_groups: 0, net_people: 0, tel: 0, tGrp: 0, tPpl: 0, tSales: 0, fee: 0 };
            (Object.keys(cur) as (keyof Fx)[]).forEach((k) => { cur[k] += fx[k]; });
            b.fx = cur;
          }
          fxOk = true;
        } else fxErr = "広告効果シートの列を読めません";
      } else fxOk = true; // シートが空/未配信＝広告効果なし（前回値は消す）
      if (exSheet) {
        for (let i = 1; i < exSheet.length; i++) {
          const c = exSheet[i]; const storeName = String(c[1] ?? "").trim(); const ym = ymOf(c[0]);
          if (!storeName || !ym) continue;
          const hit = lookupStore(maps, storeName);
          if (!hit) { unmatched.add(storeName); continue; }
          excluded.add(`${hit.store_id}|${ym}`);
        }
      }
      exclOk = true;
    } catch (e) { fxErr = fxErr || String(e).slice(0, 120); }

    // 除外設定だけがある店舗×月にも行を作る（PL側がフラグを引けるように。媒体は便宜上の固定名）
    if (exclOk) for (const key of excluded) {
      const [storeId, ym] = key.split("|");
      if (![...byKey.values()].some((b) => b.store_id === storeId && b.ym === ym)) getB(storeId, ym, "（広告除外設定のみ）");
    }

    const upserts = [...byKey.values()].map((b) => {
      const row: Record<string, unknown> = {
        store_id: b.store_id, corporation_id: corpByStoreId.get(b.store_id) ?? null, year_month: b.ym, media_name: b.media, brand_name: b.brand,
        ad_cost: b.cost, plan_breakdown: b.plan,
        source_updated_at: new Date().toISOString(), computed_at: new Date().toISOString(), source_count: b.n, sync_run_id: runId,
      };
      if (fxOk) Object.assign(row, {
        access_count: b.fx?.access ?? null, net_groups: b.fx?.net_groups ?? null, net_people: b.fx?.net_people ?? null, tel_count: b.fx?.tel ?? null,
        total_groups: b.fx?.tGrp ?? null, total_people: b.fx?.tPpl ?? null, total_sales: b.fx?.tSales ?? null, acquisition_fee: b.fx?.fee ?? null,
      });
      if (exclOk) row.pl_excluded = excluded.has(`${b.store_id}|${b.ym}`);
      return row;
    });
    for (let i = 0; i < upserts.length; i += 500) {
      const { error: upErr } = await sb.from("kd_ad_monthly").upsert(upserts.slice(i, i + 500), { onConflict: "store_id,year_month,media_name,brand_name" });
      if (upErr) throw new Error("upsert失敗: " + upErr.message);
    }
    // 洗い替え: ①②③が全て取れた時だけ（一部失敗時は消さない）
    const sweep = (fxOk && exclOk) ? await sweepStale(sb, "kd_ad_monthly", runId, upserts.length) : { deleted: 0, skipped: "広告効果/除外設定の取得に失敗したため見送り" };
    for (const nm of unmatched) {
      try { await sb.rpc("kd_report_unresolved_name", { p_source_table: "kd_ad_monthly", p_kind: "store", p_raw_name: nm }); } catch (_) { /* noop */ }
    }
    const note = [unmatched.size ? `店舗名未対応: ${[...unmatched].join("、")}` : "", noStore ? `店舗未指定の広告費${noStore}行は対象外` : "",
      sweep.deleted ? `古い行${sweep.deleted}件を洗い替え削除` : "", !(fxOk && exclOk) ? `広告効果/除外設定は前回値のまま(${fxErr})` : ""].filter(Boolean).join(" / ");
    await finishRun(sb, runId, true, upserts.length, note || undefined);
    return { ok: true, job: "ad_monthly", rows: upserts.length, fx_ok: fxOk, excl_ok: exclOk, excluded_months: excluded.size, no_store_rows: noStore, unmatched: [...unmatched], swept: sweep, sync_run_id: runId };
  } catch (e) {
    await finishRun(sb, runId, false, 0, String(e), "kd_ad_monthly");
    return { ok: false, error: String(e) };
  }
}

// ============== op=delivery_daily: kd_delivery_daily（明細分析の「デリバリー」区分・2026-10-06） ==============
// 元データ: GAS bqGetDelivery（stg_delivery_order=ロケットナウ等の店舗×日の件数・純売上。login経由）。
// 商品は文字列(items_text)のためランキング/ABCの対象外。months窓内だけ洗い替え（既定3か月。バックフィルは months:40 等）。
async function sweepWindow(sb: any, table: string, dateCol: string, runId: string, from: string, to: string, newCount: number) {
  const win = (q: any) => q.gte(dateCol, from).lte(dateCol, to).or(`sync_run_id.is.null,sync_run_id.neq.${runId}`);
  const { count: stale, error: cErr } = await win(sb.from(table).select("id", { count: "exact", head: true }));
  if (cErr) return { deleted: 0, skipped: "count失敗: " + cErr.message };
  if (!stale) return { deleted: 0 };
  if (newCount < 5 || stale > newCount * 0.5) return { deleted: 0, skipped: `窓内の古い行${stale}件が今回${newCount}件の半分超のため削除せず（部分応答の疑い）` };
  const { error: dErr } = await win(sb.from(table).delete());
  if (dErr) return { deleted: 0, skipped: "delete失敗: " + dErr.message };
  return { deleted: stale };
}
async function refreshDeliveryDaily(sb: any, body: any) {
  const months = Math.max(1, Math.min(60, Number(body.months) || 3));
  const runId = await startRun(sb, "kd_delivery_daily");
  try {
    const maps = await loadStoreMaps(sb);
    const res = await dashAuthed(sb, "bqGetDelivery", { months });
    if (!res.ok) throw new Error("bqGetDelivery取得に失敗: " + (res.error ?? ""));
    const rows: any[][] = res.sheets?.delivery ?? [];
    const unmatched = new Set<string>();
    const byKey = new Map<string, { store_id: string; biz_date: string; channel: string; orders: number; net_sales: number }>();
    let minDate = "9999-12-31", maxDate = "0000-01-01";
    for (let r = 1; r < rows.length; r++) {
      const row = rows[r];
      const hit = lookupStore(maps, String(row[0] ?? "").trim());
      const date = toDateStr(row[1]);
      if (!date) continue;
      if (!hit) { unmatched.add(String(row[0] ?? "")); continue; }
      const channel = String(row[2] ?? "").trim() || "デリバリー";
      const key = `${hit.store_id}|${date}|${channel}`;
      const b = byKey.get(key) ?? { store_id: hit.store_id, biz_date: date, channel, orders: 0, net_sales: 0 };
      b.orders += num(row[3]); b.net_sales += num(row[5]);
      byKey.set(key, b);
      if (date < minDate) minDate = date; if (date > maxDate) maxDate = date;
    }
    const upserts = [...byKey.values()].map((b) => ({ ...b, computed_at: new Date().toISOString(), sync_run_id: runId }));
    for (let i = 0; i < upserts.length; i += 500) {
      const { error } = await sb.from("kd_delivery_daily").upsert(upserts.slice(i, i + 500), { onConflict: "store_id,biz_date,channel" });
      if (error) throw new Error("upsert失敗: " + error.message);
    }
    // 窓の下限は months 前の月初に丸めず、実際に返ってきた最小日付から（GAS側のcutoffは日付単位）
    const sweep = upserts.length ? await sweepWindow(sb, "kd_delivery_daily", "biz_date", runId, minDate, maxDate, upserts.length) : { deleted: 0 };
    for (const nm of unmatched) {
      try { await sb.rpc("kd_report_unresolved_name", { p_source_table: "kd_delivery_daily", p_kind: "store", p_raw_name: nm }); } catch (_) { /* noop */ }
    }
    const note = [unmatched.size ? `店舗名未対応: ${[...unmatched].join("、")}` : "", sweep.deleted ? `窓内の古い行${sweep.deleted}件を洗い替え削除` : "", (sweep as any).skipped ? `洗い替え見送り: ${(sweep as any).skipped}` : ""].filter(Boolean).join(" / ");
    await finishRun(sb, runId, true, upserts.length, note || undefined);
    return { ok: true, job: "delivery_daily", rows: upserts.length, range: [minDate, maxDate], unmatched: [...unmatched], swept: sweep, sync_run_id: runId };
  } catch (e) {
    await finishRun(sb, runId, false, 0, String(e), "kd_delivery_daily");
    return { ok: false, error: String(e) };
  }
}

// ============== op=detail_daily: kd_detail_item_daily / kd_detail_hour_daily（明細分析・2026-10-06） ==============
// 元データ: GAS bqDetailItemDailyForSync（担当A実装・BQ_LOAD_TOKEN認証・ログイン不要・1回最大31日）。ランチ/ディナーの
// 境目やドリンク/フード/カラオケの判定はGAS(bqDetailと同一ロジック)で適用済みの結果をそのまま保存する（計算式は1か所）。
// 呼び方: { op:'detail_daily', from?, to? }（既定=前月1日〜今日。31日ごとに順に取得）。窓ごとに洗い替え（安全装置付き）。
// 有効化フラグ: app_secrets.kd_detail_daily_enabled='1' になるまで、取込完了ドリブン(op=due)には載せない
//   （GASアクションの本番貼替・突合確認前に毎時の失敗通知を出さないため）。手動実行(op直指定)はいつでも可。
async function bqDetailItemDailyRows(from: string, to: string): Promise<{ logic_ver: number | null; item: any[][]; hour: any[][] }> {
  const tk = Deno.env.get("BQ_LOAD_TOKEN");
  if (!tk) throw new Error("BQ_LOAD_TOKENが未設定です（Supabaseのシークレット）");
  const url = new URL(DASH_API_URL);
  url.searchParams.set("action", "bqDetailItemDailyForSync"); url.searchParams.set("token", tk);
  url.searchParams.set("from", from); url.searchParams.set("to", to); url.searchParams.set("part", "both");
  let lastText = "";
  for (let attempt = 1; attempt <= 3; attempt++) {
    const res = await fetch(url.toString());
    lastText = await res.text();
    let j: any = null;
    try { j = JSON.parse(lastText); } catch (_) { /* GASの一時不調(HTML)→再試行 */ }
    if (j) {
      if (!j.ok) {
        // 同じBQ_LOAD_TOKENで他のtoken認証アクション(bqGetAdCost等)は通るのに本アクションだけunauthorizedなら、
        // 未知のアクションがセッション必須の経路に落ちている＝本番Webアプリのデプロイが古い（新バージョン未作成）可能性が高い
        const hint = j.error === "unauthorized" ? "（同じトークンで他のtoken認証アクションは通るため、GAS本番Webアプリに本アクションが載っていない＝『デプロイを管理→新バージョン』が未実施の可能性）" : "";
        throw new Error("bqDetailItemDailyForSync失敗: " + (j.error ?? JSON.stringify(j).slice(0, 120)) + hint);
      }
      return { logic_ver: j.logic_ver ?? null, item: j.sheets?.item ?? [], hour: j.sheets?.hour ?? [] };
    }
    if (attempt < 3) await new Promise((r) => setTimeout(r, attempt * 2000));
  }
  throw new Error("bqDetailItemDailyForSyncの応答を読めませんでした: " + lastText.slice(0, 120));
}
async function refreshDetailDaily(sb: any, body: any) {
  const today = jstToday();
  const prevMonthFirst = (() => { const [y, m] = today.split("-").map(Number); return new Date(Date.UTC(y, m - 2, 1)).toISOString().slice(0, 10); })();
  const from: string = typeof body.from === "string" ? body.from : prevMonthFirst;
  const to: string = typeof body.to === "string" ? body.to : today;
  const runId = await startRun(sb, "kd_detail_item_daily", from, to);
  try {
    const maps = await loadStoreMaps(sb);
    const unmatched = new Set<string>();
    let itemTotal = 0, hourTotal = 0, deleted = 0; const skips: string[] = []; let logicVer: number | null = null;
    // 31日ごとの窓
    for (let cur = from; cur <= to;) {
      const winEnd = (() => { const e = addDays(cur, 30); return e < to ? e : to; })();
      const g = await bqDetailItemDailyRows(cur, winEnd);
      logicVer = g.logic_ver;
      const itemMap = new Map<string, any>(); const hourMap = new Map<string, any>();
      for (let r = 1; r < g.item.length; r++) {
        const row = g.item[r];
        const hit = lookupStore(maps, String(row[0] ?? "").trim()); const date = toDateStr(row[1]); const dp = String(row[2] ?? "").trim();
        if (!date || (dp !== "lunch" && dp !== "dinner")) continue;
        if (!hit) { unmatched.add(String(row[0] ?? "")); continue; }
        const item = String(row[3] ?? "").trim() || "(不明)";
        const key = `${hit.store_id}|${date}|${dp}|${item}`;
        const b = itemMap.get(key) ?? { store_id: hit.store_id, biz_date: date, daypart: dp, item_name: item, category: String(row[4] ?? "").trim() || null, qty: 0, sales_incl: 0, sales_excl: 0 };
        b.qty += num(row[5]); b.sales_incl += num(row[6]); b.sales_excl += num(row[7]);
        itemMap.set(key, b);
      }
      for (let r = 1; r < g.hour.length; r++) {
        const row = g.hour[r];
        const hit = lookupStore(maps, String(row[0] ?? "").trim()); const date = toDateStr(row[1]); const dp = String(row[2] ?? "").trim();
        const hr = Number(row[3]);
        if (!date || (dp !== "lunch" && dp !== "dinner") || !Number.isFinite(hr)) continue;
        if (!hit) { unmatched.add(String(row[0] ?? "")); continue; }
        const key = `${hit.store_id}|${date}|${dp}|${hr}`;
        const b = hourMap.get(key) ?? { store_id: hit.store_id, biz_date: date, daypart: dp, hour: hr, sales_incl: 0, sales_excl: 0, checks: 0, guests_otoshi: 0, qty: 0, drink_excl: 0, food_excl: 0, karaoke_excl: 0 };
        b.sales_incl += num(row[4]); b.sales_excl += num(row[5]); b.checks += num(row[6]); b.guests_otoshi += num(row[7]); b.qty += num(row[8]);
        b.drink_excl += num(row[9]); b.food_excl += num(row[10]); b.karaoke_excl += num(row[11]);
        hourMap.set(key, b);
      }
      const stamp = { logic_ver: logicVer, computed_at: new Date().toISOString(), sync_run_id: runId };
      const itemRows = [...itemMap.values()].map((b) => ({ ...b, ...stamp }));
      const hourRows = [...hourMap.values()].map((b) => ({ ...b, ...stamp }));
      for (let i = 0; i < itemRows.length; i += 1000) {
        const { error } = await sb.from("kd_detail_item_daily").upsert(itemRows.slice(i, i + 1000), { onConflict: "store_id,biz_date,daypart,item_name" });
        if (error) throw new Error("item upsert失敗: " + error.message);
      }
      for (let i = 0; i < hourRows.length; i += 1000) {
        const { error } = await sb.from("kd_detail_hour_daily").upsert(hourRows.slice(i, i + 1000), { onConflict: "store_id,biz_date,daypart,hour" });
        if (error) throw new Error("hour upsert失敗: " + error.message);
      }
      itemTotal += itemRows.length; hourTotal += hourRows.length;
      // 窓内の洗い替え（BQ側で消えた/変わった行を残さない。空応答や部分応答では消さない安全装置付き）
      const s1 = await sweepWindow(sb, "kd_detail_item_daily", "biz_date", runId, cur, winEnd, itemRows.length);
      const s2 = await sweepWindow(sb, "kd_detail_hour_daily", "biz_date", runId, cur, winEnd, hourRows.length);
      deleted += s1.deleted + s2.deleted;
      if ((s1 as any).skipped) skips.push(`${cur}〜 item: ${(s1 as any).skipped}`);
      if ((s2 as any).skipped) skips.push(`${cur}〜 hour: ${(s2 as any).skipped}`);
      cur = addDays(winEnd, 1);
    }
    for (const nm of unmatched) {
      try { await sb.rpc("kd_report_unresolved_name", { p_source_table: "kd_detail_item_daily", p_kind: "store", p_raw_name: nm }); } catch (_) { /* noop */ }
    }
    const note = [unmatched.size ? `店舗名未対応: ${[...unmatched].join("、")}` : "", deleted ? `古い行${deleted}件を洗い替え削除` : "", skips.length ? `洗い替え見送り: ${skips.join(" / ")}` : "", logicVer != null ? `logic_ver=${logicVer}` : ""].filter(Boolean).join(" / ");
    await finishRun(sb, runId, true, itemTotal + hourTotal, note || undefined);
    return { ok: true, job: "detail_daily", from, to, item_rows: itemTotal, hour_rows: hourTotal, logic_ver: logicVer, deleted, skips, unmatched: [...unmatched], sync_run_id: runId };
  } catch (e) {
    await finishRun(sb, runId, false, 0, String(e), "kd_detail_item_daily");
    return { ok: false, error: String(e) };
  }
}

// ============== op=home_kpi: kd_home_kpi_snapshot ==============
async function refreshHomeKpi(sb: any) {
  const today = jstToday();
  const runId = await startRun(sb, "kd_home_kpi_snapshot", today.slice(0, 7) + "-01", today);
  try {
    const { data: storeRows } = await sb.from("stores").select("id,corporation_id");
    const stores = (storeRows ?? []) as { id: string; corporation_id: string | null }[];

    // 2026-10-03変更（ユーザー回答「売上は前日分が分かればよい」）: 売上の取込は朝に前日分までが入る運用で、
    // 当日(JST)の行は一日中0/nullになる。そこで「売上のある最新営業日」(=dataDate・通常は前日)を基準に、
    // その日の実績・その月の月初〜dataDateの累計・同期間の目標累計を出す（達成率の分子分母の期間を揃える）。
    // 行のキー(period_date)は従来どおり今日のまま＝keiei-api-home等の読み手は無変更で動く。
    const { data: latest } = await sb.from("kd_dashboard_daily_summary").select("period_date")
      .lte("period_date", today).gt("net_sales", 0).order("period_date", { ascending: false }).limit(1);
    const dataDate: string = latest?.[0]?.period_date ?? today;
    const monthStart = dataDate.slice(0, 7) + "-01";

    // 最新営業日の実績
    const { data: todayRows } = await sb.from("kd_dashboard_daily_summary")
      .select("store_id,net_sales,guests,parties").eq("period_date", dataDate);
    const todayMap = new Map<string, any>();
    (todayRows ?? []).forEach((r: any) => todayMap.set(r.store_id, r));

    // 月累計売上（月初〜dataDate）
    const { data: mtdRows } = await sb.from("kd_dashboard_daily_summary")
      .select("store_id,net_sales").gte("period_date", monthStart).lte("period_date", dataDate);
    const mtdMap = new Map<string, number>();
    (mtdRows ?? []).forEach((r: any) => mtdMap.set(r.store_id, (mtdMap.get(r.store_id) ?? 0) + (Number(r.net_sales) || 0)));

    // 月初〜dataDateぶんの日別売上目標を積み上げ（dash_sales_target_daily。dash-syncが既に日次で維持）
    const { data: targetRows } = await sb.from("dash_sales_target_daily")
      .select("store_id,sales_target").gte("biz_date", monthStart).lte("biz_date", dataDate);
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
      store_id: s.id, corporation_id: s.corporation_id, period_date: today, data_date: dataDate,
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
    return { ok: true, job: "home_kpi", rows: upserts.length, data_date: dataDate, sync_run_id: runId };
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

// ============== op=due: 今回どのopを実行すべきかを返す（取込完了ドリブン・2026-10-03） ==============
// ユーザー回答「売上は前日分が分かればよい（リアルタイム不要）」。売上の元データは朝の取込（zeroregi 06:3x → dinii 07:3x〜08:3x →
// morning-refresh 08:49 → bq-sales-reconcile 11:0x）で前日分が確定し、それ以外の時間帯は変わらない。毎時に重いGAS呼び出し
// （dashboard_daily 平均32秒・失敗16.5%）を回しても読むのは同じ数字なので、ns-daily-importの完了記録(import_runs)を見て、
// 「関連する取込が前回のkd_更新より新しく終わった時」だけ重い更新を走らせる。手入力（DB_PL等）の反映用に、日中は
// 前回成功から3時間たっていれば保険として走らせる。home_kpi（Supabase内3秒）は毎回走らせる。
const DUE_GROUPS: { name: string; kdJob: string; ops: string[]; imports: string[]; safetyHours: number | null; flagKey?: string }[] = [
  { name: "売上・PL", kdJob: "kd_dashboard_daily_summary", ops: ["dashboard_daily", "store_monthly", "pl_monthly", "ad_monthly", "delivery_daily"], safetyHours: 3,
    imports: ["zeroregi-akihabara", "dinii-orders", "dinii-payment-ns", "dinii-payment-nstyle", "morning-refresh", "bq-sales-reconcile", "smaregi-payroll", "infomart-siire", "rocketnow-sales"] },
  { name: "入金", kdJob: "kd_deposit_monthly_summary", ops: ["deposit_monthly"], safetyHours: null,
    imports: ["paypay-bank", "paypay-bank-b", "paypay-merchant-deposit", "paypay-merchant-deposit-nstyle", "smbc-card-deposit", "smbc-card-deposit-toho", "morning-refresh"] },
  { name: "明細", kdJob: "kd_detail_item_daily", ops: ["detail_daily"], safetyHours: null, flagKey: "kd_detail_daily_enabled",
    imports: ["dinii-orders", "morning-refresh"] },
  { name: "予約", kdJob: "kd_reservation_daily_summary", ops: ["reservation_daily"], safetyHours: null,
    imports: ["tabelog-note-reservation", "dinii-reservation", "bq-reservation-sync"] },
];
async function planDue(sb: any) {
  const due: string[] = []; const reasons: Record<string, string> = {};
  const hourJst = new Date(Date.now() + 9 * 3600 * 1000).getUTCHours();
  for (const g of DUE_GROUPS) {
    if (g.flagKey) {   // 有効化フラグ(app_secrets)が'1'になるまで自動実行しない
      const { data: fl } = await sb.from("app_secrets").select("value").eq("key", g.flagKey).maybeSingle();
      if ((fl?.value ?? "").trim() !== "1") continue;
    }
    const { data: lastRun } = await sb.from("kd_sync_runs").select("started_at").eq("job", g.kdJob).eq("status", "success")
      .order("started_at", { ascending: false }).limit(1);
    const lastStart: string | null = lastRun?.[0]?.started_at ?? null;
    const { data: imp } = await sb.from("import_runs").select("job,finished_at").in("job", g.imports).in("status", ["success", "partial"])
      .not("finished_at", "is", null).order("finished_at", { ascending: false }).limit(1);
    const lastImp = imp?.[0] ?? null;
    let why = "";
    if (!lastStart) why = "初回";
    else if (lastImp && lastImp.finished_at > lastStart) why = `取込完了(${lastImp.job} ${String(lastImp.finished_at).slice(11, 16)}UTC)が前回更新より新しい`;
    else if (g.safetyHours && hourJst >= 8 && hourJst <= 22 && (Date.now() - new Date(lastStart).getTime()) / 3600000 >= g.safetyHours) why = `前回更新から${g.safetyHours}時間以上（手入力反映の保険）`;
    if (why) { due.push(...g.ops); reasons[g.name] = why; }
  }
  due.push("home_kpi");   // Supabase内で完結(平均3秒)・本部タスク滞留数などの鮮度のため毎回
  due.push("sessions_cleanup");
  return { ok: true, due, reasons };
}

// ============== op=verify_carry: 入金の繰越をGAS(depositCarry)とkd_deposit_carry_vで突合（読み取り専用・2026-10-05） ==============
// 旧経路(GAS depositCarry=シート全期間走査)と新経路(kd_)の数字が同じ定義で一致しているかを確認するための検査op。
// body.before省略時は当月1日(JST)。差異のある店舗だけ返す（全店一致ならmismatch=[]）。
async function verifyCarry(sb: any, body: any) {
  const before: string = typeof body.before === "string" ? body.before : jstToday().slice(0, 7) + "-01";
  const res = await dashAuthed(sb, "depositCarry", { before });
  if (!res.ok) return { ok: false, error: "GAS depositCarry失敗: " + (res.error ?? "") };
  const { idByName } = await loadStoreMaps(sb);
  const gas = new Map<string, { cash: number; dep: number }>();
  const unresolved: string[] = [];
  for (const r of (res.carry ?? []) as any[]) {
    const id = idByName.get(String(r[0] ?? "").trim());
    if (!id) { unresolved.push(String(r[0])); continue; }
    const cur = gas.get(id) ?? { cash: 0, dep: 0 };
    cur.cash += Number(r[1]) || 0; cur.dep += Number(r[2]) || 0; gas.set(id, cur);
  }
  const ym = before.slice(0, 7);
  const { data: kd } = await sb.from("kd_deposit_carry_v").select("store_id,cash_before,deposit_before,carry").eq("year_month", ym);
  const mismatch: any[] = []; let compared = 0;
  for (const k of (kd ?? []) as any[]) {
    const g = gas.get(k.store_id); if (!g) continue;
    compared++;
    const dc = Math.round(Number(k.cash_before) - g.cash), dd = Math.round(Number(k.deposit_before) - g.dep);
    if (Math.abs(dc) > 1 || Math.abs(dd) > 1) mismatch.push({ store_id: k.store_id, cash_diff: dc, deposit_diff: dd, kd_cash: Number(k.cash_before), gas_cash: g.cash, kd_dep: Number(k.deposit_before), gas_dep: g.dep });
  }
  return { ok: true, before, compared, mismatch, gas_stores: gas.size, unresolved_gas_stores: unresolved };
}

// ============== op=diag_detail_cov: 明細(dinii.orders)の月別カバレッジを返す読み取り専用の診断（2026-10-06・明細kd_化の規模見積り用） ==============
async function diagDetailCov(sb: any) {
  const res = await dashAuthed(sb, "data", { keys: "明細カバレッジ" });
  if (!res.ok) return { ok: false, error: "data取得失敗: " + (res.error ?? "") };
  const sh = res.sheets?.["明細カバレッジ"] ?? [];
  return { ok: true, header: sh[0] ?? null, rows: sh.slice(1) };
}

// ============== op=run_status: 指定jobの直近のkd_sync_runsを返す（長時間opの完了待ち用・読み取り専用） ==============
async function runStatus(sb: any, body: any) {
  const job = String(body.job ?? "");
  if (!job) return { ok: false, error: "jobが必要です" };
  const { data, error } = await sb.from("kd_sync_runs").select("id,job,status,rows,error,started_at,finished_at,period_from,period_to")
    .eq("job", job).order("started_at", { ascending: false }).limit(1);
  if (error) return { ok: false, error: error.message };
  return { ok: true, run: data?.[0] ?? null };
}

// ============== op=sessions_cleanup: ds_sessionsの期限切れ行を削除（A-11・2026-09-18） ==============
async function cleanupSessions(sb: any) {
  const { error, count } = await sb.from("ds_sessions").delete({ count: "exact" }).lt("expires_at", new Date().toISOString());
  if (error) return { ok: false, error: error.message };
  return { ok: true, deleted: count ?? 0 };
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
      case "store_monthly": result = await refreshStoreMonthly(sb); break;
      case "ad_monthly": result = await refreshAdMonthly(sb); break;
      case "delivery_daily": result = await refreshDeliveryDaily(sb, body); break;
      case "detail_daily": {
        // 長い窓(31日=約1.5〜3分)はEdge Functionのリクエスト待ち上限(150秒)を超えるため、async:trueなら即応答して裏で続行する
        // （完了は op=run_status で kd_sync_runs を見る）。通常のcron(取込完了ドリブン)は直近の短い窓のため同期で足りる。
        if (body.async === true) {
          // deno-lint-ignore no-explicit-any
          (globalThis as any).EdgeRuntime?.waitUntil(refreshDetailDaily(sb, body));
          result = { ok: true, started: true, job: "detail_daily", from: body.from, to: body.to };
        } else result = await refreshDetailDaily(sb, body);
        break;
      }
      case "pl_monthly": result = await refreshPlMonthly(sb); break;
      case "media_monthly": result = await refreshMediaMonthly(sb, body); break;
      case "deposit_monthly": result = await refreshDepositMonthly(sb); break;
      case "sessions_cleanup": result = await cleanupSessions(sb); break;
      case "due": result = await planDue(sb); break;
      case "run_status": result = await runStatus(sb, body); break;
      case "diag_detail_cov": result = await diagDetailCov(sb); break;
      case "verify_carry": result = await verifyCarry(sb, body); break;
      default: return json({ ok: false, error: "opは'reservation_daily'|'dashboard_daily'|'home_kpi'|'unresolved_notify'|'pl_monthly'|'media_monthly'|'deposit_monthly'|'store_monthly'|'ad_monthly'|'delivery_daily'|'detail_daily'|'sessions_cleanup'|'due'のいずれかが必須です" }, 400);
    }
    // 2026-09-03修正: ok:falseの結果をHTTP 200で返してしまうとGitHub Actions側のHTTP_CODEチェックを
    // すり抜けて「success」表示のまま失敗が握りつぶされる（実際にdashboard_dailyの失敗がこれで見逃されていた）。
    // 失敗時は必ず500を返す。
    return json(result, result?.ok ? 200 : 500);
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
