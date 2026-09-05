// 請求書AI自動読み取り Edge Function（Phase1.5・2026-08-24追加／Phase1.6・2026-08-25でmail_kind対応）
//
// invoices.html「🤖 AIで自動入力」ボタンから呼ばれる。指定emailの添付（PDF/画像）を
// Anthropic Claude APIへ渡し、請求元・請求書番号・金額・支払期限を抽出して返す。
// DBへの書き込みは行わない（あくまで提案。ユーザーが内容を確認・修正してから
// 既存の「請求書情報を保存」ボタンで保存する＝invoices.htmlのフォームに入力するだけ）。
//
// mail_kind='sales'のときは同じフィールド名のまま意味を反転させる
// （vendor_name=入金元・amount=入金額・due_date=入金予定日）。フィールド名を共通にすることで
// フロント側のパース・保存先(invoicesテーブル)を一切変えずに済ませている。
// mail_kind='contract'はフロント側でそもそもこの関数を呼ばない想定（保管のみのため）
//
// 入力(JSON): { email_id, mail_kind? }  ※mail_kind省略時は'invoice'として扱う（後方互換）
// 出力(JSON): { success:true, fields:{ vendor_name, invoice_number, amount, due_date, addressee_company, is_invoice, note } }
//
// 【2026-09-03追加】会計・請求書処理の全面刷新（振込先口座変更の自動検知）のため、請求書に
// 振込先口座が記載されていれば併せて抽出する（bank_name/branch_name/account_type/
// account_number/account_holder_kana。すべてnullable・後方互換のため既存フィールドは変更なし）。
// 呼び出し側（invoice-auto-match）が、これを取引先マスタの登録済み口座と突き合わせ、
// 異なる場合は自動更新せず「振込先口座変更」として要確認に回す。読み取れなければ全てnullでよい
// addressee_company（2026-08-27追加）: 宛先・宛名の会社名（自社側）。invoices.htmlはこれを
// マネーフォワードの事業者（トーホー/N-Style等）ラベルと突き合わせ、一致すれば仕訳作成時の
// 事業者選択を自動で行う（間違いを防ぐため、自動選択した旨と確認は必ず画面に表示する）
//
// 認証: 呼び出し元のJWTをそのまま転送しinvoice_emailsをRLS越しに読めるか確認（invoice_can_access()）。
//   読めなければ権限なしとして403（他の請求書系Edge Functionと同じuserClient(req)パターン）。
// 添付取得・AI呼び出しはservice roleで実施（非公開バケットのため）。
//
// 必要な環境変数: ANTHROPIC_API_KEY（Supabase Edge Functionのシークレットとしてのみ設定。
//   コード・リポジトリのどこにも平文で書かない＝INVOICE_INTAKE_SECRET等と同じ方針）
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

const BUCKET = "invoice-files";
const MODEL = "claude-sonnet-5";
const MAX_ATTACHMENTS = 4; // 1メールにつき渡す添付数の上限（コスト・処理時間対策）
const MAX_BYTES_PER_FILE = 15 * 1024 * 1024; // 個別ファイルの上限（Anthropic API側の実質上限に余裕を持たせる）

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  const chunkSize = 0x8000;
  for (let i = 0; i < bytes.length; i += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize));
  }
  return btoa(binary);
}

// mail_kind別のツール定義（フィールド名は共通・説明文だけ意味を切り替える）
function toolFor(kind: string) {
  const isSales = kind === "sales";
  // C-8（ラウンド5指示書§6.1・2026-09-01）: 1メールの添付に複数の請求書（または入金明細）が
  // 含まれる場合があるため、1件ずつの配列で返す。同じ請求書の別ページ（例:表紙+明細の2枚）は
  // 1件にまとめ、実際に別々の取引・別々の請求書だと判断できるものだけを別項目にするよう指示する
  const itemSchema = {
    type: "object",
    properties: {
      vendor_name: { type: ["string", "null"], description: isSales ? "入金元（送金してくる側）の会社名・屋号" : "請求元（発行元）の会社名・屋号" },
      invoice_number: { type: ["string", "null"], description: isSales ? "明細番号・管理番号（無ければnull）" : "請求書番号・伝票番号" },
      amount: { type: ["number", "null"], description: isSales ? "入金額（送金額）。税込の金額を円単位の整数で（カンマ・円記号は含めない）" : "請求金額。税込の合計金額を円単位の整数で（カンマ・円記号は含めない）" },
      due_date: { type: ["string", "null"], description: isSales ? "入金予定日・送金予定日。YYYY-MM-DD形式（西暦・ゼロ埋め）" : "支払期限。YYYY-MM-DD形式（西暦・ゼロ埋め）" },
      addressee_company: { type: ["string", "null"], description: "宛先・宛名として書かれている会社名（「〇〇御中」「〇〇様」の〇〇部分。請求元/入金元とは別の、受け取る側＝自社の名前）。読み取れなければnull" },
      source_hint: { type: ["string", "null"], description: "この請求書がどの添付ファイル（ファイル名）由来かの手がかり。分かれば記入" },
      bank_name: { type: ["string", "null"], description: "振込先の銀行名（記載があれば）。「〇〇銀行」まで含める" },
      bank_branch_name: { type: ["string", "null"], description: "振込先の支店名（記載があれば）。「〇〇支店」まで含める" },
      bank_account_type: { type: ["string", "null"], description: "振込先の口座種別。「普通」「当座」「貯蓄」のいずれか（記載があれば）" },
      bank_account_number: { type: ["string", "null"], description: "振込先の口座番号（記載があれば・数字のみ）" },
      bank_account_holder: { type: ["string", "null"], description: "振込先の口座名義（カナ表記、記載があれば）" },
      note: { type: ["string", "null"], description: "この1件について不確実な点や補足があれば日本語で短く。なければnull" },
    },
    required: [],
  };
  return {
    name: "extract_invoice_fields",
    description: isSales
      ? "添付から読み取った入金・送金情報を、1件ごとの配列で返す。読み取れない項目はnullにする。"
      : "添付から読み取った請求書情報を、1件ごとの配列で返す。読み取れない項目はnullにする。",
    input_schema: {
      type: "object",
      properties: {
        is_invoice: { type: "boolean", description: isSales ? "添付の中に実際の入金明細・送金明細と判断できるものが1件以上あったか" : "添付の中に実際の請求書と判断できるものが1件以上あったか" },
        invoices: {
          type: "array",
          description: isSales
            ? "見つかった入金・送金明細のリスト（1件ずつ）。同じ明細の別ページ（表紙+内訳等）は1件にまとめ、実際に別々の入金・送金だと判断できるものだけを別項目にする"
            : "見つかった請求書のリスト（1件ずつ）。同じ請求書の別ページ（表紙+明細等）は1件にまとめ、実際に別々の請求書だと判断できるものだけを別項目にする",
          items: itemSchema,
        },
      },
      required: ["is_invoice", "invoices"],
    },
  };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return json({ error: "POSTのみ対応" }, 405);

  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) return json({ error: "AI読み取りの設定が未完了です（ANTHROPIC_API_KEY未設定）" }, 500);

  let body: any;
  try {
    body = await req.json();
  } catch (_) {
    return json({ error: "JSONの読み取りに失敗しました" }, 400);
  }
  const emailId = body?.email_id || null;
  // 2026-09-04追加: 共通invoice詳細への統合により、メールに紐付かない請求書（アップロード等）
  // からも同じ「🤖 AIで自動入力」ボタンが使えるよう、invoice_idでも呼び出せるようにした
  const invoiceId = body?.invoice_id || null;
  if (!emailId && !invoiceId) return json({ error: "email_idまたはinvoice_idが必要です" }, 400);
  const mailKind = ["invoice", "sales"].includes(body?.mail_kind) ? body.mail_kind : "invoice";
  const isSales = mailKind === "sales";

  // 呼び出し元がこのメール／請求書にアクセスできるか（=invoice_can_access()）をRLS越しに確認
  const uc = userClient(req);
  let subjectForPrompt = "(件名なし)";
  if (emailId) {
    const { data: emailRow, error: emailErr } = await uc
      .from("invoice_emails").select("id, subject").eq("id", emailId).maybeSingle();
    if (emailErr) return json({ error: "確認に失敗しました: " + emailErr.message }, 500);
    if (!emailRow) return json({ error: "対象が見つからないか権限がありません" }, 403);
    subjectForPrompt = emailRow.subject ?? subjectForPrompt;
  } else {
    const { data: invRow, error: invErr } = await uc
      .from("invoices").select("id, vendor_name").eq("id", invoiceId).maybeSingle();
    if (invErr) return json({ error: "確認に失敗しました: " + invErr.message }, 500);
    if (!invRow) return json({ error: "対象が見つからないか権限がありません" }, 403);
    subjectForPrompt = invRow.vendor_name ? `${invRow.vendor_name}（アップロード請求書）` : "（アップロード請求書）";
  }

  const db = svc();
  let attQuery = db
    .from("invoice_attachments")
    .select("id, file_name, mime_type, storage_path, size_bytes")
    .order("created_at", { ascending: true });
  attQuery = emailId ? attQuery.eq("email_id", emailId) : attQuery.eq("invoice_id", invoiceId);
  const { data: attachments, error: attErr } = await attQuery;
  if (attErr) return json({ error: "添付の取得に失敗しました: " + attErr.message }, 500);

  const candidates = (attachments ?? []).filter((a: any) => {
    const mt = String(a.mime_type ?? "");
    return (mt === "application/pdf" || mt.startsWith("image/")) && (a.size_bytes ?? 0) <= MAX_BYTES_PER_FILE;
  }).slice(0, MAX_ATTACHMENTS);

  if (!candidates.length) {
    return json({ success: true, invoices: [], note: "PDF・画像の添付が見つかりませんでした" });
  }

  const content: any[] = [
    { type: "text", text: isSales
      ? `件名: ${subjectForPrompt}\n添付ファイルから入金・送金明細の情報を読み取ってください。添付の中に複数件の入金・送金明細（別々の取引）が含まれる場合は、それぞれ別項目として全件返してください（同じ明細の別ページは1件にまとめる）。`
      : `件名: ${subjectForPrompt}\n添付ファイルから請求書情報を読み取ってください。添付の中に複数件の請求書（別々の取引先・別々の請求書番号等）が含まれる場合は、それぞれ別項目として全件返してください（同じ請求書の別ページ=表紙+明細等は1件にまとめる）。` },
  ];
  // 2026-09-06修正：請求書処理の速度改善指示への対応。添付ファイルのStorageダウンロードは
  // 1件ずつ独立しており互いに依存しないため、直列forループではなくPromise.allで並列化する
  // （最大MAX_ATTACHMENTS件・通常は数件のため効果は限定的だが、無駄な待ちを削る）。
  // AIへ渡すcontent配列の順序（candidatesの並び）はPromise.all後もそのまま維持する
  const downloaded = await Promise.all(candidates.map(async (a) => {
    const { data: fileData, error: dlErr } = await db.storage.from(BUCKET).download(a.storage_path);
    if (dlErr || !fileData) return null;
    const bytes = new Uint8Array(await fileData.arrayBuffer());
    return { a, b64: bytesToBase64(bytes) };
  }));
  for (const d of downloaded) {
    if (!d) continue;
    const { a, b64 } = d;
    const mt = String(a.mime_type);
    content.push(
      { type: "text", text: `添付ファイル名: ${a.file_name}` },
      mt === "application/pdf"
        ? { type: "document", source: { type: "base64", media_type: "application/pdf", data: b64 } }
        : { type: "image", source: { type: "base64", media_type: mt, data: b64 } },
    );
  }

  let aiRes: Response;
  try {
    aiRes = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": apiKey,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: 1024,
        system: isSales
          ? "あなたは日本企業の経理担当者向けに、メール添付の入金明細・送金明細PDF・画像から項目を抽出するアシスタントです。お金が『出ていく』請求書ではなく『入ってくる』側の情報として読み取ってください。抽出結果は必ずextract_invoice_fieldsツールの呼び出しのみで返してください。"
          : "あなたは日本企業の経理担当者向けに、メール添付の請求書PDF・画像から項目を抽出するアシスタントです。抽出結果は必ずextract_invoice_fieldsツールの呼び出しのみで返してください。",
        tools: [toolFor(mailKind)],
        tool_choice: { type: "tool", name: "extract_invoice_fields" },
        messages: [{ role: "user", content }],
      }),
    });
  } catch (e) {
    return json({ error: "AI読み取りサービスへの接続に失敗しました: " + String(e) }, 502);
  }

  if (!aiRes.ok) {
    const errText = await aiRes.text().catch(() => "");
    return json({ error: `AI読み取りに失敗しました（${aiRes.status}）: ${errText.slice(0, 300)}` }, 502);
  }

  const aiJson: any = await aiRes.json();
  const toolBlock = (aiJson.content ?? []).find((c: any) => c.type === "tool_use" && c.name === "extract_invoice_fields");
  if (!toolBlock) return json({ error: "AIの応答を解釈できませんでした" }, 502);
  const result = toolBlock.input ?? {};
  const invoices: any[] = result.is_invoice && Array.isArray(result.invoices) ? result.invoices : [];

  await db.from("invoice_audit_logs").insert({
    entity_type: "invoice_email",
    entity_id: emailId,
    action: "ocr_extract",
    actor_type: "ai",
    new_value: result,
    note: `AI自動読み取り（${isSales ? "入金明細" : "請求書"}・対象添付${candidates.length}件・検出${invoices.length}件）`,
  });

  return json({ success: true, invoices });
});
