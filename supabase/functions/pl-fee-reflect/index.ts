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

// 2026-09-05新設：業務委託精算書自動連携（設計書_業務委託精算書自動連携_2026-09-04.md）。
// seisan-dashboardのGAS Web App URL（担当A実装・11章で本番デプロイ済み。DASH_API_URLとは別の
// GASプロジェクト＝別トークンPL_SYNC_TOKENで認証する）
const SEISAN_API_URL = "https://script.google.com/macros/s/AKfycbzwYN9uSEtcJHSKSVQCoQOrllhO7G6gR-E4dvP-V4o_VdGXr9VQx2mbYYPNyNEFSQCiKg/exec";
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
  const { data: canAccess, error: accessErr } = await uc.rpc("invoice_can_access");
  if (accessErr || canAccess !== true) return json({ error: "権限がありません" }, 403);

  try {
    if (action === "list_target_accounts") {
      const db = svc();
      const { data, error } = await db.from("mf_pl_fee_accounts").select("*").order("account_name");
      if (error) return json({ error: error.message }, 500);
      return json({ success: true, accounts: data ?? [] });
    }

    if (action === "add_target_account") {
      const accountName: string = (body?.account_name ?? "").trim();
      if (!accountName) return json({ error: "勘定科目名は必須です" }, 400);
      const db = svc();
      const { error } = await db.from("mf_pl_fee_accounts").insert({
        account_name: accountName, pl_label: (body?.pl_label ?? "").trim() || accountName,
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
      const { data: refl, error: reflErr } = await uc.from("invoice_pl_reflections")
        .select("id, account_name, sub_account_name, year_month, allocations, reflected_at, sheet_synced_at, sheet_sync_error, reflection_route, seisan_store_name, pl_status, pl_status_checked_at")
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
        .select("id, email_id, vendor_name").eq("id", invoiceId).maybeSingle();
      if (invErr) return json({ error: "確認に失敗しました: " + invErr.message }, 500);
      if (!inv) return json({ error: "対象が見つからないか権限がありません" }, 403);

      // ①PL科目に限定: mf_pl_fee_accounts未登録の科目はPLへ反映させない（前払費用等の資産科目を
      // 誤ってPLに載せてしまう事故防止）
      const { data: plAcc, error: plAccErr } = await uc.from("mf_pl_fee_accounts")
        .select("id").eq("account_name", accountName).maybeSingle();
      if (plAccErr) return json({ error: "PL科目の確認に失敗しました: " + plAccErr.message }, 500);
      if (!plAcc) return json({ error: `「${accountName}」はPL科目として登録されていません。設定タブの「PL連携対象科目」で先に登録してください（資産科目等をPLに載せてしまうミスを防ぐための確認です）` }, 400);

      // ②精算対象店舗との二重計上防止: 精算対象店舗は精算書側で入力すれば別途PLへ自動連携されるため、
      // この経路（DB_PL直接書き込み）の対象には含めない。
      // 2026-09-05修正：黒霧屋 新横浜のように「運営委託費の自動連携(seisan_target)は対象外だが、
      // 個別経費のPL反映(seisan_pl_categories_target)だけは精算書経由」という店舗も同じ理由で
      // 対象外にする必要があるため、どちらかのフラグが立っていれば拒否する
      // （設計書_業務委託精算書自動連携_2026-09-04.md §14。この判定漏れは今回追加した
      // seisan_confirmアクションとの整合性を取る過程で発見した既存バグ）
      const storeIds = allocations.map((a) => a.store_id).filter(Boolean);
      if (storeIds.length) {
        const { data: seisanStores, error: seisanErr } = await uc.from("stores")
          .select("id, name").in("id", storeIds).or("seisan_target.eq.true,seisan_pl_categories_target.eq.true");
        if (seisanErr) return json({ error: "店舗の確認に失敗しました: " + seisanErr.message }, 500);
        if (seisanStores && seisanStores.length) {
          const names = seisanStores.map((s: any) => s.name).join("・");
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
      try {
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
      }

      const { data: inv, error: invErr } = await uc.from("invoices")
        .select("id, email_id, vendor_name").eq("id", invoiceId).maybeSingle();
      if (invErr) return json({ error: "確認に失敗しました: " + invErr.message }, 500);
      if (!inv) return json({ error: "対象が見つからないか権限がありません" }, 403);

      // このactionの対象は精算対象店舗のみ（direct route側との二重計上防止の裏返し）
      const storeIds = allocations.map((a) => a.store_id).filter(Boolean);
      const { data: storeRows, error: storeErr } = await uc.from("stores")
        .select("id, name, seisan_target, seisan_pl_categories_target, seisan_store_name").in("id", storeIds);
      if (storeErr) return json({ error: "店舗の確認に失敗しました: " + storeErr.message }, 500);
      const storeMap = new Map((storeRows ?? []).map((s: any) => [s.id, s]));
      for (const a of allocations) {
        const s = storeMap.get(a.store_id);
        if (!s) return json({ error: `店舗が見つかりません（${a.store_name}）` }, 400);
        if (!s.seisan_target && !s.seisan_pl_categories_target) {
          return json({ error: `${s.name}は精算対象店舗ではありません。この店舗は「PLへ反映」（直接反映）から登録してください` }, 400);
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
      const results: { store: string; ok: boolean; error?: string }[] = [];
      let anyOk = false;

      for (const a of allocations) {
        const s = storeMap.get(a.store_id);
        // 重複防止（同じ請求書×科目×補助科目×店舗の既存行があれば、それを更新扱いにする＝同じsourceKeyで上書き）
        let dupQuery = uc.from("invoice_pl_reflections").select("id, seisan_line_key")
          .eq("invoice_id", invoiceId).eq("account_name", accountName).eq("reflection_route", "seisan")
          .eq("seisan_store_name", s.seisan_store_name);
        dupQuery = subAccountName ? dupQuery.eq("sub_account_name", subAccountName) : dupQuery.is("sub_account_name", null);
        const { data: existing } = await dupQuery.maybeSingle();

        let reflectionId: string | undefined = existing?.id;
        let sourceKey: string | undefined = existing?.seisan_line_key;
        if (!reflectionId) {
          const { data: newRow, error: insErr } = await uc.from("invoice_pl_reflections").insert({
            invoice_id: invoiceId, account_name: accountName, sub_account_name: subAccountName || null,
            year_month: yearMonth, allocations: [a], reflected_by: userData?.user?.id ?? null,
            reflection_route: "seisan", seisan_store_name: s.seisan_store_name,
            item_name: itemName, tax_rate: taxRate,
          }).select("id").maybeSingle();
          if (insErr) { results.push({ store: s.name, ok: false, error: "保存に失敗しました: " + insErr.message }); continue; }
          reflectionId = newRow?.id;
          sourceKey = `invoice:${invoiceId}:${reflectionId}`;
        } else {
          await db.from("invoice_pl_reflections").update({
            allocations: [a], year_month: yearMonth, item_name: itemName, tax_rate: taxRate,
          }).eq("id", reflectionId);
        }

        try {
          const gasRes = await seisanCall("sd_apiAddExternalLine", [tk, s.seisan_store_name, monthKey, {
            sourceKey, item: itemName, amount: Number(a.amount), tax: taxRate,
            account: accountName, subAccount: subAccountName || undefined, note: body?.note || undefined,
          }]);
          if (!gasRes.ok) {
            throw new Error(gasRes.error || (gasRes.locked ? "この月は振込済みのため精算書への登録・更新はできません" : "精算書側で失敗しました"));
          }
          await db.from("invoice_pl_reflections").update({
            seisan_line_key: sourceKey, sheet_synced_at: new Date().toISOString(), sheet_sync_error: null,
            pl_status: "振込確定待ち", pl_status_checked_at: new Date().toISOString(),
          }).eq("id", reflectionId);
          results.push({ store: s.name, ok: true });
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

    // 2026-09-05新規：精算書側の実データ（sd_apiGetLines）から個々の明細のPL反映状態
    // （設計書§9-2の6状態モデル。plStatusはGAS側で既に計算済みの値をそのまま使う＝
    // ns-portal側で「反映済み」を勝手に断定しない）を取得し直す
    if (action === "seisan_refresh_status") {
      const invoiceId = body?.invoice_id;
      if (!invoiceId) return json({ error: "invoice_idは必須です" }, 400);
      const { data: rows, error: rowsErr } = await uc.from("invoice_pl_reflections")
        .select("id, seisan_store_name, year_month, seisan_line_key")
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
        let updated = 0;
        for (const r of rows) {
          const line = bySourceKey.get(r.seisan_line_key);
          const status = (line && line.plStatus) || "PLエラー";
          await db.from("invoice_pl_reflections").update({ pl_status: status, pl_status_checked_at: new Date().toISOString() }).eq("id", r.id);
          updated++;
        }
        return json({ success: true, updated });
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
        .select("id, invoice_id, account_name, sub_account_name, year_month, allocations")
        .eq("id", reflectionId).eq("invoice_id", invoiceId).maybeSingle();
      if (reflErr) return json({ error: "確認に失敗しました: " + reflErr.message }, 500);
      if (!refl) return json({ error: "対象の反映内容が見つからないか権限がありません" }, 403);

      const db = svc();
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

      return json({ success: true });
    }

    return json({ error: "不明なactionです" }, 400);
  } catch (e) {
    return json({ error: "予期しないエラー: " + String(e) }, 500);
  }
});
