// 引き落とし・他行振込の自動照合（定期実行）— 担当C・2026-10-16
//
// 振込待ち（会計登録済み・支払方法が「引き落とし」「他行口座から振込」）の請求書を、MFの仕訳（預金からの出金）と照合し、
//   ・金額一致／まとめ払い → 「照合OK（要確認）」候補
//   ・振込先は合うのに金額が合わない → 「金額違い」エラー候補
// を payment_match_candidates に保存し、新しい候補だけ Lark（経理チャンネル）へ通知する。
// 振込済みにするのは人が確認してから（画面の「🔎 引き落とし・他行振込を照合」）。MFには何も書かない。
//
// 認証: invoice_intake_secret。入力: { secret, force?: boolean, dry_run?: boolean }
//   force なし＝「1日1回（日本時間9時以降・前回から20時間以上）」のときだけ実行（invoice-intake のメール取込から毎回呼ばれても二重に動かない）
import { createClient } from "npm:@supabase/supabase-js@2";
import { getValidAccessToken, mfFetch } from "../_shared/mf.ts";
import { larkPost } from "../_shared/cockpit.ts";
import { counterpartyId, dateRange, fetchOutflows, matchPayments, norm, rulePatternOf, type PayItem, type Rule } from "../_shared/payment-match.ts";

const cors: Record<string, string> = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info" };
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });
const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const yen = (n: number) => "¥" + Math.round(n).toLocaleString();
// 同じ名前が続くときは「名前 ×件数」にまとめる（通知を読みやすくする）
const groupNames = (names: string[]) => { const m = new Map<string, number>(); names.filter(Boolean).forEach((n) => m.set(n, (m.get(n) ?? 0) + 1)); return [...m].map(([n, c]) => (c > 1 ? `${n} ×${c}件` : n)).join("・"); };
const todayJst = () => new Date(Date.now() + 9 * 3600e3).toISOString().slice(0, 10);
const daysOver = (due: string) => Math.max(1, Math.round((Date.parse(todayJst()) - Date.parse(due)) / 86400e3));
const md = (d: string) => `${Number(d.slice(5, 7))}/${Number(d.slice(8, 10))}`;
const PORTAL = "https://mirai-oss.github.io/ns-portal/invoices.html";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return json({ error: "POSTのみ対応" }, 405);
  let body: any; try { body = await req.json(); } catch { return json({ error: "JSONの読み取りに失敗しました" }, 400); }
  const db = svc();
  const { data: sr } = await db.from("app_secrets").select("value").eq("key", "invoice_intake_secret").maybeSingle();
  if (!sr?.value || body?.secret !== sr.value) return json({ error: "認証エラー" }, 401);

  // 調査用（読み取りのみ）: 指定した入金元の別名に当たる「預金への入金」を期間内でそのまま一覧する。例: {explain:{needle:"シーピーワンジヤパン", from:"2026-09-01", to:"2026-10-16", tenant:"default"}}
  if (body?.explain?.departments || body?.explain?.agg) {   // 調査用: 部門一覧／ある部門の仕訳を科目・補助科目ごとに集計（読み取りのみ）
    try {
      const ex = body.explain; const { accessToken } = await getValidAccessToken(ex.tenant || "default");
      if (ex.departments) { const r = await mfFetch("/api/v3/departments", accessToken); const dj = await r.json(); return json({ success: true, departments: (dj.departments ?? []).map((d: any) => ({ id: d.id, name: d.name, code: d.code })) }); }
      const g = new Map<string, any>();
      for (let page = 1; page <= 20; page++) {
        const r = await mfFetch(`/api/v3/journals?start_date=${ex.agg.from}&end_date=${ex.agg.to}&per_page=500&page=${page}`, accessToken); const dj = await r.json();
        if (!r.ok) return json({ error: "取得失敗", detail: dj }, 502);
        for (const j of dj.journals ?? []) for (const br of j.branches ?? []) for (const [side, x] of [["借方", br.debitor], ["貸方", br.creditor]] as any) {
          if (!x || !String(x.department_name ?? "").includes(ex.agg.dept_needle)) continue;
          const k = `${side}|${x.account_name}|${x.sub_account_name ?? ""}|${x.department_name}`; const v = g.get(k) ?? { side, account: x.account_name, sub: x.sub_account_name ?? "", dept: x.department_name, n: 0, sum: 0, ex: br.remark ?? "" };
          v.n++; v.sum += Number(x.value) || 0; g.set(k, v);
        }
        if ((dj.journals ?? []).length < 500) break;
      }
      return json({ success: true, rows: [...g.values()].sort((a, b) => b.n - a.n) });
    } catch (e) { return json({ error: String((e as Error)?.message ?? e) }, 500); }
  }
  if (body?.explain?.raw || body?.explain?.accounts) {   // 調査用: 仕訳の明細を科目・補助科目の名前で検索／勘定科目の補助科目一覧
    try {
      const ex = body.explain; const { accessToken } = await getValidAccessToken(ex.tenant || "default");
      if (ex.accounts) {
        const r = await mfFetch("/api/v3/accounts", accessToken); const dj = await r.json();
        return json({ success: true, accounts: (dj.accounts ?? []).filter((a: any) => ex.accounts.includes(a.name)).map((a: any) => ({ name: a.name, id: ex.with_ids ? a.id : undefined, subs: (a.sub_accounts ?? []).map((x: any) => ex.with_ids ? { name: x.name, id: x.id } : x.name) })) });
      }
      const rows: any[] = [];
      for (let page = 1; page <= 10; page++) {
        const r = await mfFetch(`/api/v3/journals?start_date=${ex.raw.from}&end_date=${ex.raw.to}&per_page=500&page=${page}`, accessToken); const dj = await r.json();
        if (!r.ok) return json({ error: "取得失敗", detail: dj }, 502);
        for (const j of dj.journals ?? []) for (const br of j.branches ?? []) {
          const sd = (x: any) => x ? `${x.account_name ?? ""}${x.sub_account_name ? "/" + x.sub_account_name : ""}${x.department_name ? "[" + x.department_name + "]" : ""} ${x.value}` : "";
          const txt = `${sd(br.debitor)} ${sd(br.creditor)} ${br.remark ?? ""}`;
          if (txt.includes(ex.raw.needle)) rows.push({ date: j.transaction_date, no: j.number, debit: sd(br.debitor), credit: sd(br.creditor), remark: br.remark });
        }
        if ((dj.journals ?? []).length < 500) break;
      }
      return json({ success: true, rows });
    } catch (e) { return json({ error: String((e as Error)?.message ?? e) }, 500); }
  }
  if (body?.explain) {
    try {
      const ex = body.explain; const { accessToken } = await getValidAccessToken(ex.tenant || "default");
      const fo = await fetchOutflows(accessToken, ex.from, ex.to, "in");
      if ("error" in fo) return json({ error: fo.error }, 502);
      const fz = (t: string) => norm(t).replace(/[-‐-―－ｰ]/g, "ー"); const nd = fz(ex.needle).slice(0, 10);
      return json({ success: true, deposits: fo.outflows.filter((o) => [o.remark, o.sub, o.partner].some((x) => fz(x ?? "").includes(nd))).map((o) => ({ date: o.transaction_date, amount: o.amount, remark: o.remark, summary: o.summary })) });
    } catch (e) { return json({ error: String((e as Error)?.message ?? e) }, 500); }
  }

  // 1日1回の判定（force/dry_run のときは無視）
  if (!body?.force && !body?.dry_run) {
    const jstHour = (new Date().getUTCHours() + 9) % 24;
    if (jstHour < 9 || jstHour >= 22) return json({ success: true, skipped: "実行時間帯ではありません（日本時間9〜22時）" });
    const { data: last } = await db.from("payment_scan_runs").select("started_at").eq("ok", true).order("started_at", { ascending: false }).limit(1);
    if (last?.length && Date.now() - Date.parse(last[0].started_at) < 20 * 3600e3) return json({ success: true, skipped: "本日は実行済みです" });
  }
  const { data: run } = await db.from("payment_scan_runs").insert({ trigger: body?.force ? "force" : (body?.dry_run ? "dry_run" : "auto") }).select("id").single();

  try {
    // 対象の請求書
    const { data: invs, error: ie } = await db.from("invoices")
      .select("id, vendor_id, store_id, amount, due_date, journal_draft, vendor:vendors(name)")
      .not("mf_journal_id", "is", null).in("payment_status", ["wait", "csv", "processing"]).limit(500);
    if (ie) throw new Error("請求書の取得に失敗: " + ie.message);
    const vendorIds = [...new Set((invs ?? []).map((i: any) => i.vendor_id).filter(Boolean))];
    const accByVendor = new Map<string, any[]>();
    if (vendorIds.length) {
      const { data: accs } = await db.from("vendor_bank_accounts").select("vendor_id, store_id, payment_method").in("vendor_id", vendorIds).eq("is_current", true);
      for (const a of accs ?? []) { const l = accByVendor.get(a.vendor_id) ?? []; l.push(a); accByVendor.set(a.vendor_id, l); }
    }
    const methodOf = (r: any) => { const cur = accByVendor.get(r.vendor_id) ?? []; const a = cur.find((x) => r.store_id && x.store_id === r.store_id) || cur.find((x) => !x.store_id) || (cur.length === 1 ? cur[0] : null); return a ? (a.payment_method || "bank_transfer") : null; };
    const targets = body?.only_source ? [] : (invs ?? []).filter((r: any) => ["direct_debit", "other_bank_transfer"].includes(methodOf(r) ?? ""));
    const byTenant = new Map<string, any[]>();
    for (const r of targets) { const t = r.journal_draft?.tenant_id || "default"; const l = byTenant.get(t) ?? []; l.push(r); byTenant.set(t, l); }
    const nameOf = new Map<string, string>(targets.map((r: any) => [r.id, r.vendor?.name ?? "（不明）"]));

    const { data: conf } = await db.from("payment_match_candidates").select("journal_id").eq("status", "confirmed").eq("direction", "out");
    const usedJ = new Set((conf ?? []).map((x: any) => x.journal_id));
    const created: any[] = []; const errors: string[] = [];
    for (const [tenant, rs] of byTenant) {
      try {
        const items: PayItem[] = rs.map((r: any) => ({ invoice_id: r.id, vendor_id: r.vendor_id, vendor_name: r.vendor?.name ?? "", amount: Number(r.amount) || 0, due_date: r.due_date, method: methodOf(r) ?? undefined }));
        const range = dateRange(items, 5, 14);
        const { accessToken } = await getValidAccessToken(tenant);
        const fo = await fetchOutflows(accessToken, range.start, range.end, "out", tenant);
        if ("error" in fo) { errors.push(`${tenant}: ${fo.error}`); continue; }
        const { data: rl } = await db.from("payment_match_rules").select("vendor_id, pattern").eq("tenant_id", tenant);
        const cands = matchPayments(items, fo.outflows.filter((o) => !usedJ.has(o.journal_id)), (rl ?? []) as Rule[]);
        for (const c of cands) {
          const key = [c.kind, tenant, c.journal_id, [...c.invoice_ids].sort().join(",")].join("|");
          if (body?.dry_run) { created.push({ ...c, tenant, cand_key: key }); continue; }
          const { data: ex } = await db.from("payment_match_candidates").select("id").eq("cand_key", key).maybeSingle();
          if (ex) continue;   // 既に出した候補（確認済み・却下済み・通知済み）は繰り返さない
          const { error: insErr } = await db.from("payment_match_candidates").insert({ cand_key: key, kind: c.kind, tenant_id: tenant, invoice_ids: c.invoice_ids, journal_id: c.journal_id, transaction_date: c.transaction_date, outflow_amount: c.outflow_amount, invoice_total: c.invoice_total, diff: c.diff, score: c.score, reasons: c.reasons, summary: c.summary, remark: c.remark });
          if (!insErr) created.push({ ...c, tenant, cand_key: key });
        }
      } catch (e) { errors.push(`${tenant}: ${String((e as Error)?.message ?? e)}`); }
    }

    // もう振込待ちではない請求書だけの古い候補は片付ける
    if (!body?.dry_run) {
      const pendingIds = new Set(targets.map((r: any) => r.id));
      const { data: oldPend } = await db.from("payment_match_candidates").select("id, invoice_ids").eq("status", "pending").eq("direction", "out");
      const stale = (oldPend ?? []).filter((c: any) => !(c.invoice_ids ?? []).some((i: string) => pendingIds.has(i))).map((c: any) => c.id);
      if (stale.length) await db.from("payment_match_candidates").update({ status: "dismissed", decided_at: new Date().toISOString() }).in("id", stale);
    }

    // ===== 売上入金（売掛金）の照合：預金への入金仕訳と、入金待ちの売掛金を照合する =====
    let inOverdue: any[] = [];
    const inCreated: any[] = []; const autoDone: any[] = []; const inNames = new Map<string, string>();
    try {
      const since = new Date(Date.now() - 100 * 86400e3).toISOString().slice(0, 7);   // 直近約3か月
      const { data: ars } = await db.from("ar_receivables").select("id, source_name, year_month, store_id, corporation_id, expected_amount, expected_date")
        .not("mf_journal_id", "is", null).gt("expected_amount", 0).gte("year_month", since).limit(500);
      const arIds = (ars ?? []).map((r: any) => r.id);
      const paidSet = new Set<string>();
      for (let i = 0; i < arIds.length; i += 100) {
        const { data: dps } = await db.from("ar_deposits").select("receivable_id").in("receivable_id", arIds.slice(i, i + 100));
        for (const d of dps ?? []) paidSet.add(d.receivable_id);
      }
      const monthEnd = (ym: string) => { const [y, m] = ym.split("-").map(Number); return new Date(Date.UTC(y, m, 0)).toISOString().slice(0, 10); };
      const open = (ars ?? []).filter((r: any) => !paidSet.has(r.id) && r.source_name !== "現金売上" && (!body?.only_source || String(r.source_name ?? "").includes(body.only_source)));
      // 期日を過ぎても入金されていない売掛金（期日が無いものは売上月の月末＋14日）
      inOverdue = open.map((r: any) => ({ ...r, due: r.expected_date || new Date(Date.parse(monthEnd(r.year_month)) + 14 * 86400e3).toISOString().slice(0, 10) })).filter((r: any) => r.due < todayJst());
      const expMap = new Map<string, number>(open.map((r: any) => [r.id, Number(r.expected_amount) || 0]));
      const srcMap = new Map<string, string>(open.map((r: any) => [r.id, r.source_name ?? ""]));
      // 法人→MF事業者（法人名とMF事業者名の突き合わせ。1つに決まらなければトーホー側）
      const [{ data: corps }, { data: stores }, { data: tens }] = await Promise.all([
        db.from("corporations").select("id, name"), db.from("stores").select("id, corporation_id"), db.from("mf_oauth_tokens").select("id, label"),
      ]);
      const corpName = new Map((corps ?? []).map((c: any) => [c.id, c.name]));
      const storeCorp = new Map((stores ?? []).map((x: any) => [x.id, x.corporation_id]));
      const tenantOf = (r: any) => { const cid = r.corporation_id || storeCorp.get(r.store_id); const n = norm(corpName.get(cid) ?? ""); const hits = (tens ?? []).filter((t: any) => { const tn = norm(t.label ?? ""); return tn && n && (n.includes(tn) || tn.includes(n)); }); return hits.length === 1 ? hits[0].id : "default"; };
      const byT = new Map<string, any[]>();
      for (const r of open) { const t = tenantOf(r); const l = byT.get(t) ?? []; l.push(r); byT.set(t, l); inNames.set(r.id, `${r.source_name}（${r.year_month}）`); }
      const { data: confIn } = await db.from("payment_match_candidates").select("journal_id").eq("status", "confirmed").eq("direction", "in");
      const usedIn = new Set((confIn ?? []).map((x: any) => x.journal_id));
      for (const [tenant, rs] of byT) {
        try {
          const items: PayItem[] = [];
          for (const r of rs) items.push({ invoice_id: r.id, vendor_id: await counterpartyId(r.source_name ?? ""), vendor_name: r.source_name ?? "", amount: Number(r.expected_amount) || 0, due_date: r.expected_date || monthEnd(r.year_month), method: "in" });
          const range = dateRange(items, 5, 45);
          const { accessToken } = await getValidAccessToken(tenant);
          const fo = await fetchOutflows(accessToken, range.start, range.end, "in", tenant);
          if ("error" in fo) { errors.push(`売上入金 ${tenant}: ${fo.error}`); continue; }
          const { data: rl } = await db.from("payment_match_rules").select("vendor_id, pattern").eq("tenant_id", tenant);
          const cands = matchPayments(items, fo.outflows.filter((o) => !usedIn.has(o.journal_id)), (rl ?? []) as Rule[], 5, 45);
          for (const c of cands) {
            const key = ["in", c.kind, tenant, c.journal_id, [...c.invoice_ids].sort().join(",")].join("|");
            if (body?.dry_run) { inCreated.push({ ...c, tenant, cand_key: key }); continue; }
            const { data: ex } = await db.from("payment_match_candidates").select("id").eq("cand_key", key).maybeSingle();
            if (ex) continue;
            const { error: insErr } = await db.from("payment_match_candidates").insert({ cand_key: key, direction: "in", kind: c.kind, tenant_id: tenant, invoice_ids: c.invoice_ids, journal_id: c.journal_id, transaction_date: c.transaction_date, outflow_amount: c.outflow_amount, invoice_total: c.invoice_total, diff: c.diff, score: c.score, reasons: c.reasons, summary: c.summary, remark: c.remark });
            if (!insErr) inCreated.push({ ...c, tenant, cand_key: key });
          }
        } catch (e) { errors.push(`売上入金 ${tenant}: ${String((e as Error)?.message ?? e)}`); }
      }
      // 自動で入金済みにする（問題なしの条件: 点数75以上・差額0円・同じ仕訳や入金予定が他の候補と重ならない）。人が取り消すときは売上入金タブから
      if (!body?.dry_run && body?.auto_complete !== false) {
        const jCount = new Map<string, number>(), idCount = new Map<string, number>();
        for (const c of inCreated.filter((x) => x.kind !== "mismatch")) { jCount.set(c.journal_id, (jCount.get(c.journal_id) ?? 0) + 1); for (const id of c.invoice_ids) idCount.set(id, (idCount.get(id) ?? 0) + 1); }
        const taken = new Set<string>();
        for (const c of inCreated.filter((x) => x.kind !== "mismatch").sort((a, b) => b.score - a.score)) {
          if (c.score < 75 || c.diff !== 0 || jCount.get(c.journal_id) !== 1 || c.invoice_ids.some((id: string) => idCount.get(id) !== 1 || taken.has(id))) continue;
          const deps = c.invoice_ids.map((id: string) => ({ receivable_id: id, amount: c.kind === "single" ? c.outflow_amount : (expMap.get(id) ?? 0), deposit_date: c.transaction_date, bank_source: "MF仕訳から自動照合" }));
          const { error: dErr } = await db.from("ar_deposits").insert(deps);
          if (dErr) { errors.push("入金済みへの更新に失敗: " + dErr.message); continue; }
          c.invoice_ids.forEach((id: string) => taken.add(id));
          c._auto = true; autoDone.push(c);
          await db.from("payment_match_candidates").update({ status: "confirmed", decided_at: new Date().toISOString() }).eq("cand_key", c.cand_key);
          const pat = rulePatternOf(c.remark ?? "");
          if (pat.length >= 3) { const rules = []; for (const id of c.invoice_ids) rules.push({ vendor_id: await counterpartyId(srcMap.get(id) ?? ""), tenant_id: c.tenant, pattern: pat, sample_remark: String(c.remark ?? "").slice(0, 120) }); await db.from("payment_match_rules").upsert(rules, { onConflict: "vendor_id,tenant_id,pattern", ignoreDuplicates: true }); }
        }
      }
      if (!body?.dry_run) {   // 入金済みになった売掛金だけの古い候補は片付ける
        const openIds = new Set(open.map((r: any) => r.id));
        const { data: oldIn } = await db.from("payment_match_candidates").select("id, invoice_ids").eq("status", "pending").eq("direction", "in");
        const stale = (oldIn ?? []).filter((c: any) => !(c.invoice_ids ?? []).some((i: string) => openIds.has(i))).map((c: any) => c.id);
        if (stale.length) await db.from("payment_match_candidates").update({ status: "dismissed", decided_at: new Date().toISOString() }).in("id", stale);
      }
    } catch (e) { errors.push("売上入金の照合: " + String((e as Error)?.message ?? e)); }

    // Lark通知（新しい候補だけ）
    const label = (c: any) => groupNames(c.invoice_ids.map((i: string) => nameOf.get(i) ?? ""));
    const ok = created.filter((c) => c.kind !== "mismatch");
    const bad = created.filter((c) => c.kind === "mismatch");
    const lines: string[] = [];
    if (ok.length) {
      lines.push(`✅ 照合OK候補 ${ok.length}件（確認して「振込済み」にしてください）`);
      for (const c of ok.slice(0, 15)) lines.push(`・${label(c)} ${yen(c.outflow_amount)}（MF ${c.transaction_date}）${c.kind === "bundle" ? " ※まとめ払い" : ""}${c.score < 75 ? " ※要確認" : ""}`);
    }
    if (bad.length) {
      lines.push(`⚠️ 金額が合わない出金 ${bad.length}件（振込先は一致）`);
      for (const c of bad.slice(0, 15)) lines.push(`・${label(c)} 請求 ${yen(c.invoice_total)} ／ 出金 ${yen(c.outflow_amount)}（差 ${c.diff > 0 ? "+" : ""}${yen(c.diff)}・MF ${c.transaction_date}）`);
    }
    const inOk = inCreated.filter((c) => c.kind !== "mismatch" && !c._auto), inBad = inCreated.filter((c) => c.kind === "mismatch");
    const inLabel = (c: any) => groupNames(c.invoice_ids.map((i: string) => inNames.get(i) ?? ""));
    if (autoDone.length) {
      lines.push(`✅ 売上入金を自動で入金済みにしました ${autoDone.length}件（照合OK・取り消しは売上入金タブから）`);
      for (const c of autoDone.slice(0, 15)) lines.push(`・${inLabel(c)} ${yen(c.outflow_amount)}（MF ${c.transaction_date}）${c.kind === "bundle" ? " ※まとめ入金" : ""}`);
    }
    if (inOk.length) {
      lines.push(`💰 売上入金の照合OK候補 ${inOk.length}件（確認して「入金済み」にしてください）`);
      for (const c of inOk.slice(0, 15)) lines.push(`・${inLabel(c)} ${yen(c.outflow_amount)}（MF ${c.transaction_date}）${c.kind === "bundle" ? " ※まとめ入金" : ""}${c.score < 75 ? " ※要確認" : ""}`);
    }
    if (inBad.length) {
      lines.push(`⚠️ 売上入金で金額が合わないもの ${inBad.length}件（入金元は一致）`);
      for (const c of inBad.slice(0, 15)) lines.push(`・${inLabel(c)} 予定 ${yen(c.invoice_total)} ／ 入金 ${yen(c.outflow_amount)}（差 ${c.diff > 0 ? "+" : ""}${yen(c.diff)}・MF ${c.transaction_date}）`);
    }
    // 期日を過ぎても残っている支払い・入金（毎日の実行で通知。解消するまで毎日出る）
    const payOverdue = body?.only_source ? [] : (invs ?? []).filter((r: any) => r.due_date && r.due_date < todayJst());
    if (payOverdue.length) {
      lines.push(`⏰ 期日を過ぎても支払い済みになっていないもの ${payOverdue.length}件（合計 ${yen(payOverdue.reduce((t: number, r: any) => t + (Number(r.amount) || 0), 0))}）`);
      for (const r of [...payOverdue].sort((a: any, b: any) => a.due_date.localeCompare(b.due_date)).slice(0, 15)) lines.push(`・${r.vendor?.name ?? "（不明）"} ${yen(Number(r.amount) || 0)}（期日 ${md(r.due_date)}・${daysOver(r.due_date)}日超過）`);
    }
    if (inOverdue.length) {
      lines.push(`⏰ 期日を過ぎても入金されていない売上入金 ${inOverdue.length}件（合計 ${yen(inOverdue.reduce((t: number, r: any) => t + (Number(r.expected_amount) || 0), 0))}）`);
      for (const r of [...inOverdue].sort((a: any, b: any) => a.due.localeCompare(b.due)).slice(0, 15)) lines.push(`・${r.source_name}（${r.year_month}）${yen(Number(r.expected_amount) || 0)}（期日 ${md(r.due)}・${daysOver(r.due)}日超過）`);
    }
    if (errors.length) lines.push(`❗ 一部のMFを確認できませんでした: ${errors.join(" / ")}`);
    let notified = false;
    if (lines.length && !body?.dry_run) {
      notified = await larkPost(db, `【引き落とし・他行振込の自動照合】\n${lines.join("\n")}\n${PORTAL}`);
      if (notified && (created.length || inCreated.length)) await db.from("payment_match_candidates").update({ notified_at: new Date().toISOString() }).in("cand_key", [...created, ...inCreated].map((c) => c.cand_key));
    }
    if (!body?.dry_run && !body?.only_source) {   // 仕入高の月次確定の再判定（TK-222）。失敗しても照合は続ける
      try { await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/shiire-confirm-check`, { method: "POST", headers: { "Content-Type": "application/json", apikey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, Authorization: `Bearer ${Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")}` }, body: JSON.stringify({ secret: body.secret }) }); } catch (_) { /* 無視 */ }
    }
    const summary = { targets: targets.length, tenants: [...byTenant.keys()], ok: ok.length, mismatch: bad.length, in_ok: inOk.length, in_auto: autoDone.length, in_mismatch: inBad.length, overdue_pay: payOverdue.length, overdue_in: inOverdue.length, errors, notified };
    if (run?.id) await db.from("payment_scan_runs").update({ finished_at: new Date().toISOString(), ok: errors.length === 0, summary }).eq("id", run.id);
    return json({ success: true, ...summary, ...(body?.dry_run ? { preview: [...created.map((c) => ({ ...c, _in: false })), ...inCreated.map((c) => ({ ...c, _in: true }))].map((c) => ({ kind: c.kind, vendor: c._in ? inLabel(c) : label(c), invoice_total: c.invoice_total, outflow: c.outflow_amount, diff: c.diff, date: c.transaction_date, score: c.score, summary: c.summary, remark: c.remark, reasons: c.reasons })), message: lines.join("\n") } : {}) });
  } catch (e) {
    if (run?.id) await db.from("payment_scan_runs").update({ finished_at: new Date().toISOString(), ok: false, summary: { error: String((e as Error)?.message ?? e) } }).eq("id", run.id);
    return json({ error: "照合中にエラー: " + String((e as Error)?.message ?? e) }, 500);
  }
});
