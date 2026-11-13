// 面接の案内文が、いまの管理システムの画面の関数（nippo/index.html の interviewText）と 1 文字も違わないこと。
//   見本（fixtures/recruit-interview-text.json）は、画面の関数をそのまま動かして作った出力（scratchpad ob18/stage2/gen_interview_fixture.mjs・日本時間）。
import { assert, assertEquals } from "jsr:@std/assert@1";
import fixture from "./fixtures/recruit-interview-text.json" with { type: "json" };
import { interviewText, type IvInput, type IvPlace } from "./recruit-interview-text.ts";

const places = fixture.places as IvPlace[];
const placeOf = (name: unknown) => places.find((p) => p.name === name) ?? null;   // 画面の ivPlaceOf と同じ

Deno.test("面接の案内文: 画面の関数の出力（見本）と、全部の見本で完全に一致する", () => {
  assert(fixture.cases.length >= 20);
  for (const c of fixture.cases) {
    const input = c.input as unknown as IvInput;
    assertEquals(interviewText(input, placeOf(input.interview_place)), c.expected, JSON.stringify(c.input));
  }
});

Deno.test("面接の案内文: 見本に、オンライン・対面・URL なし・場所の注意書き・曜日 7 つ・日付をまたぐ時刻が入っている", () => {
  const all = fixture.cases.map((c) => c.expected);
  assert(all.some((t) => t.includes("【面接URL】")) && all.some((t) => t.includes("【場所】") && t.includes("【住所】") && t.includes("入口は建物の裏側です。")));
  assert(all.some((t) => !t.includes("【面接URL】") && !t.includes("【場所】")));
  for (const w of "日月火水木金土") assert(all.some((t) => t.includes(`(${w}) `)), w);
  assert(all.some((t) => t.includes("【面接日時】1月1日(金) 00:00")) && all.some((t) => t.includes(" 23:59")));
});

Deno.test("面接の案内文: サーバーの時刻設定に関係なく、日本時間で書く", () => {
  const t = interviewText({ name: "試験 太郎", interview_at: "2026-11-20T15:30:00Z", interview_mode: "online", interview_url: "https://meet.example/x" }, null);
  assert(t.includes("【面接日時】11月21日(土) 00:30"));
});
