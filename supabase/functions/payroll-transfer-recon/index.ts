// 給与振込の自動照合（下書き・2026-11-13。★本番未デプロイ・未実行。デプロイとスイッチ ON は、それぞれ別の承認のあと）
//
// op = "mf_scan": 第 1 段階「マネーフォワードの総額照合」
//   振込バッチ（payroll_transfer_batches）ごとに、マネーフォワードの仕訳（読むだけ）から、
//   振込指定日の前後数日の「預金からの出金」で、摘要に「WEB総振」を含むものを候補にし、
//   出金口座（設定に登録した預金名）・出金日・出金金額を、バッチの振込予定の合計と比べる。
//   ★ 金額がぴったり同じ候補が「ちょうど 1 件」のときだけ、DB の関数 payroll_transfer_mf_total_record で「総額照合済み」を記録する。
//      0 件・2 件以上・出金口座が未登録・口座が違う・金額が合わない（手数料が混ざっている疑いを含む）・日付が違う → 記録しない（理由を返す）。
//   ★ 総額が合っても、従業員ごとの行は 1 つも「完了」にならない（DB 側の決まり）。支払記録にも触れない。マネーフォワードには何も書かない。
//   ★ 同じマネーフォワードの出金を、2 つのバッチに使わない（DB の一意の決まりに任せる。断られたら、理由として返す）。
//
// スイッチ: app_settings.payroll_transfer_recon の mf_enabled（無ければ、DB の下書きの名前 mf_total_enabled を見る。どちらも無ければ false）が
//           true のときだけ動く。false のあいだは、試し実行（dry_run）でもマネーフォワードへつながない。
// 入力:     { op: "mf_scan", batch_id?: "<uuid>", dry_run?: boolean, window_days?: 0〜7（既定 3） }
//           batch_id なし＝まだ総額照合が済んでいない全バッチ（状態が「振込予定」「確認待ち」・振込指定日が今日まで・直近 45 日・最大 20 件）
//           dry_run: true＝読むだけ。記録はしない。候補（日付・金額・摘要・預金名）を返す。
// 認証:     既存の Edge Function と同じ（いずれか）
//             ・Authorization: Bearer <service_role>
//             ・x-notify-secret: <NOTIFY_SLACK_SECRET>
//             ・ログイン中の本部・社長・マスター（Authorization: Bearer <本人のトークン>）
// 出さないもの: Slack の通知（別途）。金額・摘要・口座の名前は console に出さない（このファイルに console の呼び出しは無い）。
// 設定:     app_settings.payroll_transfer_recon.corps.<法人 ID>.mf_deposit_accounts ＝ その法人の給与の出金口座（預金の「科目名/補助科目名」）。未登録なら記録しない。
//           app_settings.payroll_transfer_recon.corps.<法人 ID>.mf_tenant_id      ＝ マネーフォワードの事業者（無ければ、法人コードから決める: toho→default／livegate→livegate）。
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import { getValidAccessToken } from "../_shared/mf.ts";
import { fetchOutflows } from "../_shared/payment-match.ts";
import { isWebSofuri, judgeMfTotal, type MfOutflow, reasonText, scanRange, toMfOutflows } from "../_shared/payroll-mf-total.ts";

const cors: Record<string, string> = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info, x-notify-secret", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });
const svc = (): SupabaseClient => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const DAY = 86400e3;
const todayJst = () => new Date(Date.now() + 9 * 3600e3).toISOString().slice(0, 10);
const addDays = (ymd: string, n: number) => new Date(Date.parse(ymd) + n * DAY).toISOString().slice(0, 10);
const isUuid = (s: unknown): s is string => typeof s === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s);
// 給与の画面（invoices.html の PAYROLL_CORPS）と同じ対応: 法人コード → マネーフォワードの事業者
const CORP_CODE_TENANT: Record<string, string> = { toho: "default", livegate: "livegate" };

function timingSafeEqual(a: string, b: string) { if (a.length !== b.length) return false; let r = 0; for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i); return r === 0; }

type Caller = { kind: "service" | "secret" } | { kind: "user"; jwt: string };
/** 呼び出した人を確かめる。だめなら null */
async function authorize(req: Request, db: SupabaseClient): Promise<Caller | null> {
  const key = (Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "").trim();
  const bearer = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (key && bearer && timingSafeEqual(bearer, key)) return { kind: "service" };
  const secret = (Deno.env.get("NOTIFY_SLACK_SECRET") ?? "").trim();
  const hdr = (req.headers.get("x-notify-secret") ?? "").trim();
  if (secret && hdr && timingSafeEqual(secret, hdr)) return { kind: "secret" };
  if (!bearer) return null;
  try {
    const anon = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: `Bearer ${bearer}` } } });
    const { data } = await anon.auth.getUser();
    if (!data?.user) return null;
    const { data: u } = await db.from("users").select("role,is_master,is_active").eq("id", data.user.id).maybeSingle();
    if (!u?.is_active || !(u.is_master || ["CEO", "HQ"].includes(u.role))) return null;   // 本部・社長・マスターだけ（DB の payroll_pay_can と同じ）
    return { kind: "user", jwt: bearer };
  } catch (_e) { return null; }
}

type BatchResult = {
  batch_id: string; year_month: string | null; corporation_id: string | null; seq: number | null; batch_kind: string | null; scheduled_date: string | null;
  tenant: string | null; decision: "record" | "none"; reason: string; reason_text: string; recorded: boolean; already?: boolean; db_status?: string | null;
  counts?: { webSofuri: number; accountOk: number; exact: number };
  expected_total?: number; expected_count?: number; candidates?: unknown[];   // 試し実行のときだけ
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return json({ ok: false, error: "POST のみ対応" }, 405);
  const db = svc();
  const caller = await authorize(req, db);
  if (!caller) return json({ ok: false, error: "認証がありません（本部・社長・マスター、またはサービス用の鍵が必要です）" }, 401);
  // deno-lint-ignore no-explicit-any
  let body: any = {};
  try { body = await req.json(); } catch { body = {}; }
  // ---- op=mf_probe（2026-11-13 追加）: 読むだけの確かめ。スイッチに関係なく動くが、使えるのは管理用の鍵（サービス用の鍵・合言葉）だけ。記録は一切しない。
  //      入力 { op:"mf_probe", corp:"toho"|"livegate", date:"YYYY-MM-DD", window_days?:0〜7, amounts?:[数字…] }
  //      返すのは、その期間の預金からの出金のうち、摘要に「WEB総振」を含むもの・金額が amounts のどれかと同じもの、だけ（ほかの出金は件数だけ）。
  if (body?.op === "mf_probe") {
    if (caller.kind === "user") return json({ ok: false, error: "この確かめは、管理用の鍵からだけ使えます" }, 403);
    const tenant = typeof body.corp === "string" ? (CORP_CODE_TENANT[body.corp] ?? null) : null;
    const date = typeof body.date === "string" && /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(body.date) ? body.date : null;
    if (!tenant || !date) return json({ ok: false, error: "corp（toho／livegate）と date（YYYY-MM-DD）を指定してください" }, 400);
    const wd = Math.min(7, Math.max(0, Number.isFinite(Number(body.window_days)) ? Math.floor(Number(body.window_days)) : 3));
    const amounts: number[] = Array.isArray(body.amounts) ? body.amounts.map((x: unknown) => Number(x)).filter((x: number) => Number.isFinite(x) && x > 0).slice(0, 10) : [];
    try {
      const range = scanRange(date, wd);
      const { accessToken } = await getValidAccessToken(tenant);
      const fo = await fetchOutflows(accessToken, range.start, range.end, "out", tenant);
      if ("error" in fo) return json({ ok: false, op: "mf_probe", error: "mf_fetch_failed" }, 502);
      const raw = fo.outflows as { journal_id: string; transaction_date: string; amount: number; remark: string; summary: string }[];
      const all = toMfOutflows(raw);
      const sumOf = new Map<string, string>();
      for (const o of raw) sumOf.set(`${o.journal_id}|${o.amount}`, String(o.summary ?? ""));
      const hits = all.filter((o) => isWebSofuri(o.remark) || amounts.includes(Number(o.amount)));
      return json({ ok: true, op: "mf_probe", tenant, range, outflows_in_range: all.length,
        hits: hits.map((o) => ({ date: o.transaction_date, amount: o.amount, remark: o.remark, deposit_account: o.deposit_account, journal_id: o.journal_id, branch_no: o.branch_no,
          web_sofuri: isWebSofuri(o.remark), summary: sumOf.get(`${o.journal_id}|${o.amount}`) ?? null })) });
    } catch (_e) { return json({ ok: false, op: "mf_probe", error: "mf_fetch_failed" }, 502); }
  }
  if (body?.op !== "mf_scan") return json({ ok: false, error: "op は mf_scan（または mf_probe）を指定してください" }, 400);
  if (body.batch_id != null && !isUuid(body.batch_id)) return json({ ok: false, error: "batch_id の形が正しくありません" }, 400);
  const dryRun = body.dry_run === true;
  const windowDays = Math.min(7, Math.max(0, Number.isFinite(Number(body.window_days)) ? Math.floor(Number(body.window_days)) : 3));

  try {
    // スイッチ（OFF のあいだは、試し実行でもマネーフォワードへつながない）
    const { data: st, error: stErr } = await db.from("app_settings").select("value").eq("key", "payroll_transfer_recon").maybeSingle();
    if (stErr) return json({ ok: false, error: "設定を読めませんでした" }, 500);
    // deno-lint-ignore no-explicit-any
    const setting = (st?.value ?? {}) as Record<string, any>;
    const enabled = (setting.mf_enabled ?? setting.mf_total_enabled) === true;
    if (!enabled) return json({ ok: true, op: "mf_scan", dry_run: dryRun, switch: false, skipped: "switch_off", message: "スイッチ（mf_enabled）が OFF なので、何もしていません", results: [] });
    // deno-lint-ignore no-explicit-any
    const corpsCfg = (setting.corps && typeof setting.corps === "object" ? setting.corps : {}) as Record<string, any>;

    // 対象のバッチ（読むだけ）
    const today = todayJst();
    let q = db.from("payroll_transfer_batches").select("*");
    if (body.batch_id) q = q.eq("id", body.batch_id);
    else q = q.in("status", ["planned", "pending_check"]).is("mf_matched_at", null).lte("scheduled_date", today).gte("scheduled_date", addDays(today, -45)).order("scheduled_date", { ascending: true }).limit(20);
    const { data: batches, error: bErr } = await q;
    if (bErr) return json({ ok: false, error: "振込バッチを読めませんでした（SQL が未適用の可能性があります）" }, 500);
    if (body.batch_id && !(batches ?? []).length) return json({ ok: false, error: "バッチが見つかりません" }, 404);

    // 法人 → マネーフォワードの事業者
    const corpIds = [...new Set((batches ?? []).map((b) => String(b.corporation_id)))];
    const corpCode = new Map<string, string>();
    if (corpIds.length) {
      const { data: cs } = await db.from("corporations").select("id,corp_code").in("id", corpIds);
      for (const c of cs ?? []) corpCode.set(String(c.id), String(c.corp_code ?? ""));
    }
    const tenantOf = (corpId: string): string | null => {
      const t = corpsCfg[corpId]?.mf_tenant_id;
      if (typeof t === "string" && t.trim()) return t.trim();
      return CORP_CODE_TENANT[corpCode.get(corpId) ?? ""] ?? null;
    };

    const results: BatchResult[] = [];
    // deno-lint-ignore no-explicit-any
    const base = (b: any, tenant: string | null): BatchResult => ({
      batch_id: String(b.id), year_month: b.year_month ?? null, corporation_id: b.corporation_id ?? null, seq: b.batch_seq ?? b.seq ?? null, batch_kind: b.batch_kind ?? null,
      scheduled_date: b.scheduled_date ?? null, tenant, decision: "none", reason: "", reason_text: "", recorded: false,
    });
    const done = (r: BatchResult, reason: string, extra: Partial<BatchResult> = {}) => { results.push({ ...r, ...extra, reason, reason_text: extra.reason_text ?? reasonText(reason) }); };

    // 事業者ごとに、読む相手をまとめる（マネーフォワードの読み取りは、事業者ごとに 1 回）
    // deno-lint-ignore no-explicit-any
    const byTenant = new Map<string, any[]>();
    for (const b of batches ?? []) {
      const tenant = tenantOf(String(b.corporation_id));
      const r = base(b, tenant);
      if (b.mf_matched_at) { done(r, "already_matched", { reason_text: "このバッチは、すでに総額照合済みです" }); continue; }
      if (typeof b.scheduled_date !== "string" || b.scheduled_date > today) { done(r, "not_yet", { reason_text: "振込指定日が、まだ来ていません" }); continue; }
      if (!tenant) { done(r, "tenant_unknown"); continue; }
      const list = byTenant.get(tenant) ?? []; list.push(b); byTenant.set(tenant, list);
    }

    const usedInRun = new Set<string>();   // この実行の中で、同じ出金を 2 つのバッチに使わない（本当の守りは DB の一意の決まり）
    // 記録は、ログイン中の人が呼んだときはその人の名前で（DB の checked_by に残る）。サービス用の鍵のときはサービスとして。
    const rpcDb = caller.kind === "user"
      ? createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: `Bearer ${caller.jwt}` } } })
      : db;

    for (const [tenant, list] of byTenant) {
      const ranges = list.map((b) => scanRange(b.scheduled_date, windowDays));
      const start = ranges.map((r) => r.start).sort()[0];
      const endRaw = ranges.map((r) => r.end).sort().slice(-1)[0];
      const end = endRaw > addDays(today, 1) ? addDays(today, 1) : endRaw;
      let outflows: MfOutflow[] | null = null;
      try {
        const { accessToken } = await getValidAccessToken(tenant);
        const fo = await fetchOutflows(accessToken, start, end, "out", tenant);   // 既存の読み取り（変更なし）。預金側の名前は toMfOutflows が summary から取り出す
        if (!("error" in fo)) outflows = toMfOutflows(fo.outflows);
      } catch (_e) { outflows = null; }

      for (const b of list) {
        const r = base(b, tenant);
        if (!outflows) { done(r, "mf_fetch_failed"); continue; }
        const deposits = corpsCfg[String(b.corporation_id)]?.mf_deposit_accounts;
        const j = judgeMfTotal({ batch_id: String(b.id), scheduled_date: b.scheduled_date, expected_total: Number(b.expected_total), expected_count: Number(b.expected_count) }, outflows, { depositAccounts: deposits, windowDays });
        const extra: Partial<BatchResult> = { decision: j.decision, counts: j.counts };
        if (dryRun) {
          extra.expected_total = Number(b.expected_total); extra.expected_count = Number(b.expected_count);
          extra.candidates = j.candidates.map((c) => ({ journal_id: c.journal_id, branch_no: c.branch_no, transaction_date: c.transaction_date, amount: c.amount, deposit_account: c.deposit_account, remark: c.remark, account_ok: c.account_ok, amount_exact: c.amount_exact, date_exact: c.date_exact, diff: c.diff, day_diff: c.day_diff }));
        }
        if (j.decision !== "record" || !j.pick) { done(r, j.reason, extra); continue; }

        const useKey = `${tenant}|${j.pick.journal_id}|${j.pick.branch_no}`;
        if (usedInRun.has(useKey)) { done(r, "mf_journal_used_by_other_batch", { ...extra, decision: "none" }); continue; }
        usedInRun.add(useKey);
        if (dryRun) { done(r, j.reason, extra); continue; }   // 試し実行: ここまで（記録しない）

        const { data: rec, error: recErr } = await rpcDb.rpc("payroll_transfer_mf_total_record", {
          p_batch_id: b.id, p_tenant_id: tenant, p_journal_id: j.pick.journal_id, p_branch_no: j.pick.branch_no, p_transaction_date: j.pick.transaction_date,
          p_deposit_account: j.pick.registered_account, p_amount: j.pick.amount, p_remark: j.pick.remark, p_conclusive: false,
        });
        if (recErr) { done(r, "db_error", { ...extra, db_status: recErr.code ?? null }); continue; }
        if (rec?.ok === false) { done(r, String(rec.reason ?? "db_error"), { ...extra, decision: "none" }); continue; }   // 例: mf_journal_used_by_other_batch
        if (rec?.result !== "matched") { done(r, `db_result_${String(rec?.result ?? "unknown")}`, { ...extra, reason_text: "DB 側の判定が「一致」になりませんでした（記録は「不一致」として残ります）", db_status: rec?.status ?? null }); continue; }
        done(r, j.reason, { ...extra, recorded: true, already: rec.already === true, db_status: rec.status ?? null });
      }
    }

    return json({ ok: true, op: "mf_scan", dry_run: dryRun, switch: true, window_days: windowDays, scanned: results.length, recorded: results.filter((x) => x.recorded).length, results });
  } catch (_e) {
    return json({ ok: false, error: "照合の途中でエラーになりました" }, 500);   // 中身（金額・摘要を含むことがある）は返さない・ログにも出さない
  }
});
