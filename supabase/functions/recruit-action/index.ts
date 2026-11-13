// =============================================================
// recruit-action — 採用管理の「共通の操作」の入口（2026-11-27 下書き・★ 未デプロイ ★）
//   設計: docs/設計書_採用_面接確定とLINEのSlack操作_2026-11-13.md §2 ／ DB 側: supabase/2026-11-27_recruit_outbox.sql
//
// 役割: 管理システムの画面と Slack（slack-interact）が、同じ処理を呼ぶための入口。中身は _shared/recruit-ops.ts。
//   op=message_check … 応募者へ送ってよいかの確認（何も書かない・何も送らない）
//   op=message_send  … 応募者へ LINE を 1 通（送信箱 → 本番モードのときだけ LINE → 結果の記録）
//   op=interview_confirm … 面接の確定・変更（予定と Meet → 確定の保存 → 案内の LINE。いまの画面と同じ順番。DB 側: supabase/2026-11-28_recruit_interview.sql）
//   op=interview_cancel  … 面接の取り消し（予定を消す → 日時などを空に。応募者へは送らない）
//   op=message_retry_info / message_retry … LINE の送信失敗・結果不明の送り直し（人が確かめてから。同じ行・同じ再送の鍵。DB 側: supabase/2026-11-29_recruit_alerts.sql）
//   op=calendar_retry    … カレンダーの登録のやり直し（面接の確定は、そのまま）
//   op=alerts_scan       … 24 時間の未対応 → 予備の担当への知らせ（定期実行から。スイッチ recruit_actions.alerts_enabled と、予備の担当の設定がそろうまで、何もしない。担当者は変えない）
//   op=hire_info / hire … 採用を決める（既存の採用の処理 hire_applicant を、RPC recruit_hire が、押した人の操作として呼ぶ。招待の LINE は送信箱を通す。DB 側: supabase/2026-11-30_recruit_hire.sql）
//   op=health        … 設定の確認
//
// 外へ出るもの（どちらも、設定が既定のままなら出ない）:
//   ・LINE: 送信箱の RPC が「送ってよい」と答えたときだけ。既定は試しモード（app_settings.recruit_actions.line_mode = dry）＝呼ばない。
//           送信のスイッチ（send_enabled）が false のあいだは、テスト用の応募者（answers._test = true）以外を RPC が断る。
//   ・カレンダー（GAS）: 既定は試しモード（app_settings.recruit_actions.calendar_mode = dry）＝呼ばない。
//           実在の応募者の面接の操作は、送信のスイッチが true、かつ、カレンダーが本番モードのときだけ RPC が通す。GAS の URL・合言葉は DB の app_secrets（gas_url / gas_key / gas_cal）
//   ・Slack: 試しモード・失敗・結果不明のとき、その応募者のスレッドに 1 行（notify-slack 経由。スレッドが無ければ何もしない）。
//
// 認証（どちらか）:
//   ① Authorization: Bearer <service_role キー> … Edge Function（slack-interact）から。body の actor_id（管理システムの利用者 id）と via を、操作者として使う
//   ② Authorization: Bearer <ログインしている人のトークン> … 管理システムの画面から。トークンを Supabase に問い合わせて確かめ、その本人を操作者にする（body の actor_id は見ない）
//   ③ x-notify-secret: <NOTIFY_SLACK_SECRET> … DB の定期実行（pg_net）から。使えるのは op=alerts_scan だけ（操作者なし＝自動）
//   どちらの場合も、採用の権限・応募者の店舗は、RPC（サーバー側）が確かめる。
// デプロイ（承認のあと）: supabase functions deploy recruit-action --no-verify-jwt --project-ref uuvsxzhpxtghojoubjcc --yes
// =============================================================
import { createClient } from "npm:@supabase/supabase-js@2";
import { alertsScan, handleOp, type OpsActor, type OpsDeps } from "../_shared/recruit-ops.ts";
import { linePushOnce } from "../_shared/recruit-line.ts";
import { gasDelete, gasMeet } from "../_shared/recruit-calendar.ts";
import { NOTICE_TYPE, REF_TABLE, uuidFrom } from "../_shared/recruit-notice.ts";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info" };
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });
const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const isUuid = (s: unknown): s is string => typeof s === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s);

function timingSafeEqual(a: string, b: string) {
  if (a.length !== b.length) return false;
  let r = 0; for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}
/** だれの操作か。service_role なら body の actor_id、そうでなければ、トークンを確かめて、その本人 */
// deno-lint-ignore no-explicit-any
async function resolveActor(req: Request, sb: any, body: any): Promise<OpsActor | null> {
  const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!token) return null;
  const key = (Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "").trim();
  if (key && timingSafeEqual(token, key)) {
    if (!isUuid(body?.actor_id)) return null;
    return { user_id: body.actor_id, via: body?.via === "web" || body?.via === "app" ? body.via : "slack" };
  }
  try {
    const { data, error } = await sb.auth.getUser(token);   // Supabase に問い合わせて、トークンが本物かを確かめる（中身を読むだけ、にはしない）
    if (error || !isUuid(data?.user?.id)) return null;
    return { user_id: data.user.id, via: "web" };
  } catch (_e) { return null; }
}

// deno-lint-ignore no-explicit-any
function makeDeps(sb: any): OpsDeps {
  // notify-slack を呼ぶ（送信は、いつもここ経由＝台帳に残る・同じ鍵は二度送らない）
  // deno-lint-ignore no-explicit-any
  const notifySlack = async (body: Record<string, unknown>): Promise<any> => {
    try {
      const skey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
      const res = await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/notify-slack`, {
        method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${skey}`, apikey: skey }, body: JSON.stringify(body), signal: AbortSignal.timeout(15000),
      });
      return await res.json().catch(() => null);
    } catch (_e) { return null; }
  };
  // その応募者の親（スレッド）があるときだけ、そこへ 1 行
  const post = async (applicantId: string, key: string, text: string, blocks?: unknown[]): Promise<"sent" | "duplicate" | "no_thread" | "failed"> => {
    const { data: c } = await sb.from("notice_cases").select("slack_refs").eq("type_key", NOTICE_TYPE).eq("ref_table", REF_TABLE).eq("ref_id", applicantId).maybeSingle();
    const refs = (c?.slack_refs ?? {}) as { ts?: string; channel_key?: string; tombstone?: boolean; merged_into?: string };
    if (!refs.ts || !refs.channel_key || refs.tombstone || refs.merged_into) return "no_thread";
    const r = await notifySlack({ action: "send", notification_id: await uuidFrom(key), channel_key: refs.channel_key, thread_ts: refs.ts, text, ...(blocks ? { blocks } : {}), event: "recruit_action_result",
      dedupe_key: key, ref: { table: REF_TABLE, id: applicantId }, source: "ef:recruit-action", username: "採用管理", icon_emoji: ":bust_in_silhouette:" });
    return r?.ok ? (r.status === "duplicate" ? "duplicate" : "sent") : "failed";
  };
  return {
    async rpc(name, args) {
      const { data, error } = await sb.rpc(name, args);
      return { data, error: error ? { message: String(error.message ?? error) } : null };
    },
    async lineToken() {
      const { data } = await sb.from("app_secrets").select("value").eq("key", "line_channel_token").maybeSingle();
      return String(data?.value ?? "").trim();
    },
    linePush: (token, to, text, retryKey) => linePushOnce(token, to, text, retryKey),
    calendar: {
      async config() {
        const { data } = await sb.from("app_secrets").select("key,value").in("key", ["gas_url", "gas_key", "gas_cal"]);
        const m: Record<string, string> = {};
        for (const r of (data ?? []) as { key: string; value: string | null }[]) m[r.key] = String(r.value ?? "").trim();
        return m.gas_url ? { url: m.gas_url, key: m.gas_key ?? "", cal: m.gas_cal || "primary" } : null;
      },
      meet: (cfg, a) => gasMeet(cfg, a),
      remove: (cfg, eventId) => gasDelete(cfg, eventId),
    },
    async bodyChars() {
      const { data } = await sb.from("app_settings").select("value").eq("key", "recruit_slack").maybeSingle();
      const n = Number(data?.value?.body_chars);
      return Number.isFinite(n) ? Math.max(0, Math.min(500, n)) : 200;
    },
    async threadNote(applicantId, key, text, blocks) { await post(applicantId, key, text, blocks); },
    threadPost: (applicantId, key, text) => post(applicantId, key, text),
    async noteUpdate(key, text) {
      // すでに出した 1 行を書き換える（ボタンを外す）。台帳の番号は、鍵から決まる。出していなければ、notify-slack が「無い」と答えるだけ
      await notifySlack({ action: "update", notification_id: await uuidFrom(key), text, blocks: [{ type: "section", text: { type: "mrkdwn", text } }] });
    },
    async people(ids) {
      const [{ data: us }, { data: sl }] = await Promise.all([sb.from("users").select("id,name").in("id", ids), sb.from("user_slack").select("user_id,slack_user_id").in("user_id", ids)]);
      const out: Record<string, { name: string | null; slack: string | null }> = {};
      for (const u of (us ?? []) as { id: string; name: string | null }[]) out[u.id] = { name: u.name ?? null, slack: null };
      for (const l of (sl ?? []) as { user_id: string; slack_user_id: string | null }[]) if (out[l.user_id]) out[l.user_id].slack = l.slack_user_id ?? null;
      return out;
    },
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ ok: false, code: "method", message: "POSTのみ" }, 405);
  // deno-lint-ignore no-explicit-any
  let b: any = {};
  try { b = await req.json(); } catch (_e) { return json({ ok: false, code: "bad_request", message: "JSONを読めません" }, 400); }
  const sb = svc();
  // DB の定期実行から（x-notify-secret）: 24 時間の未対応の見回りだけ。ほかの op は、この鍵では受けない
  const secret = (Deno.env.get("NOTIFY_SLACK_SECRET") ?? "").trim(), given = (req.headers.get("x-notify-secret") ?? "").trim();
  const bearer = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim(), skey0 = (Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "").trim();
  if (b?.op === "alerts_scan") {
    const bySecret = !!secret && !!given && timingSafeEqual(secret, given), byService = !!skey0 && !!bearer && timingSafeEqual(bearer, skey0);
    if (!bySecret && !byService) return json({ ok: false, code: "unauthorized", message: "認証エラー" }, 401);
    try {
      // テスト用の応募者を含めるのは、service_role から呼んだときだけ（定期実行は、いつも含めない）
      const r = await alertsScan(makeDeps(sb), { include_test: byService && b?.include_test === true, limit: b?.limit });
      return json(r, 200);   // 返事には、件数だけ（氏名などは入れない。pg_net の応答の控えに残るため）
    } catch (e) { return json({ ok: false, code: "error", message: String((e as Error)?.message ?? e).slice(0, 200) }, 500); }
  }
  const actor = await resolveActor(req, sb, b);
  if (!actor) return json({ ok: false, code: "unauthorized", message: "ログインが必要です" }, 401);
  try {
    if (b?.op === "health") {
      const { data } = await sb.rpc("recruit_actions_cfg");
      return json({ ok: true, code: "health", cfg: data ?? null });
    }
    const r = await handleOp(makeDeps(sb), actor, b);
    // 返事には、LINE の宛先・本文を入れない（recruit-ops が返す値は、状態と短い説明だけ）
    return json(r, r.code === "bad_request" || r.code === "unknown_op" ? 400 : 200);
  } catch (e) {
    return json({ ok: false, code: "error", message: String((e as Error)?.message ?? e).slice(0, 200) }, 500);
  }
});
