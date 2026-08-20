// シフト公開時にスマレジ・タイムカードへ予定(division=schedule)として反映する
// docs/シフト打刻_設計書.md v1.0 §4e
import { createClient } from "npm:@supabase/supabase-js@2";

const IS_PROD = Deno.env.get("SMAREGI_ENV") === "prod";
const ID_BASE = IS_PROD ? "https://id.smaregi.jp" : "https://id.smaregi.dev";
const API_BASE = IS_PROD ? "https://api.smaregi.jp" : "https://api.smaregi.dev";
const CONTRACT = Deno.env.get("SMAREGI_CONTRACT_ID") ?? "";
const CID = Deno.env.get("SMAREGI_CLIENT_ID") ?? "";
const SECRET = Deno.env.get("SMAREGI_CLIENT_SECRET") ?? "";
const SCOPES = "timecard.shifts:read timecard.shifts:write";

const cors: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });

const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

function jwtUid(req: Request): string {
  try {
    const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    return JSON.parse(atob(jwt.split(".")[1].replace(/-/g, "+").replace(/_/g, "/"))).sub ?? "";
  } catch (_) { return ""; }
}

async function getToken(): Promise<string> {
  const res = await fetch(`${ID_BASE}/app/${CONTRACT}/token`, {
    method: "POST",
    headers: {
      Authorization: "Basic " + btoa(`${CID}:${SECRET}`),
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: "grant_type=client_credentials&scope=" + encodeURIComponent(SCOPES),
  });
  const j = await res.json();
  if (!res.ok || !j.access_token) throw new Error("token error: " + JSON.stringify(j));
  return j.access_token;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const body = await req.json().catch(() => ({}));
    const periodKey = String(body.period_key ?? "");
    const storeId = String(body.store_id ?? "");
    if (!periodKey || !storeId) return json({ ok: false, error: "period_key and store_id required" }, 400);

    const uid = jwtUid(req);
    if (!uid) return json({ ok: false, error: "unauthorized" }, 401);
    const sb = svc();

    // 権限確認: マスター/CEO/HQ/TEAMは常に可、TENCHOは自店舗のみ
    const { data: caller } = await sb.from("users").select("role,is_active,is_master").eq("id", uid).single();
    if (!caller || !caller.is_active) return json({ ok: false, error: "unauthorized" }, 401);
    let allowed = caller.is_master || ["CEO", "HQ", "TEAM"].includes(caller.role);
    if (!allowed && caller.role === "TENCHO") {
      const { data: us } = await sb.from("user_stores").select("store_id").eq("user_id", uid).eq("store_id", storeId).maybeSingle();
      allowed = !!us;
    }
    if (!allowed) return json({ ok: false, error: "forbidden" }, 403);

    const { data: store } = await sb.from("stores").select("smaregi_store_id").eq("id", storeId).single();
    const smStoreId = store?.smaregi_store_id;

    const { data: shifts, error: shErr } = await sb
      .from("sf_shifts")
      .select("id,user_id,work_date,start_time,end_time,is_off,smaregi_shift_result_id")
      .eq("store_id", storeId)
      .eq("period_key", periodKey)
      .eq("status", "published");
    if (shErr) return json({ ok: false, error: shErr.message }, 500);
    if (!shifts || !shifts.length) return json({ ok: true, synced: 0, failed: 0, skipped: 0 });

    if (!smStoreId) {
      // 店舗がスマレジと未紐付け → 全件エラー扱いにして管理画面に気づかせる
      for (const s of shifts) {
        await sb.from("sf_shifts").update({ smaregi_sync_status: "error", smaregi_error: "店舗にスマレジ店舗IDが未設定です" }).eq("id", s.id);
      }
      return json({ ok: true, synced: 0, failed: shifts.length, skipped: 0 });
    }

    const userIds = [...new Set(shifts.map((s) => s.user_id))];
    const { data: profs } = await sb.from("employee_profiles").select("user_id,smaregi_staff_id").in("user_id", userIds);
    const staffMap: Record<string, string> = {};
    (profs ?? []).forEach((p: any) => { if (p.smaregi_staff_id) staffMap[p.user_id] = p.smaregi_staff_id; });

    let token: string;
    try {
      token = await getToken();
    } catch (e) {
      return json({ ok: false, error: "スマレジ認証に失敗しました: " + String(e) }, 502);
    }

    let synced = 0, failed = 0, skipped = 0;
    for (const s of shifts) {
      const staffId = staffMap[s.user_id];
      if (!staffId) { // スマレジ未連携の人（本人がまだスタッフ紐付けされていない等）はスキップ
        await sb.from("sf_shifts").update({ smaregi_sync_status: "error", smaregi_error: "スマレジ・スタッフIDが未連携です" }).eq("id", s.id);
        skipped++;
        continue;
      }
      if (s.is_off) { // 休みはスマレジ側に何も作らない
        await sb.from("sf_shifts").update({ smaregi_sync_status: "synced", smaregi_error: null }).eq("id", s.id);
        synced++;
        continue;
      }
      try {
        const payload = {
          shiftDate: s.work_date,
          division: "schedule",
          attendance: `${s.work_date}T${s.start_time.slice(0, 5)}:00+09:00`,
          leaving: `${s.work_date}T${s.end_time.slice(0, 5)}:00+09:00`,
        };
        let res: Response;
        if (s.smaregi_shift_result_id) {
          res = await fetch(`${API_BASE}/${CONTRACT}/timecard/shifts/${s.smaregi_shift_result_id}`, {
            method: "PUT",
            headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
            body: JSON.stringify(payload),
          });
        } else {
          res = await fetch(`${API_BASE}/${CONTRACT}/timecard/shifts/${smStoreId}/${staffId}`, {
            method: "POST",
            headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
            body: JSON.stringify(payload),
          });
        }
        const j = await res.json().catch(() => null);
        if (!res.ok) {
          await sb.from("sf_shifts").update({ smaregi_sync_status: "error", smaregi_error: (j ? JSON.stringify(j) : `HTTP ${res.status}`).slice(0, 500) }).eq("id", s.id);
          failed++;
          continue;
        }
        await sb.from("sf_shifts").update({
          smaregi_sync_status: "synced",
          smaregi_shift_result_id: String(j.shiftResultId ?? s.smaregi_shift_result_id),
          smaregi_error: null,
        }).eq("id", s.id);
        synced++;
      } catch (e) {
        await sb.from("sf_shifts").update({ smaregi_sync_status: "error", smaregi_error: String(e).slice(0, 500) }).eq("id", s.id);
        failed++;
      }
    }
    return json({ ok: true, synced, failed, skipped });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
