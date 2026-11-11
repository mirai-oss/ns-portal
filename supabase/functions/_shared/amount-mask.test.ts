import { assertEquals, assert } from "jsr:@std/assert@1";
import { AMOUNT_MASK as M, maskAmountsDeep, maskAmountsText, shouldMaskChannel } from "./amount-mask.ts";

Deno.test("金額だけを置き換える（日付・時刻・人数・分は残す）", () => {
  assertEquals(maskAmountsText("時給 ¥1,200（2026/11/10から・全事業所共通）"), `時給 ${M}（2026/11/10から・全事業所共通）`);
  assertEquals(maskAmountsText("片道 500円／30分／乗換1／定期1か月 12,340 円"), `片道 ${M}／30分／乗換1／定期1か月 ${M}`);
  assertEquals(maskAmountsText("上限 ¥6,000（月額）・¥11,230"), `上限 ${M}（月額）・${M}`);
  assertEquals(maskAmountsText("✅ 経路を承認（IC 片道 ¥420）"), `✅ 経路を承認（IC 片道 ${M}）`);
  assertEquals(maskAmountsText("合計所得見積額 ￥1,030,000 / 1.5万円"), `合計所得見積額 ${M} / ${M}`);
  for (const keep of ["2026年11月10日 12:48", "11/13 13:44 まで", "確認した人: 40人", "3 件・2 名", "勤務 13時間 30分", "スタッフID 380", "締め日まであと 19 日"]) assertEquals(maskAmountsText(keep), keep);
  assertEquals(maskAmountsText(""), "");
});

Deno.test("ブロックの中は、読む文字だけ。ボタンの value・action_id・url は変えない", () => {
  const value = JSON.stringify({ workflow_id: "w1", notification_id: "n1", fare: "¥500" });
  const blocks: any[] = [
    { type: "section", text: { type: "mrkdwn", text: "🚃 *交通費の確認*\n本人の申告: *片道 ¥500*\n検索の最安: *¥420*" } },
    { type: "actions", block_id: "onboarding_commute", elements: [
      { type: "button", style: "primary", text: { type: "plain_text", text: "✅ 経路を承認（IC 片道 ¥420）", emoji: true }, action_id: "hr.onboarding.commute.approve_computed", value },
      { type: "button", text: { type: "plain_text", text: "従業員ページ" }, url: "https://example.com/?fare=500円", action_id: "hr.onboarding.link.nippo" },
    ] },
    { type: "context", elements: [{ type: "mrkdwn", text: "上限 6,000円" }] },
  ];
  const out = maskAmountsDeep(blocks) as any[];
  assert(!JSON.stringify(out.map((b) => b.text ?? b.elements?.map((e: any) => e.text))).includes("¥"));
  assertEquals(out[1].elements[0].value, value);
  assertEquals(out[1].elements[0].action_id, "hr.onboarding.commute.approve_computed");
  assertEquals(out[1].elements[1].url, "https://example.com/?fare=500円");
  assertEquals(out[1].block_id, "onboarding_commute");
  assertEquals(out[1].elements[0].text.text, `✅ 経路を承認（IC 片道 ${M}）`);
  assertEquals(out[2].elements[0].text, `上限 ${M}`);
  assertEquals(blocks[0].text.text.includes("¥500"), true); // 元の配列は変えない
});

Deno.test("設定で指定したチャンネルだけ。設定が無ければ何もしない", () => {
  assertEquals(shouldMaskChannel(null, "hq.jinji"), false);
  assertEquals(shouldMaskChannel({}, "hq.jinji"), false);
  assertEquals(shouldMaskChannel({ hide_amount_channels: ["hq.jinji", "hq.juyo_shonin"] }, "hq.jinji"), true);
  assertEquals(shouldMaskChannel({ hide_amount_channels: ["hq.jinji"] }, "keiei.report"), false);
  assertEquals(shouldMaskChannel({ hide_amount_channels: ["hq.jinji"] }, "user:abc"), false);
});
