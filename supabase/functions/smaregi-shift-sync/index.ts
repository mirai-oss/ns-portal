// シフト公開時にスマレジ・タイムカードへ予定(division=schedule)として反映する
// docs/シフト打刻_設計書.md v1.0 §4e
// v2.6.82: 個別削除(delete_one)・スマレジ側の既存予定を取り込む(import_from_smaregi)を追加
import { createClient } from "npm:@supabase/supabase-js@2";
import { getContractToken, resolveStoreContract, staffIdsByUser, API_BASE } from "../_shared/smaregi-contracts.ts";

// 2026-10-17 担当D: 複数契約対応。シフトは店舗単位の操作なので、店舗の運営（＝スマレジ契約）で送り先の契約を決める
// （店舗の対応は store_external_mappings の有効期間で引く＝運営変更の前後で別契約に切り替わる。判定日はシフトの日付）。
const SCOPES = "timecard.shifts:read timecard.shifts:write";

const cors: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });

const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

// 日をまたぐシフト（終了時刻が開始時刻より前＝翌日側の時刻）に対応するため、
// 'YYYY-MM-DD' を1日進める（2026-08-25 担当Bからの依頼で発見・修正）。
function addOneDay(dateStr: string): string {
  const d = new Date(dateStr + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() + 1);
  return d.toISOString().slice(0, 10);
}

function jwtUid(req: Request): string {
  try {
    const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    return JSON.parse(atob(jwt.split(".")[1].replace(/-/g, "+").replace(/_/g, "/"))).sub ?? "";
  } catch (_) { return ""; }
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
      const { data: row } = await sb.from("sf_shifts").select("id,store_id,work_date,smaregi_shift_result_id").eq("id", shiftId).maybeSingle();
      if (!row) return json({ ok: true }); // 既に無ければ削除済み扱い
      if (!(await callerAllowed(sb, uid, row.store_id))) return json({ ok: false, error: "forbidden" }, 403);
      if (row.smaregi_shift_result_id) {
        const rcDel = await resolveStoreContract(sb, row.store_id, String(row.work_date));
        if (!rcDel) return json({ ok: false, error: "店舗のスマレジ契約・店舗IDが特定できません" }, 400);
        let token: string;
        try { token = await getContractToken(rcDel.contract.contract_id, SCOPES); } catch (e) { return json({ ok: false, error: "スマレジ認証に失敗しました: " + String(e) }, 502); }
        const res = await fetch(`${API_BASE}/${rcDel.contract.contract_id}/timecard/shifts/${row.smaregi_shift_result_id}`, {
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

    // 期間の開始日で契約・事業所IDを決める（A=1日〜／B=16日〜。期間は運営変更日(月初)をまたがない）
    const pr0 = periodRange(periodKey);
    const periodStart = pr0 ? `${pr0.year}-${String(pr0.month).padStart(2, "0")}-${String(pr0.fromDay).padStart(2, "0")}` : new Date().toISOString().slice(0, 10);
    const rc = await resolveStoreContract(sb, storeId, periodStart);
    const smStoreId = rc?.smaregiStoreId;
    const contractId = rc?.contract.contract_id ?? "";

    // ---- スマレジと常に同じ状態に合わせる（Smaregi→ポータルの一方向リコンサイル。追加・時刻の食い違い修正・スマレジ側で消えた分の削除） ----
    if (action === "import_from_smaregi") {
      if (!smStoreId) return json({ ok: false, error: "店舗にスマレジ店舗IDが未設定です" }, 400);
      const range = periodRange(periodKey);
      if (!range) return json({ ok: false, error: "period_key の形式が不正です" }, 400);

      const { data: members } = await sb.from("user_stores").select("user_id").eq("store_id", storeId);
      const userIds = [...new Set((members ?? []).map((m: any) => m.user_id))];
      if (!userIds.length) return json({ ok: true, added: 0, updated: 0, removed: 0 });

      const userToStaff = await staffIdsByUser(sb, contractId, userIds as string[], periodStart);
      const staffToUser: Record<string, string> = {};
      Object.entries(userToStaff).forEach(([uid2, sid]) => { staffToUser[sid] = uid2; });
      const staffIds = Object.keys(staffToUser);
      if (!staffIds.length) return json({ ok: true, added: 0, updated: 0, removed: 0 });

      // ポータル側の現状（この店舗・この期間）
      const { data: existing } = await sb.from("sf_shifts")
        .select("id,user_id,work_date,start_time,end_time,is_off,smaregi_shift_result_id")
        .eq("store_id", storeId).eq("period_key", periodKey);
      const existingByKey: Record<string, any> = {};
      (existing ?? []).forEach((r: any) => { existingByKey[`${r.user_id}|${r.work_date}`] = r; });

      // 2026-09-10追加: sf_shiftsは(user_id,work_date)がDB全体で一意（1人1日1件。店舗をまたいでも1件）。
      //   掛け持ち勤務の人（本部所属で他店舗もヘルプする等）は、この店舗・この期間には行が無くても
      //   「別の店舗」に既にその日の行を持っていることがあり、それに気づかず新規insertしようとすると
      //   DB全体の一意制約違反でスマレジ同期処理全体が失敗していた（ユーザー報告の実エラー原因）。
      //   対象スタッフ・対象日範囲でstore_idを問わず既存行を取得し、他店舗に既にある日は
      //   上書き・追加のどちらもせずスキップする（他店舗のシフトを無断で書き換えないため）
      const rangeStart = `${range.year}-${String(range.month).padStart(2, "0")}-${String(range.fromDay).padStart(2, "0")}`;
      const rangeEnd = `${range.year}-${String(range.month).padStart(2, "0")}-${String(range.toDay).padStart(2, "0")}`;
      const { data: existingElsewhere } = await sb.from("sf_shifts")
        .select("user_id,work_date,store_id")
        .in("user_id", userIds).gte("work_date", rangeStart).lte("work_date", rangeEnd).neq("store_id", storeId);
      const otherStoreKeys = new Set((existingElsewhere ?? []).map((r: any) => `${r.user_id}|${r.work_date}`));
      const conflicts: string[] = [];

      let token: string;
      try { token = await getContractToken(contractId, SCOPES); } catch (e) { return json({ ok: false, error: "スマレジ認証に失敗しました: " + String(e) }, 502); }

      // スマレジ側の現状（この店舗・対象スタッフ・対象月）を1人1日1件に正規化
      const smaregiByKey: Record<string, { shiftResultId: string; start: string; end: string }> = {};
      for (const staffId of staffIds) {
        const userId = staffToUser[staffId];
        let res: Response;
        try {
          res = await fetch(
            `${API_BASE}/${contractId}/timecard/shifts/staffs/${staffId}/daily?division=schedule&year=${range.year}&month=${String(range.month).padStart(2, "0")}&store_id=${smStoreId}`,
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
            if (smaregiByKey[key]) continue; // 同じ日に複数レコードがある場合は最初の1件のみ（sf_shiftsは1人1日1件のため）
            smaregiByKey[key] = {
              shiftResultId: String(rec.shiftResultId ?? ""),
              start: String(rec.attendance).slice(11, 16),
              end: String(rec.leaving).slice(11, 16),
            };
          }
        }
      }

      const nowIso = new Date().toISOString();
      const toInsert: any[] = [];
      let updated = 0, removed = 0;

      // スマレジにある分 → ポータルに無ければ追加、あって内容が違えば上書き（スマレジを正として合わせる）
      for (const key of Object.keys(smaregiByKey)) {
        const sm = smaregiByKey[key];
        const cur = existingByKey[key];
        const [userId, workDate] = key.split("|");
        if (!cur && otherStoreKeys.has(key)) {
          // 既に他店舗にこの人・この日の行があるため、書き換えずスキップ（掛け持ち勤務の衝突）
          conflicts.push(`${userId} ${workDate}`);
          continue;
        }
        if (!cur) {
          toInsert.push({
            user_id: userId, store_id: storeId, work_date: workDate, period_key: periodKey,
            preset_id: null, is_off: false, start_time: sm.start, end_time: sm.end, break_minutes: 0,
            status: "published", published_at: nowIso,
            smaregi_sync_status: "synced", smaregi_shift_result_id: sm.shiftResultId,
            created_by: uid, updated_at: nowIso,
          });
        } else if (!cur.is_off && (String(cur.start_time).slice(0, 5) !== sm.start || String(cur.end_time).slice(0, 5) !== sm.end || cur.smaregi_shift_result_id !== sm.shiftResultId)) {
          await sb.from("sf_shifts").update({
            start_time: sm.start, end_time: sm.end, status: "published", published_at: nowIso,
            smaregi_sync_status: "synced", smaregi_shift_result_id: sm.shiftResultId, smaregi_error: null, updated_at: nowIso,
          }).eq("id", cur.id);
          updated++;
        }
      }

      // ポータルにはあるがスマレジから消えた分（スマレジ側で削除された）→ ポータルからも削除
      for (const key of Object.keys(existingByKey)) {
        const cur = existingByKey[key];
        if (cur.smaregi_shift_result_id && !smaregiByKey[key]) {
          await sb.from("sf_shifts").delete().eq("id", cur.id);
          removed++;
        }
      }

      // 2026-09-10修正: 一括insertが1件でも一意制約違反になると全体がエラーになり、この時点で
      //   既に反映済みの更新・削除の結果まで呼び出し元に返せなくなっていた。1件ずつinsertし直し、
      //   個別の失敗だけconflictsに積む（上のotherStoreKeysガードで大半は防げるが、他要因の
      //   一意制約違反が起きた場合の保険として残す）
      let added = 0;
      for (const row of toInsert) {
        const { error: insErr } = await sb.from("sf_shifts").insert(row);
        if (insErr) { conflicts.push(`${row.user_id} ${row.work_date} (${insErr.message})`); continue; }
        added++;
      }
      return json({ ok: true, added, updated, removed, conflictCount: conflicts.length, conflicts: conflicts.slice(0, 20) });
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
    const staffMap = await staffIdsByUser(sb, contractId, userIds as string[], periodStart);

    let token: string;
    try {
      token = await getContractToken(contractId, SCOPES);
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
        // 日またぎシフト（終了時刻が開始時刻より前）は退勤日を翌日にする
        // （2026-08-25 担当Bから発見・依頼。以前は退勤日=出勤日のままでスマレジ側がエラーになっていた）
        const startHm = s.start_time.slice(0, 5);
        const endHm = s.end_time.slice(0, 5);
        const leavingDate = endHm < startHm ? addOneDay(s.work_date) : s.work_date;
        const payload = {
          shiftDate: s.work_date,
          division: "schedule",
          attendance: `${s.work_date}T${startHm}:00+09:00`,
          leaving: `${leavingDate}T${endHm}:00+09:00`,
        };
        let res: Response;
        if (s.smaregi_shift_result_id) {
          res = await fetch(`${API_BASE}/${contractId}/timecard/shifts/${s.smaregi_shift_result_id}`, {
            method: "PUT",
            headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
            body: JSON.stringify(payload),
          });
        } else {
          res = await fetch(`${API_BASE}/${contractId}/timecard/shifts/${smStoreId}/${staffId}`, {
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
