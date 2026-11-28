import { assertEquals } from "jsr:@std/assert@1";
import { strToU8, zipSync } from "npm:fflate@0.8.2";
import { readSheets } from "./xlsx-lite.ts";

const book = zipSync({
  "xl/workbook.xml": strToU8('<workbook><sheets><sheet name="20301" sheetId="1" r:id="rId1"/><sheet name="メモ" sheetId="2" r:id="rId2"/></sheets></workbook>'),
  "xl/_rels/workbook.xml.rels": strToU8('<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/><Relationship Target="/xl/worksheets/sheet2.xml" Id="rId2"/></Relationships>'),
  "xl/sharedStrings.xml": strToU8('<sst><si><t>費用</t><rPh sb="0" eb="2"><t>ヒヨウ</t></rPh></si><si><r><t>鳥</t></r><r><t xml:space="preserve">一代 &amp; 店</t></r></si></sst>'),
  "xl/worksheets/sheet1.xml": strToU8('<worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="C1" t="s"><v>1</v></c></row><row r="3" spans="1:3"><c r="A3" s="2"/><c r="B3"><v>1234</v></c><c r="C3" t="inlineStr"><is><t>直接</t></is></c><c r="D3" t="str"><f>A1</f><v>式</v></c></row><row r="900"><c r="A900"><v>1</v></c></row></sheetData></worksheet>'),
  "xl/worksheets/sheet2.xml": strToU8("<worksheet><sheetData/></worksheet>"),
});

Deno.test("選んだシートだけを読む: 共有の文字（ふりがなは除く）・数・直接の文字・式の結果・空の行・読む行の上限", () => {
  const s = readSheets(book, (n) => n === "20301");
  assertEquals(s.length, 1);
  assertEquals(s[0].rows, [["費用", null, "鳥一代 & 店"], [], [null, 1234, "直接", "式"]]);
  assertEquals(readSheets(book, (n) => n === "ない"), []);
  assertEquals(readSheets(book, () => true).map((x) => x.name), ["20301", "メモ"]);
});
