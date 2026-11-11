// =============================================================
// slack-link — 従業員と Slack の紐づけ（2026-11-08 新規）
//   op=sync        Slack のメンバー一覧（users.list・users:read.email）と users.email を突き合わせて user_slack に登録（既に紐づいている人は表示名だけ更新）
//   op=members     Slack のメンバー一覧（Bot・削除済みを除く）＋どの従業員に紐づいているか。手で紐づけるときの候補用（メールは伏せ字）
//   op=invite      { user_id, channel: line|email|both|auto|copy }（auto=初回は both・以後 LINE か メール） 招待リンク（app_settings 'slack_invite'）を本人の LINE かメール（info@ns0314.com の Gmail・請求書メールと同じ GAS 経路）で送る／copy=文面だけ返す
//   op=link        { user_id, slack_user_id } 手で紐づけ（matched_by=manual）／ op=unlink { user_id }
//   op=set_invite  { url } 招待リンクを保存（Slack の「メンバーを招待 → 招待リンクをコピー」で作ったもの）
//   op=status      { user_id? } 紐づけ状態と招待の履歴
//   op=remind      Slack 未連携の従業員一覧を hq.slack_unlinked へ（pg_cron 毎朝 09:45・x-notify-secret）
//   op=remind_employees  本人へ自動再送（招待から 3 日→以後 7 日おき→最大 3 回・LINE＋メール。pg_cron 毎朝 10:00）
// 認証: JWT（CEO/HQ/マスター）。op=sync と op=invite は x-notify-secret（pg_cron 毎朝 09:30／手元のテスト送信）と service_role でも可
// デプロイ: supabase functions deploy slack-link --no-verify-jwt --project-ref uuvsxzhpxtghojoubjcc --yes
// =============================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info, x-notify-secret", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });
const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const mask = (em: string) => em.replace(/^(.).*(@.*)$/, "$1***$2");
const RESEND_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const RESEND_FROM = Deno.env.get("RESEND_FROM") ?? "鳥一代グループ 日報システム <onboarding@resend.dev>";
// メール送信: 請求書メールの「メール作成」と同じ経路（GAS invoice-intake WebApp → GmailApp・差出人 info@ns0314.com）。
//   ユーザー確認 2026-11-08: 会社のメールはこの仕組みで送れている。GAS の設定が無いときだけ Resend にフォールバック
async function emailSend(to: string, subject: string, text: string): Promise<{ ok: boolean; error?: string; via?: string }> {
  const gasUrl = Deno.env.get("INVOICE_GAS_WEBAPP_URL") ?? "", gasSecret = Deno.env.get("INVOICE_INTAKE_SECRET") ?? "";
  if (gasUrl && gasSecret) {
    try {
      const r = await fetch(gasUrl, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ token: gasSecret, mode: "compose", to, subject, body: text }) });
      const j = await r.json().catch(() => null);
      if (r.ok && j?.success) return { ok: true, via: "gmail" };
      return { ok: false, error: "Gmail 送信エラー: " + (j?.error ?? `HTTP ${r.status}`) };
    } catch (e) { return { ok: false, error: "Gmail 送信エラー: " + String(e).slice(0, 120) }; }
  }
  if (!RESEND_KEY) return { ok: false, error: "メール送信の設定がありません（INVOICE_GAS_WEBAPP_URL / RESEND_API_KEY）" };
  const html = `<div style="font-family:sans-serif;line-height:1.8;font-size:15px">${text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/(https?:\/\/\S+)/g, '<a href="$1">$1</a>').replace(/\n/g, "<br>")}</div>`;
  const r = await fetch("https://api.resend.com/emails", { method: "POST", headers: { Authorization: `Bearer ${RESEND_KEY}`, "Content-Type": "application/json" }, body: JSON.stringify({ from: RESEND_FROM, to, subject, html, text }) });
  if (!r.ok) return { ok: false, error: `メール送信エラー(${r.status}) ${(await r.text()).slice(0, 120)}` };
  return { ok: true };
}

function timingSafeEqual(a: string, b: string) {
  if (a.length !== b.length) return false;
  let r = 0; for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}
type Actor = { id: string; name: string; role: string; is_master: boolean };
async function auth(req: Request): Promise<{ mode: "user" | "secret" | "service"; actor?: Actor } | null> {
  const key = (Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "").trim();
  const bearer = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (key && bearer && timingSafeEqual(bearer, key)) return { mode: "service" };
  const secret = (Deno.env.get("NOTIFY_SLACK_SECRET") ?? "").trim();
  const hdr = (req.headers.get("x-notify-secret") ?? "").trim();
  if (secret && hdr && timingSafeEqual(secret, hdr)) return { mode: "secret" };
  if (!bearer) return null;
  const anon = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: `Bearer ${bearer}` } } });
  const { data } = await anon.auth.getUser();
  if (!data?.user) return null;
  const { data: u } = await svc().from("users").select("id,name,role,is_master,is_active").eq("id", data.user.id).maybeSingle();
  if (!u?.is_active) return null;
  if (!(u.is_master || ["CEO", "HQ"].includes(u.role))) return null;
  return { mode: "user", actor: { id: u.id, name: u.name, role: u.role, is_master: !!u.is_master } };
}

async function notifySlackSvc(body: Record<string, unknown>): Promise<any> {
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  try {
    const res = await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/notify-slack`, { method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}`, apikey: key }, body: JSON.stringify(body) });
    return await res.json().catch(() => null);
  } catch { return null; }
}
async function slackApi(method: string, params: Record<string, string> = {}): Promise<any> {
  const token = Deno.env.get("SLACK_BOT_TOKEN") ?? "";
  const qs = new URLSearchParams(params).toString();
  const r = await fetch(`https://slack.com/api/${method}${qs ? "?" + qs : ""}`, { headers: { Authorization: `Bearer ${token}` } });
  return await r.json().catch(() => ({ ok: false, error: "bad_json" }));
}
type Member = { id: string; email: string; real_name: string; display_name: string };
async function listMembers(): Promise<Member[]> {
  const out: Member[] = [];
  let cursor = "";
  do {
    const r = await slackApi("users.list", { limit: "200", ...(cursor ? { cursor } : {}) });
    if (!r.ok) throw new Error("users.list: " + (r.error ?? "?"));
    for (const m of r.members ?? []) {
      if (m.deleted || m.is_bot || m.id === "USLACKBOT") continue;
      out.push({ id: m.id, email: String(m.profile?.email ?? "").toLowerCase().trim(), real_name: m.real_name ?? m.profile?.real_name ?? "", display_name: m.profile?.display_name ?? "" });
    }
    cursor = r.response_metadata?.next_cursor ?? "";
  } while (cursor);
  return out;
}

// メール一致で紐づける（既に紐づいている人は表示名だけ更新。手動紐づけは上書きしない）
async function sync(sb: any) {
  const members = await listMembers();
  const byEmail = new Map<string, Member>();
  for (const m of members) if (m.email) byEmail.set(m.email, m);
  const { data: users } = await sb.from("users").select("id,email,name,is_active").eq("is_active", true);
  const { data: links } = await sb.from("user_slack").select("user_id,slack_user_id,matched_by,matched_email,matched_at");
  const linked = new Map<string, any>((links ?? []).map((l: any) => [l.user_id, l]));
  const now = new Date().toISOString();
  const newly: { user_id: string; name: string; slack_user_id: string }[] = [];
  const rows: any[] = [];
  for (const u of users ?? []) {
    const em = (u.email ?? "").toLowerCase().trim();
    const m = em ? byEmail.get(em) : undefined;
    const cur = linked.get(u.id);
    if (cur) {
      const mm = members.find((x) => x.id === cur.slack_user_id);
      // 2026-11-08 修正: upsert は無い列を null で送るため matched_at（not null）も必ず入れる（初回実行で not-null 違反になった）
      if (mm) rows.push({ user_id: u.id, slack_user_id: cur.slack_user_id, matched_by: cur.matched_by ?? "email", matched_email: cur.matched_email ?? mm.email ?? null, matched_at: cur.matched_at ?? now, slack_name: mm.real_name, slack_display_name: mm.display_name, updated_at: now });
      continue;
    }
    if (m) { rows.push({ user_id: u.id, slack_user_id: m.id, matched_by: "email", matched_email: em, matched_at: now, slack_name: m.real_name, slack_display_name: m.display_name, updated_at: now }); newly.push({ user_id: u.id, name: u.name, slack_user_id: m.id }); }
  }
  if (rows.length) { const { error } = await sb.from("user_slack").upsert(rows, { onConflict: "user_id" }); if (error) throw new Error(error.message); }
  // 2026-11-08: 新しく紐づいた人には、その場で本人の Slack に案内（Slack の参加イベントが届かなくても 10 分おきの照合でここに来る）
  for (const n of newly) {
    await notifySlackSvc({ action: "send", channel_key: `user:${n.user_id}`, event: "slack_link_welcome", source: "ef:slack-link",
      text: `👋 ${n.name}さん、N-Style の Slack へようこそ。管理システムの従業員情報と自動で紐づきました。\n勤怠確認のボタンや申請のやりとりがここに届きます。`,
      dedupe_key: `slack_link_welcome:${n.user_id}`, username: "N-Style 通知Bot" });
    // 2026-11-11（ユーザー決定）: 紐づけできた記録は Slack に出さない（人の対応が要らないため。紐づけは user_slack に残る）
  }
  const linkedSlack = new Set(rows.map((r) => r.slack_user_id));
  const unmatchedSlack = members.filter((m) => !linkedSlack.has(m.id)).map((m) => ({ id: m.id, name: m.real_name, email: m.email ? mask(m.email) : "" }));
  const unlinkedUsers = (users ?? []).filter((u: any) => !rows.some((r) => r.user_id === u.id)).length;
  return { ok: true, slack_members: members.length, linked: rows.length, newly_linked: newly, unlinked_users: unlinkedUsers, unmatched_slack: unmatchedSlack };
}

// 毎朝のリマインド（2026-11-08 ユーザー指示）: 管理システムに登録済みで Slack 未連携の人を hq.slack_unlinked（C0CFE1Y9HC7）へ。0 人なら送らない
//   除外: 名前に「連携用」「テスト」を含むアカウント（システム用・テスト用）
async function remind(sb: any) {
  const { data: users } = await sb.from("users").select("id,name,role,email,line_user_id").eq("is_active", true);
  const { data: links } = await sb.from("user_slack").select("user_id");
  const linked = new Set((links ?? []).map((l: any) => l.user_id));
  const targets = (users ?? []).filter((u: any) => !linked.has(u.id) && !/連携用|テスト/.test(String(u.name ?? "")));
  if (!targets.length) return { ok: true, sent: false, unlinked: 0 };
  const ids = targets.map((u: any) => u.id);
  const { data: us } = await sb.from("user_stores").select("user_id,stores(name)").in("user_id", ids);
  const storeOf = new Map<string, string[]>();
  for (const r of us ?? []) { const arr = storeOf.get(r.user_id) ?? []; const n = (r as any).stores?.name; if (n && !arr.includes(n)) arr.push(n); storeOf.set(r.user_id, arr); }
  const { data: logs } = await sb.from("slack_invite_log").select("user_id,sent_at,channel,resend_no").in("user_id", ids).in("channel", ["line", "email"]).order("sent_at", { ascending: false });
  const lastSent = new Map<string, string>(); const resends = new Map<string, number>();
  for (const l of logs ?? []) { if (!lastSent.has(l.user_id)) lastSent.set(l.user_id, l.sent_at); resends.set(l.user_id, Math.max(resends.get(l.user_id) ?? 0, Number(l.resend_no ?? 0))); }
  const ROLE: Record<string, string> = { CEO: "社長", HQ: "本部", TEAM: "チーム長", TENCHO: "店長", SHAIN: "社員", AL: "アルバイト" };
  const fmt = (u: any) => `${u.name}（${ROLE[u.role] ?? u.role}・${(storeOf.get(u.id) ?? []).join("・") || "店舗なし"}）`;
  const jd = (iso: string) => new Date(iso).toLocaleDateString("ja-JP", { timeZone: "Asia/Tokyo", month: "numeric", day: "numeric" });
  const order: Record<string, number> = { CEO: 0, HQ: 1, TEAM: 2, TENCHO: 3, SHAIN: 4, AL: 5 };
  targets.sort((x: any, y: any) => (order[x.role] ?? 9) - (order[y.role] ?? 9) || String(x.name).localeCompare(String(y.name), "ja"));
  const followUp = targets.filter((u: any) => lastSent.has(u.id) && (resends.get(u.id) ?? 0) >= RESEND_MAX);
  const invited = targets.filter((u: any) => lastSent.has(u.id) && (resends.get(u.id) ?? 0) < RESEND_MAX), notYet = targets.filter((u: any) => !lastSent.has(u.id));
  const cap = (arr: any[], f: (u: any) => string, max = 40) => arr.slice(0, max).map(f).join("\n") + (arr.length > max ? `\n…ほか ${arr.length - max} 名` : "");
  const text = [
    `🔔 *Slack 未連携の従業員: ${targets.length} 名*（管理システムに登録済みで、まだ Slack と紐づいていない人）`,
    followUp.length ? `\n*⚠️ 要フォロー ${followUp.length} 名*（再送 ${RESEND_MAX} 回しても未連携。店長・本部から声をかけてください。登録メールが違う可能性もあり → 従業員管理の「Slack のメンバーから選んで紐づける」）\n${cap(followUp, (u) => `・${fmt(u)}　最終送信 ${jd(lastSent.get(u.id)!)}`)}` : "",
    invited.length ? `\n*招待済み・登録待ち ${invited.length} 名*（3 日後に自動で再送、以後 1 週間おき・最大 3 回）\n${cap(invited, (u) => `・${fmt(u)}　最終送信 ${jd(lastSent.get(u.id)!)}${(resends.get(u.id) ?? 0) ? `（再送 ${resends.get(u.id)} 回）` : ""}`)}` : "",
    notYet.length ? `\n*まだ招待していない ${notYet.length} 名*\n${cap(notYet, (u) => `・${fmt(u)}`)}` : "",
    `\n招待は nippo → 従業員管理 →「未連携・未提出だけ探す」→ 💬 Slack未連携のみ → 一斉送信（初回は LINE＋メール）。<https://mirai-oss.github.io/nippo/?page=admin|従業員管理を開く>`,
  ].filter(Boolean).join("\n");
  const r = await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/notify-slack`, {
    method: "POST", headers: { "Content-Type": "application/json", "x-notify-secret": Deno.env.get("NOTIFY_SLACK_SECRET") ?? "", apikey: Deno.env.get("SUPABASE_ANON_KEY") ?? "" },
    body: JSON.stringify({ action: "send", channel_key: "hq.slack_unlinked", event: "slack_unlinked_remind", source: "ef:slack-link", text, dedupe_key: `slack_unlinked_remind:${new Date().toISOString().slice(0, 10)}`, username: "N-Style 通知Bot", icon_emoji: ":bell:" }),
  });
  const j = await r.json().catch(() => null);
  return { ok: !!j?.ok, sent: !!j?.ok, unlinked: targets.length, invited: invited.length, not_yet: notYet.length, follow_up: followUp.length, error: j?.error };
}
async function linePush(sb: any, lineUserId: string, text: string): Promise<{ ok: boolean; error?: string }> {
  const { data: sec } = await sb.from("app_secrets").select("value").eq("key", "line_channel_token").maybeSingle();
  const token = (sec?.value ?? "").trim();
  if (!token) return { ok: false, error: "line_channel_token 未設定" };
  const r = await fetch("https://api.line.me/v2/bot/message/push", { method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` }, body: JSON.stringify({ to: lineUserId, messages: [{ type: "text", text }] }) });
  if (!r.ok) return { ok: false, error: `LINE ${r.status} ${(await r.text()).slice(0, 160)}` };
  return { ok: true };
}
const SLACK_GUIDE_URL_DEFAULT = "https://mirai-oss.github.io/ns-portal/docs/guide_slack_setup.pdf";   // Slack の登録のしかた（顔写真の登録など）PDF（ユーザー提供 2026-11-08・docs に公開）
function inviteText(u: { name: string; email: string }, inv: { url: string; note: string; guide_url: string }, prefix = ""): string {
  return `${prefix}【${u.name}さん】会社の連絡を Slack に移します。下のリンクから Slack に登録してください。\n\n${inv.url}\n\n★登録するときのメールは、管理システムに登録している「${u.email}」にしてください（同じメールだと自動で管理システムと紐づきます）。\n\n📄 登録のしかた・顔写真の登録方法（PDF）:\n${inv.guide_url}${inv.note ? "\n" + inv.note : ""}`;
}
// 本人への自動再送（ユーザー決定 2026-11-08）: 最初の招待から 3 日たっても未連携 → 再送 1 回目。以後 7 日おき。最大 3 回。LINE＋メール
const RESEND_FIRST_DAYS = 3, RESEND_EVERY_DAYS = 7, RESEND_MAX = 3;
async function remindEmployees(sb: any, actorId: string | null) {
  const inv = await inviteSetting(sb);
  if (!inv) return { ok: false, error: "招待リンク未設定" };
  const { data: users } = await sb.from("users").select("id,name,email,line_user_id,is_active").eq("is_active", true);
  const { data: links } = await sb.from("user_slack").select("user_id");
  const linked = new Set((links ?? []).map((l: any) => l.user_id));
  const targets = (users ?? []).filter((u: any) => !linked.has(u.id) && !/連携用|テスト/.test(String(u.name ?? "")));
  const ids = targets.map((u: any) => u.id);
  if (!ids.length) return { ok: true, sent: 0 };
  const { data: logs } = await sb.from("slack_invite_log").select("user_id,sent_at,channel,resend_no").in("user_id", ids).in("channel", ["line", "email"]);
  const byUser = new Map<string, { first: number; last: number; resends: number }>();
  for (const l of logs ?? []) {
    const t = new Date(l.sent_at).getTime();
    const cur = byUser.get(l.user_id) ?? { first: t, last: t, resends: 0 };
    cur.first = Math.min(cur.first, t); cur.last = Math.max(cur.last, t); cur.resends = Math.max(cur.resends, Number(l.resend_no ?? 0));
    byUser.set(l.user_id, cur);
  }
  const now = Date.now(), day = 86400000;
  const results: any[] = [];
  let sent = 0;
  for (const u of targets) {
    const st = byUser.get(u.id);
    if (!st) continue;                               // まだ一度も招待していない人は対象外（本部が送る）
    if (st.resends >= RESEND_MAX) continue;          // 3 回送ったら止める（要フォローとして朝の一覧へ）
    const due = st.resends === 0 ? st.first + RESEND_FIRST_DAYS * day : st.last + RESEND_EVERY_DAYS * day;
    if (now < due) continue;
    const n = st.resends + 1;
    const text = inviteText(u, inv, `【再送 ${n} 回目】Slack の登録がまだ確認できていません。\n`);
    const via: string[] = [];
    if (u.line_user_id) { const r = await linePush(sb, u.line_user_id, text); if (r.ok) { via.push("line"); await sb.from("slack_invite_log").insert({ user_id: u.id, sent_by: actorId, channel: "line", resend_no: n, note: "auto" }); } }
    if (u.email) { const r = await emailSend(u.email, `【鳥一代グループ】Slack 登録のお願い（再送 ${n} 回目）`, text); if (r.ok) { via.push("email"); await sb.from("slack_invite_log").insert({ user_id: u.id, sent_by: actorId, channel: "email", resend_no: n, note: "auto" }); } }
    if (via.length) sent++;
    results.push({ name: u.name, resend_no: n, via: via.join("+") || "failed" });
  }
  return { ok: true, sent, results };
}
async function inviteSetting(sb: any): Promise<{ url: string; note: string; guide_url: string } | null> {
  const { data } = await sb.from("app_settings").select("value").eq("key", "slack_invite").maybeSingle();
  const v = data?.value ?? null;
  return v?.url ? { url: String(v.url), note: String(v.note ?? ""), guide_url: String(v.guide_url ?? SLACK_GUIDE_URL_DEFAULT) } : null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ ok: false, error: "POSTのみ" }, 405);
  const a = await auth(req);
  if (!a) return json({ ok: false, error: "権限がありません（本部・社長・マスターのログインが必要です）" }, 401);
  let b: any = {};
  try { b = await req.json(); } catch { b = {}; }
  const sb = svc();
  const op = String(b.op ?? "");
  try {
    if (op === "sync") return json(await sync(sb));
    // x-notify-secret（内部鍵）は sync と invite だけ許す（invite は Claude 側からのテスト送信・手元運用用。送れるのは招待の案内のみ）2026-11-08
    if (op === "remind") return json(await remind(sb));
    if (op === "remind_employees") return json(await remindEmployees(sb, a.actor?.id ?? null));
    if (a.mode === "secret" && op !== "invite") return json({ ok: false, error: "この操作はログインが必要です" }, 403);
    const actorId = a.actor?.id ?? null;

    if (op === "members") {
      const members = await listMembers();
      const { data: links } = await sb.from("user_slack").select("user_id,slack_user_id");
      const { data: users } = await sb.from("users").select("id,name");
      const uname = new Map<string, string>((users ?? []).map((u: any) => [u.id, u.name]));
      const bySlack = new Map<string, string>((links ?? []).map((l: any) => [l.slack_user_id, l.user_id]));
      return json({ ok: true, members: members.map((m) => ({ id: m.id, name: m.real_name, display_name: m.display_name, email_masked: m.email ? mask(m.email) : "", linked_user_id: bySlack.get(m.id) ?? null, linked_user_name: bySlack.get(m.id) ? uname.get(bySlack.get(m.id)!) ?? "" : "" })).sort((x, y) => (x.linked_user_id ? 1 : 0) - (y.linked_user_id ? 1 : 0) || x.name.localeCompare(y.name, "ja")) });
    }
    if (op === "set_invite") {
      const url = String(b.url ?? "").trim();
      if (!/^https:\/\/(join\.slack\.com|[a-z0-9-]+\.slack\.com)\//.test(url)) return json({ ok: false, error: "Slack の招待リンク（https://join.slack.com/… か https://xxx.slack.com/…）を入れてください" }, 400);
      const { error } = await sb.from("app_settings").upsert({ key: "slack_invite", value: { url, note: String(b.note ?? ""), set_at: new Date().toISOString(), set_by: actorId }, updated_at: new Date().toISOString(), updated_by: actorId }, { onConflict: "key" });
      if (error) return json({ ok: false, error: error.message }, 500);
      return json({ ok: true });
    }
    if (op === "invite") {
      const uid = String(b.user_id ?? "");
      const { data: u } = await sb.from("users").select("id,name,email,line_user_id,is_active").eq("id", uid).maybeSingle();
      if (!u) return json({ ok: false, error: "従業員が見つかりません" }, 404);
      const inv = await inviteSetting(sb);
      if (!inv) return json({ ok: false, code: "no_invite_url", error: "Slack の招待リンクがまだ登録されていません（従業員一覧の「Slack の招待リンクを設定」から入れてください）" }, 400);
      const text = inviteText(u, inv);
      if (b.channel === "copy") {
        await sb.from("slack_invite_log").insert({ user_id: uid, sent_by: actorId, channel: "copy" });
        return json({ ok: true, sent_via: "copy", invite_url: inv.url, text });
      }
      if (b.channel === "email") {
        if (!u.email) return json({ ok: false, code: "no_email", error: "この人はメールが登録されていません", invite_url: inv.url, text });
        const r = await emailSend(u.email, "【鳥一代グループ】Slack 登録のお願い", text);
        if (!r.ok) return json({ ok: false, error: r.error, invite_url: inv.url, text }, 502);
        await sb.from("slack_invite_log").insert({ user_id: uid, sent_by: actorId, channel: "email" });
        return json({ ok: true, sent_via: "email" });
      }
      // auto: 初回（まだ一度も送っていない）は LINE とメールの両方（LINE をブロックしている人がいるため・ユーザー指示 2026-11-08）。2 回目以降は LINE があれば LINE、無ければメール
      if (b.channel === "auto") {
        const { count } = await sb.from("slack_invite_log").select("id", { count: "exact", head: true }).eq("user_id", uid).in("channel", ["line", "email"]);
        b.channel = (count ?? 0) === 0 ? "both" : (u.line_user_id ? "line" : "email");
      }
      if (b.channel === "both") {
        const via: string[] = []; const errs: string[] = [];
        if (u.line_user_id) { const r = await linePush(sb, u.line_user_id, text); if (r.ok) { via.push("line"); await sb.from("slack_invite_log").insert({ user_id: uid, sent_by: actorId, channel: "line" }); } else errs.push("LINE: " + r.error); }
        if (u.email) { const r = await emailSend(u.email, "【鳥一代グループ】Slack 登録のお願い", text); if (r.ok) { via.push("email"); await sb.from("slack_invite_log").insert({ user_id: uid, sent_by: actorId, channel: "email" }); } else errs.push(r.error ?? "メール失敗"); }
        if (!via.length) return json({ ok: false, error: errs.join("／") || "送り先がありません（LINE もメールも無い）", invite_url: inv.url, text }, 502);
        return json({ ok: true, sent_via: via.join("+"), warnings: errs });
      }
      if (b.channel === "email") {   // auto でメールに倒れたとき
        const r = await emailSend(u.email, "【鳥一代グループ】Slack 登録のお願い", text);
        if (!r.ok) return json({ ok: false, error: r.error, invite_url: inv.url, text }, 502);
        await sb.from("slack_invite_log").insert({ user_id: uid, sent_by: actorId, channel: "email" });
        return json({ ok: true, sent_via: "email" });
      }
      if (!u.line_user_id) return json({ ok: false, code: "no_line", error: "この人は LINE 未連携なので LINE では送れません。「メールで送る」か、文面をコピーして渡してください", invite_url: inv.url, text });
      const r = await linePush(sb, u.line_user_id, text);
      if (!r.ok) return json({ ok: false, error: "LINE 送信に失敗: " + r.error, invite_url: inv.url, text }, 502);
      await sb.from("slack_invite_log").insert({ user_id: uid, sent_by: actorId, channel: "line" });
      return json({ ok: true, sent_via: "line" });
    }
    if (op === "link") {
      const uid = String(b.user_id ?? ""), sid = String(b.slack_user_id ?? "");
      if (!uid || !/^[UW][A-Z0-9]+$/.test(sid)) return json({ ok: false, error: "従業員と Slack メンバーを選んでください" }, 400);
      const { data: dup } = await sb.from("user_slack").select("user_id").eq("slack_user_id", sid).neq("user_id", uid).maybeSingle();
      if (dup) return json({ ok: false, error: "その Slack メンバーは別の従業員に紐づいています。先にそちらを解除してください" }, 409);
      const members = await listMembers();
      const m = members.find((x) => x.id === sid);
      const now = new Date().toISOString();
      const { error } = await sb.from("user_slack").upsert({ user_id: uid, slack_user_id: sid, matched_by: "manual", matched_email: m?.email ?? null, matched_at: now, slack_name: m?.real_name ?? null, slack_display_name: m?.display_name ?? null, updated_at: now }, { onConflict: "user_id" });
      if (error) return json({ ok: false, error: error.message }, 500);
      return json({ ok: true, slack_name: m?.real_name ?? "" });
    }
    if (op === "unlink") {
      const uid = String(b.user_id ?? "");
      const { error } = await sb.from("user_slack").delete().eq("user_id", uid);
      if (error) return json({ ok: false, error: error.message }, 500);
      return json({ ok: true });
    }
    if (op === "status") {
      const inv = await inviteSetting(sb);
      const uid = b.user_id ? String(b.user_id) : null;
      const { data: link } = uid ? await sb.from("user_slack").select("*").eq("user_id", uid).maybeSingle() : { data: null };
      const { data: log } = uid ? await sb.from("slack_invite_log").select("channel,sent_at,sent_by").eq("user_id", uid).order("sent_at", { ascending: false }).limit(5) : { data: [] };
      return json({ ok: true, invite_url: inv?.url ?? null, invite_note: inv?.note ?? "", link, invites: log ?? [] });
    }
    return json({ ok: false, error: "op は sync / members / invite / link / unlink / set_invite / status" }, 400);
  } catch (e) { return json({ ok: false, error: String(e).slice(0, 300) }, 500); }
});
