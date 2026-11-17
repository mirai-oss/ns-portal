// =============================================================
// hq-task-reminders — 本部タスクの期限通知を、本人の Slack DM へ（サーバー側の定期実行。画面を開かなくても動く）
// 2026-11-17 新規（社長依頼）。DB: supabase/2026-12-13_hq_slack_task.sql。文面: _shared/hqtask-slack.ts。
// 呼び出し: pg_cron → public.hq_task_reminders_trigger()（毎日 9:00 と 15:15 JST）／手元から x-notify-secret 付き POST
//   body: { dry_run?: boolean, max?: number（既定 60）, op?: "post_create_button", channel_key?: string }
// スイッチ: app_settings.hq_task_slack.dm_enabled が true のときだけ送る（false のとき dry_run 以外は何も送らない）。
//   dry_run: 送らずに「誰に・どの種類を」の件数だけ返す（氏名・タスク名は返さない）。
// 重複防止: 送る前に hq_slack_reminder_claim で (工程・人・種類・日) を予約。取れなければ送らない。送信に失敗したら release して次回に回す。
// 認証: service_role（Bearer）か x-notify-secret。デプロイ: supabase functions deploy hq-task-reminders --no-verify-jwt --project-ref uuvsxzhpxtghojoubjcc --yes
// =============================================================
import { createClient } from "npm:@supabase/supabase-js@2";
import { reminderMessage, createButtonMessage, type Candidate } from "../_shared/hqtask-slack.ts";

const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json" } });
const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
function timingSafeEqual(a: string, b: string) { if (a.length !== b.length) return false; let r = 0; for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i); return r === 0; }
function authorized(req: Request): boolean {
  const key = (Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "").trim();
  const auth = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (key && auth && timingSafeEqual(auth, key)) return true;
  const secret = (Deno.env.get("NOTIFY_SLACK_SECRET") ?? "").trim();
  const hdr = (req.headers.get("x-notify-secret") ?? "").trim();
  return !!(secret && hdr && timingSafeEqual(secret, hdr));
}
async function sendSlack(body: Record<string, unknown>): Promise<any> {
  try {
    const res = await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/notify-slack`, {
      method: "POST", headers: { "Content-Type": "application/json", "x-notify-secret": Deno.env.get("NOTIFY_SLACK_SECRET") ?? "", apikey: Deno.env.get("SUPABASE_ANON_KEY") ?? "" },
      body: JSON.stringify(body),
    });
    return await res.json();
  } catch (e) { return { ok: false, error: "exception: " + String((e as Error)?.message ?? e).slice(0, 120) }; }
}
const jstDate = () => new Date(Date.now() + 9 * 3600_000).toISOString().slice(0, 10);

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ ok: false, error: "POST のみ" }, 405);
  if (!authorized(req)) return json({ ok: false, error: "認証がありません" }, 401);
  // deno-lint-ignore no-explicit-any
  let body: any = {}; try { body = await req.json(); } catch { body = {}; }
  const sb = svc();

  // 「タスクを作る」ボタンを、指定のチャンネルに 1 通置く（外へ送る操作。create_enabled が true のときだけ）
  if (body?.op === "post_create_button") {
    const { data: s } = await sb.from("app_settings").select("value").eq("key", "hq_task_slack").maybeSingle();
    if (s?.value?.create_enabled !== true) return json({ ok: false, error: "create_enabled が OFF です" }, 409);
    const key = typeof body.channel_key === "string" ? body.channel_key : "";
    if (!key) return json({ ok: false, error: "channel_key が必要です" }, 400);
    const m = createButtonMessage();
    const r = await sendSlack({ action: "send", channel_key: key, text: m.text, blocks: m.blocks, event: "hqtask_create_button", source: "ef:hq-task-reminders", dedupe_key: `hqtask_create_button:${key}:${jstDate()}` });
    return json({ ok: !!r?.ok, notification_id: r?.notification_id ?? null, error: r?.ok ? null : String(r?.error ?? "") });
  }

  const dry = body?.dry_run === true;
  const max = Math.min(200, Math.max(1, Number(body?.max) || 60));
  const { data: set } = await sb.from("app_settings").select("value").eq("key", "hq_task_slack").maybeSingle();
  const on = set?.value?.dm_enabled === true;
  if (!on && !dry) return json({ ok: true, skipped: "switch_off", message: "dm_enabled が OFF なので、何も送っていません" });

  const { data: cands, error } = await sb.rpc("hq_slack_reminder_candidates");
  if (error) return json({ ok: false, error: "candidates: " + error.message }, 500);
  const list = (cands ?? []) as Candidate[];
  const byKind: Record<string, number> = {};
  for (const c of list) byKind[c.kind] = (byKind[c.kind] ?? 0) + 1;
  if (dry) return json({ ok: true, dry_run: true, switch: on, total: list.length, people: new Set(list.map((c) => c.recipient_id)).size, by_kind: byKind });

  let sent = 0, failed = 0, skipped = 0;
  const date = jstDate();
  for (const c of list.slice(0, max)) {
    const { data: claimed, error: ce } = await sb.rpc("hq_slack_reminder_claim", { p_step: c.step_id, p_recipient: c.recipient_id, p_kind: c.kind });
    if (ce || claimed !== true) { skipped++; continue; }
    const m = reminderMessage(c);
    const r = await sendSlack({ action: "send", channel_key: `user:${c.recipient_id}`, text: m.text, blocks: m.blocks, event: "hqtask_reminder", source: "ef:hq-task-reminders",
      dedupe_key: `hqtask:${c.step_id}:${c.recipient_id}:${c.kind}:${date}`, ref: { table: "hq_task_steps", id: c.step_id } });
    if (r?.ok) sent++;
    else { failed++; await sb.rpc("hq_slack_reminder_release", { p_step: c.step_id, p_recipient: c.recipient_id, p_kind: c.kind }); }
  }
  return json({ ok: true, switch: true, total: list.length, sent, failed, skipped, deferred: Math.max(0, list.length - max), by_kind: byKind });
});
