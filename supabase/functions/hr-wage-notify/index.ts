// 入社登録のあと、本部へ「賃金の登録」を知らせる入口（担当B・2026-10-17新設。nippo の hqNotifyOnboarding から呼ばれる）
//   body: { user_id }（入社した人）。本人の画面・本部が代理で発行した画面のどちらからも。ログイン不要（verify_jwt無し）。
//   履歴: 2026-10-17 LINE（本部・社長・マスター個人へ。返信で登録）→ 2026-11-08 Slack 人事チャンネル hq.jinji へ文面だけ
//         → 2026-11-09 Phase 1: 入社ワークフロー（EF onboarding-notify op=open＝親メッセージ＋スレッド＋「💴 賃金を設定」ボタン）へ段階的に切替。
//   切替フラグ app_settings.onboarding_slack（SQL 2026-11-09_onboarding_phase1.sql で既定 {enabled:false, legacy_wage_text:true}）:
//     enabled=true          → onboarding-notify op=open を呼ぶ（ワークフロー行＋親メッセージ。冪等）
//     legacy_wage_text=true → 従来の「賃金登録をお願いします（準備中）」の文面も送る（両方 true の間は 2 通＝動作確認期間だけ）
//   既定（両方の列が無い＝SQL 未適用）は従来どおりの文面だけ。
//   安全策（従来どおり）: ①有効なアカウントだけ ②作成から 3 日以内 ③文面は DB の情報だけ ④従来文面は 1 人 1 回（hr_wage_requests.user_id 一意）
import { createClient } from "npm:@supabase/supabase-js@2";

const cors: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// 従来文面: Slack の人事チャンネル（slack_channels 'hq.jinji' = C0CFE1Y9HC7）へ。notify-slack を service_role で呼ぶ
async function slackHq(text: string, event: string, dedupeKey: string): Promise<{ ok: boolean; error?: string }> {
  try {
    const res = await fetch(`${SUPABASE_URL}/functions/v1/notify-slack`, {
      method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${SERVICE_KEY}`, apikey: SERVICE_KEY },
      body: JSON.stringify({ action: "send", channel_key: "hq.jinji", event, source: "ef:hr-wage-notify", text: text.slice(0, 3900), dedupe_key: dedupeKey, username: "N-Style 通知Bot", icon_emoji: ":office:" }),
    });
    const j = await res.json().catch(() => null);
    return { ok: !!j?.ok, error: j?.error ?? (res.ok ? undefined : `HTTP ${res.status}`) };
  } catch (e) { return { ok: false, error: String(e).slice(0, 200) }; }
}
// 新: 入社ワークフロー（親メッセージ＋スレッド）。EF onboarding-notify op=open（冪等）
async function onboardingOpen(uid: string): Promise<{ ok: boolean; error?: string; workflow_id?: string }> {
  try {
    const res = await fetch(`${SUPABASE_URL}/functions/v1/onboarding-notify`, {
      method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${SERVICE_KEY}`, apikey: SERVICE_KEY },
      body: JSON.stringify({ op: "open", user_id: uid, source: "nippo" }),
    });
    const j = await res.json().catch(() => null);
    return { ok: !!j?.ok, error: j?.error ?? (res.ok ? undefined : `HTTP ${res.status}`), workflow_id: j?.workflow_id };
  } catch (e) { return { ok: false, error: String(e).slice(0, 200) }; }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const body = await req.json().catch(() => ({}));
    const uid = String(body.user_id ?? "");
    if (!/^[0-9a-f-]{36}$/i.test(uid)) return json({ ok: false, error: "user_id が不正です" }, 400);
    const sb = createClient(SUPABASE_URL, SERVICE_KEY);

    const { data: u } = await sb.from("users").select("id,name,role,is_active,created_at").eq("id", uid).maybeSingle();
    if (!u || !u.is_active) return json({ ok: true, skipped: "対象外（無効・存在しない）" });
    if (Date.now() - new Date(u.created_at).getTime() > 3 * 86400e3) return json({ ok: true, skipped: "対象外（作成から3日を超えています）" });

    // 切替フラグ（無ければ従来どおり）
    const { data: cfg } = await sb.from("app_settings").select("value").eq("key", "onboarding_slack").maybeSingle();
    const enabled = cfg?.value?.enabled === true;
    const legacy = cfg?.value?.legacy_wage_text !== false;

    const out: Record<string, unknown> = { ok: true, enabled, legacy };
    if (enabled) {
      const r = await onboardingOpen(uid);
      out.workflow = r;
    }
    if (!legacy) return json(out);

    // ---- 従来文面（段階的切替が終わるまで）----
    const { count: wc } = await sb.from("employee_wage_settings").select("id", { count: "exact", head: true }).eq("user_id", uid);
    if ((wc ?? 0) > 0) return json({ ...out, skipped: "賃金設定が既にあります" });
    // 1人1回（一意制約で取り合い）
    const { data: reqRow, error: ie } = await sb.from("hr_wage_requests").insert({ user_id: uid }).select("id").maybeSingle();
    if (ie || !reqRow) return json({ ...out, skipped: "通知済み" });

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
      (enabled ? `※この上の「入社登録：${u.name}さん」のメッセージから Slack 上で賃金を入れられます。` : `※Slack 上でそのまま時給を入れられる仕組みは準備中です。`);

    const s = await slackHq(text, "hr_wage_request", `hr_wage_request:${reqRow.id}`);
    await sb.from("hr_wage_requests").update({ notified_at: new Date().toISOString() }).eq("id", reqRow.id);
    return json({ ...out, sent: s.ok ? 1 : 0, failed: s.ok ? 0 : 1, recipients: 1, channel: "hq.jinji", error: s.error });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
