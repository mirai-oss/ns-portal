// =============================================================
// slack-interact — Slack からのボタン押下・モーダル送信を受ける Edge Function（骨組み・2026-10-29）
// 状態: ★ 未デプロイ ★（Phase 3 で実装完了。設計: docs/設計書_Slack通知基盤_Phase1_2026-10-29.md §10）
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
//   attendance.alert.confirm   勤怠アラート「合っている」      → RPC sf_attendance_alert_confirm(p_alert_id)
//   attendance.alert.fix       勤怠アラート「修正する」        → モーダル attendance.fix.modal を開く
//   attendance.alert.open      「詳細を見る」(URLボタン・サーバー処理なし)
//   attendance.fix.modal       修正モーダルの送信              → 既存の勤怠修正RPC/EF → スマレジ同期 → 監査ログ → メッセージ更新
//   invoice.approval.approve / .fix / .hold      （将来）
//   cash.diff.confirm / .fix                      （将来）
//   shift.missing.remind / .extend                （将来）
//   hqtask.item.done / .extend                    （将来）
type Handler = (ctx: Ctx) => Promise<Response>;
type Ctx = { sb: any; payload: any; actor: Actor; notificationId: string | null; value: any };

const handlers: Record<string, Handler> = {
  // 例: 勤怠アラート「合っている」。ここで DB を直接 update しない。RPC が権限確認と監査ログまで行う。
  "attendance.alert.confirm": async ({ sb, actor, value, notificationId }) => {
    const { error } = await sb.rpc("sf_attendance_alert_confirm", { p_alert_id: value?.alert_id, p_actor: actor.user_id, p_via: "slack" });
    if (error) return ephemeral(`確認できませんでした: ${error.message}`);
    await updateMessage(notificationId, `✅ 確認済み（${actor.name}）`);
    return text("");
  },
  "attendance.alert.fix": async ({ payload, value, notificationId }) => {
    // trigger_id は 3 秒で失効するため、モーダルは最初に開く
    return await openModal(payload.trigger_id, attendanceFixModal(value, notificationId));
  },
  "attendance.fix.modal": async ({ sb, actor, payload, notificationId }) => {
    const meta = JSON.parse(payload.view?.private_metadata ?? "{}");
    const v = payload.view?.state?.values ?? {};
    const start = v.start?.start?.selected_time, end = v.end?.end?.selected_time, reason = v.reason?.reason?.value;
    if (!start || !end || !reason) return json({ response_action: "errors", errors: { reason: "出勤・退勤・理由をすべて入れてください" } });
    // 既存の勤怠修正入口（本人=申請のみ／店長・本部=修正）。RPC 名は Phase 3 着手時に確定（設計書§10-5）
    const { data, error } = await sb.rpc("sf_attendance_fix_from_slack", {
      p_alert_id: meta.alert_id, p_actor: actor.user_id, p_start: start, p_end: end, p_reason: reason,
    });
    if (error) return json({ response_action: "errors", errors: { reason: error.message } });
    await updateMessage(notificationId, data?.applied ? `✅ 修正済み（${actor.name}・${start}〜${end}）` : `📝 修正申請を受け付けました（${actor.name}）`);
    return json({ response_action: "clear" });
  },
};

// ---- 4. Slack 応答のヘルパー ----
function ephemeral(msg: string) { return json({ response_type: "ephemeral", replace_original: false, text: msg }); }
async function openModal(triggerId: string, view: unknown) {
  const token = Deno.env.get("SLACK_BOT_TOKEN"); // 注: views.open だけは Bot Token が要る。notify-slack 経由にするか Phase 3 で決める
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
function attendanceFixModal(value: any, notificationId: string | null) {
  return {
    type: "modal", callback_id: "attendance.fix.modal",
    private_metadata: JSON.stringify({ alert_id: value?.alert_id, notification_id: notificationId }),
    title: { type: "plain_text", text: "勤怠の修正" }, submit: { type: "plain_text", text: "送信" }, close: { type: "plain_text", text: "やめる" },
    blocks: [
      { type: "section", text: { type: "mrkdwn", text: `*${value?.staff_name ?? ""}*　${value?.work_date ?? ""}\n予定 ${value?.planned ?? "-"}　実績 ${value?.actual ?? "-"}` } },
      { type: "input", block_id: "start", label: { type: "plain_text", text: "正しい出勤時刻" }, element: { type: "timepicker", action_id: "start", initial_time: value?.actual_start ?? "17:00" } },
      { type: "input", block_id: "end", label: { type: "plain_text", text: "正しい退勤時刻" }, element: { type: "timepicker", action_id: "end", initial_time: value?.actual_end ?? "23:00" } },
      { type: "input", block_id: "reason", label: { type: "plain_text", text: "修正理由" }, element: { type: "plain_text_input", action_id: "reason", multiline: true, max_length: 300 } },
    ],
  };
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
  if (!actor) return ephemeral("あなたの Slack アカウントは管理システムに紐付いていません。本部に連絡してください。");

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

  const h = handlers[key];
  if (!h) return ephemeral(`この操作（${key}）はまだ対応していません`);
  try {
    return await h({ sb, payload, actor, notificationId, value });
  } catch (e) {
    return ephemeral("処理に失敗しました: " + String(e).slice(0, 200));
  }
});
