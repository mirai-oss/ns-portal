// 請求書メール自動処理 Phase4: マッピング接続（担当C・2026-10-13）
//
// 請求書の明細行（invoice_lines）の店舗表記を、店舗マスタ正本の共通ゲートウェイ resolve_store で正式な店舗に結びつける。
// 自前の店舗名照合は書かない（docs/resolve_store_使い方_2026-10-07.md）。
//  ・店舗コードがあり、取引先が定期請求書10社（インフォマート由来）なら resolve_store('infomart', p_code) を先に試す
//    ※インフォマートのコードとハブのstore_noは06と08が逆。必ずresolve_store経由で解決する（store_noとして扱わない）
//  ・それで決まらなければ resolve_store('invoice', p_name=店舗表記)。未解決は resolve_store が kd_unresolved_names に隔離記録する
//  ・店舗表記が無い行（1店舗だけの請求書）は、請求書の店舗→取引先の既定店舗で補う（rule）
//  ・confidence が exact/high のものだけ確定（resolved_by='mapping'）。low は確定せず resolve_info に候補だけ残す（人の確認へ）
//  ・人が確定した行（resolved_by='human'）は触らない
// 結果の要約は invoices.lines_check.mapping に書く。MFには何も登録しない。
//
// 認証: 共有シークレット（app_secrets.invoice_intake_secret）またはユーザーJWT（invoice_can_access）
// 入力(JSON): { secret?, invoice_id }
import { createClient } from "npm:@supabase/supabase-js@2";

const cors: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });
const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const userClient = (req: Request) =>
  createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return json({ error: "POSTのみ対応" }, 405);
  let body: any;
  try { body = await req.json(); } catch { return json({ error: "JSONの読み取りに失敗しました" }, 400); }
  if (!body?.invoice_id) return json({ error: "invoice_idが必要です" }, 400);
  const db = svc();
  if (body?.secret) {
    const { data: sr } = await db.from("app_secrets").select("value").eq("key", "invoice_intake_secret").maybeSingle();
    if (!sr?.value || body.secret !== sr.value) return json({ error: "認証エラー" }, 401);
  } else {
    const { data: ok, error } = await userClient(req).rpc("invoice_can_access");
    if (error || ok !== true) return json({ error: "権限がありません" }, 403);
  }

  const { data: inv } = await db.from("invoices").select("id, vendor_id, corporation_id, store_id, lines_check, intake_source").eq("id", body.invoice_id).maybeSingle();
  if (!inv) return json({ error: "請求書が見つかりません" }, 404);
  const { data: lines } = await db.from("invoice_lines").select("id, line_no, store_text, store_code, brand_text, resolved_by").eq("invoice_id", inv.id).order("line_no");
  if (!lines?.length) return json({ success: true, resolved: 0, note: "明細行がありません" });

  // 法人の手がかり（corp_code）
  let corpHint: string | null = null;
  if (inv.corporation_id) {
    const { data: c } = await db.from("corporations").select("corp_code").eq("id", inv.corporation_id).maybeSingle();
    corpHint = c?.corp_code ?? null;
  }
  // 取引先が定期請求書10社（行ルールあり＝インフォマート由来）か
  let isInfomartVendor = false; let vendorDefaultStore: string | null = null;
  if (inv.vendor_id) {
    const { count } = await db.from("vendor_line_rules").select("id", { count: "exact", head: true }).eq("vendor_id", inv.vendor_id).eq("is_active", true);
    isInfomartVendor = !!count;
    const { data: v } = await db.from("vendors").select("default_store_id").eq("id", inv.vendor_id).maybeSingle();
    vendorDefaultStore = v?.default_store_id ?? null;
  }

  // インフォマートから取り込んだ請求書（intake_source='infomart'）の店舗コードは、取引先に行ルールが無くても必ずインフォマートのコードとして解決する（06/08がハブのstore_noと逆）
  if (inv.intake_source === "infomart") isInfomartVendor = true;

  const cache = new Map<string, any>();
  const callResolve = async (args: Record<string, unknown>) => {
    const key = JSON.stringify(args);
    if (cache.has(key)) return cache.get(key);
    const { data, error } = await db.rpc("resolve_store", args);
    const hit = error ? null : (Array.isArray(data) ? data[0] ?? null : data);
    cache.set(key, hit);
    return hit;
  };

  // 2026-10-14: 店舗の表記が登録に無くても、この取引先が過去（直近3件のMF登録済み請求書）ずっと同じ1店舗宛だったなら、その店舗を「AIの推定」として当てる（承認で確認）
  let historyStore: string | null = null;
  if (inv.vendor_id) {
    const { data: v0 } = await db.from("vendors").select("name").eq("id", inv.vendor_id).maybeSingle();
    const { data: vs } = await db.from("vendors").select("id, name");
    const nn = (s: unknown) => String(s ?? "").normalize("NFKC").replace(/\s+/g, "").replace(/株式会社|有限会社|合同会社|㈱|㈲|\(株\)|\(有\)/g, "").toLowerCase();
    const ids = (vs ?? []).filter((x: any) => nn(x.name) === nn(v0?.name)).map((x: any) => x.id);
    const { data: past } = await db.from("invoices").select("id, store_id").in("vendor_id", ids.length ? ids : [inv.vendor_id])
      .not("mf_journal_id", "is", null).order("mf_journal_created_at", { ascending: false }).limit(3);
    const per: (string | null)[] = [];
    for (const pi of past ?? []) {
      const { data: st } = await db.from("invoice_stores").select("store_id").eq("invoice_id", pi.id);
      const set = new Set<string>((st ?? []).map((x: any) => x.store_id)); if (pi.store_id) set.add(pi.store_id);
      if (set.size === 0) continue;   // 店舗が記録されていない過去分は判断材料にしない
      per.push(set.size === 1 ? [...set][0] : null);
    }
    if (per.length && per.every((x) => x && x === per[0])) historyStore = per[0];
  }
  // 2026-10-19: 店名の前後に説明が付く表記（例:「和食と個室居酒屋 匠味 新横浜店」）は、resolve_store では部分一致（low）になり人の確認に回っていた。
  // 登録済みの店名・表示名・別名（4文字以上）が文中に含まれ、含まれる名前の持ち主がちょうど1店舗のときだけ、確定扱いにする（紛らわしいものは従来どおり人の確認）
  const nzs = (t: unknown) => String(t ?? "").normalize("NFKC").replace(/[\s　・･\-－ー()（）「」『』\[\]【】/]/g, "").toLowerCase();
  const tokens: { sid: string; tok: string }[] = [];
  { const { data: ss } = await db.from("stores").select("id, name, display_name"); const { data: as } = await db.from("store_aliases").select("store_id, alias");
    for (const s of ss ?? []) for (const n of [s.name, s.display_name]) { const t = nzs(n); if (t.length >= 4) tokens.push({ sid: s.id, tok: t }); }
    for (const a of as ?? []) { const t = nzs(a.alias); if (t.length >= 4) tokens.push({ sid: a.store_id, tok: t }); } }
  const containedOwner = (text: string): string | null => {
    const t = nzs(text); const hits = tokens.filter((x) => t.includes(x.tok));
    if (!hits.length) return null;
    const longest = Math.max(...hits.map((x) => x.tok.length));
    const owners = new Set(hits.filter((x) => x.tok.length === longest).map((x) => x.sid));   // 一番長く当たった名前の持ち主
    return owners.size === 1 ? [...owners][0] : null;
  };
  let resolved = 0, low = 0, unresolved = 0, skipped = 0;
  const unresolvedNames = new Set<string>();
  for (const l of lines) {
    if (l.resolved_by === "human") { skipped++; continue; }
    let hit: any = null; let via = "";
    if (l.store_code && isInfomartVendor) {
      hit = await callResolve({ p_source: "infomart", p_code: String(l.store_code).trim(), p_name: l.store_text ?? null, p_corp_hint: corpHint, p_log: false });
      if (hit) via = "infomart:code";
    }
    if (!hit && l.store_text) {
      hit = await callResolve({ p_source: "invoice", p_name: String(l.store_text).trim(), p_corp_hint: corpHint, p_log: true });
      if (hit) via = "invoice:name";
    }
    let patch: Record<string, unknown>;
    if (hit && (hit.confidence === "exact" || hit.confidence === "high")) {
      patch = { resolved_store_id: hit.store_id, resolved_by: "mapping", resolve_info: { confidence: hit.confidence, matched_by: hit.matched_by, via, brand_id: hit.brand_id ?? null } };
      resolved++;
    } else if (hit && l.store_text && containedOwner(String(l.store_text)) === hit.store_id) {
      patch = { resolved_store_id: hit.store_id, resolved_by: "mapping", resolve_info: { confidence: "high", matched_by: "contains_name", via, brand_id: hit.brand_id ?? null, note: "店名・別名が文中に含まれるため確定（他の店舗と紛れません）" } };
      resolved++;
    } else if (hit) {
      patch = { resolved_store_id: null, resolved_by: null, resolve_info: { confidence: "low", matched_by: hit.matched_by, via, candidate_store_id: hit.store_id } };
      low++;
    } else if (!l.store_text && !l.store_code && (inv.store_id || vendorDefaultStore)) {
      patch = { resolved_store_id: inv.store_id ?? vendorDefaultStore, resolved_by: "rule", resolve_info: { confidence: "rule", via: inv.store_id ? "invoice.store_id" : "vendor.default_store_id" } };
      resolved++;
    } else if (historyStore) {   // 2026-10-19: 店名の記載が無い行（毎月同じ取引先の請求書）にも使う。承認すると店舗が記録され、次回から続く
      patch = { resolved_store_id: historyStore, resolved_by: "ai", resolve_info: { confidence: "history", via: "vendor_history", note: "過去の請求書がすべて同じ1店舗だったため推定（要確認）" } };
      resolved++;
    } else {
      patch = { resolved_store_id: null, resolved_by: null, resolve_info: { confidence: "unresolved", via: via || (l.store_text || l.store_code ? "no_match" : "no_store_text") } };
      unresolved++;
      if (l.store_text) unresolvedNames.add(String(l.store_text));
    }
    await db.from("invoice_lines").update(patch).eq("id", l.id);
  }
  const mapping = { resolved, low, unresolved, skipped_human: skipped, unresolved_names: [...unresolvedNames], checked_at: new Date().toISOString() };
  await db.from("invoices").update({ lines_check: { ...(inv.lines_check ?? {}), mapping } }).eq("id", inv.id);
  // Phase5: 店舗が決まったので仕訳の下書きを作る（待たずに別Functionへ依頼。secret経由のときだけ）
  if (body?.secret) {
    const kick = fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/invoice-journal-draft`, {
      method: "POST",
      headers: { "Content-Type": "application/json", apikey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, Authorization: `Bearer ${Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")}` },
      body: JSON.stringify({ secret: body.secret, invoice_id: inv.id }),
    }).catch((e) => console.error("仕訳下書きの依頼に失敗: " + e));
    const er = (globalThis as any).EdgeRuntime;
    if (er?.waitUntil) er.waitUntil(kick);
  }
  return json({ success: true, ...mapping });
});
