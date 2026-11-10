// 交通費の仮判定・自動承認判定の単体テスト（モック応答。2026-11-09）
//   実行: deno test supabase/functions/_shared/commute-judge.test.ts
//   ★ モックは公開ドキュメントから想定した形。実 API の形はキー到着後に検証（commute-mock.ts 冒頭）。
import { assertEquals, assert } from "jsr:@std/assert@1";
import { parseCourses, judge, autoJudge, normalizeStationName, pickStation, payHint, DEFAULT_RULES, DEFAULT_AUTO } from "./commute-judge.ts";
import REAL from "./fixtures/ekispert-real-2026-11-10.json" with { type: "json" };
import { SCENARIOS, mockResultSet } from "./commute-mock.ts";

const input = (claimed: number | null, method = "train", home = true, store = true) => ({ claimed, method, home_station_known: home, store_station_known: store });

Deno.test("通常経路: 1 件（オブジェクト形）を読める・申請額が一致すれば自動承認できます", () => {
  const c = parseCourses(SCENARIOS.single().ResultSet);
  assertEquals(c.length, 1);
  assertEquals(c[0].fare, 170); assertEquals(c[0].round, 340); assertEquals(c[0].teiki1, 5110); assertEquals(c[0].time_min, 8); assertEquals(c[0].uses_bus, false);
  const j = judge(c, 170, DEFAULT_RULES);
  assertEquals(j.judgement, "auto_approvable"); assertEquals(j.computed?.fare, 170);
  const a = autoJudge(j, input(170), DEFAULT_AUTO);
  assertEquals(a.mode, "shadow"); assertEquals(a.eligible, true); assertEquals(a.fare, 170);
});

Deno.test("複数経路: 最速＋15 分・乗換 2 回以内に絞り、その中の最安を算出額にする", () => {
  const c = parseCourses(SCENARIOS.multi().ResultSet);
  assertEquals(c.length, 3);
  const j = judge(c, 580, DEFAULT_RULES);
  // 最速 22 分（新幹線）。+15 分以内＝37 分までなので 横浜経由（37 分）は入り、菊名経由（44 分・乗換 3）は外れる
  assertEquals(j.reasonable.map((r) => r.index), [0, 1]);
  assertEquals(j.computed?.fare, 580);
  assertEquals(j.judgement, "auto_approvable");
});

Deno.test("運賃不一致: 申請額が候補の最高＋許容を超えると「本人に確認」", () => {
  const c = parseCourses(SCENARIOS.multi().ResultSet);
  const j = judge(c, 2500, DEFAULT_RULES);
  assertEquals(j.judgement, "person_review");
  const a = autoJudge(j, input(2500), DEFAULT_AUTO);
  assertEquals(a.eligible, false);
});

Deno.test("運賃が候補の範囲内（最安より高いが最高＋許容以内）は本部確認", () => {
  const c = parseCourses(SCENARIOS.multi().ResultSet);
  const j = judge(c, 1600, DEFAULT_RULES); // 最高 1540 + 許容 max(100, 308)=308 → 1848 まで hq_review
  assertEquals(j.judgement, "hq_review");
});

Deno.test("バス利用: 最安の合理的経路がバスを含むと本部確認・自動承認の対象外", () => {
  const c = parseCourses(SCENARIOS.bus().ResultSet);
  assert(c[0].uses_bus); assert(!c[1].uses_bus);
  // 鉄道のみ経路は徒歩 12 分（960m）で合理的。最安は鉄道 170 円 → 申請 170 なら自動承認できます（バス経路は比較相手ではない）
  const j1 = judge(c, 170, DEFAULT_RULES);
  assertEquals(j1.judgement, "auto_approvable");
  // 徒歩上限を 500m にすると鉄道のみ経路が外れ、最安がバス経路に → 本部確認
  const j2 = judge(c, 390, { ...DEFAULT_RULES, max_walk_m: 500 });
  assertEquals(j2.judgement, "hq_review");
  assert(j2.reasons.some((r) => r.includes("バス")));
  const a = autoJudge({ ...j2, judgement: "auto_approvable" }, input(390, "train_bus"), { ...DEFAULT_AUTO, enabled: true });
  assertEquals(a.eligible, false);
  assert(a.reasons.some((r) => r.includes("バス")) && a.reasons.some((r) => r.includes("通勤手段")));
});

Deno.test("検索失敗: 運賃なし／0 件／エラー応答は search_failed", () => {
  assertEquals(judge(parseCourses(SCENARIOS.noFare().ResultSet), 200, DEFAULT_RULES).judgement, "search_failed");
  assertEquals(parseCourses(SCENARIOS.empty().ResultSet).length, 0);
  assertEquals(judge([], 200, DEFAULT_RULES).judgement, "search_failed");
  assertEquals(parseCourses(SCENARIOS.error().ResultSet).length, 0);
});

Deno.test("申請額なしは本部確認（自動承認しない）", () => {
  const j = judge(parseCourses(SCENARIOS.single().ResultSet), null, DEFAULT_RULES);
  assertEquals(j.judgement, "hq_review");
  assertEquals(autoJudge(j, input(null), DEFAULT_AUTO).eligible, false);
});

Deno.test("条件に合う経路が無いときは最速だけを候補にし、理由を残す", () => {
  const rs = mockResultSet([
    { points: ["A", "B", "C", "D"], lines: [{ name: "1" }, { name: "2" }, { name: "3" }, { name: "4" }], onBoard: 30, transfers: 3, fare: 500 },
    { points: ["A", "E", "F", "G", "D"], lines: [{ name: "1" }, { name: "2" }, { name: "3" }, { name: "4" }], onBoard: 50, transfers: 3, fare: 400 },
  ]);
  const j = judge(parseCourses(rs.ResultSet), 500, DEFAULT_RULES);
  assertEquals(j.reasonable.length, 1); assertEquals(j.computed?.fare, 500);
  assert(j.reasons[0].includes("最速の経路だけ"));
});

Deno.test("自動承認: 既定は OFF（shadow）。enabled で live。片道上限・最寄り駅未登録・申請額が上回る と対象外", () => {
  const j = judge(parseCourses(SCENARIOS.single().ResultSet), 170, DEFAULT_RULES);
  assertEquals(autoJudge(j, input(170), { enabled: false, shadow: false }).mode, "off");
  assertEquals(autoJudge(j, input(170), { enabled: false, shadow: false }).eligible, false);
  const live = autoJudge(j, input(170), { enabled: true });
  assertEquals(live.mode, "live"); assertEquals(live.eligible, true);
  assertEquals(autoJudge(j, input(170), { enabled: true, max_oneway_yen: 100 }).eligible, false);
  assertEquals(autoJudge(j, input(170, "train", false), { enabled: true }).eligible, false);
  assertEquals(autoJudge(j, input(170, "train", true, false), { enabled: true }).eligible, false);
  const j2 = judge(parseCourses(SCENARIOS.single().ResultSet), 160, DEFAULT_RULES); // 申請 160 < 170 → 自動承認できます（本人が安い額）
  assertEquals(autoJudge(j2, input(160), { enabled: true }).fare, 160);
  assertEquals(autoJudge(j2, input(160), { enabled: true, require_exact_match: true }).eligible, false);
});

Deno.test("判定の数値は app_settings.commute_rules で変えられる（許容額・最速＋分）", () => {
  const c = parseCourses(SCENARIOS.multi().ResultSet);
  const j = judge(c, 1600, { ...DEFAULT_RULES, tolerance_yen: 0, tolerance_pct: 0 });
  assertEquals(j.judgement, "person_review");
  const j2 = judge(c, 520, { ...DEFAULT_RULES, max_extra_minutes: 30, max_transfers: 3 });
  assertEquals(j2.reasonable.length, 3); assertEquals(j2.computed?.fare, 520); assertEquals(j2.judgement, "auto_approvable");
});

Deno.test("最寄り駅の自由記入を駅名に正規化（本番の extra の実例に基づく）", () => {
  assertEquals(normalizeStationName("大口駅（JR横浜線）"), "大口");
  assertEquals(normalizeStationName("橋本駅（JR横浜線）／電車で40ほど"), "橋本");
  assertEquals(normalizeStationName("電車40分"), "");
  assertEquals(normalizeStationName("田町"), "田町");
  assertEquals(normalizeStationName("新横浜駅"), "新横浜");
  assertEquals(normalizeStationName(" 川崎 (JR) "), "川崎");
  assertEquals(normalizeStationName(null), "");
});

// ---- 2026-11-10: 実 API の応答（fixtures/ekispert-real-2026-11-10.json。個人情報なし）での検証 ----
Deno.test("実応答: 田町→新橋。経路 5 件・最安 160 円・定期 1/3/6 が読める", () => {
  const c = parseCourses((REAL as any).tamachi_shinbashi);
  assertEquals(c.length, 5); assertEquals(c[0].fare, 160); assertEquals(c[0].round, 320); assertEquals(c[0].teiki1, 4910); assertEquals(c[0].teiki3, 13960); assertEquals(c[0].teiki6, 26620);
  const j = judge(c, 160, DEFAULT_RULES);
  assertEquals(j.judgement, "auto_approvable"); assertEquals(j.computed?.fare, 160);
  assertEquals(payHint(j.computed).break_even_days, 16);
});
Deno.test("実応答: バスは Type がオブジェクト {text:'bus'} → uses_bus を正しく判定。運賃なし（徒歩のみ）は候補外", () => {
  const c = parseCourses((REAL as any).honatsugi_bus);
  assert(c.some((x) => x.uses_bus)); assert(c.some((x) => x.fare === null));
  const j = judge(c, 230, DEFAULT_RULES);
  assertEquals(j.computed?.uses_bus, true); assertEquals(j.judgement, "hq_review");   // 最安の経路がバス → 本部確認
});
Deno.test("実応答: 新幹線（別料金 870 円）は既定で候補にしない。運賃だけ安く見える経路を最安にしない", () => {
  const all = parseCourses((REAL as any).shinyokohama_tamachi_all);
  assert(all.some((x) => x.uses_express && x.charge === 870));
  const j = judge(all, 570, DEFAULT_RULES);
  assert(j.reasonable.every((x) => !x.uses_express)); assertEquals(j.computed?.fare, 570);
  const j2 = judge(all, 430, DEFAULT_RULES);   // 新幹線の運賃（430）で申請しても自動承認にならない（430 ≦ 570 だが…）
  assertEquals(j2.computed?.fare, 570);
  const allow = judge(all, 1300, { ...DEFAULT_RULES, allow_express: true, max_extra_minutes: 60 });
  assert(allow.reasonable.some((x) => x.uses_express)); assert(allow.reasonable.filter((x) => x.uses_express).every((x) => (x.fare ?? 0) >= 1300));   // 許可時は 運賃＋料金 で比較
  const noexp = parseCourses((REAL as any).shinyokohama_tamachi_noexp);
  assert(noexp.every((x) => !x.uses_express)); assertEquals(Math.min(...noexp.map((x) => x.fare ?? 9e9)), 530);
});
Deno.test("実応答: 同名駅は会社のエリア（東京・神奈川…）を優先。エリア外しか無ければ null（推測しない）", () => {
  const n = pickStation((REAL as any).station_nihonbashi.Point, "日本橋");
  assertEquals(n?.name, "日本橋(東京都)"); assertEquals(n?.ambiguous, true);
  const k = pickStation((REAL as any).station_kawasaki.Point, "川崎");
  assertEquals(k?.name, "川崎"); assertEquals(k?.ambiguous, false);
  assertEquals(pickStation((REAL as any).station_none.Point, "名古屋"), null);
  assertEquals(pickStation((REAL as any).station_nihonbashi.Point, "日本橋", ["北海道"]), null);
});
