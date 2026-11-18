// =============================================================
// hqtask-comment-dm — 本部タスクのコメントでメンションされた人へ、Slack の個人 DM を「親（短い）＋スレッド（コメントの流れ）」で送る
// 2026-11-18 新規（社長依頼: 親投稿はシンプルに・コメントの流れはスレッドに）。呼び出し元: DB 関数 hqtask_comment_dm_call（hq_notify_comment から）
// body: { comment_id: uuid, recipient_id: uuid }
// 親: 「○○さんが、あなたをメンションしました／【タスク名】／▶ タスクを開く」。スレッド: そのタスクの直近のコメント（古い順・今回が最後）
// スイッチ: app_settings.hqtask_comment_slack_dm（enabled・only_user_ids）。重複防止: hqtask_comment_slack_sent（コメント×相手で1回。失敗したら取り消して次回に回す）
// DM の投稿 ts は hqtask_comment_slack_sent に保存（第2段階＝スレッドへの返信をコメントに取り込む、の土台）
// 認証: service_role（Bearer）か x-notify-secret。デプロイ: supabase functions deploy hqtask-comment-dm --no-verify-jwt --project-ref uuvsxzhpxtghojoubjcc --yes
// =============================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json" } });
const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const isUuid = (x: unknown): x is string => typeof x === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(x);
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
const oneLine = (s: unknown, n: number) => String(s ?? "").replace(/\s+/g, " ").trim().slice(0, n);
const jst = (iso: string) => { const d = new Date(new Date(iso).getTime() + 9 * 3600_000); return `${String(d.getUTCMonth() + 1).padStart(2, "0")}/${String(d.getUTCDate()).padStart(2, "0")} ${String(d.getUTCHours()).padStart(2, "0")}:${String(d.getUTCMinutes()).padStart(2, "0")}`; };

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ ok: false, error: "POST のみ" }, 405);
  if (!authorized(req)) return json({ ok: false, error: "認証がありません" }, 401);
  // deno-lint-ignore no-explicit-any
  let body: any = {}; try { body = await req.json(); } catch { body = {}; }
  if (!isUuid(body?.comment_id) || !isUuid(body?.recipient_id)) return json({ ok: false, error: "comment_id と recipient_id（uuid）が必要です" }, 400);
  const sb = svc();
  const commentId: string = body.comment_id, recipient: string = body.recipient_id;

  // スイッチ（DB 側でも見ているが、ここでも確かめる）
  const { data: cfg } = await sb.from("app_settings").select("value").eq("key", "hqtask_comment_slack_dm").maybeSingle();
  const v = cfg?.value ?? {};
  const only: unknown[] = Array.isArray(v.only_user_ids) ? v.only_user_ids : [];
  if (v.enabled !== true || (only.length > 0 && !only.includes(recipient))) return json({ ok: true, status: "off" });

  const { data: com } = await sb.from("hq_task_comments").select("id,task_id,created_by,body,mentions,created_at").eq("id", commentId).maybeSingle();
  if (!com || !Array.isArray(com.mentions) || !com.mentions.includes(recipient) || com.created_by === recipient) return json({ ok: true, status: "skip" });
  const { data: task } = await sb.from("hq_tasks").select("id,title").eq("id", com.task_id).maybeSingle();
  if (!task) return json({ ok: true, status: "skip" });
  const { data: linked } = await sb.from("user_slack").select("user_id").eq("user_id", recipient).maybeSingle();
  if (!linked) return json({ ok: true, status: "unlinked" });

  // 二重送信の防止（コメント×相手で1回）。取れなければ何もしない
  const { error: ce } = await sb.from("hqtask_comment_slack_sent").insert({ comment_id: commentId, user_id: recipient, task_id: task.id });
  if (ce) return json({ ok: true, status: String(ce.code) === "23505" ? "duplicate" : "claim_error" });
  const release = async () => { await sb.from("hqtask_comment_slack_sent").delete().eq("comment_id", commentId).eq("user_id", recipient); };

  try {
    const { data: from } = await sb.from("users").select("name").eq("id", com.created_by).maybeSingle();
    const url = `https://mirai-oss.github.io/ns-portal/tasks.html?task=${task.id}`;
    const parentText = `💬 ${from?.name ?? "誰か"}さんが、あなたをメンションしました\n【${oneLine(task.title, 80)}】\n▶ タスクを開く: ${url}`;
    const key = `user:${recipient}`;
    const r1 = await sendSlack({ action: "send", channel_key: key, text: parentText, event: "hqtask_comment_mention", source: "ef:hqtask-comment-dm", ref: { table: "hq_task_comments", id: commentId } });
    if (!r1?.ok || !r1.ts) { await release(); return json({ ok: false, status: "parent_failed", error: String(r1?.error ?? "").slice(0, 120) }, 502); }

    // スレッド: このタスクの直近のコメント（今回のものが最後）
    const { data: recent } = await sb.from("hq_task_comments").select("id,created_by,body,created_at").eq("task_id", task.id).lte("created_at", com.created_at).order("created_at", { ascending: false }).limit(6);
    const rows = (recent ?? []).slice().reverse();
    const ids = [...new Set(rows.map((r: { created_by: string }) => r.created_by))];
    const { data: us } = ids.length ? await sb.from("users").select("id,name").in("id", ids) : { data: [] };
    const nm = new Map((us ?? []).map((u: { id: string; name: string }) => [u.id, u.name]));
    const lines = rows.map((r: { id: string; created_by: string; body: string; created_at: string }) =>
      `${r.id === commentId ? "▶ " : "・"}${nm.get(r.created_by) ?? "不明"}（${jst(r.created_at)}）${oneLine(r.body, r.id === commentId ? 500 : 140)}`);
    const histText = `コメントの流れ（古い順・直近${rows.length}件）\n${lines.join("\n")}`;
    const r2 = await sendSlack({ action: "send", channel_key: key, thread_ts: r1.ts, text: histText, event: "hqtask_comment_history", source: "ef:hqtask-comment-dm", ref: { table: "hq_task_comments", id: commentId } });
    await sb.from("hqtask_comment_slack_sent").update({ slack_channel: r1.slack_channel_id ?? null, slack_ts: r1.ts }).eq("comment_id", commentId).eq("user_id", recipient);
    return json({ ok: true, status: "sent", thread: !!r2?.ok });
  } catch (e) {
    await release();
    return json({ ok: false, status: "error", error: String((e as Error)?.message ?? e).slice(0, 120) }, 500);
  }
});
