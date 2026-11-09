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


// =============================================================
// 自動承認の判定（2026-11-09・設計検討 → 実装。★ 既定は OFF（記録だけ＝shadow）。有効化はユーザー承認後に app_settings.commute_rules.auto_approve.enabled=true）
//   方針（ユーザー指示）: 「API 算出額と会社規定が一致する通常申請だけ自動承認し、例外は本部確認」。
//   ここでは「条件を満たすか」を返すだけで、承認（RPC onboarding_commute_decide）は呼び出し側が enabled のときだけ行う。
//   金額は API の応答と本人の申請だけから決める（AI が運賃を推測しない）。否認は絶対に自動でしない（満たさなければ従来どおり人が見る）。
// =============================================================
export type AutoRules = {
  enabled: boolean;            // true で実際に承認する（既定 false）
  shadow: boolean;             // true なら「もし有効なら自動承認したか」を記録だけする（既定 true）
  max_oneway_yen: number;      // 片道がこれを超えたら人が見る（既定 1,500 円）
  allow_bus: boolean;          // 最安の合理的経路がバスを含んでも可とするか（既定 false）
  allowed_methods: string[];   // 本人の通勤手段がこれ以外なら人が見る（既定 ['train']）
  require_home_station: boolean; // 本人の最寄り駅が登録されていること（住所からの推定経路は人が見る）
  require_exact_match: boolean;  // true なら 申請額 == 算出額 のときだけ。false なら 申請額 <= 算出額（既定 false）
};
export const DEFAULT_AUTO: AutoRules = { enabled: false, shadow: true, max_oneway_yen: 1500, allow_bus: false, allowed_methods: ["train"], require_home_station: true, require_exact_match: false };

export type AutoInput = { claimed: number | null; method: string | null; home_station_known: boolean; store_station_known: boolean };
export type AutoResult = { mode: "off" | "shadow" | "live"; eligible: boolean; fare: number | null; reasons: string[] };

/** 自動承認の条件判定（純粋関数）。eligible=true でも mode が live のときだけ呼び出し側が承認する */
export function autoJudge(j: { judgement: string; computed: Candidate | null; reasonable: Candidate[] }, input: AutoInput, auto: Partial<AutoRules> | null | undefined): AutoResult {
  const a: AutoRules = { ...DEFAULT_AUTO, ...(auto ?? {}) };
  const mode: AutoResult["mode"] = a.enabled ? "live" : a.shadow ? "shadow" : "off";
  const no: string[] = [];
  if (j.judgement !== "auto_approvable") no.push(`仮判定が「自動承認できます」ではない（${j.judgement}）`);
  if (input.claimed === null || input.claimed === undefined) no.push("本人の申請額がない");
  if (!j.computed || j.computed.fare === null) no.push("API の算出額がない");
  if (j.computed && j.computed.fare !== null && input.claimed !== null && input.claimed !== undefined) {
    if (a.require_exact_match ? input.claimed !== j.computed.fare : input.claimed > j.computed.fare) no.push(`申請額 ${input.claimed} 円 が算出額 ${j.computed.fare} 円 と${a.require_exact_match ? "一致しない" : "合わない（申請額が上回る）"}`);
    if (j.computed.fare > a.max_oneway_yen) no.push(`片道 ${j.computed.fare} 円 が上限 ${a.max_oneway_yen} 円 を超える`);
    if (j.computed.uses_bus && !a.allow_bus) no.push("最安の経路がバスを含む");
  }
  if (input.method && !a.allowed_methods.includes(input.method)) no.push(`通勤手段が ${input.method}（自動承認は ${a.allowed_methods.join("/")} のみ）`);
  if (!input.method) no.push("通勤手段が未記入");
  if (a.require_home_station && !input.home_station_known) no.push("本人の最寄り駅が未登録（住所からの推定）");
  if (!input.store_station_known) no.push("店舗の最寄り駅が未登録");
  const eligible = no.length === 0 && mode !== "off";
  const fare = eligible && input.claimed !== null && input.claimed !== undefined ? input.claimed : null;
  const reasons = eligible ? [`申請額 ${fare} 円 ≦ API 算出額 ${j.computed?.fare} 円・片道 ${a.max_oneway_yen} 円以内・バスなし・通勤手段 ${input.method}`] : no;
  return { mode, eligible, fare, reasons };
}

/** 本人の「最寄り駅」欄（自由記入）を駅名検索に使える形へ。例: "大口駅（JR横浜線）" → "大口"、"橋本駅（JR横浜線）／電車で40ほど" → "橋本"、"電車40分" → ""（駅名なし＝住所から探す） */
export function normalizeStationName(raw: unknown): string {
  let s = String(raw ?? "").trim();
  if (!s) return "";
  s = s.split(/[／/、,・\n]/)[0].trim();                  // 複数書いてあれば先頭
  s = s.replace(/[（(][^）)]*[）)]/g, "").trim();           // （JR横浜線）などの括弧
  s = s.replace(/\s*(駅|えき)$/u, "").trim();              // 末尾の「駅」
  if (!s || /^\d/.test(s) || /^(電車|バス|徒歩|自転車|車|約|なし|無し|不明)/.test(s) || /\d+\s*分/.test(s) || s.length > 20) return "";
  return s;
}
