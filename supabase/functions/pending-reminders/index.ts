// =============================================================
// pending-reminders — 押されていない Slack のボタン（○×・承認/却下・確認・判断依頼）をまとめてリマインドする
// 2026-11-08 新規（ユーザー指示「承認、却下等選ぶものは全て完了してないものを今後リマインドで流してください」）
//
// 呼び出し: pg_cron → public.pending_reminders_trigger()（08:00〜22:00 JST の毎時。body に min_age_hours=12）／手元から x-notify-secret 付き POST
//   間隔（ユーザー決定 2026-11-08）: 最後の連絡から 12 時間で送り、完了するまで 12 時間おき。深夜（22〜8 時）は cron を回さない＝朝 8 時に送る。
//   body: { min_age_hours?: number (既定 12), max_per_run?: number (既定 30), dry_run?: boolean, only?: string[] }
//   only は "alert_open" | "alert_approval" | "request" | "change" | "decision" の配列（指定なし=全部）
//
// やり方: 最初に送ったメッセージの台帳（notification_deliveries.payload）からボタン付きブロックをそのまま取り出し、
//   先頭に「⏰ リマインド（n回目）」を足して同じ宛先へ再送する。再送した台帳 id は各テーブルの *_notification_ids に追加する
//   → ボタンが押されたとき slack-interact の updateMany が元メッセージとリマインドを全部「済」に書き換える。
//   状態（status）はここでは一切変えない（例外: 期限切れの判断依頼だけ expired にして「⌛ 期限切れ」に書き換える）。
// 宛先: 元メッセージと同じ channel_key（店長向けは kintai.check、承認依頼はマスターの DM）。
// 認証: service_role（Bearer）か x-notify-secret。
// デプロイ: supabase functions deploy pending-reminders --no-verify-jwt --project-ref uuvsxzhpxtghojoubjcc --yes
// =============================================================
import { createClient } from "npm:@supabase/supabase-js@2";

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
async function sendSlack(body: Record<string, unknown>): Promise<any> {
  const res = await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/notify-slack`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-notify-secret": Deno.env.get("NOTIFY_SLACK_SECRET") ?? "", apikey: Deno.env.get("SUPABASE_ANON_KEY") ?? "" },
    body: JSON.stringify(body),
  });
  return await res.json().catch(() => ({ ok: false, error: "notify-slack の応答を読めません" }));
}
const jst = (iso: string) => new Date(iso).toLocaleString("ja-JP", { timeZone: "Asia/Tokyo", month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit", hour12: false });
function ageText(sinceIso: string): string {
  const h = Math.max(0, Math.floor((Date.now() - new Date(sinceIso).getTime()) / 3600000));
  if (h < 24) return `${h}時間`;
  const d = Math.floor(h / 24);
  return h % 24 ? `${d}日${h % 24}時間` : `${d}日`;
}

// 未対応 1 件 = 「どのテーブルの・どの行の・どの台帳 id 列に・どの台帳 id が入っているか」
type Item = {
  kind: "alert_open" | "alert_approval" | "request" | "change" | "decision";
  table: string; id: string; idsColumn: string; ids: string[];
  since: string;            // 最初の連絡（created_at）
  reminded_at: string | null; remind_count: number;
  label: string;            // ログ用
};

async function collect(sb: any, only: Set<string> | null): Promise<Item[]> {
  const out: Item[] = [];
  const want = (k: string) => !only || only.has(k);
  if (want("alert_open") || want("alert_approval")) {
    const { data } = await sb.from("sf_attendance_alerts").select("id,status,notification_ids,approval_notification_ids,created_at,reminded_at,remind_count,updated_at")
      .in("status", ["open", "fix_requested"]);
    for (const a of data ?? []) {
      if (a.status === "open" && want("alert_open")) out.push({ kind: "alert_open", table: "sf_attendance_alerts", id: a.id, idsColumn: "notification_ids", ids: a.notification_ids ?? [], since: a.created_at, reminded_at: a.reminded_at, remind_count: a.remind_count ?? 0, label: `勤怠確認 ${a.id.slice(0, 8)}` });
      if (a.status === "fix_requested" && want("alert_approval")) out.push({ kind: "alert_approval", table: "sf_attendance_alerts", id: a.id, idsColumn: "approval_notification_ids", ids: a.approval_notification_ids ?? [], since: a.updated_at ?? a.created_at, reminded_at: a.reminded_at, remind_count: a.remind_count ?? 0, label: `修正承認 ${a.id.slice(0, 8)}` });
    }
  }
  if (want("request")) {
    const { data } = await sb.from("sf_attendance_requests").select("id,approval_notification_ids,created_at,reminded_at,remind_count").eq("status", "pending");
    for (const r of data ?? []) out.push({ kind: "request", table: "sf_attendance_requests", id: r.id, idsColumn: "approval_notification_ids", ids: r.approval_notification_ids ?? [], since: r.created_at, reminded_at: r.reminded_at, remind_count: r.remind_count ?? 0, label: `申請承認 ${r.id.slice(0, 8)}` });
  }
  if (want("change")) {
    const { data } = await sb.from("sf_attendance_smaregi_changes").select("id,notification_ids,created_at,reminded_at,remind_count").eq("status", "open");
    for (const c of data ?? []) out.push({ kind: "change", table: "sf_attendance_smaregi_changes", id: c.id, idsColumn: "notification_ids", ids: c.notification_ids ?? [], since: c.created_at, reminded_at: c.reminded_at, remind_count: c.remind_count ?? 0, label: `直接修正の確認 ${c.id.slice(0, 8)}` });
  }
  if (want("decision")) {
    const { data } = await sb.from("decision_requests").select("id,notification_id,reminder_notification_ids,created_at,reminded_at,remind_count,expires_at").eq("status", "pending").gt("expires_at", new Date().toISOString());
    for (const d of data ?? []) out.push({ kind: "decision", table: "decision_requests", id: d.id, idsColumn: "reminder_notification_ids", ids: [d.notification_id, ...(d.reminder_notification_ids ?? [])].filter(Boolean), since: d.created_at, reminded_at: d.reminded_at, remind_count: d.remind_count ?? 0, label: `判断依頼 ${d.id.slice(0, 8)}` });
  }
  return out;
}

// 期限切れの判断依頼を締める（リマインドし続けない）。メッセージも「⌛ 期限切れ」に書き換える
async function expireDecisions(sb: any, dryRun: boolean): Promise<number> {
  const { data } = await sb.from("decision_requests").select("id,notification_id,reminder_notification_ids,question").eq("status", "pending").lte("expires_at", new Date().toISOString());
  if (!data?.length || dryRun) return data?.length ?? 0;
  for (const d of data) {
    await sb.from("decision_requests").update({ status: "expired", updated_at: new Date().toISOString() }).eq("id", d.id).eq("status", "pending");
    const ids = [d.notification_id, ...(d.reminder_notification_ids ?? [])].filter(Boolean);
    await Promise.all(ids.map((nid: string) => sendSlack({ action: "update", notification_id: nid, text: `⌛ 期限切れ（回答なし）\n> ${String(d.question ?? "").replace(/\n/g, "\n> ")}` })));
  }
  return data.length;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ ok: false, error: "POSTのみ" }, 405);
  if (!authorized(req)) return json({ ok: false, error: "認証がありません" }, 401);
  let body: any = {};
  try { body = await req.json(); } catch { body = {}; }
  const minAgeMs = Math.max(0, Number(body.min_age_hours ?? 12)) * 3600000;
  const maxPerRun = Math.min(100, Math.max(1, Number(body.max_per_run ?? 30)));
  const dryRun = !!body.dry_run;
  const only = Array.isArray(body.only) && body.only.length ? new Set<string>(body.only.map(String)) : null;
  const sb = svc();
  const nowIso = new Date().toISOString();

  const expired = await expireDecisions(sb, dryRun);
  const items = await collect(sb, only);
  const results: any[] = [];
  let sent = 0, skippedFresh = 0, skippedNoSource = 0, failed = 0, capped = 0;

  // 古いものから。最後の連絡（リマインド or 最初）から min_age 未満は飛ばす
  items.sort((a, b) => a.since.localeCompare(b.since));
  for (const it of items) {
    const last = it.reminded_at ?? it.since;
    if (Date.now() - new Date(last).getTime() < minAgeMs) { skippedFresh++; continue; }
    if (sent >= maxPerRun) { capped++; continue; }
    // 元メッセージの台帳（送れていたもの）。宛先ごとに 1 通ずつ再送する（承認依頼はマスター各人の DM）
    const { data: rows } = await sb.from("notification_deliveries").select("id,channel_key,payload,delivery_status,created_at").in("id", it.ids).in("delivery_status", ["sent", "updated"]).order("created_at", { ascending: true });
    const byChannel = new Map<string, any>();
    for (const r of rows ?? []) if (!byChannel.has(r.channel_key) && r.payload?.blocks) byChannel.set(r.channel_key, r);
    if (!byChannel.size) { skippedNoSource++; results.push({ ...it, ids: undefined, result: "no_source" }); continue; }
    const n = it.remind_count + 1;
    const header = { type: "context", elements: [{ type: "mrkdwn", text: `⏰ *リマインド（${n}回目）*　未対応のまま *${ageText(it.since)}*（最初の連絡 ${jst(it.since)}）` }] };
    const newIds: string[] = [];
    let anyFail = false;
    for (const [ch, src] of byChannel) {
      const nid = crypto.randomUUID();
      const text = `⏰ リマインド（${n}回目） ${String(src.payload?.text ?? "").slice(0, 600)}`;
      if (dryRun) { results.push({ kind: it.kind, id: it.id, channel: ch, n, dry_run: true }); continue; }
      const r = await sendSlack({
        action: "send", notification_id: nid, channel_key: ch, event: "reminder", source: "ef:pending-reminders",
        text, blocks: [header, ...src.payload.blocks],
        dedupe_key: `remind:${it.table}:${it.id}:${n}:${ch}`, ref: { table: it.table, id: it.id }, username: "勤怠確認", icon_emoji: ":alarm_clock:",
      });
      if (r?.ok && r.notification_id) newIds.push(r.notification_id); else { anyFail = true; results.push({ kind: it.kind, id: it.id, channel: ch, error: r?.error ?? "send_failed" }); }
    }
    if (dryRun) { sent++; continue; }
    if (newIds.length) {
      // 台帳 id を追記（配列の読み書きは短いので競合はほぼ無いが、必ず最新を読んでから足す）
      const { data: cur } = await sb.from(it.table).select(it.idsColumn).eq("id", it.id).maybeSingle();
      const existing = ((cur as Record<string, unknown> | null)?.[it.idsColumn] as string[] | null | undefined) ?? [];
      const merged = [...existing, ...newIds];
      await sb.from(it.table).update({ [it.idsColumn]: merged, reminded_at: nowIso, remind_count: n, updated_at: nowIso }).eq("id", it.id);
      sent++;
      results.push({ kind: it.kind, id: it.id, n, sent_to: [...byChannel.keys()] });
    }
    if (anyFail) failed++;
  }
  return json({ ok: true, dry_run: dryRun, min_age_hours: minAgeMs / 3600000, pending: items.length, sent, skipped_fresh: skippedFresh, skipped_no_source: skippedNoSource, failed, capped, expired_decisions: expired, results });
});
