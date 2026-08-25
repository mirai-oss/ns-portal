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
const REPORT_TITLE: Record<string, string> = { pl_monthly: "月次PL", pl_annual_trend: "年間推移PL", ad_media: "媒体別広告実績" };
const PL_REPORT_KEYS = ["pl_monthly", "pl_annual_trend"];
const AD_REPORT_KEYS = ["ad_media"];

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

// ---------------- 広告媒体データ取得（2026-08-25追加・同日ユーザー要望でサブブランド分離／媒体名手動マッピング対応） ----------------
// 媒体名の正規化: tori-dashboard/app.js の canonMedia()（3196行目）と同じロジックをそのまま移植。
// 広告DB（費用）とstg_media（売上）で表記が違っても自動で突合できるようにする（例: 鶏HP・黒HP→ホットペッパー）。
// aliasMapが与えられればハードコードのルールより優先する（tpl_media_aliasテーブル・管理者が自己登録できる）。
function canonMedia(m: unknown, aliasMap?: Map<string, string>): string {
  const s = String(m ?? "").trim();
  if (!s) return "";
  if (aliasMap) {
    const hit = aliasMap.get(s.toUpperCase());
    if (hit) return hit;
  }
  const u = s.toUpperCase();
  if (u.indexOf("RETTY") >= 0 || /RT$/.test(u)) return "Retty";
  if (u.indexOf("ホットペッパー") >= 0 || u.indexOf("HP") >= 0) return "ホットペッパー";
  if (u.indexOf("ぐるなび") >= 0 || u.indexOf("GN") >= 0) return "ぐるなび";
  if (u.indexOf("食べログ") >= 0 || u.indexOf("TL") >= 0) return "食べログ";
  if (u.indexOf("LP") >= 0) return "自社LP";
  if (u.indexOf("インスタ") >= 0 || u.indexOf("INSTAGRAM") >= 0) return "Instagram";
  if (u.indexOf("GOOGLE") >= 0 || u.indexOf("グーグル") >= 0 || u.indexOf("マップ") >= 0) return "Google";
  return s;
}

async function fetchMediaAliasMap(sb: any): Promise<Map<string, string>> {
  const { data } = await sb.from("tpl_media_alias").select("raw_media,canonical_media");
  const map = new Map<string, string>();
  (data ?? []).forEach((r: any) => map.set(String(r.raw_media).trim().toUpperCase(), String(r.canonical_media).trim()));
  return map;
}

// 広告費（広告DBシート。BQ未収容のためGASの汎用action:'data'で取得）。
// tori-dashboard/app.js の ingestAd()（470行目）と同じヘッダー自動検出ロジックを移植
// （タイトル行が上にあってもズレないよう先頭12行から見出し行を探す）。
// media は生の表記のまま返す（canonMedia適用はaliasMap確定後に呼び出し側で行う）。
type AdCostRow = { ym: string; storeName: string; media: string; cost: number };

function colIndexOf(header: string[], name: string): number {
  return header.findIndex((h) => String(h ?? "").indexOf(name) >= 0);
}
async function fetchAdCostRows(token: string): Promise<AdCostRow[]> {
  const res = await dashCall({ action: "data", token, keys: "広告" });
  if (!res.ok) throw new Error("広告DB取得に失敗: " + (res.error ?? ""));
  const rows: any[][] = res.sheets?.["広告"] ?? [];
  if (!rows.length) return [];
  let hi = -1;
  for (let i = 0; i < Math.min(rows.length, 12); i++) {
    const line = rows[i].map((x) => String(x ?? "")).join(",");
    if (/広告費|広告|費用|金額/.test(line) && /年月|日付|店舗/.test(line)) { hi = i; break; }
  }
  if (hi < 0) hi = 0;
  const header = rows[hi].map((h) => String(h ?? "").trim());
  const iD = colIndexOf(header, "日付") >= 0 ? colIndexOf(header, "日付") : colIndexOf(header, "年月");
  const iS = colIndexOf(header, "店舗");
  const iM = colIndexOf(header, "媒体");
  let iC = colIndexOf(header, "広告費");
  if (iC < 0) iC = colIndexOf(header, "広告");
  if (iC < 0) iC = colIndexOf(header, "費用");
  if (iC < 0) iC = colIndexOf(header, "金額");
  if (iD < 0 || iC < 0) return []; // 列が見つからない＝広告DB未設定（app.js側と同じ扱い）
  const out: AdCostRow[] = [];
  for (let i = hi + 1; i < rows.length; i++) {
    const r = rows[i];
    const ym = normalizeYm(r[iD]);
    if (!ym) continue;
    const cost = Number(r[iC] ?? 0);
    if (!cost) continue;
    out.push({
      ym,
      storeName: String(iS >= 0 ? r[iS] ?? "" : "").trim(),
      media: String(iM >= 0 ? r[iM] ?? "" : "").trim(),
      cost,
    });
  }
  return out;
}

// 媒体別売上（BigQuery stg_media・bqGetMedia）。既存アクション・変更なし。media は生の表記のまま返す。
type AdSalesRow = { ym: string; storeName: string; media: string; guests: number; parties: number; netSales: number };
async function fetchMediaSales(token: string): Promise<AdSalesRow[]> {
  const res = await dashCall({ action: "bqGetMedia", token });
  if (!res.ok) throw new Error("bqGetMedia取得に失敗: " + (res.error ?? ""));
  const rows: any[] = (res.sheets?.media ?? []).slice(1); // header: 店舗名,営業日,媒体名,客数,客組数,純売上
  const out: AdSalesRow[] = [];
  for (const r of rows) {
    const ym = normalizeYm(r[1]);
    if (!ym) continue;
    out.push({
      ym,
      storeName: String(r[0] ?? "").trim(),
      media: String(r[2] ?? "").trim(),
      guests: Number(r[3] ?? 0),
      parties: Number(r[4] ?? 0),
      netSales: Number(r[5] ?? 0),
    });
  }
  return out;
}

type AdMediaRow = { media: string; cost: number; sales: number; guests: number; parties: number };
type AdBrandBlock = { brand: string; rows: AdMediaRow[] };

// 対象期間・対象店舗（複数選択可）に絞った上で、ブランド（本体／サブブランド）×媒体ごとに
// 費用・売上・客数・客組数を合算する。scopeStoreNames=null は「選択店舗すべて合算」を意味する
// （その場合はブランド区別をせず単一ブロックにまとめる＝合算シートは店舗横断の全体像を見る用途のため）。
function buildAdMediaRows(costRows: (AdCostRow & { brand: string })[], salesRows: (AdSalesRow & { brand: string })[], scopeStoreNames: Set<string> | null): AdBrandBlock[] {
  const cScoped = scopeStoreNames ? costRows.filter((r) => scopeStoreNames.has(r.storeName)) : costRows;
  const sScoped = scopeStoreNames ? salesRows.filter((r) => scopeStoreNames.has(r.storeName)) : salesRows;
  const brandKey = (b: string) => (scopeStoreNames ? b : "__all__");
  const blocks = new Map<string, Map<string, AdMediaRow>>();
  const get = (brand: string, media: string) => {
    const bKey = brandKey(brand);
    if (!blocks.has(bKey)) blocks.set(bKey, new Map());
    const m = blocks.get(bKey)!;
    const key = media || "（媒体未設定）";
    if (!m.has(key)) m.set(key, { media: key, cost: 0, sales: 0, guests: 0, parties: 0 });
    return m.get(key)!;
  };
  for (const c of cScoped) get(c.brand, c.media).cost += c.cost;
  for (const s of sScoped) { const r = get(s.brand, s.media); r.sales += s.netSales; r.guests += s.guests; r.parties += s.parties; }
  // ブロック順: ブランド名でソート（本体を先に出したいので費用+売上合計の降順）
  const brandTotal = new Map<string, number>();
  for (const [b, m] of blocks) brandTotal.set(b, [...m.values()].reduce((s, r) => s + r.cost + r.sales, 0));
  return [...blocks.entries()]
    .sort((a, b) => (brandTotal.get(b[0]) ?? 0) - (brandTotal.get(a[0]) ?? 0))
    .map(([brand, m]) => ({
      brand: scopeStoreNames ? brand : "",
      rows: [...m.values()].sort((a, b) => b.cost - a.cost || b.sales - a.sales),
    }));
}

// ---------------- CSV（広告媒体別） ----------------
function buildCsvAdMedia(costRows: (AdCostRow & { brand: string })[], salesRows: (AdSalesRow & { brand: string })[], storeNamesInOrder: string[]): Uint8Array {
  const headers = ["対象店舗", "年月", "店舗名", "ブランド", "媒体", "区分", "金額/件数"];
  const lines = [headers.map(csvEscape).join(",")];
  const scopeLabel = storeNamesInOrder.length > 1 ? "個別" : storeNamesInOrder[0] ?? "";
  for (const c of costRows) lines.push([scopeLabel, c.ym, c.storeName, c.brand, c.media, "広告費", c.cost].map(csvEscape).join(","));
  for (const s of salesRows) {
    lines.push([scopeLabel, s.ym, s.storeName, s.brand, s.media, "売上", s.netSales].map(csvEscape).join(","));
    lines.push([scopeLabel, s.ym, s.storeName, s.brand, s.media, "客数", s.guests].map(csvEscape).join(","));
    lines.push([scopeLabel, s.ym, s.storeName, s.brand, s.media, "客組数", s.parties].map(csvEscape).join(","));
  }
  const text = lines.join("\r\n");
  const bom = new Uint8Array([0xef, 0xbb, 0xbf]);
  const body = new TextEncoder().encode(text);
  const out = new Uint8Array(bom.length + body.length);
  out.set(bom); out.set(body, bom.length);
  return out;
}

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

// 媒体別広告実績シート（PLより単純な「媒体×指標」の一覧表。テンプレートファイルは未登録のため
// 既定書式で出力されるが、後日export-templatesでテンプレートをアップロードすればloadStyleProfile()が
// 自動的にそのデザインを読みに行く＝コード変更なしでテンプレート方式に切り替わる設計）
// blocks.length>1（サブブランドあり）の場合はブランドごとに見出し行を挟んで区切って表示する
// （2026-08-25ユーザー要望: メインブランドとサブブランドの費用対効果を分けて見たい）。
function writeAdSheet(wb: any, sheetName: string, title: string, style: StyleProfile, blocks: AdBrandBlock[]) {
  const sheet = wb.addWorksheet(sheetName.slice(0, 31));
  sheet.getCell("A1").value = title;
  sheet.getCell("A1").font = style.titleFont;
  sheet.getColumn(1).width = style.labelColWidth;

  const headers = ["媒体", "広告費", "売上", "客数", "客組数", "ROAS"];
  const showBrandHeading = blocks.length > 1;
  let r = 3;

  for (const block of blocks) {
    if (showBrandHeading) {
      sheet.getCell(r, 1).value = `▼ ${block.brand}`;
      sheet.getCell(r, 1).font = { bold: true, italic: true };
      r++;
    }
    const headerRowIdx = r;
    headers.forEach((h, i) => {
      const c = sheet.getCell(headerRowIdx, i + 1);
      c.value = h; c.font = style.headerFont; c.fill = style.headerFill; c.border = style.dataBorder;
      sheet.getColumn(i + 1).width = i === 0 ? style.labelColWidth : style.valueColWidth;
    });
    r++;
    const dataStartRow = r;
    block.rows.forEach((row) => {
      const rowIdx = r;
      sheet.getCell(rowIdx, 1).value = row.media;
      sheet.getCell(rowIdx, 2).value = row.cost;
      sheet.getCell(rowIdx, 3).value = row.sales;
      sheet.getCell(rowIdx, 4).value = row.guests;
      sheet.getCell(rowIdx, 5).value = row.parties;
      const c2 = colLetter(sheet, rowIdx, 2), c3 = colLetter(sheet, rowIdx, 3);
      sheet.getCell(rowIdx, 6).value = { formula: `IF(${c2}${rowIdx}=0,"—",${c3}${rowIdx}/${c2}${rowIdx})` };
      for (let c = 1; c <= 6; c++) {
        const cell = sheet.getCell(rowIdx, c);
        cell.border = style.dataBorder;
        if (c >= 2 && c <= 5) cell.numFmt = style.numFmt;
        if (c === 6) cell.numFmt = "0%;;\"—\"";
      }
      r++;
    });
    const totalRowIdx = r;
    sheet.getCell(totalRowIdx, 1).value = "小計";
    sheet.getCell(totalRowIdx, 1).font = style.totalFont;
    for (let c = 2; c <= 5; c++) {
      const colL = colLetter(sheet, dataStartRow, c);
      const cell = sheet.getCell(totalRowIdx, c);
      cell.value = block.rows.length ? { formula: `SUM(${colL}${dataStartRow}:${colL}${totalRowIdx - 1})` } : 0;
      cell.numFmt = style.numFmt; cell.font = style.totalFont; cell.border = style.totalBorder;
    }
    const c2t = colLetter(sheet, totalRowIdx, 2), c3t = colLetter(sheet, totalRowIdx, 3);
    const roasCell = sheet.getCell(totalRowIdx, 6);
    roasCell.value = { formula: `IF(${c2t}${totalRowIdx}=0,"—",${c3t}${totalRowIdx}/${c2t}${totalRowIdx})` };
    roasCell.numFmt = "0%;;\"—\""; roasCell.font = style.totalFont; roasCell.border = style.totalBorder;
    sheet.getCell(totalRowIdx, 1).border = style.totalBorder;
    r += 2; // ブロック間の空行
  }

  sheet.views = [{ state: "frozen", ySplit: 3, xSplit: 1 }];
}

async function buildAdExcel(
  sb: any, reportKey: string, layout: any,
  costRows: (AdCostRow & { brand: string })[], salesRows: (AdSalesRow & { brand: string })[],
  storeNamesInOrder: string[], periodFrom: string, periodTo: string,
): Promise<ArrayBuffer> {
  const style = await loadStyleProfile(sb, reportKey, layout);
  const wb = new ExcelJS.Workbook();
  wb.creator = "N-Style データ出力センター";
  wb.created = new Date();
  const title = REPORT_TITLE[reportKey] ?? "広告実績";

  if (storeNamesInOrder.length > 1) {
    const combined = buildAdMediaRows(costRows, salesRows, null);
    writeAdSheet(wb, "合計", `${title} 合計（${periodFrom}〜${periodTo}）`, style, combined);
  }
  for (const name of storeNamesInOrder) {
    const scoped = buildAdMediaRows(costRows, salesRows, new Set([name]));
    writeAdSheet(wb, name, `${title} ${name}（${periodFrom}〜${periodTo}）`, style, scoped);
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
    if (![...PL_REPORT_KEYS, ...AD_REPORT_KEYS].includes(reportKey)) {
      return json({ ok: false, error: `report_keyは${[...PL_REPORT_KEYS, ...AD_REPORT_KEYS].join("/")}のいずれかです` }, 400);
    }
    const isAd = AD_REPORT_KEYS.includes(reportKey);
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
    const canonicalByStoreId = new Map<string, string>();
    (storeRows ?? []).forEach((s: any) => {
      const n = String(s.dash_store_name || s.name).trim();
      canonicalByStoreId.set(s.id, n);
      if (!targetNames.has(n)) { targetNames.add(n); storeNamesInOrder.push(n); }
    });
    if (targetNames.size === 0) return json({ ok: false, error: "店舗名を解決できませんでした" }, 500);

    // 広告DB（媒体別広告実績）は店舗名がサブブランド表記（例:「匠味（新横浜）」）のことがあり、
    // stores.name/dash_store_nameと直接一致しない。store_aliasesで正規化して解決する
    // （2026-08-25実機調査で判明。tori-dashboard/app.jsのresolveStoreEx()相当の簡易版）。
    // 2026-08-25追記（同日ユーザー要望）: store_aliases.source='2枚看板'のものは「別ブランドとして
    // 費用対効果を分けて見たい」対象なので、正準名へ丸めつつも brandLabel は元のブランド名を保持する。
    const normalizeStoreName = (s: string) => s.trim().replace(/[\s()（）]/g, "");
    const normToCanonical = new Map<string, string>();
    const normToBrandLabel = new Map<string, string>(); // 2枚看板のみ登録（サブブランドの表示名）
    (storeRows ?? []).forEach((s: any) => {
      const canon = canonicalByStoreId.get(s.id)!;
      normToCanonical.set(normalizeStoreName(canon), canon);
      normToCanonical.set(normalizeStoreName(String(s.name)), canon);
    });
    if (isAd) {
      const { data: aliasRows } = await sb.from("store_aliases").select("alias,store_id,source").in("store_id", targetIds);
      (aliasRows ?? []).forEach((a: any) => {
        const canon = canonicalByStoreId.get(a.store_id);
        if (!canon) return;
        const norm = normalizeStoreName(String(a.alias));
        normToCanonical.set(norm, canon);
        if (String(a.source) === "2枚看板") normToBrandLabel.set(norm, String(a.alias).trim());
      });
    }
    function resolveAdStore(raw: string): { canonicalName: string; brandLabel: string } | null {
      const direct = String(raw ?? "").trim();
      const norm = normalizeStoreName(direct);
      if (targetNames.has(direct)) return { canonicalName: direct, brandLabel: direct };
      const canon = normToCanonical.get(norm);
      if (!canon) return null;
      return { canonicalName: canon, brandLabel: normToBrandLabel.get(norm) ?? canon };
    }

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

    const { data: tpl } = await sb.from("tpl_templates").select("id,layout").eq("template_code", reportKey).maybeSingle();
    const layout = tpl?.layout ?? { header_row: 3, data_start_row: 4, label_col: 1, value_start_col: 2 };

    let fileBuf: Uint8Array | ArrayBuffer;
    let ext: string; let contentType: string;
    let rowCount: number;

    if (isAd) {
      const [allCostRows, allSalesRows, mediaAliasMap] = await Promise.all([
        fetchAdCostRows(login.token!), fetchMediaSales(login.token!), fetchMediaAliasMap(sb),
      ]);
      // 広告DBの店舗名（サブブランド表記あり）をresolveAdStore()で正規化してから対象期間・対象店舗に絞る。
      // 媒体名はtpl_media_aliasの手動登録を優先しつつcanonMedia()で正規化する。
      const costMatched = allCostRows
        .map((r) => {
          const resolved = resolveAdStore(r.storeName);
          return { ...r, storeName: resolved?.canonicalName ?? "", brand: resolved?.brandLabel ?? "", media: canonMedia(r.media, mediaAliasMap) };
        })
        .filter((r) => r.ym >= periodFrom && r.ym <= periodTo && targetNames.has(r.storeName));
      const salesMatched = allSalesRows
        .map((r) => {
          const resolved = resolveAdStore(r.storeName);
          return { ...r, storeName: resolved?.canonicalName ?? "", brand: resolved?.brandLabel ?? "", media: canonMedia(r.media, mediaAliasMap) };
        })
        .filter((r) => r.ym >= periodFrom && r.ym <= periodTo && targetNames.has(r.storeName));

      if (costMatched.length === 0 && salesMatched.length === 0) {
        await sb.from("export_history").update({
          status: "failed", error_message: "対象条件に一致するデータがありません", completed_at: new Date().toISOString(),
        }).eq("id", historyId);
        return json({ ok: false, error: "対象条件に一致するデータがありません（広告DB未設定、またはBQミラー未反映の可能性）" }, 200);
      }
      rowCount = costMatched.length + salesMatched.length;
      if (format === "excel") {
        fileBuf = await buildAdExcel(sb, reportKey, layout, costMatched, salesMatched, storeNamesInOrder, periodFrom, periodTo);
        ext = "xlsx"; contentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
      } else {
        fileBuf = buildCsvAdMedia(costMatched, salesMatched, storeNamesInOrder);
        ext = "csv"; contentType = "text/csv";
      }
    } else {
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
      rowCount = plMatched.length + dailyMatched.length * 3; // 売上高・原価・人件費の3行/月店舗 相当
      if (format === "excel") {
        fileBuf = await buildExcel(sb, reportKey, layout, dailyMatched, plMatched, plCompanyWide, storeNamesInOrder, periodFrom, periodTo);
        ext = "xlsx"; contentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
      } else {
        fileBuf = buildCsv(dailyMatched, [...plMatched, ...plCompanyWide]);
        ext = "csv"; contentType = "text/csv";
      }
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
