// =============================================================
// commute-route — 通勤経路の検索と交通費の仮判定（Phase 2・2026-11-10）
//   役割: 本人の最寄り駅（または住所）→ 所属店舗の最寄り駅 の経路候補を駅すぱあと API で取り、
//         app_settings.commute_rules（仮の基準）で「合理的な経路」を絞り、本人申請額（片道）と照合して判定を employee_commute に保存する。
//   鉄則（ユーザー指示）: AI が運賃を推測して金額を決めない（金額は API の応答だけ）。最安だけで自動否認しない（最終判断は人）。住所は Slack に出さない。
//   キー（2026-11-10）: Edge Function のシークレット EKISPERT_API_KEY を優先（`python3 scripts/set_function_secret.py EKISPERT_API_KEY`。コード・GitHub・チャットに書かない）。
//         無ければ従来の app_secrets.ekispert_key（本部権限の人が読める表なので非推奨）。どちらも無ければ判定 search_failed・理由 no_api_key（落ちない）
//   body.op = "selftest": 接続の自己診断（キーは返さない）。駅名検索 1 回＋経路検索 1 回で HTTP 状態・エラーコード・応答の形（Course 件数・Price の kind・Line の Type）だけ返す
//   認証: Authorization: Bearer <service_role> または x-notify-secret
//   body: { user_id, store_id?, dry_run?, mock_result_set? }   dry_run=true は保存せず結果だけ返す（検証用）
//         mock_result_set は dry_run=true のときだけ有効: 駅すぱあとを呼ばず、渡された ResultSet（_shared/commute-mock.ts の形）で判定だけ行う（キー未着でも結合テストできる）
//   自動承認（2026-11-09）: app_settings.commute_rules.auto_approve（既定 enabled=false・shadow=true）。ここは「条件を満たすか」を返すだけ。承認は onboarding-notify が enabled のときだけ RPC で行う
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

import { parseCourses, judge, autoJudge, normalizeStationName, pickStation, payHint, payPlan, conditionFor, DEFAULT_RULES, arr, type Rules, type Candidate, type AutoResult, type PayPolicy } from "../_shared/commute-judge.ts";

async function eki(path: string, params: Record<string, string>): Promise<any> {
  const u = new URL(`${EKI}${path}`);
  for (const [k, v] of Object.entries(params)) u.searchParams.set(k, v);
  const res = await fetch(u.toString(), { headers: { Accept: "application/json" } });
  const j = await res.json().catch(() => null);
  if (!res.ok) throw new Error(`駅すぱあと ${path} ${res.status}: ${JSON.stringify(j?.ResultSet?.Error ?? j).slice(0, 200)}`);
  if (j?.ResultSet?.Error) throw new Error(`駅すぱあと ${path}: ${JSON.stringify(j.ResultSet.Error).slice(0, 200)}`);
  return j?.ResultSet ?? j;
}
// 駅名 → 駅（同名駅は会社のエリアを優先。エリア外しか無い・見つからないときは null＝推測しない）
async function findStation(key: string, name: string, prefOrder: string[]): Promise<{ code: string; name: string; ambiguous: boolean } | null> {
  const rs = await eki("/station", { key, name, type: "train" });
  return pickStation(rs?.Point, name, prefOrder);
}
// 住所 → 最寄りの鉄道駅（commute_rules.use_address_lookup=true のときだけ。住所は API にだけ送り、結果・ログには残さない）
async function nearestStationByAddress(key: string, address: string): Promise<{ code: string; name: string } | null> {
  const rs = await eki("/address/station", { key, address, type: "train" });
  const p = arr(rs?.Point)[0];
  return p?.Station?.code ? { code: String(p.Station.code), name: String(p.Station.Name ?? "") } : null;
}

// キーの取得: シークレット（env）優先 → app_secrets
async function loadKey(sb: any): Promise<{ key: string; source: "env" | "app_secrets" | "none" }> {
  const env = (Deno.env.get("EKISPERT_API_KEY") ?? "").trim();
  if (env) return { key: env, source: "env" };
  const { data } = await sb.from("app_secrets").select("value").eq("key", "ekispert_key").maybeSingle();
  const v = String(data?.value ?? "").trim();
  return v ? { key: v, source: "app_secrets" } : { key: "", source: "none" };
}
// 生の呼び出し（自己診断用。エラーでも throw せず状態を返す。キーは URL にだけ入り、戻り値には含めない）
async function ekiRaw(path: string, params: Record<string, string>): Promise<{ status: number; error: unknown; rs: any }> {
  const u = new URL(`${EKI}${path}`);
  for (const [k, v] of Object.entries(params)) u.searchParams.set(k, v);
  try {
    const res = await fetch(u.toString(), { headers: { Accept: "application/json" } });
    const j = await res.json().catch(() => null);
    return { status: res.status, error: j?.ResultSet?.Error ?? (res.ok ? null : j), rs: j?.ResultSet ?? null };
  } catch (e) { return { status: 0, error: String(e).slice(0, 120), rs: null }; }
}
async function selftest(sb: any, body: any) {
  const { key, source } = await loadKey(sb);
  if (!key) return json({ ok: false, key_source: source, error: "キーが未設定です（EKISPERT_API_KEY）" });
  const fromName = String(body.from ?? "田町"), toName = String(body.to ?? "新橋");
  const st1 = await ekiRaw("/station", { key, name: fromName, type: "train" });
  const st2 = await ekiRaw("/station", { key, name: toName, type: "train" });
  const p1 = arr(st1.rs?.Point), p2 = arr(st2.rs?.Point);
  const c1 = p1[0]?.Station?.code ? String(p1[0].Station.code) : null, c2 = p2[0]?.Station?.code ? String(p2[0].Station.code) : null;
  const out: any = { ok: false, key_source: source, engine: st1.rs?.engineVersion ?? null, api_version: st1.rs?.apiVersion ?? null,
    station: [{ name: fromName, http: st1.status, candidates: p1.length, first: p1[0]?.Station?.Name ?? null, first_type: p1[0]?.Station?.Type ?? null, code_found: !!c1, error: st1.error }, { name: toName, http: st2.status, candidates: p2.length, first: p2[0]?.Station?.Name ?? null, code_found: !!c2, error: st2.error }] };
  if (c1 && c2) {
    const cr = await ekiRaw("/search/course/extreme", { key, viaList: `${c1}:${c2}`, searchType: "plain", answerCount: "8", sort: "price", conditionDetail: conditionFor(DEFAULT_RULES, false) });
    const courses = arr(cr.rs?.Course);
    const cands = parseCourses(cr.rs ?? {});
    out.course = { http: cr.status, error: cr.error, course_is_array: Array.isArray(cr.rs?.Course), count: courses.length,
      price_kinds: [...new Set(courses.flatMap((c: any) => arr(c?.Price).map((p: any) => String(p?.kind))))],
      line_types: [...new Set(courses.flatMap((c: any) => arr(c?.Route?.Line).map((l: any) => typeof l?.Type === "object" ? JSON.stringify(l.Type).slice(0, 60) : String(l?.Type))))],
      route_keys: Object.keys(courses[0]?.Route ?? {}).slice(0, 14), price_sample: arr(courses[0]?.Price).slice(0, 4).map((p: any) => ({ kind: p?.kind, Oneway: p?.Oneway, Round: p?.Round, Type: p?.Type })),
      parsed: cands.map((c) => ({ summary: c.summary.slice(0, 60), fare: c.fare, round: c.round, time_min: c.time_min, transfers: c.transfers, walk_min: c.walk_min, uses_bus: c.uses_bus, teiki1: c.teiki1, teiki3: c.teiki3, teiki6: c.teiki6 })) };
    out.ok = cr.status === 200 && !cr.error && cands.some((c) => c.fare !== null);
  }
  return json(out);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ ok: false, error: "POSTのみ" }, 405);
  if (!authorized(req)) return json({ ok: false, error: "unauthorized" }, 401);
  const body = await req.json().catch(() => ({}));
  if (body.op === "selftest") return await selftest(createClient(SUPABASE_URL, SERVICE_KEY), body);
  // 仕様調査用（2026-11-10）: 許可した GET エンドポイントだけを任意パラメータで呼び、応答（キーは含まれない）を返す。評価版の制限・応答の形の確認に使う
  if (body.op === "probe") {
    const allow = ["/station", "/station/light", "/search/course/plain", "/search/course/extreme", "/search/course/light", "/geo/station", "/address/station", "/dataversion", "/toolbox/course/condition", "/operationLine", "/railmap/list", "/course/passStation"];
    const path = String(body.path ?? "");
    if (!allow.includes(path)) return json({ ok: false, error: "許可されていない path", allow }, 400);
    const { key, source } = await loadKey(createClient(SUPABASE_URL, SERVICE_KEY));
    if (!key) return json({ ok: false, key_source: source, error: "キーが未設定です" });
    const params: Record<string, string> = {};
    for (const [k, v] of Object.entries(body.params ?? {})) if (k !== "key" && /^[A-Za-z0-9_]{1,40}$/.test(k)) params[k] = String(v).slice(0, 300);
    const r = await ekiRaw(path, { key, ...params });
    const text = JSON.stringify(r.rs ?? null);
    return json({ ok: r.status === 200 && !r.error, http: r.status, error: r.error, length: text.length, result: JSON.parse(text.slice(0, 0) || "null") ?? undefined, raw: text.slice(0, Math.min(Number(body.max_chars ?? 6000), 40000)) });
  }
  const uid = String(body.user_id ?? "");
  if (!/^[0-9a-f-]{36}$/i.test(uid)) return json({ ok: false, error: "user_id が不正です" }, 400);
  const sb = createClient(SUPABASE_URL, SERVICE_KEY);
  try {
    const [{ data: cm }, { data: prof }, { data: rulesRow }, keyInfo, { data: us }] = await Promise.all([
      sb.from("employee_commute").select("*").eq("user_id", uid).maybeSingle(),
      sb.from("employee_profiles").select("address,extra").eq("user_id", uid).maybeSingle(),
      sb.from("app_settings").select("value").eq("key", "commute_rules").maybeSingle(),
      loadKey(sb),
      sb.from("user_stores").select("store_id,stores(id,name,nearest_station,sort_order)").eq("user_id", uid),
    ]);
    const rules: Rules = { ...DEFAULT_RULES, ...(rulesRow?.value ?? {}) };
    const stores = (us ?? []).map((x: any) => x.stores).filter(Boolean).sort((a: any, b: any) => (a.sort_order ?? 0) - (b.sort_order ?? 0));
    const store = body.store_id ? stores.find((s: any) => s.id === body.store_id) : stores[0];
    // 最寄り駅は自由記入（例: "大口駅（JR横浜線）"・"電車40分"）→ 駅名だけに正規化。駅名が取れなければ住所から探す
    const homeStationRaw = String(cm?.home_station ?? prof?.extra?.["最寄り駅"] ?? "");
    const homeStation = normalizeStationName(homeStationRaw);
    const workStation = normalizeStationName(store?.nearest_station);
    // dry_run のときだけ申請額を差し替えられる（結合テスト用。保存はしない）
    const claimed: number | null = body.dry_run === true && body.mock_claimed !== undefined && body.mock_claimed !== null && Number.isFinite(Number(body.mock_claimed)) ? Number(body.mock_claimed) : (cm?.claimed_oneway_fare ?? null);
    const key = keyInfo.key;
    const autoRules = (rulesRow?.value as any)?.auto_approve ?? null;
    const mock = body.dry_run === true && body.mock_result_set ? body.mock_result_set : null;
    const fail = async (reason: string, code: string) => {
      const auto: AutoResult = autoJudge({ judgement: "search_failed", computed: null, reasonable: [] }, { claimed, method: cm?.method ?? null, home_station_known: !!homeStation, store_station_known: !!workStation }, autoRules);
      const result = { provider: "ekispert", searched_at: new Date().toISOString(), store_id: store?.id ?? null, store_name: store?.name ?? null, from: homeStation || null, to: workStation || null, error: reason, error_code: code, candidates: [], auto };
      if (!body.dry_run) {
        await sb.from("employee_commute").upsert({ user_id: uid, search_result: result, judgement: "search_failed", judgement_reasons: [reason], judged_at: new Date().toISOString(), updated_at: new Date().toISOString() }, { onConflict: "user_id" });
        await setItem(sb, cm?.workflow_id ?? null, uid, "commute_check", "manual_required", { judgement: "search_failed", reason }, reason);
      }
      return json({ ok: false, judgement: "search_failed", error: reason, error_code: code, result, auto: result.auto });
    };
    if (!store) return await fail("所属店舗がありません", "no_store");
    if (!workStation) return await fail(`店舗「${store.name}」の最寄り駅が未設定です（nippo の店舗管理で登録）`, "no_store_station");
    if (!homeStation && !(rules.use_address_lookup === true && prof?.address)) return await fail("本人の最寄り駅（駅名）が登録されていません。本人に最寄り駅を確認してください", "no_home");
    if (!key && !mock) return await fail("駅すぱあと API のキーが未設定です（EKISPERT_API_KEY）", "no_api_key");

    let rs: any;
    const stationNotes: string[] = [];
    const busAllowed = rules.allow_bus === true || (cm as any)?.bus_exception === true;
    if (!busAllowed && (cm?.uses_bus === true || /bus/.test(String(cm?.method ?? "")))) stationNotes.push("本人はバス利用を申請しています（会社ルール: バスは原則不可。認める場合は「⚙️ 支給方法」でバス例外を付けて再検索）");
    if (mock) {
      rs = mock?.ResultSet ?? mock;   // 結合テスト用（dry_run のみ）。駅すぱあとは呼ばない
    } else {
      // 出発: 本人の最寄り駅（駅名）。駅名が無いときは、設定 use_address_lookup=true の場合だけ住所から最寄りの鉄道駅を引く（既定は引かない＝本人に最寄り駅を確認）
      const pref = Array.isArray(rules.pref_order) ? rules.pref_order : (DEFAULT_RULES.pref_order ?? []);
      let fromSt = homeStation ? await findStation(key, homeStation, pref) : null;
      if (!fromSt && !homeStation && rules.use_address_lookup === true && prof?.address) { const n = await nearestStationByAddress(key, String(prof.address)); if (n) { fromSt = { ...n, ambiguous: true }; stationNotes.push("本人の最寄り駅は住所からの推定です（本人に確認）"); } }
      const toSt = await findStation(key, workStation, pref);
      if (!fromSt || !toSt) return await fail(`駅を特定できません（${!fromSt ? (homeStation ? "本人: " + homeStation : "本人の最寄り駅が未登録") : ""}${!toSt ? " 店舗: " + workStation : ""}）。同名駅や表記ゆれの可能性があるため人が確認してください`, "station_not_found");
      if (fromSt.ambiguous && homeStation) stationNotes.push(`本人の最寄り駅「${homeStation}」は同名の駅が複数あります（${fromSt.name} で検索）`);
      // 会社ルール（2026-11-10）: IC 運賃・新幹線/特急/飛行機なし。バスは原則不可（本部が個別に「バス例外」を付けた人か、ルールで許可したときだけ探索に含める）
      //   /search/course/extreme を平均待ち時間（searchType=plain）で使い、探索条件 conditionDetail で IC とバス可否を指定。安い順に最大 8 件
      rs = await eki("/search/course/extreme", { key, viaList: `${fromSt.code}:${toSt.code}`, searchType: "plain", answerCount: "8", sort: "price", conditionDetail: conditionFor(rules, busAllowed) });
    }
    const cands = parseCourses(rs).map((c) => ({ ...c }));
    const j = judge(cands, claimed, rules);
    // 駅の特定にあいまいさがあれば自動承認可能にはしない（本部確認）
    if (stationNotes.length) { j.reasons.push(...stationNotes); if (j.judgement === "auto_approvable") j.judgement = "hq_review"; }
    // 自動承認の条件判定（記録だけ。承認は呼び出し側が enabled のときだけ）
    const auto = autoJudge(j, { claimed, method: cm?.method ?? null, home_station_known: !!homeStation, store_station_known: !!workStation }, autoRules);
    // 支給額の計算（会社ルール: 1 日上限・個別の支給方法・定期と実費の安い方）
    const plan = payPlan(j.computed, { policy: ((cm as any)?.pay_policy ?? "daily_cap") as PayPolicy, cap: Number(rules.daily_cap_round_yen ?? 500), days: (cm as any)?.expected_days_per_month ?? null });
    const result = {
      provider: mock ? "mock" : "ekispert", searched_at: new Date().toISOString(), store_id: store.id, store_name: store.name, from: homeStation || "（住所から）", to: workStation,
      candidates: cands, reasonable_indexes: j.reasonable.map((c) => c.index), computed_index: j.computed?.index ?? null, rules, auto, pay_hint: payHint(j.computed), pay_plan: plan, fare_type: rules.fare_type ?? "ic", bus_allowed: busAllowed,
    };
    if (!body.dry_run) {
      await sb.from("employee_commute").upsert({
        user_id: uid, search_result: result, computed_oneway_fare: j.computed?.fare ?? null, computed_round_fare: j.computed?.round ?? null,
        computed_teiki1: j.computed?.teiki1 ?? null, computed_teiki3: j.computed?.teiki3 ?? null, computed_teiki6: j.computed?.teiki6 ?? null,
        judgement: cm?.judgement === "approved" ? "approved" : j.judgement, judgement_reasons: j.reasons, judged_at: new Date().toISOString(), updated_at: new Date().toISOString(),
      }, { onConflict: "user_id" });
      // 項目: 判定結果は人が見て押す → manual_required（判定を payload に）。承認済みなら触らない
      if (cm?.judgement !== "approved") await setItem(sb, cm?.workflow_id ?? null, uid, "commute_check", "manual_required", { judgement: j.judgement, reasons: j.reasons, computed_fare: j.computed?.fare ?? null, claimed, auto }, j.reasons[0] ?? null);
      // 自動承認の判定を記録（shadow でも残す＝有効化前に「どれだけ自動承認できたか」を集計できる）
      if (auto.mode !== "off" && cm?.workflow_id) await sb.from("onboarding_events").insert({ workflow_id: cm.workflow_id, item_key: "commute_check", kind: "commute.auto_judged", via: "auto", payload: { ...auto, judgement: j.judgement, claimed, computed_fare: j.computed?.fare ?? null } });
    }
    return json({ ok: true, judgement: j.judgement, reasons: j.reasons, claimed, computed: j.computed, reasonable: j.reasonable, candidates: cands, auto, pay_hint: payHint(j.computed), pay_plan: plan, fare_type: rules.fare_type ?? "ic", bus_allowed: busAllowed, store: { id: store.id, name: store.name }, from: homeStation || "（住所から）", to: workStation, mock: !!mock });
  } catch (e) {
    return json({ ok: false, error: String((e as Error).message ?? e).slice(0, 300) }, 500);
  }
});

async function setItem(sb: any, wfId: string | null, uid: string, item: string, state: string, payload: unknown, error: string | null) {
  if (!wfId) { const { data } = await sb.from("onboarding_workflows").select("id").eq("user_id", uid).maybeSingle(); if (!data) return; wfId = data.id; }
  await sb.rpc("onboarding_set_item", { p_workflow: wfId, p_item: item, p_state: state, p_payload: payload, p_actor: null, p_via: "auto", p_error: error });
}
