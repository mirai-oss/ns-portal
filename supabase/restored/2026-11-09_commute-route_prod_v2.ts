// =============================================================
// commute-route — 通勤経路の検索と交通費の仮判定（Phase 2・2026-11-10）
//   役割: 本人の最寄り駅（または住所）→ 所属店舗の最寄り駅 の経路候補を駅すぱあと API で取り、
//         app_settings.commute_rules（仮の基準）で「合理的な経路」を絞り、本人申請額（片道）と照合して判定を employee_commute に保存する。
//   鉄則（ユーザー指示）: AI が運賃を推測して金額を決めない（金額は API の応答だけ）。最安だけで自動否認しない（最終判断は人）。住所は Slack に出さない。
//   キー: app_secrets.ekispert_key（未設定なら判定 search_failed・理由 no_api_key。落ちない）
//   認証: Authorization: Bearer <service_role> または x-notify-secret
//   body: { user_id, store_id?, dry_run? }   dry_run=true は保存せず結果だけ返す（検証用）
//   駅すぱあと: GET /v1/json/search/course/plain?key=&from=&to=&bus=  （平均待ち時間探索。from/to は駅コード・住所・座標）
//               GET /v1/json/station?key=&name=  （駅名→駅コード）
//   出典: https://docs.ekispert.com/v1/api/search/course/plain.html  https://docs.ekispert.com/v1/api/station.html
//   デプロイ: supabase functions deploy commute-route --no-verify-jwt --project-ref uuvsxzhpxtghojoubjcc --yes
// =============================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info, x-notify-secret" };
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const EKI = "https://api.ekispert.jp/v1/json";

function authorized(req: Request): boolean {
  const secret = (Deno.env.get("NOTIFY_SLACK_SECRET") ?? "").trim();
  const hdr = (req.headers.get("x-notify-secret") ?? "").trim();
  if (secret && hdr && secret === hdr) return true;
  const bearer = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  return !!bearer && bearer === SERVICE_KEY;
}

import { parseCourses, judge, DEFAULT_RULES, arr, type Rules, type Candidate } from "../_shared/commute-judge.ts";

async function eki(path: string, params: Record<string, string>): Promise<any> {
  const u = new URL(`${EKI}${path}`);
  for (const [k, v] of Object.entries(params)) u.searchParams.set(k, v);
  const res = await fetch(u.toString(), { headers: { Accept: "application/json" } });
  const j = await res.json().catch(() => null);
  if (!res.ok) throw new Error(`駅すぱあと ${path} ${res.status}: ${JSON.stringify(j?.ResultSet?.Error ?? j).slice(0, 200)}`);
  if (j?.ResultSet?.Error) throw new Error(`駅すぱあと ${path}: ${JSON.stringify(j.ResultSet.Error).slice(0, 200)}`);
  return j?.ResultSet ?? j;
}
async function stationCode(key: string, name: string): Promise<string | null> {
  const rs = await eki("/station", { key, name, type: "train" });
  const p = arr(rs?.Point)[0];
  return p?.Station?.code ? String(p.Station.code) : null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ ok: false, error: "POSTのみ" }, 405);
  if (!authorized(req)) return json({ ok: false, error: "unauthorized" }, 401);
  const body = await req.json().catch(() => ({}));
  const uid = String(body.user_id ?? "");
  if (!/^[0-9a-f-]{36}$/i.test(uid)) return json({ ok: false, error: "user_id が不正です" }, 400);
  const sb = createClient(SUPABASE_URL, SERVICE_KEY);
  try {
    const [{ data: cm }, { data: prof }, { data: rulesRow }, { data: keyRow }, { data: us }] = await Promise.all([
      sb.from("employee_commute").select("*").eq("user_id", uid).maybeSingle(),
      sb.from("employee_profiles").select("address,extra").eq("user_id", uid).maybeSingle(),
      sb.from("app_settings").select("value").eq("key", "commute_rules").maybeSingle(),
      sb.from("app_secrets").select("value").eq("key", "ekispert_key").maybeSingle(),
      sb.from("user_stores").select("store_id,stores(id,name,nearest_station,sort_order)").eq("user_id", uid),
    ]);
    const rules: Rules = { ...DEFAULT_RULES, ...(rulesRow?.value ?? {}) };
    const stores = (us ?? []).map((x: any) => x.stores).filter(Boolean).sort((a: any, b: any) => (a.sort_order ?? 0) - (b.sort_order ?? 0));
    const store = body.store_id ? stores.find((s: any) => s.id === body.store_id) : stores[0];
    const homeStation = (cm?.home_station ?? prof?.extra?.["最寄り駅"] ?? "").split(/[／/]/)[0].trim();
    const workStation = String(store?.nearest_station ?? "").split(/[、,]/)[0].trim();
    const claimed = cm?.claimed_oneway_fare ?? null;
    const key = (keyRow?.value ?? "").trim();
    const fail = async (reason: string, code: string) => {
      const result = { provider: "ekispert", searched_at: new Date().toISOString(), store_id: store?.id ?? null, store_name: store?.name ?? null, from: homeStation || null, to: workStation || null, error: reason, error_code: code, candidates: [] };
      if (!body.dry_run) {
        await sb.from("employee_commute").upsert({ user_id: uid, search_result: result, judgement: "search_failed", judgement_reasons: [reason], judged_at: new Date().toISOString(), updated_at: new Date().toISOString() }, { onConflict: "user_id" });
        await setItem(sb, cm?.workflow_id ?? null, uid, "commute_check", "manual_required", { judgement: "search_failed", reason }, reason);
      }
      return json({ ok: false, judgement: "search_failed", error: reason, error_code: code, result });
    };
    if (!store) return await fail("所属店舗がありません", "no_store");
    if (!workStation) return await fail(`店舗「${store.name}」の最寄り駅が未設定です（nippo の店舗管理で登録）`, "no_store_station");
    if (!homeStation && !prof?.address) return await fail("本人の最寄り駅・住所がありません", "no_home");
    if (!key) return await fail("駅すぱあと API のキーが未設定です（app_secrets.ekispert_key）", "no_api_key");

    // 出発: 最寄り駅があれば駅コード、無ければ住所（住所は API にだけ送り、結果には残さない）
    let from = "";
    if (homeStation) from = (await stationCode(key, homeStation)) ?? "";
    if (!from && prof?.address) from = String(prof.address);
    const to = await stationCode(key, workStation);
    if (!from || !to) return await fail(`駅が見つかりません（${!from ? "本人: " + homeStation : ""}${!to ? " 店舗: " + workStation : ""}）`, "station_not_found");
    const rs = await eki("/search/course/plain", { key, from, to, bus: "true", answerCount: "6" });
    const cands = parseCourses(rs).map((c) => ({ ...c }));
    const j = judge(cands, claimed, rules);
    const result = {
      provider: "ekispert", searched_at: new Date().toISOString(), store_id: store.id, store_name: store.name, from: homeStation || "（住所から）", to: workStation,
      candidates: cands, reasonable_indexes: j.reasonable.map((c) => c.index), computed_index: j.computed?.index ?? null, rules,
    };
    if (!body.dry_run) {
      await sb.from("employee_commute").upsert({
        user_id: uid, search_result: result, computed_oneway_fare: j.computed?.fare ?? null, computed_round_fare: j.computed?.round ?? null,
        computed_teiki1: j.computed?.teiki1 ?? null, computed_teiki3: j.computed?.teiki3 ?? null, computed_teiki6: j.computed?.teiki6 ?? null,
        judgement: cm?.judgement === "approved" ? "approved" : j.judgement, judgement_reasons: j.reasons, judged_at: new Date().toISOString(), updated_at: new Date().toISOString(),
      }, { onConflict: "user_id" });
      // 項目: 判定結果は人が見て押す → manual_required（判定を payload に）。承認済みなら触らない
      if (cm?.judgement !== "approved") await setItem(sb, cm?.workflow_id ?? null, uid, "commute_check", "manual_required", { judgement: j.judgement, reasons: j.reasons, computed_fare: j.computed?.fare ?? null, claimed }, j.reasons[0] ?? null);
    }
    return json({ ok: true, judgement: j.judgement, reasons: j.reasons, claimed, computed: j.computed, reasonable: j.reasonable, candidates: cands, store: { id: store.id, name: store.name }, from: homeStation || "（住所から）", to: workStation });
  } catch (e) {
    return json({ ok: false, error: String((e as Error).message ?? e).slice(0, 300) }, 500);
  }
});

async function setItem(sb: any, wfId: string | null, uid: string, item: string, state: string, payload: unknown, error: string | null) {
  if (!wfId) { const { data } = await sb.from("onboarding_workflows").select("id").eq("user_id", uid).maybeSingle(); if (!data) return; wfId = data.id; }
  await sb.rpc("onboarding_set_item", { p_workflow: wfId, p_item: item, p_state: state, p_payload: payload, p_actor: null, p_via: "auto", p_error: error });
}
