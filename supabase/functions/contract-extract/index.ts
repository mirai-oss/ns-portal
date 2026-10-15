// 契約書AI読み取り Edge Function（社内情報管理システム「物件・契約」用・2026-10-14新規）
//
// 物件・契約の画面で契約書（PDF・画像）をアップロードした直後に ns-info-system から呼ばれる。
// 書類（info.documents）の契約書をAnthropic Claude APIへ渡し、賃料・管理会社・更新日などを抽出して返す。
// DBの properties は書き換えない（提案のみ）。画面側が読み取り結果をフォームに自動入力し、人が確認して保存する。
// 設計書: docs/設計書_契約書の自動読み取り_2026-10-14.md
//
// 入力(JSON): { document_id, force? }  ※force=true で保存済みの読み取り結果があっても再読み取り
// 出力(JSON): { success:true, cached:boolean, fields:{...}, evidence:{...}, warnings:[...], needs_review:[...] }
//
// 認証: 呼び出し元のJWTでinfo.documentsの行をRLS越しに読めること、かつ has_edit_perm('property') を満たすこと。
// 契約書の取得・AI呼び出し・結果の保存は service role（documents は非公開バケット）。
// 必要な環境変数: ANTHROPIC_API_KEY（invoice-ocr と共通のシークレット）。
import { createClient } from "npm:@supabase/supabase-js@2";

const cors: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });

const URL_ = Deno.env.get("SUPABASE_URL")!;
const svc = () => createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const userClient = (req: Request) =>
  createClient(URL_, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    db: { schema: "info" },
  });

const BUCKET = "documents";
const MODEL = "claude-sonnet-5";
const MAX_BYTES = 15 * 1024 * 1024;

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  return btoa(binary);
}

// properties の列に合わせたフィールド名。値が契約書に無い・読み取れない場合は必ず null（推測しない）
const TOOL = {
  name: "extract_contract_fields",
  description: "賃貸借契約書から、物件・賃料・契約期間などの項目を抽出して返す。契約書に書かれていない項目・読み取れない項目は必ず null にする（推測や計算で埋めない。ただし坪数は下記の換算のみ可）。",
  input_schema: {
    type: "object",
    properties: {
      is_lease_contract: { type: "boolean", description: "建物の賃貸借契約書（または覚書・更新契約書）なら true。それ以外の書類なら false" },
      management_company: { type: ["string", "null"], description: "管理会社（管理業者）の名称。貸主（オーナー）と別に書かれている場合のみ。無ければ null" },
      mgmt_phone: { type: ["string", "null"], description: "管理会社の電話番号" },
      mgmt_contact: { type: ["string", "null"], description: "管理会社の担当者名" },
      landlord_name: { type: ["string", "null"], description: "貸主（賃貸人・オーナー）の名称" },
      landlord_phone: { type: ["string", "null"], description: "貸主の電話番号" },
      tenant_name: { type: ["string", "null"], description: "借主（賃借人）の名称（会社名）。自社側の確認用" },
      property_address: { type: ["string", "null"], description: "物件（賃貸借の目的物）の所在地・建物名・号室" },
      rent: { type: ["integer", "null"], description: "月額賃料（円・整数）。**消費税を含まない税別の金額**。共益費・管理費は含めない。契約書に税別の金額が書かれていればそれをそのまま使う。税込の金額しか書かれていない場合のみ、税率10%で税別に換算した整数（税込÷1.1の端数切捨て）を入れ、doubts に「税込から換算」と書く" },
      rent_tax_note: { type: ["string", "null"], description: "賃料の税の扱い（例: 税別・税込・消費税別途）。契約書の記載のまま。税込金額・消費税額が書かれていればここに併記（例: 税込906,866円・消費税82,351円）" },
      common_fee: { type: ["integer", "null"], description: "月額の共益費・管理費（円・整数）。賃料と同じく税別の金額（税込のみの記載なら税別に換算し doubts に書く）" },
      area_sqm: { type: ["number", "null"], description: "賃貸面積（㎡）。契約書の記載のまま" },
      tsubo: { type: ["number", "null"], description: "賃貸面積（坪）。契約書に坪の記載があればそのまま。㎡のみの場合は ㎡×0.3025 を小数第2位まで" },
      contract_type: { type: ["string", "null"], description: "契約の種類（例: 普通借家契約／定期借家契約）" },
      contract_date: { type: ["string", "null"], description: "契約日（締結日）または契約開始日。YYYY-MM-DD。和暦は西暦に直す" },
      contract_start: { type: ["string", "null"], description: "賃貸借期間の開始日 YYYY-MM-DD" },
      contract_end: { type: ["string", "null"], description: "賃貸借期間の満了日 YYYY-MM-DD" },
      renewal_date: { type: ["string", "null"], description: "更新日（契約更新の期日）。通常は賃貸借期間の満了日。定期借家で更新が無い場合は満了日を入れ、auto_renewal を false にする。YYYY-MM-DD" },
      auto_renewal: { type: ["boolean", "null"], description: "自動更新の定めがあるか" },
      renewal_fee: { type: ["string", "null"], description: "更新料（記載のまま。例: 賃料の1か月分）" },
      notice_period: { type: ["string", "null"], description: "解約予告期間（記載のまま。例: 6か月前）" },
      deposit: { type: ["string", "null"], description: "敷金・保証金（金額と区分を記載のまま。例: 保証金 2,690,160円）" },
      amortization: { type: ["string", "null"], description: "償却・敷引（記載のまま。例: 賃料の1か月）" },
      evidence: {
        type: "object",
        description: "各項目の根拠。キーは上のフィールド名、値は契約書から該当箇所を短く抜粋（条文番号つきなら条番号も）。読み取れた項目だけ書く",
        additionalProperties: { type: "string" },
      },
      doubts: {
        type: "array",
        items: { type: "string" },
        description: "人の確認が必要な点（例: 賃料の記載が2か所で異なる／手書き修正がある／期間満了日が読み取りにくい）",
      },
    },
    required: ["is_lease_contract"],
  },
};

const SYSTEM =
  "あなたは日本の不動産賃貸借契約書（店舗・事務所）から、経理・総務が管理台帳に転記する項目を抽出するアシスタントです。" +
  "契約書に明記された内容だけを返してください。書かれていない項目は null にし、推測で埋めないでください。" +
  "金額はカンマ・円を除いた整数で返します。日付は西暦 YYYY-MM-DD（令和・平成は西暦に換算）。" +
  "契約書が複数ページ・別紙・覚書を含む場合は、最新の合意内容（覚書・変更契約があればそれ）を優先し、その旨を doubts に書いてください。" +
  "賃料が月額と年額で書かれている場合は月額にしてください。";

const isIso = (s: unknown) => typeof s === "string" && /^\d{4}-\d{2}-\d{2}$/.test(s) && !Number.isNaN(Date.parse(s));

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) return json({ error: "AI読み取りのAPIキーが未設定です（ANTHROPIC_API_KEY）" }, 500);

  let body: any = null;
  try { body = await req.json(); } catch { return json({ error: "JSONを読み取れません" }, 400); }
  const documentId = String(body?.document_id ?? "");
  const force = body?.force === true;
  if (!documentId) return json({ error: "document_id は必須です" }, 400);

  // 認証: 呼び出し元がこの書類を読めて、物件の編集権限があること
  const uc = userClient(req);
  const { data: doc, error: docErr } = await uc.from("documents")
    .select("id, corporation_id, title, file_path, mime_type, size_bytes").eq("id", documentId).maybeSingle();
  if (docErr || !doc) return json({ error: "書類が見つからないか、権限がありません" }, 403);
  const { data: canEdit } = await uc.rpc("has_edit_perm", { cat: "property" });
  if (canEdit !== true) {
    const { data: au } = await uc.auth.getUser();
    const { data: me } = au?.user ? await uc.from("profiles").select("is_master").eq("id", au.user.id).maybeSingle() : { data: null };
    if (!me?.is_master) return json({ error: "物件・契約の編集権限がありません" }, 403);
  }

  const db = svc();
  const dbi = createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { db: { schema: "info" } });

  // 保存済みの結果があればそれを返す（同じ契約書で二重に課金しない）
  if (!force) {
    const { data: prev } = await dbi.from("contract_extractions").select("result").eq("document_id", documentId)
      .order("created_at", { ascending: false }).limit(1).maybeSingle();
    if (prev?.result) return json({ success: true, cached: true, ...(prev.result as object) });
  }

  const mt = String(doc.mime_type ?? "");
  if (!(mt === "application/pdf" || mt.startsWith("image/"))) {
    return json({ error: "PDFまたは画像の契約書のみ読み取れます" }, 400);
  }
  if ((doc.size_bytes ?? 0) > MAX_BYTES) return json({ error: "ファイルが大きすぎます（15MBまで）" }, 400);

  const { data: file, error: dlErr } = await db.storage.from(BUCKET).download(doc.file_path);
  if (dlErr || !file) return json({ error: "契約書ファイルを取得できませんでした" }, 500);
  const b64 = bytesToBase64(new Uint8Array(await file.arrayBuffer()));

  let aiRes: Response;
  try {
    aiRes = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "content-type": "application/json", "x-api-key": apiKey, "anthropic-version": "2023-06-01" },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: 2048,
        system: SYSTEM,
        tools: [TOOL],
        tool_choice: { type: "tool", name: TOOL.name },
        messages: [{
          role: "user",
          content: [
            { type: "text", text: `書類名: ${doc.title ?? ""}\nこの契約書から項目を抽出してください。` },
            mt === "application/pdf"
              ? { type: "document", source: { type: "base64", media_type: "application/pdf", data: b64 } }
              : { type: "image", source: { type: "base64", media_type: mt, data: b64 } },
          ],
        }],
      }),
    });
  } catch (e) {
    return json({ error: "AI読み取りサービスへの接続に失敗しました: " + String(e) }, 502);
  }
  if (!aiRes.ok) {
    const t = await aiRes.text().catch(() => "");
    return json({ error: `AI読み取りに失敗しました（${aiRes.status}）: ${t.slice(0, 300)}` }, 502);
  }
  const aiJson: any = await aiRes.json();
  const tb = (aiJson.content ?? []).find((c: any) => c.type === "tool_use" && c.name === TOOL.name);
  if (!tb) return json({ error: "AIの応答を解釈できませんでした" }, 502);
  const r: any = tb.input ?? {};

  // 値の検証（AIの出力を鵜呑みにしない）。怪しい値は null にして「要確認」へ回す
  const warnings: string[] = [];
  const needsReview: string[] = [...(Array.isArray(r.doubts) ? r.doubts.map(String) : [])];
  const fields: Record<string, unknown> = {};
  const str = (k: string) => (typeof r[k] === "string" && r[k].trim() ? r[k].trim() : null);
  for (const k of ["management_company", "mgmt_phone", "mgmt_contact", "landlord_name", "landlord_phone", "tenant_name",
    "property_address", "rent_tax_note", "contract_type", "renewal_fee", "notice_period", "deposit", "amortization"]) fields[k] = str(k);
  const int = (k: string, lo: number, hi: number) => {
    const v = r[k];
    if (v == null) return null;
    const n = Number(v);
    if (!Number.isFinite(n) || !Number.isInteger(n) || n < lo || n > hi) { warnings.push(`${k} の値が範囲外のため無視しました（${v}）`); return null; }
    return n;
  };
  fields.rent = int("rent", 1, 20_000_000);
  fields.common_fee = int("common_fee", 0, 5_000_000);
  const num = (k: string, lo: number, hi: number) => {
    const v = r[k];
    if (v == null) return null;
    const n = Number(v);
    if (!Number.isFinite(n) || n < lo || n > hi) { warnings.push(`${k} の値が範囲外のため無視しました（${v}）`); return null; }
    return Math.round(n * 100) / 100;
  };
  fields.area_sqm = num("area_sqm", 1, 5000);
  fields.tsubo = num("tsubo", 0.5, 2000);
  for (const k of ["contract_date", "contract_start", "contract_end", "renewal_date"]) {
    if (r[k] == null) { fields[k] = null; continue; }
    if (!isIso(r[k])) { warnings.push(`${k} の日付形式が不正のため無視しました（${r[k]}）`); fields[k] = null; continue; }
    fields[k] = r[k];
  }
  fields.auto_renewal = typeof r.auto_renewal === "boolean" ? r.auto_renewal : null;
  // 更新日が無く満了日がある場合は満了日を更新日の候補にする（定期借家でない場合）
  if (!fields.renewal_date && fields.contract_end) {
    fields.renewal_date = fields.contract_end;
    needsReview.push("更新日は契約書に明記がないため、賃貸借期間の満了日を入れています");
  }
  if (fields.contract_start && fields.contract_end && String(fields.contract_end) < String(fields.contract_start)) {
    warnings.push("賃貸借期間の終了日が開始日より前です。日付を確認してください");
  }

  const out = {
    is_lease_contract: r.is_lease_contract === true,
    fields,
    evidence: (r.evidence && typeof r.evidence === "object") ? r.evidence : {},
    warnings,
    needs_review: needsReview,
  };

  const { data: u } = await uc.auth.getUser();
  await dbi.from("contract_extractions").insert({
    document_id: documentId,
    corporation_id: doc.corporation_id,
    result: out,
    model: MODEL,
    created_by: u?.user?.id ?? null,
  });

  return json({ success: true, cached: false, ...out });
});
