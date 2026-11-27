// 2026-11-27: 精算書へ登録するとき補助科目が空なら、MFの仕訳の補助科目を使う（仕訳どおりの科目・補助科目で入れる）
export type Debit = { account_name?: string | null; sub_account_name?: string | null; value?: number | string | null };

const nz = (x: unknown) => String(x ?? "").normalize("NFKC").trim();
// 精算書の科目名 と MFの科目名の違い
const ALIAS: [string, string][] = [["仕入（食材・飲料）", "仕入高"], ["消耗品・備品費", "備品・消耗品費"], ["家賃", "地代家賃"], ["退職金等", "退職金"], ["採用教育費", "研修採用費"]];

// 戻り値: sub=使う補助科目（仕訳に無ければ空）。choices=仕訳の内訳が複数で決められない
export function pickSubAccount(debits: Debit[], accountName: string, amount: number, taxRate: string): { sub: string } | { choices: string[] } {
  const names = new Set([nz(accountName)]);
  for (const [a, b] of ALIAS) { if (nz(a) === nz(accountName)) names.add(nz(b)); if (nz(b) === nz(accountName)) names.add(nz(a)); }
  const cands = debits.filter((d) => names.has(nz(d.account_name)));
  if (!cands.length) return { sub: "" };
  const rate = taxRate === "8%" ? 1.08 : taxRate === "10%" ? 1.1 : 1;
  // 金額（税込または税抜）が合う明細があれば、その明細だけで決める
  const hit = cands.filter((d) => Math.abs(Number(d.value) - amount) <= 3 || Math.abs(Number(d.value) * rate - amount) <= 3);
  const subs = [...new Set((hit.length ? hit : cands).map((d) => String(d.sub_account_name ?? "").trim()))];
  return subs.length === 1 ? { sub: subs[0] } : { choices: subs.map((s) => s || "（補助科目なし）") };
}
