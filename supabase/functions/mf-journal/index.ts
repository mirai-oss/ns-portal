// 請求書 → マネーフォワード仕訳登録（2026-08-27新規）
//
// invoices.html「🧾 仕訳を作成」ボタンから呼ばれる。以下のactionを持つ:
//   - "accounts": 勘定科目一覧（GET /api/v3/accounts）をそのまま返す（②勘定科目から直接選ぶ場合用）
//   - "suggest" : 過去の仕訳（当期分）からvendor_nameに一致する最有力候補を1件だけ返す（初期表示用）
//   - "list_journals": 過去の仕訳（当期＋前期）をキーワード検索し、複数件を一覧で返す
//                 （①「仕訳日記帳から選ぶ」モード用。空欄なら直近の仕訳を新しい順に返す）
//   - "list_departments"（2026-08-31追加）: キーワードを問わず、過去の仕訳に登場した部門一覧だけを返す。
//                 マネーフォワードには部門マスタ取得APIが無いため代用。仕訳辞書（テンプレート）を
//                 特定の請求書と無関係に作成・編集する画面（invoices.html設定タブ）で使う
//   - "create"  : 実際に仕訳を登録する（POST /api/v3/journals）。branchesは複数行（複合仕訳/振替伝票）に対応。
//                 呼び出し前にinvoice_can_access()で権限確認。成功したらinvoices.mf_journal_id等を更新し
//                 invoice_audit_logsへ記録。invoices.linked_hq_step_idが設定されていれば、その本部タスクの
//                 工程も呼び出しユーザー自身のJWTで完了させる（hq_task_stepsのRLS/トリガーをそのまま経由）
//   - "search_hq_steps": 本部タスクの工程をキーワード検索する（紐付け選択用。未完了のみ）
//   - "list_tenants": 連携済みの事業者（テナント）一覧を返す（mf_oauth_tokensの行一覧。トークン自体は含めない）
//   - "linked_invoices": body.step_idsの配列を渡すと、メールから紐付けられた請求書（存在すれば）を
//                 まとめて返す。tasks.html（本部タスクボード）が工程一覧描画時にN+1にならないよう
//                 一括問い合わせする想定（2026-08-27・担当Eからの連携依頼に対応）
//   - "create_standalone": メールに紐付かない請求書（本部タスクから直接アップロードした写真等・
//                 会計タブの「アップロード請求書」単独利用の両方）の仕訳登録。
//                 body: {tenant_id, linked_hq_step_id(任意・2026-08-31から必須ではない), vendor_name,
//                 branches, transaction_date, remark, voucher_files:[{file_name,file_data(base64)}],
//                 email_id(任意・2026-09-01のC-8から。1メールに複数請求書がある場合、2件目以降を
//                 このactionで登録しつつ元のメールにも紐付けたいときに渡す)}。
//                 invoicesに新規行(email_idは指定が無ければnull)を作成し、通常のcreateと同じく
//                 MFへ仕訳登録→証憑添付。linked_hq_step_idを渡した場合のみ、その本部タスクの工程も自動完了する
//                 【2026-09-04時点】このactionは請求書処理タブからは呼ばれなくなった（下記
//                 intake_uploadに置き換え）。給与仕訳（payrollPreviewSubmit）専用として残置。
//   - "intake_upload"（2026-09-04新規）: 「共通請求書詳細への完全統合」指示書対応。アップロード
//                 請求書タブの取込専用action。invoices行の作成＋証憑保存のみを行い、マネーフォワード
//                 への仕訳登録は一切行わない（登録は共通invoice詳細のcreateアクションのみで行う）。
//                 body: {vendor_name?, invoice_number?, amount?, due_date?, corporation_id?, store_id?,
//                 voucher_files:[{file_name,file_data(base64)}]（1件以上必須）}
//
// 複数事業者対応（2026-08-27）: accounts/suggest/list_journals/createはbody.tenant_idで
// どの事業者（有限会社トーホーエージェンシー='default'、株式会社N-Style='nstyle'等）かを指定できる。
// 省略時は'default'（後方互換）。事業者ごとにmf_oauth_tokensの行が分かれている。
//
// 認証: userClient(req)でinvoice_can_access()を満たすか確認してから処理する（他の請求書系Function共通）
// マネーフォワードのアクセストークンは_shared/mf.tsのgetValidAccessToken()で取得（自動リフレッシュ込み）
import { createClient } from "npm:@supabase/supabase-js@2";
import { getValidAccessToken, mfFetch } from "../_shared/mf.ts";

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

// 今期（4/1始まり）の開始日。MF側は会計期間外の日付をstart_dateに渡すとエラーになるため。
function fiscalYearStart(): string {
  const now = new Date();
  const y = now.getUTCMonth() >= 3 ? now.getUTCFullYear() : now.getUTCFullYear() - 1; // UTC基準の簡易判定（JST運用のみのため実用上問題なし）
  return `${y}-04-01`;
}
// 前期首。当期分だけだと検索範囲が狭いため、履歴検索(list_journals/suggest)は前期も含めて探す
// （2026-04-01〜が当期・2025-04-01〜2026-03-31が前期と実データで確認済み。2期分あれば実用上十分）
function prevFiscalYearStart(): string {
  const now = new Date();
  const y = (now.getUTCMonth() >= 3 ? now.getUTCFullYear() : now.getUTCFullYear() - 1) - 1;
  return `${y}-04-01`;
}
function todayStr(): string {
  return new Date().toISOString().slice(0, 10);
}

function branchSummary(br: any): string {
  const d = br.debitor, c = br.creditor;
  const side = (s: any) => s ? `${s.account_name ?? "?"}${s.sub_account_name ? "/" + s.sub_account_name : ""} ${(s.value ?? 0).toLocaleString()}円${s.department_name ? "（" + s.department_name + "）" : ""}` : "?";
  return `${side(d)} ／ ${side(c)}`;
}
function branchToTemplate(br: any) {
  const side = (s: any) => s ? {
    account_id: s.account_id, account_name: s.account_name,
    sub_account_id: s.sub_account_id, sub_account_name: s.sub_account_name,
    department_id: s.department_id, department_name: s.department_name,
    tax_id: s.tax_id, tax_name: s.tax_name, // 2026-09-02追加（税率のAPI連携）
    value: s.value,
  } : null;
  return { debit: side(br.debitor), credit: side(br.creditor), remark: br.remark };
}

// 部門一覧を直接取得（2026-08-31追加）。GET /api/v3/departmentsには departments.read スコープが必要で、
// 従来の連携（mf-oauth-authorize経由の再認可がまだの事業者）には無いため、その場合はnullを返す。
// 呼び出し側は、nullなら従来どおり仕訳履歴から実際に使われた部門をスキャンする方式にフォールバックする
// （ユーザー報告「会計入力の部門プルダウンに一部の部門が出ない」＝一度もMF側の仕訳で使われたことのない
// 部門がスキャン方式では拾えないのが原因だったための対応。再認可すれば自動でこちらが使われるようになる）
// 明細行（branches）の組み立て＋検証（2026-08-31拡張）。
// これまでは1行=借方1つ＋貸方1つを必ずペアで持ち、同額しか組めなかった（「手数料1900+手数料100→
// 買掛金2000」のような、借方複数行を貸方1行にまとめる書き方ができなかった＝ユーザー報告により発覚）。
// MoneyForwardの公式OpenAPI仕様（CRUDJournalLineスキーマ）を確認したところ、1行の中でcreditor/debitorは
// どちらもrequired指定が無く、借方だけ・貸方だけの行を作れる構造だったため、それに合わせて拡張した。
// 後方互換: 呼び出し側が旧形式（{debit,credit,amount}=借方貸方同額のペア行）を送ってきても、
// 各サイドのvalueが無ければ b.amount を使うフォールバックでそのまま動く。
// 全体の貸借バランス（借方合計=貸方合計）は行ごとではなくbranches全体で検証する
function buildFlexibleBranches(rawBranches: any[], defaultRemark: string, fallbackRemark: string):
  { ok: true; branches: any[]; totalDebit: number; totalCredit: number } | { ok: false; error: string } {
  if (!rawBranches.length) return { ok: false, error: "明細行が0件です" };
  let totalDebit = 0, totalCredit = 0;
  const branches: any[] = [];
  for (const b of rawBranches) {
    const hasDebit = !!b?.debit;
    const hasCredit = !!b?.credit;
    if (!hasDebit && !hasCredit) return { ok: false, error: "各行に借方または貸方の少なくとも一方を入力してください" };
    const dAmt = hasDebit ? Number(b.debit.value ?? b.amount) : null;
    const cAmt = hasCredit ? Number(b.credit.value ?? b.amount) : null;
    if (hasDebit && (!b.debit.account_id || !Number.isFinite(dAmt) || (dAmt as number) <= 0)) {
      return { ok: false, error: "借方の勘定科目・金額を正しく入力してください" };
    }
    if (hasCredit && (!b.credit.account_id || !Number.isFinite(cAmt) || (cAmt as number) <= 0)) {
      return { ok: false, error: "貸方の勘定科目・金額を正しく入力してください" };
    }
    const departmentId = b.department_id || null;
    // 2026-09-02追加: 税区分（tax_id）のAPI連携。department_idと同じく明細行（branch）の階層に
    // 置く設計にした（invoices.html側の既存の部門選択と全く同じデータの流れ方に揃えるため）。
    // CRUDJournalLineDetailsのtax_idフィールド（公式OpenAPI仕様で確認済み）にそのまま渡す。
    // 未指定なら従来どおり勘定科目の既定税区分がMF側で適用される。
    const taxId = b.tax_id || null;
    // 2026-09-02追加: 貸方側にも部門・税区分を持てるように（ユーザー報告「貸方のほうは部門とか
    // 税率とか出てこない」に対応）。department_id/tax_idは従来どおり借方用、貸方用は別の
    // credit_department_id/credit_tax_idで独立して指定できる（CRUDJournalLineDetailsは
    // debitor/creditorそれぞれが自分のdepartment_id/tax_idを持てる構造のため）
    const creditDepartmentId = b.credit_department_id || null;
    const creditTaxId = b.credit_tax_id || null;
    const remark = (b.remark || defaultRemark || fallbackRemark || "").slice(0, 100);
    const out: any = { remark };
    if (hasDebit) {
      out.debitor = { account_id: b.debit.account_id, value: Math.round(dAmt as number), ...(b.debit.sub_account_id ? { sub_account_id: b.debit.sub_account_id } : {}), ...(departmentId ? { department_id: departmentId } : {}), ...(taxId ? { tax_id: taxId } : {}) };
      totalDebit += Math.round(dAmt as number);
    }
    if (hasCredit) {
      out.creditor = { account_id: b.credit.account_id, value: Math.round(cAmt as number), ...(b.credit.sub_account_id ? { sub_account_id: b.credit.sub_account_id } : {}), ...(creditDepartmentId ? { department_id: creditDepartmentId } : {}), ...(creditTaxId ? { tax_id: creditTaxId } : {}) };
      totalCredit += Math.round(cAmt as number);
    }
    branches.push(out);
  }
  if (Math.round(totalDebit) !== Math.round(totalCredit)) {
    return { ok: false, error: `借方合計（${totalDebit.toLocaleString()}円）と貸方合計（${totalCredit.toLocaleString()}円）が一致していません` };
  }
  return { ok: true, branches, totalDebit, totalCredit };
}

async function fetchDepartmentsDirect(accessToken: string): Promise<{ id: string; name: string }[] | null> {
  try {
    const res = await mfFetch("/api/v3/departments", accessToken);
    if (!res.ok) return null;
    const data = await res.json();
    const list = data.departments ?? (Array.isArray(data) ? data : []);
    if (!Array.isArray(list)) return null;
    return list.map((d: any) => ({ id: d.id, name: d.name })).filter((d: any) => d.id && d.name);
  } catch (_e) {
    return null;
  }
}
// 税区分一覧を取得（2026-09-02追加。ユーザー報告「仕訳辞書で税率の設定が無い」に対応）。
// GET /api/v3/taxes には departments.read と同様に専用スコープ mfc/accounting/taxes.read が必要
// （公式OpenAPI仕様で確認済み）。未認可の連携（再認可がまだの事業者）の場合はnullを返し、
// 呼び出し側は税区分選択欄そのものを出さない（部門一覧のような代用手段がAPI上に無いため）
async function fetchTaxesDirect(accessToken: string): Promise<{ id: string; name: string; tax_rate: number | null }[] | null> {
  try {
    const res = await mfFetch("/api/v3/taxes?available=true", accessToken);
    if (!res.ok) return null;
    const data = await res.json();
    const list = data.taxes ?? (Array.isArray(data) ? data : []);
    if (!Array.isArray(list)) return null;
    return list.map((t: any) => ({ id: t.id, name: t.name, tax_rate: t.tax_rate ?? null })).filter((t: any) => t.id && t.name);
  } catch (_e) {
    return null;
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return json({ error: "POSTのみ対応" }, 405);

  let body: any;
  try { body = await req.json(); } catch { return json({ error: "JSONの読み取りに失敗しました" }, 400); }
  const action = body?.action;

  // すべてのactionで呼び出し元の権限を確認（invoice_can_access()と同じ判定をRPC経由で）
  const uc = userClient(req);
  const { data: canAccess, error: accessErr } = await uc.rpc("invoice_can_access");
  if (accessErr || canAccess !== true) return json({ error: "権限がありません" }, 403);

  try {
    // マネーフォワードへの問い合わせを伴わないactionは先に処理する（MF未連携でも動くように）
    if (action === "list_tenants") {
      const db = svc();
      const { data, error } = await db.from("mf_oauth_tokens").select("id, label, updated_at").order("label");
      if (error) return json({ error: "事業者一覧の取得に失敗しました: " + error.message }, 500);
      return json({ success: true, tenants: (data ?? []).map((t) => ({ id: t.id, label: t.label || t.id })) });
    }

    if (action === "linked_invoices") {
      // 本部タスクの工程IDの配列を受け取り、メールから紐付けられた請求書（invoices.linked_hq_step_id）が
      // あればその内容（仕訳登録済みかどうか含む）を返す。tasks.htmlが工程一覧を描画するときに
      // まとめて1回で問い合わせる想定（1件ずつ問い合わせるとN+1になるため）
      const stepIds: string[] = Array.isArray(body?.step_ids) ? body.step_ids : [];
      if (!stepIds.length) return json({ success: true, invoices: [] });
      const { data, error } = await uc.from("invoices")
        .select("id, linked_hq_step_id, vendor_name, amount, invoice_status, mf_journal_id, mf_journal_number, mf_tenant_id, email_id")
        .in("linked_hq_step_id", stepIds);
      if (error) return json({ error: "取得に失敗しました: " + error.message }, 500);
      return json({ success: true, invoices: data ?? [] });
    }

    if (action === "search_hq_steps") {
      const keyword: string = (body?.keyword ?? "").trim();
      if (!keyword) return json({ success: true, results: [] });
      // 工程タイトル一致・親タスクタイトル一致の両方を探して統合する（会社名がどちら側の
      // タイトルに入っているか分からないため）。工程が未完了、かつ親タスクが未着手/進行中
      // （status in todo,doing）のものだけ対象＝完了済みタスクの中の工程は候補に出さない
      const [byStep, byTask] = await Promise.all([
        uc.from("hq_task_steps")
          .select("id, title, due_date, task:hq_tasks!inner(id, title, corp, target_date, status)")
          .ilike("title", `%${keyword}%`).is("completed_at", null).in("task.status", ["todo", "doing"]).limit(20),
        uc.from("hq_task_steps")
          .select("id, title, due_date, task:hq_tasks!inner(id, title, corp, target_date, status)")
          .ilike("task.title", `%${keyword}%`).is("completed_at", null).in("task.status", ["todo", "doing"]).limit(20),
      ]);
      const merged = new Map<string, any>();
      for (const r of [...(byStep.data ?? []), ...(byTask.data ?? [])]) merged.set(r.id, r);
      return json({ success: true, results: Array.from(merged.values()) });
    }

    // 以降のactionはマネーフォワードへ問い合わせる。どの事業者（テナント）かをtenant_idで指定
    // （省略時は最初に連携した'default'＝有限会社トーホーエージェンシー）
    const tenantId: string = body?.tenant_id || "default";
    let accessToken: string;
    try {
      ({ accessToken } = await getValidAccessToken(tenantId));
    } catch (e) {
      return json({ error: "マネーフォワード未連携、またはトークン更新に失敗しました: " + String(e) }, 502);
    }

    if (action === "accounts") {
      const res = await mfFetch("/api/v3/accounts", accessToken);
      const data = await res.json();
      if (!res.ok) return json({ error: "勘定科目の取得に失敗しました", detail: data }, 502);
      return json({ success: true, accounts: data.accounts ?? [] });
    }

    // get_journal（2026-09-03追加）: 既に登録済みの仕訳を、実際にマネーフォワード側でどう登録されたか
    // 確認できるようにクリックしたら開けるプレビュー用。GET /api/v3/journals/{id}（公式OpenAPI仕様で
    // 確認済み・journal.writeスコープで利用可）をそのまま呼び、既存のbranchToTemplate()で
    // 借方/貸方の表示用データに整形する（仕訳辞書のプレビューと同じ形式なので画面側の表示ロジックを流用できる）
    if (action === "get_journal") {
      const journalId = body?.journal_id;
      if (!journalId) return json({ error: "journal_idは必須です" }, 400);
      // 注意: マネーフォワードのIDは既にパーセントエンコード済みの文字列がそのまま返ってくる仕様
      // （実データで確認済み）のため、encodeURIComponent()で二重エンコードしない。そのままパスに埋め込む
      const res = await mfFetch(`/api/v3/journals/${journalId}`, accessToken);
      const data = await res.json();
      if (!res.ok) return json({ error: "仕訳の取得に失敗しました", detail: data }, 502);
      const j = data.journal ?? {};
      const branches = (j.branches ?? []).map(branchToTemplate);
      return json({ success: true, branches, transaction_date: j.transaction_date ?? null, journal_number: j.number ?? null, memo: j.memo ?? null });
    }

    if (action === "suggest" || action === "list_journals" || action === "list_departments") {
      // list_departments（2026-08-31追加）: キーワードに関係なく、過去の仕訳に登場した部門一覧だけを返す。
      // マネーフォワードには部門マスタを直接取得するAPIが無いため、履歴から集めて代用。
      // 仕訳辞書（invoices.html設定タブ）でテンプレートを作るとき、特定の請求書に紐づかない
      // 状態でも部門を選べるようにするために追加した
      const keyword: string = (body?.vendor_name ?? body?.keyword ?? "").trim();
      if (action === "suggest" && !keyword) return json({ success: true, match: null, departments: [] });

      // 部門一覧・税区分一覧の直接取得を先に試す（成功すればこちらを優先＝全件確実に出る）
      const [directDepartments, directTaxes] = await Promise.all([
        fetchDepartmentsDirect(accessToken),
        fetchTaxesDirect(accessToken),
      ]);
      // 2026-09-02緊急修正: list_departmentsアクションは本来ここから先の仕訳履歴（journals）取得を
      // 一切必要としない（部門一覧の直接取得が失敗した場合の代用スキャン用だけに使っていた）にも
      // 関わらず、これまで無条件で「前期＋当期の2期分・per_page=500」という重い仕訳履歴取得を
      // 直列で必須にしていたため、その取得がマネーフォワード側で偶発的に失敗する（タイムアウト等）
      // たびに、既に取得済みの部門・税区分データもろとも502エラーで丸ごと失われていた。
      // これが「N-Styleで部門・税率が反映されない（実際は間欠的に失敗していた）」の実際の原因
      // だったため、list_departmentsで直接取得が両方とも成功した場合は仕訳履歴の取得自体を
      // スキップするようにした（suggest/list_journalsは仕訳検索そのものが目的のため従来どおり必須）
      const needJournals = action !== "list_departments" || !(directDepartments && directDepartments.length);
      let journals: any[] = [];
      if (needJournals) {
        // 前期＋当期の2期分をまとめて検索（前期・当期をまたいで1回のGETで取れる範囲か未確認のため
        // 念のため2回に分けて取得しマージする。件数が多い場合はper_pageの上限に注意）
        const [resCur, resPrev] = await Promise.all([
          mfFetch(`/api/v3/journals?start_date=${fiscalYearStart()}&end_date=${todayStr()}&per_page=500&page=1`, accessToken),
          mfFetch(`/api/v3/journals?start_date=${prevFiscalYearStart()}&end_date=${fiscalYearStart()}&per_page=500&page=1`, accessToken),
        ]);
        const [dataCur, dataPrev] = await Promise.all([resCur.json(), resPrev.json()]);
        if (!resCur.ok) return json({ error: "仕訳履歴の取得に失敗しました", detail: dataCur }, 502);
        journals = [...(dataCur.journals ?? []), ...(resPrev.ok ? (dataPrev.journals ?? []) : [])];
      }

      const deptMap = new Map<string, string>(); // id -> name
      const matches: any[] = [];
      let best: any = null;
      for (const j of journals) {
        for (const br of j.branches ?? []) {
          for (const side of [br.debitor, br.creditor]) {
            if (side?.department_id) deptMap.set(side.department_id, side.department_name ?? "");
          }
          const hay = [
            br.remark, br.debitor?.trade_partner_name, br.creditor?.trade_partner_name,
            br.debitor?.sub_account_name, br.creditor?.sub_account_name,
            br.debitor?.account_name, br.creditor?.account_name,
          ].filter(Boolean).join(" ");
          if (!keyword || hay.includes(keyword)) {
            const tmpl = branchToTemplate(br);
            if (!best || (j.transaction_date ?? "") >= (best._date ?? "")) best = { ...tmpl, _date: j.transaction_date };
            if (action === "list_journals") {
              matches.push({ journal_id: j.id, transaction_date: j.transaction_date, summary: branchSummary(br), template: tmpl });
            }
          }
        }
      }
      if (best) delete best._date;

      // 部門一覧: 直接取得（departments.readスコープ）が成功していればそちらを優先（全部門が確実に出る）。
      // 未認可でnullだった場合のみ、従来どおり仕訳履歴から実際に使われた部門をスキャンした結果を使う
      const departments = (directDepartments && directDepartments.length)
        ? directDepartments
        : Array.from(deptMap, ([id, name]) => ({ id, name }));
      // 税区分一覧: 部門と違い代用手段（仕訳履歴からのスキャン）が無いため、未認可（taxes.read無し）なら
      // そのまま空配列（呼び出し側は「まだ税率の連携ができていません」と案内する。2026-09-02追加）
      const taxes = directTaxes ?? [];

      if (action === "list_departments") {
        return json({ success: true, departments, taxes, searched_count: journals.length });
      }
      if (action === "list_journals") {
        matches.sort((a, b) => (a.transaction_date < b.transaction_date ? 1 : -1)); // 新しい順
        return json({ success: true, results: matches.slice(0, 30), searched_count: journals.length });
      }
      return json({
        success: true,
        match: best,
        departments,
        taxes,
        searched_count: journals.length,
      });
    }

    if (action === "create") {
      const invoiceId = body?.invoice_id;
      const transactionDate = body?.transaction_date || todayStr();
      const defaultRemark = (body?.remark ?? "").slice(0, 100);
      // branches: [{debit:{account_id,sub_account_id?,department_id?}, credit:{...}, amount, remark?}, ...]
      // 複数行を渡せば複合仕訳（振替伝票）になる。後方互換: 旧形式(debit/credit/amount直下)も1行として受け付ける
      const rawBranches: any[] = Array.isArray(body?.branches) && body.branches.length
        ? body.branches
        : (body?.debit && body?.credit ? [{ debit: body.debit, credit: body.credit, amount: body.amount, department_id: body.department_id }] : []);

      if (!invoiceId || !rawBranches.length) {
        return json({ error: "必要な項目が不足しています（明細行が0件です）" }, 400);
      }

      // 呼び出し元が本当にこの請求書を見れるか（RLS経由で）確認してからemail_idを取得
      const { data: inv, error: invErr } = await uc.from("invoices").select("id, email_id, mf_journal_id, vendor_name, linked_hq_step_id").eq("id", invoiceId).maybeSingle();
      if (invErr) return json({ error: "確認に失敗しました: " + invErr.message }, 500);
      if (!inv) return json({ error: "対象が見つからないか権限がありません" }, 403);
      if (inv.mf_journal_id) return json({ error: "この請求書は既に仕訳登録済みです（重複登録防止）" }, 409);
      // 画面上で選んだが「保存」を押す前に「仕訳を作成」した場合に備え、リクエストの値を優先する
      const linkedHqStepId: string | null = (body?.linked_hq_step_id !== undefined ? body.linked_hq_step_id : inv.linked_hq_step_id) || null;

      const built = buildFlexibleBranches(rawBranches, defaultRemark, inv.vendor_name || "");
      if (!built.ok) return json({ error: built.error }, 400);
      const { branches } = built;
      const mfBody = { journal: { transaction_date: transactionDate, journal_type: "journal_entry", branches } };

      const res = await mfFetch("/api/v3/journals", accessToken, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(mfBody),
      });
      const data = await res.json();
      if (!res.ok) {
        const db = svc();
        await db.from("mf_sync_logs").insert({ action: "journal_create_failed", actor_type: "human", detail: { invoice_id: invoiceId, response: data } });
        // 2026-09-04追加：会計ダッシュボードの「MFエラー」カードが実データで判定できるよう、
        // invoices側にもエラー内容を記録する（従来はmf_sync_logsのみで一覧からは見えなかった）
        await db.from("invoices").update({ mf_registration_error: JSON.stringify(data).slice(0, 500), mf_registration_error_at: new Date().toISOString() }).eq("id", invoiceId);
        return json({ error: "マネーフォワードへの登録に失敗しました", detail: data }, 502);
      }

      const journalId = data?.id ?? data?.journal?.id ?? null;
      const journalNumber = data?.number ?? data?.journal?.number ?? null;

      const db = svc();
      // 借方に使った勘定科目名（PL連携対象科目かどうかの判定用メタ情報。フロントのアカウント一覧から
      // 送ってもらう＝MF側への送信には使わない。ラウンド5指示書§6.1・手数料→PL連携）
      const debitAccountNames: string[] = Array.isArray(body?.debit_account_names)
        ? body.debit_account_names.filter((x: any) => typeof x === "string" && x)
        : [];
      await db.from("invoices").update({
        mf_journal_id: journalId, mf_journal_number: journalNumber, mf_journal_created_at: new Date().toISOString(), mf_tenant_id: tenantId,
        mf_registration_error: null, mf_registration_error_at: null, // 登録成功。過去のエラー記録があればクリアする
        ...(debitAccountNames.length ? { mf_debit_accounts: debitAccountNames } : {}),
        ...(linkedHqStepId !== inv.linked_hq_step_id ? { linked_hq_step_id: linkedHqStepId } : {}), // 未保存の選択を反映
      }).eq("id", invoiceId);
      await db.from("mf_sync_logs").insert({ action: "journal_create", actor_type: "human", detail: { invoice_id: invoiceId, journal_id: journalId } });
      await db.from("invoice_audit_logs").insert({
        entity_type: "invoice_email", entity_id: inv.email_id, action: "mf_journal_created", actor_type: "human",
        note: `マネーフォワードへ仕訳登録（伝票番号: ${journalNumber ?? "-"}）`,
      });

      // メールの添付（PDF/画像）を証憑としてマネーフォワードへ添付（2026-08-27・voucher.writeスコープ追加後に対応）
      // POST /api/v3/vouchers { journal_id, voucher_files:[{file_name, file_data(base64)}] }
      // attach_filesがfalse明示のときはスキップ（デフォルトは添付する）
      let voucherAttached = 0, voucherError: string | null = null;
      if (journalId && body?.attach_files !== false) {
        // 2026-09-04修正: アップロード請求書（email_id=null）の場合、従来
        // .eq("email_id", inv.email_id) は email_id=eq.null となり0件しか返らず、
        // 証憑が自動添付されない不具合があった。invoice_idでも紐付けられるようになった
        // ため（invoice_attachments.invoice_id）、email_idが無ければinvoice_idで探す
        const attQuery = db.from("invoice_attachments").select("file_name, storage_path, mime_type, size_bytes").order("created_at").limit(5);
        const { data: atts } = inv.email_id
          ? await attQuery.eq("email_id", inv.email_id)
          : await attQuery.eq("invoice_id", invoiceId);
        const files: { file_name: string; file_data: string }[] = [];
        for (const a of atts ?? []) {
          if ((a.size_bytes ?? 0) > 15 * 1024 * 1024) continue; // 大きすぎるものはスキップ（413対策）
          const { data: blob, error: dlErr } = await db.storage.from("invoice-files").download(a.storage_path);
          if (dlErr || !blob) continue;
          const bytes = new Uint8Array(await blob.arrayBuffer());
          let binary = "";
          const chunkSize = 0x8000;
          for (let i = 0; i < bytes.length; i += chunkSize) binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize));
          files.push({ file_name: (a.file_name || "attachment").slice(0, 255), file_data: btoa(binary) });
        }
        if (files.length) {
          const vRes = await mfFetch("/api/v3/vouchers", accessToken, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ journal_id: journalId, voucher_files: files }),
          });
          const vData = await vRes.json().catch(() => ({}));
          if (vRes.ok) {
            voucherAttached = (vData.voucher_file_ids ?? []).length;
          } else {
            voucherError = vRes.status === 401 || vRes.status === 403
              ? "証憑添付の権限がありません（voucher.writeスコープでの再連携が必要です）"
              : `証憑の添付に失敗しました: ${JSON.stringify(vData)}`;
          }
          await db.from("invoice_audit_logs").insert({
            entity_type: "invoice_email", entity_id: inv.email_id, action: "mf_voucher_attach", actor_type: "human",
            note: voucherError ?? `マネーフォワードへ証憑を${voucherAttached}件添付しました`,
          });
        }
      }

      // 紐付けた本部タスクの工程があれば、呼び出しユーザー自身のJWTで完了させる
      // （hq_task_stepsのRLS/完了トリガーをそのまま経由＝完了者・通知等は既存ロジック任せ）
      let hqStepCompleted = false, hqStepError: string | null = null;
      if (linkedHqStepId) {
        const { error: hqErr } = await uc.from("hq_task_steps")
          .update({ completed_at: new Date().toISOString() })
          .eq("id", linkedHqStepId)
          .is("completed_at", null); // 既に完了済みなら触らない（他の人が先に完了させたケース）
        if (hqErr) { hqStepError = hqErr.message; }
        else { hqStepCompleted = true; }
        await db.from("invoice_audit_logs").insert({
          entity_type: "invoice_email", entity_id: inv.email_id, action: "mf_journal_hq_step_link", actor_type: "human",
          note: hqStepError ? `紐付けタスクの自動完了に失敗: ${hqStepError}` : "紐付けた本部タスクの工程を自動完了しました",
        });
      }
      // 2026-09-04追加：本部タスクevent_type連携の統一監査ログ（invoice_task_events）にも記録する。
      // 完了処理自体は上のuc経由（既存・変更なし）のまま、event_typeベースの監査ログとしての
      // 一貫性のためにここで追記する（invoice_fire_task_event RPCと同じ形の記録を残すだけ）。
      // unique(invoice_id,event_type)違反（同じ請求書への2回目の呼び出し等）が起きても
      // 本来の仕訳登録処理自体は既に成功しているため、ここのエラーは無視してよい
      await db.from("invoice_task_events").insert({
        invoice_id: invoiceId, event_type: "mf_journal_created", hq_task_step_id: linkedHqStepId || null,
        result: !linkedHqStepId ? "skipped_no_mapping" : hqStepCompleted ? "completed" : (hqStepError ? "error" : "skipped_already_completed"),
        detail: hqStepError || null, triggered_by: null,
      });

      return json({ success: true, journal_id: journalId, journal_number: journalNumber, hq_step_completed: hqStepCompleted, hq_step_error: hqStepError, voucher_attached: voucherAttached, voucher_error: voucherError });
    }

    if (action === "create_standalone") {
      // メールに紐付かない請求書（本部タスクから直接アップロードした写真等）の仕訳登録。
      // invoicesテーブルに新規行（email_id=null）を作ってから通常のcreateと同じ流れで登録する。
      // 証憑ファイルはStorage/invoice_attachmentsを経由せず、リクエストのvoucher_filesに
      // 直接base64で埋め込んで渡してもらう（呼び出し元のブラウザで読み込んだファイルをそのまま送る想定）
      // linked_hq_step_id は2026-08-31から任意化（会計タブの「アップロード請求書」は本部タスクと
      // 無関係に単独で使うため）。指定された場合のみ、その工程が見えるか確認したうえで完了させる
      const linkedHqStepId: string | null = body?.linked_hq_step_id || null;
      const vendorName: string = (body?.vendor_name ?? "").trim() || null;
      const transactionDate = body?.transaction_date || todayStr();
      const defaultRemark = (body?.remark ?? "").slice(0, 100);
      const rawBranches: any[] = Array.isArray(body?.branches) ? body.branches : [];
      if (linkedHqStepId) {
        // 呼び出し元がこの工程を見れるか（RLS経由で）確認
        const { data: step, error: stepErr } = await uc.from("hq_task_steps").select("id").eq("id", linkedHqStepId).maybeSingle();
        if (stepErr) return json({ error: "確認に失敗しました: " + stepErr.message }, 500);
        if (!step) return json({ error: "対象の工程が見つからないか権限がありません" }, 403);
      }
      // C-8（ラウンド5指示書§6.1・2026-09-01）: 1メールに複数請求書がある場合、2件目以降を
      // このactionで登録できるよう、任意でemail_idを受け取れるようにする（省略時は従来どおりnull=
      // メールに紐付かない単独請求書）。渡された場合は呼び出し元がそのメールを見れるか確認する
      const linkedEmailId: string | null = body?.email_id || null;
      if (linkedEmailId) {
        const { data: em, error: emErr } = await uc.from("invoice_emails").select("id").eq("id", linkedEmailId).maybeSingle();
        if (emErr) return json({ error: "確認に失敗しました: " + emErr.message }, 500);
        if (!em) return json({ error: "対象のメールが見つからないか権限がありません" }, 403);
      }

      const built = buildFlexibleBranches(rawBranches, defaultRemark, vendorName || "");
      if (!built.ok) return json({ error: built.error }, 400);
      const { branches, totalDebit: totalAmount } = built;
      const mfBody = { journal: { transaction_date: transactionDate, journal_type: "journal_entry", branches } };

      const res = await mfFetch("/api/v3/journals", accessToken, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(mfBody),
      });
      const data = await res.json();
      if (!res.ok) {
        const db = svc();
        await db.from("mf_sync_logs").insert({ action: "journal_create_failed", actor_type: "human", detail: { linked_hq_step_id: linkedHqStepId, response: data } });
        return json({ error: "マネーフォワードへの登録に失敗しました", detail: data }, 502);
      }
      const journalId = data?.id ?? data?.journal?.id ?? null;
      const journalNumber = data?.number ?? data?.journal?.number ?? null;

      const db = svc();
      const debitAccountNames: string[] = Array.isArray(body?.debit_account_names)
        ? body.debit_account_names.filter((x: any) => typeof x === "string" && x)
        : [];
      const { data: newInv, error: insErr } = await db.from("invoices").insert({
        email_id: linkedEmailId, linked_hq_step_id: linkedHqStepId, vendor_name: vendorName,
        amount: totalAmount, invoice_status: "paid",
        mf_journal_id: journalId, mf_journal_number: journalNumber, mf_journal_created_at: new Date().toISOString(), mf_tenant_id: tenantId,
        ...(debitAccountNames.length ? { mf_debit_accounts: debitAccountNames } : {}),
      }).select("id").single();
      if (insErr) return json({ error: "マネーフォワードへの登録はできましたが記録の保存に失敗しました: " + insErr.message, journal_id: journalId, journal_number: journalNumber }, 500);
      await db.from("mf_sync_logs").insert({ action: "journal_create", actor_type: "human", detail: { invoice_id: newInv.id, journal_id: journalId, standalone: true } });

      // 証憑（リクエストに直接入っているbase64ファイル。最大5件）
      let voucherAttached = 0, voucherError: string | null = null;
      const inlineFiles: { file_name: string; file_data: string }[] = Array.isArray(body?.voucher_files) ? body.voucher_files.slice(0, 5) : [];
      if (journalId && inlineFiles.length) {
        const vRes = await mfFetch("/api/v3/vouchers", accessToken, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ journal_id: journalId, voucher_files: inlineFiles }),
        });
        const vData = await vRes.json().catch(() => ({}));
        if (vRes.ok) voucherAttached = (vData.voucher_file_ids ?? []).length;
        else voucherError = vRes.status === 401 || vRes.status === 403 ? "証憑添付の権限がありません" : `証憑の添付に失敗しました: ${JSON.stringify(vData)}`;
      }

      // 2026-09-04追加: 上記はマネーフォワード側へ送るだけで、これまでSupabase側
      // （invoice_attachments）には一切保存していなかった。ユーザー報告「アップロード請求書から
      // 入力すると、請求書一覧の処理画面でプレビューが表示されない」に対応するため、同じファイルを
      // invoice-filesバケット＋invoice_attachments（invoice_id紐付け）にも保存する。
      // マネーフォワードへの送信が失敗していてもこちらの保存は独立して試みる（証憑を見返せることの
      // 方が重要なため）
      for (const f of inlineFiles) {
        try {
          const bytes = Uint8Array.from(atob(f.file_data), (c) => c.charCodeAt(0));
          const ext = (f.file_name.split(".").pop() || "").toLowerCase();
          const mimeType = ext === "pdf" ? "application/pdf" : ext === "png" ? "image/png" : (ext === "jpg" || ext === "jpeg") ? "image/jpeg" : undefined;
          const hashBuf = await crypto.subtle.digest("SHA-256", bytes);
          const fileHash = Array.from(new Uint8Array(hashBuf)).map((b) => b.toString(16).padStart(2, "0")).join("");
          const storagePath = `standalone/${newInv.id}/${crypto.randomUUID()}_${f.file_name}`;
          const { error: upErr } = await db.storage.from("invoice-files").upload(storagePath, bytes, { contentType: mimeType });
          if (!upErr) {
            await db.from("invoice_attachments").insert({
              invoice_id: newInv.id, file_name: f.file_name, mime_type: mimeType ?? null,
              storage_path: storagePath, file_hash: fileHash, size_bytes: bytes.length,
            });
          }
        } catch (_e) { /* 証憑プレビューの保存に失敗しても登録自体は成立させる（正直な部分成功として扱う） */ }
      }

      // 紐付けた工程があれば完了させる（呼び出しユーザー自身のJWTで＝completed_byが正しく記録される）。
      // linked_hq_step_idが無い場合（会計タブ単独のアップロード請求書）は何もしない
      let hqStepCompleted = false, hqErr: { message: string } | null = null;
      if (linkedHqStepId) {
        const { error } = await uc.from("hq_task_steps")
          .update({ completed_at: new Date().toISOString() })
          .eq("id", linkedHqStepId)
          .is("completed_at", null);
        hqErr = error; hqStepCompleted = !error;
      }

      return json({ success: true, invoice_id: newInv.id, journal_id: journalId, journal_number: journalNumber, hq_step_completed: hqStepCompleted, hq_step_error: hqErr?.message ?? null, voucher_attached: voucherAttached, voucher_error: voucherError });
    }

    if (action === "intake_upload") {
      // 2026-09-04新規：「共通請求書詳細への完全統合」指示書STEP対応。
      // アップロード請求書タブは、この指示書により「会計登録できる入口」から「取込専用」に
      // 変更された（会計・仕訳の登録は共通invoice詳細＝createアクションのみで行う）。
      // ここではinvoices行の作成と証憑ファイルの保存だけを行い、マネーフォワードへは一切
      // 何も送信しない（create_standaloneと違い、journalsへのPOSTが無い）。
      // 【注意】create_standaloneアクション自体は削除していない＝給与仕訳
      // （payrollPreviewSubmit）が「登録済みの給与データから、確認済みの仕訳をその場で登録する」
      // 目的で今も使っている。あちらは請求書の取込ではないためこの指示書のスコープ外
      const vendorName: string = (body?.vendor_name ?? "").trim() || null;
      const invoiceNumber: string = (body?.invoice_number ?? "").trim() || null;
      const amount = body?.amount != null && body.amount !== "" ? Number(body.amount) : null;
      const dueDate: string | null = body?.due_date || null;
      const corporationId: string | null = body?.corporation_id || null;
      const storeId: string | null = body?.store_id || null;
      const inlineFiles: { file_name: string; file_data: string }[] = Array.isArray(body?.voucher_files) ? body.voucher_files.slice(0, 5) : [];
      if (!inlineFiles.length) return json({ error: "証憑ファイルを1件以上選択してください" }, 400);

      const db = svc();
      const { data: newInv, error: insErr } = await db.from("invoices").insert({
        email_id: null, vendor_name: vendorName, invoice_number: invoiceNumber, amount, due_date: dueDate,
        corporation_id: corporationId, store_id: storeId, invoice_status: "draft", intake_source: "manual",
      }).select("id").single();
      if (insErr) return json({ error: "請求書の作成に失敗しました: " + insErr.message }, 500);

      let attached = 0;
      for (const f of inlineFiles) {
        try {
          const bytes = Uint8Array.from(atob(f.file_data), (c) => c.charCodeAt(0));
          const ext = (f.file_name.split(".").pop() || "").toLowerCase();
          const mimeType = ext === "pdf" ? "application/pdf" : ext === "png" ? "image/png" : (ext === "jpg" || ext === "jpeg") ? "image/jpeg" : undefined;
          const hashBuf = await crypto.subtle.digest("SHA-256", bytes);
          const fileHash = Array.from(new Uint8Array(hashBuf)).map((b) => b.toString(16).padStart(2, "0")).join("");
          const storagePath = `standalone/${newInv.id}/${crypto.randomUUID()}_${f.file_name}`;
          const { error: upErr } = await db.storage.from("invoice-files").upload(storagePath, bytes, { contentType: mimeType });
          if (!upErr) {
            await db.from("invoice_attachments").insert({
              invoice_id: newInv.id, file_name: f.file_name, mime_type: mimeType ?? null,
              storage_path: storagePath, file_hash: fileHash, size_bytes: bytes.length,
            });
            attached++;
          }
        } catch (_e) { /* 1件失敗しても他のファイルは続行し、取込自体は成立させる */ }
      }
      await db.from("mf_sync_logs").insert({ action: "invoice_intake_upload", actor_type: "human", detail: { invoice_id: newInv.id, files_attached: attached } });

      return json({ success: true, invoice_id: newInv.id, files_attached: attached });
    }

    return json({ error: "不明なactionです" }, 400);
  } catch (e) {
    return json({ error: "予期しないエラー: " + String(e) }, 500);
  }
});
