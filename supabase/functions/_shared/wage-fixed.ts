// 2026-11-18 月給の行を、スマレジへ送るときの固定残業代の扱い（実測: docs/実測結果_固定残業代のスマレジ書き込み_2026-11-18.md）
//   ・fixedWage を付けずに PUT すると、スマレジの固定残業代は消える → 消さないための計画を、送る前に立てる
//   ・外すには fixedWage を付けない（または null）。rules: [] は使わない
//   ・管理システムは「あり／なし／未設定」と金額だけ持つ（含める区分は持たない）。区分は、スマレジの今の行で適用中ならそのまま引き継ぎ、無ければ 6 つ全部
export const ALL_RULES = ["statutoryOvertime", "midnight", "prescribedHoliday", "statutoryHoliday", "month45HourOvertime", "month60HourOvertime"] as const;
export type CurrentFixed = { flag: string | number | null; amount: string | number | null; flags: Array<string | number | null> } | null;
export type FixedPlan =
  | { kind: "send"; fixedWage: { amount: number; rules: { ruleType: string }[] } }
  | { kind: "plain" }                         // 付けずに送る（スマレジ側にも固定残業代が無い／「なし」を送る）
  | { kind: "refuse"; reason: string };       // 送らない（固定残業代を消してしまうため）

const on = (v: unknown) => String(v ?? "0") === "1";
export function rulesFromFlags(flags: Array<string | number | null> | undefined): string[] {
  const r = (flags ?? []).map((f, i) => (on(f) ? ALL_RULES[i] : null)).filter(Boolean) as string[];
  return r;
}
export function planFixedWage(row: { fixed_ot_state?: string | null; fixed_ot_amount?: number | null }, cur: CurrentFixed): FixedPlan {
  const state = row.fixed_ot_state ?? "unknown";
  const curOn = !!cur && on(cur.flag) && Number(cur.amount ?? 0) > 0;
  if (state === "applied") {
    const amount = Number(row.fixed_ot_amount ?? 0);
    if (!Number.isInteger(amount) || amount < 1) return { kind: "refuse", reason: "固定残業代の金額が不正なため、スマレジへは送りません" };
    const keep = curOn ? rulesFromFlags(cur!.flags) : [];
    const rules = keep.length ? keep : [...ALL_RULES];
    return { kind: "send", fixedWage: { amount, rules: rules.map((ruleType) => ({ ruleType })) } };
  }
  if (state === "none") return { kind: "plain" };
  // unknown: スマレジに固定残業代があるなら、送ると消えてしまうので送らない。無ければ、これまでどおり基本賃金だけを送る
  if (curOn) return { kind: "refuse", reason: "スマレジのこの行には固定残業代があります。管理システムの固定残業代が未設定のため、送ると消えてしまいます。先に固定残業代を設定してください" };
  return { kind: "plain" };
}
// 送ったあとに読み直した行との照合。違う項目の名前を返す（空なら全部一致）
export function verifyFixedWage(row: { wage: number; effective_date: string }, plan: FixedPlan, read: { wage: number; flag: string | number | null; amount: string | number | null; flags: Array<string | number | null> } | null): string[] {
  if (!read) return ["スマレジに行が見つかりません"];
  const bad: string[] = [];
  if (Number(read.wage) !== Number(row.wage)) bad.push("基本賃金");
  if (plan.kind === "send") {
    if (!on(read.flag)) bad.push("固定残業代を適用する");
    if (Number(read.amount ?? 0) !== plan.fixedWage.amount) bad.push("固定残業代の金額");
    const want = new Set(plan.fixedWage.rules.map((x) => x.ruleType));
    ALL_RULES.forEach((n, i) => { if (on(read.flags?.[i]) !== want.has(n)) bad.push("含める区分(" + n + ")"); });
  } else if (plan.kind === "plain") {
    if (on(read.flag) || Number(read.amount ?? 0) > 0) bad.push("固定残業代（無いはずが残っている）");
  }
  return bad;
}
