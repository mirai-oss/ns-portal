// =============================================================
// smaregi-attendance-fix — 承認済みの勤怠修正（sf_attendance_alerts.status=approved）をスマレジ・タイムカードの勤務実績へ書き戻す
// 2026-11-07 新規（ユーザー指示「管理システム側で勤怠修正したものは、スマレジで API 連携で修正されるように」）
//
// スマレジ API: PUT /{contract_id}/timecard/shifts/{shift_result_id}
//   body { shiftDate, division: "result", attendance, leaving, breakStartTime1.., tardyFlag, earlyLeavingFlag }
//   scope: timecard.shifts:write（シフト同期と同じ。新規申請不要）。締め済み期間は 409。
//   遅刻/早退フラグは現在の実績（GET …/shifts/staffs/{staff_id}/daily?division=result）から引き継ぐ。休憩は申請の値（無ければ null）。
//
// 呼び出し: { alert_id }（Slack ○× の修正申請）または { request_id }（フォーム申請: kind=fix は PUT・kind=add は POST /shifts/{store}/{staff} で実績を新規作成）
//   認証は service_role（Authorization: Bearer）か x-notify-secret（slack-interact・手元の確認用）
//   2026-11-07: 実績 ID は既定外の契約では 'sdm155v1:123' のように契約 ID が前置されている（同期の仕様）→ API に渡す前に外す
// 結果: 成功 → alerts.smaregi_sync_status='synced'・labor_cost_daily の手修正ロック解除（以後はスマレジが正）
//       失敗 → 'failed'＋smaregi_error（Slack に表示し、手で直す）
// デプロイ: supabase functions deploy smaregi-attendance-fix --no-verify-jwt --project-ref uuvsxzhpxtghojoubjcc --yes
//   （認証は関数内で行う。--no-verify-jwt が無いとゲートウェイが Authorization 無しの呼び出しを 401 にする＝2026-11-07 初回デプロイで確認）
// =============================================================
import { createClient } from "npm:@supabase/supabase-js@2";
import { getContractToken, resolveStoreContract, staffIdsByUser, API_BASE } from "../_shared/smaregi-contracts.ts";

const SCOPES = "timecard.shifts:read timecard.shifts:write";
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json" } });
const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

function timingSafeEqual(a: string, b: string) {
  if (a.length !== b.length) return false;
  let r = 0; for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}
function authorized(req: Request): boolean {
  const key = (Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "").trim();
  const auth = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (key && auth && timingSafeEqual(auth, key)) return true;
  const secret = (Deno.env.get("NOTIFY_SLACK_SECRET") ?? "").trim();
  const hdr = (req.headers.get("x-notify-secret") ?? "").trim();
  return !!(secret && hdr && timingSafeEqual(secret, hdr));
}
// "YYYY-MM-DDThh:mm:ss+09:00"（スマレジの例と同じ形）
function jstIso(iso: string): string {
  const d = new Date(iso);
  const p: Record<string, string> = {};
  for (const x of new Intl.DateTimeFormat("ja-JP", { timeZone: "Asia/Tokyo", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false }).formatToParts(d)) p[x.type] = x.value;
  return `${p.year}-${p.month}-${p.day}T${p.hour === "24" ? "00" : p.hour}:${p.minute}:${p.second}+09:00`;
}


type Target = {
  table: "sf_attendance_alerts" | "sf_attendance_requests"; id: string; kind: "fix" | "add" | "delete";
  deleted_key?: string | null;   // 2026-11-08 打刻削除: 承認時に消した行の smaregi_shift_result_id（'sdm155v1:123' 形式あり）
  user_id: string; store_id: string; work_date: string; labor_cost_daily_id: string | null;
  clock_in: string; clock_out: string; b1s: string | null; b1e: string | null; b2s: string | null; b2e: string | null;
};
const stripContract = (key: string | null | undefined, contractId: string) => (key ?? "").startsWith(contractId + ":") ? String(key).slice(contractId.length + 1) : String(key ?? "");

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ ok: false, error: "POSTのみ" }, 405);
  if (!authorized(req)) return json({ ok: false, error: "認証がありません" }, 401);
  let body: any = {};
  try { body = await req.json(); } catch { return json({ ok: false, error: "JSONを読めません" }, 400); }
  const sb = svc();
  const now = () => new Date().toISOString();

  // ---- 対象の読み込み（アラート or フォーム申請）----
  let t: Target | null = null;
  if (/^[0-9a-f-]{36}$/.test(String(body.alert_id ?? ""))) {
    const { data: a } = await sb.from("sf_attendance_alerts").select("request_kind,deleted_shift_result_id,id,status,user_id,store_id,work_date,labor_cost_daily_id,proposed_clock_in,proposed_clock_out,proposed_break_start_1,proposed_break_end_1,proposed_break_start_2,proposed_break_end_2,smaregi_sync_status").eq("id", body.alert_id).maybeSingle();
    if (!a) return json({ ok: false, error: "アラートが見つかりません" }, 404);
    if (a.status !== "approved") return json({ ok: false, code: "not_approved", error: `承認済みではありません（${a.status}）` }, 409);
    if (a.smaregi_sync_status === "synced") return json({ ok: true, code: "already_synced" });
    t = { table: "sf_attendance_alerts", id: a.id, kind: a.request_kind === "delete" ? "delete" : "fix", deleted_key: a.deleted_shift_result_id ?? null, user_id: a.user_id, store_id: a.store_id, work_date: a.work_date, labor_cost_daily_id: a.labor_cost_daily_id,
      clock_in: a.proposed_clock_in, clock_out: a.proposed_clock_out, b1s: a.proposed_break_start_1, b1e: a.proposed_break_end_1, b2s: a.proposed_break_start_2, b2e: a.proposed_break_end_2 };
  } else if (/^[0-9a-f-]{36}$/.test(String(body.request_id ?? ""))) {
    const { data: r } = await sb.from("sf_attendance_requests").select("id,kind,status,user_id,store_id,work_date,labor_cost_daily_id,clock_in,clock_out,break_start_1,break_end_1,break_start_2,break_end_2,smaregi_sync_status").eq("id", body.request_id).maybeSingle();
    if (!r) return json({ ok: false, error: "申請が見つかりません" }, 404);
    if (r.status !== "approved") return json({ ok: false, code: "not_approved", error: `承認済みではありません（${r.status}）` }, 409);
    if (r.smaregi_sync_status === "synced") return json({ ok: true, code: "already_synced" });
    t = { table: "sf_attendance_requests", id: r.id, kind: r.kind === "add" ? "add" : "fix", user_id: r.user_id, store_id: r.store_id, work_date: r.work_date, labor_cost_daily_id: r.labor_cost_daily_id,
      clock_in: r.clock_in, clock_out: r.clock_out, b1s: r.break_start_1, b1e: r.break_end_1, b2s: r.break_start_2, b2e: r.break_end_2 };
  } else {
    return json({ ok: false, error: "alert_id か request_id が必要です" }, 400);
  }
  const target = t;
  const fail = async (code: string, error: string, extra: Record<string, unknown> = {}) => {
    await sb.from(target.table).update({ smaregi_sync_status: "failed", smaregi_error: error.slice(0, 500), smaregi_response: extra.response ?? null, updated_at: now() }).eq("id", target.id);
    return json({ ok: false, code, error, ...extra }, 200);
  };
  await sb.from(target.table).update({ smaregi_sync_status: "pending", updated_at: now() }).eq("id", target.id);

  // ---- 契約・事業所・スタッフ（店舗の契約を勤務日時点で決める。黒霧屋=11/1〜LiveGate）----
  const rc = await resolveStoreContract(sb, target.store_id, target.work_date);
  if (!rc) return await fail("no_contract", "この店舗のスマレジ契約／事業所 ID（store_external_mappings）が見つかりません");
  const contractId = rc.contract.contract_id;

  // ---- 打刻削除（2026-11-08）: ハブ側は承認 RPC で削除済み。スマレジの勤務実績を DELETE（締め済みは 409）----
  if (target.kind === "delete") {
    const key = target.deleted_key ?? "";
    if (!key || key.startsWith("req:")) {
      // スマレジに無い行（フォーム追加がまだ反映前など）→ 消すものが無い
      await sb.from(target.table).update({ smaregi_sync_status: "skipped", smaregi_synced_at: now(), smaregi_error: null, updated_at: now() }).eq("id", target.id);
      return json({ ok: true, code: "no_smaregi_record", mode: "delete" });
    }
    let dtoken: string;
    try { dtoken = await getContractToken(contractId, SCOPES); } catch (e) { return await fail("auth", "スマレジ認証に失敗: " + String(e).slice(0, 200)); }
    const did = stripContract(key, contractId);
    const dres = await fetch(`${API_BASE}/${contractId}/timecard/shifts/${did}`, { method: "DELETE", headers: { Authorization: `Bearer ${dtoken}`, "Content-Type": "application/json" }, body: JSON.stringify({ division: "result" }) });
    const dj = await dres.json().catch(() => null);
    if (!dres.ok && dres.status !== 404) {
      const detail = dj?.detail ?? dj?.title ?? (dj ? JSON.stringify(dj).slice(0, 200) : "");
      const hint = dres.status === 409 ? "（締め済みの期間のため、スマレジの管理画面から消してください）" : "";
      return await fail("smaregi_" + dres.status, `スマレジの勤務実績の削除に失敗 HTTP ${dres.status} ${detail}${hint}`, { response: dj, status: dres.status });
    }
    // 404＝スマレジ側にもう無い → 消えている状態なので成功扱い
    await sb.from(target.table).update({ smaregi_sync_status: "synced", smaregi_synced_at: now(), smaregi_error: null, smaregi_response: dj ?? { status: dres.status }, updated_at: now() }).eq("id", target.id);
    return json({ ok: true, code: dres.status === 404 ? "already_deleted" : "deleted", mode: "delete", contract: contractId.slice(-3), shift_result_id: did });
  }

  const staffMap = await staffIdsByUser(sb, contractId, [target.user_id], target.work_date);
  const staffId = staffMap[target.user_id];
  if (!staffId) {
    // 紐づけ自体はあるが勤務日が有効期間外（例: 入社前の日付）なのか、紐づけが無いのかを分けて伝える
    const { data: anyLinks } = await sb.from("employee_smaregi_links").select("effective_from,effective_to").eq("contract_id", contractId).eq("user_id", target.user_id);
    if (anyLinks?.length) {
      const spans = anyLinks.map((l: any) => `${l.effective_from ?? "?"}〜${l.effective_to ?? ""}`).join(", ");
      return await fail("staff_out_of_range", `この従業員のスマレジ・スタッフ ID はありますが、勤務日 ${target.work_date} が紐づけの有効期間（${spans}）の外です`);
    }
    return await fail("no_staff", `この従業員の契約…${contractId.slice(-3)} でのスマレジ・スタッフ ID（employee_smaregi_links）が見つかりません`);
  }

  let token: string;
  try { token = await getContractToken(contractId, SCOPES); } catch (e) { return await fail("auth", "スマレジ認証に失敗: " + String(e).slice(0, 200)); }

  const { data: l } = target.labor_cost_daily_id ? await sb.from("labor_cost_daily").select("id,smaregi_shift_result_id").eq("id", target.labor_cost_daily_id).maybeSingle() : { data: null };
  const existingKey = l?.smaregi_shift_result_id ?? null;
  const isAdd = target.kind === "add" || !existingKey || String(existingKey).startsWith("req:");

  // 現在の実績（遅刻/早退フラグの引き継ぎ用）
  const [y, m] = String(target.work_date).split("-");
  let cur: any = null;
  if (!isAdd) {
    try {
      const r = await fetch(`${API_BASE}/${contractId}/timecard/shifts/staffs/${staffId}/daily?division=result&year=${y}&month=${m}`, { headers: { Authorization: `Bearer ${token}` } });
      const b = r.ok ? await r.json() : null;
      const want = stripContract(existingKey, contractId);
      for (const byStore of Object.values<any>(b?.shiftDaily ?? {})) for (const entry of Object.values<any>(byStore ?? {})) {
        const rec = entry?.["0"]; if (rec && String(rec.shiftResultId) === want) cur = rec;
      }
    } catch (_) { /* 取れなくても出勤・退勤・休憩だけで更新する */ }
  }
  const bk = (v: string | null) => (v ? jstIso(v) : null);
  const payload: Record<string, unknown> = {
    shiftDate: target.work_date, division: "result",
    attendance: jstIso(target.clock_in), leaving: jstIso(target.clock_out),
    breakStartTime1: bk(target.b1s), breakEndTime1: bk(target.b1e), breakStartTime2: bk(target.b2s), breakEndTime2: bk(target.b2e),
    ...(cur?.tardyFlag != null ? { tardyFlag: String(cur.tardyFlag) } : {}),
    ...(cur?.earlyLeavingFlag != null ? { earlyLeavingFlag: String(cur.earlyLeavingFlag) } : {}),
  };
  const url = isAdd
    ? `${API_BASE}/${contractId}/timecard/shifts/${rc.smaregiStoreId}/${staffId}`
    : `${API_BASE}/${contractId}/timecard/shifts/${stripContract(existingKey, contractId)}`;
  const res = await fetch(url, { method: isAdd ? "POST" : "PUT", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" }, body: JSON.stringify(payload) });
  const rj = await res.json().catch(() => null);
  if (!res.ok) {
    const detail = rj?.detail ?? rj?.title ?? (rj ? JSON.stringify(rj).slice(0, 200) : "");
    const hint = res.status === 409 ? "（締め済みの期間のため、スマレジの管理画面から直してください）" : res.status === 404 ? "（スマレジ側に実績が無い）" : res.status === 400 && isAdd ? "（同じ日に実績が既にある・スタッフが事業所に所属していない等）" : "";
    return await fail("smaregi_" + res.status, `スマレジ${isAdd ? "登録" : "更新"}に失敗 HTTP ${res.status} ${detail}${hint}`, { response: rj, status: res.status });
  }
  // 成功: 記録し、ハブの手修正ロックを解除（以後はスマレジが正）。追加のときは実績 ID をハブの行に入れる（翌朝の同期がこの行に upsert するように）
  await sb.from(target.table).update({ smaregi_sync_status: "synced", smaregi_synced_at: now(), smaregi_error: null, smaregi_response: rj, updated_at: now() }).eq("id", target.id);
  if (l?.id) {
    const upd: Record<string, unknown> = { manual_fixed_at: null, updated_at: now() };
    if (isAdd && rj?.shiftResultId != null) {
      upd.smaregi_shift_result_id = rc.contract.is_default ? String(rj.shiftResultId) : `${contractId}:${rj.shiftResultId}`;
      upd.smaregi_staff_id = staffId;
      upd.source = "smaregi";
    }
    await sb.from("labor_cost_daily").update(upd).eq("id", l.id);
  }
  return json({ ok: true, code: "synced", mode: isAdd ? "add" : "fix", contract: contractId.slice(-3), shift_result_id: rj?.shiftResultId ?? stripContract(existingKey, contractId), sent: payload, response: rj });
});
