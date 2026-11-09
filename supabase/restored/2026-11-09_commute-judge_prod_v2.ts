// 通勤経路の候補の読み取りと「仮の判定」（Phase 2・2026-11-10）。EF commute-route から使う。純粋関数＝単体テスト可能。
// ルール（数値）は app_settings.commute_rules。AI が運賃を推測して金額を決めることはしない（金額は API の応答だけ）。最安だけで否認しない（最終判断は人）。
export type Rules = { max_extra_minutes: number; max_transfers: number; max_walk_m: number; tolerance_yen: number; tolerance_pct: number; bus_needs_review: boolean };
export type Candidate = { index: number; summary: string; fare: number | null; round: number | null; time_min: number | null; transfers: number | null; walk_min: number | null; uses_bus: boolean; teiki1: number | null; teiki3: number | null; teiki6: number | null };
export const DEFAULT_RULES: Rules = { max_extra_minutes: 15, max_transfers: 2, max_walk_m: 1500, tolerance_yen: 100, tolerance_pct: 20, bus_needs_review: true };

export const arr = (x: unknown): any[] => (x === undefined || x === null ? [] : Array.isArray(x) ? x : [x]);
export const num = (x: unknown): number | null => (x === undefined || x === null || x === "" ? null : Number.isFinite(Number(x)) ? Number(x) : null);

/** 駅すぱあとの Course 配列 → 候補の一覧（応答の形は XML 由来で単数/配列が揺れるため arr() で吸収） */
export function parseCourses(resultSet: any): Candidate[] {
  return arr(resultSet?.Course).map((c: any, i: number) => {
    const route = c?.Route ?? {};
    const lines = arr(route.Line);
    const points = arr(route.Point);
    const names = points.map((p: any) => p?.Station?.Name ?? p?.Name ?? "").filter(Boolean);
    const lineNames = lines.map((l: any) => l?.Name ?? "").filter(Boolean);
    const usesBus = lines.some((l: any) => String(l?.Type ?? l?.type ?? "").toLowerCase().includes("bus") || /バス/.test(String(l?.Name ?? "")));
    const prices = arr(c?.Price);
    const fare = prices.find((p: any) => p?.kind === "FareSummary") ?? prices.find((p: any) => p?.kind === "Fare");
    const teiki = (k: string) => { const p = prices.find((x: any) => x?.kind === k + "Summary") ?? prices.find((x: any) => x?.kind === k); return num(p?.Oneway); };
    const timeOnBoard = num(route.timeOnBoard), timeWalk = num(route.timeWalk), timeOther = num(route.timeOther);
    const total = timeOnBoard === null && timeWalk === null && timeOther === null ? null : (timeOnBoard ?? 0) + (timeWalk ?? 0) + (timeOther ?? 0);
    const summary = names.length ? names.join("→") + (lineNames.length ? `（${lineNames.join("・")}）` : "") : lineNames.join("・");
    return { index: i, summary: summary.slice(0, 160), fare: num(fare?.Oneway), round: num(fare?.Round), time_min: total, transfers: num(route.transferCount), walk_min: timeWalk, uses_bus: usesBus, teiki1: teiki("Teiki1"), teiki3: teiki("Teiki3"), teiki6: teiki("Teiki6") };
  });
}

/** 仮の判定（数値は app_settings.commute_rules）。最安だけで否認しない＝結果は人が見る */
export function judge(cands: Candidate[], claimed: number | null, rules: Rules): { judgement: string; reasons: string[]; reasonable: Candidate[]; computed: Candidate | null } {
  const withFare = cands.filter((c) => c.fare !== null);
  if (!withFare.length) return { judgement: "search_failed", reasons: ["運賃つきの経路が取れませんでした"], reasonable: [], computed: null };
  const minTime = Math.min(...withFare.map((c) => c.time_min ?? Infinity));
  const walkMax = rules.max_walk_m / 80; // 徒歩 80m/分 で分に換算
  let reasonable = withFare.filter((c) => (c.time_min === null || !Number.isFinite(minTime) || c.time_min <= minTime + rules.max_extra_minutes) && (c.transfers === null || c.transfers <= rules.max_transfers) && (c.walk_min === null || c.walk_min <= walkMax));
  const reasons: string[] = [];
  if (!reasonable.length) { reasonable = [withFare.reduce((a, b) => ((a.time_min ?? 1e9) <= (b.time_min ?? 1e9) ? a : b))]; reasons.push("条件（最速＋15分・乗換2回・徒歩1.5km）に合う経路が無いため最速の経路だけを候補にしました"); }
  const computed = reasonable.reduce((a, b) => ((a.fare ?? 1e9) <= (b.fare ?? 1e9) ? a : b));
  const maxFare = Math.max(...reasonable.map((c) => c.fare ?? 0));
  const tol = Math.max(rules.tolerance_yen, Math.round(maxFare * rules.tolerance_pct / 100));
  let judgement = "hq_review";
  if (claimed === null || claimed === undefined) { judgement = "hq_review"; reasons.push("本人の申請額がありません"); }
  else if (claimed <= (computed.fare ?? 0)) { judgement = "auto_approvable"; reasons.push(`申請額 ${claimed} 円 ≦ 合理的経路の最安 ${computed.fare} 円`); }
  else if (claimed <= maxFare + tol) { judgement = "hq_review"; reasons.push(`申請額 ${claimed} 円 は候補の範囲内（最安 ${computed.fare}〜最高 ${maxFare} 円＋許容 ${tol} 円）`); }
  else { judgement = "person_review"; reasons.push(`申請額 ${claimed} 円 が候補の最高 ${maxFare} 円＋許容 ${tol} 円 を超えています（本人に経路を確認）`); }
  // バスの扱い: 最安の合理的経路（＝申請額の比較相手）がバスを含むときだけ本部確認に回す（他の候補にバスがあっても自動承認可能のまま）
  if (rules.bus_needs_review && computed.uses_bus && judgement === "auto_approvable") { judgement = "hq_review"; reasons.push("最安の経路がバスを含むため本部確認"); }
  return { judgement, reasons, reasonable, computed };
}

