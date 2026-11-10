// 駅すぱあと API（/v1/json/search/course/plain）の応答を模したモック（2026-11-09）。
// 2026-11-10: 実 API で形を確認済み（Course は配列／1 件のときの形は未確認のため単数も吸収・Price の kind は FareSummary/Teiki1Summary/ChargeSummary・Line.Type は文字列かオブジェクト・時間は分）。実応答そのものは fixtures/ekispert-real-2026-11-10.json。
// 以下は説明用の想定データ。
//   実 API の応答（単数/配列の揺れ・Price の kind 名・Line.Type の値・timeWalk の単位）は評価版キー到着後に必ず実物で検証し、
//   違いがあれば parseCourses（commute-judge.ts）とこのモックを直す。本番コードはこのファイルを import しない（テスト専用）。
export type MockLine = { name: string; type?: "train" | "bus" | "walk" | string };
export type MockCourse = {
  points: string[];                    // 駅名の並び（出発→到着）
  lines: MockLine[];                   // 利用路線
  onBoard: number; walk?: number; other?: number; transfers?: number;
  fare?: number | null; round?: number | null; teiki1?: number | null; teiki3?: number | null; teiki6?: number | null;
  fareKind?: "FareSummary" | "Fare";   // 運賃の kind（合算は FareSummary）
};

/** 1 経路ぶんの Course オブジェクト */
export function mockCourse(c: MockCourse): any {
  const Price: any[] = [];
  if (c.fare !== null && c.fare !== undefined) Price.push({ kind: c.fareKind ?? "FareSummary", Oneway: String(c.fare), Round: String(c.round ?? c.fare * 2) });
  if (c.teiki1 != null) Price.push({ kind: "Teiki1Summary", Oneway: String(c.teiki1) });
  if (c.teiki3 != null) Price.push({ kind: "Teiki3Summary", Oneway: String(c.teiki3) });
  if (c.teiki6 != null) Price.push({ kind: "Teiki6Summary", Oneway: String(c.teiki6) });
  // 実 API（2026-11-10 確認）: 鉄道・徒歩は文字列 "train"/"walk"、バスは {text:"bus",detail:"local"}、新幹線は {text:"train",detail:"shinkansen"}
  const Line = c.lines.map((l) => ({ Name: l.name, Type: l.type === "bus" ? { text: "bus", detail: "local" } : l.type === "shinkansen" ? { text: "train", detail: "shinkansen" } : (l.type ?? "train") }));
  const Point = c.points.map((p) => ({ Station: { Name: p, code: String(10000 + p.length) } }));
  return { Route: { timeOnBoard: String(c.onBoard), timeWalk: String(c.walk ?? 0), timeOther: String(c.other ?? 0), transferCount: String(c.transfers ?? Math.max(0, c.lines.length - 1)), Line: Line.length === 1 ? Line[0] : Line, Point: Point.length === 1 ? Point[0] : Point }, Price: Price.length === 1 ? Price[0] : Price };
}

/** ResultSet 全体（Course は 1 件だとオブジェクト、2 件以上で配列＝XML 由来の揺れを再現） */
export function mockResultSet(courses: MockCourse[]): any {
  const list = courses.map(mockCourse);
  return { ResultSet: { apiVersion: "1.27.0.0", engineVersion: "mock", Course: list.length === 1 ? list[0] : list } };
}

/** エラー応答（キー不正・駅なし等） */
export function mockError(message = "Invalid access key", code = "W403"): any {
  return { ResultSet: { apiVersion: "1.27.0.0", Error: { code, Message: message } } };
}

// 代表的なシナリオ（テストと説明用）
export const SCENARIOS = {
  /** 通常: 1 経路・鉄道のみ */
  single: () => mockResultSet([{ points: ["田町", "新橋"], lines: [{ name: "JR山手線" }], onBoard: 6, walk: 2, fare: 170, round: 340, teiki1: 5110 }]),
  /** 複数経路: 最速だが高い / 少し遅いが安い / 乗換多い */
  multi: () => mockResultSet([
    { points: ["新横浜", "品川", "田町"], lines: [{ name: "JR東海道線快速" }, { name: "JR山手線" }], onBoard: 18, walk: 4, transfers: 1, fare: 1540 },
    { points: ["新横浜", "横浜", "田町"], lines: [{ name: "JR横浜線" }, { name: "JR京浜東北線" }], onBoard: 34, walk: 3, transfers: 1, fare: 580, teiki1: 17000 },
    { points: ["新横浜", "菊名", "目黒", "田町"], lines: [{ name: "JR横浜線" }, { name: "東急東横線" }, { name: "都営三田線" }], onBoard: 38, walk: 6, transfers: 3, fare: 520 },
  ]),
  /** バスを含む最安経路 */
  bus: () => mockResultSet([
    { points: ["本厚木", "厚木バスセンター", "愛甲石田"], lines: [{ name: "神奈中バス", type: "bus" }, { name: "小田急線" }], onBoard: 20, walk: 1, transfers: 1, fare: 390 },
    { points: ["本厚木", "愛甲石田"], lines: [{ name: "小田急線" }], onBoard: 5, walk: 12, fare: 170 },
  ]),
  /** 運賃なし（経路は出るが Price が無い＝検索失敗扱い） */
  noFare: () => mockResultSet([{ points: ["A", "B"], lines: [{ name: "徒歩", type: "walk" }], onBoard: 0, walk: 25, fare: null }]),
  /** 経路 0 件 */
  empty: () => ({ ResultSet: { apiVersion: "1.27.0.0" } }),
  /** エラー */
  error: () => mockError(),
};
