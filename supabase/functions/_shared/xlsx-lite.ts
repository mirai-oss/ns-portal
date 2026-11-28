// xlsx の中身を、必要なシートだけ軽く読む（値だけ。書式・画像は読まない）。
//   Edge Function は計算量の上限が小さいので、ブック全体を組み立てる読み込み（ExcelJS など）は使わない。
import { strFromU8, unzipSync } from "npm:fflate@0.8.2";
import type { Cell, Sheet } from "./recruit-cost-sheet.ts";

const decode = (s: string) =>
  s.replace(/&(#x[0-9a-fA-F]+|#\d+|amp|lt|gt|quot|apos);/g, (_, e) =>
    e === "amp" ? "&" : e === "lt" ? "<" : e === "gt" ? ">" : e === "quot" ? '"' : e === "apos" ? "'" : String.fromCodePoint(e[1] === "x" ? parseInt(e.slice(2), 16) : Number(e.slice(1))));
const attr = (tag: string, name: string) => {
  const m = tag.match(new RegExp(`(?:^|\\s)${name}="([^"]*)"`));
  return m ? decode(m[1]) : null;
};
/** 文字の要素をつなげる（ふりがな rPh は除く）。 */
const textOf = (xml: string) => [...xml.replace(/<rPh\b[\s\S]*?<\/rPh>/g, "").matchAll(/<t(?:\s[^>]*)?>([\s\S]*?)<\/t>/g)].map((m) => decode(m[1])).join("");
const colIndex = (ref: string) => [...ref.replace(/\d+$/, "")].reduce((n, c) => n * 26 + (c.charCodeAt(0) - 64), 0) - 1;

function unzip(buf: Uint8Array, want: (name: string) => boolean): Record<string, string> {
  const files = unzipSync(buf, { filter: (f) => want(f.name) });
  return Object.fromEntries(Object.entries(files).map(([k, v]) => [k, strFromU8(v)]));
}

function sheetList(buf: Uint8Array): { name: string; path: string }[] {
  const f = unzip(buf, (n) => n === "xl/workbook.xml" || n === "xl/_rels/workbook.xml.rels");
  const rels = new Map<string, string>();
  for (const [tag] of (f["xl/_rels/workbook.xml.rels"] ?? "").matchAll(/<Relationship\b[^>]*>/g)) {
    const t = attr(tag, "Target") ?? "";
    rels.set(attr(tag, "Id") ?? "", t.startsWith("/") ? t.slice(1) : `xl/${t}`);
  }
  return [...(f["xl/workbook.xml"] ?? "").matchAll(/<sheet\b[^>]*>/g)]
    .map(([tag]) => ({ name: attr(tag, "name") ?? "", path: rels.get(attr(tag, "r:id") ?? "") ?? "" }))
    .filter((s) => s.path);
}

/** 条件に合う名前のシートだけを読む。maxRows 行より下は読まない。 */
export function readSheets(buf: Uint8Array, pick: (name: string) => boolean, maxRows = 500): Sheet[] {
  const list = sheetList(buf).filter((s) => pick(s.name));
  if (!list.length) return [];
  const paths = new Set(list.map((s) => s.path));
  const f = unzip(buf, (n) => n === "xl/sharedStrings.xml" || paths.has(n));
  const shared = [...(f["xl/sharedStrings.xml"] ?? "").matchAll(/<si(?:\s[^>]*)?(?:\/>|>([\s\S]*?)<\/si>)/g)].map((m) => textOf(m[1] ?? ""));
  return list.map((s) => {
    const rows: Cell[][] = [];
    for (const rm of (f[s.path] ?? "").matchAll(/<row\b([^>]*?)(?:\/>|>([\s\S]*?)<\/row>)/g)) {
      const no = Number(attr(rm[1], "r") ?? rows.length + 1);
      if (no > maxRows) break;
      const row: Cell[] = [];
      for (const cm of (rm[2] ?? "").matchAll(/<c\b([^>]*?)(?:\/>|>([\s\S]*?)<\/c>)/g)) {
        const i = colIndex(attr(cm[1], "r") ?? ""), type = attr(cm[1], "t"), body = cm[2] ?? "";
        if (i < 0 || i >= 30) continue;
        const v = body.match(/<v(?:\s[^>]*)?>([\s\S]*?)<\/v>/)?.[1];
        let val: Cell = null;
        if (type === "inlineStr") val = textOf(body);
        else if (v !== undefined) val = type === "s" ? shared[Number(v)] ?? null : type === "str" || type === "e" ? decode(v) : Number(v);
        while (row.length < i) row.push(null);
        row[i] = val;
      }
      while (rows.length < no - 1) rows.push([]);
      rows[no - 1] = row;
    }
    return { name: s.name, rows };
  });
}
