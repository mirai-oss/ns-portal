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
      const { data: refl, error: reflErr } = await uc.from("invoice_pl_reflections")
        .select("id, account_name, sub_account_name, year_month, allocations, reflected_at, sheet_synced_at, sheet_sync_error")
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
      // この経路（DB_PL直接書き込み）の対象には含めない
      const storeIds = allocations.map((a) => a.store_id).filter(Boolean);
      if (storeIds.length) {
        const { data: seisanStores, error: seisanErr } = await uc.from("stores")
          .select("id, name").in("id", storeIds).eq("seisan_target", true);
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

    return json({ error: "不明なactionです" }, 400);
  } catch (e) {
    return json({ error: "予期しないエラー: " + String(e) }, 500);
  }
});
