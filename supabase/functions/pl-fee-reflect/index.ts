// MF仕訳 → PL自動反映（C-7拡張・ラウンド5指示書§6.1／設計書_広告費自動連携_§5・2026-09-01）
// 【2026-09-03拡張】ユーザー要望「会計入力したものを全てPL反映させるかどうかの欄を作ってほしい。
// 店舗・勘定科目・補助科目は会計仕訳から拾って、PL連携前に内容を確認で出してほしい」を受け、
// 従来の「事前登録した科目だけ対象」から「仕訳登録済みの請求書すべてが対象」に拡張。
// 1請求書の仕訳に複数の勘定科目が混ざっていても科目ごとに個別反映できるよう、実績を
// invoice_pl_reflections（1行=1請求書×1科目×1補助科目）に複数行持てるようにした
// （invoices.pl_fee_*列は「最初にPLへ反映した日時」等の簡易フラグとして引き続き使う。
// invoices.htmlの「📊 PLへ反映」パネルから呼ばれる）。
//
// 【同日・追加の重要な制約2点（ユーザー指摘）】
// ①「PL科目に限定」: 会計仕訳の借方科目を無条件に全部PLへ載せるのではなく、mf_pl_fee_accounts
//   に登録済みの科目（＝実際にPLの費用科目として使うもの）だけを対象にする。例:
//   家賃＋電気代がまとめて来る請求書で仕訳が「前払費用／水道光熱費」に分かれている場合、
//   水道光熱費だけがPL反映の対象になり、前払費用（資産科目）は対象に出さない
//   （mf_pl_fee_accountsは元は「PL反映パネルを出すかどうかのゲート」だったが、今回から
//   「どの科目がPL科目として有効か」の定義そのものとして使う＝設定タブの位置づけが変わった）。
// ②「精算書経由の店舗との二重計上防止」: 精算対象店舗（stores.seisan_target）の経費は、
//   精算書に入力すればA-9の自動連携（syncSeisanCategoriesToPl）で既にPLへ反映される仕組みが
//   別途あるため、この経路（invoice_pl_reflections→writePlFee→DB_PL直接書き込み）で
//   精算対象店舗を対象にすると同じ経費がDB_PLに2行できてしまう。そのため精算対象店舗は
//   このconfirmで明確に拒否し、精算書側で入力するよう案内する（フロント側でも選択肢から除外）。
//
// actionは6つ:
//   - "status": {invoice_id} → その請求書の対象外フラグ＋反映済み科目一覧を返す
//   - "confirm": 勘定科目・補助科目・対象年月・店舗×金額の割り振りを確定する。
//     body: {invoice_id, account_name, sub_account_name?, year_month(YYYY-MM-01), allocations:[{store_id,store_name,amount}]}
//     呼び出し前にinvoice_can_access()で権限確認。account_nameがmf_pl_fee_accounts未登録、または
//     allocationsに精算対象店舗が含まれる場合は拒否する（①②の制約）。
//     ①invoice_pl_reflectionsへ1行追加（同じ請求書×同じ科目×同じ補助科目が既にあれば重複反映として拒否）
//       ＋invoicesのpl_fee_reflected_atを（未設定なら）記録
//     ②経営ダッシュボードGAS（tori-dashboard・DASH_API_URL）の書き込みaction「writePlFee」を呼び、
//       DB_PL（＋BigQuery）への計上を依頼する（精算対象店舗は上記の理由でここには含まれない）。
//       sub_accountは既にGAS側で受け取り可能（DB_PL・PL管理システムのシートには現状まだ
//       補助科目の列が無いため書き込まれない＝担当Aへ別途依頼予定）
//   - "exclude"/"unexclude": 「この請求書はPLに反映しない」という明示的な決定を記録／取り消す
//   - "list_target_accounts"/"add_target_account"/"remove_target_account": 設定タブ用。
//     今後はここに登録した科目＝実際にPLへ反映できる科目そのもの（上記①）
import { createClient } from "npm:@supabase/supabase-js@2";
import { zeroPlSheet } from "../_shared/pl-sheet.ts";
import { operatorCorpMap } from "../_shared/store-operator.ts";

const cors: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });

const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const userClient = (req: Request) =>
  createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });

// tori-dashboardのGAS Web App URL（ad-cost-reflect/dash-sync/index.tsと同じ値。公開リポジトリのapp.jsにも
// 同じ値がある＝秘密情報ではない）
const DASH_API_URL = "https://script.google.com/macros/s/AKfycbwW0qhyEr0-uQWTaLg7MkQhurHq6wMoaOKL7uCCnI_bgnAsGB5-auqG_dm_Q9uJc3Kc/exec";

// 2026-10-21新設: 請求書由来のPL自動行を pl_entries へ直接書く（設計書 仮確定PLと実際PL §8 Q5=a・docs/調査_着地予想PL_請求書の直接書き込み設計）。
// 切替フラグ app_secrets.pl_direct_write='1' かつ 対象年月が 2026-10 以降のときだけ有効（既定=無効＝従来のGAS経由）。
// 行の形: source/memo='自動｜請求書'、source_key='inv:<請求書ID>:<反映ID>:<store_id>'（冪等キー）、item=MFの勘定科目、sub_item=MFの補助科目。
const PL_DIRECT_FROM = "2026-10";
const PL_CAT: Record<string, string> = {
  "役員報酬": "L", "法定福利費": "L", "通勤手当": "L", "旅費交通費": "L", "賞与積立": "L", "退職金等": "L",
  "家賃": "R", "リース料": "R", "家賃更新按分": "R", "広告宣伝費": "A", "販売促進費": "A",
  "その他売上": "S", "銀行返済": "X", "仕入（食材・飲料）": "F",
};
function plCat(name: string): string {   // tori-dashboard plSeisanGuessCat_ と同じ判定（未登録は O）
  if (PL_CAT[name]) return PL_CAT[name];
  if (/給料|雑給|人件費|法定福利|通勤/.test(name)) return "L";
  if (/広告|販促/.test(name)) return "A";
  if (/家賃|賃料/.test(name)) return "R";
  if (/仕入/.test(name)) return "F";
  if (/売上/.test(name)) return "S";
  return "O";
}
async function plDirectOn(db: any, ym: string): Promise<boolean> {
  if (String(ym).slice(0, 7) < PL_DIRECT_FROM) return false;
  const { data } = await db.from("app_secrets").select("value").eq("key", "pl_direct_write").maybeSingle();
  return String(data?.value ?? "").trim() === "1";
}
function plDirectRows(invoiceId: string, reflectionId: string, account: string, sub: string | null, ym: string, allocations: any[]) {
  return allocations.filter((a) => Number(a.amount) > 0 && a.store_id).map((a) => ({
    year_month: String(ym).slice(0, 7), store_id: a.store_id, item: account, category: plCat(account), amount: Number(a.amount),
    memo: "自動｜請求書", sub_item: sub || "", source: "自動｜請求書", source_key: `inv:${invoiceId}:${reflectionId}:${a.store_id}`,
  }));
}
async function plDirectWrite(db: any, rows: any[]): Promise<{ ok: boolean; error?: string }> {
  if (!rows.length) return { ok: true };
  const { data, error } = await db.rpc("pl_entries_bulk_upsert", { p_rows: rows, p_mode: "upsert", p_dry_run: false, p_actor: "invoice-direct", p_scope: [] });
  if (error) return { ok: false, error: error.message };
  if (!data?.ok) return { ok: false, error: JSON.stringify(data?.errors ?? data?.error).slice(0, 300) };
  return { ok: true };
}

// 2026-09-05新設：業務委託精算書自動連携（設計書_業務委託精算書自動連携_2026-09-04.md）。
// seisan-dashboardのGAS Web App URL（担当A実装・11章で本番デプロイ済み。DASH_API_URLとは別の
// GASプロジェクト＝別トークンPL_SYNC_TOKENで認証する）
const SEISAN_API_URL = "https://script.google.com/macros/s/AKfycbzwYN9uSEtcJHSKSVQCoQOrllhO7G6gR-E4dvP-V4o_VdGXr9VQx2mbYYPNyNEFSQCiKg/exec";
// 2026-09-08新設：ユーザー要望「黒霧屋はPLに反映させるか、精算書に反映させるか選べて、精算書に
// 反映しないで直でPLに反映させるようにできるようにして欲しい。請求書がトーホーになってる場合には
// トーホーで支払いしてるから精算書には入れない、請求書がN styleになっていたら立替払いしてるから
// 精算書に入れる、の定義です」に対応。invoices.html側（plfeeSeisanRoute）と全く同じ判定を
// サーバー側でも独立して行う（フロントは案内表示・UI制御用、サーバー側はここが最終防衛ライン）。
//   - seisan_target（完全業務委託店舗。じんべぇ川崎等）→ 常に"seisan"（対象法人に関わらず）
//   - seisan_pl_categories_targetのみ（黒霧屋 新横浜等。「使い分け」店舗）→
//       請求書の対象法人が店舗の運営法人（stores.corporation_id）と同じ＝運営法人自身が
//       直接支払っている（立替ではない）ので"direct"、対象法人が異なる（未設定含む）＝
//       別法人が立替払いをしている（後で精算が必要）ので"seisan"
//   - どちらのフラグも無い店舗 → "normal"
function plSeisanRoute(
  store: { seisan_target?: boolean; seisan_pl_categories_target?: boolean; corporation_id?: string | null },
  invoiceCorpId: string | null | undefined,
): "seisan" | "direct" | "normal" {
  if (!store) return "normal";
  if (store.seisan_target) return "seisan";
  if (store.seisan_pl_categories_target) return (invoiceCorpId && invoiceCorpId === store.corporation_id) ? "direct" : "seisan";
  return "normal";
}

// seisan-dashboard側のWeb App呼び出し規約: {fn:'関数名', args:[...]} を1本のPOSTで送るだけ
// （既存sd_apiCategorizedLines等と同じ形。設計書§5冒頭）
//
// 2026-09-05実機確認で判明：この呼び出し規約のGASディスパッチャは、関数自体の戻り値を
// そのまま返すのではなく、{ok:true, result:<関数の戻り値>}（fn呼び出し自体が例外を投げた
// 場合は{ok:false, error:...}）という1段外側のラッパーで包んで返す（診断用Edge Function
// diagseisanpingで実際にsd_apiGetLinesを叩いて確認済み。設計書§5-1/5-2に書かれている
// {ok,lines,...}等の戻り値は、このラッパーのresultの中身のこと）。
// 呼び出し側（sd_apiAddExternalLine/sd_apiGetLines）はこのresultをそのまま使えるよう、
// ここで1段アンラップしておく（ラッパーが無い形式で返ってきた場合はそのまま通す＝後方互換）
async function seisanCall(fn: string, args: unknown[]) {
  const res = await fetch(SEISAN_API_URL, {
    method: "POST",
    headers: { "Content-Type": "text/plain;charset=utf-8" },
    body: JSON.stringify({ fn, args }),
  });
  const text = await res.text();
  let outer: any;
  try {
    outer = JSON.parse(text);
  } catch {
    throw new Error("精算書APIの応答を読めませんでした: " + text.slice(0, 200));
  }
  if (outer && typeof outer === "object" && outer.ok === false) {
    throw new Error(outer.error || "精算書API呼び出し自体が失敗しました（" + fn + "）");
  }
  return (outer && typeof outer === "object" && "result" in outer) ? outer.result : outer;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return json({ error: "POSTのみ対応" }, 405);

  let body: any;
  try { body = await req.json(); } catch { return json({ error: "JSONの読み取りに失敗しました" }, 400); }
  const action = body?.action;

  const uc = userClient(req);
  // 2026-10-14: zero_orphan（孤立したPLシート行を0円にする・管理用）だけは、サーバー間の共有シークレットでも呼べる
  let bySecret = false;
  if ((action === "zero_orphan" || action === "retry_sheet_sync" || action === "rebuild_pl_rows" || action === "direct_rebuild") && body?.secret) {
    const { data: sr } = await svc().from("app_secrets").select("value").eq("key", "invoice_intake_secret").maybeSingle();
    bySecret = !!sr?.value && body.secret === sr.value;
  }
  if (!bySecret) {
    const { data: canAccess, error: accessErr } = await uc.rpc("invoice_can_access");
    if (accessErr || canAccess !== true) return json({ error: "権限がありません" }, 403);
  }

  try {
    // 2026-10-21新設: 請求書由来の確定行を pl_entries へ直接書く切替の準備・比較レポート（設計書 Q-C3）。
    //   body: { secret, action:"direct_rebuild", months:["2026-10",...], dry?:true }。2026-10以降のみ。
    //   dry=true: 書かずに、店舗×科目ごとの「いまのpl_entries（旧GAS由来の自動行）」と「請求書記録から作る直接行」の合計を比べて返す。
    //   dry=false: 直接行を upsert（冪等キー inv:…）。旧GAS由来行の除去は切替日の手順で別に行う（二重計上に注意）。
    if (action === "direct_rebuild") {
      const db = svc();
      const months: string[] = (Array.isArray(body?.months) && body.months.length ? body.months : [PL_DIRECT_FROM]).map(String).filter((m) => m >= PL_DIRECT_FROM);
      if (!months.length) return json({ error: "2026-10以降の月を指定してください" }, 400);
      const { data: refls } = await db.from("invoice_pl_reflections").select("id, invoice_id, account_name, sub_account_name, year_month, allocations, reflection_route").eq("reflection_route", "direct");
      const rows: any[] = [];
      for (const r of refls ?? []) if (months.includes(String(r.year_month).slice(0, 7))) rows.push(...plDirectRows(r.invoice_id, r.id, r.account_name, r.sub_account_name, r.year_month, r.allocations ?? []));
      if (body?.dry) {
        const { data: cur } = await db.from("pl_entries").select("year_month, store_id, item, amount, source, sub_item").is("deleted_at", null).in("year_month", months).like("source", "自動｜%").neq("source", "自動｜精算書").neq("source", "自動｜仕入高差額調整").neq("source", "自動｜スポット人件費");
        const key = (x: any) => `${x.year_month}|${x.store_id}|${x.item}`;
        const a = new Map<string, number>(), b = new Map<string, number>();
        for (const x of cur ?? []) if (x.source !== "自動｜請求書") a.set(key(x), (a.get(key(x)) ?? 0) + Number(x.amount));
        for (const x of rows) b.set(key(x), (b.get(key(x)) ?? 0) + Number(x.amount));
        const { data: st } = await db.from("stores").select("id, name");
        const nm = new Map((st ?? []).map((x: any) => [x.id, x.name]));
        const diff: string[] = [];
        for (const k of new Set([...a.keys(), ...b.keys()])) { const d = (b.get(k) ?? 0) - (a.get(k) ?? 0); const [ym, sid, item] = k.split("|"); if (d !== 0) diff.push(`${ym}|${nm.get(sid) ?? sid}|${item}｜旧GAS由来 ${a.get(k) ?? 0} → 直接 ${b.get(k) ?? 0}（差 ${d > 0 ? "+" : ""}${d}）`); }
        return json({ success: true, dry: true, direct_rows: rows.length, old_rows: (cur ?? []).length, mismatches: diff.length, diff });
      }
      const wr = await plDirectWrite(db, rows);
      if (!wr.ok) return json({ error: "pl_entriesへの書き込みに失敗: " + wr.error }, 500);
      return json({ success: true, written: rows.length });
    }
    // 2026-10-19新設: 請求書由来のPL自動行の作り直し（書き込みの重なりで補助科目+請求書IDが別行のものになった行の修復）。
    //   body: { secret, action:"rebuild_pl_rows", months:["2026-08",...], dry?:true }。正しい内容は invoice_pl_reflections（direct）から作る。
    //   dry=true は書き込まず、取り除く行・入れる行・店舗×科目ごとの合計の差を返す。実行すると、成功した反映の同期エラー表示も消す
    if (action === "rebuild_pl_rows") {
      const db = svc();
      const months: string[] = (Array.isArray(body?.months) && body.months.length ? body.months : ["2026-08", "2026-09", "2026-10"]).map(String);
      const { data: all } = await db.from("invoice_pl_reflections").select("id, invoice_id, account_name, sub_account_name, year_month, allocations, reflection_route").eq("reflection_route", "direct");
      const rows: any[] = []; const idSet = new Set<string>(); const reflIds: string[] = [];
      for (const r of all ?? []) {
        idSet.add(String(r.invoice_id));
        if (!months.includes(String(r.year_month).slice(0, 7))) continue;
        reflIds.push(r.id);
        for (const a of (r.allocations ?? [])) if (Number(a.amount) > 0) rows.push({ ym: String(r.year_month).slice(0, 7), store: a.store_name, account: r.account_name, sub: r.sub_account_name || "", amount: Number(a.amount), source: r.invoice_id });
      }
      const tk = Deno.env.get("AD_COST_WRITE_TOKEN"); if (!tk) return json({ error: "AD_COST_WRITE_TOKEN が未設定です" }, 500);
      let text = "", j: any = null;
      for (let attempt = 1; attempt <= 4 && !j; attempt++) {
        const res = await fetch(DASH_API_URL, { method: "POST", headers: { "Content-Type": "text/plain;charset=utf-8" }, body: JSON.stringify({ action: "repairPlAutoRows", token: tk, months, invoice_ids: [...idSet], rows, dry: !!body?.dry }) });
        text = await res.text(); try { j = JSON.parse(text); } catch { j = null; await new Promise((rs) => setTimeout(rs, 3000 * attempt)); }
      }
      if (!j) return json({ error: "GASの応答を読めませんでした: " + text.slice(0, 200) }, 502);
      if (!j.ok) return json({ error: j.error || "GAS側で失敗しました", detail: j }, 502);
      if (body?.dry) {
        const sum = (arr: any[]) => { const m = new Map<string, number>(); for (const x of arr) { const k = `${x.ym}|${x.store}|${x.account}`; m.set(k, (m.get(k) ?? 0) + Number(x.amount)); } return m; };
        const rm = sum(j.removed_rows ?? []), ad = sum(j.added_rows ?? []); const diff: string[] = [];
        for (const k of new Set([...rm.keys(), ...ad.keys()])) { const d = (ad.get(k) ?? 0) - (rm.get(k) ?? 0); if (d !== 0) diff.push(`${k} ${d > 0 ? "+" : ""}${d}`); }
        return json({ success: true, dry: true, removed: j.removed, added: j.added, normalized: j.normalized, unknown: j.unknown, unknown_rows: j.unknown_rows, total_diff_by_store_account: diff, removed_rows: j.removed_rows, added_rows: j.added_rows });
      }
      if (reflIds.length) await db.from("invoice_pl_reflections").update({ sheet_synced_at: new Date().toISOString(), sheet_sync_error: null }).in("id", reflIds);
      return json({ success: true, removed: j.removed, added: j.added, normalized: j.normalized, unknown: j.unknown, plsys: j.plsys, bq: j.bq });
    }
    // 2026-10-19新設: PLシートへの書き込みが一時的なGASの不調（HTMLが返る等）で失敗したまま残っている直接反映（direct）を、保存済みの内容でやり直す。
    //   body: { secret, action:"retry_sheet_sync", dry?:true, ids?:[反映ID] }。書き込みは writePlFee（請求書IDで冪等に差し替え）と同じ
    if (action === "retry_sheet_sync") {
      const db = svc();
      let q = db.from("invoice_pl_reflections").select("id, invoice_id, account_name, sub_account_name, year_month, allocations, reflection_route, sheet_sync_error")
        .not("sheet_sync_error", "is", null).eq("reflection_route", "direct").limit(100);
      if (Array.isArray(body?.ids) && body.ids.length) q = q.in("id", body.ids);
      const { data: rows } = await q;
      const tk = Deno.env.get("AD_COST_WRITE_TOKEN"); if (!tk) return json({ error: "AD_COST_WRITE_TOKEN が未設定です" }, 500);
      const out: any[] = [];
      for (const r of rows ?? []) {
        const { data: inv } = await db.from("invoices").select("vendor_name").eq("id", r.invoice_id).maybeSingle();
        const label = `${r.account_name}${r.sub_account_name ? "/" + r.sub_account_name : ""}（${inv?.vendor_name ?? ""}・${String(r.year_month).slice(0, 7)}）`;
        if (body?.dry) { out.push({ id: r.id, label, before: String(r.sheet_sync_error).slice(0, 60) }); continue; }
        let ok = false, err: string | null = null;
        for (let attempt = 1; attempt <= 3 && !ok; attempt++) {
          try {
            const res = await fetch(DASH_API_URL, { method: "POST", headers: { "Content-Type": "text/plain;charset=utf-8" }, body: JSON.stringify({
              action: "writePlFee", token: tk, year_month: String(r.year_month).slice(0, 7), account_name: r.account_name, sub_account: r.sub_account_name || undefined,
              allocations: (r.allocations ?? []).map((a: any) => ({ store_name: a.store_name, amount: Number(a.amount) })), source_invoice_id: r.invoice_id, vendor_name: inv?.vendor_name }) });
            const text = await res.text(); let j: any; try { j = JSON.parse(text); } catch { throw new Error("GASの応答を読めませんでした"); }
            if (!j.ok) throw new Error(j.error || "GAS側で失敗しました");
            ok = true; err = null;
          } catch (e) { err = String((e as Error)?.message ?? e); await new Promise((rs) => setTimeout(rs, 3000 * attempt)); }
        }
        await db.from("invoice_pl_reflections").update({ sheet_synced_at: ok ? new Date().toISOString() : null, sheet_sync_error: ok ? null : err }).eq("id", r.id);
        out.push({ id: r.id, label, ok, error: err });
      }
      return json({ success: true, count: out.length, items: out });
    }
    // 2026-10-14新設: 請求書が既に無い（または取り消し済み）のにDB_PLに残っている行（外部連携:<source_key>）を0円にする
    if (action === "zero_orphan") {
      const sk = String(body?.source_key ?? "").trim(); const acc = String(body?.account_name ?? "").trim();
      const ym = String(body?.year_month ?? "").trim(); const names: string[] = Array.isArray(body?.store_names) ? body.store_names : [];
      if (!sk || !acc || !/^\d{4}-\d{2}/.test(ym) || !names.length) return json({ error: "source_key・account_name・year_month・store_names は必須です" }, 400);
      const r = await zeroPlSheet({ accountName: acc, subAccount: String(body?.sub_account_name ?? "").trim() || null, ym, storeNames: names, sourceId: sk });
      return json({ success: r.ok, stores: r.stores, error: r.error ?? null }, r.ok ? 200 : 500);
    }

    if (action === "list_target_accounts") {
      const db = svc();
      const { data, error } = await db.from("mf_pl_fee_accounts").select("*").order("account_name");
      if (error) return json({ error: error.message }, 500);
      return json({ success: true, accounts: data ?? [] });
    }

    if (action === "add_target_account") {
      const accountName: string = (body?.account_name ?? "").trim();
      const subAccountName: string = (body?.sub_account_name ?? "").trim();
      if (!accountName) return json({ error: "勘定科目名は必須です" }, 400);
      const defaultLabel = accountName + (subAccountName ? "/" + subAccountName : "");
      const db = svc();
      const { error } = await db.from("mf_pl_fee_accounts").insert({
        account_name: accountName, sub_account_name: subAccountName || null,
        pl_label: (body?.pl_label ?? "").trim() || defaultLabel,
      });
      if (error) return json({ error: error.message.includes("duplicate") ? "既に登録されています" : error.message }, 500);
      return json({ success: true });
    }

    if (action === "remove_target_account") {
      const id = body?.id;
      if (!id) return json({ error: "idは必須です" }, 400);
      const db = svc();
      const { error } = await db.from("mf_pl_fee_accounts").delete().eq("id", id);
      if (error) return json({ error: error.message }, 500);
      return json({ success: true });
    }

    if (action === "status") {
      const invoiceId = body?.invoice_id;
      if (!invoiceId) return json({ error: "invoice_idは必須です" }, 400);
      const { data: inv, error: invErr } = await uc.from("invoices")
        .select("id, pl_fee_excluded_at, pl_fee_excluded_by").eq("id", invoiceId).maybeSingle();
      if (invErr) return json({ error: "確認に失敗しました: " + invErr.message }, 500);
      if (!inv) return json({ error: "対象が見つからないか権限がありません" }, 403);
      // 2026-09-05追加：業務委託精算書自動連携（reflection_route='seisan'）の行を区別して
      // 返せるよう、新設列（reflection_route/seisan_store_name/pl_status/pl_status_checked_at）も選択する
      // 2026-09-17追加：精算書への添付ファイル反映状況（attached_count/attachment_error）も
      // 返す。ユーザー報告「精算書の添付にファイルが無い」に対応し、反映履歴カードで
      // 添付の成否を確認できるようにするため
      const { data: refl, error: reflErr } = await uc.from("invoice_pl_reflections")
        .select("id, account_name, sub_account_name, year_month, allocations, reflected_at, sheet_synced_at, sheet_sync_error, reflection_route, seisan_store_name, pl_status, pl_status_checked_at, attached_count, attachment_error, tax_rate, item_name")
        .eq("invoice_id", invoiceId).order("reflected_at", { ascending: true });
      if (reflErr) return json({ error: "確認に失敗しました: " + reflErr.message }, 500);
      return json({ success: true, excluded_at: inv.pl_fee_excluded_at, reflections: refl ?? [] });
    }

    if (action === "exclude" || action === "unexclude") {
      const invoiceId = body?.invoice_id;
      if (!invoiceId) return json({ error: "invoice_idは必須です" }, 400);
      const rawToken = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
      const { data: userData } = rawToken ? await uc.auth.getUser(rawToken) : { data: { user: null } } as any;
      const patch = action === "exclude"
        ? { pl_fee_excluded_at: new Date().toISOString(), pl_fee_excluded_by: userData?.user?.id ?? null }
        : { pl_fee_excluded_at: null, pl_fee_excluded_by: null };
      const { error } = await uc.from("invoices").update(patch).eq("id", invoiceId);
      if (error) return json({ error: "保存に失敗しました: " + error.message }, 500);
      return json({ success: true });
    }

    if (action === "confirm") {
      const invoiceId = body?.invoice_id;
      const accountName: string = (body?.account_name ?? "").trim();
      const subAccountName: string = (body?.sub_account_name ?? "").trim();
      const yearMonth: string = body?.year_month || "";
      const allocations: any[] = Array.isArray(body?.allocations) ? body.allocations : [];
      if (!invoiceId || !accountName || !/^\d{4}-\d{2}-01$/.test(yearMonth)) {
        return json({ error: "勘定科目・対象年月（YYYY-MM-01）・請求書IDは必須です" }, 400);
      }
      if (!allocations.length) return json({ error: "店舗×金額の割り振りが0件です" }, 400);
      let total = 0;
      for (const a of allocations) {
        const amt = Number(a.amount);
        if (!a.store_id || !a.store_name || !Number.isFinite(amt) || amt <= 0) {
          return json({ error: "各行に店舗と金額（0円より大きい）を入力してください" }, 400);
        }
        total += amt;
      }

      const { data: inv, error: invErr } = await uc.from("invoices")
        .select("id, email_id, vendor_name, corporation_id").eq("id", invoiceId).maybeSingle();
      if (invErr) return json({ error: "確認に失敗しました: " + invErr.message }, 500);
      if (!inv) return json({ error: "対象が見つからないか権限がありません" }, 403);

      // ①PL科目に限定: mf_pl_fee_accounts未登録の科目はPLへ反映させない（前払費用等の資産科目を
      // 誤ってPLに載せてしまう事故防止）
      // 2026-09-10修正: mf_pl_fee_accountsは勘定科目・補助科目を分けて登録する形に変わった
      // （account_name×sub_account_nameの組で1件）ため、account_nameだけでなくsub_account_name
      // も一致するかを見る（従来はaccount_name完全一致だけを見ており、勘定科目・補助科目を
      // 分けて指定する新UIでは常に不一致になり「登録されていません」で弾かれてしまっていた）
      let plAccQuery = uc.from("mf_pl_fee_accounts").select("id").eq("account_name", accountName);
      plAccQuery = subAccountName ? plAccQuery.eq("sub_account_name", subAccountName) : plAccQuery.is("sub_account_name", null);
      const { data: plAcc, error: plAccErr } = await plAccQuery.maybeSingle();
      if (plAccErr) return json({ error: "PL科目の確認に失敗しました: " + plAccErr.message }, 500);
      if (!plAcc) return json({ error: `「${accountName}${subAccountName ? "/" + subAccountName : ""}」はPL科目として登録されていません。設定タブの「PL連携対象科目」で先に登録してください（資産科目等をPLに載せてしまうミスを防ぐための確認です）` }, 400);

      // ②精算対象店舗との二重計上防止: 精算対象店舗は精算書側で入力すれば別途PLへ自動連携されるため、
      // この経路（DB_PL直接書き込み）の対象には含めない。
      // 2026-09-08修正：黒霧屋 新横浜のように「運営委託費の自動連携(seisan_target)は対象外だが、
      // 個別経費のPL反映(seisan_pl_categories_target)だけは精算書経由」という店舗は、常に拒否するのではなく
      // plSeisanRoute()で請求書の対象法人から判定する（"seisan"の場合だけ拒否。"direct"＝運営法人自身が
      // 直接支払っている請求書の場合はここを通す）
      const storeIds = allocations.map((a) => a.store_id).filter(Boolean);
      if (storeIds.length) {
        const { data: candStores, error: seisanErr } = await uc.from("stores")
          .select("id, name, corporation_id, seisan_target, seisan_pl_categories_target").in("id", storeIds);
        if (seisanErr) return json({ error: "店舗の確認に失敗しました: " + seisanErr.message }, 500);
        const opMap = await operatorCorpMap(svc(), storeIds, body?.year_month);   // 運営会社が時期で変わる店舗（黒霧屋 新横浜）は、その月の運営会社で判定
        const blockedStores = (candStores ?? []).filter((s: any) => plSeisanRoute({ ...s, corporation_id: opMap.get(s.id) ?? s.corporation_id }, inv.corporation_id) === "seisan");
        if (blockedStores.length) {
          const names = blockedStores.map((s: any) => s.name).join("・");
          return json({ error: `${names}は精算対象店舗のため、ここではPLに反映できません（精算書に入力すると自動でPLにも反映されるため、二重計上になってしまいます）。精算書側で入力してください` }, 400);
        }
      }

      // 重複反映防止は「請求書×勘定科目×補助科目」単位（同じ請求書でも別の科目なら別枠として反映できる）
      let dupQuery = uc.from("invoice_pl_reflections").select("id").eq("invoice_id", invoiceId).eq("account_name", accountName);
      dupQuery = subAccountName ? dupQuery.eq("sub_account_name", subAccountName) : dupQuery.is("sub_account_name", null);
      const { data: dup, error: dupErr } = await dupQuery.maybeSingle();
      if (dupErr) return json({ error: "確認に失敗しました: " + dupErr.message }, 500);
      if (dup) return json({ error: `この科目（${accountName}${subAccountName ? "/" + subAccountName : ""}）は既にPLへ反映済みです（重複反映防止）` }, 409);

      const db = svc();
      const nowIso = new Date().toISOString();
      const rawToken = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
      const { data: userData } = rawToken ? await uc.auth.getUser(rawToken) : { data: { user: null } } as any;

      const { data: reflRow, error: insErr } = await uc.from("invoice_pl_reflections").insert({
        invoice_id: invoiceId, account_name: accountName, sub_account_name: subAccountName || null,
        year_month: yearMonth, allocations, reflected_by: userData?.user?.id ?? null,
      }).select("id").maybeSingle();
      if (insErr) return json({ error: "反映内容の保存に失敗しました: " + insErr.message }, 500);

      // 一覧・ダッシュボードのバッジ表示用に「最初にPLへ反映した日時」だけ簡易フラグとして記録（未設定時のみ）
      await uc.from("invoices").update({ pl_fee_reflected_at: nowIso, updated_at: nowIso })
        .eq("id", invoiceId).is("pl_fee_reflected_at", null);

      await db.from("invoice_audit_logs").insert({
        entity_type: "invoice_email", entity_id: inv.email_id, action: "pl_fee_reflected", actor_type: "human",
        note: `PLへ反映（科目: ${accountName}${subAccountName ? "/" + subAccountName : ""}／対象: ${yearMonth.slice(0, 7)}／合計: ${total.toLocaleString()}円／${allocations.length}店舗）`,
      });

      let sheetSynced = false, sheetError: string | null = null;
      const directOn = await plDirectOn(db, yearMonth);
      if (directOn) {   // 2026-10-21: pl_entries へ直接書く（GAS経由は使わない）
        const wr = await plDirectWrite(db, plDirectRows(invoiceId, reflRow?.id, accountName, subAccountName || null, yearMonth, allocations));
        sheetSynced = wr.ok; sheetError = wr.ok ? null : wr.error ?? "pl_entriesへの書き込みに失敗";
      } else try {
        const tk = Deno.env.get("AD_COST_WRITE_TOKEN"); // writeAdCostと同じ共有トークン（担当AのwritePlFee action用）
        if (!tk) throw new Error("AD_COST_WRITE_TOKEN が未設定です");
        const res = await fetch(DASH_API_URL, {
          method: "POST",
          headers: { "Content-Type": "text/plain;charset=utf-8" },
          body: JSON.stringify({
            action: "writePlFee", token: tk,
            year_month: yearMonth.slice(0, 7), account_name: accountName, sub_account: subAccountName || undefined,
            allocations: allocations.map((a) => ({ store_name: a.store_name, amount: Number(a.amount) })),
            source_invoice_id: invoiceId, vendor_name: inv.vendor_name,
          }),
        });
        const text = await res.text();
        let j: any;
        try { j = JSON.parse(text); } catch { throw new Error("GASの応答を読めませんでした: " + text.slice(0, 200)); }
        if (!j.ok) throw new Error(j.error || "GAS側で失敗しました");
        sheetSynced = true;
      } catch (e) {
        sheetError = String((e as Error)?.message ?? e);
      }

      await db.from("invoice_pl_reflections").update({
        sheet_synced_at: sheetSynced ? new Date().toISOString() : null,
        sheet_sync_error: sheetError,
      }).eq("id", reflRow?.id);

      return json({ success: true, account_name: accountName, sub_account_name: subAccountName || null, year_month: yearMonth, total, sheet_synced: sheetSynced, sheet_error: sheetError });
    }

    // ============================================================
    // 2026-09-05新規：業務委託精算書自動連携（設計書_業務委託精算書自動連携_2026-09-04.md）。
    // 精算対象店舗（stores.seisan_target/seisan_pl_categories_target）の分は、DB_PLへ直接では
    // なく業務委託精算書（seisan-dashboard）へ登録する。設計書§4のとおり「1回の呼び出しは
    // 1店舗1明細」が前提のため、店舗ごとにinvoice_pl_reflectionsを1行作る（reflection_route=
    // 'seisan'。allocationsは常に1要素）。sourceKeyにはこの行のid（新規なら発行直後のid、
    // 既存なら再利用）を使い"invoice:<invoice_id>:<この行のid>"とすることで、同じ
    // 請求書×科目×店舗の組み合わせを編集し直しても同じsourceKeyで冪等に上書きされるようにする。
    // ============================================================
    if (action === "seisan_confirm") {
      const invoiceId = body?.invoice_id;
      const accountName: string = (body?.account_name ?? "").trim();
      const subAccountName: string = (body?.sub_account_name ?? "").trim();
      const itemName: string = (body?.item_name ?? "").trim() || accountName;
      const taxRate: string = body?.tax_rate || "10%";
      const yearMonth: string = body?.year_month || "";
      const allocations: any[] = Array.isArray(body?.allocations) ? body.allocations : [];
      if (!invoiceId || !accountName || !/^\d{4}-\d{2}-01$/.test(yearMonth)) {
        return json({ error: "勘定科目・対象年月（YYYY-MM-01）・請求書IDは必須です" }, 400);
      }
      if (!allocations.length) return json({ error: "店舗×金額の割り振りが0件です" }, 400);
      if (!["10%", "8%", "非課税"].includes(taxRate)) return json({ error: "税率は10%/8%/非課税のいずれかです" }, 400);
      for (const a of allocations) {
        const amt = Number(a.amount);
        if (!a.store_id || !a.store_name || !Number.isFinite(amt) || amt <= 0) {
          return json({ error: "各行に店舗と金額（0円より大きい）を入力してください" }, 400);
        }
        // 2026-10-13追加：同じ請求書・同じ科目でも8%と10%の仕入は別の行として精算書へ登録できるよう、行ごとの税率（a.tax_rate）を許可する（省略時は全体のtax_rate）
        if (a.tax_rate != null && !["10%", "8%", "非課税"].includes(a.tax_rate)) return json({ error: "税率は10%/8%/非課税のいずれかです" }, 400);
      }

      const { data: inv, error: invErr } = await uc.from("invoices")
        .select("id, email_id, vendor_name, corporation_id").eq("id", invoiceId).maybeSingle();
      if (invErr) return json({ error: "確認に失敗しました: " + invErr.message }, 500);
      if (!inv) return json({ error: "対象が見つからないか権限がありません" }, 403);

      // このactionの対象は精算対象店舗のみ（direct route側との二重計上防止の裏返し）。
      // 2026-09-08修正：黒霧屋のような「使い分け」店舗は、この請求書の対象法人によって
      // plSeisanRoute()が"direct"（PL直接反映）と判定する場合は、ここ（精算書登録）には
      // 入れられないようにする（confirm側の拒否と対になる、ユーザー定義の業務ルール）
      const storeIds = allocations.map((a) => a.store_id).filter(Boolean);
      const { data: storeRows, error: storeErr } = await uc.from("stores")
        .select("id, name, corporation_id, seisan_target, seisan_pl_categories_target, seisan_store_name").in("id", storeIds);
      if (storeErr) return json({ error: "店舗の確認に失敗しました: " + storeErr.message }, 500);
      const opMap2 = await operatorCorpMap(svc(), storeIds, yearMonth);   // 運営会社が時期で変わる店舗（黒霧屋 新横浜）は、その月の運営会社で判定
      const storeMap = new Map((storeRows ?? []).map((s: any) => [s.id, { ...s, corporation_id: opMap2.get(s.id) ?? s.corporation_id }]));
      for (const a of allocations) {
        const s = storeMap.get(a.store_id);
        if (!s) return json({ error: `店舗が見つかりません（${a.store_name}）` }, 400);
        const route = plSeisanRoute(s, inv.corporation_id);
        if (route === "normal") {
          return json({ error: `${s.name}は精算対象店舗ではありません。この店舗は「PLへ反映」（直接反映）から登録してください` }, 400);
        }
        if (route === "direct") {
          return json({ error: `${s.name}はこの請求書の対象法人（運営元法人と同じ）では直接支払い扱いのため、業務委託精算書には登録できません。「PLへ反映」（直接反映）から登録してください` }, 400);
        }
        if (!s.seisan_store_name) {
          return json({ error: `${s.name}の「精算書店舗名」が店舗マスタに未設定です。設定タブから設定してから登録してください` }, 400);
        }
      }

      const tk = Deno.env.get("PL_SYNC_TOKEN");
      if (!tk) return json({ error: "PL_SYNC_TOKEN が未設定です（担当Cまでご連絡ください）" }, 500);

      const db = svc();
      const rawToken = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
      const { data: userData } = rawToken ? await uc.auth.getUser(rawToken) : { data: { user: null } } as any;
      const monthKey = yearMonth.slice(0, 7);
      const results: { store: string; ok: boolean; error?: string; attachments?: number }[] = [];
      let anyOk = false;

      // 2026-09-10追加：ユーザー要望「請求書のところから仕分け・登録したときの添付ファイルも
      // 精算書に自動で添付されるようにしてほしい」に対応。従来はsd_apiAddExternalLineで明細
      // （店舗・科目・金額）だけを登録しており、請求書の証憑ファイル自体は精算書側に一切渡って
      // いなかった。ここで請求書の添付（invoice_attachments）を一度だけ読み込み、店舗ごとの
      // 登録が成功するたびsd_apiUploadAttachment（新設・PL_SYNC_TOKEN認証のサーバー間API）で
      // 精算書のDriveフォルダへアップロードする（mf-journal/index.tsのマネーフォワード証憑添付
      // と同じchunk方式のbase64エンコードを使い回す）
      const { data: atts } = await db.from("invoice_attachments")
        .select("file_name, storage_path, mime_type, size_bytes").eq("invoice_id", invoiceId)
        .order("created_at").limit(5);
      const attachmentFiles: { file_name: string; mime_type: string | null; b64: string }[] = [];
      for (const at of atts ?? []) {
        if ((at.size_bytes ?? 0) > 15 * 1024 * 1024) continue; // 大きすぎるものはスキップ（413対策）
        const { data: blob, error: dlErr } = await db.storage.from("invoice-files").download(at.storage_path);
        if (dlErr || !blob) continue;
        const bytes = new Uint8Array(await blob.arrayBuffer());
        let binary = "";
        const chunkSize = 0x8000;
        for (let i = 0; i < bytes.length; i += chunkSize) binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize));
        attachmentFiles.push({ file_name: at.file_name || "attachment", mime_type: at.mime_type, b64: btoa(binary) });
      }

      for (const a of allocations) {
        const s = storeMap.get(a.store_id);
        // 重複防止（同じ請求書×科目×補助科目×店舗×税率の既存行があれば、それを更新扱いにする＝同じsourceKeyで上書き）
        // 2026-10-13修正：税率もキーに含める。従来は税率違い（8%と10%）の仕入が同じキーになり、片方がもう片方を上書きして精算書に1行しか入らなかった
        const lineTax: string = a.tax_rate || taxRate;
        let dupQuery = uc.from("invoice_pl_reflections").select("id, seisan_line_key")
          .eq("invoice_id", invoiceId).eq("account_name", accountName).eq("reflection_route", "seisan")
          .eq("seisan_store_name", s.seisan_store_name).eq("tax_rate", lineTax);
        dupQuery = subAccountName ? dupQuery.eq("sub_account_name", subAccountName) : dupQuery.is("sub_account_name", null);
        const { data: existing } = await dupQuery.maybeSingle();

        let reflectionId: string | undefined = existing?.id;
        let sourceKey: string | undefined = existing?.seisan_line_key;
        if (!reflectionId) {
          const { data: newRow, error: insErr } = await uc.from("invoice_pl_reflections").insert({
            invoice_id: invoiceId, account_name: accountName, sub_account_name: subAccountName || null,
            year_month: yearMonth, allocations: [a], reflected_by: userData?.user?.id ?? null,
            reflection_route: "seisan", seisan_store_name: s.seisan_store_name,
            item_name: itemName, tax_rate: lineTax,
          }).select("id").maybeSingle();
          if (insErr) { results.push({ store: s.name, ok: false, error: "保存に失敗しました: " + insErr.message }); continue; }
          reflectionId = newRow?.id;
          sourceKey = `invoice:${invoiceId}:${reflectionId}`;
        } else {
          await db.from("invoice_pl_reflections").update({
            allocations: [a], year_month: yearMonth, item_name: itemName, tax_rate: lineTax,
          }).eq("id", reflectionId);
        }

        try {
          const gasRes = await seisanCall("sd_apiAddExternalLine", [tk, s.seisan_store_name, monthKey, {
            sourceKey, item: itemName, amount: Number(a.amount), tax: lineTax,
            account: accountName, subAccount: subAccountName || undefined, note: body?.note || undefined,
          }]);
          if (!gasRes.ok) {
            throw new Error(gasRes.error || (gasRes.locked ? "この月は振込済みのため精算書への登録・更新はできません" : "精算書側で失敗しました"));
          }
          await db.from("invoice_pl_reflections").update({
            seisan_line_key: sourceKey, sheet_synced_at: new Date().toISOString(), sheet_sync_error: null,
            pl_status: "振込確定待ち", pl_status_checked_at: new Date().toISOString(),
          }).eq("id", reflectionId);

          // 添付ファイルを精算書側へアップロード（2件目以降は費目名に②③…を付けて別ファイル扱いに
          // する＝sd_apiUploadAttachmentは同じkindなら上書きする冪等設計のため、複数枚を別々に残すには
          // kindを変える必要がある）。ここが失敗しても明細行の登録自体は成功しているので、行全体を
          // 失敗扱いにはせず、件数だけresultsに記録する
          // 2026-09-17修正：ユーザー報告「精算書の添付にファイルが無い」に対応。従来はこの結果を
          // その場のレスポンス（results配列）にしか残しておらず、画面を再度開くと添付が成功したか
          // 失敗したか一切わからなかった。attached_count/attachment_errorとしてDBにも保存し、
          // 反映履歴カードから確認できるようにする
          let attachedCount = 0;
          let attachmentError: string | null = null;
          for (let fi = 0; fi < attachmentFiles.length; fi++) {
            const f = attachmentFiles[fi];
            const kind = fi === 0 ? itemName : `${itemName}${["②", "③", "④", "⑤"][fi - 1] ?? `(${fi + 1})`}`;
            try {
              const upRes = await seisanCall("sd_apiUploadAttachment", [tk, s.seisan_store_name, monthKey, {
                kind, fileName: f.file_name, mimeType: f.mime_type || undefined, b64: f.b64,
                uniq: String(invoiceId).replace(/-/g, "").slice(0, 8),   // 2026-10-19: 請求書ごとに別ファイルにする（同じ費目名の別請求書の添付を上書きしない）
              }]);
              if (upRes.ok) attachedCount++;
              else if (!attachmentError) attachmentError = upRes.error || "精算書側で添付の保存に失敗しました";
            } catch (ae) {
              // 添付アップロードの失敗は明細登録自体の成否には影響させない（結果はresults/DBに記録するのみ）
              if (!attachmentError) attachmentError = String((ae as Error)?.message ?? ae);
            }
          }
          await db.from("invoice_pl_reflections").update({
            attached_count: attachedCount,
            attachment_error: attachmentFiles.length ? attachmentError : null,
          }).eq("id", reflectionId);

          results.push({ store: s.name, ok: true, attachments: attachedCount });
          anyOk = true;
        } catch (e) {
          const msg = String((e as Error)?.message ?? e);
          await db.from("invoice_pl_reflections").update({
            seisan_line_key: sourceKey, sheet_sync_error: msg, pl_status: "PLエラー", pl_status_checked_at: new Date().toISOString(),
          }).eq("id", reflectionId);
          results.push({ store: s.name, ok: false, error: msg });
        }
      }

      // 2026-09-06修正：ユーザー報告「業務委託精算書へ反映したつもりなのに『PLに反映済み』と
      // 出てややこしい」に対応。seisanルートはまだ実際にPLへは入っていない（精算書側の振込確定・
      // 次回同期を待つ状態）ため、direct routeと同じpl_fee_reflected_atに書き込むのは不正確
      // だった。以前から用意されていた専用列invoices.pl_fee_seisan_synced_at（統合請求書一覧の
      // 「精算書」列が既に参照している）に書き込むよう修正
      if (anyOk) {
        await uc.from("invoices").update({ pl_fee_seisan_synced_at: new Date().toISOString(), updated_at: new Date().toISOString() })
          .eq("id", invoiceId).is("pl_fee_seisan_synced_at", null);
      }

      const totalAmt = allocations.reduce((s: number, a: any) => s + Number(a.amount), 0);
      await db.from("invoice_audit_logs").insert({
        entity_type: "invoice_email", entity_id: inv.email_id, action: "pl_fee_reflected_seisan", actor_type: "human",
        note: `業務委託精算書へ登録（科目: ${accountName}${subAccountName ? "/" + subAccountName : ""}／対象: ${monthKey}／合計: ${totalAmt.toLocaleString()}円／${allocations.length}店舗）${results.some((r) => !r.ok) ? "※一部失敗あり" : ""}`,
      });

      return json({ success: results.every((r) => r.ok), results });
    }

    // 2026-09-26新設：ユーザー要望「N-Styleの業務委託精算店舗（じんべぇ川崎・秋葉原肉寿司等）
    // のPayPay売上・手数料も業務委託精算書に反映したい」に対応。invoices.htmlのarjSubmitJournal
    // （売上入金からのMF仕訳作成）が仕訳登録に成功した直後に呼ばれる。MoneyForwardへの直接
    // 仕訳登録（銀行入金の簿付け・現金の動きの記録）はそのまま残し、対象店舗であれば追加で
    // 業務委託精算書へ「〇〇売上」「〇〇手数料」の2行を登録する（ユーザー確認済み：両方登録する
    // 方針＝現金の動きの記録と精算書のPL集計は別の役割として両方必要）。seisan_target/
    // seisan_pl_categories_targetのどちらも立っていない店舗は何もせず成功扱い（skipped）で
    // 返す（精算対象店舗以外はこの機能自体が関係ないため、エラーにはしない）。sourceKeyは
    // "receivable:<ar_receivables.id>:sales"/"fee"の固定2種のため、invoice_pl_reflectionsの
    // ような子テーブルは持たず、ar_receivables自体にseisan_synced_at/seisan_sync_errorを
    // 直接持たせている（1行=常にこの2明細のみという単純な構造のため）
    if (action === "seisan_confirm_receivable") {
      const receivableId = body?.receivable_id;
      if (!receivableId) return json({ error: "receivable_idは必須です" }, 400);
      const { data: rcv, error: rcvErr } = await uc.from("ar_receivables")
        .select("id, store_id, corporation_id, gross_amount, fee_amount, year_month, source_name, recurring_master_id")
        .eq("id", receivableId).maybeSingle();
      if (rcvErr) return json({ error: "確認に失敗しました: " + rcvErr.message }, 500);
      if (!rcv) return json({ error: "対象が見つからないか権限がありません" }, 403);
      if (!rcv.store_id) return json({ success: true, skipped: true, reason: "共通費行（店舗未設定）は対象外です" });

      const { data: store, error: storeErr } = await uc.from("stores")
        .select("id, name, corporation_id, seisan_target, seisan_pl_categories_target, seisan_store_name")
        .eq("id", rcv.store_id).maybeSingle();
      if (storeErr) return json({ error: "店舗の確認に失敗しました: " + storeErr.message }, 500);
      if (!store) return json({ success: true, skipped: true, reason: "店舗が見つかりません" });

      // 2026-09-26注記：経費のplSeisanRoute（"誰がこの請求書を立て替えたか"で direct/seisan を
      // 分岐する仕組み）は、売上入金にはそのまま適用できない。売上は立替払いという概念が無く、
      // 「受け取った売上そのもの」なので、店舗自身がどちらの法人の会計を使っていようと関係ない。
      // 実際、黒霧屋 新横浜はar_receivables.corporation_id（=店舗自身のcorporation_id・トーホー）
      // が一致するためplSeisanRouteに通すと"direct"（対象外）になってしまうが、ユーザーから
      // 「黒霧屋も対象」と明示指示を受けている。そのためここではseisan_target/
      // seisan_pl_categories_targetのどちらか一方でも立っていれば常に対象とする
      // （経費のdirect/seisan分岐はここでは行わない）
      if (!store.seisan_target && !store.seisan_pl_categories_target) {
        return json({ success: true, skipped: true, reason: `${store.name}は業務委託精算書の対象店舗ではありません` });
      }
      if (!store.seisan_store_name) {
        return json({ error: `${store.name}の「精算書店舗名」が店舗マスタに未設定です。設定タブから設定してから登録してください` }, 400);
      }

      const tk = Deno.env.get("PL_SYNC_TOKEN");
      if (!tk) return json({ error: "PL_SYNC_TOKEN が未設定です（担当Cまでご連絡ください）" }, 500);

      const monthKey = String(rcv.year_month || "").slice(0, 7);
      if (!/^\d{4}-\d{2}$/.test(monthKey)) return json({ error: "対象年月が不正です" }, 400);

      // 税率は10%固定（実データは飲食売上で8%/10%が混在するが、行を分けて明細を渡す元データが
      // 無いため簡易的に10%とする。精算書シート側で実態に応じて手動で直せる通常の1行として扱う）
      // 2026-09-26修正：ユーザー要望「PayPay加盟店売上をPayPay売上に、PayPay加盟店手数料を
      // PayPay手数料に変更してほしい」に対応。source_name（ar_receivables.source_nameの表記
      // そのまま＝"PayPay加盟店"）の末尾「加盟店」は精算書の費目名としては不要な事務的な
      // 接尾語のため取り除く（ロケットナウ等、他のsource_nameはそのまま使う＝汎用的な仕組みを
      // 保つ）
      const srcLabel = (rcv.source_name || "PayPay").trim().replace(/加盟店$/, "");
      let salesItem = `${srcLabel}売上`;
      let feeItem = `${srcLabel}手数料`;
      // 2026-10-02追加（ユーザー要望）: SMBC GMO PAYMENT（カード売上）は振込明細書が前半/後半の
      // 月2回発行され、ar_receivablesも前半用・後半用の別々のar_recurring_master（smbc-card-deposit.js
      // のRECURRING_MASTER_NAME_H1/H2＝「カード売上（SMBC GMO PAYMENT・前半分）」/「…後半分）」）に
      // 紐づく。精算書上でどちらの振込か区別できるよう、費目名を「カード売上（前半分）」のように
      // 半期つきへ変更（note列の自由記述を正規表現で読むよりロバストなrecurring_masterのnameで判定）。
      if (rcv.source_name === "SMBC GMO PAYMENT（カード売上）" && rcv.recurring_master_id) {
        const { data: master } = await uc.from("ar_recurring_master")
          .select("name").eq("id", rcv.recurring_master_id).maybeSingle();
        const half = master?.name?.includes("前半") ? "前半分" : master?.name?.includes("後半") ? "後半分" : null;
        if (half) {
          salesItem = `カード売上（${half}）`;
          feeItem = `カード手数料（${half}）`;
        }
      }
      // 2026-10-01修正（ユーザー指摘「カード売上が変動費で入ってしまっている」）: 精算GAS
      // （sd_apiAddExternalLine）へkubunを渡していなかったため、売上の明細も常に精算GAS側の
      // 既定値'変動費'で保存されていた（PayPay等、既存のsource_nameすべてに共通する不具合。
      // 今回SMBC GMO PAYMENTのカード売上で顕在化して発覚）。売上行='売上'・手数料行='変動費'を
      // 明示的に渡すよう修正。
      // 2026-10-13追加（ユーザー指示）：デリバリー売上（ロケットナウ・Uber Eats）は軽減税率8%。手数料は10%のまま。
      const salesTax = /ロケット|uber/i.test(rcv.source_name || "") ? "8%" : "10%";
      const lines = [
        { key: "sales", item: salesItem, account: "売上高", kubun: "売上", amount: Number(rcv.gross_amount) || 0, tax: salesTax },
        { key: "fee", item: feeItem, account: "支払手数料", kubun: "変動費", amount: Number(rcv.fee_amount) || 0, tax: "10%" },
      ].filter((l) => l.amount > 0);
      if (!lines.length) return json({ success: true, skipped: true, reason: "売上・手数料とも0円のため登録対象がありません" });

      const db = svc();
      const results: { item: string; ok: boolean; error?: string }[] = [];
      for (const l of lines) {
        const sourceKey = `receivable:${receivableId}:${l.key}`;
        try {
          const gasRes = await seisanCall("sd_apiAddExternalLine", [tk, store.seisan_store_name, monthKey, {
            sourceKey, item: l.item, amount: l.amount, tax: l.tax, account: l.account, kubun: l.kubun,
          }]);
          if (!gasRes.ok) {
            throw new Error(gasRes.error || (gasRes.locked ? "この月は振込済みのため精算書への登録・更新はできません" : "精算書側で失敗しました"));
          }
          results.push({ item: l.item, ok: true });
        } catch (e) {
          results.push({ item: l.item, ok: false, error: String((e as Error)?.message ?? e) });
        }
      }
      const allOk = results.every((r) => r.ok);
      await db.from("ar_receivables").update({
        seisan_synced_at: allOk ? new Date().toISOString() : null,
        seisan_sync_error: allOk ? null : results.filter((r) => !r.ok).map((r) => `${r.item}: ${r.error}`).join("／"),
      }).eq("id", receivableId);

      return json({ success: allOk, results });
    }

    // 2026-09-05新規：精算書側の実データ（sd_apiGetLines）から個々の明細のPL反映状態
    // （設計書§9-2の6状態モデル。plStatusはGAS側で既に計算済みの値をそのまま使う＝
    // ns-portal側で「反映済み」を勝手に断定しない）を取得し直す
    if (action === "seisan_refresh_status") {
      const invoiceId = body?.invoice_id;
      if (!invoiceId) return json({ error: "invoice_idは必須です" }, 400);
      const { data: rows, error: rowsErr } = await uc.from("invoice_pl_reflections")
        .select("id, seisan_store_name, year_month, seisan_line_key, account_name, sub_account_name, item_name")
        .eq("invoice_id", invoiceId).eq("reflection_route", "seisan").not("seisan_line_key", "is", null);
      if (rowsErr) return json({ error: "確認に失敗しました: " + rowsErr.message }, 500);
      if (!rows || !rows.length) return json({ success: true, updated: 0 });

      const tk = Deno.env.get("PL_SYNC_TOKEN");
      if (!tk) return json({ error: "PL_SYNC_TOKEN が未設定です" }, 500);

      const items = rows.map((r: any) => ({ store: r.seisan_store_name, monthKey: String(r.year_month).slice(0, 7), sourceKey: r.seisan_line_key }));
      const db = svc();
      try {
        const res = await seisanCall("sd_apiGetLines", [tk, items]);
        if (!res.ok) return json({ error: res.error || "精算書側の状態取得に失敗しました" }, 500);
        const lines: any[] = Array.isArray(res.lines) ? res.lines : [];
        const bySourceKey = new Map(lines.map((l: any) => [l.sourceKey, l]));
        let updated = 0, notFound = 0;
        // 2026-09-19追加（実装指示書§5.7）：ユーザー報告「秋葉原肉寿司4件のうち3件が
        // 『状態を更新』で確認できない」に対応。従来はnotFoundの件数しか返しておらず、
        // 「どの明細が・なぜ見つからないか」が画面から一切分からなかった（担当者が精算書
        // シート側の外部参照ID列を手で1件ずつ突き合わせる必要があった）。見つからなかった
        // 行の科目名・費目名・sourceKey（＝精算書シートの「外部参照ID」列に入っているはずの
        // 値）とGAS側が返したerror文言（店舗/DBシート自体が見つからない場合のみ設定される。
        // それ以外の「単に一致する行が無い」場合はGAS側にerrorという概念自体が無いので固定文言
        // を補う）をnot_found_detailsとして返し、ポップアップ・反映履歴カードの両方で
        // sourceKeyまで開示することで、精算書シート側の突き合わせ依頼・担当A/司令塔への
        // 報告がこの画面の情報だけで完結するようにする
        const notFoundDetails: { id: string; label: string; source_key: string; reason: string }[] = [];
        for (const r of rows) {
          const line = bySourceKey.get(r.seisan_line_key);
          if (!line || !line.plStatus) {
            notFound++;
            const label = `${r.account_name || ""}${r.sub_account_name ? "/" + r.sub_account_name : ""}${r.item_name ? "（" + r.item_name + "）" : ""}`;
            const reason = line?.error
              ? line.error
              : "精算書シートの「外部参照ID」列にこのIDと一致する行が見つかりません（行が消された・まとめられた・IDが書き換わった可能性）";
            notFoundDetails.push({ id: r.id, label, source_key: r.seisan_line_key, reason });
            continue;
          }
          await db.from("invoice_pl_reflections").update({ pl_status: line.plStatus, pl_status_checked_at: new Date().toISOString() }).eq("id", r.id);
          updated++;
        }
        return json({ success: true, updated, not_found: notFound, not_found_details: notFoundDetails });
      } catch (e) {
        return json({ error: "精算書APIの呼び出しに失敗しました: " + String((e as Error)?.message ?? e) }, 500);
      }
    }

    // 2026-09-05新規：ユーザー要望「PL登録したら修正できない。取り消しして修正できるように
    // してほしい」に対応。invoice_pl_reflectionsの該当行を削除し、他に反映済み科目が無ければ
    // invoices.pl_fee_reflected_atも未反映状態に戻す。
    // 【正直な注記・重要】tori-dashboard側（writePlFee）は「請求書ID（source_key）単位で
    // DB_PLの行を都度upsert（同じキーなら上書き）」する設計のため、ここで取り消した直後の
    // 時点ではGoogle Sheets側の数字はまだ古いまま残る（削除ではなく上書き方式のため）。
    // ユーザーが正しい内容で再度「PLへ反映」を確定すると、同じ請求書ID（source_key）で
    // upsertされ、シート側も正しい内容に上書きされる。つまり「金額や科目を直す」用途では
    // 取り消し→再登録で完全に直るが、「そもそも反映自体を取りやめたい」場合はシート側の
    // 行が孤立して残るため、担当A側でのシート削除（GAS側に削除APIが無い）が別途必要になる。
    if (action === "unconfirm") {
      const reflectionId = body?.reflection_id;
      const invoiceId = body?.invoice_id;
      if (!reflectionId || !invoiceId) return json({ error: "reflection_id・invoice_idは必須です" }, 400);
      const { data: refl, error: reflErr } = await uc.from("invoice_pl_reflections")
        .select("id, invoice_id, account_name, sub_account_name, year_month, allocations, reflection_route")
        .eq("id", reflectionId).eq("invoice_id", invoiceId).maybeSingle();
      if (reflErr) return json({ error: "確認に失敗しました: " + reflErr.message }, 500);
      if (!refl) return json({ error: "対象の反映内容が見つからないか権限がありません" }, 403);

      const db = svc();
      // 2026-10-14: 取り消し時にPLシート側の行も0円にして、二重・過大を防ぐ（精算書ルートは対象外）
      let sheetZero: { ok: boolean; error?: string } = { ok: true };
      // 2026-10-21: pl_entries へ直接書いた行（source_key='inv:<請求書ID>:<反映ID>:…'）があれば、それを取り消す（deleted_at）。無ければ従来どおりシート側を0円にする
      const { data: directRows } = await db.from("pl_entries").select("id").like("source_key", `inv:${invoiceId}:${reflectionId}:%`).is("deleted_at", null);
      if (directRows?.length) {
        const { error: dErr } = await db.rpc("pl_entries_delete", { p_ids: directRows.map((x: any) => x.id), p_actor: "invoice-direct" });
        sheetZero = dErr ? { ok: false, error: dErr.message } : { ok: true };
      } else if ((refl as any).reflection_route !== "seisan") {
        const { data: invZ } = await uc.from("invoices").select("vendor_name").eq("id", invoiceId).maybeSingle();
        sheetZero = await zeroPlSheet({ accountName: refl.account_name, subAccount: refl.sub_account_name, ym: String(refl.year_month),
          storeNames: (Array.isArray(refl.allocations) ? refl.allocations : []).map((a: any) => a?.store_name), sourceId: invoiceId, vendorName: invZ?.vendor_name });
      }
      const { error: delErr } = await db.from("invoice_pl_reflections").delete().eq("id", reflectionId);
      if (delErr) return json({ error: "取り消しに失敗しました: " + delErr.message }, 500);

      const { count } = await uc.from("invoice_pl_reflections").select("id", { count: "exact", head: true }).eq("invoice_id", invoiceId);
      if (!count) {
        await db.from("invoices").update({ pl_fee_reflected_at: null, pl_fee_reflected_by: null }).eq("id", invoiceId);
      }

      const { data: inv } = await uc.from("invoices").select("email_id").eq("id", invoiceId).maybeSingle();
      const total = (Array.isArray(refl.allocations) ? refl.allocations : []).reduce((s: number, a: any) => s + (Number(a?.amount) || 0), 0);
      await db.from("invoice_audit_logs").insert({
        entity_type: "invoice_email", entity_id: inv?.email_id, action: "pl_fee_unconfirmed", actor_type: "human",
        note: `PL反映を取り消し（科目: ${refl.account_name}${refl.sub_account_name ? "/" + refl.sub_account_name : ""}／対象: ${String(refl.year_month).slice(0, 7)}／合計: ${total.toLocaleString()}円）。シート側は正しい内容で再登録するまで古い数字のまま残ります`,
      });

      return json({ success: true, sheet_zeroed: sheetZero.ok, sheet_error: sheetZero.ok ? null : sheetZero.error });
    }

    return json({ error: "不明なactionです" }, 400);
  } catch (e) {
    return json({ error: "予期しないエラー: " + String(e) }, 500);
  }
});
