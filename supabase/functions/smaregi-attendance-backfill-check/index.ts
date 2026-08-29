// スマレジのスタッフIDを新しく登録した従業員を見つけるEdge Function
// 2026-08-30 担当B新規作成
//
// 位置づけ: ユーザー要望「従業員管理でアルバイトの方をスマレジと紐付け登録したら、
//   その人の過去の勤怠実績を自動でまとめて取得し直したい」への対応。
//   このFunction自体はスマレジAPIを呼ばない（読み取り専用の軽い判定だけ）。
//   実際の過去分取得は既存のsmaregi-attendance-sync（date_from/date_to対応済み・無変更）を
//   .github/workflows/smaregi-attendance-backfill.yml が複数回チャンク呼び出しする。
//
// 呼び出し方:
//   { } （省略）→ まだsf_attendance_backfill_doneに記録の無い人（＝新規登録者）を返す
//   { mark: true } → 現在smaregi_staff_idが設定されている人全員を「バックフィル済み」として記録する
//     （バックフィル実行後にワークフローから呼ぶ）
// 認可: CEO/HQ/マスターのユーザーJWT、またはservice_role直呼び
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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const sb = svc();
    let body: any = {};
    try { body = await req.json(); } catch { /* GET等ボディなし */ }

    const authHeader = req.headers.get("Authorization") ?? "";
    const isServiceRole = authHeader.includes(Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? " ");
    if (!isServiceRole) {
      const uid = jwtUid(req);
      const { data: u } = await sb.from("users").select("role,is_master,is_active").eq("id", uid).maybeSingle();
      if (!u?.is_active || !(u.is_master || ["CEO", "HQ"].includes(u.role))) {
        return json({ ok: false, error: "権限がありません（CEO/HQ/マスターのみ）" }, 403);
      }
    }

    const { data: profs } = await sb.from("employee_profiles").select("user_id,smaregi_staff_id").not("smaregi_staff_id", "is", null);
    const all = profs ?? [];

    if (body.mark === true) {
      if (!all.length) return json({ ok: true, marked: 0 });
      const rows = all.map((p: any) => ({ user_id: p.user_id, smaregi_staff_id: p.smaregi_staff_id, backfilled_at: new Date().toISOString() }));
      const { error } = await sb.from("sf_attendance_backfill_done").upsert(rows, { onConflict: "user_id" });
      if (error) return json({ ok: false, error: error.message }, 500);
      return json({ ok: true, marked: rows.length });
    }

    const { data: done } = await sb.from("sf_attendance_backfill_done").select("user_id");
    const doneSet = new Set((done ?? []).map((r: any) => r.user_id));
    const pending = all.filter((p: any) => !doneSet.has(p.user_id));
    return json({ ok: true, totalLinked: all.length, pendingCount: pending.length, pending });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
