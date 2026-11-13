// =============================================================
// recruit-notify — 採用管理の Slack 通知の入口（2026-11-16 下書き・★ 未デプロイ ★）
//   設計: scratchpad rc1/設計_採用管理のSlack通知.md ／ DB 側: supabase/2026-11-16_recruit_notice.sql
//
// 役割: 応募者に出来事があったとき（DB のトリガーが pg_net で呼ぶ）、その応募者の「いまの状態」を読んで Slack を合わせる。
//       ・親メッセージが無ければ作る（応募者 1 人につき 1 件だけ）
//       ・状態が変わっていれば、親と、スレッド 1 通目のカードを書き換える
//       ・対応が要る出来事（応募者からの返信・面接日程の確定依頼など）と、経過の記録を、スレッドに返信する
//   送信は notify-slack 経由（Bot Token はここでは投稿に使わない。スレッドへのリンクの取得にだけ使う）。
//   電話番号・メールアドレスは文面に入れない。応募者へは何も送らない（Slack へ出すだけ）。
//
// 入力（POST・JSON）:
//   { "op": "event", "applicant_id": "<uuid>", "kind": "created|updated|message|merged|deleted|onboarding|sweep", "ref": "<メッセージの id など・任意>" }
//   { "op": "health" }
//   ※ kind は目印（ログ用と、渡されたメッセージを必ず見るため）。何を書くかは、DB のいまの状態と控え（notice_cases）の差で決める。
//      だから、同じ出来事が二度届いても、通信エラーでやり直しても、二度は書かない。
//   ※ 過去の応募者をまとめて流し込む処理（backfill）は作っていない。
//
// 認証（どちらか）: Authorization: Bearer <service_role キー> ／ x-notify-secret: <NOTIFY_SLACK_SECRET>（DB の pg_net から）
// スイッチ: app_settings.recruit_slack.enabled が true のときだけ動く（既定 false。false のあいだは、呼ばれても何もしない）
// デプロイ（承認のあと）: supabase functions deploy recruit-notify --no-verify-jwt --project-ref uuvsxzhpxtghojoubjcc --yes
// =============================================================
import { createClient } from "npm:@supabase/supabase-js@2";
import { handleEvent, NOTICE_TYPE, REF_TABLE, type Applicant, type Cfg, type Db, type Msg, type NotifyResult, type Onboarding, type Refs } from "../_shared/recruit-notice.ts";

const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json" } });
const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

function timingSafeEqual(a: string, b: string) {
  if (a.length !== b.length) return false;
  let r = 0; for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}
function authorized(req: Request): boolean {
  const key = (Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "").trim();
  const auth = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (key && auth && timingSafeEqual(auth, key)) return true;
  const secret = (Deno.env.get("NOTIFY_SLACK_SECRET") ?? "").trim();
  const hdr = (req.headers.get("x-notify-secret") ?? "").trim();
  return !!(secret && hdr && timingSafeEqual(secret, hdr));
}
/** 送信の出口は notify-slack だけ（台帳 notification_deliveries に 1 通ずつ残る） */
async function sendSlack(body: Record<string, unknown>): Promise<NotifyResult> {
  try {
    const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    const res = await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/notify-slack`, {
      method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}`, apikey: key },
      body: JSON.stringify(body), signal: AbortSignal.timeout(20000),
    });
    return await res.json().catch(() => ({ ok: false, error: "notify-slack の応答を読めません" }));
  } catch (e) {
    return { ok: false, error: "notify-slack を呼べません: " + String((e as Error)?.message ?? e).slice(0, 120) };
  }
}

// deno-lint-ignore no-explicit-any
function makeDb(sb: any): Db {
  const caseQ = (id: string) => sb.from("notice_cases").select("slack_refs").eq("type_key", NOTICE_TYPE).eq("ref_table", REF_TABLE).eq("ref_id", id).maybeSingle();
  return {
    async settings(): Promise<Cfg> {
      const { data } = await sb.from("app_settings").select("value").eq("key", "recruit_slack").maybeSingle();
      const v = (data?.value ?? {}) as Record<string, unknown>;
      const n = Number(v.body_chars);
      // 2026-11-27 応募者への送信のスイッチ（別の設定 recruit_actions。ボタンを出しているときだけ読む。無い・読めない・true 以外は false＝実在の応募者のカードに、送るボタンを出さない）
      //   面接のボタンは、さらに、カレンダーが本番モード（calendar_mode = live）のときだけ、実在の応募者のカードに出す（RPC が通す条件と同じ）
      let sendEnabled = false, interviewEnabled = false;
      if (v.actions_enabled === true) {
        const { data: ra } = await sb.from("app_settings").select("value").eq("key", "recruit_actions").maybeSingle();
        const rv = (ra?.value ?? {}) as Record<string, unknown>;
        sendEnabled = rv.send_enabled === true;
        interviewEnabled = sendEnabled && rv.calendar_mode === "live";
      }
      return { enabled: v.enabled === true, since: typeof v.since === "string" ? v.since : null, channelKey: typeof v.channel_key === "string" && v.channel_key ? v.channel_key : "hr.saiyo", bodyChars: Number.isFinite(n) ? Math.max(0, Math.min(500, n)) : 200,
        actionsEnabled: v.actions_enabled === true, sendEnabled, interviewEnabled };   // 2026-11-26 カードに［担当者を変更］を出すか（既定 false。true 以外は、今までのカードと同じ）
    },
    async applicant(id) {
      // 列の増減に強くするため * で読む。文面に使うのは recruit-notice.ts の Applicant にある列だけ（電話・メールは使わない）
      const { data, error } = await sb.from("applicants").select("*").eq("id", id).maybeSingle();
      if (error) throw new Error("applicants: " + error.message);
      return (data ?? null) as Applicant | null;
    },
    async caseOf(id) {
      const { data, error } = await caseQ(id);
      if (error) throw new Error("notice_cases: " + error.message);
      return data ? { refs: (data.slack_refs ?? {}) as Refs } : null;
    },
    async lock(id, token) {
      const { data, error } = await sb.rpc("recruit_notice_lock", { p_applicant: id, p_token: token });
      if (error) throw new Error("recruit_notice_lock: " + error.message);
      return data === true;
    },
    async unlock(id, token) {
      const { data, error } = await sb.rpc("recruit_notice_unlock", { p_applicant: id, p_token: token });
      if (error) throw new Error("recruit_notice_unlock: " + error.message);
      return data === true;
    },
    async claim(id) {
      const { data, error } = await sb.rpc("recruit_notice_claim", { p_applicant: id });
      if (error) throw new Error("recruit_notice_claim: " + error.message);
      return data === true;
    },
    async merge(keepId, mergedId) {
      const { data, error } = await sb.rpc("recruit_notice_merge", { p_keep: keepId, p_merged: mergedId });
      if (error) throw new Error("recruit_notice_merge: " + error.message);
      return data === true;
    },
    async saveCase(id, patch) {
      const { error } = await sb.rpc("notice_case_upsert", { p_type: NOTICE_TYPE, p_ref_table: REF_TABLE, p_ref_id: id, p_patch: patch });
      return error ? String(error.message ?? error) : null;
    },
    async names(ids) {
      if (!ids.length) return {};
      const { data } = await sb.from("users").select("id,name").in("id", ids);
      return Object.fromEntries(((data ?? []) as { id: string; name: string }[]).map((u) => [u.id, u.name]));
    },
    async storeName(id) {
      const { data } = await sb.from("stores").select("name").eq("id", id).maybeSingle();
      return data?.name ?? null;
    },
    async onboarding(applicantId) {
      // 入社登録（既存の流れ）の控え。応募者 1 人に 1 行（onboarding_workflows_applicant_uq）。読むだけ
      const { data, error } = await sb.from("onboarding_workflows").select("id,status,user_id,slack_channel_id,slack_parent_ts").eq("applicant_id", applicantId).maybeSingle();
      return error ? null : ((data ?? null) as Onboarding | null);
    },
    async messages(applicantId, sinceIso, extraId) {
      const cols = "id,applicant_id,channel,direction,body,sent_at,sent_by";
      const { data, error } = await sb.from("applicant_messages").select(cols).eq("applicant_id", applicantId).gte("sent_at", sinceIso).order("sent_at", { ascending: true }).limit(30);
      if (error) throw new Error("applicant_messages: " + error.message);
      const list = (data ?? []) as (Msg & { applicant_id: string })[];
      if (extraId && !list.some((m) => m.id === extraId)) {
        const { data: one } = await sb.from("applicant_messages").select(cols).eq("id", extraId).eq("applicant_id", applicantId).maybeSingle();
        if (one) list.unshift(one);
      }
      return list;
    },
    async delivered(keys) {
      if (!keys.length) return new Set<string>();
      const { data, error } = await sb.from("notification_deliveries").select("dedupe_key").in("dedupe_key", keys).in("delivery_status", ["sent", "updated"]);
      if (error) throw new Error("notification_deliveries: " + error.message);
      return new Set(((data ?? []) as { dedupe_key: string }[]).map((r) => r.dedupe_key));
    },
    async mentions(scene, storeId, assignees) {
      const { data, error } = await sb.rpc("notice_mention_targets", { p_type: NOTICE_TYPE, p_scene: scene, p_store: storeId, p_task_assignees: assignees });
      if (error) return [];
      return (((data?.targets ?? []) as { slack_user_id?: string }[]).map((x) => String(x.slack_user_id ?? "")).filter(Boolean));
    },
    async permalink(channelId, ts) {
      const token = Deno.env.get("SLACK_BOT_TOKEN");
      if (!token) return null;
      try {
        const res = await fetch(`https://slack.com/api/chat.getPermalink?channel=${encodeURIComponent(channelId)}&message_ts=${encodeURIComponent(ts)}`, { headers: { Authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(10000) });
        const j = await res.json();
        return j?.ok && typeof j.permalink === "string" && j.permalink.startsWith("https://") ? j.permalink : null;
      } catch (_e) { return null; }
    },
  };
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ ok: false, error: "POSTのみ" }, 405);
  if (!authorized(req)) return json({ ok: false, error: "認証エラー" }, 401);
  // deno-lint-ignore no-explicit-any
  let b: any = {};
  try { b = await req.json(); } catch (_e) { return json({ ok: false, error: "JSONを読めません" }, 400); }
  const db = makeDb(svc());
  try {
    switch (b?.op) {
      case "health": {
        const cfg = await db.settings();
        return json({ ok: true, enabled: cfg.enabled, since_set: !!cfg.since, channel_key: cfg.channelKey });
      }
      case "event": {
        // 2026-11-12 通しの確認用: test=true は、使い捨ての応募者（answers._test が true）に限り、本番のスイッチが OFF でも動かす。
        //   実在の応募者には効かない（_test の印が無ければ断る）。メンションはしない（実在の担当者を呼ばないため）。
        let d: Db = db;
        if (b.test === true) {
          const a = await db.applicant(String(b.applicant_id ?? ""));
          // deno-lint-ignore no-explicit-any
          if (!a || (a as any).answers?._test !== true) return json({ ok: false, error: "テスト用の応募者ではありません" }, 400);
          const base = await db.settings();
          d = { ...db, settings: () => Promise.resolve({ ...base, enabled: true, since: "2026-11-12T00:00:00Z" }), mentions: () => Promise.resolve([]) };
        }
        const r = await handleEvent(d, sendSlack, String(b.applicant_id ?? ""), { kind: typeof b.kind === "string" ? b.kind : undefined, ref: typeof b.ref === "string" ? b.ref : null, source: "ef:recruit-notify" });
        // 返事には氏名などを入れない（pg_net の応答の控え net._http_response に残るため）
        return json(r, r.ok ? 200 : 500);
      }
      default: return json({ ok: false, error: "不明な op" }, 400);
    }
  } catch (e) {
    return json({ ok: false, error: String((e as Error)?.message ?? e).slice(0, 300) }, 500);
  }
});
