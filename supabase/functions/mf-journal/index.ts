// 請求書 → マネーフォワード仕訳登録（2026-08-27新規）
//
// invoices.html「🧾 仕訳を作成」ボタンから呼ばれる。3つのactionを持つ:
//   - "accounts": 勘定科目一覧（GET /api/v3/accounts）をそのまま返す（プルダウン用）
//   - "suggest" : 過去の仕訳（当期分）からvendor_nameに一致するものを探し、
//                 借方/貸方の勘定科目・部門を提案する（見つからなければ全部null）。
//                 副産物として、見つかった範囲内のユニークな部門一覧も返す（部門プルダウンの代用。
//                 部門一覧専用エンドポイントは今回付与したスコープでは403のため使わない）
//   - "create"  : 実際に仕訳を登録する（POST /api/v3/journals）。呼び出し前にinvoice_can_access()で
//                 権限確認。成功したらinvoices.mf_journal_id等を更新しinvoice_audit_logsへ記録。
//                 invoices.linked_hq_step_idが設定されていれば、その本部タスクの工程も
//                 呼び出しユーザー自身のJWTで完了させる（hq_task_stepsのRLS/トリガーをそのまま経由）
//   - "search_hq_steps": 本部タスクの工程をキーワード検索する（紐付け選択用。未完了のみ）
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
function todayStr(): string {
  return new Date().toISOString().slice(0, 10);
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
    let accessToken: string;
    try {
      ({ accessToken } = await getValidAccessToken());
    } catch (e) {
      return json({ error: "マネーフォワード未連携、またはトークン更新に失敗しました: " + String(e) }, 502);
    }

    if (action === "accounts") {
      const res = await mfFetch("/api/v3/accounts", accessToken);
      const data = await res.json();
      if (!res.ok) return json({ error: "勘定科目の取得に失敗しました", detail: data }, 502);
      return json({ success: true, accounts: data.accounts ?? [] });
    }

    if (action === "suggest") {
      const vendorName: string = (body?.vendor_name ?? "").trim();
      if (!vendorName) return json({ success: true, match: null, departments: [] });

      const res = await mfFetch(
        `/api/v3/journals?start_date=${fiscalYearStart()}&end_date=${todayStr()}&per_page=500&page=1`,
        accessToken,
      );
      const data = await res.json();
      if (!res.ok) return json({ error: "仕訳履歴の取得に失敗しました", detail: data }, 502);

      const journals: any[] = data.journals ?? [];
      const deptMap = new Map<string, string>(); // id -> name
      let best: any = null;
      for (const j of journals) {
        for (const br of j.branches ?? []) {
          for (const side of [br.debitor, br.creditor]) {
            if (side?.department_id) deptMap.set(side.department_id, side.department_name ?? "");
          }
          const hay = [
            br.remark, br.debitor?.trade_partner_name, br.creditor?.trade_partner_name,
            br.debitor?.sub_account_name, br.creditor?.sub_account_name,
          ].filter(Boolean).join(" ");
          if (hay.includes(vendorName)) {
            // transaction_dateが新しいものを優先（journalsは概ね登録順=昇順で返るため単純比較で十分）
            if (!best || (j.transaction_date ?? "") >= (best._date ?? "")) {
              best = {
                debit: { account_id: br.debitor?.account_id, account_name: br.debitor?.account_name, sub_account_id: br.debitor?.sub_account_id, sub_account_name: br.debitor?.sub_account_name, department_id: br.debitor?.department_id, department_name: br.debitor?.department_name },
                credit: { account_id: br.creditor?.account_id, account_name: br.creditor?.account_name, sub_account_id: br.creditor?.sub_account_id, sub_account_name: br.creditor?.sub_account_name, department_id: br.creditor?.department_id, department_name: br.creditor?.department_name },
                remark: br.remark, _date: j.transaction_date,
              };
            }
          }
        }
      }
      if (best) delete best._date;
      return json({
        success: true,
        match: best,
        departments: Array.from(deptMap, ([id, name]) => ({ id, name })),
        searched_count: journals.length,
      });
    }

    if (action === "search_hq_steps") {
      const keyword: string = (body?.keyword ?? "").trim();
      if (!keyword) return json({ success: true, results: [] });
      // 工程タイトル一致・親タスクタイトル一致の両方を探して統合する（会社名がどちら側の
      // タイトルに入っているか分からないため）。どちらも未完了のものだけ対象。
      const [byStep, byTask] = await Promise.all([
        uc.from("hq_task_steps")
          .select("id, title, due_date, task:hq_tasks(id, title, corp, target_date)")
          .ilike("title", `%${keyword}%`).is("completed_at", null).limit(20),
        uc.from("hq_task_steps")
          .select("id, title, due_date, task:hq_tasks!inner(id, title, corp, target_date)")
          .ilike("task.title", `%${keyword}%`).is("completed_at", null).limit(20),
      ]);
      const merged = new Map<string, any>();
      for (const r of [...(byStep.data ?? []), ...(byTask.data ?? [])]) merged.set(r.id, r);
      return json({ success: true, results: Array.from(merged.values()) });
    }

    if (action === "create") {
      const invoiceId = body?.invoice_id;
      const debit = body?.debit; // { account_id, sub_account_id? }
      const credit = body?.credit; // { account_id, sub_account_id? }
      const departmentId = body?.department_id || null;
      const amount = Number(body?.amount);
      const transactionDate = body?.transaction_date || todayStr();
      const remark = (body?.remark ?? "").slice(0, 100);

      if (!invoiceId || !debit?.account_id || !credit?.account_id || !Number.isFinite(amount) || amount <= 0) {
        return json({ error: "必要な項目が不足しています（借方/貸方の勘定科目・金額）" }, 400);
      }

      // 呼び出し元が本当にこの請求書を見れるか（RLS経由で）確認してからemail_idを取得
      const { data: inv, error: invErr } = await uc.from("invoices").select("id, email_id, mf_journal_id, vendor_name, linked_hq_step_id").eq("id", invoiceId).maybeSingle();
      if (invErr) return json({ error: "確認に失敗しました: " + invErr.message }, 500);
      if (!inv) return json({ error: "対象が見つからないか権限がありません" }, 403);
      if (inv.mf_journal_id) return json({ error: "この請求書は既に仕訳登録済みです（重複登録防止）" }, 409);
      // 画面上で選んだが「保存」を押す前に「仕訳を作成」した場合に備え、リクエストの値を優先する
      const linkedHqStepId: string | null = (body?.linked_hq_step_id !== undefined ? body.linked_hq_step_id : inv.linked_hq_step_id) || null;

      const branch: Record<string, unknown> = {
        debitor: { account_id: debit.account_id, value: Math.round(amount), ...(debit.sub_account_id ? { sub_account_id: debit.sub_account_id } : {}), ...(departmentId ? { department_id: departmentId } : {}) },
        creditor: { account_id: credit.account_id, value: Math.round(amount), ...(credit.sub_account_id ? { sub_account_id: credit.sub_account_id } : {}) },
        remark: remark || inv.vendor_name || "",
      };
      const mfBody = { journal: { transaction_date: transactionDate, journal_type: "journal_entry", branches: [branch] } };

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
        mf_journal_id: journalId, mf_journal_number: journalNumber, mf_journal_created_at: new Date().toISOString(),
        ...(linkedHqStepId !== inv.linked_hq_step_id ? { linked_hq_step_id: linkedHqStepId } : {}), // 未保存の選択を反映
      }).eq("id", invoiceId);
      await db.from("mf_sync_logs").insert({ action: "journal_create", actor_type: "human", detail: { invoice_id: invoiceId, journal_id: journalId } });
      await db.from("invoice_audit_logs").insert({
        entity_type: "invoice_email", entity_id: inv.email_id, action: "mf_journal_created", actor_type: "human",
        note: `マネーフォワードへ仕訳登録（伝票番号: ${journalNumber ?? "-"}）`,
      });

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

      return json({ success: true, journal_id: journalId, journal_number: journalNumber, hq_step_completed: hqStepCompleted, hq_step_error: hqStepError });
    }

    return json({ error: "不明なactionです" }, 400);
  } catch (e) {
    return json({ error: "予期しないエラー: " + String(e) }, 500);
  }
});
