// 担当G: データ出力センター Export Service — 出力実行（PoC: 月次PL／年間推移PL）
// 実装指示書_担当G_データ出力センター_2026-08-25.md ／ 調査レポート_担当G_データ出力センター_2026-08-25.md
//
// 対応フォーマット: excel（exceljs・テンプレート方式）／csv（長形式＋店舗別・合算の両方を1ファイルに）
// Google Sheets出力は承認事項②により後追い（本関数は未対応）。
//
// アーキテクチャ（調査レポート§6）:
//   Supabase(service_role) --権限チェック--> GASブリッジ(bqGetPL, 既存資産・変更なし)
//     --> このEdge Function内でアプリ層の店舗フィルタ・集計 --> exceljs/CSV生成
//     --> export-outputs(非公開バケット)へ保存 --> export_historyへ記録 --> 署名URLを返す
//
// exceljsのDeno互換性メモ（実機検証済み・2026-08-25）: exceljsが依存するarchiverパッケージが
//   import時にNode process.umask()を呼び、Deno既定権限だと NotCapable エラーになる。
//   Supabase Edge Runtimeの権限セットで--allow-sys相当が有効か不明なため、
//   importより前にprocess.umaskをダミー関数で差し替えて回避する（ローカルDeno実機で無権限動作を確認済み）。
// @ts-nocheck
import process from "node:process";
try { (process as any).umask = () => 0o022; } catch (_) { /* ignore */ }

import { createClient } from "npm:@supabase/supabase-js@2";
// 重要: 静的importだと自分のprocess.umaskシムより先にexceljs(→archiver→fstream)が評価され
// NotCapableで落ちる（Deno実機で確認済み）。動的importにして評価タイミングをシムの後に遅らせる。
const ExcelJS = (await import("npm:exceljs@4.4.0")).default;

const DASH_API_URL = "https://script.google.com/macros/s/AKfycbz9rd37EZa6X8WRMVEBrXobN8DbYWkHRlhFNYU5rd1UZ0V8j0-6shMQjEeoi4HDWZ0B/exec";

const cors: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });

const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

function jwtUid(req: Request): string {
  try {
    const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    return JSON.parse(atob(jwt.split(".")[1].replace(/-/g, "+").replace(/_/g, "/"))).sub ?? "";
  } catch (_) { return ""; }
}

async function dashCall(body: unknown) {
  const res = await fetch(DASH_API_URL, {
    method: "POST",
    headers: { "Content-Type": "text/plain;charset=utf-8" },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  try { return JSON.parse(text); }
  catch (_) { return { ok: false, error: "ダッシュボードの応答を読めませんでした: " + text.slice(0, 200) }; }
}

async function dashLogin(sb: any): Promise<{ ok: boolean; token?: string; error?: string }> {
  const { data: sec } = await sb.from("app_secrets").select("key,value").in("key", ["dash_id", "dash_pw"]);
  const secMap: Record<string, string> = {};
  (sec ?? []).forEach((r: any) => { secMap[r.key] = (r.value ?? "").trim(); });
  if (!secMap.dash_id || !secMap.dash_pw) return { ok: false, error: "app_secretsにdash_id/dash_pwが未設定です" };
  const login = await dashCall({ action: "login", id: secMap.dash_id, pw: secMap.dash_pw });
  if (!login.ok) return { ok: false, error: "ダッシュボードへのログインに失敗: " + (login.error ?? "") };
  return { ok: true, token: login.token };
}

function normalizeYm(v: unknown): string | null {
  const m = String(v ?? "").trim().match(/(\d{4})[-\/](\d{2})/);
  return m ? `${m[1]}-${m[2]}` : null;
}

type PlRow = { ym: string; storeName: string; item: string; category: string; amount: number };

async function fetchPlRows(token: string): Promise<PlRow[]> {
  const res = await dashCall({ action: "bqGetPL", token });
  if (!res.ok) throw new Error("bqGetPL取得に失敗: " + (res.error ?? ""));
  const rows: any[] = (res.sheets?.PL ?? []).slice(1);
  const out: PlRow[] = [];
  for (const r of rows) {
    const ym = normalizeYm(r[0]);
    if (!ym) continue;
    out.push({
      ym,
      storeName: String(r[1] ?? "").trim(),
      item: String(r[2] ?? "").trim(),
      category: String(r[3] ?? "").trim(),
      amount: Number(r[4] ?? 0),
    });
  }
  return out;
}

// ---------------- CSV（長形式。既存bqGetPLの7列に合わせる。合算は store_name='__合計__' の合成行として同一ファイルに含める） ----------------
function csvEscape(v: unknown): string {
  const s = String(v ?? "");
  return /[",\n\r]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
}
function buildCsv(matched: PlRow[], companyWide: PlRow[], storeCount: number): Uint8Array {
  const headers = ["年月", "店舗名", "勘定科目", "区分", "金額"];
  const lines = [headers.map(csvEscape).join(",")];
  for (const r of matched) {
    lines.push([r.ym, r.storeName, r.item, r.category, r.amount].map(csvEscape).join(","));
  }
  if (storeCount > 1) {
    const combinedMap = new Map<string, { ym: string; item: string; category: string; amount: number }>();
    for (const r of [...matched, ...companyWide]) {
      const key = `${r.ym}__${r.category}__${r.item}`;
      const cur = combinedMap.get(key) ?? { ym: r.ym, item: r.item, category: r.category, amount: 0 };
      cur.amount += r.amount;
      combinedMap.set(key, cur);
    }
    for (const c of combinedMap.values()) {
      lines.push([c.ym, "__合計__", c.item, c.category, c.amount].map(csvEscape).join(","));
    }
  }
  const text = lines.join("\r\n");
  const bom = new Uint8Array([0xef, 0xbb, 0xbf]);
  const body = new TextEncoder().encode(text);
  const out = new Uint8Array(bom.length + body.length);
  out.set(bom); out.set(body, bom.length);
  return out;
}

// ---------------- Excel（exceljs・テンプレート方式） ----------------
type StyleProfile = {
  titleFont: any; headerFont: any; headerFill: any;
  dataBorder: any; totalFont: any; totalBorder: any; numFmt: string;
  labelColWidth: number; valueColWidth: number;
};

const DEFAULT_STYLE: StyleProfile = {
  titleFont: { bold: true, size: 14, color: { argb: "FF1F5FBF" } },
  headerFont: { bold: true, color: { argb: "FFFFFFFF" } },
  headerFill: { type: "pattern", pattern: "solid", fgColor: { argb: "FF1F5FBF" } },
  dataBorder: { top: { style: "thin" }, bottom: { style: "thin" }, left: { style: "thin" }, right: { style: "thin" } },
  totalFont: { bold: true },
  totalBorder: { top: { style: "double" } },
  numFmt: "#,##0",
  labelColWidth: 22,
  valueColWidth: 14,
};

async function loadStyleProfile(sb: any, layout: any): Promise<StyleProfile> {
  const { data: tpl } = await sb.from("tpl_templates").select("file_path").eq("template_code", "pl_monthly").maybeSingle();
  if (!tpl?.file_path) return DEFAULT_STYLE;
  const { data: fileBlob, error } = await sb.storage.from("export-templates").download(tpl.file_path);
  if (error || !fileBlob) return DEFAULT_STYLE;
  try {
    const buf = await fileBlob.arrayBuffer();
    const wb = new ExcelJS.Workbook();
    await wb.xlsx.load(buf);
    const sheet = wb.worksheets[0];
    const headerRow = layout.header_row ?? 3;
    const dataRow = layout.data_start_row ?? 4;
    const labelCol = layout.label_col ?? 1;
    const valueCol = layout.value_start_col ?? 2;
    const titleCell = sheet.getCell(1, labelCol);
    const headerCell = sheet.getCell(headerRow, valueCol);
    const dataCell = sheet.getCell(dataRow, valueCol);
    const totalCell = sheet.getCell(dataRow + 1, valueCol);
    return {
      titleFont: titleCell.font ?? DEFAULT_STYLE.titleFont,
      headerFont: headerCell.font ?? DEFAULT_STYLE.headerFont,
      headerFill: headerCell.fill ?? DEFAULT_STYLE.headerFill,
      dataBorder: dataCell.border ?? DEFAULT_STYLE.dataBorder,
      totalFont: totalCell.font ?? DEFAULT_STYLE.totalFont,
      totalBorder: totalCell.border ?? DEFAULT_STYLE.totalBorder,
      numFmt: dataCell.numFmt ?? DEFAULT_STYLE.numFmt,
      labelColWidth: sheet.getColumn(labelCol).width ?? DEFAULT_STYLE.labelColWidth,
      valueColWidth: sheet.getColumn(valueCol).width ?? DEFAULT_STYLE.valueColWidth,
    };
  } catch (_) {
    return DEFAULT_STYLE; // テンプレート読込失敗時は既定書式にフォールバック（出力自体は止めない）
  }
}

type SheetRow = { category: string; item: string; byMonth: Map<string, number> };

function buildRowsForScope(rows: PlRow[], scopeStoreNames: Set<string> | null, includeCompanyWide: PlRow[]): { rows: SheetRow[]; months: string[] } {
  // scopeStoreNames=null は「全選択店舗合算」を意味する（rows自体が既に選択店舗全体のはず）
  const target = scopeStoreNames ? rows.filter((r) => scopeStoreNames.has(r.storeName)) : [...rows, ...includeCompanyWide];
  const monthSet = new Set<string>();
  const order: string[] = [];
  const map = new Map<string, SheetRow>();
  for (const r of target) {
    monthSet.add(r.ym);
    const key = `${r.category}__${r.item}`;
    if (!map.has(key)) {
      map.set(key, { category: r.category, item: r.item, byMonth: new Map() });
      order.push(key);
    }
    const sr = map.get(key)!;
    sr.byMonth.set(r.ym, (sr.byMonth.get(r.ym) ?? 0) + r.amount);
  }
  const months = [...monthSet].sort();
  return { rows: order.map((k) => map.get(k)!), months };
}

function writeSheet(wb: ExcelJS.Workbook, sheetName: string, title: string, style: StyleProfile, data: { rows: SheetRow[]; months: string[] }) {
  const sheet = wb.addWorksheet(sheetName.slice(0, 31));
  sheet.getCell("A1").value = title;
  sheet.getCell("A1").font = style.titleFont;
  sheet.getColumn(1).width = style.labelColWidth;
  sheet.getColumn(2).width = style.labelColWidth;

  const headerRowIdx = 3;
  const dataStartRow = 4;
  sheet.getCell(headerRowIdx, 1).value = "区分";
  sheet.getCell(headerRowIdx, 2).value = "勘定科目";
  data.months.forEach((ym, i) => { sheet.getCell(headerRowIdx, 3 + i).value = ym; sheet.getColumn(3 + i).width = style.valueColWidth; });
  const totalColIdx = 3 + data.months.length;
  sheet.getCell(headerRowIdx, totalColIdx).value = "合計";
  sheet.getColumn(totalColIdx).width = style.valueColWidth;
  for (let c = 1; c <= totalColIdx; c++) {
    const cell = sheet.getCell(headerRowIdx, c);
    cell.font = style.headerFont;
    cell.fill = style.headerFill;
    cell.border = style.dataBorder;
  }

  data.rows.forEach((r, idx) => {
    const rowIdx = dataStartRow + idx;
    sheet.getCell(rowIdx, 1).value = r.category;
    sheet.getCell(rowIdx, 2).value = r.item;
    data.months.forEach((ym, i) => {
      const cell = sheet.getCell(rowIdx, 3 + i);
      cell.value = r.byMonth.get(ym) ?? 0;
      cell.numFmt = style.numFmt;
      cell.border = style.dataBorder;
    });
    const totalCell = sheet.getCell(rowIdx, totalColIdx);
    const startColLetter = sheet.getCell(rowIdx, 3).address.replace(/\d+/, "");
    const endColLetter = sheet.getCell(rowIdx, totalColIdx - 1).address.replace(/\d+/, "");
    totalCell.value = data.months.length ? { formula: `SUM(${startColLetter}${rowIdx}:${endColLetter}${rowIdx})` } : 0;
    totalCell.numFmt = style.numFmt;
    totalCell.border = style.dataBorder;
    sheet.getCell(rowIdx, 1).border = style.dataBorder;
    sheet.getCell(rowIdx, 2).border = style.dataBorder;
  });

  const totalRowIdx = dataStartRow + data.rows.length;
  sheet.getCell(totalRowIdx, 2).value = "合計";
  sheet.getCell(totalRowIdx, 2).font = style.totalFont;
  for (let c = 3; c <= totalColIdx; c++) {
    const colLetter = sheet.getCell(dataStartRow, c).address.replace(/\d+/, "");
    const cell = sheet.getCell(totalRowIdx, c);
    cell.value = data.rows.length ? { formula: `SUM(${colLetter}${dataStartRow}:${colLetter}${totalRowIdx - 1})` } : 0;
    cell.numFmt = style.numFmt;
    cell.font = style.totalFont;
    cell.border = style.totalBorder;
  }
  sheet.views = [{ state: "frozen", ySplit: headerRowIdx, xSplit: 2 }];
}

async function buildExcel(sb: any, layout: any, matched: PlRow[], companyWide: PlRow[], storeNamesInOrder: string[], periodFrom: string, periodTo: string): Promise<ArrayBuffer> {
  const style = await loadStyleProfile(sb, layout);
  const wb = new ExcelJS.Workbook();
  wb.creator = "N-Style データ出力センター";
  wb.created = new Date();

  if (storeNamesInOrder.length > 1) {
    const combined = buildRowsForScope(matched, null, companyWide);
    writeSheet(wb, "合計", `月次PL 合計（${periodFrom}〜${periodTo}）`, style, combined);
  }
  for (const name of storeNamesInOrder) {
    const scoped = buildRowsForScope(matched, new Set([name]), []);
    writeSheet(wb, name, `月次PL ${name}（${periodFrom}〜${periodTo}）`, style, scoped);
  }
  const buf = await wb.xlsx.writeBuffer();
  return buf as unknown as ArrayBuffer;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const startedAt = Date.now();
  const sb = svc();
  let historyId: string | null = null;
  try {
    let body: any = {};
    try { body = await req.json(); } catch { /* ボディなし */ }

    const uid = jwtUid(req);
    const { data: u } = await sb.from("users").select("role,is_master,is_active").eq("id", uid).maybeSingle();
    if (!u?.is_active) return json({ ok: false, error: "認証が必要です" }, 401);

    // export_can_access()はauth.uid()前提のSQL関数でservice_roleクライアントからは正しく解決しない
    // （export-preview/index.tsと同じ理由）。RPCに頼らずここで直接ロール判定する。
    const canAccess = !!(u.is_master || ["CEO", "HQ", "TEAM", "TENCHO"].includes(u.role));
    if (!canAccess) return json({ ok: false, error: "データ出力センターへのアクセス権限がありません" }, 403);

    const reportKey = String(body.report_key ?? "");
    if (reportKey !== "pl_monthly") return json({ ok: false, error: "Phase 1では report_key='pl_monthly' のみ対応しています" }, 400);
    const format = String(body.format ?? "");
    if (!["excel", "csv"].includes(format)) return json({ ok: false, error: "formatはexcel/csvのいずれかです（Google Sheetsは後追い予定）" }, 400);

    const periodFrom = String(body.period_from ?? "").slice(0, 7);
    const periodTo = String(body.period_to ?? "").slice(0, 7);
    if (!/^\d{4}-\d{2}$/.test(periodFrom) || !/^\d{4}-\d{2}$/.test(periodTo) || periodFrom > periodTo) {
      return json({ ok: false, error: "対象期間が不正です" }, 400);
    }

    const { data: allowedIds } = await sb.rpc("export_allowed_store_ids", { p_uid: uid });
    const allowedIdSet = new Set<string>((allowedIds ?? []) as string[]);
    if (allowedIdSet.size === 0) return json({ ok: false, error: "出力可能な店舗がありません" }, 403);
    const requestedIds: string[] = Array.isArray(body.store_ids) ? body.store_ids : [];
    const targetIds = requestedIds.length ? requestedIds.filter((id) => allowedIdSet.has(id)) : [...allowedIdSet];
    if (targetIds.length === 0) return json({ ok: false, error: "指定された店舗はいずれも出力権限がありません" }, 403);

    const { data: storeRows } = await sb.from("stores").select("id,name,dash_store_name").in("id", targetIds);
    const storeNamesInOrder: string[] = [];
    const targetNames = new Set<string>();
    (storeRows ?? []).forEach((s: any) => {
      const n = String(s.dash_store_name || s.name).trim();
      if (!targetNames.has(n)) { targetNames.add(n); storeNamesInOrder.push(n); }
    });
    if (targetNames.size === 0) return json({ ok: false, error: "店舗名を解決できませんでした" }, 500);

    // --- 出力履歴を先に作成（pending）。この時点でIDを持っておき失敗時もfailedとして残す ---
    const { data: hist, error: histErr } = await sb.from("export_history").insert({
      user_id: uid,
      report_key: reportKey,
      export_type: format === "excel" ? "excel" : "csv",
      store_ids: targetIds,
      period_from: periodFrom,
      period_to: periodTo,
      filters: { store_names: storeNamesInOrder },
      status: "processing",
    }).select("id").single();
    if (histErr) return json({ ok: false, error: "履歴の作成に失敗: " + histErr.message }, 500);
    historyId = hist.id;

    const login = await dashLogin(sb);
    if (!login.ok) throw new Error(login.error);
    const allRows = await fetchPlRows(login.token!);
    const matched = allRows.filter((r) => r.ym >= periodFrom && r.ym <= periodTo && targetNames.has(r.storeName));
    const companyWide = allRows.filter((r) => r.ym >= periodFrom && r.ym <= periodTo && r.storeName === "");

    if (matched.length === 0) {
      await sb.from("export_history").update({
        status: "failed", error_message: "対象条件に一致するデータがありません", completed_at: new Date().toISOString(),
      }).eq("id", historyId);
      return json({ ok: false, error: "対象条件に一致するデータがありません（BQミラー未反映の可能性）" }, 200);
    }

    const { data: tpl } = await sb.from("tpl_templates").select("id,layout").eq("template_code", "pl_monthly").maybeSingle();
    const layout = tpl?.layout ?? { header_row: 3, data_start_row: 4, label_col: 1, value_start_col: 2 };

    let fileBuf: Uint8Array | ArrayBuffer;
    let ext: string; let contentType: string;
    if (format === "excel") {
      fileBuf = await buildExcel(sb, layout, matched, companyWide, storeNamesInOrder, periodFrom, periodTo);
      ext = "xlsx"; contentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
    } else {
      fileBuf = buildCsv(matched, companyWide, storeNamesInOrder.length);
      ext = "csv"; contentType = "text/csv";
    }

    // 保存キーはASCIIのみ（過去事故: Storageキーに日本語ファイル名を直接使うと Invalid key で失敗。
    // 引継ぎ書_2026-08-24_請求書メール管理Phase1完了.md／WORKLOG参照）。
    // 見た目の良い日本語ファイル名は createSignedUrl の download オプションで付与する。
    const filePath = `${historyId}/pl_monthly_${periodFrom}_${periodTo}.${ext}`;
    const { error: upErr } = await sb.storage.from("export-outputs").upload(filePath, fileBuf, { contentType, upsert: false });
    if (upErr) throw new Error("ファイル保存に失敗: " + upErr.message);

    const downloadName = `月次PL_${periodFrom}_${periodTo}.${ext}`;
    const { data: signed } = await sb.storage.from("export-outputs").createSignedUrl(filePath, 600, { download: downloadName });

    const fileSize = fileBuf instanceof Uint8Array ? fileBuf.byteLength : (fileBuf as ArrayBuffer).byteLength;
    await sb.from("export_history").update({
      template_id: tpl?.id ?? null,
      file_path: filePath,
      status: "completed",
      row_count: matched.length,
      file_size_bytes: fileSize,
      duration_ms: Date.now() - startedAt,
      completed_at: new Date().toISOString(),
    }).eq("id", historyId);

    return json({
      ok: true,
      export_id: historyId,
      file_path: filePath,
      signed_url: signed?.signedUrl ?? null,
      row_count: matched.length,
      store_count: targetNames.size,
    });
  } catch (e) {
    if (historyId) {
      await sb.from("export_history").update({
        status: "failed", error_message: String(e), completed_at: new Date().toISOString(),
      }).eq("id", historyId);
    }
    return json({ ok: false, error: String(e) }, 500);
  }
});
