// スマレジ・タイムカード 勤怠実績の日次取込 Edge Function
// docs/実装指示書_データ基盤Day2_勤怠API取込.md タスクC
// 2026-08-21 新規作成。
//
// 目的: 「CSV手動ダウンロード→シート貼り付け」を止めずに（旧経路は並走）、
//   スマレジの打刻実績(division=result)をAPIで取得し、attendance_records・
//   labor_cost_daily へ保存する。
//
// 従業員の特定は employee_profiles.smaregi_staff_id をキーにする
//   （「スマレジが従業員情報の正本」という2026-08-21のユーザー方針決定に基づく。
//    public.users.smaregi_staff_id という同名の別列があるが未使用＝混同しないこと）。
//
// スマレジAPIの応答は shiftDaily が「日付 → 店舗ID → 連番」のネストしたオブジェクト
// （配列ではない）。2026-08-21に使い捨てEdge Functionで実データを確認して判明。
//
// 呼び出し方:
//   { action: "sync", date_from?: "YYYY-MM-DD", date_to?: "YYYY-MM-DD" }
//     省略時は「昨日1日分」を対象にする（日次バッチ想定）。
//   認可: CEO/HQ/マスターのユーザーJWT、または内部の合言葉(p_secret)。
//     現状はservice_role権限での呼び出し（launchd/cron等の内部呼び出し）を主眼に、
//     人が確認のため叩く場合は認証済みCEO/HQ/マスターのJWTを必須にする。
import { createClient } from "npm:@supabase/supabase-js@2";
import { loadContracts, getContractToken, loadLinks, loadStoreMap, API_BASE } from "../_shared/smaregi-contracts.ts";

// 2026-11-07: 休憩（breakStartTime1〜breakEndTime2）を labor_cost_daily の break_* 列へ。取込・判定ロジックは無変更（列の追加のみ）。
// 2026-11-07: スマレジ側で直接修正された勤務の検知（ユーザー指示）。前回取込済みの行と出勤・退勤・休憩を比べ、違えば
//   sf_attendance_smaregi_changes に積み、勤怠確認チャンネル（slack_channels 'kintai.check'）へ「✏️ スマレジ側で直接修正」を通知。
//   対象外: 手修正ロック中（manual_fixed_at）・前回は退勤がまだ無かった行・休憩は前回取込で休憩を持っていた行だけ比較（初回の列追加で誤検知しない）。
// 2026-10-17 担当D: 複数契約対応。契約（smaregi_contracts）ごとにループし、従業員×契約リンクのスタッフIDと
// 契約ごとの店舗対応（store_external_mappings）で勤怠を取り込む（契約が違えば同じ番号の事業所IDが別店舗を指すため）。
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

// {y}-{m} の月ごとにdaily(division=result)を取得。年月をまたぐ範囲指定はこの関数の外でループする
async function fetchMonthResults(token: string, contract: string, staffId: string, year: number, month: number) {
  const url = `${API_BASE}/${contract}/timecard/shifts/staffs/${staffId}/daily?division=result&year=${year}&month=${String(month).padStart(2, "0")}`;
  const res = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
  if (!res.ok) {
    const t = await res.text();
    throw new Error(`smaregi API error (staff ${staffId} ${year}-${month}): ${res.status} ${t}`);
  }
  const body = await res.json();
  // shiftDaily: { "YYYY-MM-DD": { [storeId]: { "0": {...record}, personnelExpenses: "..." } } }
  const daily = body?.shiftDaily ?? {};
  const out: any[] = [];
  for (const [dateStr, byStore] of Object.entries<any>(daily)) {
    for (const [storeId, entry] of Object.entries<any>(byStore ?? {})) {
      const rec = entry?.["0"];
      if (!rec) continue;
      out.push({
        date: dateStr,
        storeIdSmaregi: storeId,
        shiftResultId: String(rec.shiftResultId ?? ""),
        attendance: rec.attendance || null,
        leaving: rec.leaving || null,
        tardy: rec.tardyFlag === "1",
        earlyLeaving: rec.earlyLeavingFlag === "1",
        dutyMinute: rec.dutyMinute ?? null,
        personnelExpenses: entry?.personnelExpenses ? Number(entry.personnelExpenses) : null,
        // 2026-11-07 休憩（ユーザー指示「休憩時間も取得」。Slack 勤怠確認の表示・修正・書き戻しに使う）
        breakStart1: rec.breakStartTime1 || null, breakEnd1: rec.breakEndTime1 || null,
        breakStart2: rec.breakStartTime2 || null, breakEnd2: rec.breakEndTime2 || null,
      });
    }
  }
  return out;
}

// ---- 2026-11-07 スマレジ側の直接修正の検知 ----
const sameTime = (a: string | null | undefined, b: string | null | undefined) => {
  if (!a && !b) return true; if (!a || !b) return false;
  return new Date(a).getTime() === new Date(b).getTime();
};
function hmJst(iso: string | null | undefined, workDate?: string): string {
  if (!iso) return "なし";
  const d = new Date(iso); const p: Record<string, string> = {};
  for (const x of new Intl.DateTimeFormat("ja-JP", { timeZone: "Asia/Tokyo", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hour12: false }).formatToParts(d)) p[x.type] = x.value;
  const date = `${p.year}-${p.month}-${p.day}`;
  return `${workDate && date > workDate ? "翌" : ""}${p.hour === "24" ? "00" : p.hour}:${p.minute}`;
}
function breakText(s1: any, e1: any, s2: any, e2: any, workDate: string): string {
  const one = (s: any, e: any) => s ? `${hmJst(s, workDate)}−${e ? hmJst(e, workDate) : "終了なし"}` : null;
  const parts = [one(s1, e1), one(s2, e2)].filter(Boolean);
  return parts.length ? parts.join("・") : "なし";
}
// 前回取込済みの行（prev）と今回（r）の差分。違いが無ければ null
function detectChange(prev: any, r: any, workDate: string): { before: any; after: any; text: string } | null {
  if (!prev || prev.manual_fixed_at || !prev.clock_out || !r.leaving) return null;
  const diffs: string[] = [];
  if (!sameTime(prev.clock_in, r.attendance)) diffs.push(`出勤 ${hmJst(prev.clock_in, workDate)} → ${hmJst(r.attendance, workDate)}`);
  if (!sameTime(prev.clock_out, r.leaving)) diffs.push(`退勤 ${hmJst(prev.clock_out, workDate)} → ${hmJst(r.leaving, workDate)}`);
  if (prev.break_minutes != null) { // 休憩は一度取り込んだ行だけ比べる
    if (!sameTime(prev.break_start_1, r.breakStart1) || !sameTime(prev.break_end_1, r.breakEnd1) || !sameTime(prev.break_start_2, r.breakStart2) || !sameTime(prev.break_end_2, r.breakEnd2)) {
      diffs.push(`休憩 ${breakText(prev.break_start_1, prev.break_end_1, prev.break_start_2, prev.break_end_2, workDate)} → ${breakText(r.breakStart1, r.breakEnd1, r.breakStart2, r.breakEnd2, workDate)}`);
    }
  }
  if (!diffs.length) return null;
  return {
    before: { clock_in: prev.clock_in, clock_out: prev.clock_out, break_start_1: prev.break_start_1, break_end_1: prev.break_end_1, break_start_2: prev.break_start_2, break_end_2: prev.break_end_2 },
    after: { clock_in: r.attendance, clock_out: r.leaving, break_start_1: r.breakStart1, break_end_1: r.breakEnd1, break_start_2: r.breakStart2, break_end_2: r.breakEnd2 },
    text: diffs.join("／"),
  };
}
async function notifySlack(body: Record<string, unknown>) {
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const res = await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/notify-slack`, {
    method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}`, apikey: key }, body: JSON.stringify(body),
  });
  return await res.json().catch(() => null);
}
const WD = ["日", "月", "火", "水", "木", "金", "土"];
async function notifySmaregiChange(sb: any, ch: { labor_cost_daily_id: string; user_id: string; store_id: string; work_date: string; text: string; before: any; after: any }) {
  const { data: ins } = await sb.from("sf_attendance_smaregi_changes").insert({
    labor_cost_daily_id: ch.labor_cost_daily_id, user_id: ch.user_id, store_id: ch.store_id, work_date: ch.work_date,
    before: ch.before, after: ch.after, diff_text: ch.text,
  }).select("id").single();
  if (!ins?.id) return { ok: false, error: "insert failed" };
  const [{ data: u }, { data: st }] = await Promise.all([sb.from("users").select("name").eq("id", ch.user_id).maybeSingle(), sb.from("stores").select("name").eq("id", ch.store_id).maybeSingle()]);
  const [y, m, d] = ch.work_date.split("-").map(Number);
  const title = `${m}/${d}（${WD[new Date(Date.UTC(y, m - 1, d)).getUTCDay()]}）　${st?.name ?? ""}`;
  const nid = crypto.randomUUID();
  const r = await notifySlack({
    action: "send", notification_id: nid, channel_key: "kintai.check", event: "attendance_smaregi_change", source: "ef:smaregi-attendance-sync",
    text: `✏️ スマレジ側で直接修正 ${title} ${u?.name ?? ""} ${ch.text}`,
    blocks: [
      { type: "section", text: { type: "mrkdwn", text: `✏️ *スマレジ・タイムカード側で直接修正されました*\n${title}\n*${u?.name ?? ""}*\n${ch.text}\n管理システムには今朝の取込で反映済み。心当たりを確認してください` } },
      { type: "actions", block_id: "attendance_change", elements: [
        { type: "button", style: "primary", text: { type: "plain_text", text: "○ 確認した", emoji: true }, action_id: "attendance.change.ack", value: JSON.stringify({ change_id: ins.id, notification_id: nid }) },
      ] },
      { type: "context", elements: [{ type: "mrkdwn", text: `変更 \`${String(ins.id).slice(0, 8)}\`・勤怠の修正は Slack の「× 修正する」→ マスター承認の流れで行う約束です` }] },
    ],
    dedupe_key: `attendance_change:${ins.id}`, ref: { table: "sf_attendance_smaregi_changes", id: ins.id }, username: "勤怠確認", icon_emoji: ":pencil2:",
  });
  if (r?.ok && r.notification_id) await sb.from("sf_attendance_smaregi_changes").update({ notification_ids: [r.notification_id] }).eq("id", ins.id);
  return { ok: !!r?.ok, change_id: ins.id, error: r?.error };
}

// 休憩合計（分）。開始・終了がそろった休憩だけ数える（2026-11-07）
function breakMinutes(r: any): number | null {
  let total = 0, any = false;
  for (const [s, e] of [[r.breakStart1, r.breakEnd1], [r.breakStart2, r.breakEnd2]]) {
    if (!s || !e) continue;
    const m = (new Date(e).getTime() - new Date(s).getTime()) / 60000;
    if (Number.isFinite(m) && m > 0) { total += m; any = true; }
  }
  return any ? Math.round(total) : (r.breakStart1 || r.breakStart2 ? null : 0);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const sb = svc();
    let body: any = {};
    try { body = await req.json(); } catch { /* GET等ボディなし */ }

    // 認可: CEO/HQ/マスター/店長/チーム長のJWT、またはservice_roleキー直呼び（内部バッチ用）を許可
    // 2026-09-08追加: ユーザー指示「店長・チーム長もスマレジと同期の権限付与してください」に対応
    //   （nippoのシフト管理UI「実績・差異」タブのスマレジ最新取得ボタンを店長・チーム長にも開放）
    const authHeader = req.headers.get("Authorization") ?? "";
    const isServiceRole = authHeader.includes(Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? " ");
    if (!isServiceRole) {
      const uid = jwtUid(req);
      const { data: u } = await sb.from("users").select("role,is_master,is_active").eq("id", uid).maybeSingle();
      if (!u?.is_active || !(u.is_master || ["CEO", "HQ", "TENCHO", "TEAM"].includes(u.role))) {
        return json({ ok: false, error: "権限がありません（CEO/HQ/店長/チーム長/マスターのみ）" }, 403);
      }
    }

    // 対象期間: デフォルトは「昨日」（日次バッチ想定）
    // 2026-08-24修正: 旧実装には2つのバグが複合していた（D-3実装中に8/22・8/23の欠落で発覚）。
    //   ①new Date()がUTC基準のため、08:00 JST（=前日23:00 UTC）に実行されるcronでは
    //     「JSTの本当の昨日」ではなく2日前を指してしまう
    //   ②日付文字列(body.date_from等)からはnew Date("YYYY-MM-DD")で常に0時0分になるのに対し、
    //     デフォルトの「昨日」はnew Date()由来で時刻成分が残ったままだったため、下のフィルタ
    //     `d < dateFrom`（dは0時0分）が単一日指定時に常にtrueとなり、実際にはinserted:0のまま
    //     何日も自動同期が空振りし続けていた（実行ログの"inserted":0の連続で確認）
    // 対策: JST基準で計算した「昨日」を一度'YYYY-MM-DD'文字列にしてから、body.date_from等と
    //   同じnew Date(文字列)経路に通す（＝常に0時0分になる・時刻成分を持ち込まない）。
    const nowJst = new Date(Date.now() + 9 * 3600 * 1000);
    const yesterdayStr = new Date(nowJst.getTime() - 86400000).toISOString().slice(0, 10);
    const dateFrom = new Date(body.date_from || yesterdayStr);
    const dateTo = new Date(body.date_to || yesterdayStr);

    const monthsSeen = new Set<string>();
    let cur = new Date(dateFrom);
    const months: Array<{ y: number; m: number }> = [];
    while (cur <= dateTo) {
      const key = `${cur.getFullYear()}-${cur.getMonth() + 1}`;
      if (!monthsSeen.has(key)) { monthsSeen.add(key); months.push({ y: cur.getFullYear(), m: cur.getMonth() + 1 }); }
      cur = new Date(cur.getFullYear(), cur.getMonth() + 1, 1);
    }

    let inserted = 0, skipped = 0;
    const errors: string[] = [];
    const staffNotFound: string[] = []; // 2026-09-09追加: スマレジ側に存在しないstaff_id（本部・マスター等の疑似アカウントに多い）。毎回失敗するとわかっているためerrorCountには含めない
    // 2026-09-09追加: attendance_records（生ログ）は(user_id,work_date)にunique制約があり「1日1行」設計。
    //   一方labor_cost_dailyはsmaregi_shift_result_id単位で複数行保持できる設計（split shift対応）。
    //   従来はattendance_recordsもsmaregi_shift_result_id単位でupsertしていたため、1日に複数の
    //   シフト結果（ランチ→ディナー等の分割シフト）がある人で(user_id,work_date)の一意制約違反が
    //   多発していた（実行結果で306件反映／エラー43件のうち大半を占めていた）。
    //   対策: (user_id,work_date)ごとに、その日の最も早い出勤〜最も遅い退勤にまとめてから
    //   1日1行でupsertする（onConflictも(user_id,work_date)に変更）
    const attendanceByDay = new Map<string, { user_id: string; store_id: string; work_date: string; clock_in: string | null; clock_out: string | null }>();

    const contracts = await loadContracts(sb, body.contract_id ? String(body.contract_id) : undefined);
    if (!contracts.length) return json({ ok: false, error: "有効なスマレジ契約がありません（smaregi_contracts または環境変数）" }, 500);
    const byContract: any[] = [];
    let contractsFailed = 0;
    let totalStaff = 0;

    // 2026-11-07: 直接修正の検知用に、対象期間の取込済み行を先に読む（smaregi_shift_result_id → 行）

    const existing = new Map<string, any>();

    {

      const { data: ex } = await sb.from("labor_cost_daily")

        .select("id,smaregi_shift_result_id,user_id,store_id,work_date,clock_in,clock_out,break_start_1,break_end_1,break_start_2,break_end_2,break_minutes,manual_fixed_at")

        .gte("work_date", dateFrom.toISOString().slice(0, 10)).lte("work_date", dateTo.toISOString().slice(0, 10));

      for (const e of ex ?? []) if (e.smaregi_shift_result_id) existing.set(e.smaregi_shift_result_id, e);

    }

    const smaregiChanges: any[] = [];


    for (const c of contracts) {
    const tag = `…${c.contract_id.slice(-3)}`;
    const sum = { contract: tag, label: c.label, staff: 0, inserted: 0, errors: 0 };
    byContract.push(sum);
    let token: string, links: any[], storeMap: Record<string, string>;
    try {
      token = await getContractToken(c.contract_id, SCOPES);
      links = await loadLinks(sb, c.contract_id, dateFrom.toISOString().slice(0, 10), dateTo.toISOString().slice(0, 10));
      storeMap = await loadStoreMap(sb, c, dateTo.toISOString().slice(0, 10)); // 取込対象日で引く（運営変更の前後で店舗の対応が変わるため）
    } catch (e) { errors.push(`契約${tag}: ${String(e)}`); sum.errors++; contractsFailed++; continue; } // 契約単位で失敗を記録し他の契約は続行
    sum.staff = links.length; totalStaff += links.length;
    for (const p of links) {
      for (const { y, m } of months) {
        try {
          const recs = await fetchMonthResults(token, c.contract_id, p.smaregi_staff_id, y, m);
          for (const r of recs) {
            const d = new Date(r.date);
            if (d < dateFrom || d > dateTo) continue; // 月単位取得なので範囲外は捨てる
            const storeId = storeMap[r.storeIdSmaregi];
            if (!storeId) { errors.push(`store未対応: 契約${tag} smaregi_store_id=${r.storeIdSmaregi}`); sum.errors++; continue; }
            if (!r.shiftResultId) { skipped++; continue; }

            // attendance_records用に日別でまとめる（実際のupsertはループの外で1日1回だけ行う）
            const dayKey = `${p.user_id}|${r.date}`;
            const cur = attendanceByDay.get(dayKey);
            if (!cur) {
              attendanceByDay.set(dayKey, { user_id: p.user_id, store_id: storeId, work_date: r.date, clock_in: r.attendance, clock_out: r.leaving });
            } else {
              if (r.attendance && (!cur.clock_in || r.attendance < cur.clock_in)) cur.clock_in = r.attendance;
              if (r.leaving && (!cur.clock_out || r.leaving > cur.clock_out)) cur.clock_out = r.leaving;
            }

            // スマレジのシフト結果IDは契約ごとの採番（別契約で同じ番号がありうる）。既定の契約は従来どおり素のID、それ以外は契約IDを前置して衝突を防ぐ
            const shiftKey = c.is_default ? r.shiftResultId : `${c.contract_id}:${r.shiftResultId}`;
            const prev = existing.get(shiftKey);
            const chg = detectChange(prev, r, r.date);
            if (chg) smaregiChanges.push({ labor_cost_daily_id: prev.id, user_id: p.user_id, store_id: storeId, work_date: r.date, ...chg });
            // labor_cost_daily（集計・見積もり。computed_costの自前計算は次フェーズ）
            const { error: lcErr } = await sb.from("labor_cost_daily").upsert({
              user_id: p.user_id,
              store_id: storeId,
              work_date: r.date,
              clock_in: r.attendance,
              clock_out: r.leaving,
              worked_minutes: r.dutyMinute,
              tardy: r.tardy,
              early_leaving: r.earlyLeaving,
              smaregi_estimate_cost: r.personnelExpenses,
              smaregi_shift_result_id: shiftKey,
              smaregi_staff_id: p.smaregi_staff_id,
              source: "smaregi",
              break_start_1: r.breakStart1, break_end_1: r.breakEnd1, break_start_2: r.breakStart2, break_end_2: r.breakEnd2,
              break_minutes: breakMinutes(r),
              updated_at: new Date().toISOString(),
            }, { onConflict: "smaregi_shift_result_id" });
            if (lcErr) { errors.push(`labor_cost_daily upsert失敗 (${r.shiftResultId}): ${lcErr.message}`); continue; }

            inserted++; sum.inserted++;
          }
        } catch (e) {
          // 2026-09-09追加: スマレジ側にそもそも存在しないstaff_id（400 Bad Request「所属事業所が存在しません。ID: xxx」）は、
          //   何度実行しても必ず失敗する既知のパターンのため、errorsとは別集計にして毎回のノイズを減らす。
          // 注: スマレジのエラー文言(日本語)はres.text()の生JSON中で\uXXXXエスケープされたまま渡ってくるため、
          //   日本語文字列そのものでは一致判定できない。"Bad Request"・"ID:"はASCIIのまま含まれるためこちらで判定する
          const msg = String(e);
          if (msg.includes("400") && msg.includes("Bad Request") && msg.includes("ID:")) {
            staffNotFound.push(p.smaregi_staff_id);
          } else {
            errors.push(`staff ${p.smaregi_staff_id} ${y}-${m}: ${msg}`);
          }
        }
      }
    }

    } // for contracts

    // 2026-11-07: スマレジ側の直接修正を通知（同じ行の未確認の通知が既にあれば出さない）
    const changeResults: any[] = [];
    for (const ch of smaregiChanges) {
      try {
        const { data: dup } = await sb.from("sf_attendance_smaregi_changes").select("id").eq("labor_cost_daily_id", ch.labor_cost_daily_id).eq("status", "open").limit(1);
        if (dup?.length) { changeResults.push({ labor_cost_daily_id: ch.labor_cost_daily_id, skipped: "open" }); continue; }
        changeResults.push(await notifySmaregiChange(sb, ch));
      } catch (e) { changeResults.push({ labor_cost_daily_id: ch.labor_cost_daily_id, error: String(e).slice(0, 200) }); }
    }

    // attendance_records（生ログ）は1日1行にまとめてから書き込む
    for (const rec of attendanceByDay.values()) {
      const { error: arErr } = await sb.from("attendance_records").upsert({
        user_id: rec.user_id,
        store_id: rec.store_id,
        work_date: rec.work_date,
        clock_in: rec.clock_in,
        clock_out: rec.clock_out,
        source: "api",
      }, { onConflict: "user_id,work_date" });
      if (arErr) { errors.push(`attendance_records upsert失敗 (${rec.user_id} ${rec.work_date}): ${arErr.message}`); }
    }

    return json({
      ok: contractsFailed < contracts.length,
      contracts: byContract,
      dateFrom: dateFrom.toISOString().slice(0, 10),
      dateTo: dateTo.toISOString().slice(0, 10),
      staffCount: totalStaff,
      inserted,
      skipped,
      smaregiChangeCount: smaregiChanges.length,
      smaregiChanges: changeResults.slice(0, 20),
      staffNotFoundCount: staffNotFound.length,
      staffNotFound: [...new Set(staffNotFound)].slice(0, 10),
      errorCount: errors.length,
      errors: errors.slice(0, 20),
    });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
