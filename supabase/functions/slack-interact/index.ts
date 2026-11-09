// =============================================================
// slack-interact — Slack からのボタン押下・モーダル送信を受ける Edge Function（骨組み・2026-10-29）
// 状態: ★ 未デプロイ ★（設計: docs/設計書_Slack通知基盤_Phase1_2026-10-29.md §10）
// 2026-11-07: Claude セッションの判断依頼（decision.request.<選択肢key>）を追加。
// 2026-11-07: 勤怠確認ボタン（attendance.alert.confirm / .fix → モーダル attendance.fix.modal → マスター承認 attendance.fix.approve / .reject）を本実装。
//   承認後は EF smaregi-attendance-fix でスマレジの勤務実績にも書き戻す（EdgeRuntime.waitUntil で 3 秒制限の外）。
//   2026-11-07: モーダルに休憩1・2（開始/終了）と「休憩なし」チェックを追加。RPC sf_attendance_fix_request に休憩 4 引数。
//   フロー（ユーザー決定）: 店長が ○ or ×（修正時刻・理由）→ マスターの Slack へ承認依頼 → 承認で RPC が labor_cost_daily / attendance_records に反映。
//
// 鉄則（ユーザー確定・2026-10-29）: Slack から DB を直接更新しない。必ず
//   Slack interaction → この関数 → 署名検証 → 操作者の特定(user_slack) → 権限確認(既存RBAC)
//   → 既存の RPC / Edge Function（管理システムの正規の入口）→ DB 更新 → 監査ログ → 元メッセージ更新(notify-slack update)
// の順にする。この関数は「受付と振り分け」だけを持ち、業務ロジックを持たない。
//
// secrets: SLACK_SIGNING_SECRET（Slack App の Basic Information → Signing Secret）
//          NOTIFY_SLACK_SECRET（notify-slack の update を呼ぶ内部合言葉）
// デプロイ: supabase functions deploy slack-interact --no-verify-jwt --project-ref uuvsxzhpxtghojoubjcc
//   （Slack は JWT を付けないため、署名検証がこの関数の唯一の認証）
// =============================================================
import { createClient } from "npm:@supabase/supabase-js@2";
import { wageModal } from "../_shared/onboarding-blocks.ts";

const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const text = (s: string, status = 200) => new Response(s, { status, headers: { "Content-Type": "text/plain; charset=utf-8" } });
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json" } });

// ---- 1. 署名検証（v0 方式: HMAC-SHA256("v0:" + timestamp + ":" + rawBody)・5分以内・定数時間比較）----
async function verifySlackSignature(req: Request, rawBody: string): Promise<boolean> {
  const secret = Deno.env.get("SLACK_SIGNING_SECRET") ?? "";
  const ts = req.headers.get("x-slack-request-timestamp") ?? "";
  const sig = req.headers.get("x-slack-signature") ?? "";
  if (!secret || !ts || !sig) return false;
  if (Math.abs(Date.now() / 1000 - Number(ts)) > 60 * 5) return false; // リプレイ防止
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`v0:${ts}:${rawBody}`));
  const expected = "v0=" + [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("");
  if (expected.length !== sig.length) return false;
  let r = 0;
  for (let i = 0; i < expected.length; i++) r |= expected.charCodeAt(i) ^ sig.charCodeAt(i);
  return r === 0;
}

// ---- 2. 操作者の特定と権限（既存RBAC: users.role / sf_can_manage 等。ここでは判定の材料だけ集める）----
type Actor = { user_id: string; role: string; is_master: boolean; name: string };
async function resolveActor(sb: any, slackUserId: string): Promise<Actor | null> {
  const { data: link } = await sb.from("user_slack").select("user_id").eq("slack_user_id", slackUserId).maybeSingle();
  if (!link) return null;
  const { data: u } = await sb.from("users").select("id,role,is_master,name,is_active").eq("id", link.user_id).maybeSingle();
  if (!u?.is_active) return null;
  return { user_id: u.id, role: u.role, is_master: !!u.is_master, name: u.name };
}

// ---- 3. action_id / callback_id の規約: '<領域>.<対象>.<操作>'（設計書§10-3）----
//   attendance.alert.confirm   勤怠確認「○ 合っている」        → RPC sf_attendance_alert_confirm(p_alert_id, p_actor)
//   attendance.alert.fix       勤怠確認「× 修正する」          → モーダル attendance.fix.modal を開く（出勤・退勤 datetimepicker・理由）
//   attendance.fix.modal       修正モーダルの送信              → RPC sf_attendance_fix_request → マスターへ承認依頼 DM
//   attendance.alert.delete / attendance.delete.modal   「🗑 打刻を消す」→ 理由モーダル → RPC sf_attendance_delete_request → マスターへ承認依頼 DM（2026-11-08）
//                              承認は attendance.fix.approve と同じ RPC（request_kind=delete で管理システムの行を削除 → EF smaregi-attendance-fix が DELETE）
//   attendance.fix.approve / .reject   マスターの承認 / 却下   → RPC sf_attendance_fix_decide（承認で labor_cost_daily / attendance_records に反映）
//   attendance.change.ack      スマレジ側の直接修正の通知「○ 確認した」→ RPC sf_attendance_change_ack
//   attendance.request.approve / .reject   フォーム申請（勤怠追加・修正）の承認 / 却下 → RPC sf_attendance_request_decide → EF smaregi-attendance-fix(request_id)
//   invoice.approval.approve / .fix / .hold      （将来）
//   cash.diff.confirm / .fix                      （将来）
//   shift.missing.remind / .extend                （将来）
//   hqtask.item.done / .extend                    （将来）
//   decision.request.<選択肢key>  Claude セッションの判断依頼（2026-11-07）→ RPC decision_request_answer
//                                 value = {"request_id","notification_id","key"}。選択肢 key は ^[a-z0-9_]{1,32}$
//   hr.onboarding.wage / .wage.modal   入社登録（2026-11-09 Phase 1）: 親メッセージ「💴 賃金を設定」→ モーダル（時給/日給/月給・適用開始日・金額）
//                                 → RPC hr_save_wage(p_actor) → EF onboarding-notify op=wage_sync（smaregi-sync wage_push → wage_pull 照合 → スレッド＋親更新）
//   hr.onboarding.retry           失敗したスレッドの「🔁 もう一度反映」→ EF onboarding-notify op=wage_sync
//   hr.onboarding.refresh         「🔄 表示を更新」→ EF onboarding-notify op=refresh
//   hr.onboarding.link            URL ボタン（従業員ページ・本部タスク）の押下通知。何もしない
//                                 value = {"workflow_id","notification_id"}。権限: マスター / CEO / HQ（hrAllowed）
type Handler = (ctx: Ctx) => Promise<Response>;
type Ctx = { sb: any; payload: any; actor: Actor; notificationId: string | null; value: any };

const handlers: Record<string, Handler> = {
  // 勤怠確認「○ 合っている」。権限・状態は RPC 側。結果を店長向けメッセージ（複数可）に反映する。
  "attendance.alert.confirm": async ({ sb, actor, payload, value }) => {
    const ru: string | undefined = payload.response_url;
    const { data, error } = await sb.rpc("sf_attendance_alert_confirm", { p_alert_id: value?.alert_id, p_actor: actor.user_id, p_via: "slack" });
    if (error) return ephemeral(`記録できませんでした: ${error.message}`, ru);
    if (!data?.ok) return ephemeral(data?.message ?? "記録できませんでした", ru);
    // 2026-11-08: Slack は 3 秒以内の返事を要求（スマホは特に厳しく「なかなか接続できません」になる）→ メッセージ更新は返事の後で
    waitUntil(updateMany(data.notification_ids, `✅ 合っている（${actor.name}・${nowJst()}）\n${data.summary}`));
    return text("");
  },
  // 勤怠確認「🗑 打刻を消す」（2026-11-08）: 理由だけのモーダル → RPC sf_attendance_delete_request → マスターへ承認依頼
  "attendance.alert.delete": async ({ payload, value, notificationId }) => {
    return await openModal(payload.trigger_id, attendanceDeleteModal(value, notificationId));
  },
  "attendance.delete.modal": async ({ sb, actor, payload }) => {
    const meta = JSON.parse(payload.view?.private_metadata ?? "{}");
    const v = payload.view?.state?.values ?? {};
    const reason = (v.reason?.reason?.value ?? "").trim();
    if (!reason) return json({ response_action: "errors", errors: { reason: "削除の理由を入れてください" } });
    const { data, error } = await sb.rpc("sf_attendance_delete_request", { p_alert_id: meta.alert_id, p_actor: actor.user_id, p_reason: reason, p_via: "slack" });
    if (error) return json({ response_action: "errors", errors: { reason: error.message } });
    if (!data?.ok) return json({ response_action: "errors", errors: { reason: data?.message ?? "申請できませんでした" } });
    waitUntil((async () => {
      await updateMany(data.notification_ids, `🗑 打刻の削除を申請しました（${actor.name}・${nowJst()}）\n${data.summary}\n理由: ${data.reason}\n承認待ち（マスター）`);
      const ids: string[] = [];
      for (const ch of await masterChannels(sb)) {
        const nid = crypto.randomUUID();
        const val = JSON.stringify({ alert_id: data.alert_id, notification_id: nid });
        const r = await sendSlack({
          action: "send", notification_id: nid, channel_key: ch, event: "attendance_delete_request", source: "ef:slack-interact",
          text: `🗑 打刻削除の承認依頼 ${data.summary}`,
          blocks: [
            { type: "section", text: { type: "mrkdwn", text: `🗑 *打刻削除の承認依頼*\n${data.summary}\n申請: ${actor.name}\n*この日の勤務を取り消します（出勤していなかった等）*\n理由: ${data.reason}` } },
            { type: "actions", block_id: "attendance_fix", elements: [
              { type: "button", style: "danger", text: { type: "plain_text", text: "✅ 承認して削除", emoji: true }, action_id: "attendance.fix.approve", value: val },
              { type: "button", text: { type: "plain_text", text: "❌ 却下", emoji: true }, action_id: "attendance.fix.reject", value: val },
            ] },
            { type: "context", elements: [{ type: "mrkdwn", text: `確認 \`${String(data.alert_id).slice(0, 8)}\`・承認すると管理システムの勤怠実績を削除し、スマレジ・タイムカードの勤務実績も削除します` }] },
          ],
          dedupe_key: `attendance_delete:${data.alert_id}:${ch}:${nid.slice(0, 8)}`, ref: { table: "sf_attendance_alerts", id: data.alert_id }, username: "勤怠確認", icon_emoji: ":alarm_clock:",
        });
        if (r?.ok && r.notification_id) ids.push(r.notification_id);
      }
      if (ids.length) await sb.from("sf_attendance_alerts").update({ approval_notification_ids: ids, updated_at: new Date().toISOString() }).eq("id", data.alert_id);
    })());
    return json({ response_action: "clear" });
  },
  // 勤怠確認「× 修正する」。trigger_id は 3 秒で失効するため、モーダルを最初に開く
  "attendance.alert.fix": async ({ payload, value, notificationId }) => {
    return await openModal(payload.trigger_id, attendanceFixModal(value, notificationId));
  },
  // 修正モーダルの送信 → 修正申請（反映はしない）→ マスターへ承認依頼
  "attendance.fix.modal": async ({ sb, actor, payload }) => {
    const meta = JSON.parse(payload.view?.private_metadata ?? "{}");
    const v = payload.view?.state?.values ?? {};
    const start = v.start?.start?.selected_date_time, end = v.end?.end?.selected_date_time, reason = (v.reason?.reason?.value ?? "").trim();
    if (!start || !end || !reason) return json({ response_action: "errors", errors: { reason: "出勤・退勤・理由をすべて入れてください" } });
    // 休憩: 「休憩なし」にチェックがあれば全部 null。無ければ入力された休憩（datetimepicker は消せないため、消したいときはチェックで）
    const noBreak = (v.nobreak?.nobreak?.selected_options ?? []).length > 0;
    const pick = (b: string) => noBreak ? null : (v[b]?.[b]?.selected_date_time ? new Date(Number(v[b][b].selected_date_time) * 1000).toISOString() : null);
    const { data, error } = await sb.rpc("sf_attendance_fix_request", {
      p_alert_id: meta.alert_id, p_actor: actor.user_id,
      p_clock_in: new Date(Number(start) * 1000).toISOString(), p_clock_out: new Date(Number(end) * 1000).toISOString(),
      p_reason: reason, p_via: "slack",
      p_break_start_1: pick("b1s"), p_break_end_1: pick("b1e"), p_break_start_2: pick("b2s"), p_break_end_2: pick("b2e"),
    });
    if (error) return json({ response_action: "errors", errors: { reason: error.message } });
    if (!data?.ok) {
      const block = data?.code === "invalid_time" ? "end" : data?.code === "invalid_break" ? "b1e" : "reason";
      return json({ response_action: "errors", errors: { [block]: data?.message ?? "申請できませんでした" } });
    }
    // 2026-11-08: 申請は RPC で記録済み。Slack の 3 秒制限（スマホで「なかなか接続できません」）を避けるため、ここで先にモーダルを閉じて残りは後で行う
    waitUntil((async () => {
    await updateMany(data.notification_ids, `📝 修正を申請しました（${actor.name}・${nowJst()}）\n${data.summary}\n→ 修正後 ${data.proposed}　理由: ${data.reason}\n承認待ち（マスター）`);
    // マスターへ承認依頼（user_slack 紐付けのあるマスターの DM。居なければ hq.keiri_kanshi）
    const channels = await masterChannels(sb);
    const ids: string[] = [];
    for (const ch of channels) {
      const nid = crypto.randomUUID();
      const val = JSON.stringify({ alert_id: data.alert_id, notification_id: nid });
      const r = await sendSlack({
        action: "send", notification_id: nid, channel_key: ch, event: "attendance_fix_request", source: "ef:slack-interact",
        text: `🙋 勤怠修正の承認依頼 ${data.summary} → ${data.proposed}`,
        blocks: [
          { type: "section", text: { type: "mrkdwn", text: `🙋 *勤怠修正の承認依頼*\n${data.summary}\n申請: ${actor.name}\n*修正後: ${data.proposed}*\n理由: ${data.reason}` } },
          { type: "actions", block_id: "attendance_fix", elements: [
            { type: "button", style: "primary", text: { type: "plain_text", text: "✅ 承認", emoji: true }, action_id: "attendance.fix.approve", value: val },
            { type: "button", style: "danger", text: { type: "plain_text", text: "❌ 却下", emoji: true }, action_id: "attendance.fix.reject", value: val },
          ] },
          { type: "context", elements: [{ type: "mrkdwn", text: `確認 \`${String(data.alert_id).slice(0, 8)}\`・承認すると管理システムの勤怠実績に反映（スマレジ側の打刻は別途修正）` }] },
        ],
        dedupe_key: `attendance_fix:${data.alert_id}:${ch}:${nid.slice(0, 8)}`, // 2026-11-08: 同じアラートに 2 度目の申請が来たとき（テストの再利用など）に「重複」で送られない事故を防ぐ ref: { table: "sf_attendance_alerts", id: data.alert_id }, username: "勤怠確認", icon_emoji: ":alarm_clock:",
      });
      if (r?.ok && r.notification_id) ids.push(r.notification_id);
    }
    // 承認メッセージの台帳 id を控える（状態ではなく連絡の記録。状態遷移は RPC のみ）
    if (ids.length) await sb.from("sf_attendance_alerts").update({ approval_notification_ids: ids, updated_at: new Date().toISOString() }).eq("id", data.alert_id);
    })());
    return json({ response_action: "clear" });
  },
  // スマレジ側の直接修正の通知「○ 確認した」（2026-11-07）
  "attendance.change.ack": async ({ sb, actor, payload, value }) => {
    const ru: string | undefined = payload.response_url;
    const { data, error } = await sb.rpc("sf_attendance_change_ack", { p_change_id: value?.change_id, p_actor: actor.user_id, p_via: "slack" });
    if (error) return ephemeral(`記録できませんでした: ${error.message}`, ru);
    if (!data?.ok) return ephemeral(data?.message ?? "記録できませんでした", ru);
    waitUntil(updateMany(data.notification_ids, `✅ 確認済み（${actor.name}・${nowJst()}）\n✏️ スマレジ側で直接修正: ${data.summary}\n${data.diff_text}`));
    return text("");
  },
  // マスターの承認 / 却下
  "attendance.fix.approve": (ctx) => attendanceDecide(ctx, true),
  "attendance.fix.reject": (ctx) => attendanceDecide(ctx, false),
  // フォーム申請（勤怠追加・修正）の承認 / 却下（2026-11-07）
  "attendance.request.approve": (ctx) => requestDecide(ctx, true),
  "attendance.request.reject": (ctx) => requestDecide(ctx, false),
  // Claude セッションの判断依頼（2026-11-07）。action_id は 'decision.request.<選択肢key>' で前方一致（下の入口で振り分け）。
  // 権限・状態（先に誰かが答えた/期限切れ/取消）・選択肢の検査と更新は RPC 側。ここは結果をメッセージに反映するだけ。
  "decision.request.*": async ({ sb, actor, payload, value, notificationId }) => {
    const actionId: string = payload.actions?.[0]?.action_id ?? "";
    const key = actionId.slice("decision.request.".length);
    const requestId = value?.request_id;
    const ru: string | undefined = payload.response_url;
    if (!requestId || !/^[a-z0-9_]{1,32}$/.test(key)) return ephemeral("この判断依頼のボタンは読めませんでした", ru);
    const { data, error } = await sb.rpc("decision_request_answer", { p_request_id: requestId, p_answer: key, p_actor: actor.user_id, p_via: "slack" });
    if (error) return ephemeral(`記録できませんでした: ${error.message}`, ru);
    if (!data?.ok) return ephemeral(data?.message ?? "記録できませんでした", ru);
    const when = new Date().toLocaleString("ja-JP", { timeZone: "Asia/Tokyo", hour12: false });
    const done = `✅ ${actor.name} が「${data.label}」を選択しました（${when}）\n> ${String(data.question ?? "").replace(/\n/g, "\n> ")}`;
    waitUntil((async () => {
      await updateMessage(notificationId ?? data.notification_id ?? null, done);
      // リマインド（EF pending-reminders）で再送したコピーも「済」にする（2026-11-08）
      const { data: dr } = await sb.from("decision_requests").select("notification_id,reminder_notification_ids").eq("id", requestId).maybeSingle();
      await updateMany([dr?.notification_id, ...(dr?.reminder_notification_ids ?? [])].filter((x: unknown) => typeof x === "string" && x !== (notificationId ?? data.notification_id)), done);
    })());
    return text("");
  },

  // ---- 入社登録ワークフロー（2026-11-09 Phase 1）。業務ロジックは RPC（hr_save_wage / onboarding_*）と EF onboarding-notify 側。ここは受付と振り分けだけ ----
  "hr.onboarding.link": async () => text(""),
  "hr.onboarding.refresh": async ({ actor, payload, value }) => {
    if (!hrAllowed(actor)) return ephemeral("入社手続きの操作は本部・社長・マスターのみです", payload.response_url);
    if (!value?.workflow_id) return ephemeral("ワークフローの id が読めませんでした", payload.response_url);
    waitUntil(onboardingNotify({ op: "refresh", workflow_id: value.workflow_id }));
    return text("");
  },
  "hr.onboarding.wage": async ({ sb, actor, payload, value, notificationId }) => {
    const ru: string | undefined = payload.response_url;
    if (!hrAllowed(actor)) return ephemeral("賃金の設定は本部・社長・マスターのみです", ru);
    const wfId = value?.workflow_id;
    if (!wfId) return ephemeral("ワークフローの id が読めませんでした", ru);
    const { data: wf } = await sb.from("onboarding_workflow_v").select("id,user_id,user_name,hire_date,status").eq("id", wfId).maybeSingle();
    if (!wf?.user_id) return ephemeral("入社ワークフローが見つかりません", ru);
    if (wf.status === "cancelled") return ephemeral("この入社手続きは中止されています", ru);
    const contracts = await activeContracts(sb, wf.user_id);
    if (!contracts.length) return ephemeral("スマレジにまだ登録されていないため、賃金を反映できません。先に nippo の従業員ページからスマレジに登録してください。", ru);
    return await openModal(payload.trigger_id, wageModal({ workflow_id: wf.id, user_id: wf.user_id, notification_id: notificationId }, { name: wf.user_name ?? "", hire_date: wf.hire_date, contracts }));
  },
  "hr.onboarding.wage.modal": async ({ sb, actor, payload }) => {
    const meta = JSON.parse(payload.view?.private_metadata ?? "{}");
    const v = payload.view?.state?.values ?? {};
    const division = Number(v.division?.division?.selected_option?.value ?? "0");
    const date: string = v.date?.date?.selected_date ?? "";
    const wage = Number(v.wage?.wage?.value ?? "");
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) return json({ response_action: "errors", errors: { date: "適用開始日を選んでください" } });
    if (!Number.isInteger(wage) || wage <= 0) return json({ response_action: "errors", errors: { wage: "金額（円）を整数で入れてください" } });
    if (division === 2 && date.slice(8) !== "01") return json({ response_action: "errors", errors: { date: "月給の適用開始日は月初日（1日）にしてください" } });
    if (division === 0 && wage > 100000) return json({ response_action: "errors", errors: { wage: "時給が大きすぎます。月給は「月給」を選んでください" } });
    if (!meta.workflow_id || !meta.user_id) return json({ response_action: "errors", errors: { wage: "対象が読めませんでした。もう一度ボタンから開いてください" } });
    let contract: string | null = v.contract?.contract?.selected_option?.value ?? null;
    if (!contract) {
      const cs = await activeContracts(sb, meta.user_id);
      if (cs.length !== 1) return json({ response_action: "errors", errors: { wage: cs.length ? "スマレジの契約を選んでください" : "スマレジに登録されていません" } });
      contract = cs[0].contract_id;
    }
    // 保存は正規の RPC（権限・検証は RPC 側。日給(1) は 2026-11-09 から許可）。反映（数秒）はモーダルを閉じたあとに
    const { data, error } = await sb.rpc("hr_save_wage", { p_user: meta.user_id, p_contract: contract, p_division: division, p_store: null, p_wage: wage, p_holiday: null, p_date: date, p_actor: actor.user_id });
    if (error) return json({ response_action: "errors", errors: { wage: error.message } });
    if (!data?.ok) return json({ response_action: "errors", errors: { wage: "保存できませんでした" } });
    waitUntil(onboardingNotify({ op: "wage_sync", workflow_id: meta.workflow_id, actor_id: actor.user_id, contract_id: contract }));
    return json({ response_action: "clear" });
  },
  "hr.onboarding.retry": async ({ actor, payload, value }) => {
    if (!hrAllowed(actor)) return ephemeral("入社手続きの操作は本部・社長・マスターのみです", payload.response_url);
    if (!value?.workflow_id) return ephemeral("ワークフローの id が読めませんでした", payload.response_url);
    waitUntil(onboardingNotify({ op: "wage_sync", workflow_id: value.workflow_id, actor_id: actor.user_id }));
    return text("");
  },
};

// 入社手続き（人事）の操作権限: マスター / CEO / HQ（既存の hr_save_wage と同じ）
const hrAllowed = (a: Actor) => a.is_master || a.role === "CEO" || a.role === "HQ";
// その人の有効なスマレジ契約（employee_smaregi_links。主契約を先頭に）
async function activeContracts(sb: any, userId: string): Promise<{ contract_id: string; label: string; staff_id: string }[]> {
  const [{ data: links }, { data: cs }] = await Promise.all([
    sb.from("employee_smaregi_links").select("contract_id,smaregi_staff_id,is_primary").eq("user_id", userId).is("effective_to", null).order("is_primary", { ascending: false }),
    sb.from("smaregi_contracts").select("contract_id,label").eq("is_active", true),
  ]);
  const labels: Record<string, string> = {};
  for (const c of cs ?? []) labels[c.contract_id] = c.label ?? c.contract_id;
  return (links ?? []).filter((l: any) => labels[l.contract_id]).map((l: any) => ({ contract_id: l.contract_id, label: labels[l.contract_id], staff_id: String(l.smaregi_staff_id) }));
}
// EF onboarding-notify（親メッセージの更新・スレッド投稿・賃金のスマレジ反映と照合）を service_role で呼ぶ。失敗しても throw しない
async function onboardingNotify(body: Record<string, unknown>): Promise<any> {
  try {
    const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    const res = await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/onboarding-notify`, {
      method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}`, apikey: key }, body: JSON.stringify(body),
    });
    return await res.json().catch(() => ({ ok: false, error: `HTTP ${res.status}` }));
  } catch (e) { return { ok: false, error: String(e).slice(0, 200) }; }
}

// ---- 4. Slack 応答のヘルパー ----
// ボタン押下（block_actions）への HTTP 応答本文は Slack に無視されるため、response_url があればそこへ送る（本人だけに見える）。
function ephemeral(msg: string, responseUrl?: string) {
  if (responseUrl) {
    fetch(responseUrl, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ response_type: "ephemeral", replace_original: false, text: msg }) }).catch(() => {});
    return text("");
  }
  return json({ response_type: "ephemeral", replace_original: false, text: msg });
}
async function openModal(triggerId: string, view: unknown) {
  const token = Deno.env.get("SLACK_BOT_TOKEN"); // views.open は Bot Token が要る。secrets はプロジェクト共通なので notify-slack と同じ値が入る（2026-11-07 確認）
  await fetch("https://slack.com/api/views.open", {
    method: "POST", headers: { "Content-Type": "application/json; charset=utf-8", Authorization: `Bearer ${token}` },
    body: JSON.stringify({ trigger_id: triggerId, view }),
  });
  return text("");
}
async function updateMessage(notificationId: string | null, newText: string) {
  if (!notificationId) return;
  await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/notify-slack`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-notify-secret": Deno.env.get("NOTIFY_SLACK_SECRET") ?? "", apikey: Deno.env.get("SUPABASE_ANON_KEY") ?? "" },
    body: JSON.stringify({ action: "update", notification_id: notificationId, text: newText }),
  });
}
function attendanceDeleteModal(value: any, notificationId: string | null) {
  return {
    type: "modal", callback_id: "attendance.delete.modal",
    private_metadata: JSON.stringify({ alert_id: value?.alert_id, notification_id: notificationId }),
    title: { type: "plain_text", text: "打刻を消す" }, submit: { type: "plain_text", text: "承認を依頼" }, close: { type: "plain_text", text: "やめる" },
    blocks: [
      { type: "section", text: { type: "mrkdwn", text: `*${value?.title ?? ""}*\nこの日の勤務を取り消します（本人が出勤していなかった・誤って打刻した等）。理由を入れてください。マスターの承認後に管理システムとスマレジの勤務実績から削除されます。` } },
      { type: "input", block_id: "reason", label: { type: "plain_text", text: "削除の理由" }, element: { type: "plain_text_input", action_id: "reason", multiline: true, max_length: 300, placeholder: { type: "plain_text", text: "例: この日は出勤していない（別の人の打刻）" } } },
    ],
  };
}
function attendanceFixModal(value: any, notificationId: string | null) {
  const now = Math.floor(Date.now() / 1000);
  return {
    type: "modal", callback_id: "attendance.fix.modal",
    private_metadata: JSON.stringify({ alert_id: value?.alert_id, notification_id: notificationId }),
    title: { type: "plain_text", text: "勤怠の修正" }, submit: { type: "plain_text", text: "承認を依頼" }, close: { type: "plain_text", text: "やめる" },
    blocks: [
      { type: "section", text: { type: "mrkdwn", text: `*${value?.title ?? ""}*\n正しい出勤・退勤の日時と理由を入れてください。マスターの承認後に管理システムへ反映されます。` } },
      { type: "input", block_id: "start", label: { type: "plain_text", text: "正しい出勤（日時）" }, element: { type: "datetimepicker", action_id: "start", initial_date_time: Number(value?.in) || now } },
      { type: "input", block_id: "end", label: { type: "plain_text", text: "正しい退勤（日時）" }, element: { type: "datetimepicker", action_id: "end", initial_date_time: Number(value?.out) || now } },
      { type: "divider" },
      { type: "section", text: { type: "mrkdwn", text: "*休憩*（任意。入れた休憩がそのまま記録されます。休憩を無しにするときは下にチェック）" } },
      { type: "input", optional: true, block_id: "b1s", label: { type: "plain_text", text: "休憩1 開始" }, element: { type: "datetimepicker", action_id: "b1s", ...(value?.b1s ? { initial_date_time: Number(value.b1s) } : {}) } },
      { type: "input", optional: true, block_id: "b1e", label: { type: "plain_text", text: "休憩1 終了" }, element: { type: "datetimepicker", action_id: "b1e", ...(value?.b1e ? { initial_date_time: Number(value.b1e) } : {}) } },
      { type: "input", optional: true, block_id: "b2s", label: { type: "plain_text", text: "休憩2 開始" }, element: { type: "datetimepicker", action_id: "b2s", ...(value?.b2s ? { initial_date_time: Number(value.b2s) } : {}) } },
      { type: "input", optional: true, block_id: "b2e", label: { type: "plain_text", text: "休憩2 終了" }, element: { type: "datetimepicker", action_id: "b2e", ...(value?.b2e ? { initial_date_time: Number(value.b2e) } : {}) } },
      { type: "input", optional: true, block_id: "nobreak", label: { type: "plain_text", text: "休憩の扱い" }, element: { type: "checkboxes", action_id: "nobreak", options: [{ text: { type: "plain_text", text: "この勤務は休憩なしにする（上の休憩欄は無視）" }, value: "none" }] } },
      { type: "divider" },
      { type: "input", block_id: "reason", label: { type: "plain_text", text: "修正理由" }, element: { type: "plain_text_input", action_id: "reason", multiline: true, max_length: 300, placeholder: { type: "plain_text", text: "例: 退勤の打刻忘れ" } } },
    ],
  };
}
async function attendanceDecide({ sb, actor, payload, value }: Ctx, approve: boolean) {
  const ru: string | undefined = payload.response_url;
  const { data, error } = await sb.rpc("sf_attendance_fix_decide", { p_alert_id: value?.alert_id, p_actor: actor.user_id, p_approve: approve, p_note: null, p_via: "slack" });
  if (error) return ephemeral(`記録できませんでした: ${error.message}`, ru);
  if (!data?.ok) return ephemeral(data?.message ?? "記録できませんでした", ru);
  const when = nowJst();
  const isDel = data.request_kind === "delete";   // 2026-11-08 打刻削除
  if (!approve) {
    waitUntil((async () => {
      await updateMany(data.approval_notification_ids, `❌ 却下しました（${actor.name}・${when}）\n${data.summary}\n→ 申請 ${data.proposed}（理由: ${data.reason}）`);
      await updateMany(data.notification_ids, `❌ ${isDel ? "打刻削除の申請" : "修正申請"}は却下されました（${actor.name}・${when}）\n${data.summary}\n→ 申請 ${data.proposed}`);
    })());
    return text("");
  }
  if (isDel) {
    const headD = `✅ 承認しました（${actor.name}・${when}）\n${data.summary}\n→ 打刻削除（理由: ${data.reason}）\n管理システムの勤怠実績を削除済み。`;
    const headDM = `🗑 打刻の削除が承認され、管理システムの勤怠実績を削除しました（${when}）\n${data.summary}\n`;
    waitUntil((async () => {
      await updateMany(data.approval_notification_ids, headD + "スマレジの勤務実績を削除中…");
      await updateMany(data.notification_ids, headDM + "スマレジの勤務実績を削除中…");
      const r = await smaregiFix(data.alert_id);
      const tail = r.ok ? "✅ スマレジの勤務実績も削除済み" : `⚠️ スマレジ側の削除に失敗: ${r.error ?? "不明"}\nスマレジの管理画面から消してください（管理システム側は削除済み。消さないと翌朝の取込で戻ります）`;
      await updateMany(data.approval_notification_ids, headD + tail);
      await updateMany(data.notification_ids, headDM + tail);
    })());
    return text("");
  }
  // 承認: ハブは RPC で反映済み。スマレジへの書き戻し（EF smaregi-attendance-fix・数秒かかる）は Slack の 3 秒制限の外で行う
  const head = `✅ 承認しました（${actor.name}・${when}）\n${data.summary}\n→ 修正後 ${data.proposed}（理由: ${data.reason}）\n管理システムに反映済み。`;
  const headMgr = `✅ 修正が承認され、管理システムに反映されました（${when}）\n${data.summary}\n→ 修正後 ${data.proposed}\n`;
  const after = (async () => {
    await updateMany(data.approval_notification_ids, head + "スマレジへ反映中…");
    await updateMany(data.notification_ids, headMgr + "スマレジへ反映中…");
    const r = await smaregiFix(data.alert_id);
    const tail = r.ok ? "✅ スマレジの勤務実績にも反映済み" : `⚠️ スマレジへの反映に失敗: ${r.error ?? "不明"}\nスマレジの管理画面から直してください（管理システム側は反映済み・ロック中）`;
    await updateMany(data.approval_notification_ids, head + tail);
    await updateMany(data.notification_ids, headMgr + tail);
  })();
  waitUntil(after);
  return text("");
}
// フォーム申請の承認 / 却下。承認: RPC がハブに反映 → EF smaregi-attendance-fix（request_id）でスマレジへ（修正=PUT・追加=POST）
async function requestDecide({ sb, actor, payload, value }: Ctx, approve: boolean) {
  const ru: string | undefined = payload.response_url;
  const { data, error } = await sb.rpc("sf_attendance_request_decide", { p_request_id: value?.request_id, p_actor: actor.user_id, p_approve: approve, p_note: null, p_via: "slack" });
  if (error) return ephemeral(`記録できませんでした: ${error.message}`, ru);
  if (!data?.ok) return ephemeral(data?.message ?? "記録できませんでした", ru);
  const when = nowJst();
  const kindLabel = data.kind === "add" ? "勤怠追加" : "勤怠修正";
  if (!approve) {
    waitUntil((async () => {
      await updateMany(data.approval_notification_ids, `❌ 却下しました（${actor.name}・${when}）\n${data.summary}\n申請: ${data.requested_by_name}　理由: ${data.reason}`);
      await updateMany(data.notice_notification_ids, `❌ ${kindLabel}の申請は却下されました（${actor.name}・${when}）\n${data.summary}\n申請: ${data.requested_by_name}`);
    })());
    return text("");
  }
  const head = `✅ 承認しました（${actor.name}・${when}）\n${data.summary}\n申請: ${data.requested_by_name}　理由: ${data.reason}\n管理システムに反映済み。`;
  const headN = `✅ ${kindLabel}が承認され、管理システムに反映されました（${when}）\n${data.summary}\n申請: ${data.requested_by_name}\n`;
  const after = (async () => {
    await updateMany(data.approval_notification_ids, head + "スマレジへ反映中…");
    await updateMany(data.notice_notification_ids, headN + "スマレジへ反映中…");
    const r = await smaregiFix(data.request_id, "request_id");
    const tail = r.ok ? "✅ スマレジの勤務実績にも反映済み" : `⚠️ スマレジへの反映に失敗: ${r.error ?? "不明"}\nスマレジの管理画面から直してください（管理システム側は反映済み・ロック中）`;
    await updateMany(data.approval_notification_ids, head + tail);
    await updateMany(data.notice_notification_ids, headN + tail);
  })();
  waitUntil(after);
  return text("");
}
declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void } | undefined;
function waitUntil(p: Promise<unknown>) {
  try { if (typeof EdgeRuntime !== "undefined" && EdgeRuntime?.waitUntil) { EdgeRuntime.waitUntil(p); return; } } catch (_) { /* fallthrough */ }
  p.catch(() => {});
}
async function smaregiFix(id: string, field: "alert_id" | "request_id" = "alert_id"): Promise<{ ok: boolean; error?: string }> {
  try {
    const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    const res = await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/smaregi-attendance-fix`, {
      method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}`, apikey: key },
      body: JSON.stringify({ [field]: id }),
    });
    const j = await res.json().catch(() => null);
    return { ok: !!j?.ok, error: j?.error ?? (res.ok ? undefined : `HTTP ${res.status}`) };
  } catch (e) { return { ok: false, error: String(e).slice(0, 200) }; }
}
function nowJst() { return new Date().toLocaleString("ja-JP", { timeZone: "Asia/Tokyo", hour12: false }); }
async function updateMany(ids: unknown, newText: string) {
  const list = Array.isArray(ids) ? ids.filter((x) => typeof x === "string") as string[] : [];
  await Promise.all(list.map((id) => updateMessage(id, newText)));
}
async function sendSlack(body: Record<string, unknown>): Promise<any> {
  const res = await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/notify-slack`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-notify-secret": Deno.env.get("NOTIFY_SLACK_SECRET") ?? "", apikey: Deno.env.get("SUPABASE_ANON_KEY") ?? "" },
    body: JSON.stringify(body),
  });
  return await res.json();
}
// 承認者＝マスター（is_master）。Slack 紐付けのある人の DM へ。居なければ hq.keiri_kanshi
async function masterChannels(sb: any): Promise<string[]> {
  const { data: masters } = await sb.from("users").select("id").eq("is_master", true).eq("is_active", true);
  const ids = (masters ?? []).map((m: any) => m.id);
  if (!ids.length) return ["hq.keiri_kanshi"];
  const { data: linked } = await sb.from("user_slack").select("user_id").in("user_id", ids);
  const out = (linked ?? []).map((r: any) => `user:${r.user_id}`);
  return out.length ? out : ["hq.keiri_kanshi"];
}

// ---- 5. 入口 ----
Deno.serve(async (req) => {
  if (req.method !== "POST") return text("POSTのみ", 405);
  const raw = await req.text();
  if (!(await verifySlackSignature(req, raw))) return text("署名が一致しません", 401);

  // Slack は application/x-www-form-urlencoded の payload=<JSON> で送る
  const payload = JSON.parse(new URLSearchParams(raw).get("payload") ?? "{}");
  const sb = svc();
  const actor = await resolveActor(sb, payload.user?.id ?? "");
  if (!actor) return ephemeral("あなたの Slack アカウントは管理システムに紐付いていません。本部に連絡してください。", payload.response_url);

  let key = "", value: any = null;
  if (payload.type === "block_actions") {
    const a = payload.actions?.[0];
    key = a?.action_id ?? "";
    try { value = JSON.parse(a?.value ?? "null"); } catch { value = a?.value; }
  } else if (payload.type === "view_submission") {
    key = payload.view?.callback_id ?? "";
  } else {
    return text("");
  }
  const notificationId = value?.notification_id ?? (() => { try { return JSON.parse(payload.view?.private_metadata ?? "{}").notification_id ?? null; } catch { return null; } })();

  // 監査: 誰が・どのボタンを・どの通知で押したか（結果は各RPC側の監査ログに残る）
  await sb.from("notification_deliveries").update({
    action_state: { last_action: key, by: actor.user_id, at: new Date().toISOString() }, updated_at: new Date().toISOString(),
  }).eq("id", notificationId ?? "00000000-0000-0000-0000-000000000000");

  const h = handlers[key] ?? (key.startsWith("decision.request.") ? handlers["decision.request.*"] : key.startsWith("hr.onboarding.link") ? handlers["hr.onboarding.link"] : undefined);
  if (!h) return ephemeral(`この操作（${key}）はまだ対応していません`, payload.response_url);
  try {
    return await h({ sb, payload, actor, notificationId, value });
  } catch (e) {
    return ephemeral("処理に失敗しました: " + String(e).slice(0, 200), payload.response_url);
  }
});
