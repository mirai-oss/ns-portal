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
import { wageModal, commuteSettingModal, cancelModal, personContactModal, personContactTemplate, taxSettingModal, yen, commutePolicyModal } from "../_shared/onboarding-blocks.ts";

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
//   hr.onboarding.wage.confirm    適用開始日がスマレジ側の日付に変わった賃金（確認待ち 🙋）の「✅ この日付で確定」→ EF onboarding-notify op=wage_confirm
//   hr.onboarding.refresh         「🔄 表示を更新」→ EF onboarding-notify op=refresh
//   hr.onboarding.link            URL ボタン（従業員ページ・本部タスク）の押下通知。何もしない
//   hr.onboarding.contact / .contact.modal   「📨 本人へ連絡」→ 種類と文面のモーダル → EF onboarding-notify op=person_contact（2026-11-09。既定は送らず文面をスレッドに出すだけ）
//   hr.onboarding.account.check   「🔎 スマレジ照合」→ EF onboarding-notify op=account_check（GET で登録済みの項目を ✓）
//   hr.onboarding.commute.undo    自動承認の「↩️ 取り消して本部で確認」→ RPC onboarding_commute_decide(rejected) → op=commute_decided
//   hr.onboarding.tax / .tax.modal   「🧾 源泉所得税」（2026-11-09 Phase 6）→ スマレジと同じ 4 項目のモーダル → RPC onboarding_set_tax_setting → op=tax_setting_saved
//   hr.onboarding.yearend.sync / .dependents.sync   承認済みの年末調整／扶養家族を「スマレジに反映」→ RPC onboarding_enqueue_year_end / _dependents → スレッド
//   hr.onboarding.yearend.approve / .reject / .compare（dependents も同じ）  v2（2026-11-09）: 本部の承認（RPC onboarding_post_join_approve → 承認後に enqueue）／差し戻し（RPC onboarding_post_join_reject）／スマレジと比較（op=post_join_compare）
//   hr.onboarding.post_join.remind   「📨 フォームのお願い」→ op=person_contact kind=post_join_form（既定は文面だけ）
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
    // 契約が 1 つならここで決めて private_metadata に入れる（送信時に DB を引かない＝3 秒以内に返事するため）
    return await openModal(payload.trigger_id, wageModal({ workflow_id: wf.id, user_id: wf.user_id, notification_id: notificationId, contract_id: contracts.length === 1 ? contracts[0].contract_id : null }, { name: wf.user_name ?? "", hire_date: wf.hire_date, contracts }));
  },
  "hr.onboarding.wage.modal": async ({ sb, actor, payload }) => {
    const meta = JSON.parse(payload.view?.private_metadata ?? "{}");
    const v = payload.view?.state?.values ?? {};
    const division = Number(v.division?.division?.selected_option?.value ?? "0");
    const date: string = v.date?.date?.selected_date ?? "";
    const wage = Number(v.wage?.wage?.value ?? "");
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) return json({ response_action: "errors", errors: { date: "適用開始日を選んでください" } });
    if (!Number.isInteger(wage) || wage <= 0) return json({ response_action: "errors", errors: { wage: "金額（円）を整数で入れてください" } });
    if ((division === 2 || division === 1) && date.slice(8) !== "01") return json({ response_action: "errors", errors: { date: `${division === 2 ? "月給" : "日給"}の適用開始日は月初日（1日）にしてください（スマレジの仕様）` } });
    if (division === 0 && wage > 100000) return json({ response_action: "errors", errors: { wage: "時給が大きすぎます。月給は「月給」を選んでください" } });
    if (!meta.workflow_id || !meta.user_id) return json({ response_action: "errors", errors: { wage: "対象が読めませんでした。もう一度ボタンから開いてください" } });
    const contract: string | null = v.contract?.contract?.selected_option?.value ?? meta.contract_id ?? null;
    if (!contract) return json({ response_action: "errors", errors: { wage: "スマレジの契約を選んでください（登録されていない場合は先に nippo からスマレジ登録）" } });
    // 2026-11-09: 実機（スマホ）で「Slack になかなか接続できません」＝3 秒超。保存（RPC hr_save_wage・権限と検証は RPC 側）もスマレジ反映も返事の後ろ（EF onboarding-notify op=wage_save_sync）で行い、
    //   保存エラーはスレッドに ⚠️ で届く。ここでは形式チェックだけして先にモーダルを閉じる
    waitUntil(onboardingNotify({ op: "wage_save_sync", workflow_id: meta.workflow_id, actor_id: actor.user_id, contract_id: contract, division, wage, date }));
    return json({ response_action: "clear" });
  },
  // 救済処理で適用開始日がスマレジ側の日付に変わった賃金（確認待ち）を、人が確認して確定する（2026-11-09）
  "hr.onboarding.wage.confirm": async ({ actor, payload, value }) => {
    if (!hrAllowed(actor)) return ephemeral("入社手続きの操作は本部・社長・マスターのみです", payload.response_url);
    if (!value?.workflow_id) return ephemeral("ワークフローの id が読めませんでした", payload.response_url);
    waitUntil((async () => {
      const r = await onboardingNotify({ op: "wage_confirm", workflow_id: value.workflow_id, actor_id: actor.user_id });
      if (!r?.ok) ephemeral(`確定できませんでした: ${r?.error ?? "不明"}`, payload.response_url);
    })());
    return text("");
  },
  // ---- Phase 2: 交通費（2026-11-10）。判断は RPC onboarding_commute_decide、通知は onboarding-notify ----
  "hr.onboarding.commute.approve": (ctx) => commuteApprove(ctx, "claimed"),
  "hr.onboarding.commute.approve_computed": (ctx) => commuteApprove(ctx, "computed"),
  "hr.onboarding.commute.person": async ({ sb, actor, payload, value }) => {
    if (!hrAllowed(actor)) return ephemeral("入社手続きの操作は本部・社長・マスターのみです", payload.response_url);
    const wf = await wfRow(sb, value?.workflow_id); if (!wf) return ephemeral("ワークフローが見つかりません", payload.response_url);
    const { error } = await sb.rpc("onboarding_commute_decide", { p_user: wf.user_id, p_decision: "person_review", p_fare: null, p_note: null, p_actor: actor.user_id });
    if (error) return ephemeral(`記録できませんでした: ${error.message}`, payload.response_url);
    // 本人への確認文も続けて作る（person_notify_enabled=false のあいだはスレッドに文面を出すだけ。true なら Slack DM → LINE の順で送る）
    waitUntil((async () => {
      await onboardingNotify({ op: "commute_decided", workflow_id: wf.id, actor_id: actor.user_id, decision: "person_review" });
      await onboardingNotify({ op: "person_contact", workflow_id: wf.id, actor_id: actor.user_id, kind: "commute_question" });
    })());
    return text("");
  },
  // 自動承認の取り消し（2026-11-09）: 差し戻し扱いにして「本部の確認が必要」へ戻す（approved_fare は履歴として残る）
  "hr.onboarding.commute.undo": async ({ sb, actor, payload, value }) => {
    if (!hrAllowed(actor)) return ephemeral("入社手続きの操作は本部・社長・マスターのみです", payload.response_url);
    const wf = await wfRow(sb, value?.workflow_id); if (!wf) return ephemeral("ワークフローが見つかりません", payload.response_url);
    const note = "自動承認を取り消し（本部で確認）";
    const { error } = await sb.rpc("onboarding_commute_decide", { p_user: wf.user_id, p_decision: "rejected", p_fare: null, p_note: note, p_actor: actor.user_id });
    if (error) return ephemeral(`取り消せませんでした: ${error.message}`, payload.response_url);
    waitUntil(onboardingNotify({ op: "commute_decided", workflow_id: wf.id, actor_id: actor.user_id, decision: "rejected", note }));
    return text("");
  },
  // 本人へ連絡（2026-11-09）: 種類のひな型を入れたモーダル → op=person_contact
  "hr.onboarding.contact": async ({ sb, actor, payload, value, notificationId }) => {
    const ru: string | undefined = payload.response_url;
    if (!hrAllowed(actor)) return ephemeral("本人への連絡は本部・社長・マスターのみです", ru);
    const wf = await wfRow(sb, value?.workflow_id); if (!wf?.user_id) return ephemeral("ワークフローが見つかりません", ru);
    const [{ data: cm }, { data: us }, { data: u }, { data: st }, { data: items }] = await Promise.all([
      sb.from("employee_commute").select("claimed_oneway_fare,computed_oneway_fare,route_text,judgement").eq("user_id", wf.user_id).maybeSingle(),
      sb.from("user_slack").select("slack_user_id").eq("user_id", wf.user_id).maybeSingle(),
      sb.from("users").select("line_user_id").eq("id", wf.user_id).maybeSingle(),
      sb.from("app_settings").select("value").eq("key", "onboarding_alerts").maybeSingle(),
      sb.from("onboarding_items").select("item_key,state").eq("workflow_id", wf.id),
    ]);
    const kind = cm?.judgement === "person_review" ? "commute_question" : (items ?? []).some((i: any) => ["slack_link", "smaregi_account"].includes(i.item_key) && i.state !== "completed") ? "welcome" : "custom";
    const channels = [us?.slack_user_id ? "Slack" : null, u?.line_user_id ? "LINE" : null].filter(Boolean) as string[];
    const textBody = personContactTemplate(kind, { name: wf.user_name ?? "", claimed: cm?.claimed_oneway_fare ?? null, computed: cm?.computed_oneway_fare ?? null, route_text: cm?.route_text ?? null });
    return await openModal(payload.trigger_id, personContactModal({ workflow_id: wf.id, notification_id: notificationId }, { name: wf.user_name ?? "", kind, text: textBody, channels, live: st?.value?.person_notify_enabled === true }));
  },
  "hr.onboarding.contact.modal": async ({ actor, payload }) => {
    const meta = JSON.parse(payload.view?.private_metadata ?? "{}");
    const v = payload.view?.state?.values ?? {};
    const kind = v.kind?.kind?.selected_option?.value ?? "custom";
    const body = (v.text?.text?.value ?? "").trim();
    if (!body) return json({ response_action: "errors", errors: { text: "文面を入れてください" } });
    waitUntil(onboardingNotify({ op: "person_contact", workflow_id: meta.workflow_id, actor_id: actor.user_id, kind, text: body }));
    return json({ response_action: "clear" });
  },
  // ---- Phase 6（2026-11-09）: 源泉所得税（スマレジと同じ 4 項目）----
  "hr.onboarding.tax": async ({ sb, actor, payload, value, notificationId }) => {
    const ru: string | undefined = payload.response_url;
    if (!hrAllowed(actor)) return ephemeral("源泉所得税の設定は本部・社長・マスターのみです", ru);
    const wf = await wfRow(sb, value?.workflow_id); if (!wf?.user_id) return ephemeral("ワークフローが見つかりません", ru);
    const contracts = await activeContracts(sb, wf.user_id);
    if (!contracts.length) return ephemeral("スマレジにまだ登録されていないため、源泉所得税を設定できません。", ru);
    const [{ data: t }, { data: y }, { data: ds }] = await Promise.all([
      sb.from("employee_tax_settings").select("tax_category,application_ym,spouse_deduction_division,dependents_count").eq("user_id", wf.user_id).maybeSingle(),
      sb.from("employee_year_end").select("spouse_flag,estimate_income").eq("user_id", wf.user_id).maybeSingle(),
      sb.from("employee_dependents").select("relationship").eq("user_id", wf.user_id).eq("is_active", true),
    ]);
    const hire = String(wf.hire_date ?? new Date().toISOString().slice(0, 10)).slice(0, 7).replace("-", "/");
    const depCount = (ds ?? []).length;
    const spouseGuess = t?.spouse_deduction_division ?? (y?.spouse_flag ? 1 : 0);
    const note = y ? "本人提出の年末調整あり" : "本人提出の年末調整はまだありません（初期値は推定）";
    return await openModal(payload.trigger_id, taxSettingModal({ workflow_id: wf.id, notification_id: notificationId }, { name: wf.user_name ?? "", application_ym: String(t?.application_ym ?? "").replace("-", "/") || hire, tax_category: t?.tax_category === "otsu" ? "otsu" : "kou", spouse_division: Number(spouseGuess), dependents_count: t?.dependents_count ?? depCount, note }));
  },
  "hr.onboarding.tax.modal": async ({ sb, actor, payload }) => {
    const meta = JSON.parse(payload.view?.private_metadata ?? "{}");
    const v = payload.view?.state?.values ?? {};
    const ym = String(v.ym?.ym?.value ?? "").trim().replace("/", "-");
    const type = v.type?.type?.selected_option?.value ?? "kou";
    const spouse = Number(v.spouse?.spouse?.selected_option?.value ?? 0);
    const dep = Number(v.dep?.dep?.value ?? 0);
    if (!/^\d{4}-\d{2}$/.test(ym)) return json({ response_action: "errors", errors: { ym: "YYYY/MM の形で入れてください（例: 2026/11）" } });
    if (!Number.isInteger(dep) || dep < 0 || dep > 20) return json({ response_action: "errors", errors: { dep: "0〜20 の整数" } });
    waitUntil((async () => {
      const { data, error } = await sb.rpc("onboarding_set_tax_setting", { p_workflow: meta.workflow_id, p_application_ym: ym, p_tax_category: type, p_spouse_division: spouse, p_dependents_count: dep, p_actor: actor.user_id });
      if (error || !data?.ok) { await onboardingNotify({ op: "thread", workflow_id: meta.workflow_id, text: `⚠️ 源泉所得税の設定を記録できませんでした（${actor.name}）: ${error?.message ?? "不明"}`, event: "onboarding_tax_failed" }); return; }
      await onboardingNotify({ op: "tax_setting_saved", workflow_id: meta.workflow_id, actor_id: actor.user_id });
    })());
    return json({ response_action: "clear" });
  },
  "hr.onboarding.yearend.sync": async ({ sb, actor, payload, value }) => {
    if (!hrAllowed(actor)) return ephemeral("入社手続きの操作は本部・社長・マスターのみです", payload.response_url);
    if (!value?.workflow_id) return ephemeral("ワークフローの id が読めませんでした", payload.response_url);
    const { data, error } = await sb.rpc("onboarding_enqueue_year_end", { p_workflow: value.workflow_id, p_actor: actor.user_id });
    if (error) return ephemeral(`登録できませんでした: ${error.message}`, payload.response_url);
    if (!data?.ok) return ephemeral(data?.error ?? "登録できませんでした", payload.response_url);
    const j = data.job ?? {};
    waitUntil(onboardingNotify({ op: "thread", workflow_id: value.workflow_id, text: j.ok ? `🧾 年末調整をスマレジに反映します（${actor.name}・${nowJst()}）。結果はこのスレッドに届きます${j.duplicate ? "（既に待機中のジョブがあります）" : ""}` : `🙋 年末調整: 自動反映は未有効化です（${actor.name}）。スマレジ管理画面「年末調整 → 設定を編集」に nippo の従業員編集の内容を入力してください`, event: "onboarding_year_end_sync" }));
    return text("");
  },
  "hr.onboarding.dependents.sync": async ({ sb, actor, payload, value }) => {
    if (!hrAllowed(actor)) return ephemeral("入社手続きの操作は本部・社長・マスターのみです", payload.response_url);
    if (!value?.workflow_id) return ephemeral("ワークフローの id が読めませんでした", payload.response_url);
    const { data, error } = await sb.rpc("onboarding_enqueue_dependents", { p_workflow: value.workflow_id, p_actor: actor.user_id });
    if (error) return ephemeral(`登録できませんでした: ${error.message}`, payload.response_url);
    if (!data?.ok) return ephemeral(data?.error ?? "登録できませんでした", payload.response_url);
    const j = data.job ?? {};
    waitUntil(onboardingNotify({ op: "thread", workflow_id: value.workflow_id, text: j.ok ? `👪 扶養家族 ${data.count} 人をスマレジに反映します（${actor.name}・${nowJst()}）。結果はこのスレッドに届きます${j.duplicate ? "（既に待機中のジョブがあります）" : ""}` : `🙋 扶養家族: 自動反映は未有効化です（${actor.name}）。スマレジ管理画面「扶養設定 → 設定を編集 → 扶養親族を追加」に nippo の従業員編集の内容を入力してください（マイナンバーは本人画面）`, event: "onboarding_dependents_sync" }));
    return text("");
  },
  // ---- Phase 6 v2: 承認／差し戻し／比較（本部のみ）。承認後にだけスマレジへ ----
  "hr.onboarding.yearend.approve": (ctx) => postJoinDecide(ctx, "year_end", "approved"),
  "hr.onboarding.dependents.approve": (ctx) => postJoinDecide(ctx, "dependents", "approved"),
  "hr.onboarding.yearend.reject": (ctx) => postJoinDecide(ctx, "year_end", "rejected"),
  "hr.onboarding.dependents.reject": (ctx) => postJoinDecide(ctx, "dependents", "rejected"),
  "hr.onboarding.yearend.compare": async ({ actor, payload, value }) => {
    if (!hrAllowed(actor)) return ephemeral("入社手続きの操作は本部・社長・マスターのみです", payload.response_url);
    if (!value?.workflow_id) return ephemeral("ワークフローの id が読めませんでした", payload.response_url);
    waitUntil(onboardingNotify({ op: "post_join_compare", workflow_id: value.workflow_id, track: "year_end", target_year: value.target_year ?? null, actor_id: actor.user_id }));
    return text("");
  },
  "hr.onboarding.dependents.compare": async ({ actor, payload, value }) => {
    if (!hrAllowed(actor)) return ephemeral("入社手続きの操作は本部・社長・マスターのみです", payload.response_url);
    if (!value?.workflow_id) return ephemeral("ワークフローの id が読めませんでした", payload.response_url);
    waitUntil(onboardingNotify({ op: "post_join_compare", workflow_id: value.workflow_id, track: "dependents", actor_id: actor.user_id }));
    return text("");
  },
  "hr.onboarding.post_join.remind": async ({ actor, payload, value }) => {
    if (!hrAllowed(actor)) return ephemeral("入社手続きの操作は本部・社長・マスターのみです", payload.response_url);
    if (!value?.workflow_id) return ephemeral("ワークフローの id が読めませんでした", payload.response_url);
    waitUntil(onboardingNotify({ op: "person_contact", workflow_id: value.workflow_id, actor_id: actor.user_id, kind: "post_join_form" }));
    return text("");
  },
  // スマレジ照合（2026-11-09）: GET で登録済みの項目を ✓（本人アカウントは UI 読み取りへ）
  "hr.onboarding.account.check": async ({ actor, payload, value }) => {
    if (!hrAllowed(actor)) return ephemeral("入社手続きの操作は本部・社長・マスターのみです", payload.response_url);
    if (!value?.workflow_id) return ephemeral("ワークフローの id が読めませんでした", payload.response_url);
    waitUntil(onboardingNotify({ op: "account_check", workflow_id: value.workflow_id, actor_id: actor.user_id }));
    return text("");
  },
  "hr.onboarding.commute.research": async ({ actor, payload, value }) => {
    if (!hrAllowed(actor)) return ephemeral("入社手続きの操作は本部・社長・マスターのみです", payload.response_url);
    if (!value?.workflow_id) return ephemeral("ワークフローの id が読めませんでした", payload.response_url);
    waitUntil(onboardingNotify({ op: "commute_check", workflow_id: value.workflow_id }));
    return text("");
  },
  "hr.onboarding.commute.set": async ({ sb, actor, payload, value, notificationId }) => {
    const ru: string | undefined = payload.response_url;
    if (!hrAllowed(actor)) return ephemeral("交通費の設定は本部・社長・マスターのみです", ru);
    const wf = await wfRow(sb, value?.workflow_id); if (!wf?.user_id) return ephemeral("ワークフローが見つかりません", ru);
    const contracts = await activeContracts(sb, wf.user_id);
    if (!contracts.length) return ephemeral("スマレジにまだ登録されていないため、交通費を設定できません。", ru);
    const [{ data: cm }, { data: rules }, { data: us }] = await Promise.all([
      sb.from("employee_commute").select("approved_fare,judgement,search_result").eq("user_id", wf.user_id).maybeSingle(),
      sb.from("app_settings").select("value").eq("key", "commute_rules").maybeSingle(),
      sb.from("user_stores").select("stores(id,name)").eq("user_id", wf.user_id),
    ]);
    const stores = (us ?? []).map((x: any) => x.stores).filter(Boolean);
    const capDefault = wf.role === "AL" ? Number(rules?.value?.al_cap_yen ?? 6000) : null;
    return await openModal(payload.trigger_id, commuteSettingModal({ workflow_id: wf.id, user_id: wf.user_id, notification_id: notificationId, contract_id: contracts[0].contract_id },
      { name: wf.user_name ?? "", hire_date: wf.hire_date, approved_fare: cm?.approved_fare ?? null, stores, cap_default: capDefault, cap_unit: String(rules?.value?.cap_unit ?? "unknown"), plan: (cm as any)?.search_result?.pay_plan ?? null }));
  },
  // 支給方法（個別設定・2026-11-10 会社ルール）: 1 日上限（基本）／定期代支給／全額支給・出勤日数の見込み・バス例外 → RPC onboarding_set_commute_policy → 再検索
  "hr.onboarding.commute.policy": async ({ sb, actor, payload, value, notificationId }) => {
    const ru: string | undefined = payload.response_url;
    if (!hrAllowed(actor)) return ephemeral("支給方法の変更は本部・社長・マスターのみです", ru);
    const wf = await wfRow(sb, value?.workflow_id); if (!wf?.user_id) return ephemeral("ワークフローが見つかりません", ru);
    const [{ data: cm }, { data: rules }] = await Promise.all([
      sb.from("employee_commute").select("*").eq("user_id", wf.user_id).maybeSingle(),
      sb.from("app_settings").select("value").eq("key", "commute_rules").maybeSingle(),
    ]);
    return await openModal(payload.trigger_id, commutePolicyModal({ workflow_id: wf.id, user_id: wf.user_id, notification_id: notificationId },
      { name: wf.user_name ?? "", policy: String((cm as any)?.pay_policy ?? "daily_cap"), bus_exception: (cm as any)?.bus_exception === true, cap: Number(rules?.value?.daily_cap_round_yen ?? 500), plan_text: (cm as any)?.search_result?.pay_plan?.text ?? null,
        bus_request: (cm as any)?.uses_bus ? String((cm as any)?.special_note ?? "（理由の記入なし）") : null }));
  },
  "hr.onboarding.commute.policy.modal": async ({ sb, actor, payload }) => {
    const meta = JSON.parse(payload.view?.private_metadata ?? "{}");
    const v = payload.view?.state?.values ?? {};
    const policy = v.policy?.policy?.selected_option?.value ?? "daily_cap";
    const bus = (v.bus?.bus?.selected_options ?? []).length > 0;
    const reason = (v.reason?.reason?.value ?? "").trim() || null;
    if ((policy !== "daily_cap" || bus) && !reason) return json({ response_action: "errors", errors: { reason: "基本ルールと違う扱いにするときは理由を入れてください" } });
    waitUntil((async () => {
      const { error } = await sb.rpc("onboarding_set_commute_policy", { p_user: meta.user_id, p_policy: policy, p_bus_exception: bus, p_reason: reason, p_actor: actor.user_id });
      if (error) { await onboardingNotify({ op: "thread", workflow_id: meta.workflow_id, text: `⚠️ 支給方法を保存できませんでした（${actor.name}）: ${error.message}`, event: "onboarding_commute_policy_failed" }); return; }
      const label = ({ daily_cap: "基本（1 日上限）", teiki: "定期代支給（本部承認）", full: "全額支給（本部承認）" } as Record<string, string>)[policy] ?? policy;
      await onboardingNotify({ op: "thread", workflow_id: meta.workflow_id, text: `⚙️ 交通費の支給方法を「${label}」にしました（${actor.name}・${nowJst()}）${bus ? "／バス例外を承認" : ""}${reason ? `\n理由: ${reason}` : ""}\n経路を再検索して支給額を計算し直します`, event: "onboarding_commute_policy" });
      await onboardingNotify({ op: "commute_check", workflow_id: meta.workflow_id });
    })());
    return json({ response_action: "clear" });
  },
  "hr.onboarding.commute.set.modal": async ({ sb, actor, payload }) => {
    const meta = JSON.parse(payload.view?.private_metadata ?? "{}");
    const v = payload.view?.state?.values ?? {};
    const payType = v.pay_type?.pay_type?.selected_option?.value ?? "per_shift";
    const date: string = v.date?.date?.selected_date ?? "";
    const scopeV: string = v.scope?.scope?.selected_option?.value ?? "all";
    const amount = Number(v.amount?.amount?.value ?? "");
    const capRaw = v.cap?.cap?.value; const cap = capRaw === undefined || capRaw === null || capRaw === "" ? null : Number(capRaw);
    const note = (v.note?.note?.value ?? "").trim() || null;
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) return json({ response_action: "errors", errors: { date: "適用開始日を選んでください" } });
    if (!Number.isInteger(amount) || amount < 0) return json({ response_action: "errors", errors: { amount: "金額（円）を整数で入れてください" } });
    if (cap !== null && (!Number.isInteger(cap) || cap < 0)) return json({ response_action: "errors", errors: { cap: "上限は整数で" } });
    const scope = scopeV.startsWith("store:") ? "per_store" : "all";
    const storeAmounts = scope === "per_store" ? { [scopeV.slice(6)]: amount } : null;
    // 3 秒制限: 保存（RPC）とスレッド通知は返事の後ろ
    waitUntil((async () => {
      const { data, error } = await sb.rpc("onboarding_set_commute_setting", { p_workflow: meta.workflow_id, p_contract: meta.contract_id, p_pay_type: payType, p_effective_date: date, p_scope: scope, p_amount: scope === "all" ? amount : null, p_store_amounts: storeAmounts, p_cap_amount: cap, p_cap_unit: null, p_note: note, p_actor: actor.user_id });
      if (error || !data?.ok) { await onboardingNotify({ op: "thread", workflow_id: meta.workflow_id, text: `⚠️ 交通費の設定を保存できませんでした（${actor.name}）: ${error?.message ?? "不明"}`, event: "onboarding_commute_setting_failed" }); return; }
      await onboardingNotify({ op: "commute_setting_saved", workflow_id: meta.workflow_id, setting_id: data.setting_id, actor_id: actor.user_id, duplicate: !!data.job?.duplicate });
    })());
    return json({ response_action: "clear" });
  },
  // ---- Phase 3: UI ジョブの再実行（失敗・打ち切りのあと）----
  "hr.onboarding.ui.retry": async ({ sb, actor, payload, value }) => {
    if (!hrAllowed(actor)) return ephemeral("入社手続きの操作は本部・社長・マスターのみです", payload.response_url);
    if (!value?.workflow_id || !value?.job_id) return ephemeral("ジョブの id が読めませんでした", payload.response_url);
    const { data: old } = await sb.from("ui_automation_jobs").select("kind,payload").eq("id", value.job_id).maybeSingle();
    if (!old) return ephemeral("元のジョブが見つかりません", payload.response_url);
    const { data, error } = await sb.rpc("ui_job_enqueue", { p_workflow: value.workflow_id, p_kind: old.kind, p_payload: old.payload, p_actor: actor.user_id, p_dry_run: false });
    if (error) return ephemeral(`再実行を登録できませんでした: ${error.message}`, payload.response_url);
    if (!data?.ok) return ephemeral(data?.error ?? "再実行を登録できませんでした（自動書き込みが未有効化の可能性）", payload.response_url);
    waitUntil(onboardingNotify({ op: "thread", workflow_id: value.workflow_id, text: `🔁 ${old.kind} の自動設定を再実行します（${actor.name}・${nowJst()}）${data?.duplicate ? "（既に待機中のジョブがあります）" : ""}`, event: "onboarding_ui_retry" }));
    return text("");
  },
  // ---- Phase 4: 入社手続きの中止 ----
  "hr.onboarding.cancel": async ({ sb, actor, payload, value, notificationId }) => {
    if (!hrAllowed(actor)) return ephemeral("入社手続きの中止は本部・社長・マスターのみです", payload.response_url);
    const wf = await wfRow(sb, value?.workflow_id); if (!wf) return ephemeral("ワークフローが見つかりません", payload.response_url);
    return await openModal(payload.trigger_id, cancelModal({ workflow_id: wf.id, notification_id: notificationId }, wf.user_name ?? ""));
  },
  "hr.onboarding.cancel.modal": async ({ sb, actor, payload }) => {
    const meta = JSON.parse(payload.view?.private_metadata ?? "{}");
    const v = payload.view?.state?.values ?? {};
    const reason = v.reason?.reason?.selected_option?.value ?? "";
    const note = (v.note?.note?.value ?? "").trim() || null;
    if (!reason) return json({ response_action: "errors", errors: { reason: "理由を選んでください" } });
    waitUntil((async () => {
      const { error } = await sb.rpc("onboarding_cancel", { p_workflow: meta.workflow_id, p_reason: reason, p_note: note, p_actor: actor.user_id });
      if (error) { await onboardingNotify({ op: "thread", workflow_id: meta.workflow_id, text: `⚠️ 中止を記録できませんでした（${actor.name}）: ${error.message}`, event: "onboarding_cancel_failed" }); return; }
      await onboardingNotify({ op: "cancelled", workflow_id: meta.workflow_id, actor_id: actor.user_id, reason, note });
    })());
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
async function wfRow(sb: any, wfId: unknown): Promise<any | null> {
  if (typeof wfId !== "string" || !/^[0-9a-f-]{36}$/i.test(wfId)) return null;
  const { data } = await sb.from("onboarding_workflow_v").select("id,user_id,user_name,hire_date,status,role,contract_id").eq("id", wfId).maybeSingle();
  return data ?? null;
}
// 交通費の承認: mode=claimed（申請額）/ computed（検索の最安）。金額は employee_commute から読む（ボタンの value に金額を載せない＝改ざん防止）
async function commuteApprove({ sb, actor, payload, value }: Ctx, mode: "claimed" | "computed") {
  const ru: string | undefined = payload.response_url;
  if (!hrAllowed(actor)) return ephemeral("交通費の承認は本部・社長・マスターのみです", ru);
  const wf = await wfRow(sb, value?.workflow_id); if (!wf?.user_id) return ephemeral("ワークフローが見つかりません", ru);
  const { data: cm } = await sb.from("employee_commute").select("claimed_oneway_fare,computed_oneway_fare,judgement").eq("user_id", wf.user_id).maybeSingle();
  const fare = mode === "claimed" ? cm?.claimed_oneway_fare : cm?.computed_oneway_fare;
  if (fare === null || fare === undefined) return ephemeral(mode === "claimed" ? "本人の申請額がありません。nippo の従業員ページで片道額を入れてから承認してください" : "検索の最安額がありません（再検索してください）", ru);
  const { data, error } = await sb.rpc("onboarding_commute_decide", { p_user: wf.user_id, p_decision: "approved", p_fare: fare, p_note: mode === "computed" ? "検索の最安額で承認" : "申請額で承認", p_actor: actor.user_id });
  if (error) return ephemeral(`記録できませんでした: ${error.message}`, ru);
  if (!data?.ok) return ephemeral("記録できませんでした", ru);
  waitUntil(onboardingNotify({ op: "commute_decided", workflow_id: wf.id, actor_id: actor.user_id, decision: "approved", fare, note: mode === "computed" ? "検索の最安額で承認" : null }));
  return text("");
}
// 入社後フォーム（年末調整・扶養）の承認／差し戻し。承認は RPC onboarding_post_join_approve → 承認できたら enqueue（スイッチ OFF なら manual）→ op=post_join_decided
async function postJoinDecide({ sb, actor, payload, value }: Ctx, track: "year_end" | "dependents", decision: "approved" | "rejected") {
  const ru: string | undefined = payload.response_url;
  if (!hrAllowed(actor)) return ephemeral("承認・差し戻しは本部・社長・マスターのみです", ru);
  const wf = await wfRow(sb, value?.workflow_id); if (!wf?.user_id) return ephemeral("ワークフローが見つかりません", ru);
  const year = track === "year_end" ? (Number.isInteger(value?.target_year) ? value.target_year : null) : 0;
  const fn = decision === "approved" ? "onboarding_post_join_approve" : "onboarding_post_join_reject";
  const { data, error } = await sb.rpc(fn, { p_user: wf.user_id, p_track: track, p_year: year, p_actor: actor.user_id, p_note: null });
  if (error) return ephemeral(`記録できませんでした: ${error.message}`, ru);
  if (!data?.ok) return ephemeral(data?.error ?? "記録できませんでした", ru);
  waitUntil((async () => {
    let job: any = undefined;
    if (decision === "approved") {
      if (data.can_enqueue === false) job = null;
      else { const { data: eq, error: ee } = await sb.rpc(track === "year_end" ? "onboarding_enqueue_year_end" : "onboarding_enqueue_dependents", track === "year_end" ? { p_workflow: wf.id, p_actor: actor.user_id, p_year: data.target_year ?? null } : { p_workflow: wf.id, p_actor: actor.user_id }); job = ee ? { ok: false, error: ee.message } : (eq?.ok ? eq.job : { ok: false, error: eq?.error }); }
    }
    await onboardingNotify({ op: "post_join_decided", workflow_id: wf.id, track, target_year: data.target_year ?? null, decision, actor_id: actor.user_id, job });
  })());
  return text("");
}
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
