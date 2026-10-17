// 賃金（時給・月給）をLINEの返信文から読み取る（担当B・2026-10-17）。入社登録のLINE通知への返信用。
//   例: 「時給 1200」「時給 1200 休日 1300」「月給 250000」「新橋 1400」（その店舗だけの時給）。複数行・「、」区切りで並べてもよい。
//   先頭に本人の名前を付けてもよい（複数人が承認待ちのときの見分け用）。
// 純粋な関数だけ（DB・LINEには触らない）＝単体テストできる。
export type Store = { id: string; name: string };
export type WageItem = { division: 0 | 2; store_id: string | null; store_name: string | null; wage: number; holiday_wage: number | null };
export type ParseResult = { items: WageItem[]; errors: string[]; nameHit: number | null };

export const norm = (s: string) => String(s ?? "").normalize("NFKC").replace(/[\s　]+/g, "").toLowerCase();

const num = (s: string) => Number(String(s).replace(/,/g, ""));

// personNames: 承認待ちの人の名前（先頭一致で「どの人の賃金か」を決める用。見つかった最初の人のindexをnameHitで返す）
export function parseWageReply(text: string, stores: Store[], personNames: string[] = []): ParseResult {
  const items: WageItem[] = []; const errors: string[] = [];
  let body = String(text ?? "").normalize("NFKC");
  // 先頭の名前（フルネームまたは名前の先頭2文字以上。複数人の承認待ちを見分ける用）。最も長く一致した人を選ぶ
  let nameHit: number | null = null;
  const nb = norm(body); let bestLen = 0;
  for (let i = 0; i < personNames.length; i++) {
    const pn = norm(personNames[i]); if (!pn) continue;
    let k = 0; while (k < pn.length && k < nb.length && pn[k] === nb[k]) k++;
    if (k >= 2 && k > bestLen && (k === pn.length || /^[^\d]/.test(nb.slice(k)))) { bestLen = k; nameHit = i; }
  }
  if (nameHit !== null) {
    // 本文から名前部分（bestLen文字ぶん。間のスペースも含めて）を取り除く
    let k = 0, out = "";
    for (const ch of body) { if (k < bestLen) { if (!/[\s　]/.test(ch)) k++; continue; } out += ch; }
    body = out;
  }
  const segs = body.split(/[\n、；;]+|,(?!\d{3}(?!\d))/).map((x) => x.trim()).filter(Boolean); // 1,200 のカンマでは分けない
  const re = /^(.*?)\s*(\d[\d,]*)\s*円?\s*(?:[(（]?\s*(?:休日|祝日|休)\s*(\d[\d,]*)\s*円?\s*[)）]?)?$/;
  for (const seg of segs) {
    const m = seg.match(re);
    if (!m) { errors.push(`「${seg}」の意味が読み取れませんでした`); continue; }
    const label = m[1].replace(/[\s:：=＝は]+$/g, "").trim();
    const wage = num(m[2]); const hol = m[3] ? num(m[3]) : null;
    const nl = norm(label);
    if (nl === "月給" || nl === "給料" || nl === "月額") {
      if (hol !== null) errors.push("月給には休日賃金はありません");
      if (wage < 50000 || wage > 2000000) { errors.push(`月給 ${wage}円は範囲外です（5万〜200万円）。桁を確認してください`); continue; }
      items.push({ division: 2, store_id: null, store_name: null, wage, holiday_wage: null });
      continue;
    }
    let store: Store | null = null;
    if (nl && nl !== "時給" && nl !== "時間給") {
      const hits = stores.filter((s) => norm(s.name).includes(nl) && nl.length >= 2);
      if (hits.length === 1) store = hits[0];
      else if (hits.length > 1) { errors.push(`「${label}」に当てはまる店舗が複数あります（${hits.map((h) => h.name).join("・")}）。もう少し長く書いてください`); continue; }
      else { errors.push(`「${label}」に当てはまる店舗が見つかりません`); continue; }
    }
    if (wage < 500 || wage > 20000) { errors.push(`時給 ${wage}円は範囲外です（500〜2万円）。桁を確認してください（月給なら「月給 ${wage}」）`); continue; }
    if (hol !== null && (hol < 500 || hol > 20000)) { errors.push(`休日賃金 ${hol}円は範囲外です`); continue; }
    items.push({ division: 0, store_id: store?.id ?? null, store_name: store?.name ?? null, wage, holiday_wage: hol });
  }
  // 同じ対象を2回書いたとき
  const seen = new Set<string>();
  for (const it of items) { const k = `${it.division}|${it.store_id ?? ""}`; if (seen.has(k)) errors.push("同じ内容（同じ店舗・区分）が2回書かれています"); seen.add(k); }
  if (!items.length && !errors.length) errors.push("金額が読み取れませんでした");
  return { items, errors, nameHit };
}

export function describeItems(items: WageItem[]): string {
  return items.map((it) => it.division === 2
    ? `月給 ${it.wage.toLocaleString("ja-JP")}円`
    : `時給 ${it.wage.toLocaleString("ja-JP")}円${it.holiday_wage != null ? `（休日 ${it.holiday_wage.toLocaleString("ja-JP")}円）` : ""}／${it.store_name ? it.store_name + "だけ" : "全事業所共通"}`).join("\n");
}

// 「はい」「いいえ」の判定
export function yesNo(text: string): "yes" | "no" | null {
  const t = norm(text).replace(/[。！!]/g, "");
  if (["はい", "ok", "おk", "okです", "お願いします", "おねがいします", "登録", "登録して", "yes", "y", "ええ", "はいok"].includes(t)) return "yes";
  if (["いいえ", "キャンセル", "やめる", "取り消し", "no", "n", "違う", "ちがう", "いや"].includes(t)) return "no";
  return null;
}

// 先頭の「1か月の最初の日」（月給の適用開始日用）
export const monthStart = (d: string) => d.slice(0, 7) + "-01";
