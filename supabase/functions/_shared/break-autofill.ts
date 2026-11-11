// =============================================================
// 社員・店長の休憩の自動補完（2026-11-13）: 判定と推定だけの部品（DB にもスマレジにも触らない＝単体でテストできる）
//   仕様（ユーザー確定 2026-11-11）: 対象は社員・店長。6 時間を超える勤務で休憩が未登録なら 60 分を補完。登録済みは上書きしない。
//   休憩の時刻が分からないときは、勤務時間の中に 1 つ作る（推定）。推定は「推定」として記録し、実際の時刻と区別する。
//   置き場所: 勤務の中央。出勤から 1 時間以内・退勤まで 1 時間以内・深夜（22 時〜翌 5 時）には置かない（深夜の割増の時間を減らさないため）。
// =============================================================
export type AutofillConfig = { minSpanMinutes: number; breakMinutes: number; edgeMarginMinutes: number; nightStartHour: number; nightEndHour: number; deductedToleranceMinutes: number; roundMinutes: number };
export const DEFAULT_AUTOFILL: AutofillConfig = { minSpanMinutes: 360, breakMinutes: 60, edgeMarginMinutes: 60, nightStartHour: 22, nightEndHour: 5, deductedToleranceMinutes: 30, roundMinutes: 5 };
export type Estimate = { ok: true; start: string; end: string; minutes: number; placement: "middle" | "before_night" | "after_night" } | { ok: false; reason: "too_short" | "night_only" | "invalid" };

const MIN = 60000, JST = 9 * 3600000;
const ms = (iso: string) => new Date(iso).getTime();
/** JST の「その日の 0 時」（ms） */
const jstDayStart = (t: number) => Math.floor((t + JST) / 86400000) * 86400000 - JST;
/** [s,e) が深夜帯（JST nightStart 時〜翌 nightEnd 時）に重なる分数 */
export function nightOverlapMinutes(s: number, e: number, cfg: AutofillConfig): number {
  let total = 0;
  for (let d = jstDayStart(s) - 86400000; d <= jstDayStart(e); d += 86400000) {
    const ns = d + cfg.nightStartHour * 3600000, ne = d + 86400000 + cfg.nightEndHour * 3600000;
    total += Math.max(0, Math.min(e, ne) - Math.max(s, ns));
  }
  return Math.round(total / MIN);
}
/** 推定の休憩（開始・終了）を作る。作れないとき（短い・深夜を避けられない）は理由を返す */
export function estimateBreak(clockInIso: string, clockOutIso: string, cfg: AutofillConfig = DEFAULT_AUTOFILL): Estimate {
  const a = ms(clockInIso), b = ms(clockOutIso);
  if (!Number.isFinite(a) || !Number.isFinite(b) || b <= a) return { ok: false, reason: "invalid" };
  const span = (b - a) / MIN;
  if (!(span > cfg.minSpanMinutes)) return { ok: false, reason: "too_short" };
  const len = cfg.breakMinutes * MIN, lo = a + cfg.edgeMarginMinutes * MIN, hi = b - cfg.edgeMarginMinutes * MIN - len;   // 開始時刻の取りうる範囲 [lo, hi]
  if (hi < lo) return { ok: false, reason: "too_short" };
  const round = (t: number) => Math.floor(t / (cfg.roundMinutes * MIN)) * (cfg.roundMinutes * MIN);
  const clamp = (t: number) => Math.min(hi, Math.max(lo, t));
  const iso = (t: number) => new Date(t).toISOString();
  const out = (s: number, placement: "middle" | "before_night" | "after_night"): Estimate => ({ ok: true, start: iso(s), end: iso(s + len), minutes: cfg.breakMinutes, placement });
  let s = clamp(round(a + (b - a - len) / 2));
  if (s < lo) s = lo;
  if (nightOverlapMinutes(s, s + len, cfg) === 0) return out(s, "middle");
  // 深夜にかかる: 深夜の前に寄せる（終了＝22 時）。だめなら深夜の後（開始＝5 時）。どちらも無理なら補完しない
  for (let d = jstDayStart(s) - 86400000; d <= jstDayStart(s) + 86400000; d += 86400000) {
    const before = d + cfg.nightStartHour * 3600000 - len;
    if (before >= lo && before <= hi && nightOverlapMinutes(before, before + len, cfg) === 0) return out(before, "before_night");
  }
  for (let d = jstDayStart(s) - 86400000; d <= jstDayStart(s) + 86400000; d += 86400000) {
    const after = d + cfg.nightEndHour * 3600000;
    if (after >= lo && after <= hi && nightOverlapMinutes(after, after + len, cfg) === 0) return out(after, "after_night");
  }
  return { ok: false, reason: "night_only" };
}

// "YYYY-MM-DDThh:mm:ss+09:00"（スマレジへ送る形。smaregi-attendance-fix と同じ）
export function jstIso(iso: string): string {
  const t = new Date(new Date(iso).getTime() + JST);
  const p = (n: number) => String(n).padStart(2, "0");
  return `${t.getUTCFullYear()}-${p(t.getUTCMonth() + 1)}-${p(t.getUTCDate())}T${p(t.getUTCHours())}:${p(t.getUTCMinutes())}:${p(t.getUTCSeconds())}+09:00`;
}

export type SmaregiDaily = { shiftResultId?: unknown; attendance?: string | null; leaving?: string | null; breakStartTime1?: string | null; breakEndTime1?: string | null; breakStartTime2?: string | null; breakEndTime2?: string | null; dutyMinute?: unknown; tardyFlag?: unknown; earlyLeavingFlag?: unknown };
export type PreCheck = { ok: true } | { ok: false; status: "skipped" | "conflict"; reason: "not_found" | "has_break" | "time_changed" | "not_left" | "deducted" };
const same = (x: string | null | undefined, y: string) => !!x && Math.abs(ms(x) - ms(y)) < MIN;
/** スマレジのいまの実績を見て、補完してよいか決める（二重登録・二重控除・競合を防ぐ）
 *   has_break  : スマレジに休憩が入っている → 上書きしない（次の取り込みで管理システムにも入る）
 *   time_changed: 出勤・退勤が管理システムと違う → スマレジで直されている。補完しない（競合）
 *   deducted   : 休憩の時刻は無いのに、スマレジの勤務時間が出勤〜退勤より短い → スマレジ側で休憩が自動で引かれている疑い。補完しない（二重控除の防止） */
export function preCheck(rec: SmaregiDaily | null | undefined, hub: { clock_in: string; clock_out: string }, cfg: AutofillConfig = DEFAULT_AUTOFILL): PreCheck {
  if (!rec) return { ok: false, status: "conflict", reason: "not_found" };
  if (!rec.attendance || !rec.leaving) return { ok: false, status: "conflict", reason: "not_left" };
  if (rec.breakStartTime1 || rec.breakEndTime1 || rec.breakStartTime2 || rec.breakEndTime2) return { ok: false, status: "skipped", reason: "has_break" };
  if (!same(rec.attendance, hub.clock_in) || !same(rec.leaving, hub.clock_out)) return { ok: false, status: "conflict", reason: "time_changed" };
  const duty = rec.dutyMinute === null || rec.dutyMinute === undefined || rec.dutyMinute === "" ? null : Number(rec.dutyMinute);
  const span = (ms(rec.leaving) - ms(rec.attendance)) / MIN;
  if (duty !== null && Number.isFinite(duty) && span - duty >= cfg.deductedToleranceMinutes) return { ok: false, status: "skipped", reason: "deducted" };
  return { ok: true };
}
/** スマレジへ送る中身。出勤・退勤・遅刻早退の印はスマレジのいまの値のまま。休憩 1 に推定の時刻、休憩 2 は空 */
export function buildPayload(workDate: string, rec: SmaregiDaily, est: { start: string; end: string }): Record<string, unknown> {
  return {
    shiftDate: workDate, division: "result", attendance: jstIso(String(rec.attendance)), leaving: jstIso(String(rec.leaving)),
    breakStartTime1: jstIso(est.start), breakEndTime1: jstIso(est.end), breakStartTime2: null, breakEndTime2: null,
    ...(rec.tardyFlag != null && rec.tardyFlag !== "" ? { tardyFlag: String(rec.tardyFlag) } : {}),
    ...(rec.earlyLeavingFlag != null && rec.earlyLeavingFlag !== "" ? { earlyLeavingFlag: String(rec.earlyLeavingFlag) } : {}),
  };
}
/** 書いたあとに読み直して確かめる: 出勤・退勤は変わらず、休憩 1 が送ったとおりで、休憩 2 は無い */
export function verifyAfter(rec: SmaregiDaily | null | undefined, hub: { clock_in: string; clock_out: string }, est: { start: string; end: string }): boolean {
  return !!rec && same(rec.attendance, hub.clock_in) && same(rec.leaving, hub.clock_out) && same(rec.breakStartTime1, est.start) && same(rec.breakEndTime1, est.end) && !rec.breakStartTime2 && !rec.breakEndTime2;
}
export const REASON_LABEL: Record<string, string> = {
  not_found: "スマレジに勤怠が見つかりません", not_left: "スマレジで退勤が入っていません", has_break: "スマレジに休憩が登録されています（上書きしません）",
  time_changed: "スマレジで出勤・退勤が変更されています", deducted: "スマレジ側で休憩が自動で引かれている疑いがあります（二重に引かないよう、補完していません）",
  night_only: "深夜の時間帯を避けて休憩を置けません", closed: "スマレジの勤怠が締め済みです", verify_failed: "書き込んだあとの読み直しで、内容が一致しませんでした",
};
