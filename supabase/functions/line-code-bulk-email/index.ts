// 2026-09-07 担当B（nippo）新規
// ユーザー要望「LINE未連携の人へ、1人ずつ開かずに合言葉をまとめて送りたい。メールで送れるなら
// それが理想」に対応。既存の合言葉発行(admin_issue_line_code RPC)は1人ずつのため、
// このEdge Functionでは①合言葉が未発行の人には発行し②登録メールアドレスへResendで送信、を
// まとめて行う。スマレジ招待メール(smaregi-sync の action:"invite")と同じRESEND_API_KEY・
// 同じメール文面パターンを踏襲。
//
// body: { user_ids?: string[] }  省略時は「有効・LINE未連携の全員」が対象（CEO/HQのみ）
import { createClient } from "npm:@supabase/supabase-js@2";

const cors: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });

const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const RESEND_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const RESEND_FROM = Deno.env.get("RESEND_FROM") ?? "鳥一代グループ 日報システム <onboarding@resend.dev>";
const APP_URL = Deno.env.get("APP_URL") ?? "https://mirai-oss.github.io/nippo/";

function jwtUid(req: Request): string {
  try {
    const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    return JSON.parse(atob(jwt.split(".")[1].replace(/-/g, "+").replace(/_/g, "/"))).sub ?? "";
  } catch (_) { return ""; }
}

async function genCode(sb: ReturnType<typeof svc>): Promise<string> {
  const chars = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ";
  for (let guard = 0; guard < 500; guard++) {
    let code = "";
    for (let i = 0; i < 6; i++) code += chars[Math.floor(Math.random() * chars.length)];
    const { count: c1 } = await sb.from("users").select("id", { count: "exact", head: true }).eq("line_code", code);
    const { count: c2 } = await sb.from("applicants").select("id", { count: "exact", head: true }).eq("line_code", code);
    if (!c1 && !c2) return code;
  }
  throw new Error("合言葉の採番に失敗しました");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const sb = svc();
    const uid = jwtUid(req);
    if (!uid) return json({ ok: false, error: "ログインが必要です" }, 401);
    const { data: caller } = await sb.from("users").select("role,is_active").eq("id", uid).maybeSingle();
    if (!caller?.is_active || !["CEO", "HQ"].includes(caller.role)) {
      return json({ ok: false, error: "権限がありません（社長・本部のみ）" }, 403);
    }
    if (!RESEND_KEY) return json({ ok: false, error: "RESEND_API_KEYが未設定です" }, 400);

    let body: any = {};
    try { body = await req.json(); } catch { /* no body */ }
    const userIds: string[] | null = Array.isArray(body.user_ids) && body.user_ids.length ? body.user_ids : null;

    let q = sb.from("users").select("id,name,email,line_code").is("line_user_id", null).eq("is_active", true);
    if (userIds) q = q.in("id", userIds);
    const { data: targets } = await q;
    if (!targets || !targets.length) return json({ ok: true, sent: [], sentCount: 0, failedCount: 0, failed: [] });

    const { data: oaRow } = await sb.from("app_secrets").select("value").eq("key", "line_oa_id").maybeSingle();
    const oa = (oaRow?.value ?? "").trim();
    if (!oa) return json({ ok: false, error: "LINE公式アカウントIDが未設定です（設定画面で登録してください）" }, 400);

    const sent: any[] = [];
    const failed: any[] = [];
    for (const t of targets) {
      try {
        let code = t.line_code;
        if (!code) {
          code = await genCode(sb);
          await sb.from("users").update({ line_code: code, updated_at: new Date().toISOString() }).eq("id", t.id);
        }
        if (!t.email) { failed.push({ name: t.name, reason: "メールアドレス未登録" }); continue; }
        const lineUrl = `https://line.me/R/oaMessage/${encodeURIComponent(oa)}/?${encodeURIComponent(code)}`;
        const html = `<div style="font-family:sans-serif;max-width:560px;margin:0 auto;line-height:1.8">
          <h2 style="color:#06c755">💚 鳥一代グループ 日報・週報システム</h2>
          <p>${t.name} さん</p>
          <p>お疲れさまです。本部です。<br>
          シフト提出の締切が近いときなどのお知らせをLINEで受け取れるよう、以下のリンクからLINE連携をお願いします。</p>
          <p style="margin:24px 0"><a href="${lineUrl}" style="background:#06c755;color:#fff;padding:12px 24px;border-radius:8px;text-decoration:none;font-weight:bold">💚 LINEで連携する</a></p>
          <p style="font-size:13px;color:#666">・リンクを開くとLINEアプリが起動し、下の合言葉が入力された状態でメッセージが用意されます。そのまま送信してください<br>
          ・リンクが開けない場合は、LINEで下の合言葉を送ってください</p>
          <p style="font-size:24px;font-weight:bold;letter-spacing:4px;text-align:center;margin:16px 0">${code}</p>
          <p style="font-size:12px;color:#999">このメールに心当たりがない場合は破棄してください。管理システム: ${APP_URL}</p>
        </div>`;
        const mres = await fetch("https://api.resend.com/emails", {
          method: "POST",
          headers: { Authorization: `Bearer ${RESEND_KEY}`, "Content-Type": "application/json" },
          body: JSON.stringify({ from: RESEND_FROM, to: t.email, subject: "【鳥一代グループ】LINE連携のお願い", html }),
        });
        if (mres.ok) sent.push({ name: t.name, email: t.email, code });
        else failed.push({ name: t.name, reason: `メール送信エラー(${mres.status})` });
      } catch (e) {
        failed.push({ name: t.name, reason: String(e) });
      }
    }
    return json({ ok: true, sent, sentCount: sent.length, failed, failedCount: failed.length });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
