// 面接の案内文が、いまの管理システムの画面の関数（nippo/index.html の interviewText）と 1 文字も違わないこと。
//   見本（fixtures/recruit-interview-text.json）は、画面の関数をそのまま動かして作った出力（scratchpad ob18/stage2/gen_interview_fixture.mjs・日本時間）。
import { assert, assertEquals } from "jsr:@std/assert@1";
import fixture from "./fixtures/recruit-interview-text.json" with { type: "json" };
import { interviewCancelText, interviewChangeText, interviewText, type IvInput, type IvPlace } from "./recruit-interview-text.ts";

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

// ---- 2026-12-03 変更・取り消しの案内（文面は案。決まったら、ここの期待値も直す） ----
Deno.test("変更の案内（日時が変わった・オンライン）: 全文", () => {
  assertEquals(interviewChangeText({ name: "試験 太郎", interview_at: "2026-11-21T06:00:00Z", interview_mode: "online", interview_url: "https://meet.google.com/new-link" }, null, "2026-11-20T05:00:00Z"),
    "試験 太郎さん\n\n面接の日時が変更になりましたのでご連絡いたします。\n\n【変更前】11月20日(金) 14:00\n【変更後の面接日時】11月21日(土) 15:00\n【面接URL】https://meet.google.com/new-link\n\nお時間になりましたら、上のリンクからご参加ください。"
    + "\n\n以前にお送りしたご案内は、こちらの内容に読み替えてください。\nご都合が悪くなった場合は、このままご返信ください。\nお会いできるのを楽しみにしております。");
});
Deno.test("変更の案内（日時は同じで、やり方・場所・URL が変わった／対面）: 「変更前」の行は出さず、変更後の場所・住所・注意書きを書く", () => {
  const t = interviewChangeText({ name: "試験 太郎", interview_at: "2026-11-20T05:00:00Z", interview_mode: "onsite", interview_place: "テスト本店", interview_address: "東京都テスト区1-2-3" }, { name: "テスト本店", address: "東京都テスト区1-2-3", note: "入口は裏側です。" }, "2026-11-20T05:00:00+00:00");
  assertEquals(t, "試験 太郎さん\n\n面接のご案内の内容が変更になりましたのでご連絡いたします。\n\n【面接日時】11月20日(金) 14:00\n【場所】テスト本店\n【住所】東京都テスト区1-2-3\n入口は裏側です。\n\nお気をつけてお越しください。"
    + "\n\n以前にお送りしたご案内は、こちらの内容に読み替えてください。\nご都合が悪くなった場合は、このままご返信ください。\nお会いできるのを楽しみにしております。");
  assert(!t.includes("【変更前】") && !t.includes("決まりました"));
});
Deno.test("取り消しの案内: 全文", () => {
  assertEquals(interviewCancelText("試験 太郎", "2026-11-20T05:00:00Z"),
    "試験 太郎さん\n\n誠に恐れ入りますが、下記の面接は取り消し（キャンセル）となりましたのでご連絡いたします。\n\n【取り消しとなった面接】11月20日(金) 14:00\n\n以前にお送りした面接のご案内（URL・場所）は、使えなくなります。\nご不明な点があれば、このままご返信ください。");
});
