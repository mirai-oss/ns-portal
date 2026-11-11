import { assertEquals, assert } from "jsr:@std/assert@1";
import { AMOUNT_MASK as M, findAmountLeaks, hasAmountLeak, maskAmountsDeep, maskAmountsText, shouldMaskChannel } from "./amount-mask.ts";

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

Deno.test("日付・時刻・番号などの必要な数字は消さない。全角の金額は消す", () => {
  for (const keep of ["👤【入社登録】11/12｜鳥一代 本店｜テスト 太郎", "入社日 2026-12-01（月）", "適用開始日 2026/12/01", "受付 10:30／期限 11月14日 18:00", "従業員番号 00123・スタッフID 4567", "電話 090-1234-5678",
    "勤務 9:00〜22:30（13時間 30分）", "対象 3 人・確認待ち 12件・2回目", "賃金設定済み（11/12 10:30）", "交通費確認待ち｜申請日 2026年11月12日", "定期1か月・乗換2回・所要45分", "〒105-0004", "✅ 賃金をスマレジに反映しました　スマレジ賃金設定ID 890", "賃金の申請番号 12345・交通費の受付No 678"]) {
    assertEquals(maskAmountsText(keep), keep, keep);
    assertEquals(hasAmountLeak(keep), false, "消し残りと見なさない: " + keep);
  }
  assertEquals(maskAmountsText("時給 １，２００円／片道 ￥４２０"), `時給 ${M}／片道 ${M}`);
});

Deno.test("消し残りの検査: 単位の無い金額・飾りで分断された金額・◯万 を見つける（場所だけ返す。金額は返さない）", () => {
  for (const bad of ["時給 1200（全事業所共通）", "賃金: 1,250 → 1,300", "交通費（片道 420／往復 840）", "定期 12,340／月", "月給 25万", "上限 *6,000* 円", "*¥*1,200", "支給額　185000", '・勤務日数ごと／事業所別／{"bee9f74a-2079":500}／上限なし', "*時給*\n1200"]) {
    assertEquals(hasAmountLeak(maskAmountsText(bad)), true, "見つける: " + bad);
  }
  // ふつうに消せるものは、消したあと残らない
  for (const ok of ["時給 ¥1,200（2026/11/10から）", "片道 500円／30分／定期1か月 12,340 円", "上限 ¥6,000（月額）", "月給 250,000円・1.5万円"]) assertEquals(hasAmountLeak(maskAmountsText(ok)), false, ok);
  const blocks = [
    { type: "section", text: { type: "mrkdwn", text: "👤 *入社登録*｜2026/11/12｜鳥一代 本店" } },
    { type: "section", fields: [{ type: "mrkdwn", text: "*状況*\n賃金設定済み" }, { type: "mrkdwn", text: "*時給*\n1200" }] },
    { type: "actions", elements: [{ type: "button", text: { type: "plain_text", text: "💴 賃金を設定" }, action_id: "hr.onboarding.wage.open", value: JSON.stringify({ wage: 1200, note: "時給 1200" }) }] },
  ];
  assertEquals(findAmountLeaks("入社登録 2026/11/12", blocks), ["blocks[1].fields[1].text"]);   // ボタンの value は見ない（画面に出ない）
  assertEquals(findAmountLeaks("時給 1200", null), ["text"]);
  assertEquals(findAmountLeaks("👤【入社登録】11/12｜鳥一代 本店｜テスト 太郎\n@担当　⚪ 未対応", [blocks[0], blocks[2]]), []);
});
