// スポット人件費の申請フォーム（承認制・ログイン不要のURLフォーム）。2026-10-05
// 合言葉（app_secrets.spot_form_token）を知っている人だけが、①店舗・従業員名簿の取得 ②承認待ちの申請の送信ができる。
// 送っただけでは何も変わらない（社長・本部がダッシュボードで承認して初めてPL/日別人件費に反映）。
// 申請者は名簿の実在IDだけ受け付け、名前はサーバー側で引き直す。直近1時間に40件を超えると受け付けない（連打・いたずら防止）。
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });
const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const body = await req.json().catch(() => ({}));
    const sb = svc();
    const { data: sec } = await sb.from("app_secrets").select("value").eq("key", "spot_form_token").maybeSingle();
    const formToken = String(sec?.value ?? "").trim();
    if (!formToken || String(body.token ?? "").trim() !== formToken) return json({ ok: false, error: "unauthorized" }, 401);

    const { data: storeRows } = await sb.from("stores").select("name,sort_order").eq("is_active", true).order("sort_order");
    const stores = (storeRows ?? []).map((s: any) => String(s.name));

    if (body.action === "options") {
      const { data: staff } = await sb.from("users").select("id,name").eq("is_active", true).order("name");
      return json({ ok: true, stores, staff: (staff ?? []).filter((u: any) => String(u.name ?? "").trim()).map((u: any) => ({ id: u.id, name: u.name })) });
    }

    const store = String(body.store ?? "").trim();
    if (!stores.includes(store)) return json({ ok: false, error: "店舗を選んでください" }, 400);
    const date = String(body.date ?? "").trim();
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) return json({ ok: false, error: "日付を選んでください" }, 400);
    const d = new Date(date + "T00:00:00+09:00").getTime(), now = Date.now();
    if (isNaN(d) || d < now - 120 * 86400000 || d > now + 7 * 86400000) return json({ ok: false, error: "日付が範囲外です（過去120日〜1週間先まで）" }, 400);
    const kind = String(body.kind ?? "");
    if (kind !== "タイミー" && kind !== "その他") return json({ ok: false, error: "区分を選んでください" }, 400);
    const amount = Number(body.amount);
    if (!isFinite(amount) || amount <= 0 || amount > 1000000) return json({ ok: false, error: "金額を正しく入力してください（1〜100万円）" }, 400);
    const hcRaw = String(body.headcount ?? "").trim();
    const headcount = hcRaw === "" ? null : Math.round(Number(hcRaw));
    if (headcount !== null && (!isFinite(headcount) || headcount < 0 || headcount > 200)) return json({ ok: false, error: "人数を正しく入力してください" }, 400);
    const note = String(body.note ?? "").trim().slice(0, 200);

    const requesterId = String(body.requesterId ?? "").trim();
    if (!requesterId) return json({ ok: false, error: "申請者を選んでください" }, 400);
    const { data: ru } = await sb.from("users").select("id,name").eq("id", requesterId).eq("is_active", true).maybeSingle();
    if (!ru) return json({ ok: false, error: "申請者が見つかりません。名前を選び直してください" }, 400);

    const since = new Date(now - 3600 * 1000).toISOString();
    const { count } = await sb.from("spot_labor_requests").select("id", { count: "exact", head: true }).gte("submitted_at", since);
    if ((count ?? 0) >= 40) return json({ ok: false, error: "短時間に申請が集中しています。しばらく待ってからお試しください" }, 429);

    const { data: ins, error } = await sb.from("spot_labor_requests")
      .insert({ store_name: store, work_date: date, kind, amount, headcount, note: note || null, requester_id: ru.id, requester_name: ru.name, status: "pending" })
      .select("id").single();
    if (error) return json({ ok: false, error: "保存に失敗しました: " + String(error.message ?? error) }, 500);
    return json({ ok: true, id: ins.id });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
