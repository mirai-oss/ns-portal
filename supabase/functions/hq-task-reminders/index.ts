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
import { callModel, jstToday as aiToday, systemPrompt, toDraft, type RosterEntry } from "../_shared/hqtask-ai.ts";
import { reminderMessage, createButtonMessage, parentMessage, type Candidate } from "../_shared/hqtask-slack.ts";

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

  // 2026-11-18 @アプリ の文章→下書きの試験（Slack へは何も送らない・何も保存しない）。text を AI に渡して、下書きと、失敗したときの理由（鍵は出さない）を返す
  if (body?.op === "ai_selftest") {
    const apiKey = Deno.env.get("ANTHROPIC_API_KEY") ?? "";
    if (!apiKey) return json({ ok: false, error: "ANTHROPIC_API_KEY 未設定" });
    const { data: set } = await sb.from("app_settings").select("value").eq("key", "hq_task_slack").maybeSingle();
    const { data: ros } = await sb.from("user_slack").select("slack_user_id,user_id");
    const { data: us } = await sb.from("users").select("id,name,role").eq("is_active", true).in("id", (ros ?? []).map((r: any) => r.user_id));
    const byId = new Map((us ?? []).map((u: any) => [u.id, u]));
    const roster: RosterEntry[] = (ros ?? []).filter((r: any) => byId.has(r.user_id)).map((r: any) => ({ slack_user_id: r.slack_user_id, name: String((byId.get(r.user_id) as any).name ?? "").replace(/[\s　]+/g, ""), role: (byId.get(r.user_id) as any).role }));
    let err = "";
    const today = aiToday();
    const out = await callModel({ apiKey, model: String(body?.model || set?.value?.ai_model || "claude-haiku-5-5"), system: systemPrompt(today, roster), user: `次の文章から、本部タスクの下書きを作ってください。\n\n${String(body?.text ?? "")}`, onError: (e) => { err = e; } });
    if (!out) return json({ ok: false, error: err || "unknown" });
    const d = toDraft(out.json, roster, today);
    const nm = new Map(roster.map((r) => [r.slack_user_id, r.name]));
    return json({ ok: true, tokens: [out.inTokens, out.outTokens], draft: { ...d, steps: d.steps.map((x) => ({ ...x, users: x.users.map((u) => nm.get(u) ?? "?") })) } });
  }

  // 2026-11-18 親投稿（チャンネル）を、いまのタスクの状態（2 行目＝文字と太字）に合わせて書き換える。社内の Slack の投稿を直すだけ（応募者・外部には送らない）
  //   only_changed: true（定期実行用）＝いまの表示が台帳の最後の表示と同じなら何もしない（Slack への無駄な書き換えをしない）。Slack 側で消えた投稿（message_not_found）は飛ばす
  if (body?.op === "refresh_parents") {
    const max = Math.min(100, Math.max(1, Number(body?.max) || 50));
    const onlyChanged = body?.only_changed === true;
    const { data: logs } = await sb.from("hq_slack_task_log").select("task_id,parent_notification_id").not("parent_notification_id", "is", null).order("created_at", { ascending: false }).limit(max);
    const ids = ((logs ?? []) as any[]).map((l) => l.parent_notification_id);
    const { data: led } = await sb.from("notification_deliveries").select("id,delivery_status,error,payload").in("id", ids.length ? ids : ["00000000-0000-0000-0000-000000000000"]);
    const ledger = new Map(((led ?? []) as any[]).map((r) => [r.id, r]));
    let done = 0, failed = 0, same = 0, gone = 0;
    for (const l of (logs ?? []) as any[]) {
      const lr = ledger.get(l.parent_notification_id);
      if (onlyChanged && lr?.delivery_status === "failed" && lr?.error === "message_not_found") { gone++; continue; }
      const { data: g } = await sb.rpc("hq_slack_task_get", { p_task: l.task_id });
      const { data: sg } = await sb.rpc("hq_slack_steps_get", { p_task: l.task_id });
      if (!g?.ok) { failed++; continue; }
      const sl = (sg?.steps ?? []) as any[];
      const allDone = sl.length > 0 && sl.every((x) => x.done);
      const pm = parentMessage({ title: g.title, due: g.due, dueTime: g.due_time, done: allDone, strip: { urgent: g.urgent, names: sl.filter((x) => !x.done).flatMap((x) => x.assignee_names ?? []), stepsDone: sl.filter((x) => x.done).length, stepsTotal: sl.length,
        overdue: !allDone && String(g.due ?? "") !== "" && String(g.due) < jstDate() } });
      if (onlyChanged) {
        const cur = ((lr?.payload?.updated_blocks ?? lr?.payload?.blocks) as any[] | undefined)?.[0]?.text?.text;
        if (cur === (pm.blocks as any[])[0].text.text) { same++; continue; }
      }
      const r = await sendSlack({ action: "update", notification_id: l.parent_notification_id, text: pm.text, blocks: pm.blocks });
      if (r?.ok) done++; else failed++;
    }
    return json({ ok: true, op: "refresh_parents", total: (logs ?? []).length, updated: done, unchanged: same, gone, failed });
  }

  // 作成者への「完了しました」DM（Slack のフォームで付けたタスクが完了したとき）。dm_enabled が true のときだけ送る
  if (body?.op === "completions") {
    const { data: s2 } = await sb.from("app_settings").select("value").eq("key", "hq_task_slack").maybeSingle();
    const dry2 = body?.dry_run === true;
    if (s2?.value?.dm_enabled !== true && !dry2) return json({ ok: true, skipped: "switch_off" });
    const { data: rows, error: e2 } = await sb.rpc("hq_slack_complete_candidates");
    if (e2) return json({ ok: false, error: "complete_candidates: " + e2.message }, 500);
    const list2 = (rows ?? []) as any[];
    if (dry2) return json({ ok: true, dry_run: true, total: list2.length });
    let sent2 = 0, failed2 = 0;
    for (const c of list2.slice(0, 30)) {
      const { data: ok2 } = await sb.rpc("hq_slack_complete_claim", { p_task: c.task_id });
      if (ok2 !== true) continue;
      const at = c.completed_at ? new Date(c.completed_at).toLocaleString("ja-JP", { timeZone: "Asia/Tokyo", month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit", hour12: false }) : "";
      const title = String(c.task_title ?? "").replace(/[\u0000-\u001f]/g, " ").slice(0, 100);
      const text = `✅ *あなたが付けたタスクが完了しました*\n*${title}*\n完了：${c.completer_names ?? "—"}（${at}）\n🔗 <${c.url}|管理システムで開く>`;
      const r = await sendSlack({ action: "send", channel_key: `user:${c.creator_id}`, text: `✅ 完了しました：${title}`, event: "hqtask_completed", source: "ef:hq-task-reminders",
        blocks: [{ type: "section", text: { type: "mrkdwn", text } }, { type: "actions", block_id: "hqtask_done", elements: [{ type: "button", text: { type: "plain_text", text: "管理システムで開く", emoji: true }, url: c.url, action_id: "hqtask.link" }] }],
        dedupe_key: `hqtask_completed:${c.task_id}`, ref: { table: "hq_tasks", id: c.task_id } });
      if (r?.ok) sent2++; else { failed2++; await sb.rpc("hq_slack_complete_release", { p_task: c.task_id }); }
      // 親投稿（チャンネル）があれば「✅ … ｜完了」に更新する
      if (r?.ok) {
        const { data: lg } = await sb.from("hq_slack_task_log").select("parent_notification_id").eq("task_id", c.task_id).maybeSingle();
        const { data: tk } = await sb.from("hq_tasks").select("title,due_date,due_time").eq("id", c.task_id).maybeSingle();
        if (lg?.parent_notification_id && tk) {
          const { data: sgs } = await sb.rpc("hq_slack_steps_get", { p_task: c.task_id });
          const nn = ((sgs?.steps ?? []) as any[]).length;
          const pm = parentMessage({ title: tk.title, due: tk.due_date, dueTime: tk.due_time, done: true, strip: { stepsDone: nn, stepsTotal: nn } });
          await sendSlack({ action: "update", notification_id: lg.parent_notification_id, text: pm.text, blocks: pm.blocks });
        }
      }
    }
    return json({ ok: true, op: "completions", total: list2.length, sent: sent2, failed: failed2 });
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

  // 依頼者の名前・詳細（DM に「誰から・何を」を必ず出すため）
  const taskIds = [...new Set(list.map((c) => c.task_id))];
  const { data: tks } = await sb.from("hq_tasks").select("id,description,created_by").in("id", taskIds.length ? taskIds : ["00000000-0000-0000-0000-000000000000"]);
  const creatorIds = [...new Set((tks ?? []).map((t: any) => t.created_by).filter(Boolean))];
  const { data: us } = await sb.from("users").select("id,name").in("id", creatorIds.length ? creatorIds : ["00000000-0000-0000-0000-000000000000"]);
  const nameOf = new Map((us ?? []).map((u: any) => [u.id, String(u.name ?? "").replace(/[\s\u3000]+/g, "")]));
  const extra = new Map((tks ?? []).map((t: any) => [t.id, { creatorName: t.created_by ? (nameOf.get(t.created_by) ?? null) : null, memo: t.description ?? null }]));
  let sent = 0, failed = 0, skipped = 0;
  const date = jstDate();
  for (const c of list.slice(0, max)) {
    const { data: claimed, error: ce } = await sb.rpc("hq_slack_reminder_claim", { p_step: c.step_id, p_recipient: c.recipient_id, p_kind: c.kind });
    if (ce || claimed !== true) { skipped++; continue; }
    const m = reminderMessage(c, extra.get(c.task_id) ?? {});
    const r = await sendSlack({ action: "send", channel_key: `user:${c.recipient_id}`, text: m.text, blocks: m.blocks, event: "hqtask_reminder", source: "ef:hq-task-reminders",
      dedupe_key: `hqtask:${c.step_id}:${c.recipient_id}:${c.kind}:${date}`, ref: { table: "hq_task_steps", id: c.step_id } });
    if (r?.ok) sent++;
    else { failed++; await sb.rpc("hq_slack_reminder_release", { p_step: c.step_id, p_recipient: c.recipient_id, p_kind: c.kind }); }
  }
  return json({ ok: true, switch: true, total: list.length, sent, failed, skipped, deferred: Math.max(0, list.length - max), by_kind: byKind });
});
