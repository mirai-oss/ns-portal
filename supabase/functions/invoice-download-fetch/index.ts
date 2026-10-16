// パスワード付き・URLダウンロード型の請求書メールの自動取得（担当C・2026-10-16）
//
// 「請求書のURLが書かれたメール」と、数分後の「パスワードが書かれたメール」の2通で届く請求書を、
// 件名で組み合わせ、パスワードを使ってPDFをダウンロードし、URLのメールの添付として保存する。
// 保存後は、メールを「請求書（添付あり）」として、通常の自動処理（invoice-auto-create→明細→仕訳の下書き→承認待ち）へ流す。
//
// 安全策: 開くのは「許可リスト（ALLOW）」に載せたダウンロードサービスのURLだけ。パスワードは取得の処理中にだけ使い、ログ・履歴には残さない。
//   取得は、人が手作業でやっているのと同じ操作（URLを開く→パスワードを入力→ダウンロード）だけ。ログイン・送信・購入などはしない。
// 対応済み: k-mac（ガーデンのファイル転送。https://smtp01.k-mac.jp/get/<トークン>）
//
// 認証: invoice-intake と同じ共有シークレット（app_secrets.invoice_intake_secret）。
// 入力(JSON): { secret, email_id } … このメール（URL側でもパスワード側でも可）に関係する組み合わせを解決する
//             { secret, action:"scan", since?:ISO } … 直近のURLメールをまとめて確認する
import { createClient } from "npm:@supabase/supabase-js@2";

const cors: Record<string, string> = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info" };
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });
const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

// 許可リスト: ダウンロードサービスのURLの形
const ALLOW = [{ kind: "kmac", re: /https:\/\/smtp01\.k-mac\.jp\/get\/[A-Za-z0-9_-]+/ }];
const urlOf = (body: string): { kind: string; url: string } | null => { for (const a of ALLOW) { const m = String(body ?? "").match(a.re); if (m) return { kind: a.kind, url: m[0] }; } return null; };
const passwordOf = (body: string): string | null => { const m = String(body ?? "").match(/【パスワード[^】]*】\s*([!-~]{4,64})/); return m ? m[1] : null; };
const targetSubjectOf = (body: string): string | null => { const m = String(body ?? "").match(/件名\s*\(subject\)[^：:\n]*[：:]\s*([^\n\r]+)/) || String(body ?? "").match(/件名[^：:\n]*[：:]\s*([^\n\r]+)/); return m ? m[1].trim() : null; };
const norm = (s: unknown) => String(s ?? "").normalize("NFKC").replace(/\s+/g, "").replace(/^(re|fwd?):/i, "").toLowerCase();

function bytesToHex(b: Uint8Array) { return Array.from(b).map((x) => x.toString(16).padStart(2, "0")).join(""); }
function decodeHtml(s: string) { return s.replace(/&amp;/g, "&").replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">"); }

// Cookieを引き継ぎながらfetchする簡易クライアント
function makeClient() {
  const jar = new Map<string, string>();
  const cookieHeader = () => [...jar.entries()].map(([k, v]) => `${k}=${v}`).join("; ");
  const save = (res: Response) => { const sc = (res.headers as any).getSetCookie ? (res.headers as any).getSetCookie() : (res.headers.get("set-cookie") ? [res.headers.get("set-cookie")!] : []); for (const c of sc) { const [kv] = String(c).split(";"); const i = kv.indexOf("="); if (i > 0) jar.set(kv.slice(0, i).trim(), kv.slice(i + 1).trim()); } };
  return async (url: string, init: RequestInit = {}) => {
    const headers = new Headers(init.headers ?? {}); headers.set("User-Agent", "Mozilla/5.0"); if (jar.size) headers.set("Cookie", cookieHeader());
    const res = await fetch(url, { ...init, headers, redirect: "follow" }); save(res); return res;
  };
}

// k-macのファイル転送: ①ページ取得(hidden query) ②mode=auth(JSON) ③mode=clear(ファイル一覧) ④mode=dl&num=N(ダウンロード)
async function fetchKmac(url: string, password: string): Promise<{ ok: true; files: { name: string; bytes: Uint8Array; mime: string }[] } | { ok: false; error: string }> {
  const http = makeClient();
  const page = await http(url); const html = await page.text();
  const query = (html.match(/name=["']query["']\s+value=["']([^"']+)["']/) || [])[1];
  if (!query) return { ok: false, error: "ダウンロードページの形が想定と違います（query が見つかりません）" };
  const form = (o: Record<string, string>) => ({ method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: new URLSearchParams(o).toString() });
  const auth = await http(new URL("/get/auth", url).toString(), form({ query, password, mode: "auth" }));
  const atxt = await auth.text(); let aj: any = null; try { aj = JSON.parse(atxt); } catch { /* 形式が違う */ }
  if (!aj || aj.result !== "success") return { ok: false, error: `パスワード認証に失敗しました（応答 ${atxt.slice(0, 40).replace(/\s+/g, " ")}）` };
  const list = await http(url, form({ query, password, mode: "clear" })); const lhtml = await list.text();
  // ファイル一覧: <div class="files num_N"> … <div class="filename">ファイル名</div>
  const items: { name: string; num: string }[] = [];
  for (const m of lhtml.matchAll(/class=["']files num_(\d+)["'][\s\S]*?<div class=["']filename["']>([^<]*)<\/div>/g)) items.push({ name: decodeHtml(m[2].trim()), num: m[1] });
  if (!items.length) return { ok: false, error: "ファイル一覧を読み取れませんでした（取得できるファイルが無い、または形が違います）" };
  // #dlinfo の hidden項目（query・password・md5pass 等）をそのまま引き継ぐ
  const dl = (lhtml.match(/<form[^>]*id=["']dlinfo["'][\s\S]*?<\/form>/i) || [""])[0];
  const hidden: Record<string, string> = {};
  for (const m of dl.matchAll(/<input[^>]*name=["']([^"']+)["'][^>]*>/g)) { const v = (m[0].match(/value=["']([^"']*)["']/) || [])[1] ?? ""; hidden[m[1]] = decodeHtml(v); }
  const files: { name: string; bytes: Uint8Array; mime: string }[] = [];
  for (const it of items.slice(0, 5)) {
    const res = await http(url, form({ ...hidden, query, password, mode: "dl", num: it.num }));
    if (!res.ok) continue;
    const ct = res.headers.get("content-type") ?? "";
    const bytes = new Uint8Array(await res.arrayBuffer());
    if (!bytes.length || /text\/html/i.test(ct)) continue;
    let name = it.name; const cd = res.headers.get("content-disposition") ?? ""; const fm = cd.match(/filename\*=UTF-8''([^;]+)/i); if (fm) { try { name = decodeURIComponent(fm[1]); } catch { /* そのまま */ } }
    files.push({ name: name || `file${it.num}.pdf`, bytes, mime: /pdf/i.test(ct) || /\.pdf$/i.test(name) ? "application/pdf" : (ct.split(";")[0] || "application/octet-stream") });
  }
  if (!files.length) return { ok: false, error: "ファイルのダウンロードに失敗しました" };
  return { ok: true, files };
}

async function logAudit(db: any, emailId: string, action: string, note: string) {
  await db.from("invoice_audit_logs").insert({ entity_type: "invoice_email", entity_id: emailId, action, actor_type: "ai", note });
}

// 1通のURLメールについて、組になるパスワードメールを探し、取得して保存する
async function resolveUrlMail(db: any, urlMail: any, secret: string): Promise<{ email_id: string; status: string; note?: string }> {
  const found = urlOf(urlMail.body_text); if (!found) return { email_id: urlMail.id, status: "skipped", note: "許可リストのURLがありません" };
  const { data: done } = await db.from("invoice_audit_logs").select("id").eq("entity_id", urlMail.id).eq("action", "download_fetched").limit(1);
  if (done?.length) return { email_id: urlMail.id, status: "skipped", note: "取得済みです" };
  // パスワードのメール: 受信から3日以内・本文の「対象メール件名」がURLメールの件名と同じ
  const since = new Date(new Date(urlMail.received_at ?? Date.now()).getTime() - 3600e3).toISOString();
  const { data: cands } = await db.from("invoice_emails").select("id, subject, body_text, received_at").gte("received_at", since).like("body_text", "%パスワード%").order("received_at", { ascending: true }).limit(40);
  const subj = norm(urlMail.subject);
  const pms = (cands ?? []).filter((c: any) => c.id !== urlMail.id && passwordOf(c.body_text) && norm(targetSubjectOf(c.body_text)) === subj);
  if (!pms.length) return { email_id: urlMail.id, status: "waiting", note: "パスワードのメールがまだ届いていません" };
  // 同じ件名のURL・パスワードが複数組ある場合があるため、認証が通るパスワードが見つかるまで順に試す（同じパスワードは1回だけ）
  let r: Awaited<ReturnType<typeof fetchKmac>> = { ok: false, error: "未対応のサービスです" };
  const tried = new Set<string>();
  for (const pm of pms.slice(0, 4)) {
    const password = passwordOf(pm.body_text)!; if (tried.has(password)) continue; tried.add(password);
    r = found.kind === "kmac" ? await fetchKmac(found.url, password) : { ok: false as const, error: "未対応のサービスです" };
    if (r.ok || !/認証に失敗/.test(r.error)) break;
  }
  if (!r.ok) { await logAudit(db, urlMail.id, "download_failed", "請求書の自動ダウンロードに失敗: " + r.error); return { email_id: urlMail.id, status: "error", note: r.error }; }
  let saved = 0;
  for (const f of r.files) {
    const hash = bytesToHex(new Uint8Array(await crypto.subtle.digest("SHA-256", f.bytes)));
    const { data: dup } = await db.from("invoice_attachments").select("id, email_id, invoice_id").eq("file_hash", hash).limit(1);
    if (dup?.length) {   // 同じファイルは既にある（転送メール等）。請求書に未紐づけなら、このメールの添付として付け替えて処理に乗せる
      if (!dup[0].invoice_id && dup[0].email_id !== urlMail.id) { const { error: mvErr } = await db.from("invoice_attachments").update({ email_id: urlMail.id }).eq("id", dup[0].id); if (!mvErr) saved++; }
      continue;
    }
    const ext = (/\.[A-Za-z0-9]{1,10}$/.exec(f.name) || [".pdf"])[0].toLowerCase();
    const path = `${urlMail.id}/dl_${crypto.randomUUID()}${ext}`;
    const { error: upErr } = await db.storage.from("invoice-files").upload(path, f.bytes, { contentType: f.mime });
    if (upErr) continue;
    const { error: insErr } = await db.from("invoice_attachments").insert({ email_id: urlMail.id, file_name: f.name.slice(0, 200), mime_type: f.mime, storage_path: path, file_hash: hash, size_bytes: f.bytes.length });
    if (!insErr) saved++;
  }
  await logAudit(db, urlMail.id, "download_fetched", `パスワード付きの請求書を自動ダウンロードしました（${r.files.length}件取得・${saved}件保存）`);
  if (saved > 0) {
    // 通常の請求書（添付あり）として自動処理へ
    await db.from("invoice_emails").update({ auto_category: "invoice_attachment", auto_category_by: "rule", auto_confidence: 1, auto_category_reason: "パスワード付きURLから自動ダウンロードした請求書", auto_invoice_at: null, auto_invoice_note: null, ...(urlMail.mail_kind ? {} : { mail_kind: "invoice" }) }).eq("id", urlMail.id);
    const kick = fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/invoice-auto-create`, { method: "POST", headers: { "Content-Type": "application/json", apikey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, Authorization: `Bearer ${Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")}` }, body: JSON.stringify({ secret, email_id: urlMail.id }) }).catch((e) => console.error("自動生成の依頼に失敗: " + e));
    const er = (globalThis as any).EdgeRuntime; if (er?.waitUntil) er.waitUntil(kick);
  }
  return { email_id: urlMail.id, status: saved ? "fetched" : "duplicate", note: `${saved}件保存` };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return json({ error: "POSTのみ対応" }, 405);
  let body: any; try { body = await req.json(); } catch { return json({ error: "JSONの読み取りに失敗しました" }, 400); }
  const db = svc();
  const { data: sr, error: se } = await db.from("app_secrets").select("value").eq("key", "invoice_intake_secret").maybeSingle();
  if (se) return json({ error: "シークレット確認に失敗しました: " + se.message }, 500);
  if (!sr?.value || body?.secret !== sr.value) return json({ error: "認証エラー" }, 401);
  try {
    const results: any[] = [];
    if (body?.action === "scan") {
      const since = body.since ? new Date(body.since).toISOString() : new Date(Date.now() - 7 * 86400e3).toISOString();
      const { data: mails } = await db.from("invoice_emails").select("id, subject, body_text, received_at, mail_kind").gte("received_at", since).like("body_text", "%smtp01.k-mac.jp/get/%").order("received_at", { ascending: true }).limit(30);
      for (const m of mails ?? []) results.push(await resolveUrlMail(db, m, body.secret));
      return json({ success: true, processed: results.length, results });
    }
    if (!body?.email_id) return json({ error: "email_id が必要です" }, 400);
    const { data: me } = await db.from("invoice_emails").select("id, subject, body_text, received_at, mail_kind").eq("id", body.email_id).maybeSingle();
    if (!me) return json({ error: "メールが見つかりません" }, 404);
    if (urlOf(me.body_text)) results.push(await resolveUrlMail(db, me, body.secret));
    else if (passwordOf(me.body_text)) {   // パスワード側が届いた: 対応するURLメール（同じ件名・直近3日）を探して解決
      const target = norm(targetSubjectOf(me.body_text));
      const since = new Date(new Date(me.received_at ?? Date.now()).getTime() - 3 * 86400e3).toISOString();
      const { data: urls } = await db.from("invoice_emails").select("id, subject, body_text, received_at, mail_kind").gte("received_at", since).like("body_text", "%smtp01.k-mac.jp/get/%").order("received_at", { ascending: false }).limit(20);
      for (const u of (urls ?? []).filter((x: any) => norm(x.subject) === target)) results.push(await resolveUrlMail(db, u, body.secret));
    }
    return json({ success: true, results });
  } catch (e) {
    return json({ error: "処理中にエラー: " + String((e as Error)?.message ?? e) }, 500);
  }
});
