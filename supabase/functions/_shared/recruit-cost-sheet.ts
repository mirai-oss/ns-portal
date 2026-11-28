// 求人広告費の内訳シート（月ごとに 1 シート）を読み、固定費を広告費の割合で按分して recruit_costs の行にする。
//   ここは計算だけ（読み込み・書き込み・通知は functions/recruit-cost-sync）。金額・ファイルの場所はコードに書かない（設定から読む）。

export type Cell = string | number | null;
export type Sheet = { name: string; rows: Cell[][] };
export type CostRow = { area: string; form_key: "al" | "shain"; ad: number; amount: number };

const norm = (v: Cell) => String(v ?? "").replace(/[\s　]/g, "");

export function yen(v: Cell): number | null {
  if (typeof v === "number") return Number.isFinite(v) ? Math.round(v) : null;
  const s = norm(v).replace(/[¥￥,，円]/g, "");
  return /^\d+(\.\d+)?$/.test(s) ? Math.round(Number(s)) : null;
}

/** シートの対象月（YYYY-MM）。見出しの期間（YYYYMM01_…）を優先し、無ければシート名（YYYYM / YYYYMM）。 */
export function sheetMonth(s: Sheet): string | null {
  for (const row of s.rows.slice(0, 5)) {
    for (const c of row) {
      const m = norm(c).match(/(20\d{2})(0[1-9]|1[0-2])01[_＿\-〜～]/);
      if (m) return `${m[1]}-${m[2]}`;
    }
  }
  const n = norm(s.name).match(/^(20\d{2})(1[0-2]|0?[1-9])$/);
  return n ? `${n[1]}-${n[2].padStart(2, "0")}` : null;
}

/** 企業名（店舗名）→ 市区町村の順で、管理システムの応募画面のエリア名にする。分からなければ null（勝手に決めない）。 */
export function areaOf(company: Cell, city: Cell): string | null {
  const c = norm(company);
  for (const [k, a] of [["恵比寿", "恵比寿"], ["新横浜", "新横浜"], ["はなれ", "はなれ"], ["芝", "芝"], ["本店", "本店"], ["新橋", "新橋"], ["川崎", "川崎"]]) if (c.includes(k)) return a;
  const t = norm(city);
  for (const [k, a] of [["川崎市", "川崎"], ["港北区", "新横浜"], ["渋谷区", "恵比寿"]]) if (t.includes(k)) return a;
  return null;
}

export function formOf(v: Cell): "al" | "shain" | null {
  const s = norm(v);
  if (s.includes("正社員")) return "shain";
  if (s.includes("アルバイト") || s.includes("パート")) return "al";
  return null;
}

/** 1 シートを読む。各行の合計がシートの「合計」と合わない・読めない行があるときは、例外（何も書かない）。 */
export function parseSheet(s: Sheet): { area: string; form_key: "al" | "shain"; ad: number }[] {
  const h = s.rows.findIndex((r) => r.some((c) => norm(c) === "求人") && r.some((c) => norm(c) === "費用"));
  if (h < 0) throw new Error("見出し（求人・費用）が見つかりません");
  const col = (name: string) => {
    const i = s.rows[h].findIndex((c) => norm(c) === name);
    if (i < 0) throw new Error(`見出し「${name}」が見つかりません`);
    return i;
  };
  const [job, city, company, cost, form] = ["求人", "市区町村", "企業名", "費用", "雇用形態"].map(col);
  const group = new Map<string, { area: string; form_key: "al" | "shain"; ad: number }>();
  let sum = 0, total: number | null = null;
  for (let i = h + 1; i < s.rows.length; i++) {
    const r = s.rows[i];
    if (r.some((c) => norm(c) === "合計")) { total = yen(r[cost]) ?? r.map(yen).find((x) => x !== null) ?? null; break; }
    if (!norm(r[job]) && !norm(r[cost])) continue;
    const ad = yen(r[cost]), area = areaOf(r[company], r[city]), fk = formOf(r[form]);
    if (ad === null) throw new Error(`${i + 1} 行目の費用が読めません`);
    if (!area) throw new Error(`${i + 1} 行目の店舗（エリア）が分かりません: ${String(r[company] ?? "")} / ${String(r[city] ?? "")}`);
    if (!fk) throw new Error(`${i + 1} 行目の雇用形態が分かりません: ${String(r[form] ?? "")}`);
    sum += ad;
    const key = `${area}|${fk}`;
    const g = group.get(key) ?? { area, form_key: fk, ad: 0 };
    g.ad += ad;
    group.set(key, g);
  }
  if (total === null) throw new Error("「合計」の行が見つかりません");
  if (sum !== total) throw new Error(`行の合計（${sum}）がシートの「合計」（${total}）と合いません`);
  if (!group.size || sum <= 0) throw new Error("広告費の行がありません（固定費を按分できません）");
  return [...group.values()];
}

/** 固定費を広告費の割合で按分して足す。端数は余りの大きい順に 1 円ずつ配り、合計は必ず「広告費＋固定費」になる。 */
export function allocate(ads: { area: string; form_key: "al" | "shain"; ad: number }[], fee: number): CostRow[] {
  const total = ads.reduce((s, a) => s + a.ad, 0);
  const parts = ads.map((a) => ({ ...a, share: Math.floor((fee * a.ad) / total), rem: (fee * a.ad) % total }));
  let rest = fee - parts.reduce((s, p) => s + p.share, 0);
  for (const p of [...parts].sort((x, y) => y.rem - x.rem || `${x.area}${x.form_key}`.localeCompare(`${y.area}${y.form_key}`))) {
    if (rest <= 0) break;
    p.share++; rest--;
  }
  return parts.map((p) => ({ area: p.area, form_key: p.form_key, ad: p.ad, amount: p.ad + p.share }));
}

/** 日本時間で見た「前の月」（YYYY-MM）。 */
export function previousMonthJst(now: Date): string {
  const j = new Date(now.getTime() + 9 * 3600e3);
  const d = new Date(Date.UTC(j.getUTCFullYear(), j.getUTCMonth() - 1, 1));
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}`;
}
