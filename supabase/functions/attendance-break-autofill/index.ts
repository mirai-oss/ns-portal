// =============================================================
// attendance-break-autofill — 社員・店長の休憩の自動補完（2026-11-13 新規。★未デプロイ・設定は既定で無効）
//   設計: docs/設計書_勤怠修正画面と社員休憩自動補完_2026-11-12.md ／ SQL: supabase/2026-11-13_break_autofill.sql
//
//   op:
//     run   { dry_run?, from?, to?, limit? }   対象の勤怠（RPC attendance_break_autofill_scan）に、60 分の休憩（推定）を補完してスマレジへ同期する。
//           実際に書くのは、設定 app_settings.attendance_break_autofill.enabled=true かつ dry_run!==true のときだけ。それ以外は「試し実行」＝何も書かずに件数だけ返す。
//     smaregi_settings { }                     スマレジ側の「休憩時間自動設定」（事業所・従業員区分）を読むだけ。有効なものがあれば一覧を返す
//   二重登録・二重控除・同期ループを防ぐしくみ:
//     ・同じ勤怠には 1 回だけ（RPC attendance_break_autofill_begin が、勤怠の行をロックして条件を確かめ直し、履歴に 1 行だけ作る）
//     ・書く前にスマレジのいまの実績を読み直す。休憩が入っていたら書かない／出勤・退勤が変わっていたら書かない／勤務時間が出勤〜退勤より短ければ（スマレジ側で引かれている疑い）書かない
//     ・スマレジ側の休憩時間自動設定が有効、または確認できないときは、実行そのものを止める
//     ・成功したら、管理システムの勤怠にも同じ値（スマレジの読み直しの勤務時間・概算人件費）を入れる → 次の取り込みで違いが出ない＝「スマレジ側で直された」という検知・通知が出ない
//   通常の補完は Slack に出さない。失敗・競合・例外だけを本部タスクに（RPC attendance_break_autofill_task_sync）。
//   スマレジ API: 既存の勤怠修正の書き戻し（smaregi-attendance-fix）と同じ PUT /{contract}/timecard/shifts/{shift_result_id}
//   認証: Authorization: Bearer <service_role> か x-notify-secret
//   デプロイ: supabase functions deploy attendance-break-autofill --no-verify-jwt --project-ref uuvsxzhpxtghojoubjcc --yes（★別途承認）
// =============================================================
import { createClient } from "npm:@supabase/supabase-js@2";
import { API_BASE, getContractToken, staffIdsByUser } from "../_shared/smaregi-contracts.ts";
import { buildPayload, DEFAULT_AUTOFILL, estimateBreak, preCheck, type SmaregiDaily, verifyAfter } from "../_shared/break-autofill.ts";

const SCOPES = "timecard.shifts:read timecard.shifts:write";
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json" } });
const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
function timingSafeEqual(a: string, b: string) { if (a.length !== b.length) return false; let r = 0; for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i); return r === 0; }
function authorized(req: Request): boolean {
  const key = (Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "").trim();
  const auth = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (key && auth && timingSafeEqual(auth, key)) return true;
  const secret = (Deno.env.get("NOTIFY_SLACK_SECRET") ?? "").trim();
  const hdr = (req.headers.get("x-notify-secret") ?? "").trim();
  return !!(secret && hdr && timingSafeEqual(secret, hdr));
}
const stripContract = (key: string | null | undefined, contractId: string) => (key ?? "").startsWith(contractId + ":") ? String(key).slice(contractId.length + 1) : String(key ?? "");

// スマレジの 1 人 1 か月ぶんの実績を読み、勤怠の番号 → { rec, cost } にする
async function fetchMonth(contractId: string, token: string, staffId: string, y: string, m: string): Promise<{ ok: boolean; status: number; byId: Record<string, { rec: SmaregiDaily; cost: number | null }> }> {
  const r = await fetch(`${API_BASE}/${contractId}/timecard/shifts/staffs/${staffId}/daily?division=result&year=${y}&month=${m}`, { headers: { Authorization: `Bearer ${token}` } });
  const byId: Record<string, { rec: SmaregiDaily; cost: number | null }> = {};
  if (!r.ok) return { ok: false, status: r.status, byId };
  const b = await r.json().catch(() => null);
  for (const byStore of Object.values<any>(b?.shiftDaily ?? {})) for (const entry of Object.values<any>(byStore ?? {})) {
    const rec = entry?.["0"]; if (rec?.shiftResultId != null) byId[String(rec.shiftResultId)] = { rec, cost: entry?.personnelExpenses ? Number(entry.personnelExpenses) : null };
  }
  return { ok: true, status: r.status, byId };
}

// スマレジ側の「休憩時間自動設定」を読む（読むだけ）。state: enabled＝有効なものがある／disabled＝全部無効／unknown＝読めなかった（権限・通信）
//   事業所: autoBreakTimeDivision 1=時間指定（開始・終了の時刻が入っていれば有効）／2=条件指定（休憩の分数が 1 以上の行があれば有効）
//   従業員区分: autoBreakTimeSettingFlag が true のとき、中身を同じ基準で見る
function autoBreakOn(x: any): boolean {
  if (!x) return false;
  const div = String(x.autoBreakTimeDivision ?? "");
  const hasTime = !!(x.autoBreakStartTime1 || x.autoBreakEndTime1 || x.autoBreakStartTime2 || x.autoBreakEndTime2);
  const hasCond = [1, 2, 3].some((i) => Number(x[`autoBreakCondition${i}SettingTime`] ?? 0) > 0);
  return div === "2" ? hasCond : div === "1" ? hasTime : (hasTime || hasCond);
}
async function smaregiAutoBreak(contractId: string): Promise<{ state: "enabled" | "disabled" | "unknown"; stores: { id: string; name: string; on: boolean }[]; classifications: { id: string; name: string; on: boolean }[]; error?: string }> {
  const out = { state: "unknown" as "enabled" | "disabled" | "unknown", stores: [] as { id: string; name: string; on: boolean }[], classifications: [] as { id: string; name: string; on: boolean }[], error: undefined as string | undefined };
  try {
    const t1 = await getContractToken(contractId, "timecard.stores:read");
    const r1 = await fetch(`${API_BASE}/${contractId}/timecard/stores?limit=100`, { headers: { Authorization: `Bearer ${t1}` } });
    if (!r1.ok) { out.error = `事業所の設定を読めません HTTP ${r1.status}`; return out; }
    const j1 = await r1.json(); const arr1: any[] = Array.isArray(j1) ? j1 : (Array.isArray(j1?.stores) ? j1.stores : []);
    for (let s of arr1) {
      const sid = String(s.storeId ?? s.id ?? "");
      if (!("autoBreakTimeDivision" in s)) {   // 一覧に設定が入っていないときは、事業所ごとに読む。読めなければ「確認できない」
        const rd = await fetch(`${API_BASE}/${contractId}/timecard/stores/${sid}`, { headers: { Authorization: `Bearer ${t1}` } });
        if (!rd.ok) { out.error = `事業所 ${sid} の設定を読めません HTTP ${rd.status}`; return out; }
        const d = await rd.json(); s = { ...s, ...(Array.isArray(d) ? d[0] : (d?.store ?? d)) };
        if (!("autoBreakTimeDivision" in s)) { out.error = `事業所 ${sid} の休憩時間自動設定の項目が見つかりません`; return out; }
      }
      out.stores.push({ id: sid, name: String(s.storeName ?? s.name ?? ""), on: autoBreakOn(s) });
    }
    const t2 = await getContractToken(contractId, "timecard.settings:read");
    const r2 = await fetch(`${API_BASE}/${contractId}/timecard/employee_classifications?limit=100`, { headers: { Authorization: `Bearer ${t2}` } });
    if (!r2.ok) { out.error = `従業員区分の設定を読めません HTTP ${r2.status}`; return out; }
    const j2 = await r2.json();
    for (const c of (Array.isArray(j2) ? j2 : (j2?.employeeClassifications ?? j2?.employee_classifications ?? [])) as any[]) {
      const id = String(c.employeeClassificationId ?? c.id ?? ""); let on = false;
      if (c.autoBreakTimeSettingFlag === true || c.autoBreakTimeSettingFlag === "1" || c.autoBreakTimeSettingFlag === 1) {
        const rd = await fetch(`${API_BASE}/${contractId}/timecard/employee_classifications/${id}`, { headers: { Authorization: `Bearer ${t2}` } });
        if (!rd.ok) { out.error = `従業員区分 ${id} の設定を読めません HTTP ${rd.status}`; return out; }
        on = autoBreakOn(await rd.json());
      }
      out.classifications.push({ id, name: String(c.employeeClassificationName ?? c.name ?? ""), on });
    }
    out.state = [...out.stores, ...out.classifications].some((x) => x.on) ? "enabled" : "disabled";
  } catch (e) { out.error = String((e as Error).message ?? e).slice(0, 200); }
  return out;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ ok: false, error: "POSTのみ" }, 405);
  if (!authorized(req)) return json({ ok: false, error: "認証がありません" }, 401);
  let body: any = {};
  try { body = await req.json(); } catch { body = {}; }
  const sb = svc();
  const { data: cfgRaw } = await sb.rpc("attendance_break_autofill_cfg");
  const cfg = (cfgRaw ?? {}) as Record<string, any>;
  const acfg = { ...DEFAULT_AUTOFILL, minSpanMinutes: Number(cfg.min_span_minutes ?? 360), breakMinutes: Number(cfg.break_minutes ?? 60), deductedToleranceMinutes: Number(cfg.deducted_tolerance_minutes ?? 30) };
  const { data: contracts } = await sb.from("smaregi_contracts").select("contract_id,is_active").order("contract_id");
  const contractIds = ((contracts ?? []) as any[]).filter((c) => c.is_active !== false).map((c) => String(c.contract_id));

  if (body.op === "smaregi_settings") {
    const res: Record<string, unknown> = {};
    for (const c of contractIds) res[c] = await smaregiAutoBreak(c);
    return json({ ok: true, contracts: res, confirmed_off: cfg.smaregi_auto_break_confirmed_off === true });
  }
  if ((body.op ?? "run") !== "run") return json({ ok: false, error: "不明な op" }, 400);

  const live = cfg.enabled === true && body.dry_run !== true;
  const { data: scan, error: scanErr } = await sb.rpc("attendance_break_autofill_scan", { p_from: body.from ?? null, p_to: body.to ?? null });
  if (scanErr) return json({ ok: false, error: "対象を読めません: " + scanErr.message }, 500);
  const rows = ((scan ?? []) as any[]).sort((a, b) => String(a.work_date).localeCompare(String(b.work_date)));
  const skipCounts: Record<string, number> = {};
  for (const r of rows) if (!r.eligible) skipCounts[r.skip_reason] = (skipCounts[r.skip_reason] ?? 0) + 1;
  const limit = Math.min(100, Math.max(1, Number(body.limit ?? cfg.max_per_run ?? 30)));
  const targets = rows.filter((r) => r.eligible).slice(0, limit);
  const summary = { ok: true, live, enabled: cfg.enabled === true, candidates: rows.filter((r) => r.eligible).length, processed: 0, synced: 0, skipped: 0, conflict: 0, error: 0, would_fill: 0,
    scan_skipped: skipCounts, results: {} as Record<string, number>, superseded: 0, task: null as unknown, smaregi_auto_break: {} as Record<string, string>, stopped: null as string | null };

  // スマレジ側の自動休憩と重ならないこと（実際に書くときは必須。試し実行でも結果を返す）
  const gate: Record<string, "enabled" | "disabled" | "unknown"> = {};
  for (const c of new Set(targets.map((r) => String(r.contract_id)))) { const g = await smaregiAutoBreak(c); gate[c] = g.state; summary.smaregi_auto_break[c] = g.state + (g.error ? `（${g.error}）` : ""); }
  const bad = Object.entries(gate).filter(([, s]) => s === "enabled" || (s === "unknown" && cfg.smaregi_auto_break_confirmed_off !== true)).map(([c]) => c);
  if (live && bad.length) {
    summary.stopped = "スマレジ側の「休憩時間自動設定」が有効、または確認できないため、補完を止めました（二重に休憩を引かないため）。スマレジの管理画面で確認してください";
    return json(summary);
  }
  if (live) { const { data: sup } = await sb.rpc("attendance_break_autofill_reconcile"); summary.superseded = Number(sup ?? 0); }

  const tokens: Record<string, string> = {}; const months: Record<string, Awaited<ReturnType<typeof fetchMonth>>> = {};
  const bump = (k: string) => { summary.results[k] = (summary.results[k] ?? 0) + 1; };
  for (const t of targets) {
    summary.processed++;
    const est = estimateBreak(String(t.clock_in), String(t.clock_out), acfg);
    if (!live) { if (est.ok) summary.would_fill++; else bump("skipped:" + est.reason); continue; }
    try {
      if (!est.ok) {   // 置けない（深夜を避けられない など）: 補完しない。理由を残す
        await sb.rpc("attendance_break_autofill_begin", { p_labor: t.labor_cost_daily_id, p_est_start: null, p_est_end: null, p_rule: { reason: est.reason }, p_status: "skipped", p_reason: est.reason });
        summary.skipped++; bump("skipped:" + est.reason); continue;
      }
      const C = String(t.contract_id);
      const { data: bg, error: bgErr } = await sb.rpc("attendance_break_autofill_begin", { p_labor: t.labor_cost_daily_id, p_est_start: est.start, p_est_end: est.end, p_rule: { minutes: est.minutes, placement: est.placement, min_span_minutes: acfg.minSpanMinutes }, p_status: "syncing" });
      if (bgErr || !bg?.ok) { bump("not_started:" + (bg?.reason ?? "error")); continue; }   // そのあいだに条件が変わった・すでに処理済み
      const id = bg.id as string;
      const finish = async (status: string, reason: string | null, extra: Record<string, unknown> = {}) => {
        await sb.rpc("attendance_break_autofill_finish", { p_id: id, p_status: status, p_reason: reason, p_response: extra.response ?? null, p_duty_minute: extra.duty ?? null, p_cost: extra.cost ?? null });
        (summary as any)[status] = ((summary as any)[status] ?? 0) + 1; bump(status + (reason ? ":" + reason : ""));
      };
      const staff = (await staffIdsByUser(sb, C, [t.user_id], t.work_date))[t.user_id];
      if (!staff) { await finish("error", "no_staff"); continue; }
      tokens[C] ??= await getContractToken(C, SCOPES);
      const [y, m] = String(t.work_date).split("-"); const mk = `${C}|${staff}|${y}-${m}`;
      months[mk] = await fetchMonth(C, tokens[C], staff, y, m);                 // 書く直前に必ず読み直す（同じ人の前の補完の結果も入る）
      if (!months[mk].ok) { await finish("error", `smaregi_get_${months[mk].status}`); continue; }
      const sid = stripContract(t.smaregi_shift_result_id, C);
      const cur = months[mk].byId[sid];
      const hub = { clock_in: String(t.clock_in), clock_out: String(t.clock_out) };
      const pc = preCheck(cur?.rec, hub, acfg);
      if (!pc.ok) { await finish(pc.status, pc.reason); continue; }
      const res = await fetch(`${API_BASE}/${C}/timecard/shifts/${sid}`, { method: "PUT", headers: { Authorization: `Bearer ${tokens[C]}`, "Content-Type": "application/json" }, body: JSON.stringify(buildPayload(String(t.work_date), cur.rec, est)) });
      const rj = await res.json().catch(() => null);
      if (!res.ok) { await finish(res.status === 409 ? "skipped" : "error", res.status === 409 ? "closed" : `smaregi_put_${res.status}`, { response: rj }); continue; }
      const after = await fetchMonth(C, tokens[C], staff, y, m);
      const got = after.byId[sid];
      if (!after.ok || !verifyAfter(got?.rec, hub, est)) { await finish("error", "verify_failed", { response: rj }); continue; }
      const duty = got.rec.dutyMinute === null || got.rec.dutyMinute === undefined || got.rec.dutyMinute === "" ? null : Number(got.rec.dutyMinute);
      await finish("synced", null, { response: { shiftResultId: sid }, duty, cost: got.cost });
    } catch (e) {
      summary.error++; bump("error:exception");
      console.error("break autofill", String((e as Error).message ?? e).slice(0, 200));
    }
  }
  if (live) { const { data: tk } = await sb.rpc("attendance_break_autofill_task_sync"); summary.task = tk ?? null; }
  return json(summary);   // 氏名・金額は返さない（件数だけ）
});
