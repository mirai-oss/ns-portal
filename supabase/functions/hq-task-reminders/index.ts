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
import { reminderMessage, createButtonMessage, parentMessage, taskCardMessage, nextNoticeMessage, type NextItem, type StepRow, type Candidate } from "../_shared/hqtask-slack.ts";

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

// 2026-11-19 次の担当者への通知。前の工程が止まっている（期限の当日・超過）・前の工程が完了した、ときに、次の工程の担当者へ 1 人 1 通にまとめて DM。
//   設定 hq_task_slack.next_notice_enabled と dm_enabled が両方 true のときだけ送る（dry_run は件数だけ返す）。only_recipient＝その人だけに送る（試し送り用）
// deno-lint-ignore no-explicit-any
async function runNext(sb: any, o: { kinds: string[]; dry?: boolean; onlyRecipient?: string | null }): Promise<Record<string, unknown>> {
  const { data: set } = await sb.from("app_settings").select("value").eq("key", "hq_task_slack").maybeSingle();
  const on = set?.value?.dm_enabled === true && set?.value?.next_notice_enabled === true;
  if (!on && !o.dry) return { next: "switch_off" };
  const { data: cands, error } = await sb.rpc("hq_slack_next_candidates");
  if (error) return { next: "error", error: String(error.message).slice(0, 120) };
  // deno-lint-ignore no-explicit-any
  const list = ((cands ?? []) as any[]).filter((c) => o.kinds.includes(c.kind) && (!o.onlyRecipient || c.recipient_id === o.onlyRecipient));
  const people = new Map<string, any[]>();
  for (const c of list) people.set(c.recipient_id, [...(people.get(c.recipient_id) ?? []), c]);
  if (o.dry) { const by: Record<string, number> = {}; for (const c of list) by[c.kind] = (by[c.kind] ?? 0) + 1; return { next: "dry_run", total: list.length, people: people.size, by_kind: by }; }
  let sent = 0, failed = 0;
  const date = jstDate();
  for (const [rid, rows] of people) {
    const mine: any[] = [];
    for (const c of rows.slice(0, 20)) { const { data: ok } = await sb.rpc("hq_slack_reminder_claim", { p_step: c.step_id, p_recipient: rid, p_kind: c.kind }); if (ok === true) mine.push(c); }
    if (!mine.length) continue;
    const m = nextNoticeMessage(mine as NextItem[]);
    const r = await sendSlack({ action: "send", channel_key: `user:${rid}`, text: m.text, blocks: m.blocks, event: "hqtask_next", source: "ef:hq-task-reminders",
      dedupe_key: `hqtask_next:${rid}:${date}:${mine.map((c) => `${c.step_id.slice(0, 8)}${c.kind.slice(5, 6)}`).join("")}`, ref: { table: "hq_task_steps", id: mine[0].step_id } });
    if (r?.ok) sent += mine.length; else { failed += mine.length; for (const c of mine) await sb.rpc("hq_slack_reminder_release", { p_step: c.step_id, p_recipient: rid, p_kind: c.kind }); }
  }
  return { next: "done", people: people.size, items_sent: sent, failed };
}

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

  // Slack の鍵（Bot Token）に付いている権限（スコープ）の名前だけを返す（鍵の値は出さない）。ファイル添付に files:read が要るかの確認用
  if (body?.op === "slack_scopes") {
    const t = Deno.env.get("SLACK_BOT_TOKEN") ?? "";
    if (!t) return json({ ok: false, error: "SLACK_BOT_TOKEN 未設定" });
    const r = await fetch("https://slack.com/api/auth.test", { method: "POST", headers: { Authorization: `Bearer ${t}` } });
    const j = await r.json().catch(() => ({}));
    return json({ ok: !!j?.ok, scopes: String(r.headers.get("x-oauth-scopes") ?? "").split(",").map((x) => x.trim()).filter(Boolean), error: j?.error ?? null });
  }

  // 社長が承認した古い通知の投稿を、Slack から削除する（台帳の番号を指定。台帳が「Indeedから新しい応募」の旧い経路の投稿であるものだけ・Bot が自分で出した投稿だけ）。list_only=true なら、削除せず一覧だけ返す
  if (body?.op === "delete_old_route_posts") {
    const ids = (Array.isArray(body?.ids) ? body.ids : []).map(String).slice(0, 10);
    const { data: led } = await sb.from("notification_deliveries").select("id,event,slack_channel_id,slack_ts,payload,delivery_status,created_at").in("id", ids.length ? ids : ["00000000-0000-0000-0000-000000000000"]);
    const out: unknown[] = [];
    for (const r of (led ?? []) as any[]) {
      const okRow = r.event === "route" && String(r.payload?.text ?? "").includes("Indeedから新しい応募") && r.slack_ts && r.slack_channel_id;
      if (!okRow) { out.push({ id: r.id, skipped: "対象外" }); continue; }
      if (body?.list_only === true) { out.push({ id: r.id, at: r.created_at, status: r.delivery_status, text: String(r.payload?.text ?? "").slice(0, 40) }); continue; }
      const res = await fetch("https://slack.com/api/chat.delete", { method: "POST", headers: { "Content-Type": "application/json; charset=utf-8", Authorization: `Bearer ${Deno.env.get("SLACK_BOT_TOKEN")}` }, body: JSON.stringify({ channel: r.slack_channel_id, ts: r.slack_ts }) });
      const j = await res.json().catch(() => ({}));
      out.push({ id: r.id, deleted: !!j?.ok, error: j?.error ?? null });
    }
    return json({ ok: true, op: "delete_old_route_posts", results: out });
  }

  if (body?.op === "next_notices") {
    const kinds = Array.isArray(body?.kinds) && body.kinds.length ? body.kinds.map(String) : ["next_today", "next_over", "next_ready"];
    return json({ ok: true, op: "next_notices", ...(await runNext(sb, { kinds, dry: body?.dry_run === true, onlyRecipient: body?.only_recipient ? String(body.only_recipient) : null })) });
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

  // 2026-11-18 親投稿とスレッドの詳細カード（チャンネル）を、いまのタスクの状態に合わせて書き換える。社内の Slack の投稿を直すだけ（応募者・外部には送らない）
  //   管理システム（画面）で工程を足した・完了した・担当や期限を変えたときも、これで Slack に追従する（定期実行は 1 分ごと）。
  //   only_changed: true（定期実行用）＝いまの表示が台帳の最後の表示と同じなら何もしない（Slack への無駄な書き換えをしない）。Slack 側で消えた投稿（message_not_found）は飛ばす
  if (body?.op === "refresh_parents") {
    const max = Math.min(100, Math.max(1, Number(body?.max) || 50));
    const onlyChanged = body?.only_changed === true;
    const { data: logs } = await sb.from("hq_slack_task_log").select("task_id,parent_notification_id,card_notification_id").or("parent_notification_id.not.is.null,card_notification_id.not.is.null").order("created_at", { ascending: false }).limit(max);
    const ids = ((logs ?? []) as any[]).flatMap((l) => [l.parent_notification_id, l.card_notification_id]).filter(Boolean);
    const { data: led } = await sb.from("notification_deliveries").select("id,delivery_status,error,payload").in("id", ids.length ? ids : ["00000000-0000-0000-0000-000000000000"]);
    const ledger = new Map(((led ?? []) as any[]).map((r) => [r.id, r]));
    let done = 0, failed = 0, same = 0, gone = 0, cardsDone = 0;
    // 台帳の最後の表示（blocks）と同じか。同じなら Slack へ送らない
    // DB（jsonb）は項目の並びを入れ替えて保存するので、項目名を並べ直した形で比べる
    // deno-lint-ignore no-explicit-any
    const canon = (v: any): any => Array.isArray(v) ? v.map(canon) : v && typeof v === "object" ? Object.fromEntries(Object.keys(v).sort().map((k) => [k, canon(v[k])])) : v;
    const unchanged = (nid: string, blocks: unknown[]) => { const lr = ledger.get(nid); const cur = (lr?.payload?.updated_blocks ?? lr?.payload?.blocks); return JSON.stringify(canon(cur ?? null)) === JSON.stringify(canon(blocks)); };
    const isGone = (nid: string) => { const lr = ledger.get(nid); return lr?.delivery_status === "failed" && lr?.error === "message_not_found"; };
    for (const l of (logs ?? []) as any[]) {
      if (onlyChanged && (!l.parent_notification_id || isGone(l.parent_notification_id)) && (!l.card_notification_id || isGone(l.card_notification_id))) { gone++; continue; }
      const { data: g } = await sb.rpc("hq_slack_task_get", { p_task: l.task_id });
      const { data: sg } = await sb.rpc("hq_slack_steps_get", { p_task: l.task_id });
      if (!g?.ok) { failed++; continue; }
      const rows = (sg?.steps ?? []) as StepRow[];
      const allDone = rows.length > 0 && rows.every((x) => x.done);
      if (l.parent_notification_id && !(onlyChanged && isGone(l.parent_notification_id))) {
        const pm = parentMessage({ title: g.title, due: g.due, dueTime: g.due_time, done: allDone, strip: { urgent: g.urgent, names: rows.filter((x) => !x.done).flatMap((x) => x.assignee_names ?? []), stepsDone: rows.filter((x) => x.done).length, stepsTotal: rows.length,
          overdue: !allDone && String(g.due ?? "") !== "" && String(g.due) < jstDate() } });
        if (onlyChanged && unchanged(l.parent_notification_id, pm.blocks)) same++;
        else { const r = await sendSlack({ action: "update", notification_id: l.parent_notification_id, text: pm.text, blocks: pm.blocks }); if (r?.ok) done++; else failed++; }
      }
      if (l.card_notification_id && !(onlyChanged && isGone(l.card_notification_id))) {
        const { data: cr } = await sb.from("users").select("name").eq("id", g.creator_id).maybeSingle();
        const cm = taskCardMessage({ task_id: l.task_id, title: g.title, corp: g.corp, assigneeNames: [...new Set(rows.filter((x) => !x.done).flatMap((x) => x.assignee_names ?? []))], due: g.due, dueTime: g.due_time, memo: g.memo, notes: g.notes,
          steps: rows.map((x) => ({ title: x.title, done: x.done, names: x.assignee_names, due: x.due, dueTime: x.due_time, id: x.id, canComplete: !x.photo })), creatorName: String(cr?.name ?? "").replace(/[\s\u3000]+/g, ""), urgent: g.urgent, url: `https://mirai-oss.github.io/ns-portal/tasks.html?task=${l.task_id}` });
        if (onlyChanged && unchanged(l.card_notification_id, cm.blocks)) same++;
        else { const r = await sendSlack({ action: "update", notification_id: l.card_notification_id, text: cm.text, blocks: cm.blocks }); if (r?.ok) { cardsDone++; } else failed++; }
      }
    }
    // 前の工程が完了した → 次の担当者へ「あなたの番です」（1 分ごとのこの実行に乗せる。スイッチが OFF なら何もしない）
    const nx = onlyChanged ? await runNext(sb, { kinds: ["next_ready"] }).catch(() => ({ next: "error" })) : {};
    return json({ ok: true, op: "refresh_parents", total: (logs ?? []).length, updated: done, cards_updated: cardsDone, unchanged: same, gone, failed, ...nx });
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
  // 朝の実行（日本時間 12 時より前）だけ、次の担当者への通知（前の工程が期限の当日・超過）も送る
  const jstHour = new Date(Date.now() + 9 * 3600_000).getUTCHours();
  const nx = jstHour < 12 ? await runNext(sb, { kinds: ["next_today", "next_over"] }).catch(() => ({ next: "error" })) : {};
  return json({ ok: true, switch: true, total: list.length, sent, failed, skipped, deferred: Math.max(0, list.length - max), by_kind: byKind, ...nx });
});
