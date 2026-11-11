// =============================================================
// スマレジの賃金設定と管理システムの賃金の突き合わせ（2026-11-12）
//   スマレジ同期（smaregi-sync の wage_pull_all / wage_pull）が使う、判定だけの部品（DB にもスマレジにも触らない＝単体でテストできる）。
//   正本は管理システム。スマレジにだけある行の扱い:
//     ・保留が無効（holdEnabled=false・既定）: これまでどおり「管理システムに無い行」を取り込む
//     ・保留が有効: 初期投入（initialAllowed＝その契約の賃金が 1 件も無い人で、入社手続き中または連携から 14 日以内）のときだけ取り込む。
//                   それ以外は、正式な賃金にせず「未承認の変更（new_row）」として返す（呼び出し側が外部変更の控えに記録する）
//   あわせて、保留が有効のときは「金額の違い（amount_changed）」「行の削除（deleted）」も外部変更として返す
// =============================================================
export type SmaregiWage = { id: string; division: number; storeId: string | null; effectiveDate: string; wage: number; holidayWage: number | null };
export type SystemWage = { id: string; division: number; store_id: string | null; effective_date: string; wage: number; holiday_wage: number | null; sync_status: string; smaregi_wage_apply_id: string | null };
export type ExternalItem = {
  kind: "new_row" | "amount_changed" | "deleted"; division: number; store_id: string | null; smaregi_store_id: string | null; effective_date: string;
  smaregi_wage_apply_id: string | null; smaregi_value: { wage: number; holiday_wage: number | null } | null; system_value: { wage: number; holiday_wage: number | null } | null; wage_setting_id: string | null;
};
export type ReconcileOpts = { today: string; storeMap: Record<string, string>; holdEnabled: boolean; initialAllowed: boolean; scope: "current_future" | "all" };
export type ReconcileResult = {
  inserts: { division: number; store_id: string | null; wage: number; holiday_wage: number | null; effective_date: string; smaregi_wage_apply_id: string }[];
  links: { row_id: string; smaregi_wage_apply_id: string }[];
  drift: { row_id: string }[];
  external: ExternalItem[];
  rows: { w: SmaregiWage; store_id: string | null; outcome: "unsupported" | "skipped_store" | "history" | "insert" | "held" | "drift" | "conflict" | "matched"; row_id?: string; system_wage?: number }[];
  counts: { imported: number; held: number; drift: number; conflicts: number; matched: number; unsupported: number; skipped_store: number; history: number; deleted: number; with_wage: boolean };
};

// 管理システムで扱う賃金設定: 時給(0)・月給(2)・日給(1。全事業所共通・休日賃金なしだけ）。営業時間帯別(3)は対象外
export const wageSupported = (w: { division: number; storeId: string | null; holidayWage: number | null }) =>
  w.division === 0 || w.division === 2 || (w.division === 1 && !w.storeId && (w.holidayWage === null || w.holidayWage === undefined));

/** 「いま有効（区分×事業所ごとに今日以前で最新）＋これから適用（未来日）」だけを残す */
export function currentAndFuture<T>(list: T[], today: string, keyOf: (x: T) => string, dateOf: (x: T) => string): T[] {
  const cur: Record<string, T> = {}; const keep: T[] = [];
  for (const w of list) {
    if (dateOf(w) > today) { keep.push(w); continue; }
    const k = keyOf(w);
    if (!cur[k] || dateOf(cur[k]) < dateOf(w)) cur[k] = w;
  }
  keep.push(...Object.values(cur));
  return keep;
}

export function reconcileWages(list: SmaregiWage[], mine: SystemWage[], o: ReconcileOpts): ReconcileResult {
  const res: ReconcileResult = { inserts: [], links: [], drift: [], external: [], rows: [],
    counts: { imported: 0, held: 0, drift: 0, conflicts: 0, matched: 0, unsupported: 0, skipped_store: 0, history: 0, deleted: 0, with_wage: false } };
  const have: Record<string, SystemWage> = {};
  for (const m of mine) have[`${m.division}|${m.store_id ?? ""}|${m.effective_date}`] = m;
  const supported = list.filter((w) => { if (wageSupported(w)) return true; res.counts.unsupported++; res.rows.push({ w, store_id: null, outcome: "unsupported" }); return false; });
  const cf = currentAndFuture(supported, o.today, (w) => `${w.division}|${w.storeId ?? ""}`, (w) => w.effectiveDate);
  const cfIds = new Set(cf.map((w) => w.id));
  const target = o.scope === "all" ? supported : cf;
  res.counts.with_wage = cf.length > 0;
  for (const w of target) {
    const storeUuid = w.storeId ? (o.storeMap[w.storeId] ?? null) : null;
    if (w.storeId && !storeUuid) { res.counts.skipped_store++; res.rows.push({ w, store_id: null, outcome: "skipped_store" }); continue; }
    const ex = have[`${w.division}|${storeUuid ?? ""}|${w.effectiveDate}`];
    const hol = w.division === 0 ? w.holidayWage : null;
    if (!ex) {
      if (!o.holdEnabled || o.initialAllowed) {
        res.inserts.push({ division: w.division, store_id: storeUuid, wage: w.wage, holiday_wage: hol, effective_date: w.effectiveDate, smaregi_wage_apply_id: w.id });
        res.counts.imported++; res.rows.push({ w, store_id: storeUuid, outcome: "insert" });
      } else if (!cfIds.has(w.id)) {
        // 保留が有効で、いま有効でも これから適用でもない行（過去の履歴）: 取り込まないし、未承認の変更にもしない
        res.counts.history++; res.rows.push({ w, store_id: storeUuid, outcome: "history" });
      } else {
        res.external.push({ kind: "new_row", division: w.division, store_id: storeUuid, smaregi_store_id: w.storeId, effective_date: w.effectiveDate, smaregi_wage_apply_id: w.id,
          smaregi_value: { wage: w.wage, holiday_wage: hol }, system_value: null, wage_setting_id: null });
        res.counts.held++; res.rows.push({ w, store_id: storeUuid, outcome: "held" });
      }
    } else if (ex.wage !== w.wage || (ex.holiday_wage ?? null) !== (hol ?? null)) {
      if (ex.sync_status === "synced") {
        res.drift.push({ row_id: ex.id }); res.counts.drift++; res.rows.push({ w, store_id: storeUuid, outcome: "drift", row_id: ex.id, system_wage: ex.wage });
        if (o.holdEnabled) res.external.push({ kind: "amount_changed", division: w.division, store_id: storeUuid, smaregi_store_id: w.storeId, effective_date: w.effectiveDate, smaregi_wage_apply_id: w.id,
          smaregi_value: { wage: w.wage, holiday_wage: hol }, system_value: { wage: ex.wage, holiday_wage: ex.holiday_wage ?? null }, wage_setting_id: ex.id });
      } else { res.counts.conflicts++; res.rows.push({ w, store_id: storeUuid, outcome: "conflict", row_id: ex.id, system_wage: ex.wage }); }
    } else {
      if (!ex.smaregi_wage_apply_id) res.links.push({ row_id: ex.id, smaregi_wage_apply_id: w.id });
      res.counts.matched++; res.rows.push({ w, store_id: storeUuid, outcome: "matched", row_id: ex.id });
    }
  }
  // 行の削除: 管理システムで同期済み（スマレジの番号つき）の「いま有効・これから適用」の行が、スマレジのどこにも無い
  if (o.holdEnabled) {
    const smIds = new Set(list.map((w) => w.id));
    const smKeys = new Set(supported.map((w) => `${w.division}|${w.storeId ? (o.storeMap[w.storeId] ?? "?") : ""}|${w.effectiveDate}`));
    const sysCf = currentAndFuture(mine.filter((m) => m.sync_status === "synced" && m.smaregi_wage_apply_id), o.today, (m) => `${m.division}|${m.store_id ?? ""}`, (m) => m.effective_date);
    for (const m of sysCf) {
      if (smIds.has(String(m.smaregi_wage_apply_id)) || smKeys.has(`${m.division}|${m.store_id ?? ""}|${m.effective_date}`)) continue;
      res.external.push({ kind: "deleted", division: m.division, store_id: m.store_id, smaregi_store_id: null, effective_date: m.effective_date, smaregi_wage_apply_id: m.smaregi_wage_apply_id,
        smaregi_value: null, system_value: { wage: m.wage, holiday_wage: m.holiday_wage ?? null }, wage_setting_id: m.id });
      res.counts.deleted++;
    }
  }
  return res;
}
