// MF事業者ごとの会計期間の期首月と、仕訳の取得範囲を会計期間ごとに分割する部品（2026-10-17・担当C）
// MFの仕訳一覧APIは、日付の範囲が会計期間をまたぐ／どの期間にも入らないとエラーになる（invalid_query_parameter_value）。
// 実機確認: トーホー=4月・N-Style=8月・LiveGate=11月（2025-10〜11の範囲だけエラー）。
export const FISCAL_YEAR_START_MONTH: Record<string, number> = { default: 4, nstyle: 8, livegate: 11 };
export function fiscalStartMonth(tenant: string): number { return FISCAL_YEAR_START_MONTH[tenant] ?? 4; }
/** start〜end（YYYY-MM-DD）を、会計期間の切れ目で分けた範囲の一覧にする（古い順） */
export function splitByFiscalYear(tenant: string, start: string, end: string): { start: string; end: string }[] {
  const sm = fiscalStartMonth(tenant);
  const out: { start: string; end: string }[] = [];
  let cur = start;
  while (cur <= end) {
    const y = Number(cur.slice(0, 4)), m = Number(cur.slice(5, 7));
    const fyStartYear = m >= sm ? y : y - 1;                      // この日を含む会計期間の開始年
    const nextStart = `${fyStartYear + 1}-${String(sm).padStart(2, "0")}-01`;   // 次の会計期間の初日
    const lastDay = new Date(Date.parse(nextStart) - 86400e3).toISOString().slice(0, 10);
    const e = lastDay < end ? lastDay : end;
    out.push({ start: cur, end: e });
    cur = nextStart;
  }
  return out;
}
