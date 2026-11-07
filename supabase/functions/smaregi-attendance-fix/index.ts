// =============================================================
// smaregi-attendance-fix — 承認済みの勤怠修正（sf_attendance_alerts.status=approved）をスマレジ・タイムカードの勤務実績へ書き戻す
// 2026-11-07 新規（ユーザー指示「管理システム側で勤怠修正したものは、スマレジで API 連携で修正されるように」）
//
// スマレジ API: PUT /{contract_id}/timecard/shifts/{shift_result_id}
//   body { shiftDate, division: "result", attendance, leaving, breakStartTime1.., tardyFlag, earlyLeavingFlag }
//   scope: timecard.shifts:write（シフト同期と同じ。新規申請不要）。締め済み期間は 409。
//   遅刻/早退フラグは現在の実績（GET …/shifts/staffs/{staff_id}/daily?division=result）から引き継ぐ。休憩は申請の値（無ければ null）。
//
// 呼び出し: { alert_id } 認証は service_role（Authorization: Bearer）か x-notify-secret（slack-interact・手元の確認用）
// 結果: 成功 → alerts.smaregi_sync_status='synced'・labor_cost_daily の手修正ロック解除（以後はスマレジが正）
//       失敗 → 'failed'＋smaregi_error（Slack に表示し、手で直す）
// デプロイ: supabase functions deploy smaregi-attendance-fix --no-verify-jwt --project-ref uuvsxzhpxtghojoubjcc --yes
//   （認証は関数内で行う。--no-verify-jwt が無いとゲートウェイが Authorization 無しの呼び出しを 401 にする＝2026-11-07 初回デプロイで確認）
// =============================================================
import { createClient } from "npm:@supabase/supabase-js@2";
import { getContractToken, API_BASE } from "../_shared/smaregi-contracts.ts";

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

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ ok: false, error: "POSTのみ" }, 405);
  if (!authorized(req)) return json({ ok: false, error: "認証がありません" }, 401);
  let body: any = {};
  try { body = await req.json(); } catch { return json({ ok: false, error: "JSONを読めません" }, 400); }
  const alertId = String(body.alert_id ?? "");
  if (!/^[0-9a-f-]{36}$/.test(alertId)) return json({ ok: false, error: "alert_id が必要です" }, 400);
  const sb = svc();
  const now = () => new Date().toISOString();
  const fail = async (code: string, error: string, extra: Record<string, unknown> = {}) => {
    await sb.from("sf_attendance_alerts").update({ smaregi_sync_status: "failed", smaregi_error: error.slice(0, 500), smaregi_response: extra.response ?? null, updated_at: now() }).eq("id", alertId);
    return json({ ok: false, code, error, ...extra }, 200);
  };

  const { data: a } = await sb.from("sf_attendance_alerts").select("id,status,user_id,store_id,work_date,labor_cost_daily_id,proposed_clock_in,proposed_clock_out,proposed_break_start_1,proposed_break_end_1,proposed_break_start_2,proposed_break_end_2,smaregi_sync_status").eq("id", alertId).maybeSingle();
  if (!a) return json({ ok: false, error: "アラートが見つかりません" }, 404);
  if (a.status !== "approved") return json({ ok: false, code: "not_approved", error: `承認済みではありません（${a.status}）` }, 409);
  if (a.smaregi_sync_status === "synced") return json({ ok: true, code: "already_synced" });
  await sb.from("sf_attendance_alerts").update({ smaregi_sync_status: "pending", updated_at: now() }).eq("id", alertId);

  const { data: l } = await sb.from("labor_cost_daily").select("id,smaregi_shift_result_id,smaregi_staff_id,work_date").eq("id", a.labor_cost_daily_id).maybeSingle();
  if (!l?.smaregi_shift_result_id || !l?.smaregi_staff_id) return await fail("no_smaregi_id", "スマレジの実績ID／スタッフIDが無い行のため書き戻せません（手で直してください）");

  // 契約の特定: 従業員×契約リンクのうち、この行のスタッフIDと一致し勤務日に有効なもの
  const { data: links } = await sb.from("employee_smaregi_links").select("contract_id,smaregi_staff_id,effective_from,effective_to")
    .eq("user_id", a.user_id).eq("smaregi_staff_id", String(l.smaregi_staff_id));
  const effective = (links ?? []).filter((x: any) => (!x.effective_from || x.effective_from <= a.work_date) && (!x.effective_to || x.effective_to >= a.work_date));
  // 2 契約（トーホー sez093z1 / LiveGate sdm155v1）の切り分け: 店舗の契約（store_external_mappings の corporation_hint・勤務日時点）と一致するリンクを優先。
  // 例: 黒霧屋 新横浜は 2026-11-01 から livegate。兼務者は両契約にリンクがあるため、店舗側で決める。
  const { data: maps } = await sb.from("store_external_mappings").select("corporation_hint,effective_from,effective_to,is_active")
    .eq("source_system", "smaregi_timecard").eq("store_id", a.store_id);
  const storeHint = (maps ?? []).find((m: any) => m.is_active !== false && (!m.effective_from || m.effective_from <= a.work_date) && (!m.effective_to || m.effective_to >= a.work_date))?.corporation_hint ?? null;
  const { data: contracts } = await sb.from("smaregi_contracts").select("contract_id,corporation_hint,is_default").eq("is_active", true);
  const storeContract = storeHint
    ? (contracts ?? []).find((c: any) => c.corporation_hint === storeHint)?.contract_id ?? null
    : (contracts ?? []).find((c: any) => c.is_default)?.contract_id ?? null;
  const link = effective.find((x: any) => storeContract && x.contract_id === storeContract) ?? (effective.length === 1 ? effective[0] : null);
  if (!link?.contract_id) return await fail("no_contract", `この従業員のスマレジ契約を特定できません（店舗の契約=${storeContract ?? "不明"}・有効なリンク=${effective.map((x: any) => String(x.contract_id).slice(-3)).join("/") || "なし"}）`);

  let token: string;
  try { token = await getContractToken(link.contract_id, SCOPES); } catch (e) { return await fail("auth", "スマレジ認証に失敗: " + String(e).slice(0, 200)); }

  // 現在の実績（休憩・フラグを引き継ぐため）
  const [y, m] = String(a.work_date).split("-");
  let cur: any = null;
  try {
    const r = await fetch(`${API_BASE}/${link.contract_id}/timecard/shifts/staffs/${l.smaregi_staff_id}/daily?division=result&year=${y}&month=${m}`, { headers: { Authorization: `Bearer ${token}` } });
    const b = r.ok ? await r.json() : null;
    for (const byStore of Object.values<any>(b?.shiftDaily ?? {})) {
      for (const entry of Object.values<any>(byStore ?? {})) {
        const rec = entry?.["0"];
        if (rec && String(rec.shiftResultId) === String(l.smaregi_shift_result_id)) cur = rec;
      }
    }
  } catch (_) { /* 引き継ぎ情報が取れなくても出勤・退勤だけで更新する */ }

  // 休憩は申請の値をそのまま送る（申請で休憩なしなら null で消す。2026-11-07 ユーザー指示「修正依頼に休憩も」）
  const bk = (v: string | null) => (v ? jstIso(v) : null);
  const payload: Record<string, unknown> = {
    shiftDate: a.work_date, division: "result",
    attendance: jstIso(a.proposed_clock_in), leaving: jstIso(a.proposed_clock_out),
    breakStartTime1: bk(a.proposed_break_start_1), breakEndTime1: bk(a.proposed_break_end_1),
    breakStartTime2: bk(a.proposed_break_start_2), breakEndTime2: bk(a.proposed_break_end_2),
    ...(cur?.tardyFlag != null ? { tardyFlag: String(cur.tardyFlag) } : {}),
    ...(cur?.earlyLeavingFlag != null ? { earlyLeavingFlag: String(cur.earlyLeavingFlag) } : {}),
  };
  const res = await fetch(`${API_BASE}/${link.contract_id}/timecard/shifts/${l.smaregi_shift_result_id}`, {
    method: "PUT", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" }, body: JSON.stringify(payload),
  });
  const rj = await res.json().catch(() => null);
  if (!res.ok) {
    const detail = rj?.detail ?? rj?.title ?? (rj ? JSON.stringify(rj).slice(0, 200) : "");
    const hint = res.status === 409 ? "（締め済みの期間のため、スマレジの管理画面から直してください）" : res.status === 404 ? "（スマレジ側に実績が無い）" : "";
    return await fail("smaregi_" + res.status, `スマレジ更新に失敗 HTTP ${res.status} ${detail}${hint}`, { response: rj, status: res.status });
  }
  // 成功: 記録し、ハブの手修正ロックを解除（以後はスマレジが正。翌朝の同期で同じ値・正しい概算人件費に置き換わる）
  await sb.from("sf_attendance_alerts").update({ smaregi_sync_status: "synced", smaregi_synced_at: now(), smaregi_error: null, smaregi_response: rj, updated_at: now() }).eq("id", alertId);
  await sb.from("labor_cost_daily").update({ manual_fixed_at: null, updated_at: now() }).eq("id", l.id);
  return json({ ok: true, code: "synced", contract: String(link.contract_id).slice(-3), shift_result_id: l.smaregi_shift_result_id, sent: payload, response: rj });
});
