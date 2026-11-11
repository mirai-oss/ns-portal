// Slack 送信ヘルパー（Slack通知基盤 Phase 2・2026-11-04）
// Edge Function からは Slack の Bot Token を直接使わず、送信専用の Edge Function notify-slack に
// 合言葉 NOTIFY_SLACK_SECRET（プロジェクトの secrets。無ければ app_secrets.notify_slack_secret）で
// channel_key＋本文を渡す。1通ごとに台帳 notification_deliveries に残る。
// 送信失敗で throw しない（本処理を止めない）。設計: docs/設計書_Slack通知基盤_Phase1_2026-10-29.md §4
export type SlackPostOpts = { event?: string; source?: string; username?: string; icon_emoji?: string; dedupe_key?: string };

export async function slackPost(sb: any, channelKey: string, text: string, opts: SlackPostOpts = {}): Promise<boolean> {
  try {
    let secret = (Deno.env.get("NOTIFY_SLACK_SECRET") ?? "").trim();
    if (!secret && sb) {
      const { data } = await sb.from("app_secrets").select("value").eq("key", "notify_slack_secret").maybeSingle();
      secret = (data?.value ?? "").trim();
    }
    if (!secret || !channelKey || !text) return false;
    const url = `${Deno.env.get("SUPABASE_URL")}/functions/v1/notify-slack`;
    const res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-notify-secret": secret },
      body: JSON.stringify({
        action: "send", channel_key: channelKey, text,
        source: opts.source ?? "edge", event: opts.event ?? "generic",
        ...(opts.username ? { username: opts.username } : {}),
        ...(opts.icon_emoji ? { icon_emoji: opts.icon_emoji } : {}),
        ...(opts.dedupe_key ? { dedupe_key: opts.dedupe_key } : {}),
      }),
    });
    const j = await res.json().catch(() => ({}));
    return res.ok && j?.ok === true;
  } catch (_) {
    return false;
  }
}

// 2026-11-11（ユーザー決定「親メッセージは 1 行・詳細はスレッド」）: 監視・障害などの通知用。
//   親に 1 行だけ出し、詳細はそのスレッドへの返信にする。dedupe_key を渡すと、同じ案件で親を 2 つ出さない（2 回目は詳細だけスレッドに足す）。
//   送信に失敗しても throw しない。戻り値は親を送れたかどうか。
export async function slackPostThread(sb: any, channelKey: string, parentLine: string, detail: string, opts: SlackPostOpts = {}): Promise<boolean> {
  try {
    let secret = (Deno.env.get("NOTIFY_SLACK_SECRET") ?? "").trim();
    if (!secret && sb) {
      const { data } = await sb.from("app_secrets").select("value").eq("key", "notify_slack_secret").maybeSingle();
      secret = (data?.value ?? "").trim();
    }
    if (!secret || !channelKey || !parentLine) return false;
    const url = `${Deno.env.get("SUPABASE_URL")}/functions/v1/notify-slack`;
    const send = async (body: Record<string, unknown>) => {
      const res = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json", "x-notify-secret": secret }, body: JSON.stringify(body) });
      return await res.json().catch(() => ({}));
    };
    const base = { source: opts.source ?? "edge", event: opts.event ?? "generic", ...(opts.username ? { username: opts.username } : {}), ...(opts.icon_emoji ? { icon_emoji: opts.icon_emoji } : {}) };
    const p = await send({ action: "send", channel_key: channelKey, text: parentLine.split("\n")[0].slice(0, 150), ...base, ...(opts.dedupe_key ? { dedupe_key: opts.dedupe_key } : {}) });
    if (p?.ok !== true || !p.ts) return false;
    if (detail) await send({ action: "send", channel_key: channelKey, thread_ts: p.ts, text: detail, ...base, event: (opts.event ?? "generic") + "_detail" });
    return true;
  } catch (_) {
    return false;
  }
}

