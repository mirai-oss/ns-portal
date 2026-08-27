// 請求書 → マネーフォワード仕訳登録（2026-08-27新規）
//
// invoices.html「🧾 仕訳を作成」ボタンから呼ばれる。以下のactionを持つ:
//   - "accounts": 勘定科目一覧（GET /api/v3/accounts）をそのまま返す（②勘定科目から直接選ぶ場合用）
//   - "suggest" : 過去の仕訳（当期分）からvendor_nameに一致する最有力候補を1件だけ返す（初期表示用）
//   - "list_journals": 過去の仕訳（当期＋前期）をキーワード検索し、複数件を一覧で返す
//                 （①「仕訳日記帳から選ぶ」モード用。空欄なら直近の仕訳を新しい順に返す）
//   - "create"  : 実際に仕訳を登録する（POST /api/v3/journals）。branchesは複数行（複合仕訳/振替伝票）に対応。
//                 呼び出し前にinvoice_can_access()で権限確認。成功したらinvoices.mf_journal_id等を更新し
//                 invoice_audit_logsへ記録。invoices.linked_hq_step_idが設定されていれば、その本部タスクの
//                 工程も呼び出しユーザー自身のJWTで完了させる（hq_task_stepsのRLS/トリガーをそのまま経由）
//   - "search_hq_steps": 本部タスクの工程をキーワード検索する（紐付け選択用。未完了のみ）
//   - "list_tenants": 連携済みの事業者（テナント）一覧を返す（mf_oauth_tokensの行一覧。トークン自体は含めない）
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
    value: s.value,
  } : null;
  return { debit: side(br.debitor), credit: side(br.creditor), remark: br.remark };
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

    if (action === "suggest" || action === "list_journals") {
      const keyword: string = (body?.vendor_name ?? body?.keyword ?? "").trim();
      if (action === "suggest" && !keyword) return json({ success: true, match: null, departments: [] });

      // 前期＋当期の2期分をまとめて検索（前期・当期をまたいで1回のGETで取れる範囲か未確認のため
      // 念のため2回に分けて取得しマージする。件数が多い場合はper_pageの上限に注意）
      const [resCur, resPrev] = await Promise.all([
        mfFetch(`/api/v3/journals?start_date=${fiscalYearStart()}&end_date=${todayStr()}&per_page=500&page=1`, accessToken),
        mfFetch(`/api/v3/journals?start_date=${prevFiscalYearStart()}&end_date=${fiscalYearStart()}&per_page=500&page=1`, accessToken),
      ]);
      const [dataCur, dataPrev] = await Promise.all([resCur.json(), resPrev.json()]);
      if (!resCur.ok) return json({ error: "仕訳履歴の取得に失敗しました", detail: dataCur }, 502);
      const journals: any[] = [...(dataCur.journals ?? []), ...(resPrev.ok ? (dataPrev.journals ?? []) : [])];

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

      if (action === "list_journals") {
        matches.sort((a, b) => (a.transaction_date < b.transaction_date ? 1 : -1)); // 新しい順
        return json({ success: true, results: matches.slice(0, 30), searched_count: journals.length });
      }
      return json({
        success: true,
        match: best,
        departments: Array.from(deptMap, ([id, name]) => ({ id, name })),
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
      for (const b of rawBranches) {
        const amt = Number(b.amount);
        if (!b.debit?.account_id || !b.credit?.account_id || !Number.isFinite(amt) || amt <= 0) {
          return json({ error: "各行に借方・貸方の勘定科目と金額を入力してください" }, 400);
        }
      }

      // 呼び出し元が本当にこの請求書を見れるか（RLS経由で）確認してからemail_idを取得
      const { data: inv, error: invErr } = await uc.from("invoices").select("id, email_id, mf_journal_id, vendor_name, linked_hq_step_id").eq("id", invoiceId).maybeSingle();
      if (invErr) return json({ error: "確認に失敗しました: " + invErr.message }, 500);
      if (!inv) return json({ error: "対象が見つからないか権限がありません" }, 403);
      if (inv.mf_journal_id) return json({ error: "この請求書は既に仕訳登録済みです（重複登録防止）" }, 409);
      // 画面上で選んだが「保存」を押す前に「仕訳を作成」した場合に備え、リクエストの値を優先する
      const linkedHqStepId: string | null = (body?.linked_hq_step_id !== undefined ? body.linked_hq_step_id : inv.linked_hq_step_id) || null;

      const branches = rawBranches.map((b) => {
        const amt = Math.round(Number(b.amount));
        const departmentId = b.department_id || null;
        return {
          debitor: { account_id: b.debit.account_id, value: amt, ...(b.debit.sub_account_id ? { sub_account_id: b.debit.sub_account_id } : {}), ...(departmentId ? { department_id: departmentId } : {}) },
          creditor: { account_id: b.credit.account_id, value: amt, ...(b.credit.sub_account_id ? { sub_account_id: b.credit.sub_account_id } : {}) },
          remark: (b.remark || defaultRemark || inv.vendor_name || "").slice(0, 100),
        };
      });
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
        return json({ error: "マネーフォワードへの登録に失敗しました", detail: data }, 502);
      }

      const journalId = data?.id ?? data?.journal?.id ?? null;
      const journalNumber = data?.number ?? data?.journal?.number ?? null;

      const db = svc();
      await db.from("invoices").update({
        mf_journal_id: journalId, mf_journal_number: journalNumber, mf_journal_created_at: new Date().toISOString(), mf_tenant_id: tenantId,
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
        const { data: atts } = await db.from("invoice_attachments").select("file_name, storage_path, mime_type, size_bytes").eq("email_id", inv.email_id).order("created_at").limit(5);
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

      return json({ success: true, journal_id: journalId, journal_number: journalNumber, hq_step_completed: hqStepCompleted, hq_step_error: hqStepError, voucher_attached: voucherAttached, voucher_error: voucherError });
    }

    return json({ error: "不明なactionです" }, 400);
  } catch (e) {
    return json({ error: "予期しないエラー: " + String(e) }, 500);
  }
});
