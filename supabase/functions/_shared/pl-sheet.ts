// PLシート（DB_PL）の行を「0円」に書き換える共通処理（担当C・2026-10-14）
// 背景: tori-dashboard の writePlFee は請求書ID（source_key）単位でDB_PLへupsertする設計で、削除APIが無い。
//   そのため PL反映の取り消し・請求書の削除をしても、シート側の行が孤立して残り、PLが二重・過大になる
//   （2026-10-14 アールエスエス9月分で発生）。取り消し・削除の時に、同じキーで金額0を書き込んで無効化する。
//   （writePlFee は金額0を許容。負数は不可。行自体は0円のまま残るが、集計には影響しない）
const DASH_API_URL = "https://script.google.com/macros/s/AKfycbwW0qhyEr0-uQWTaLg7MkQhurHq6wMoaOKL7uCCnI_bgnAsGB5-auqG_dm_Q9uJc3Kc/exec";

export async function zeroPlSheet(p: {
  accountName: string; subAccount?: string | null; ym: string; // YYYY-MM または YYYY-MM-DD
  storeNames: string[]; sourceId: string; vendorName?: string | null;
}): Promise<{ ok: boolean; error?: string; stores: number }> {
  const names = [...new Set(p.storeNames.map((s) => String(s ?? "").trim()).filter(Boolean))];
  if (!names.length) return { ok: true, stores: 0 };
  const tk = Deno.env.get("AD_COST_WRITE_TOKEN");
  if (!tk) return { ok: false, error: "AD_COST_WRITE_TOKEN が未設定です", stores: names.length };
  try {
    const res = await fetch(DASH_API_URL, {
      method: "POST", headers: { "Content-Type": "text/plain;charset=utf-8" },
      body: JSON.stringify({
        action: "writePlFee", token: tk, year_month: String(p.ym).slice(0, 7), account_name: p.accountName,
        sub_account: p.subAccount || undefined, allocations: names.map((n) => ({ store_name: n, amount: 0 })),
        source_invoice_id: p.sourceId, vendor_name: p.vendorName ?? undefined,
      }),
    });
    const text = await res.text();
    let j: any; try { j = JSON.parse(text); } catch { return { ok: false, error: "GASの応答を読めませんでした: " + text.slice(0, 200), stores: names.length }; }
    if (!j.ok) return { ok: false, error: j.error || "GAS側で失敗しました", stores: names.length };
    const bad = (Array.isArray(j.results) ? j.results : []).filter((x: any) => x && x.ok === false);
    if (bad.length) return { ok: false, error: bad.map((x: any) => `${x.store}: ${x.error}`).join("／"), stores: names.length };
    return { ok: true, stores: names.length };
  } catch (e) {
    return { ok: false, error: String((e as Error)?.message ?? e), stores: names.length };
  }
}
