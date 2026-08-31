// AI開発コックピット共通ヘルパー（担当H専任・2026-08-31）
// cockpit-ingest（CLI経由）と cockpit-notify（画面経由）の両方から import して使う。
//
// notifyTaskEvent(): タスクの完了/ブロック/エラー/承認依頼などをLarkへ通知し、
//   完了時は unblocks（カンマ区切りのTK番号）に書かれた後続タスクを「着手可(ready)」へ
//   自動で動かす（＝中山さんのタスク完了を見て次の担当が動ける状態にする）。
//   動かした内容は ck_events に記録する（誰がどう動いたか画面の履歴で見える）。
// Lark webhookは app_secrets の cockpit_lark_webhook（ダイニー取込と同じ経理チャンネル）。
// キーワード制限付きボットの場合は cockpit_lark_keyword を先頭に付ける。
import { createClient } from "npm:@supabase/supabase-js@2";

export const svc = () =>
  createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const PORTAL_URL = "https://mirai-oss.github.io/ns-portal/portal.html";

export async function getSecret(sb: any, key: string): Promise<string> {
  const { data } = await sb.from("app_secrets").select("value").eq("key", key).maybeSingle();
  return (data?.value ?? "").trim();
}

// Larkカスタムボットへテキスト送信。webhook未登録・送信失敗でも throw しない（本処理を止めない）
export async function larkPost(sb: any, text: string): Promise<boolean> {
  try {
    const webhook = await getSecret(sb, "cockpit_lark_webhook");
    if (!webhook) return false;
    const keyword = await getSecret(sb, "cockpit_lark_keyword");
    const body = { msg_type: "text", content: { text: (keyword ? keyword + "\n" : "") + text } };
    const res = await fetch(webhook, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    return res.ok;
  } catch (_) {
    return false;
  }
}

const tk = (t: any) => "TK-" + t.task_no;

// kind: task_done / blocked / error / reopened / approval_request / approved / rejected
export async function notifyTaskEvent(
  sb: any,
  kind: string,
  task: any | null,
  opts: { actor?: string; message?: string; deviceKey?: string } = {},
): Promise<void> {
  const actor = opts.actor || "";
  const lines: string[] = [];
  let unblockedNote = "";

  // 完了時: unblocks のタスクを着手可へ動かす（未完了のものだけ）
  if (kind === "task_done" && task?.unblocks) {
    const nos = String(task.unblocks)
      .split(/[,、\s]+/)
      .map((s: string) => s.replace(/^TK-?/i, "").trim())
      .filter((s: string) => /^\d+$/.test(s))
      .map(Number);
    if (nos.length) {
      const { data: targets } = await sb.from("ck_tasks").select("*").in("task_no", nos);
      const moved: string[] = [];
      for (const t of targets ?? []) {
        if (["backlog", "blocked", "waiting_human"].includes(t.status)) {
          await sb.from("ck_tasks").update({ status: "ready", updated_at: new Date().toISOString() }).eq("id", t.id);
          moved.push(`${tk(t)}「${t.title}」→ ${t.assignee_name || "担当未定"}が着手可に`);
          await sb.from("ck_events").insert({
            task_id: t.id,
            event_type: "task_update",
            message: `${task ? tk(task) : ""}完了により自動で着手可(ready)へ変更`,
            metadata: { agent: "コックピット自動", trigger: task ? tk(task) : "" },
          });
        } else {
          moved.push(`${tk(t)}「${t.title}」は現在「${t.status}」のため変更なし`);
        }
      }
      if (moved.length) unblockedNote = moved.join("\n");
    }
  }

  const head =
    kind === "task_done" ? "✅ 完了"
    : kind === "blocked" ? "⚠️ ブロック"
    : kind === "error" ? "🚨 エラー"
    : kind === "reopened" ? "↩️ 差し戻し（完了扱いを取り消し）"
    : kind === "approval_request" ? "🙋 承認依頼"
    : kind === "approved" ? "👍 承認"
    : kind === "rejected" ? "❌ 却下"
    : "ℹ️ " + kind;

  lines.push(`【AI開発コックピット】${head}`);
  if (task) lines.push(`${tk(task)}「${task.title}」${task.assignee_name ? `（担当: ${task.assignee_name}）` : ""}`);
  if (actor || opts.deviceKey) lines.push(`by ${actor || "?"}${opts.deviceKey ? ` / ${opts.deviceKey}` : ""}`);
  if (opts.message) lines.push(opts.message);
  if (kind === "task_done" && task?.on_done_note) lines.push(`次にやること: ${task.on_done_note}`);
  if (unblockedNote) lines.push(`▼自動で動かしました\n${unblockedNote}`);
  lines.push(PORTAL_URL);

  await larkPost(sb, lines.join("\n"));
}
