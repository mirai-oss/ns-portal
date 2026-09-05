// =============================================================
// cockpit-ingest（担当H専任・2026-08-31）
// 各PCのai-cockpit CLIからheartbeat・進捗・イベントを受け取り、
// ck_devices / ck_sessions / ck_tasks / ck_events を更新する（service role・RLS通過）。
// 認証: app_secrets の 'cockpit_ingest_token'（値はSQL Editorでのみ投入・コードに書かない）
// デプロイ: supabase functions deploy cockpit-ingest --no-verify-jwt
//   （独自トークン認証のためJWT検証は使わない。トークン不一致は401で拒否）
// =============================================================
import { createClient } from "npm:@supabase/supabase-js@2";
import { larkPost, notifyTaskEvent } from "../_shared/cockpit.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });

const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ ok: false, error: "POSTのみ" }, 405);

  let b: any;
  try { b = await req.json(); } catch (_) { return json({ ok: false, error: "JSONを読めません" }, 400); }

  const sb = svc();

  // トークン照合
  const { data: sec } = await sb.from("app_secrets").select("value").eq("key", "cockpit_ingest_token").maybeSingle();
  const expected = (sec?.value ?? "").trim();
  if (!expected || (b.token ?? "").trim() !== expected) return json({ ok: false, error: "認証エラー" }, 401);

  // タスク一覧（読み取り専用）: AIセッションが「ユーザーの完了報告を代理完了する」際に
  // TK番号を確認するためのアクション（2026-08-31追加。ai-cockpit list から呼ばれる）
  if (b.list_tasks) {
    let q = sb.from("ck_tasks").select("task_no,title,status,assignee_name,priority,blocker").order("task_no");
    if (!b.include_done) q = q.not("status", "in", "(done,cancelled)");
    const { data: rows } = await q;
    return json({ ok: true, tasks: rows ?? [] });
  }

  // タスク登録（AIセッションが新しい作業を積むためのアクション。ai-cockpit add から呼ばれる）
  if (b.create_task) {
    const ct = b.create_task;
    if (!ct.title) return json({ ok: false, error: "titleが必要です" }, 400);
    const ins = {
      title: String(ct.title), description: String(ct.description ?? ""),
      priority: ["highest", "high", "mid", "low"].includes(ct.priority) ? ct.priority : "mid",
      assignee_name: String(ct.assignee_name ?? ""),
      assignee_type: ct.assignee_name === "中山" ? "human" : "ai",
      repository: String(ct.repository ?? ""), project: String(ct.project ?? ""),
      status: ["backlog", "ready", "in_progress", "waiting_human"].includes(ct.status) ? ct.status : "backlog",
      on_done_note: String(ct.on_done_note ?? ""), unblocks: String(ct.unblocks ?? ""),
    };
    const { data: t, error } = await sb.from("ck_tasks").insert(ins).select().single();
    if (error) return json({ ok: false, error: error.message }, 500);
    await sb.from("ck_events").insert({
      task_id: t.id, event_type: "task_create",
      message: `${b.agent_name || "AI"}がタスク作成: ${t.title}`,
      metadata: { agent: b.agent_name ?? "" },
    });
    return json({ ok: true, task: "TK-" + t.task_no });
  }

  const deviceKey = (b.device_key ?? "").trim();
  if (!deviceKey) return json({ ok: false, error: "device_keyが必要です" }, 400);
  const now = new Date().toISOString();

  // 端末upsert（渡された項目だけ更新）
  const devPatch: Record<string, unknown> = { device_key: deviceKey, status: "online", last_seen_at: now };
  if (b.device_name) devPatch.device_name = b.device_name;
  if (b.hostname) devPatch.hostname = b.hostname;
  if (b.os) devPatch.os = b.os;
  const { data: dev, error: devErr } = await sb.from("ck_devices").upsert(devPatch, { onConflict: "device_key" }).select().single();
  if (devErr || !dev) return json({ ok: false, error: "端末を登録できません: " + (devErr?.message ?? "") }, 500);

  // 定期ジョブの実行記録（watchのジョブ収集から呼ばれる。run_keyで重複防止・失敗のみLark通知）
  if (Array.isArray(b.job_runs)) {
    let inserted = 0, skipped = 0;
    for (const jr of b.job_runs.slice(0, 50)) {
      const key = String(jr.run_key ?? "");
      if (!key) continue;
      const { data: dup } = await sb.from("ck_events").select("id")
        .eq("event_type", "job_run").eq("metadata->>run_key", key).limit(1);
      if (dup && dup.length) { skipped++; continue; }
      const d = jr.duration_sec;
      const durTxt = d != null ? (d >= 60 ? `${Math.floor(d / 60)}分${d % 60}秒` : `${d}秒`) : "-";
      const mark = jr.status === "success" ? "✅" : jr.status === "skipped" ? "⏭" : "❌";
      await sb.from("ck_events").insert({
        device_id: dev.id, event_type: "job_run",
        message: `${mark} ${jr.job ?? "job"}（${durTxt}）${jr.status !== "success" && jr.message ? " " + String(jr.message).slice(0, 200) : ""}`,
        metadata: { run_key: key, job: jr.job ?? "", source: jr.source ?? "", status: jr.status ?? "",
                    duration_sec: d ?? null, at: jr.at ?? "", agent: "job-watch" },
      });
      inserted++;
      if (jr.status === "failure") {
        await larkPost(sb, `【AI開発コックピット】🚨 定期ジョブ失敗: ${jr.job ?? ""}（${jr.source ?? ""}）\n${String(jr.message ?? "").slice(0, 300)}\nhttps://mirai-oss.github.io/ns-portal/portal.html`);
      }
    }
    return json({ ok: true, inserted, skipped });
  }

  // タスク解決（task_no = 'TK-12' でも '12' でもOK）
  let task: any = null;
  const taskNo = b.task_no != null ? String(b.task_no).replace(/^TK-?/i, "").trim() : "";
  if (taskNo && /^\d+$/.test(taskNo)) {
    const { data: t } = await sb.from("ck_tasks").select("*").eq("task_no", Number(taskNo)).maybeSingle();
    task = t;
  }

  // セッションupsert（渡された項目だけ更新）
  let sessionRow: any = null;
  if (b.session_key) {
    const patch: Record<string, unknown> = { session_key: b.session_key, device_id: dev.id, last_heartbeat_at: now };
    for (const k of ["agent_type", "agent_name", "repository", "branch", "status", "progress_percent",
                     "current_file", "blocker", "git_head", "changed_files_count", "changed_files"]) {
      if (b[k] !== undefined && b[k] !== null) patch[k] = b[k];
    }
    if (task) patch.current_task_id = task.id;
    const { data: s, error: sErr } = await sb.from("ck_sessions").upsert(patch, { onConflict: "session_key" }).select().single();
    if (sErr) return json({ ok: false, error: "セッションを更新できません: " + sErr.message }, 500);
    sessionRow = s;
  }

  // タスク更新（task_status / progress_percent / blocker が来たときだけ）
  if (task && (b.task_status || b.task_assignee || b.task_unblocks !== undefined || b.task_note || b.progress_percent !== undefined || b.blocker !== undefined)) {
    const tp: Record<string, unknown> = { updated_at: now };
    if (b.task_assignee) { tp.assignee_name = String(b.task_assignee); tp.assignee_type = b.task_assignee === "中山" ? "human" : "ai"; }
    if (b.task_unblocks !== undefined && b.task_unblocks !== null) tp.unblocks = String(b.task_unblocks);
    if (b.task_note) tp.on_done_note = String(b.task_note);
    if (["highest", "high", "mid", "low"].includes(b.task_priority)) tp.priority = b.task_priority;
    if (b.task_status) { tp.status = b.task_status; if (b.task_status === "done") { tp.completed_at = now; tp.progress_percent = 100; } }
    if (b.progress_percent !== undefined && b.progress_percent !== null) tp.progress_percent = b.progress_percent;
    if (b.blocker !== undefined && b.blocker !== null) tp.blocker = b.blocker;
    await sb.from("ck_tasks").update(tp).eq("id", task.id);
    // 完了/ブロック/エラーはLark通知（完了時はunblocksの後続タスクを自動で着手可へ）。
    // すでに同じ状態なら通知しない（AI代理完了→画面で再度完了などの二重通知を防ぐ）
    if ((b.task_status === "done" || b.task_status === "blocked") && task.status !== b.task_status && !b.quiet) {
      await notifyTaskEvent(sb, b.task_status === "done" ? "task_done" : "blocked",
        { ...task, status: b.task_status },
        { actor: b.agent_name ?? "", message: b.message ?? "", deviceKey });
    }
  }
  if (b.event_type === "error") {
    await notifyTaskEvent(sb, "error", task, { actor: b.agent_name ?? "", message: b.message ?? "", deviceKey });
  }

  // 履歴（event_typeかmessageがあるときだけ。純粋なheartbeatは記録せずノイズを防ぐ）
  if (b.event_type || b.message) {
    await sb.from("ck_events").insert({
      session_id: sessionRow?.id ?? null,
      task_id: task?.id ?? null,
      device_id: dev.id,
      event_type: b.event_type ?? "note",
      message: b.message ?? "",
      metadata: { agent: b.agent_name ?? "", repository: b.repository ?? "", branch: b.branch ?? "", git_head: b.git_head ?? "" },
    });
  }

  // 承認依頼（approval_title があるとき）→ ck_approvals に積んで確認待ちへ
  if (b.approval_title) {
    await sb.from("ck_approvals").insert({
      task_id: task?.id ?? null, session_id: sessionRow?.id ?? null,
      kind: b.approval_kind ?? "other", title: b.approval_title, detail: b.approval_detail ?? "",
    });
    if (task) await sb.from("ck_tasks").update({ status: "waiting_human", updated_at: now }).eq("id", task.id);
    await notifyTaskEvent(sb, "approval_request", task,
      { actor: b.agent_name ?? "", message: b.approval_title + (b.approval_detail ? "\n" + b.approval_detail : ""), deviceKey });
  }

  // 承認状態の問い合わせ（approval_check=承認ID or タスクのpending有無）
  if (b.approval_check && task) {
    const { data: aps } = await sb.from("ck_approvals").select("id,title,status").eq("task_id", task.id)
      .order("requested_at", { ascending: false }).limit(5);
    return json({ ok: true, approvals: aps ?? [] });
  }

  return json({ ok: true, device: dev.device_key, session: sessionRow?.session_key ?? null, task: task ? "TK-" + task.task_no : null });
});
