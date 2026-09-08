// 取引先マスタ・取引先銀行口座・口座変更申請 Edge Function（会計・請求書処理の全面刷新 フェーズB-2・2026-09-03）
//
// invoices.htmlの設定タブ「取引先マスタ」「支払先・銀行口座」、および統合詳細モーダルの
// 「振込」タブから呼ばれる。actionは12:
//   - "list_vendors"                      : 取引先一覧を返す（invoice_can_access()で読める全員）。
//                                            info_supplier_idが設定されている行には、社内情報
//                                            管理システム側（info.suppliers）の参照情報を
//                                            info_supplierとして埋め込む（2026-09-08追加）
//   - "upsert_vendor"           {vendor}  : 取引先の新規作成・更新。vendor.info_supplier_idで
//                                            社内情報管理システムの取引先と「軽く」リンクできる
//                                            （自動同期はしない・参照表示のみ。2026-09-08追加）
//   - "search_info_suppliers"   {q}       : 社内情報管理システムの取引先（info.suppliers）を
//                                            名前部分一致で検索（紐付け候補を出すため。2026-09-08追加）
//   - "delete_vendor"           {id}      : 取引先の削除（マスター/HQ限定）。請求書・仕訳辞書で
//                                            使用中の取引先は削除できない（2026-09-08追加）
//   - "match_vendor"        {name}        : 名称のあいまい一致で候補を返す（invoice-auto-matchからも呼ばれる）
//   - "list_bank_accounts"  {vendor_id}   : ある取引先の口座一覧（現在有効＋過去分・履歴）
//   - "upsert_bank_account" {account}     : 口座の新規作成・更新（マスター/HQ限定）。account.payment_method
//                                            は"bank_transfer"（既定）|"other_bank_transfer"|"direct_debit"|
//                                            "cash"|"credit_card"（2026-09-08追加）。
//                                            direct_debit/cash/credit_cardは銀行口座情報が不要（2026-09-07/08追加）
//   - "confirm_bank_account" {id}         : 「最終確認日」を今日に更新するだけの軽量action
//   - "delete_bank_account" {id}          : 口座の削除（マスター/HQ限定。2026-09-08追加）。
//                                            現在有効・過去分どちらも削除可（参照する外部キーは無い）
//   - "list_change_requests" {status?}    : 口座変更申請の一覧（マスター/HQ限定）
//   - "approve_change_request" {id}       : 変更申請を承認→現在の口座をvalid_to=nowで無効化し、
//                                            申請内容を新しい現在口座として登録。対象請求書の
//                                            bank_account_change_detectedも解除する
//   - "reject_change_request"  {id}       : 変更申請を却下（口座は変更しない。対象請求書のフラグは解除する＝確認済み扱い）
//
// 認可: vendors/match_vendorはinvoice_can_access()。銀行口座を書き込むaction（upsert_bank_account・
// 変更申請の承認/却下）はpayroll_bank_accountsと同じ「マスター/HQのみ」の厳格チェックを追加で行う
// （テーブルのRLS自体もマスター/HQ限定だが、Edge Function側でも明確なエラーメッセージを返すために
// 事前チェックする＝mf-journal/pl-fee-reflectと同じ設計方針）。
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

async function currentUser(req: Request) {
  const rawToken = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!rawToken) return null;
  const { data } = await userClient(req).auth.getUser(rawToken);
  return data?.user ?? null;
}
async function isMasterOrHQ(userId: string | undefined): Promise<boolean> {
  if (!userId) return false;
  const { data } = await svc().from("users").select("is_master, role, is_active").eq("id", userId).maybeSingle();
  if (!data || !data.is_active) return false;
  return !!(data.is_master || ["CEO", "HQ"].includes(data.role));
}

// 取引先名のあいまい一致（plfeeFindStoreByNameと同じ設計＝空白除去＋完全一致優先→部分一致）
function normalizeName(s: string): string {
  return String(s ?? "").replace(/\s+/g, "").toLowerCase();
}
function findVendorMatches(vendors: any[], name: string): any[] {
  const n = normalizeName(name);
  if (!n) return [];
  const exact = vendors.filter((v) =>
    normalizeName(v.name) === n || (v.name_aliases ?? []).some((a: string) => normalizeName(a) === n));
  if (exact.length) return exact.map((v) => ({ ...v, confidence: 100 }));
  const partial = vendors.filter((v) => {
    const vn = normalizeName(v.name);
    const aliasHit = (v.name_aliases ?? []).some((a: string) => {
      const an = normalizeName(a);
      return an && (n.includes(an) || an.includes(n));
    });
    return (vn && (n.includes(vn) || vn.includes(n))) || aliasHit;
  });
  return partial.map((v) => ({ ...v, confidence: 70 }));
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
    if (action === "list_vendors") {
      const { data, error } = await uc.from("vendors").select("*").order("name");
      if (error) return json({ error: error.message }, 500);
      const vendors = data ?? [];
      // 2026-09-08追加：社内情報管理システムの取引先（info.suppliers）との「軽い連携」。
      // 手動でリンクされたvendorがあれば、参照表示用に相手側のレコードをまとめて取得し埋め込む
      // （自動同期はしない。あくまで参照表示のためだけにservice roleでinfoスキーマを読む）
      const linkedIds = [...new Set(vendors.map((v: any) => v.info_supplier_id).filter(Boolean))];
      if (linkedIds.length) {
        const { data: suppliers } = await svc().schema("info").from("suppliers")
          .select("id,name,kind,phone,contact_name,contact_mobile,status").in("id", linkedIds);
        const byId = new Map((suppliers ?? []).map((s: any) => [s.id, s]));
        for (const v of vendors) if (v.info_supplier_id) v.info_supplier = byId.get(v.info_supplier_id) ?? null;
      }
      return json({ success: true, vendors });
    }

    // 2026-09-08新規：ユーザー要望「取引先マスタは社内情報管理システムの取引先と連動されて
    // いるか？されていなければ連動させてほしい」への対応（軽い連携方式で採用）。
    // info.suppliers（ns-info-system・担当F管轄）を名前部分一致で検索し、候補を返すだけの
    // 読み取り専用action。info.suppliers自体には銀行口座等の機密情報は含まれていないため
    // service roleでの直接検索でよいと判断した（RLSはinfo.suppliers側の独自権限モデル用で、
    // ns-portal利用者はそちら側のprofilesを持たないため通常のuser tokenでは読めない）
    if (action === "search_info_suppliers") {
      const q: string = (body?.q ?? "").trim();
      if (!q) return json({ success: true, suppliers: [] });
      const { data, error } = await svc().schema("info").from("suppliers")
        .select("id,name,kind,phone,contact_name,contact_mobile,status").ilike("name", `%${q}%`).order("name").limit(20);
      if (error) return json({ error: error.message }, 500);
      return json({ success: true, suppliers: data ?? [] });
    }

    if (action === "upsert_vendor") {
      const v = body?.vendor ?? {};
      const name: string = (v.name ?? "").trim();
      if (!name) return json({ error: "正式名称は必須です" }, 400);
      const user = await currentUser(req);
      const row: Record<string, unknown> = {
        name,
        name_aliases: Array.isArray(v.name_aliases) ? v.name_aliases.filter((x: any) => typeof x === "string" && x.trim()) : [],
        corporation_number: v.corporation_number || null,
        contact_email: v.contact_email || null,
        contact_phone: v.contact_phone || null,
        default_corporation_id: v.default_corporation_id || null,
        default_store_id: v.default_store_id || null,
        mf_partner_name: v.mf_partner_name || null,
        infomart_partner_id: v.infomart_partner_id || null,
        notes: v.notes || null,
        is_active: v.is_active !== false,
        info_supplier_id: v.info_supplier_id || null,
        updated_by: user?.id ?? null,
      };
      if (v.id) {
        const { error } = await uc.from("vendors").update(row).eq("id", v.id);
        if (error) return json({ error: error.message }, 500);
        return json({ success: true, id: v.id });
      }
      row.created_by = user?.id ?? null;
      const { data, error } = await uc.from("vendors").insert(row).select("id").maybeSingle();
      if (error) return json({ error: error.message }, 500);
      return json({ success: true, id: data?.id });
    }

    // 2026-09-08新規：ユーザー要望「取引先マスタの取引先を削除できるようにしてほしい」に対応。
    // 誤って重複登録してしまった取引先（口座も請求書も紐付いていない、作りたてのもの）を
    // 掃除できるようにするための機能。請求書・仕訳辞書で実際に使われている取引先は、
    // 履歴を壊さないよう削除させず「無効にする」への案内で止める（vendors.idを参照する
    // 全テーブルがON DELETE NO ACTIONのため、本来DB側でも拒否されるが、分かりやすい
    // エラーメッセージを返すため事前にチェックしている）
    if (action === "delete_vendor") {
      const user = await currentUser(req);
      if (!(await isMasterOrHQ(user?.id))) return json({ error: "取引先の削除はマスター/HQのみ行えます" }, 403);
      const vendorId = body?.id;
      if (!vendorId) return json({ error: "idは必須です" }, 400);
      const db = svc();
      const [invCount, tplCount] = await Promise.all([
        db.from("invoices").select("id", { count: "exact", head: true }).eq("vendor_id", vendorId),
        db.from("mf_journal_templates").select("id", { count: "exact", head: true }).eq("vendor_id", vendorId),
      ]);
      if ((invCount.count ?? 0) > 0) return json({ error: `この取引先は請求書${invCount.count}件で使用されているため削除できません。使わなくなった場合は「無効にする」をご利用ください。` }, 409);
      if ((tplCount.count ?? 0) > 0) return json({ error: `この取引先は仕訳辞書${tplCount.count}件で使用されているため削除できません。使わなくなった場合は「無効にする」をご利用ください。` }, 409);
      // 口座・変更申請は取引先そのものの付属データなので、取引先ごと一緒に削除する
      await db.from("vendor_bank_account_change_requests").delete().eq("vendor_id", vendorId);
      await db.from("vendor_bank_accounts").delete().eq("vendor_id", vendorId);
      const { error } = await db.from("vendors").delete().eq("id", vendorId);
      if (error) return json({ error: error.message }, 500);
      return json({ success: true });
    }

    if (action === "match_vendor") {
      const name: string = (body?.name ?? "").trim();
      if (!name) return json({ success: true, matches: [] });
      const { data, error } = await uc.from("vendors").select("id, name, name_aliases, default_corporation_id, default_store_id").eq("is_active", true);
      if (error) return json({ error: error.message }, 500);
      const matches = findVendorMatches(data ?? [], name);
      return json({ success: true, matches });
    }

    if (action === "list_bank_accounts") {
      const vendorId = body?.vendor_id;
      if (!vendorId) return json({ error: "vendor_idは必須です" }, 400);
      const { data, error } = await uc.from("vendor_bank_accounts").select("*").eq("vendor_id", vendorId).order("is_current", { ascending: false }).order("valid_from", { ascending: false });
      if (error) return json({ error: error.message }, 500);
      return json({ success: true, accounts: data ?? [] });
    }

    if (action === "upsert_bank_account") {
      const user = await currentUser(req);
      if (!(await isMasterOrHQ(user?.id))) return json({ error: "銀行口座の登録・変更はマスター/HQのみ行えます" }, 403);
      const a = body?.account ?? {};
      const vendorId = a.vendor_id;
      if (!vendorId) return json({ error: "vendor_idは必須です" }, 400);
      const db = svc();
      // 2026-09-07追加：ユーザー要望「請求書の振込待ちで引き落とし・現金払いも選べるように」に
      // 対応。銀行振込以外（引き落とし・現金払い）は銀行口座情報が不要なため、送られてこなければ
      // nullのまま保存する（payroll_bank_accountsの現金払いパターンと同じ考え方）。
      // 2026-09-08追加：クレジット払い・他行口座から振込を追加（ユーザー要望）
      const paymentMethod = ["bank_transfer", "direct_debit", "cash", "credit_card", "other_bank_transfer"].includes(a.payment_method) ? a.payment_method : "bank_transfer";
      const row: Record<string, unknown> = {
        vendor_id: vendorId,
        payment_method: paymentMethod,
        bank_code: a.bank_code || null,
        bank_name: a.bank_name || null,
        branch_code: a.branch_code || null,
        branch_name: a.branch_name || null,
        account_type: a.account_type || "1",
        account_number: a.account_number || null,
        account_holder_kana: a.account_holder_kana || null,
        confirmed_at: new Date().toISOString(),
        confirmed_by: user?.id ?? null,
      };
      if (a.id) {
        const { error } = await db.from("vendor_bank_accounts").update(row).eq("id", a.id);
        if (error) return json({ error: error.message }, 500);
        return json({ success: true, id: a.id });
      }
      // 新規に「現在有効な口座」として登録する場合、既存のis_current行があれば先に無効化する
      // （vba_current_uniqueの部分ユニークインデックスが1取引先1つのis_currentしか許さないため）
      await db.from("vendor_bank_accounts").update({ is_current: false, valid_to: new Date().toISOString().slice(0, 10) }).eq("vendor_id", vendorId).eq("is_current", true);
      const { data, error } = await db.from("vendor_bank_accounts").insert({ ...row, is_current: true, source: a.source || "manual" }).select("id").maybeSingle();
      if (error) return json({ error: error.message }, 500);
      return json({ success: true, id: data?.id });
    }

    // 2026-09-08新規：ユーザー要望「取引先マスタの銀行口座が削除も編集もできないので、
    // 編集できるようにしてほしい」に対応。編集自体はupsert_bank_account（account.idを指定した
    // 更新）で既に可能だった設計だが、フロント側に編集ボタンが無かった。あわせて削除も追加。
    // vendor_bank_accounts.idを参照する外部キーは無い（information_schemaで確認済み）ため、
    // 現在有効・過去分どちらの行でも安全に削除できる
    if (action === "delete_bank_account") {
      const user = await currentUser(req);
      if (!(await isMasterOrHQ(user?.id))) return json({ error: "振込先口座の削除はマスター/HQのみ行えます" }, 403);
      const id = body?.id;
      if (!id) return json({ error: "idは必須です" }, 400);
      const { error } = await svc().from("vendor_bank_accounts").delete().eq("id", id);
      if (error) return json({ error: error.message }, 500);
      return json({ success: true });
    }

    if (action === "confirm_bank_account") {
      const user = await currentUser(req);
      if (!(await isMasterOrHQ(user?.id))) return json({ error: "マスター/HQのみ行えます" }, 403);
      const id = body?.id;
      if (!id) return json({ error: "idは必須です" }, 400);
      const { error } = await svc().from("vendor_bank_accounts").update({ confirmed_at: new Date().toISOString(), confirmed_by: user?.id ?? null }).eq("id", id);
      if (error) return json({ error: error.message }, 500);
      return json({ success: true });
    }

    if (action === "list_change_requests") {
      const status = body?.status;
      let q = uc.from("vendor_bank_account_change_requests").select("*, vendor:vendors(name), invoice:invoices(vendor_name,amount)").order("created_at", { ascending: false });
      if (status) q = q.eq("status", status);
      const { data, error } = await q;
      if (error) return json({ error: error.message }, 500);
      return json({ success: true, requests: data ?? [] });
    }

    if (action === "approve_change_request" || action === "reject_change_request") {
      const user = await currentUser(req);
      if (!(await isMasterOrHQ(user?.id))) return json({ error: "口座変更の承認・却下はマスター/HQのみ行えます" }, 403);
      const id = body?.id;
      if (!id) return json({ error: "idは必須です" }, 400);
      const db = svc();
      const { data: reqRow, error: reqErr } = await db.from("vendor_bank_account_change_requests").select("*").eq("id", id).maybeSingle();
      if (reqErr) return json({ error: reqErr.message }, 500);
      if (!reqRow) return json({ error: "対象が見つかりません" }, 404);
      if (reqRow.status !== "pending") return json({ error: "この申請は既に処理済みです" }, 409);

      if (action === "approve_change_request") {
        await db.from("vendor_bank_accounts").update({ is_current: false, valid_to: new Date().toISOString().slice(0, 10) }).eq("vendor_id", reqRow.vendor_id).eq("is_current", true);
        const { error: insErr } = await db.from("vendor_bank_accounts").insert({
          vendor_id: reqRow.vendor_id,
          bank_name: reqRow.proposed_bank_name,
          branch_name: reqRow.proposed_branch_name,
          account_type: reqRow.proposed_account_type || "1",
          account_number: reqRow.proposed_account_number,
          account_holder_kana: reqRow.proposed_account_holder_kana,
          is_current: true,
          source: "invoice_extract",
          confirmed_at: new Date().toISOString(),
          confirmed_by: user?.id ?? null,
        });
        if (insErr) return json({ error: "口座の登録に失敗しました: " + insErr.message }, 500);
      }

      await db.from("vendor_bank_account_change_requests").update({
        status: action === "approve_change_request" ? "approved" : "rejected",
        reviewed_by: user?.id ?? null,
        reviewed_at: new Date().toISOString(),
      }).eq("id", id);

      if (reqRow.invoice_id) {
        await db.from("invoices").update({ bank_account_change_detected: false }).eq("id", reqRow.invoice_id);
      }
      await db.from("invoice_audit_logs").insert({
        entity_type: "vendor_bank_account_change_request", entity_id: id, actor_type: "human",
        action: action === "approve_change_request" ? "bank_change_approved" : "bank_change_rejected",
        note: action === "approve_change_request" ? "振込先口座変更を承認しました" : "振込先口座変更を却下しました（口座は変更していません）",
      });
      return json({ success: true });
    }

    return json({ error: "不明なactionです" }, 400);
  } catch (e) {
    return json({ error: "予期しないエラー: " + String(e) }, 500);
  }
});
