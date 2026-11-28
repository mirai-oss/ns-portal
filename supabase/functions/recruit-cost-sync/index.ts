// =============================================================
// recruit-cost-sync — 求人広告費の内訳シートから、前の月の求人費用（recruit_costs）を入れる（2026-11-28・社長依頼）
//
// 呼び出し: pg_cron → public.recruit_cost_sync_trigger()（毎月 10〜20 日の 9:00 JST。反映できた月は、その後の回は何もしない）
//   body: { month?: "YYYY-MM"（省略＝前の月）, dry_run?: boolean（読むだけ・書かない・知らせない）, force?: boolean（反映済みでも入れ直す） }
// 設定: app_secrets.recruit_cost_sheet_id（Drive のファイル ID。公開リポジトリ・ログに出さない）
//       app_settings.recruit_cost_sheet = { enabled, monthly_fee（毎月足す固定費。広告費の割合で按分） }
// 知らせ: 反映できた・反映できなかったときに、社長の個人 DM へ 1 通。「まだシートが無い」は 10 日と 20 日だけ。
// 認証: service_role（Bearer）か x-notify-secret。
// デプロイ: supabase functions deploy recruit-cost-sync --no-verify-jwt --project-ref uuvsxzhpxtghojoubjcc --yes
// =============================================================
import { createClient } from "npm:@supabase/supabase-js@2";
import { allocate, parseSheet, previousMonthJst, type Sheet, sheetMonth } from "../_shared/recruit-cost-sheet.ts";
import { readSheets } from "../_shared/xlsx-lite.ts";

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

/** シートのファイルを取り、対象の月のシートを返す。名前（YYYYM / YYYYMM）で探し、無ければ全シートの見出しの期間で探す。 */
async function loadMonth(fileId: string, month: string): Promise<Sheet[]> {
  const res = await fetch(`https://drive.google.com/uc?export=download&id=${encodeURIComponent(fileId)}`, { redirect: "follow" });
  const buf = new Uint8Array(await res.arrayBuffer());
  if (!res.ok || buf[0] !== 0x50 || buf[1] !== 0x4b) throw new Error(`シートのファイルを読めません（HTTP ${res.status}。共有の設定が変わった可能性があります）`);
  if (buf.length > 10 * 1024 * 1024) throw new Error("シートのファイルが大きすぎます");
  const byName = (n: string) => sheetMonth({ name: n, rows: [] }) === month;
  const named = readSheets(buf, byName).filter((s) => sheetMonth(s) === month);
  return named.length ? named : readSheets(buf, (n) => !byName(n)).filter((s) => sheetMonth(s) === month);
}

async function dmPresident(sb: any, text: string, dedupe: string) {
  const { data: u } = await sb.from("users").select("id").eq("role", "CEO").eq("is_active", true).limit(1).maybeSingle();
  if (!u) return;
  await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/notify-slack`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-notify-secret": Deno.env.get("NOTIFY_SLACK_SECRET") ?? "", apikey: Deno.env.get("SUPABASE_ANON_KEY") ?? "" },
    body: JSON.stringify({ action: "send", channel_key: `user:${u.id}`, text, event: "recruit_cost_sync", source: "ef:recruit-cost-sync", dedupe_key: dedupe }),
  }).catch((e) => console.error("notify-slack", e));
}
const label = (m: string) => `${m.slice(0, 4)}年${Number(m.slice(5, 7))}月分`;
const y = (n: number) => `¥${n.toLocaleString("ja-JP")}`;

Deno.serve(async (req) => {
  if (!authorized(req)) return json({ ok: false, error: "認証がありません" }, 401);
  const body = await req.json().catch(() => ({}));
  const sb = svc();
  const month = /^20\d{2}-(0[1-9]|1[0-2])$/.test(body.month ?? "") ? String(body.month) : previousMonthJst(new Date());
  const dry = body.dry_run === true;
  const day = new Date(Date.now() + 9 * 3600e3).getUTCDate();
  try {
    const [{ data: id }, { data: st }] = await Promise.all([
      sb.from("app_secrets").select("value").eq("key", "recruit_cost_sheet_id").maybeSingle(),
      sb.from("app_settings").select("value").eq("key", "recruit_cost_sheet").maybeSingle(),
    ]);
    const cfg = (st?.value ?? {}) as { enabled?: boolean; monthly_fee?: number };
    if (cfg.enabled !== true) return json({ ok: true, skipped: "disabled" });
    if (!id?.value || !Number.isInteger(cfg.monthly_fee) || cfg.monthly_fee! < 0) throw new Error("設定（ファイル・固定費）が足りません");
    const { count } = await sb.from("recruit_costs").select("*", { count: "exact", head: true }).eq("month", `${month}-01`).eq("note", "auto:indeed-sheet");
    if (count && !dry && body.force !== true) return json({ ok: true, month, skipped: "already" });

    const found = await loadMonth(String(id.value).trim(), month);
    if (!found.length) {
      if (!dry && (day === 10 || day === 20)) await dmPresident(sb, `⚠️ 求人費用: 広告費の内訳シートに${label(month)}がまだありません。20日まで毎朝、もう一度確認します。`, `recruit-cost:${month}:missing:${day}`);
      return json({ ok: true, month, skipped: "sheet_missing" });
    }
    if (found.length > 1) throw new Error(`${label(month)}のシートが ${found.length} 枚あります`);
    const rows = allocate(parseSheet(found[0]), cfg.monthly_fee!);
    const ad = rows.reduce((s, r) => s + r.ad, 0), total = rows.reduce((s, r) => s + r.amount, 0);
    if (dry) return json({ ok: true, month, dry_run: true, ad, total, rows });

    const { data: done, error } = await sb.rpc("recruit_cost_replace", { p_month: `${month}-01`, p_rows: rows.map(({ area, form_key, amount }) => ({ area, form_key, amount })) });
    if (error) throw new Error(`保存できません: ${error.message}`);
    const manual = Number((done as { manual?: number })?.manual ?? 0);
    await dmPresident(sb, `📊 求人費用を反映しました（${label(month)}）\n広告費 ${y(ad)} ＋ 固定費 ${y(cfg.monthly_fee!)} ＝ ${y(total)}` +
      (manual ? `\n⚠️ この月には手で入力した費用が ${manual} 件あり、合計に足されます。応募管理の「求人費用」で確認してください。` : ""), `recruit-cost:${month}:done:${total}`);
    return json({ ok: true, month, rows: rows.length, manual });
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error("recruit-cost-sync", month, msg);
    if (!dry) await dmPresident(sb, `⚠️ 求人費用を反映できませんでした（${label(month)}）。何も書き換えていません。\n理由: ${msg.slice(0, 300)}`, `recruit-cost:${month}:error:${day}`);
    return json({ ok: false, month, error: msg }, 500);
  }
});
