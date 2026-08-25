// 担当G: データ出力センター Export Service — 出力実行（PoC: 月次PL／年間推移PL）
// 実装指示書_担当G_データ出力センター_2026-08-25.md ／ 調査レポート_担当G_データ出力センター_2026-08-25.md
//
// 2026-08-25 ユーザーフィードバックにより改修:
//   ①「売上・仕入が入っていない」→ stg_pl（bqGetPL）は手入力の販管費（F/L/A/R/O区分）のみで、
//     売上高・原価（自動）・人件費（自動）は別のBQテーブル(fact_daily_store、bqDailyStore経由)に
//     あることが判明。tori-dashboard/app.js の viewPL()（3801行目〜）が実際に行っている
//     「自動集計(stat()) と 手入力(plAgg()) を合成してPLを組み立てる」ロジックを再現し、
//     売上高→原価→売上総利益→人件費/広告費/家賃/その他経費→販管費計→営業利益 の構造で出力する。
//   ②「月次PL／年間推移PLが同じになる」→ report_key を pl_monthly と pl_annual_trend の
//     2種類に分離（内部の集計・出力ロジックは共通、タイトル・テンプレートコードのみ分岐）。
//
// 対応フォーマット: excel（exceljs・テンプレート方式）／csv（長形式）
// Google Sheets出力は承認事項②により後追い（本関数は未対応）。
//
// アーキテクチャ（調査レポート§6）:
//   Supabase(service_role) --権限チェック--> GASブリッジ(bqGetPL/bqDailyStore、既存資産・変更なし)
//     --> このEdge Function内でアプリ層の店舗フィルタ・集計 --> exceljs/CSV生成
//     --> export-outputs(非公開バケット)へ保存 --> export_historyへ記録 --> 署名URLを返す
//
// exceljsのDeno互換性メモ（実機検証済み・2026-08-25）: exceljsが依存するarchiverパッケージが
//   import時にNode process.umask()を呼び、Deno既定権限だと NotCapable エラーになる。
//   importより前にprocess.umaskをダミー関数で差し替えて回避する（動的importが必須。静的importだと
//   自分のシムより先にexceljsが評価されてしまい失敗する＝実機で確認済み）。
// @ts-nocheck
import process from "node:process";
try { (process as any).umask = () => 0o022; } catch (_) { /* ignore */ }

import { createClient } from "npm:@supabase/supabase-js@2";
const ExcelJS = (await import("npm:exceljs@4.4.0")).default;

const DASH_API_URL = "https://script.google.com/macros/s/AKfycbz9rd37EZa6X8WRMVEBrXobN8DbYWkHRlhFNYU5rd1UZ0V8j0-6shMQjEeoi4HDWZ0B/exec";
const REPORT_TITLE: Record<string, string> = { pl_monthly: "月次PL", pl_annual_trend: "年間推移PL" };

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

// ---------------- データ取得 ----------------
// stg_pl（手入力の販管費。区分F=原価補正／L=人件費補正／A=広告費／R=家賃／O=その他経費）
type PlItemRow = { ym: string; storeName: string; item: string; category: string; amount: number };

async function fetchPlRows(token: string): Promise<PlItemRow[]> {
  const res = await dashCall({ action: "bqGetPL", token });
  if (!res.ok) throw new Error("bqGetPL取得に失敗: " + (res.error ?? ""));
  const rows: any[] = (res.sheets?.PL ?? []).slice(1);
  const out: PlItemRow[] = [];
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

// fact_daily_store（自動集計。売上高・原価・人件費の日次実績を月次に集約）
type DailyAgg = { ym: string; storeName: string; netSales: number; cogs: number; labor: number };

async function fetchDailyAgg(token: string): Promise<DailyAgg[]> {
  const res = await dashCall({ action: "bqDailyStore", token });
  if (!res.ok) throw new Error("bqDailyStore取得に失敗: " + (res.error ?? ""));
  const rows: any[] = (res.sheets?.daily ?? []).slice(1);
  // header: date, store_name, net_sales, guests_total, parttime_labor_cost, fulltime_labor_cost,
  //         labor_cost_total, cogs, cash, employee_salary_bonus, statutory_welfare, commute_allowance, parties_total
  const map = new Map<string, DailyAgg>();
  for (const r of rows) {
    const ym = normalizeYm(r[0]);
    if (!ym) continue;
    const storeName = String(r[1] ?? "").trim();
    const key = `${ym}__${storeName}`;
    const cur = map.get(key) ?? { ym, storeName, netSales: 0, cogs: 0, labor: 0 };
    cur.netSales += Number(r[2] ?? 0);
    cur.labor += Number(r[6] ?? 0);
    cur.cogs += Number(r[7] ?? 0);
    map.set(key, cur);
  }
  return [...map.values()];
}

// stg_plの区分コード → PLの区分（表示名）
const SECTION_BY_CODE: Record<string, string> = { F: "原価", L: "人件費", A: "広告費", R: "家賃", O: "その他経費" };
const SECTION_ORDER = ["売上", "原価", "人件費", "広告費", "家賃", "その他経費"];

// ---------------- CSV（長形式・自然な符号（費用も正の値）。区分・出所を明示） ----------------
function csvEscape(v: unknown): string {
  const s = String(v ?? "");
  return /[",\n\r]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
}
function buildCsv(dailyScoped: DailyAgg[], plScoped: PlItemRow[]): Uint8Array {
  const headers = ["年月", "店舗名", "区分", "勘定科目", "出所", "金額"];
  const lines = [headers.map(csvEscape).join(",")];
  for (const d of dailyScoped) {
    lines.push([d.ym, d.storeName, "売上", "売上高", "自動", d.netSales].map(csvEscape).join(","));
    lines.push([d.ym, d.storeName, "原価", "原価（自動）", "自動", d.cogs].map(csvEscape).join(","));
    lines.push([d.ym, d.storeName, "人件費", "人件費（自動）", "自動", d.labor].map(csvEscape).join(","));
  }
  for (const p of plScoped) {
    const section = SECTION_BY_CODE[p.category] ?? "その他経費";
    lines.push([p.ym, p.storeName || "（全社共通）", section, p.item, "手入力", p.amount].map(csvEscape).join(","));
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

async function loadStyleProfile(sb: any, templateCode: string, layout: any): Promise<StyleProfile> {
  const { data: tpl } = await sb.from("tpl_templates").select("file_path").eq("template_code", templateCode).maybeSingle();
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

type SheetRow = { section: string; item: string; sign: 1 | -1; byMonth: Map<string, number> };

// 選択スコープ（1店舗、または合算=null）に絞った売上・原価・人件費（自動）＋stg_pl手入力を
// 「区分（売上/原価/人件費/広告費/家賃/その他経費）」単位の行リストへ変換する。
// 費用行はsign=-1で保持し、月別セルには符号込みの値を書く（合計行が単純SUMで正しい営業利益になるようにするため）。
function buildSections(
  dailyRows: DailyAgg[], plRows: PlItemRow[],
  scopeStoreNames: Set<string> | null, companyWidePl: PlItemRow[],
): { rows: SheetRow[]; months: string[] } {
  const dScoped = scopeStoreNames ? dailyRows.filter((d) => scopeStoreNames.has(d.storeName)) : dailyRows;
  const pScoped = scopeStoreNames ? plRows.filter((p) => scopeStoreNames.has(p.storeName)) : [...plRows, ...companyWidePl];

  const monthSet = new Set<string>();
  const order: string[] = [];
  const map = new Map<string, SheetRow>();
  const upsert = (key: string, section: string, item: string, sign: 1 | -1, ym: string, amount: number) => {
    monthSet.add(ym);
    if (!map.has(key)) { map.set(key, { section, item, sign, byMonth: new Map() }); order.push(key); }
    const r = map.get(key)!;
    r.byMonth.set(ym, (r.byMonth.get(ym) ?? 0) + sign * amount);
  };

  for (const d of dScoped) {
    upsert("売上__売上高", "売上", "売上高", 1, d.ym, d.netSales);
    upsert("原価__原価（自動）", "原価", "原価（自動）", -1, d.ym, d.cogs);
    upsert("人件費__人件費（自動）", "人件費", "人件費（自動）", -1, d.ym, d.labor);
  }
  for (const p of pScoped) {
    const section = SECTION_BY_CODE[p.category] ?? "その他経費";
    upsert(`${section}__${p.item}`, section, p.item, -1, p.ym, p.amount);
  }

  // 区分の並び順（売上→原価→人件費→広告費→家賃→その他経費）で安定ソート
  order.sort((ka, kb) => {
    const a = map.get(ka)!, b = map.get(kb)!;
    const sa = SECTION_ORDER.indexOf(a.section), sb = SECTION_ORDER.indexOf(b.section);
    return sa !== sb ? sa - sb : 0;
  });
  const months = [...monthSet].sort();
  return { rows: order.map((k) => map.get(k)!), months };
}

function colLetter(sheet: any, row: number, col: number): string {
  return sheet.getCell(row, col).address.replace(/\d+/, "");
}

function writePlSheet(wb: any, sheetName: string, title: string, style: StyleProfile, data: { rows: SheetRow[]; months: string[] }) {
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
    cell.font = style.headerFont; cell.fill = style.headerFill; cell.border = style.dataBorder;
  }

  const writeDataRow = (rowIdx: number, label1: string, label2: string, byMonth: Map<string, number> | null, bold: boolean) => {
    sheet.getCell(rowIdx, 1).value = label1;
    sheet.getCell(rowIdx, 2).value = label2;
    if (bold) { sheet.getCell(rowIdx, 1).font = style.totalFont; sheet.getCell(rowIdx, 2).font = style.totalFont; }
    data.months.forEach((ym, i) => {
      const cell = sheet.getCell(rowIdx, 3 + i);
      if (byMonth) cell.value = byMonth.get(ym) ?? 0;
      cell.numFmt = style.numFmt;
      cell.border = bold ? style.totalBorder : style.dataBorder;
      if (bold) cell.font = style.totalFont;
    });
    const totalCell = sheet.getCell(rowIdx, totalColIdx);
    if (data.months.length) {
      const c1 = colLetter(sheet, rowIdx, 3), c2 = colLetter(sheet, rowIdx, totalColIdx - 1);
      totalCell.value = { formula: `SUM(${c1}${rowIdx}:${c2}${rowIdx})` };
    } else totalCell.value = 0;
    totalCell.numFmt = style.numFmt;
    totalCell.border = bold ? style.totalBorder : style.dataBorder;
    if (bold) totalCell.font = style.totalFont;
    sheet.getCell(rowIdx, 1).border = bold ? style.totalBorder : style.dataBorder;
    sheet.getCell(rowIdx, 2).border = bold ? style.totalBorder : style.dataBorder;
  };

  let r = dataStartRow;
  const salesStart = r;
  for (const row of data.rows.filter((x) => x.section === "売上")) { writeDataRow(r, row.section, row.item, row.byMonth, false); r++; }
  for (const row of data.rows.filter((x) => x.section === "原価")) { writeDataRow(r, row.section, row.item, row.byMonth, false); r++; }
  const costEnd = r - 1;
  const grossRow = r; writeDataRow(r, "", "売上総利益", null, true);
  // 売上総利益 = SUM(売上〜原価の範囲)。月別セル・合計セルとも直接SUM式を上書きする
  for (let i = 0; i < data.months.length; i++) {
    const c = colLetter(sheet, grossRow, 3 + i);
    sheet.getCell(grossRow, 3 + i).value = { formula: `SUM(${c}${salesStart}:${c}${costEnd})` };
  }
  sheet.getCell(grossRow, totalColIdx).value = data.months.length
    ? { formula: `SUM(${colLetter(sheet, grossRow, 3)}${grossRow}:${colLetter(sheet, grossRow, totalColIdx - 1)}${grossRow})` } : 0;
  r++;

  const sgaStart = r;
  for (const sec of ["人件費", "広告費", "家賃", "その他経費"]) {
    for (const row of data.rows.filter((x) => x.section === sec)) { writeDataRow(r, row.section, row.item, row.byMonth, false); r++; }
  }
  const sgaEnd = r - 1;
  const sgaRow = r; writeDataRow(r, "", "販管費計", null, true);
  for (let i = 0; i < data.months.length; i++) {
    const c = colLetter(sheet, sgaRow, 3 + i);
    sheet.getCell(sgaRow, 3 + i).value = sgaEnd >= sgaStart ? { formula: `SUM(${c}${sgaStart}:${c}${sgaEnd})` } : 0;
  }
  sheet.getCell(sgaRow, totalColIdx).value = data.months.length
    ? { formula: `SUM(${colLetter(sheet, sgaRow, 3)}${sgaRow}:${colLetter(sheet, sgaRow, totalColIdx - 1)}${sgaRow})` } : 0;
  r++;

  const opRow = r; writeDataRow(r, "", "営業利益", null, true);
  for (let i = 0; i < data.months.length; i++) {
    const c = colLetter(sheet, opRow, 3 + i);
    sheet.getCell(opRow, 3 + i).value = { formula: `${c}${grossRow}+${c}${sgaRow}` };
  }
  sheet.getCell(opRow, totalColIdx).value = { formula: `${colLetter(sheet, opRow, totalColIdx)}${grossRow}+${colLetter(sheet, opRow, totalColIdx)}${sgaRow}` };

  sheet.views = [{ state: "frozen", ySplit: headerRowIdx, xSplit: 2 }];
}

async function buildExcel(
  sb: any, reportKey: string, layout: any,
  dailyRows: DailyAgg[], plRows: PlItemRow[], companyWidePl: PlItemRow[],
  storeNamesInOrder: string[], periodFrom: string, periodTo: string,
): Promise<ArrayBuffer> {
  const style = await loadStyleProfile(sb, reportKey, layout);
  const wb = new ExcelJS.Workbook();
  wb.creator = "N-Style データ出力センター";
  wb.created = new Date();
  const title = REPORT_TITLE[reportKey] ?? "PL";

  if (storeNamesInOrder.length > 1) {
    const combined = buildSections(dailyRows, plRows, null, companyWidePl);
    writePlSheet(wb, "合計", `${title} 合計（${periodFrom}〜${periodTo}）`, style, combined);
  }
  for (const name of storeNamesInOrder) {
    const scoped = buildSections(dailyRows, plRows, new Set([name]), []);
    writePlSheet(wb, name, `${title} ${name}（${periodFrom}〜${periodTo}）`, style, scoped);
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
    if (!["pl_monthly", "pl_annual_trend"].includes(reportKey)) {
      return json({ ok: false, error: "report_keyはpl_monthly/pl_annual_trendのいずれかです" }, 400);
    }
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
    const [allPlRows, allDailyRows] = await Promise.all([fetchPlRows(login.token!), fetchDailyAgg(login.token!)]);

    const plMatched = allPlRows.filter((r) => r.ym >= periodFrom && r.ym <= periodTo && targetNames.has(r.storeName));
    const plCompanyWide = allPlRows.filter((r) => r.ym >= periodFrom && r.ym <= periodTo && r.storeName === "");
    const dailyMatched = allDailyRows.filter((r) => r.ym >= periodFrom && r.ym <= periodTo && targetNames.has(r.storeName));

    if (plMatched.length === 0 && dailyMatched.length === 0) {
      await sb.from("export_history").update({
        status: "failed", error_message: "対象条件に一致するデータがありません", completed_at: new Date().toISOString(),
      }).eq("id", historyId);
      return json({ ok: false, error: "対象条件に一致するデータがありません（BQミラー未反映の可能性）" }, 200);
    }

    const { data: tpl } = await sb.from("tpl_templates").select("id,layout").eq("template_code", reportKey).maybeSingle();
    const layout = tpl?.layout ?? { header_row: 3, data_start_row: 4, label_col: 1, value_start_col: 2 };
    const rowCount = plMatched.length + dailyMatched.length * 3; // 売上高・原価・人件費の3行/月店舗 相当

    let fileBuf: Uint8Array | ArrayBuffer;
    let ext: string; let contentType: string;
    if (format === "excel") {
      fileBuf = await buildExcel(sb, reportKey, layout, dailyMatched, plMatched, plCompanyWide, storeNamesInOrder, periodFrom, periodTo);
      ext = "xlsx"; contentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
    } else {
      fileBuf = buildCsv(dailyMatched, [...plMatched, ...plCompanyWide]);
      ext = "csv"; contentType = "text/csv";
    }

    // 保存キーはASCIIのみ（過去事故: Storageキーに日本語ファイル名を直接使うと Invalid key で失敗。
    // 引継ぎ書_2026-08-24_請求書メール管理Phase1完了.md／WORKLOG参照）。
    // 見た目の良い日本語ファイル名は createSignedUrl の download オプションで付与する。
    const filePath = `${historyId}/${reportKey}_${periodFrom}_${periodTo}.${ext}`;
    const { error: upErr } = await sb.storage.from("export-outputs").upload(filePath, fileBuf, { contentType, upsert: false });
    if (upErr) throw new Error("ファイル保存に失敗: " + upErr.message);

    const downloadName = `${REPORT_TITLE[reportKey] ?? reportKey}_${periodFrom}_${periodTo}.${ext}`;
    const { data: signed } = await sb.storage.from("export-outputs").createSignedUrl(filePath, 600, { download: downloadName });

    const fileSize = fileBuf instanceof Uint8Array ? fileBuf.byteLength : (fileBuf as ArrayBuffer).byteLength;
    await sb.from("export_history").update({
      template_id: tpl?.id ?? null,
      file_path: filePath,
      status: "completed",
      row_count: rowCount,
      file_size_bytes: fileSize,
      duration_ms: Date.now() - startedAt,
      completed_at: new Date().toISOString(),
    }).eq("id", historyId);

    return json({
      ok: true,
      export_id: historyId,
      file_path: filePath,
      signed_url: signed?.signedUrl ?? null,
      row_count: rowCount,
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
