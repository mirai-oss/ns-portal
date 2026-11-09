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


// 2026-11-08: 通知先を LINE → Slack の人事チャンネル（slack_channels 'hq.jinji' = C0CFE1Y9HC7）へ（ユーザー指示）。notify-slack を service_role で呼ぶ
async function slackHq(text: string, event: string, dedupeKey: string): Promise<{ ok: boolean; error?: string }> {
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  try {
    const res = await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/notify-slack`, {
      method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}`, apikey: key },
      body: JSON.stringify({ action: "send", channel_key: "hq.jinji", event, source: "ef:hr-wage-notify", text: text.slice(0, 3900), dedupe_key: dedupeKey, username: "N-Style 通知Bot", icon_emoji: ":office:" }),
    });
    const j = await res.json().catch(() => null);
    return { ok: !!j?.ok, error: j?.error ?? (res.ok ? undefined : `HTTP ${res.status}`) };
  } catch (e) { return { ok: false, error: String(e).slice(0, 200) }; }
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

    const [{ data: us }, { data: prof }] = await Promise.all([
      sb.from("user_stores").select("stores(name)").eq("user_id", uid),
      sb.from("employee_profiles").select("hire_date").eq("user_id", uid).maybeSingle(),
    ]);
    const storeNames = (us ?? []).map((x: any) => x.stores?.name).filter(Boolean).join("・") || "所属なし";
    const kind = u.role === "AL" ? "アルバイト" : "社員";
    const text =
      `【入社登録】${u.name}さん（${kind}／${storeNames}）が入社登録しました。\n` +
      (prof?.hire_date ? `入社日: ${String(prof.hire_date).replace(/-/g, "/")}\n` : "") +
      `\n賃金（時給・月給）の登録をお願いします: nippo → 従業員管理 → ${u.name}さん → 賃金設定（スマレジに反映されます）。\n` +
      `https://mirai-oss.github.io/nippo/?page=admin&u=${uid}\n` +
      `※Slack 上でそのまま時給を入れられる仕組みは準備中です。`;

    // 2026-11-08: LINE（CEO/HQ 個人・返信で登録）→ Slack 人事チャンネルへ（ユーザー指示）。返信での自動登録は Slack 版を後日
    const s = await slackHq(text, "hr_wage_request", `hr_wage_request:${reqRow.id}`);
    const sent = s.ok ? 1 : 0, failed = s.ok ? 0 : 1;
    await sb.from("hr_wage_requests").update({ notified_at: new Date().toISOString() }).eq("id", reqRow.id);
    return json({ ok: true, sent, failed, recipients: 1, channel: "hq.jinji", error: s.error });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
