// 給与明細PDF「事業所別集計」AI読み取り Edge Function（2026-09-02新規）
//
// invoices.html給与仕訳プレビューの「📊 PDFから事業所別の金額・交通費を読み取る」ボタンから呼ばれる。
// 当初はpdf.js＋正規表現でテキスト抽出→パターン照合していたが、ユーザー実機テストで
// 実際のPDFに対して「勤務詳細の表を読み取れませんでした」と失敗する不具合が発生した
// （店舗名の表記ゆれ・レイアウトの細かな差異に弱いため）。ユーザーから
// 「請求書メールの請求書読み取りと同じ理屈で、AIでつないでできないものなのか」と提案があり、
// 既存のinvoice-ocr Edge Function（Anthropic Claude APIへPDFを直接渡して構造化抽出する方式）
// と全く同じ設計に切り替えた。正規表現より遥かにレイアウト崩れ・表記ゆれに強い。
//
// 2026-09-07: 給与明細PDFが事業所ごとに複数枚に分かれている従業員（担当Bスレッド依頼）に対応するため、
// 複数PDFをまとめて1回のAI呼び出しで読み取れるよう拡張（pdf_files配列）。従来のpdf_base64（単数）も
// 後方互換のため引き続き受け付ける。あわせて、担当Bスレッドから受領した「AIで仕訳候補を自動生成する」
// 仕様の注意事項（同日複数事業所・日付空欄の継続行への対応）をAIへの指示文に明記した
//
// 入力(JSON): { pdf_files:[{file_name?, file_data(base64)}] } または後方互換の { pdf_base64 }（単数）
//   ※フロント側で既にpayroll-pdfsバケットから取得済みのbase64をそのまま渡す
//   （storageへの再アクセスをこのFunction内で行わずに済むよう、あえてbase64を直接受け取る設計にした）
// 出力(JSON): { success:true, stores:[{store_name, amount_total, commute_total, days_count}], note }
//   ※複数ファイルを渡した場合、stores は全ファイルを通して事業所ごとに集計した結果（1事業所1件）
//
// 認証: 呼び出し元のJWTでinvoice_can_access()を満たすか確認（他の請求書・給与仕訳系Edge Functionと同じ）
// 必要な環境変数: ANTHROPIC_API_KEY（invoice-ocrと同じシークレットをそのまま流用）
import { createClient } from "npm:@supabase/supabase-js@2";

const cors: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });

const userClient = (req: Request) =>
  createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });

const MODEL = "claude-sonnet-5";

const TOOL = {
  name: "extract_store_breakdown",
  description: "給与明細PDFの「勤務詳細」表（勤務日・事業所・勤務時間・時給単価・金額・交通費の列を持つ表）から、事業所（勤務先店舗）ごとに金額列・交通費列を合計して返す。",
  input_schema: {
    type: "object",
    properties: {
      stores: {
        type: "array",
        description: "事業所ごとの集計結果（1事業所につき1件）",
        items: {
          type: "object",
          properties: {
            store_name: { type: "string", description: "勤務詳細表の「事業所」欄に書かれている表記そのまま（例: 本店・芝 等）" },
            amount_total: { type: "number", description: "その事業所の「金額」列の合計（円・小数点があればそのまま）" },
            commute_total: { type: "number", description: "その事業所の「交通費」列の合計（円・整数）" },
            days_count: { type: "number", description: "その事業所での勤務日数（行数）" },
          },
          required: ["store_name", "amount_total", "commute_total", "days_count"],
        },
      },
      note: { type: ["string", "null"], description: "勤務詳細の表が見つからなかった等、読み取りに関する補足があれば日本語で短く。問題なければnull" },
    },
    required: ["stores"],
  },
};

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
  // 2026-09-07: 複数PDF対応（pdf_files配列を優先。無ければ従来のpdf_base64単数を1件配列として扱う）
  let pdfFiles: { file_name?: string; file_data: string }[] = [];
  if (Array.isArray(body?.pdf_files)) {
    pdfFiles = body.pdf_files.filter((f: any) => f && typeof f.file_data === "string");
  } else if (typeof body?.pdf_base64 === "string" && body.pdf_base64) {
    pdfFiles = [{ file_data: body.pdf_base64 }];
  }
  if (!pdfFiles.length) return json({ error: "pdf_filesまたはpdf_base64は必須です" }, 400);
  if (pdfFiles.length > 5) pdfFiles = pdfFiles.slice(0, 5); // 念のための上限（voucher_files添付上限と揃える）

  // 権限確認（他の請求書・給与仕訳系Edge Functionと同じパターン）
  const uc = userClient(req);
  const { data: canAccess, error: accessErr } = await uc.rpc("invoice_can_access");
  if (accessErr || canAccess !== true) return json({ error: "権限がありません" }, 403);

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
        system: "あなたは日本企業の給与計算担当者向けに、スマレジが出力する給与明細PDFの「勤務詳細」表を読み取るアシスタントです。表の「事業所」列に登場する勤務先ごとに、「金額」列と「交通費」列を正確に合計してください。" +
          "同じ従業員の給与明細が複数のPDFファイルに分かれて渡されることがあります（事業所ごとに明細が分かれているケース）。その場合は全ファイルを通して事業所ごとに集計してください（同じ事業所名が複数ファイルに跨って登場する場合は合算する）。" +
          "1つの表の中で、同じ日付に複数の事業所が記載されている行（掛け持ち勤務）は、それぞれ該当する事業所の集計に含めてください。日付欄が空欄の行は、直前の行と同じ日付の続き（同日の別時間帯や別事業所の追加行）とみなして扱ってください。" +
          "抽出結果は必ずextract_store_breakdownツールの呼び出しのみで返してください。",
        tools: [TOOL],
        tool_choice: { type: "tool", name: "extract_store_breakdown" },
        messages: [{
          role: "user",
          content: [
            { type: "text", text: pdfFiles.length > 1
              ? `この給与明細PDF（同じ従業員の${pdfFiles.length}ファイル分）の「勤務詳細」表から、事業所ごとの金額合計・交通費合計を、全ファイルを通して集計してください。`
              : "この給与明細PDFの「勤務詳細」表から、事業所ごとの金額合計・交通費合計を集計してください。" },
            ...pdfFiles.map((f) => ({ type: "document", source: { type: "base64", media_type: "application/pdf", data: f.file_data } })),
          ],
        }],
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
  const toolBlock = (aiJson.content ?? []).find((c: any) => c.type === "tool_use" && c.name === "extract_store_breakdown");
  if (!toolBlock) return json({ error: "AIの応答を解釈できませんでした" }, 502);
  const result = toolBlock.input ?? {};
  const stores: any[] = Array.isArray(result.stores) ? result.stores : [];

  return json({ success: true, stores, note: result.note ?? null });
});
