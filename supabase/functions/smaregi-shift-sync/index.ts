// シフト公開時にスマレジ・タイムカードへ予定(division=schedule)として反映する
// docs/シフト打刻_設計書.md v1.0 §4e
// v2.6.82: 個別削除(delete_one)・スマレジ側の既存予定を取り込む(import_from_smaregi)を追加
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

// マスター/CEO/HQ/TEAMは常に可、TENCHOは自店舗のみ
async function callerAllowed(sb: any, uid: string, storeId: string): Promise<boolean> {
  const { data: caller } = await sb.from("users").select("role,is_active,is_master").eq("id", uid).single();
  if (!caller || !caller.is_active) return false;
  if (caller.is_master || ["CEO", "HQ", "TEAM"].includes(caller.role)) return true;
  if (caller.role === "TENCHO") {
    const { data: us } = await sb.from("user_stores").select("store_id").eq("user_id", uid).eq("store_id", storeId).maybeSingle();
    return !!us;
  }
  return false;
}

// period_key（例 "2026-08-A"/"2026-08-B"）から年・月・対象日範囲を求める
function periodRange(periodKey: string): { year: number; month: number; fromDay: number; toDay: number } | null {
  const m = periodKey.match(/^(\d{4})-(\d{2})-([AB])$/);
  if (!m) return null;
  const year = +m[1], month = +m[2], half = m[3];
  if (half === "A") return { year, month, fromDay: 1, toDay: 15 };
  const lastDay = new Date(year, month, 0).getDate(); // month=1-indexedのままでOK（翌月0日=当月末日）
  return { year, month, fromDay: 16, toDay: lastDay };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const body = await req.json().catch(() => ({}));
    const uid = jwtUid(req);
    if (!uid) return json({ ok: false, error: "unauthorized" }, 401);
    const sb = svc();
    const action = String(body.action ?? "sync_publish");

    // ---- 個別削除: 1件のシフトをスマレジ側も含めて削除する ----
    if (action === "delete_one") {
      const shiftId = String(body.shift_id ?? "");
      if (!shiftId) return json({ ok: false, error: "shift_id required" }, 400);
      const { data: row } = await sb.from("sf_shifts").select("id,store_id,smaregi_shift_result_id").eq("id", shiftId).maybeSingle();
      if (!row) return json({ ok: true }); // 既に無ければ削除済み扱い
      if (!(await callerAllowed(sb, uid, row.store_id))) return json({ ok: false, error: "forbidden" }, 403);
      if (row.smaregi_shift_result_id) {
        let token: string;
        try { token = await getToken(); } catch (e) { return json({ ok: false, error: "スマレジ認証に失敗しました: " + String(e) }, 502); }
        const res = await fetch(`${API_BASE}/${CONTRACT}/timecard/shifts/${row.smaregi_shift_result_id}`, {
          method: "DELETE",
          headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
          body: JSON.stringify({ division: "schedule" }),
        });
        if (!res.ok) {
          const j = await res.json().catch(() => null);
          return json({ ok: false, error: "スマレジ側の削除に失敗しました: " + (j ? JSON.stringify(j) : `HTTP ${res.status}`) }, 502);
        }
      }
      const { error: delErr } = await sb.from("sf_shifts").delete().eq("id", shiftId);
      if (delErr) return json({ ok: false, error: delErr.message }, 500);
      return json({ ok: true });
    }

    // ここから先は period_key・store_id が必須の2アクション
    const periodKey = String(body.period_key ?? "");
    const storeId = String(body.store_id ?? "");
    if (!periodKey || !storeId) return json({ ok: false, error: "period_key and store_id required" }, 400);
    if (!(await callerAllowed(sb, uid, storeId))) return json({ ok: false, error: "forbidden" }, 403);

    const { data: store } = await sb.from("stores").select("smaregi_store_id").eq("id", storeId).single();
    const smStoreId = store?.smaregi_store_id;

    // ---- スマレジに既にある予定シフトを取り込む（Smaregi→ポータル。ポータル側に無い日だけ追加、既存データは上書きしない） ----
    if (action === "import_from_smaregi") {
      if (!smStoreId) return json({ ok: false, error: "店舗にスマレジ店舗IDが未設定です" }, 400);
      const range = periodRange(periodKey);
      if (!range) return json({ ok: false, error: "period_key の形式が不正です" }, 400);

      const { data: members } = await sb.from("user_stores").select("user_id").eq("store_id", storeId);
      const userIds = [...new Set((members ?? []).map((m: any) => m.user_id))];
      if (!userIds.length) return json({ ok: true, imported: 0, skipped: 0 });

      const { data: profs } = await sb.from("employee_profiles").select("user_id,smaregi_staff_id").in("user_id", userIds);
      const staffToUser: Record<string, string> = {};
      (profs ?? []).forEach((p: any) => { if (p.smaregi_staff_id) staffToUser[p.smaregi_staff_id] = p.user_id; });
      const staffIds = Object.keys(staffToUser);
      if (!staffIds.length) return json({ ok: true, imported: 0, skipped: 0 });

      const { data: existing } = await sb.from("sf_shifts").select("user_id,work_date").eq("store_id", storeId).eq("period_key", periodKey);
      const existingSet = new Set((existing ?? []).map((r: any) => `${r.user_id}|${r.work_date}`));

      let token: string;
      try { token = await getToken(); } catch (e) { return json({ ok: false, error: "スマレジ認証に失敗しました: " + String(e) }, 502); }

      const toInsert: any[] = [];
      let skipped = 0;
      for (const staffId of staffIds) {
        const userId = staffToUser[staffId];
        let res: Response;
        try {
          res = await fetch(
            `${API_BASE}/${CONTRACT}/timecard/shifts/staffs/${staffId}/daily?division=schedule&year=${range.year}&month=${String(range.month).padStart(2, "0")}&store_id=${smStoreId}`,
            { headers: { Authorization: `Bearer ${token}` } },
          );
        } catch (_e) { continue; }
        if (!res.ok) continue; // その従業員の分だけスキップ（他の人は続行）
        const j = await res.json().catch(() => null);
        const daily = j?.shiftDaily ?? {};
        for (const dateKey of Object.keys(daily)) {
          const day = +dateKey.slice(8, 10);
          if (day < range.fromDay || day > range.toDay) continue;
          const byStore = daily[dateKey]?.[String(smStoreId)];
          if (!byStore) continue;
          for (const idx of Object.keys(byStore)) {
            const rec = byStore[idx];
            if (!rec?.attendance || !rec?.leaving) continue;
            const key = `${userId}|${dateKey}`;
            if (existingSet.has(key)) { skipped++; continue; }
            existingSet.add(key); // 同じ日に複数レコードがある場合は最初の1件のみ（sf_shiftsは1人1日1件のため）
            toInsert.push({
              user_id: userId,
              store_id: storeId,
              work_date: dateKey,
              period_key: periodKey,
              preset_id: null,
              is_off: false,
              start_time: String(rec.attendance).slice(11, 16),
              end_time: String(rec.leaving).slice(11, 16),
              break_minutes: 0,
              status: "published",
              published_at: new Date().toISOString(),
              smaregi_sync_status: "synced",
              smaregi_shift_result_id: String(rec.shiftResultId ?? ""),
              created_by: uid,
              updated_at: new Date().toISOString(),
            });
          }
        }
      }
      if (toInsert.length) {
        const { error: insErr } = await sb.from("sf_shifts").insert(toInsert);
        if (insErr) return json({ ok: false, error: insErr.message }, 500);
      }
      return json({ ok: true, imported: toInsert.length, skipped });
    }

    // ---- 公開時の同期（既定動作。旧仕様と互換） ----
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
