import { assert, assertEquals } from "jsr:@std/assert@1";
import { inviteModal, inviteOpen, inviteText, lineLink } from "./recruit-invite.ts";

const ID = "11111111-1111-4111-8111-111111111111";
const ok = { ok: true, name: "山田 太郎", linked: false, line_code: "AB12CD", oa: "@abc123", indeed_url: "https://employers.indeed.com/candidates/view?id=1" };

Deno.test("リンクは公式 LINE の ID と合言葉から作る（応募フォームの完了画面と同じ形）", () => {
  assertEquals(lineLink("@abc123", "AB12CD"), "https://line.me/R/oaMessage/%40abc123/?AB12CD");
});
Deno.test("案内文: 氏名・リンク・合言葉・公式 LINE を含み、電話やメールは含まない", () => {
  const t = inviteText({ name: "山田 太郎", oa: "@abc123", code: "AB12CD" });
  assert(t.startsWith("山田 太郎 様") && t.includes("https://line.me/R/oaMessage/%40abc123/?AB12CD") && t.includes("合言葉：AB12CD") && t.includes("（@abc123）"));
  assert(inviteText({ name: "", oa: "@a", code: "X" }).startsWith("ご応募"));
});
Deno.test("窓: コピー用の枠（コードブロック）・送信ボタンなし・Indeed のページのボタン（https のときだけ）", () => {
  const v: any = inviteModal({ name: "山田 太郎", text: "本文```あ", indeedUrl: "https://employers.indeed.com/x" });
  assertEquals(v.submit, undefined);
  const code = v.blocks[1].text.text as string;
  assert(code.startsWith("```") && code.endsWith("```") && !code.slice(3, -3).includes("```"));
  assertEquals(v.blocks.at(-1).elements[0].url, "https://employers.indeed.com/x");
  assert(!JSON.stringify(inviteModal({ name: "a", text: "b", indeedUrl: "http://x" })).includes("Indeed のページ"));
});
Deno.test("押したとき: 権限なし・連携済み・合言葉なし・設定なしは窓を出さない／そろえば窓", async () => {
  const deps = (r: unknown) => ({ inviteInfo: async () => r }) as any;
  assertEquals((await inviteOpen(deps(ok), { applicant_id: "bad" })).kind, "ephemeral");
  assertEquals((await inviteOpen(deps({ ok: false, code: "denied" }), { applicant_id: ID })).kind, "ephemeral");
  assertEquals((await inviteOpen(deps({ ...ok, linked: true }), { applicant_id: ID })).kind, "ephemeral");
  assertEquals((await inviteOpen(deps({ ...ok, line_code: null }), { applicant_id: ID })).kind, "ephemeral");
  assertEquals((await inviteOpen(deps({ ...ok, oa: null }), { applicant_id: ID })).kind, "ephemeral");
  assertEquals((await inviteOpen({} as any, { applicant_id: ID })).kind, "ephemeral");
  assertEquals((await inviteOpen(deps(ok), { applicant_id: ID })).kind, "modal");
});

Deno.test("案内文: 専用フォームのリンクがあれば「LINE の登録」と「応募フォーム」の 2 つの案内になる。無ければ LINE だけ", () => {
  const f = "https://mirai-oss.github.io/nippo/?apply=al&p=" + "a".repeat(64);
  const t = inviteText({ name: "山田 太郎", oa: "@abc123", code: "AB12CD", formUrl: f });
  assert(t.includes("① LINE の登録") && t.includes("② 応募フォームのご入力") && t.includes(f) && t.includes("%40abc123/?AB12CD") && t.includes("合言葉：AB12CD"));
  const only = inviteText({ name: "山田 太郎", oa: "@abc123", code: "AB12CD" });
  assert(!only.includes("②") && only.includes("%40abc123/?AB12CD"));
});
