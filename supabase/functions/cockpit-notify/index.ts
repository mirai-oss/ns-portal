// =============================================================
// cockpit-notify（担当H専任・2026-08-31）
// コックピット画面（cockpit.html）からの通知トリガー。
// 中山さんが画面でタスクを完了/ブロック/承認したときに呼ばれ、
// _shared/cockpit.ts の notifyTaskEvent で
//   ①Lark（経理チャンネル=app_secrets cockpit_lark_webhook）へ通知
//   ②完了時は unblocks の後続タスクを自動で「着手可」へ変更＋履歴記録
// を行う。呼び出せるのはマスターのみ（JWT→usersのis_masterで確認）。
// デプロイ: supabase functions deploy cockpit-notify --no-verify-jwt
// =============================================================
import { notifyTaskEvent, svc } from "../_shared/cockpit.ts";
import { verifiedUid } from "../_shared/auth-verify.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });

// 2026-11-15（セキュリティ修正）: これまでは jwtUid で、Authorization のトークンの「中身（sub）」を読むだけで、署名・期限を確かめていなかった
//   （この関数は verify_jwt=false で配置している）。→ _shared/auth-verify.ts の verifiedUid（Supabase Auth にトークンを渡して検証）に置きかえた。

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ ok: false, error: "POSTのみ" }, 405);

  const sb = svc();
  const uid = await verifiedUid(req, sb);
  if (!uid) return json({ ok: false, error: "ログインが必要です" }, 401);
  const { data: u } = await sb.from("users").select("id,name,is_master,is_active").eq("id", uid).maybeSingle();
  if (!u?.is_master || u.is_active === false) return json({ ok: false, error: "マスター専用です" }, 403);

  let b: any;
  try { b = await req.json(); } catch (_) { return json({ ok: false, error: "JSONを読めません" }, 400); }

  const kind = String(b.kind ?? "");
  const ALLOWED = new Set(["task_done", "blocked", "error", "reopened", "approved", "rejected", "approval_request"]);
  if (!ALLOWED.has(kind)) return json({ ok: false, error: "不明なkind: " + kind }, 400);

  let task: any = null;
  if (b.task_id) {
    const { data: t } = await sb.from("ck_tasks").select("*").eq("id", b.task_id).maybeSingle();
    task = t;
  }

  await notifyTaskEvent(sb, kind, task, { actor: u.name || "中山", message: String(b.message ?? "") });
  return json({ ok: true });
});
