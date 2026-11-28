// ユビレジの日ごとの売上（支払いDBの形）を、書き込む前に確かめる。通信はしない（functions/ubiregi-sales-import で使う）。
//   行の形: { store, date: "YYYY-MM-DD", values: 数値16個 }。16個の並びは
//   店内客数,店内組数,店外客数,店外組数,純売上,支払合計,現金,ポイント,クレジット,電子マネー,掛売,商品券,QR決済,モバイル決済,キャンペーン,その他
export type SalesRow = { store: string; date: string; values: number[] };

/** 営業が終わっている最後の営業日（日本時間・区切り朝6時）。この日まで書いてよい。 */
export function lastClosedDate(now: Date, cutoffHour = 6): string {
  const jstMinusCutoff = new Date(now.getTime() + 9 * 3600e3 - cutoffHour * 3600e3);
  jstMinusCutoff.setUTCDate(jstMinusCutoff.getUTCDate() - 1);
  return jstMinusCutoff.toISOString().slice(0, 10);
}

/** 受け取った CSV の期間（営業日）。レジ側の控えと現金の照合に使う。問題があれば理由の一覧を返す。 */
export function checkCovered(rows: SalesRow[], from: unknown, to: unknown, now: Date): string[] {
  const ok = (d: unknown): d is string => typeof d === "string" && /^\d{4}-\d{2}-\d{2}$/.test(d) && new Date(`${d}T00:00:00Z`).toISOString().slice(0, 10) === d;
  if (!ok(from) || !ok(to) || from > to) return ["受け取った期間（covered_from・covered_to）が正しくありません"];
  const errors: string[] = [];
  if (to > lastClosedDate(now)) errors.push(`期間の終わり（${to}）は、まだ営業が終わっていません`);
  if (rows.some((r) => r.date < from || r.date > to)) errors.push("期間の外の日が含まれています");
  return errors;
}

/** 問題があれば理由の一覧を返す（空なら書いてよい）。allowed＝書いてよい店舗名と開始日。 */
export function checkRows(rows: unknown, allowed: Record<string, string>, now: Date): string[] {
  if (!Array.isArray(rows) || !rows.length) return ["行がありません"];
  if (rows.length > 62) return ["1回に書けるのは62行までです"];
  const errors: string[] = [], seen = new Set<string>(), last = lastClosedDate(now);
  for (const [i, r] of (rows as SalesRow[]).entries()) {
    const at = `${i + 1}行目`;
    if (!r || typeof r !== "object") { errors.push(`${at}: 形が違います`); continue; }
    const extra = Object.keys(r).filter((k) => !["store", "date", "values"].includes(k));
    if (extra.length) errors.push(`${at}: 余分な項目があります（${extra.join(",")}）`);
    if (!Object.hasOwn(allowed, r.store)) { errors.push(`${at}: この店舗は書き込みの対象ではありません`); continue; }
    if (!/^\d{4}-\d{2}-\d{2}$/.test(r.date) || new Date(`${r.date}T00:00:00Z`).toISOString().slice(0, 10) !== r.date) { errors.push(`${at}: 日付が正しくありません`); continue; }
    if (r.date < allowed[r.store]) errors.push(`${at}: 開始日（${allowed[r.store]}）より前です`);
    if (r.date > last) errors.push(`${at}: ${r.date} はまだ営業が終わっていません`);
    const key = `${r.store}|${r.date}`;
    if (seen.has(key)) errors.push(`${at}: 同じ店舗と日が重複しています`);
    seen.add(key);
    const v = r.values;
    if (!Array.isArray(v) || v.length !== 16 || v.some((x) => !Number.isInteger(x) || x < 0)) { errors.push(`${at}: 数値16個（0以上の整数）ではありません`); continue; }
    const paid = v.slice(6).reduce((s, x) => s + x, 0);
    if (paid !== v[5]) errors.push(`${at}: 支払いの内訳の合計（${paid}）が支払合計（${v[5]}）と合いません`);
    if (v[4] > v[5]) errors.push(`${at}: 税抜の売上が支払合計より大きくなっています`);
  }
  return errors;
}
