// google-reviews-fetch — Google Places API (New) から口コミ件数・平均星を毎日取得して Supabase（新正本）に書く
//   設計書: docs/設計書_Google口コミSupabase直結_2026-11-06.md
//   op=fetch   : マスタ google_place_listings（status=active・place_id あり）を 1 件ずつ Place Details で取得 → google_review_snapshots へ upsert
//                （listing_id × 取得日(JST) で冪等。同日の再実行は最新値で上書き）。Text Search は使わない。
//   op=resolve : place_id 未確定（pending / needs_review）の掲載だけ Text Search → 候補を照合 → 旧履歴（kd_google_review_listings）の
//                件数・星と一致すれば active、曖昧なら needs_review（候補を candidates に保存して人間確認）。初期移行・新規追加時だけ使う。
//   op=confirm : 人間が候補から選んだ place_id を確定（Place Details で実在確認してから保存）
//   op=health  : 状態の要約（マスタの status 別件数・直近の実行）
//   認証: x-notify-secret（NOTIFY_SLACK_SECRET。pg_cron / GitHub / 手元スクリプト用）か Authorization: Bearer <service_role>。
//   API キーは secrets GOOGLE_PLACES_API_KEY。レスポンス・ログ・DB には一切出さない。
//   失敗時: 429/5xx/通信エラーは最大 3 回（1s→3s→9s）で再試行。404(NOT_FOUND) は status='invalid' にして再試行しない。
//           1 件でも失敗したら #本部-開発システム（hq.dev_system）へ通知。前回値はそのまま残る（日報は「最終取得 M/D」を出す）。
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { slackPost } from "../_shared/slack.ts";

const PLACES = "https://places.googleapis.com/v1";
const DETAILS_MASK = "id,displayName,rating,userRatingCount";
const SEARCH_MASK = "places.id,places.displayName,places.formattedAddress";
const RETRY_WAIT_MS = [1000, 3000, 9000];

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}
function safeEqual(a: string, b: string): boolean {
  const ea = new TextEncoder().encode(a), eb = new TextEncoder().encode(b);
  if (ea.length !== eb.length) return false;
  let diff = 0;
  for (let i = 0; i < ea.length; i++) diff |= ea[i] ^ eb[i];
  return diff === 0;
}
function authorized(req: Request): boolean {
  const secret = (Deno.env.get("NOTIFY_SLACK_SECRET") ?? "").trim();
  const given = (req.headers.get("x-notify-secret") ?? "").trim();
  if (secret.length >= 16 && given && safeEqual(secret, given)) return true;
  const auth = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  const sr = (Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "").trim();
  return sr.length >= 16 && !!auth && safeEqual(auth, sr);
}
const jstDate = (d = new Date()) => new Date(d.getTime() + 9 * 3600 * 1000).toISOString().slice(0, 10);
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

type PlaceInfo = { id: string; name: string; address: string; rating: number | null; count: number | null };
type ApiResult = { ok: true; place: PlaceInfo } | { ok: false; status: number; error: string; notFound?: boolean };
type SearchResult = { ok: true; places: PlaceInfo[] } | { ok: false; status: number; error: string };

class Counter { api = 0; details = 0; search = 0; }

function apiKey(): string {
  const k = (Deno.env.get("GOOGLE_PLACES_API_KEY") ?? "").trim();
  if (!k) throw new Error("GOOGLE_PLACES_API_KEY が secrets に未設定です");
  return k;
}
// Google のエラー本文は短く切り、キーが混ざらないように念のため伏せる
function trimErr(text: string): string {
  return text.replace(/key=[^&\s"]+/gi, "key=***").slice(0, 300);
}
async function withRetry<T extends { ok: boolean }>(fn: () => Promise<T>, isRetryable: (r: T) => boolean): Promise<T> {
  let last!: T;
  for (let attempt = 0; attempt <= RETRY_WAIT_MS.length; attempt++) {
    try {
      last = await fn();
    } catch (e) {
      last = { ok: false, status: 0, error: "通信エラー: " + String(e).slice(0, 200) } as unknown as T;
    }
    if (last.ok || !isRetryable(last)) return last;
    if (attempt < RETRY_WAIT_MS.length) await sleep(RETRY_WAIT_MS[attempt]);
  }
  return last;
}
const retryable = (r: { ok: boolean; status?: number }) => !r.ok && (r.status === 0 || r.status === 429 || (r.status ?? 0) >= 500);

async function placeDetails(placeId: string, c: Counter): Promise<ApiResult> {
  return await withRetry<ApiResult>(async () => {
    c.api++; c.details++;
    const res = await fetch(`${PLACES}/places/${encodeURIComponent(placeId)}?languageCode=ja&regionCode=JP`, {
      headers: { "X-Goog-Api-Key": apiKey(), "X-Goog-FieldMask": DETAILS_MASK },
    });
    const text = await res.text();
    if (res.status === 404) return { ok: false, status: 404, error: "NOT_FOUND: Place ID が無効", notFound: true };
    if (!res.ok) return { ok: false, status: res.status, error: `HTTP ${res.status}: ${trimErr(text)}` };
    let j: any; try { j = JSON.parse(text); } catch { return { ok: false, status: 0, error: "JSON 解析失敗" }; }
    return { ok: true, place: { id: String(j.id ?? placeId), name: j.displayName?.text ?? "", address: j.formattedAddress ?? "", rating: typeof j.rating === "number" ? j.rating : null, count: typeof j.userRatingCount === "number" ? j.userRatingCount : null } };
  }, retryable);
}
async function textSearch(query: string, c: Counter): Promise<SearchResult> {
  return await withRetry<SearchResult>(async () => {
    c.api++; c.search++;
    const res = await fetch(`${PLACES}/places:searchText`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Goog-Api-Key": apiKey(), "X-Goog-FieldMask": SEARCH_MASK },
      body: JSON.stringify({ textQuery: query, languageCode: "ja", regionCode: "JP", pageSize: 5 }),
    });
    const text = await res.text();
    if (!res.ok) return { ok: false, status: res.status, error: `HTTP ${res.status}: ${trimErr(text)}` };
    let j: any; try { j = JSON.parse(text); } catch { return { ok: false, status: 0, error: "JSON 解析失敗" }; }
    const places: PlaceInfo[] = (j.places ?? []).map((p: any) => ({ id: String(p.id ?? ""), name: p.displayName?.text ?? "", address: p.formattedAddress ?? "", rating: null, count: null })).filter((p: PlaceInfo) => p.id);
    return { ok: true, places };
  }, retryable);
}

async function startRun(sb: any, op: string): Promise<number | null> {
  const { data } = await sb.from("google_review_fetch_runs").insert({ op, run_on: jstDate() }).select("id").single();
  return data?.id ?? null;
}
async function finishRun(sb: any, id: number | null, patch: Record<string, unknown>) {
  if (id === null) return;
  await sb.from("google_review_fetch_runs").update({ finished_at: new Date().toISOString(), ...patch }).eq("id", id);
}

// ---------------- op=fetch（毎日） ----------------
async function opFetch(sb: any, body: any) {
  const runId = await startRun(sb, "fetch");
  const c = new Counter();
  const today = jstDate();
  const fetchedAt = new Date().toISOString();
  let q = sb.from("google_place_listings").select("id, store_id, listing_name, place_id, google_display_name").eq("status", "active").not("place_id", "is", null).order("sort_order");
  if (body?.listing_id && UUID_RE.test(String(body.listing_id))) q = q.eq("id", body.listing_id);
  const { data: listings, error } = await q;
  if (error) { await finishRun(sb, runId, { status: "failed", error: error.message }); return { ok: false, error: "マスタ読込失敗: " + error.message }; }
  const results: any[] = []; let okN = 0, failN = 0; const renamed: string[] = [];
  for (const l of listings ?? []) {
    const r = await placeDetails(l.place_id, c);
    if (r.ok) {
      const { error: ue } = await sb.from("google_review_snapshots").upsert({
        listing_id: l.id, store_id: l.store_id, fetched_on: today, fetched_at: fetchedAt,
        total_count: r.place.count, rating: r.place.rating, google_display_name: r.place.name || null, source: "places_api",
      }, { onConflict: "listing_id,fetched_on" });
      if (ue) { failN++; results.push({ listing: l.listing_name, ok: false, error: "保存失敗: " + ue.message }); continue; }
      if (r.place.name && l.google_display_name && r.place.name !== l.google_display_name) renamed.push(`${l.listing_name}: 「${l.google_display_name}」→「${r.place.name}」`);
      await sb.from("google_place_listings").update({ last_fetched_at: fetchedAt, last_error: null, google_display_name: r.place.name || l.google_display_name }).eq("id", l.id);
      okN++; results.push({ listing: l.listing_name, ok: true, total: r.place.count, rating: r.place.rating });
    } else {
      failN++;
      const patch: Record<string, unknown> = { last_error: r.error };
      if (r.notFound) patch.status = "invalid";
      await sb.from("google_place_listings").update(patch).eq("id", l.id);
      results.push({ listing: l.listing_name, ok: false, error: r.error, invalid: !!r.notFound });
    }
    await sleep(150);
  }
  const status = failN === 0 ? "success" : okN === 0 ? "failed" : "partial";
  await finishRun(sb, runId, { status, listings_total: (listings ?? []).length, ok_count: okN, fail_count: failN, api_calls: c.api, text_search_calls: c.search, place_details_calls: c.details, detail: { results, renamed } });
  if (failN > 0) {
    const lines = results.filter((x) => !x.ok).map((x) => `・${x.listing}: ${x.error}${x.invalid ? "（Place ID 無効 → マスタを invalid に変更。再検索が必要）" : ""}`).join("\n");
    await slackPost(sb, "hq.dev_system", `⚠️ Google口コミ取得（${today}）: 成功 ${okN} / 失敗 ${failN}\n${lines}\n※失敗分は前回値のまま。日報は「最終取得 M/D」で表示されます。`, { source: "edge", event: "google_reviews_fetch" });
  } else if (renamed.length) {
    await slackPost(sb, "hq.dev_system", `ℹ️ Google掲載の名称が変わりました（取得は正常・place_id は同じ）\n${renamed.join("\n")}`, { source: "edge", event: "google_reviews_rename" });
  }
  return { ok: failN === 0, run_id: runId, date: today, listings: (listings ?? []).length, ok_count: okN, fail_count: failN, api_calls: c.api, text_search_calls: c.search, place_details_calls: c.details, results, renamed };
}

// ---------------- op=resolve（初期移行・新規追加時） ----------------
// 判定: Text Search の候補のうち「名前に看板の語（display_name か掲載名の先頭語）を含み、住所に address_hint を含む」ものが 1 件だけ
//      → その候補の Place Details を取り、旧履歴（kd_google_review_listings の最新）と件数・星が一致（±max(5, 3%)・星 ±0.3）なら active。
//      それ以外（候補 0 件・複数・旧履歴なし・件数不一致・place_id が別の掲載で使用中）は needs_review（候補を保存。人間が op=confirm で確定）。
function tokensOf(l: any): string[] {
  const t = new Set<string>();
  if (l.display_name) t.add(String(l.display_name).trim());
  const first = String(l.listing_name ?? "").trim().split(/\s+/)[0];
  if (first) t.add(first);
  return [...t].filter((x) => x.length >= 2);
}
function norm(s: string): string { return String(s ?? "").replace(/\s+/g, "").toLowerCase(); }

async function opResolve(sb: any, body: any) {
  const runId = await startRun(sb, "resolve");
  const c = new Counter();
  const dry = !!body?.dry_run;
  let q = sb.from("google_place_listings").select("id, store_id, listing_name, display_name, place_id, search_query, address_hint, status, stores(name)").in("status", ["pending", "needs_review"]).order("sort_order");
  if (body?.listing_id && UUID_RE.test(String(body.listing_id))) q = sb.from("google_place_listings").select("id, store_id, listing_name, display_name, place_id, search_query, address_hint, status, stores(name)").eq("id", body.listing_id);
  const { data: listings, error } = await q;
  if (error) { await finishRun(sb, runId, { status: "failed", error: error.message }); return { ok: false, error: "マスタ読込失敗: " + error.message }; }
  const out: any[] = []; let activated = 0, review = 0, failN = 0;
  for (const l of listings ?? []) {
    const query = (l.search_query && String(l.search_query).trim()) || l.listing_name;
    const sr = await textSearch(query, c);
    if (!sr.ok) { failN++; out.push({ listing: l.listing_name, ok: false, error: sr.error }); if (!dry) await sb.from("google_place_listings").update({ last_error: sr.error }).eq("id", l.id); continue; }
    const toks = tokensOf(l).map(norm);
    const hint = l.address_hint ? norm(l.address_hint) : "";
    const matched = sr.places.filter((p) => toks.some((t) => norm(p.name).includes(t)) && (!hint || norm(p.address).includes(hint)));
    // 旧履歴（比較用）: 件数・星・Google名称
    const { data: legacy } = await sb.from("kd_google_review_listings").select("fetched_on, total_count, avg_star, google_name").eq("store_id", l.store_id).eq("listing_name", l.listing_name).order("fetched_on", { ascending: false }).limit(1).maybeSingle();
    let decision = "needs_review", note = "", chosen: PlaceInfo | null = null, details: PlaceInfo | null = null;
    if (matched.length === 1) {
      chosen = matched[0];
      const dr = await placeDetails(chosen.id, c);
      if (dr.ok) {
        details = dr.place;
        if (!legacy) note = "旧履歴なし（件数照合できず）→ 人間確認";
        else if (legacy.total_count === null || dr.place.count === null) note = "件数が取れず照合不可 → 人間確認";
        else {
          const tol = Math.max(5, Math.round(legacy.total_count * 0.03));
          const dc = Math.abs(dr.place.count - legacy.total_count);
          const ds = (legacy.avg_star !== null && dr.place.rating !== null) ? Math.abs(Number(legacy.avg_star) - dr.place.rating) : 0;
          if (dc <= tol && ds <= 0.3) { decision = "active"; note = `auto: 旧履歴(${legacy.fetched_on} ${legacy.total_count}件/★${legacy.avg_star ?? "-"}) と一致（現在 ${dr.place.count}件/★${dr.place.rating ?? "-"}）`; }
          else note = `件数/星が旧履歴と合わない（旧 ${legacy.total_count}件/★${legacy.avg_star ?? "-"} vs 現在 ${dr.place.count}件/★${dr.place.rating ?? "-"}）→ 人間確認`;
        }
      } else { failN++; note = "候補の Place Details 取得失敗: " + dr.error; }
    } else if (matched.length === 0) note = `候補 ${sr.places.length} 件のうち名前/住所の条件に合うものが無い → 人間確認`;
    else note = `条件に合う候補が ${matched.length} 件（曖昧）→ 人間確認`;
    if (decision === "active" && chosen) {
      const { data: dup } = await sb.from("google_place_listings").select("id, listing_name").eq("place_id", chosen.id).neq("id", l.id).maybeSingle();
      if (dup) { decision = "needs_review"; note = `同じ place_id が別の掲載「${dup.listing_name}」に登録済み → 人間確認`; }
    }
    const candidates = sr.places.map((p) => ({ id: p.id, name: p.name, address: p.address, matched: matched.some((m) => m.id === p.id) }));
    if (!dry) {
      const patch: Record<string, unknown> = { candidates, review_note: note, last_error: null, status: decision };
      if (decision === "active" && chosen) Object.assign(patch, { place_id: chosen.id, google_display_name: details?.name || chosen.name, google_address: details?.address || chosen.address, last_verified_at: new Date().toISOString() });
      const { error: ue } = await sb.from("google_place_listings").update(patch).eq("id", l.id);
      if (ue) { failN++; out.push({ listing: l.listing_name, ok: false, error: "保存失敗: " + ue.message }); continue; }
    }
    if (decision === "active") activated++; else review++;
    out.push({ listing: l.listing_name, store: l.stores?.name, query, decision, note, chosen: chosen ? { name: chosen.name, address: chosen.address } : null, current: details ? { total: details.count, rating: details.rating } : null, legacy: legacy ? { fetched_on: legacy.fetched_on, total: legacy.total_count, rating: legacy.avg_star } : null, candidates: candidates.map((x) => ({ name: x.name, address: x.address, matched: x.matched })) });
    await sleep(150);
  }
  await finishRun(sb, runId, { status: failN ? "partial" : "success", listings_total: (listings ?? []).length, ok_count: activated, fail_count: failN, api_calls: c.api, text_search_calls: c.search, place_details_calls: c.details, detail: { dry_run: dry, activated, needs_review: review } });
  return { ok: failN === 0, run_id: runId, dry_run: dry, listings: (listings ?? []).length, activated, needs_review: review, failed: failN, api_calls: c.api, text_search_calls: c.search, place_details_calls: c.details, results: out };
}

// ---------------- op=confirm（人間が候補を選んで確定） ----------------
async function opConfirm(sb: any, body: any) {
  const id = String(body?.listing_id ?? ""), placeId = String(body?.place_id ?? "").trim();
  if (!UUID_RE.test(id) || !placeId || placeId.length > 300) return { ok: false, error: "listing_id(uuid) と place_id が必要です" };
  const { data: l } = await sb.from("google_place_listings").select("id, listing_name, candidates").eq("id", id).maybeSingle();
  if (!l) return { ok: false, error: "掲載が見つかりません" };
  const { data: dup } = await sb.from("google_place_listings").select("id, listing_name").eq("place_id", placeId).neq("id", id).maybeSingle();
  if (dup) return { ok: false, error: `同じ place_id が別の掲載「${dup.listing_name}」に登録済みです` };
  const c = new Counter();
  const dr = await placeDetails(placeId, c);
  if (!dr.ok) return { ok: false, error: "Place Details で確認できません: " + dr.error };
  const { error } = await sb.from("google_place_listings").update({ place_id: dr.place.id, google_display_name: dr.place.name || null, google_address: dr.place.address || null, status: "active", last_verified_at: new Date().toISOString(), last_error: null, review_note: `confirmed by ${String(body?.by ?? "admin").slice(0, 60)}: ${new Date().toISOString().slice(0, 10)}` }).eq("id", id);
  if (error) return { ok: false, error: "保存失敗: " + error.message };
  return { ok: true, listing: l.listing_name, place: { name: dr.place.name, address: dr.place.address, total: dr.place.count, rating: dr.place.rating } };
}

async function opHealth(sb: any) {
  const { data: m } = await sb.from("google_place_listings").select("status, listing_name, place_id, last_fetched_at, last_error, stores(name)").order("sort_order");
  const byStatus: Record<string, number> = {};
  for (const x of m ?? []) byStatus[x.status] = (byStatus[x.status] ?? 0) + 1;
  const { data: runs } = await sb.from("google_review_fetch_runs").select("op, run_on, status, ok_count, fail_count, api_calls, text_search_calls, place_details_calls, finished_at").order("id", { ascending: false }).limit(5);
  const { data: last } = await sb.from("google_review_snapshots").select("fetched_on").eq("source", "places_api").order("fetched_on", { ascending: false }).limit(1).maybeSingle();
  return { ok: true, by_status: byStatus, listings: (m ?? []).map((x: any) => ({ store: x.stores?.name, listing: x.listing_name, status: x.status, has_place_id: !!x.place_id, last_fetched_at: x.last_fetched_at, last_error: x.last_error })), recent_runs: runs ?? [], last_api_fetch_on: last?.fetched_on ?? null, key_configured: !!(Deno.env.get("GOOGLE_PLACES_API_KEY") ?? "").trim() };
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ ok: false, error: "POST のみ" }, 405);
  if (!authorized(req)) return json({ ok: false, error: "unauthorized" }, 401);
  let body: any = {};
  try { body = await req.json(); } catch { body = {}; }
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const op = String(body?.op ?? "fetch");
  try {
    switch (op) {
      case "fetch": return json(await opFetch(sb, body));
      case "resolve": return json(await opResolve(sb, body));
      case "confirm": return json(await opConfirm(sb, body));
      case "health": return json(await opHealth(sb));
      default: return json({ ok: false, error: "op は fetch / resolve / confirm / health" }, 400);
    }
  } catch (e) {
    const msg = String(e).replace(/key=[^&\s"]+/gi, "key=***").slice(0, 300);
    return json({ ok: false, error: msg }, 500);
  }
});
