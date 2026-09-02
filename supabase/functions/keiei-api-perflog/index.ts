// P-0a: 計測の受け皿 Edge Function（レーンP専任・2026-09-02新設）
// docs/実装指示書_脱GAS移行_Phase0-1_2026-09-02.md §1 P側 / 親計画: 計画書_経営ダッシュボード高速化と脱GAS移行_2026-09-02.md
//
// 目的: tori-dashboard/seisan-dashboard(app.js)側に既に実装済みの計測フック
//   （tori-dashboard/app.js:1479-1493 logApiPerf_()。A-p0・2026-09-02実装済み）が
//   navigator.sendBeaconで送ってくる「action名・所要ms・成否・エラー種別」を無認証で受け、
//   kd_perf_logへ記録する。sendBeaconはヘッダーを付けられないため、認証は行わない
//   （app.js側のPERF_LOG_ANON_KEYはSupabaseゲートウェイ向けのapikeyクエリで、アプリ側の認可には
//   使わない。DB保護はレート制限＋14日自動削除で行う）。
//
// 呼び出し方（2種類。同じURLをop有無で振り分け）:
//   ①ingest（無認証・sendBeaconから）: POST { app, action, ms, ok, errType, t }
//      → app.jsのlogApiPerf_()が送るペイロードそのまま（1件=1リクエスト。バッチ無し）
//   ②管理系（service_roleのみ・GitHub Actions日次cronから）: POST { op: 'notify' | 'cleanup', force?: boolean }
//      - notify : 前日(JST)分を集計し「遅いaction/失敗actionトップ10」をLarkへ配信
//                 （force:trueで当日分に対して即時実行＝動作確認用）
//      - cleanup: 14日より古い行を削除
//   運用: .github/workflows/keiei-perflog-daily.yml（cron-job.orgからworkflow_dispatchで日次起動。
//   登録手順はWORKLOG参照・ユーザー作業）
//
// Lark送信先: app_secrets.lark_webhook_url（D-3見張り番・D-4等の既存Lark配信と同じWebhookを流用）
import { createClient } from "npm:@supabase/supabase-js@2";

const cors: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });

const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const RETENTION_DAYS = 14;
const MAX_MS = 600000; // 10分（それ以上はクランプ。異常値でランキングが荒れるのを防ぐ）
const RATE_LIMIT_WINDOW_SEC = 10;
const RATE_LIMIT_MAX = 40; // 同一IPが10秒間に送れる上限（先読み・バッチ操作でも十分な余裕を見た値）

function clientIp(req: Request): string {
  const xf = req.headers.get("x-forwarded-for") || "";
  const first = xf.split(",")[0]?.trim();
  return first || req.headers.get("x-real-ip") || "unknown";
}
function clamp(n: number, lo: number, hi: number): number {
  if (!Number.isFinite(n)) return lo;
  return Math.min(hi, Math.max(lo, n));
}

async function sendLark(sb: ReturnType<typeof createClient>, text: string) {
  const { data: sec } = await sb.from("app_secrets").select("value").eq("key", "lark_webhook_url").maybeSingle();
  const url = (sec?.value ?? "").trim();
  if (!url) return { ok: false, reason: "app_secretsにlark_webhook_url未設定" };
  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ msg_type: "text", content: { text } }),
  });
  const bodyJson = await res.json().catch(() => ({}));
  return { ok: res.ok, status: res.status, body: bodyJson };
}

type Row = { app: string; action: string; ms: number; ok: boolean };

async function fetchDayRows(sb: ReturnType<typeof createClient>, fromIso: string, toIso: string): Promise<Row[]> {
  const rows: Row[] = [];
  const PAGE = 1000;
  for (let offset = 0; offset < 50000; offset += PAGE) {
    const { data, error } = await sb.from("kd_perf_log").select("app,action,ms,ok")
      .gte("created_at", fromIso).lt("created_at", toIso)
      .range(offset, offset + PAGE - 1);
    if (error) throw new Error(error.message);
    if (!data || !data.length) break;
    rows.push(...(data as Row[]));
    if (data.length < PAGE) break;
  }
  return rows;
}

async function notifyDailyRanking(sb: ReturnType<typeof createClient>, body: any) {
  // 対象: 前日1日分（JST 00:00-24:00）。force:trueなら当日分に対して即時実行（動作確認用）
  const nowJst = new Date(Date.now() + 9 * 3600 * 1000);
  const dayOffset = body.force ? 0 : -1;
  const targetJstMidnightUtcMs = Date.UTC(nowJst.getUTCFullYear(), nowJst.getUTCMonth(), nowJst.getUTCDate() + dayOffset);
  const fromUtc = new Date(targetJstMidnightUtcMs - 9 * 3600 * 1000);
  const toUtc = new Date(fromUtc.getTime() + 86400000);
  const targetLabel = new Date(targetJstMidnightUtcMs).toISOString().slice(0, 10);

  const rows = await fetchDayRows(sb, fromUtc.toISOString(), toUtc.toISOString());
  if (!rows.length) {
    const text = `📊 経営D/精算D 計測レポート（${targetLabel}）\nデータがありません（計測フックがまだ届いていない可能性があります）`;
    const sent = await sendLark(sb, text);
    return { ok: true, date: targetLabel, rows: 0, sent };
  }

  type Agg = { key: string; count: number; failCount: number; sumMs: number; maxMs: number };
  const byAction = new Map<string, Agg>();
  for (const r of rows) {
    const key = `${r.app}:${r.action}`;
    const a = byAction.get(key) ?? { key, count: 0, failCount: 0, sumMs: 0, maxMs: 0 };
    a.count++;
    a.sumMs += Number(r.ms) || 0;
    a.maxMs = Math.max(a.maxMs, Number(r.ms) || 0);
    if (!r.ok) a.failCount++;
    byAction.set(key, a);
  }
  const all = [...byAction.values()];

  // 遅いactionトップ10（ノイズ防止に3回以上呼ばれたactionのみ対象・平均ms降順）
  const slow = all.filter((a) => a.count >= 3).map((a) => ({ ...a, avgMs: a.sumMs / a.count }))
    .sort((a, b) => b.avgMs - a.avgMs).slice(0, 10);
  // 失敗actionトップ10（失敗率降順・同率は失敗件数降順）
  const failing = all.filter((a) => a.failCount > 0)
    .sort((a, b) => (b.failCount / b.count) - (a.failCount / a.count) || b.failCount - a.failCount).slice(0, 10);

  const totalCalls = rows.length;
  const totalFail = rows.filter((r) => !r.ok).length;

  const lines: string[] = [];
  lines.push(`📊 経営D/精算D 計測レポート（${targetLabel}）`);
  lines.push(`全呼び出し${totalCalls}件・失敗${totalFail}件（${totalCalls ? (totalFail / totalCalls * 100).toFixed(1) : "0"}%）`);
  lines.push("");
  lines.push(`🐢 遅いactionトップ${slow.length}（3回以上呼ばれたものが対象）`);
  slow.forEach((a, i) => lines.push(`${i + 1}. ${a.key} 平均${Math.round(a.avgMs)}ms（最大${a.maxMs}ms・${a.count}回）`));
  lines.push("");
  lines.push(`❌ 失敗actionトップ${failing.length}`);
  if (!failing.length) lines.push("（失敗なし）");
  failing.forEach((a, i) => lines.push(`${i + 1}. ${a.key} 失敗${a.failCount}/${a.count}回（${(a.failCount / a.count * 100).toFixed(0)}%）`));

  const text = lines.join("\n");
  const sent = await sendLark(sb, text);
  return { ok: true, date: targetLabel, rows: totalCalls, fail: totalFail, sent };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const sb = svc();
    const raw = await req.text();
    let body: any = {};
    if (raw) {
      try { body = JSON.parse(raw); } catch { return json({ ok: false, error: "invalid json" }, 400); }
    }

    // ---------------- 管理系操作（service_roleのみ・GitHub Actions日次cronから） ----------------
    if (body.op === "notify" || body.op === "cleanup") {
      const authHeader = req.headers.get("Authorization") ?? "";
      const isServiceRole = authHeader.includes(Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? " ");
      if (!isServiceRole) return json({ ok: false, error: "権限がありません（service_roleのみ）" }, 403);

      if (body.op === "cleanup") {
        const cutoff = new Date(Date.now() - RETENTION_DAYS * 86400000).toISOString();
        const { error, count } = await sb.from("kd_perf_log").delete({ count: "exact" }).lt("created_at", cutoff);
        if (error) return json({ ok: false, error: error.message }, 500);
        return json({ ok: true, deleted: count ?? 0 });
      }
      try {
        return json(await notifyDailyRanking(sb, body));
      } catch (e) {
        return json({ ok: false, error: String(e) }, 500);
      }
    }

    // ---------------- ingest（app.jsのnavigator.sendBeaconから。無認証） ----------------
    const ip = clientIp(req);
    // レート制限: 直近RATE_LIMIT_WINDOW_SEC秒に同一IPからRATE_LIMIT_MAX件を超えていたら捨てる
    // （sendBeaconは応答を見ないため429を返しても実害は無い。目的はDB保護のみ）
    if (ip !== "unknown") {
      const since = new Date(Date.now() - RATE_LIMIT_WINDOW_SEC * 1000).toISOString();
      const { count } = await sb.from("kd_perf_log").select("id", { count: "exact", head: true })
        .eq("ip", ip).gte("created_at", since);
      if ((count ?? 0) >= RATE_LIMIT_MAX) return json({ ok: false, error: "rate_limited" }, 429);
    }

    const action = String(body.action ?? "").trim().slice(0, 80);
    if (!action) return json({ ok: false, error: "action required" }, 400);
    const appName = String(body.app ?? "unknown").trim().slice(0, 40) || "unknown";
    const ms = Math.round(clamp(Number(body.ms), 0, MAX_MS));
    const ok = !!body.ok;
    const errType = ok ? null : (String(body.errType ?? "").trim().slice(0, 40) || null);
    const tNum = Number(body.t);
    const clientTs = Number.isFinite(tNum) && tNum > 0 ? new Date(tNum).toISOString() : null;

    const { error } = await sb.from("kd_perf_log").insert({
      app: appName, action, ms, ok, err_type: errType, client_ts: clientTs, ip: ip === "unknown" ? null : ip,
    });
    if (error) return json({ ok: false, error: error.message }, 500);
    return json({ ok: true });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
