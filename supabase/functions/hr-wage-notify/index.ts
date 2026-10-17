// 入社登録のあと、本部・社長・マスター（LINE連携済み）へ「賃金を返信してください」とLINEで通知する（担当B・2026-10-17新設）
//   body: { user_id }（入社した人）。入社登録の完了時にnippoから呼ばれる（本人の画面・本部が代理で発行した画面のどちらも）。ログイン不要（verify_jwt無し）。
//   安全策: ①1人につき1回だけ（hr_wage_requests.user_id が一意）②この3日以内に作成されたアカウントだけ ③既に賃金設定がある人は対象外
//           ④文面はDBの情報だけで組み立てる ⑤宛先は users.line_user_id 連携済みの 本部(HQ)・社長(CEO)・マスター だけ
//   通知したLINEメッセージのIDを hr_wage_request_msgs に保存（「返信（引用）」でどの人か判定するため）。
//   ※将来、通知先をSlack等に統一する可能性あり（ユーザー明言）→ 送信は send() 1か所にまとめてある
import { createClient } from "npm:@supabase/supabase-js@2";

const cors: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });

// 通知の送信（現在はLINE push）。戻り値=相手ごとのメッセージID
async function send(token: string, to: string, text: string): Promise<{ ok: boolean; messageId: string | null }> {
  const res = await fetch("https://api.line.me/v2/bot/message/push", {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ to, messages: [{ type: "text", text: text.slice(0, 4900) }] }),
  });
  if (!res.ok) return { ok: false, messageId: null };
  const j = await res.json().catch(() => ({}));
  return { ok: true, messageId: j?.sentMessages?.[0]?.id ?? null };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const body = await req.json().catch(() => ({}));
    const uid = String(body.user_id ?? "");
    if (!/^[0-9a-f-]{36}$/i.test(uid)) return json({ ok: false, error: "user_id が不正です" }, 400);
    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

    const { data: u } = await sb.from("users").select("id,name,role,is_active,created_at").eq("id", uid).maybeSingle();
    if (!u || !u.is_active) return json({ ok: true, skipped: "対象外（無効・存在しない）" });
    if (Date.now() - new Date(u.created_at).getTime() > 3 * 86400e3) return json({ ok: true, skipped: "対象外（作成から3日を超えています）" });
    const { count: wc } = await sb.from("employee_wage_settings").select("id", { count: "exact", head: true }).eq("user_id", uid);
    if ((wc ?? 0) > 0) return json({ ok: true, skipped: "賃金設定が既にあります" });

    // 1人1回（一意制約で取り合い）
    const { data: reqRow, error: ie } = await sb.from("hr_wage_requests").insert({ user_id: uid }).select("id").maybeSingle();
    if (ie || !reqRow) return json({ ok: true, skipped: "通知済み" });

    const { data: sec } = await sb.from("app_secrets").select("key,value").eq("key", "line_channel_token").maybeSingle();
    const token = (sec?.value ?? "").trim();
    if (!token) return json({ ok: false, error: "line_channel_token未設定" }, 500);

    const [{ data: us }, { data: prof }, { data: recips }] = await Promise.all([
      sb.from("user_stores").select("stores(name)").eq("user_id", uid),
      sb.from("employee_profiles").select("hire_date").eq("user_id", uid).maybeSingle(),
      sb.from("users").select("id,line_user_id,name").eq("is_active", true).not("line_user_id", "is", null).or("is_master.eq.true,role.in.(CEO,HQ)"),
    ]);
    const storeNames = (us ?? []).map((x: any) => x.stores?.name).filter(Boolean).join("・") || "所属なし";
    const kind = u.role === "AL" ? "アルバイト" : "社員";
    const text =
      `【入社登録】${u.name}さん（${kind}／${storeNames}）が入社登録しました。\n` +
      (prof?.hire_date ? `入社日: ${String(prof.hire_date).replace(/-/g, "/")}\n` : "") +
      `\n賃金を、このメッセージに返信してください（スマレジに自動で登録します）。\n` +
      `例:\n・時給 1200\n・時給 1200 休日 1300\n・月給 250000\n・新橋 1400（その店舗だけの時給）\n` +
      `\n※複数の方が待ちのときは、このメッセージを長押し→「返信」するか、先頭に名前を付けてください。`;

    let sent = 0, failed = 0;
    for (const r of recips ?? []) {
      const s = await send(token, r.line_user_id, text);
      if (s.ok) {
        sent++;
        await sb.from("hr_wage_request_msgs").upsert({ request_id: reqRow.id, line_user_id: r.line_user_id, message_id: s.messageId });
      } else failed++;
    }
    await sb.from("hr_wage_requests").update({ notified_at: new Date().toISOString() }).eq("id", reqRow.id);
    return json({ ok: true, sent, failed, recipients: (recips ?? []).length });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
