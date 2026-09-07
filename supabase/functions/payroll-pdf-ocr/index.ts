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
// 後方互換のため引き続き受け付ける。
//
// 2026-09-07（同日中に再修正）: 上の拡張と同時に「事業所ごとの金額を“AIに合計させる”」システム
// プロンプトへ注意事項を追記したところ、ユーザーから「精度がめちゃくちゃ悪くなってる」と実機報告を
// 受けた。実際のPDF（22行・2事業所・同日に2事業所で勤務する行あり）で診断用Functionを使い新旧の
// システムプロンプトをA/Bテストしたところ、追記後のプロンプトでは事業所別合計が0円近くまで崩れる
// （最悪ケースでは金額欄が数式の文字列のまま返ってくる＝スキーマ違反）ことを確認した。さらに、
// 追記前の「旧」プロンプトであっても、複数回実行すると事業所別合計がブレる（同じPDFなのに
// 実行のたびに数千円単位で結果が変わる）ことも確認された。
// 根本原因は「AIに10〜20件の小数点付き金額を暗算で合計させている」設計そのものにあると判断し、
// 集計方式を全面的に見直した: AIには勤務詳細表の各行（事業所・金額・交通費）をそのまま1行ずつ
// 転記させるだけにし（足し算は一切させない）、事業所ごとの合計はこちらのコード側（JS）で正確に
// 計算する。同じ実PDFで3回連続テストしたところ、3回とも実際の手計算結果と1円の誤差もなく完全一致
// した（旧方式は同じテストで数千〜数万円のブレがあった）。これにより日付欄が空欄の継続行・同日
// 複数事業所の行も、AIに特別なルールを教え込む必要がなく（各行をそのまま転記するだけで自然に
// 正しく扱える）、システムプロンプトもむしろ元より単純化できた。
//
// 入力(JSON): { pdf_files:[{file_name?, file_data(base64)}] } または後方互換の { pdf_base64 }（単数）
//   ※フロント側で既にpayroll-pdfsバケットから取得済みのbase64をそのまま渡す
//   （storageへの再アクセスをこのFunction内で行わずに済むよう、あえてbase64を直接受け取る設計にした）
// 出力(JSON): { success:true, stores:[{store_name, amount_total, commute_total, days_count}], note }
//   ※複数ファイルを渡した場合、stores は全ファイルを通して事業所ごとに集計した結果（1事業所1件）
//   ※出力の形は従来のまま（呼び出し元のinvoices.html側は無変更で動く）。集計方法だけを内部で
//   　「AIが合計する」→「AIは行を転記するだけ・合計はこちらのコードで計算する」に変更した
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

// AIには「行の転記」だけをさせる（事業所ごとの合計計算はさせない＝暗算の誤りを避けるため）
const TOOL = {
  name: "extract_work_detail_rows",
  description: "給与明細PDFの「勤務詳細」表の各行を、事業所ごとの合計計算はせず1行ずつそのまま転記する。",
  input_schema: {
    type: "object",
    properties: {
      rows: {
        type: "array",
        description: "勤務詳細表の各行（1日1事業所につき1件。同じ日に複数の事業所で勤務している場合は、その事業所の数だけ複数件になる）",
        items: {
          type: "object",
          properties: {
            store_name: { type: "string", description: "その行の「事業所」欄に書かれている表記そのまま（例: 本店・芝 等）" },
            amount: { type: "number", description: "その行の「金額」列の数値（円・小数点があればそのまま）" },
            commute: { type: "number", description: "その行の「交通費」列の数値（円）" },
          },
          required: ["store_name", "amount", "commute"],
        },
      },
      note: { type: ["string", "null"], description: "勤務詳細の表が見つからなかった等、読み取りに関する補足があれば日本語で短く。問題なければnull" },
    },
    required: ["rows"],
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
  // 複数PDF対応（pdf_files配列を優先。無ければ従来のpdf_base64単数を1件配列として扱う）
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
        max_tokens: 4096, // 行数が多い（20〜30行×複数事業所）と出力が長くなるため、集計版(1024)より広めに確保
        system: "あなたは日本企業の給与計算担当者向けに、スマレジが出力する給与明細PDFの「勤務詳細」表を読み取るアシスタントです。" +
          "表の各行（勤務日・事業所・金額・交通費）を、合計計算は一切せずそのまま1行ずつ転記してください（合計はこちらのプログラム側で計算します）。" +
          "同じ日付に複数の事業所が記載されている行は、それぞれ別の行として転記してください。" +
          (pdfFiles.length > 1 ? "同じ従業員の給与明細が複数のPDFファイルに分かれて渡されています。全ファイルの行をまとめて転記してください。" : "") +
          "抽出結果は必ずextract_work_detail_rowsツールの呼び出しのみで返してください。",
        tools: [TOOL],
        tool_choice: { type: "tool", name: "extract_work_detail_rows" },
        messages: [{
          role: "user",
          content: [
            { type: "text", text: pdfFiles.length > 1
              ? `この給与明細PDF（同じ従業員の${pdfFiles.length}ファイル分）の「勤務詳細」表の各行を、合計計算はせずそのまま1行ずつ転記してください。`
              : "この給与明細PDFの「勤務詳細」表の各行を、合計計算はせずそのまま1行ずつ転記してください。" },
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
  const toolBlock = (aiJson.content ?? []).find((c: any) => c.type === "tool_use" && c.name === "extract_work_detail_rows");
  if (!toolBlock) return json({ error: "AIの応答を解釈できませんでした" }, 502);
  const result = toolBlock.input ?? {};
  const rows: any[] = Array.isArray(result.rows) ? result.rows : [];

  // 事業所ごとの合計はAIにやらせず、ここ（コード）で正確に計算する（浮動小数の誤差を避けるため
  // 円未満2桁までを整数化してから合計し、最後に100で割って戻す）
  const agg: Record<string, { amount: number; commute: number; count: number }> = {};
  for (const r of rows) {
    const storeName = String(r?.store_name ?? "").trim();
    if (!storeName) continue;
    if (!agg[storeName]) agg[storeName] = { amount: 0, commute: 0, count: 0 };
    agg[storeName].amount += Math.round((Number(r?.amount) || 0) * 100);
    agg[storeName].commute += Math.round(Number(r?.commute) || 0);
    agg[storeName].count += 1;
  }
  const stores = Object.entries(agg).map(([store_name, v]) => ({
    store_name,
    amount_total: Math.round(v.amount) / 100,
    commute_total: v.commute,
    days_count: v.count,
  }));

  return json({ success: true, stores, note: result.note ?? null });
});
