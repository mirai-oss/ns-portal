// 退職申請が出されたとき、対応する本部・社長・マスター・チーム長（LINE連携済み）へLINEで知らせる（担当B・2026-10-03新設）
//   body: { request_id }。ログイン不要（申請フォームはログインしないため）。
//   安全策: ①承認待ち・直近10分以内の申請だけ ②1申請につき1回だけ（DBのline_notified_atで取り合い＝連打・再送で何度も飛ばない）
//   ③文面はDB側の情報だけで組み立てる（呼び出し元から文面は受け取らない）④宛先は hr_claim_retire_notify（service_role専用RPC）が決める
//   宛先: マスター・社長(CEO)・本部(HQ)は全店舗／チーム長(TEAM)は担当チームの店舗＋自分の所属店舗＝その申請の店舗に関係する人だけ
import { createClient } from "npm:@supabase/supabase-js@2";

const cors: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });

const APP_URL = "https://mirai-oss.github.io/nippo/?page=admin&m=retire";


// 2026-11-08: 通知先を LINE → Slack の人事チャンネル（slack_channels 'hq.jinji' = C0CFE1Y9HC7）へ（ユーザー指示）。notify-slack を service_role で呼ぶ
async function slackHq(text: string, event: string, dedupeKey: string): Promise<{ ok: boolean; error?: string }> {
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  try {
    const res = await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/notify-slack`, {
      method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}`, apikey: key },
      body: JSON.stringify({ action: "send", channel_key: "hq.jinji", event, source: "ef:hr-retire-notify", text: text.slice(0, 3900), dedupe_key: dedupeKey, username: "N-Style 通知Bot", icon_emoji: ":office:" }),
    });
    const j = await res.json().catch(() => null);
    return { ok: !!j?.ok, error: j?.error ?? (res.ok ? undefined : `HTTP ${res.status}`) };
  } catch (e) { return { ok: false, error: String(e).slice(0, 200) }; }
}
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const body = await req.json().catch(() => ({}));
    const requestId = String(body.request_id ?? "");
    if (!/^[0-9a-f-]{36}$/i.test(requestId)) return json({ ok: false, error: "request_id が不正です" }, 400);

    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: claim, error } = await sb.rpc("hr_claim_retire_notify", { p_request: requestId });
    if (error) return json({ ok: false, error: error.message }, 500);
    if (!claim || !claim.claimed) return json({ ok: true, skipped: claim?.reason ?? "対象外" });

    const d = String(claim.effective_date ?? "").replace(/-/g, "/");
    const text =
      `【退職申請】${claim.store_name}\n` +
      `${claim.user_name}さん（退職日 ${d}）の退職申請が出ました。\n` +
      `申請者: ${claim.requester || "—"}\n` +
      (claim.note ? `備考: ${claim.note}\n` : "") +
      `\n退職申請一覧で確認・承認してください。\n${APP_URL}`;

    // 2026-11-08: LINE（承認者個人）→ Slack 人事チャンネルへ（ユーザー指示）。Slack 上での承認ボタンは後日
    const s = await slackHq(text, "hr_retire_request", `hr_retire_request:${requestId}`);
    return json({ ok: true, sent: s.ok ? 1 : 0, failed: s.ok ? 0 : 1, channel: "hq.jinji", error: s.error });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
