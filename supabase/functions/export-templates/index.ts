// 担当G: データ出力センター Export Service — テンプレート管理（一覧・差し替えアップロード）
// 実装指示書_担当G_データ出力センター_2026-08-25.md §4
//
// action:'list'   → tpl_templates一覧（export_can_access()があれば誰でも閲覧可）
// action:'upload' → 新しいテンプレートファイル(.xlsx)を登録・バージョンを上げる（export_can_manage_templates()のみ）
//   file_base64でファイル本体を受け取る（テンプレートはデザインのみで数十KB程度のため base64 JSON で十分）
import { createClient } from "npm:@supabase/supabase-js@2";

const cors: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });

const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

function jwtUid(req: Request): string {
  try {
    const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    return JSON.parse(atob(jwt.split(".")[1].replace(/-/g, "+").replace(/_/g, "/"))).sub ?? "";
  } catch (_) { return ""; }
}

function base64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const sb = svc();
    let body: any = {};
    try { body = await req.json(); } catch { /* ボディなし */ }

    const uid = jwtUid(req);
    const { data: u } = await sb.from("users").select("role,is_master,is_active").eq("id", uid).maybeSingle();
    if (!u?.is_active) return json({ ok: false, error: "認証が必要です" }, 401);

    // export_can_access()/export_can_manage_templates()はauth.uid()前提のSQL関数で、
    // service_roleクライアント（ユーザーJWTコンテキストを持たない）からは正しく解決しないため、
    // RPCに頼らずここで直接ロール判定する（export-preview/export-runと同じ理由・同じ方針）。
    const canAccess = !!(u.is_master || ["CEO", "HQ", "TEAM", "TENCHO"].includes(u.role));
    const canManage = !!(u.is_master || ["CEO", "HQ"].includes(u.role));

    const action = String(body.action ?? "list");

    if (action === "list") {
      if (!canAccess) return json({ ok: false, error: "権限がありません" }, 403);
      const { data, error } = await sb.from("tpl_templates").select("*").order("category").order("template_name");
      if (error) return json({ ok: false, error: error.message }, 500);
      return json({ ok: true, templates: data });
    }

    if (action === "upload") {
      if (!canManage) return json({ ok: false, error: "テンプレート管理の権限がありません（マスター/CEO/HQのみ）" }, 403);

      const templateCode = String(body.template_code ?? "").trim();
      const fileBase64 = String(body.file_base64 ?? "");
      const note = String(body.note ?? "");
      if (!templateCode || !fileBase64) return json({ ok: false, error: "template_code / file_base64 は必須です" }, 400);

      const { data: tpl, error: tplErr } = await sb.from("tpl_templates").select("id,version").eq("template_code", templateCode).maybeSingle();
      if (tplErr || !tpl) return json({ ok: false, error: "テンプレートが見つかりません（先にtpl_templatesへ登録してください）" }, 404);

      const newVersion = (tpl.version ?? 1) + 1;
      const bytes = base64ToBytes(fileBase64);
      const filePath = `${templateCode}/v${newVersion}.xlsx`;
      const { error: upErr } = await sb.storage.from("export-templates").upload(filePath, bytes, {
        contentType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        upsert: false,
      });
      if (upErr) return json({ ok: false, error: "アップロードに失敗: " + upErr.message }, 500);

      await sb.from("tpl_template_versions").insert({
        template_id: tpl.id, version: newVersion, file_path: filePath, note, created_by: uid,
      });
      await sb.from("tpl_templates").update({
        file_path: filePath, version: newVersion, updated_by: uid, updated_at: new Date().toISOString(),
      }).eq("id", tpl.id);

      return json({ ok: true, template_id: tpl.id, version: newVersion, file_path: filePath });
    }

    return json({ ok: false, error: "不明なaction" }, 400);
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
