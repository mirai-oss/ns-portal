// 行ルールの再学習（MFの総勘定元帳＝実際の仕訳から）— TK-216⑥・設計書§9-1①（担当C・2026-10-17）
//
// 取引先ごとの行ルール（vendor_line_rules・line_pattern='*'）の借方（科目・補助科目）を、MFにある直近の実際の仕訳と比べ、
// 実績のほうが違うものを「提案」として返す（読み取りのみ。MFにも行ルールにも何も書かない）。
// 適用は画面の「このルールに更新」で、ログイン中の人が save_vendor_line_rule(p_source='ledger') を呼ぶ（人が確認して承認）。
//
// 入力(JSON): { tenant_id?:'default', months?:6 }（ログインしたユーザーのJWT。invoice_can_access() が必要）
// 出力: { proposals:[{ vendor_key, rule_id, current:{account, sub, sub_mode}, observed:[{account, sub, count, last_date, total}], recommend:{account, sub_account_mode, sub_account_name}, status }], checked, journals }
import { createClient } from "npm:@supabase/supabase-js@2";
import { getValidAccessToken, mfFetch } from "../_shared/mf.ts";
import { splitByFiscalYear } from "../_shared/mf-fiscal.ts";

const cors: Record<string, string> = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info" };
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });
const norm = (t: unknown) => String(t ?? "").normalize("NFKC").replace(/\s+/g, "").replace(/株式会社|有限会社|合同会社|\(株\)|\(有\)|㈱|㈲|（株）|（有）/g, "").toLowerCase();

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return json({ error: "POSTのみ対応" }, 405);
  let body: any = {}; try { body = await req.json(); } catch { /* 空でよい */ }
  const uc = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } });
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  let authed = false;
  if (body?.secret) { const { data: sr } = await db.from("app_secrets").select("value").eq("key", "invoice_intake_secret").maybeSingle(); authed = !!sr?.value && body.secret === sr.value; }   // 動作確認用（サーバー間）
  if (!authed) {
    const { data: ok, error: aerr } = await uc.rpc("invoice_can_access");
    if (aerr || ok !== true) return json({ error: "権限がありません" }, 403);
  }
  const tenant: string = body?.tenant_id || "default";
  const months = Math.min(Math.max(Number(body?.months) || 6, 1), 12);
  try {
    const { data: rules, error: re } = await db.from("v_vendor_line_rule_status").select("*").eq("tenant_id", tenant).eq("is_active", true).eq("line_pattern", "*");
    if (re) return json({ error: "行ルールの取得に失敗: " + re.message }, 500);
    if (!rules?.length) return json({ success: true, proposals: [], checked: 0, journals: 0, note: "この事業者の行ルールがありません" });
    const { accessToken } = await getValidAccessToken(tenant);
    const end = new Date(Date.now() + 9 * 3600e3).toISOString().slice(0, 10);
    const start = new Date(Date.now() - months * 31 * 86400e3).toISOString().slice(0, 10);
    const journals: any[] = [];
    for (const rg of splitByFiscalYear(tenant, start, end)) {   // 会計期間をまたぐ範囲はMFがエラーにするため、期間ごとに分けて取得
      for (let page = 1; page <= 20; page++) {
        const r = await mfFetch(`/api/v3/journals?start_date=${rg.start}&end_date=${rg.end}&per_page=500&page=${page}`, accessToken); const dj = await r.json();
        if (!r.ok) return json({ error: "MFの仕訳の取得に失敗しました", detail: dj }, 502);
        journals.push(...(dj.journals ?? [])); if ((dj.journals ?? []).length < 500) break;
      }
    }
    // 取引先ごとに、借方の（科目, 補助科目）の実績を数える。取引先は「借方の補助科目／取引先名／摘要」で結びつける
    const proposals: any[] = []; let checked = 0;
    for (const rule of rules) {
      const vk = norm(rule.vendor_key); if (!vk) continue;
      const tally = new Map<string, { account: string; sub: string; count: number; last: string; total: number }>();
      for (const j of journals) for (const br of j.branches ?? []) {
        const d = br.debitor; if (!d?.account_name) continue;
        const sub = norm(d.sub_account_name), par = norm(d.trade_partner_name), rem = norm(br.remark);
        const hit = (sub && (sub === vk || vk.includes(sub) || sub.includes(vk))) || (par && (par === vk || par.includes(vk) || vk.includes(par))) || (rem && rem.includes(vk));
        if (!hit) continue;
        if (/買掛金|未払金|未払費用|預金|現金|売掛金/.test(d.account_name)) continue;   // 支払い・消込側は除く（借方の費用・仕入側だけ）
        const k = `${d.account_name}|${d.sub_account_name ?? ""}`; const v = tally.get(k) ?? { account: d.account_name, sub: d.sub_account_name ?? "", count: 0, last: "", total: 0 };
        v.count++; v.total += Number(d.value) || 0; if (String(j.transaction_date) > v.last) v.last = String(j.transaction_date); tally.set(k, v);
      }
      const observed = [...tally.values()].sort((a, b) => b.count - a.count || (a.last < b.last ? 1 : -1));
      if (!observed.length) continue;
      checked++;
      const top = observed[0], totalCnt = observed.reduce((t, x) => t + x.count, 0);
      const curSub = rule.sub_account_mode === "fixed" ? (rule.sub_account_name ?? "") : rule.sub_account_mode === "vendor" ? rule.vendor_key : "";
      const same = top.account === rule.account_name && norm(top.sub) === norm(curSub);
      if (same) continue;
      // 実績が明らかに違うときだけ提案（2件以上かつ全体の6割以上）。それ以外は参考表示のみ
      const strong = top.count >= 2 && top.count / totalCnt >= 0.6;
      const subMode = !top.sub ? "none" : (norm(top.sub) === vk || vk.includes(norm(top.sub)) || norm(top.sub).includes(vk)) ? "vendor" : "fixed";
      proposals.push({
        vendor_key: rule.vendor_key, rule_id: rule.id, vendor_id: rule.vendor_id,
        current: { account: rule.account_name, sub: curSub, sub_mode: rule.sub_account_mode, unstable: !!rule.unstable },
        observed: observed.slice(0, 4), recommend: { account: top.account, sub_account_mode: subMode, sub_account_name: subMode === "fixed" ? top.sub : null },
        status: strong ? "differs" : "weak",
      });
    }
    proposals.sort((a, b) => (a.status === "differs" ? 0 : 1) - (b.status === "differs" ? 0 : 1));
    return json({ success: true, proposals, checked, journals: journals.length, range: { start, end } });
  } catch (e) {
    return json({ error: "再学習の確認中にエラー: " + String((e as Error)?.message ?? e) }, 500);
  }
});
