# 仕様: 請求書の取込口 `invoice-auto-ingest`（担当C → 担当D向け・2026-10-13）

インフォマート請求書の自動取得ジョブ（担当D・Mac mini `infomart-invoice`）が、**取引先1社×1か月ごとに1回**送る取込口。
受け取ると、下書きの請求書＋明細行＋PDF証憑を作り、メール・アップロードと同じ後続（店舗の突合→仕訳下書き→検算→「承認待ち」）に流す。**MFには何も登録しない**（人が承認画面で承認して初めて登録）。

## URL・認証
- `POST https://uuvsxzhpxtghojoubjcc.supabase.co/functions/v1/invoice-auto-ingest`
- ヘッダー: `Content-Type: application/json`（JWT不要）。認証は本文の `secret`＝`app_secrets.invoice_intake_secret`（請求書メール取込と同じ共有シークレット。service roleでDBから読んで使う。コードに直書きしない）

## 本文（JSON）
```json
{
  "secret": "<app_secrets.invoice_intake_secret>",
  "source": "infomart",
  "vendor_hint": "有限会社染谷商店",
  "target_ym": "2026-09",
  "infomart_invoice_no": "（PDFの請求No）",
  "due_date": "2026-10-31",
  "pdf": { "file_name": "染谷商店_202609.pdf", "base64": "...", "sha256": "（base64を戻したバイト列のSHA-256・小文字hex）" },
  "lines": [
    { "dept_code": "01", "tax_category": "課税仕入8%（軽減）", "gross": 942060, "tax": 69782, "sub_account": "㈲染谷商店" }
  ],
  "totals": { "gross": 2486046, "tax": 184151 }
}
```
- `lines` = CSV（会計データ出力）の行＝**取引先×店舗(部門)×税区分**。`dept_code`はインフォマートの部門コード（01〜08）、`gross`＝税込金額（借方金額）、`tax`＝借方税額、`tax_category`は「課税仕入10%」「課税仕入8%（軽減）」「対象外」など（数字を読む。対象外・非課税は税率0）。取引先ごとにCSVの「借方取引先」列で集計して送る。
- **PDFは必須**（無いと422 `pdf_required`）。`sha256`を付ければ受け側で突合（不一致は422 `hash_mismatch`）。
- 受け側の検算（送信側の4段検算と二重）: Σ`gross`＝`totals.gross`（±1円）・Σ`tax`＝`totals.tax`（±1円）。合わなければ422 `totals_mismatch`。

## 戻り値
- 作成: `{ success:true, invoice_id, vendor_resolved, lines, total_gross, total_tax }`
- **重複（作らない・エラーではない）**: `{ success:true, duplicate:true, reason, invoice_id }` — 同じPDF（SHA-256）／同じ取引先×請求番号／同じ取引先×対象月×税込合計。同じものを何度送っても1件にまとまる（毎日10:30の再送でも安全）。
- `vendor_resolved:false` = 取引先名が取引先マスタ（別名含む）に1社で確定できなかった（請求書は作る。承認画面で人が取引先を確定）。

## 受け側の扱い（担当D向けの注意）
1. **店舗は`dept_code`から `resolve_store('infomart', code)` で解決**する（ハブの`stores.store_no`とは06/08が逆）。送信側で店舗名に変換せず、コードのまま送ること。
2. **科目・貸方は取引先ごとの行ルール（`vendor_line_rules`・seed）を優先**する（RSSはCSV既定=仕入高/買掛金だがルール=衛生管理費/おしぼり・未払金）。CSVの科目列は使わない（`sub_account`は参考）。
3. 金額は**CSVの税額をそのまま使う**（仕訳の税込=税抜(gross−tax)+tax。税の1円調整は不要になる）。PLは税抜（gross−tax）で反映。
4. **仕入高のPL反映は、請求書とsiire見込の差額調整方式の確定（司令塔）まで行わない**。承認でのMF登録・精算書・広告費の反映は動く。
5. プレコフーズの納品書（証憑）は未対応。取引先の決まり（`vendor_invoice_policies`）に「本請求書はインボイスではない・納品書が必要」の警告あり。
6. 失敗時の再送: 5xxは再送してよい（二重防止があるため安全）。4xxは内容の修正が必要。
