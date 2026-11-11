import { assert, assertEquals } from "jsr:@std/assert@1";
import { mentionLine, noticeControl, noticeDetail, noticeHandover, noticeHistoryLine, noticeParent, shortDate } from "./notice-blocks.ts";

Deno.test("親メッセージは 2 行: 【種別】日付｜店舗｜氏名 ／ @担当　進捗", () => {
  const p = noticeParent({ emoji: "⏰", label: "勤怠確認", date: "2026-11-02", store: "新横浜", name: "山田 太郎", status_code: "waiting", mentions: [{ slack_user_id: "U012ABCDEF" }, { slack_user_id: "U0XYZ12345" }] });
  assertEquals(p.text, "⏰【勤怠確認】11/2｜新横浜｜山田 太郎\n<@U012ABCDEF> <@U0XYZ12345>　🟡 確認待ち");
  assertEquals(p.text.split("\n").length, 2);
  assertEquals((p.blocks as any[]).length, 1, "ボタンや詳細は親に入れない");
  assertEquals(noticeParent({ emoji: "💴", label: "賃金変更", date: "2026-11-11", store: "恵比寿", name: "佐藤 花子", status_code: "waiting", status_label: "社長承認待ち", mentions: [{ slack_user_id: "U0PRESIDENT" }] }).text,
    "💴【賃金変更】11/11｜恵比寿｜佐藤 花子\n<@U0PRESIDENT>　🟡 社長承認待ち");
  assertEquals(noticeParent({ emoji: "👤", label: "入社登録", date: "2026-11-11", store: "田町", name: "山田 太郎", status_code: "doing" }).text, "👤【入社登録】11/11｜田町｜山田 太郎\n🔵 対応中");
  assertEquals(shortDate(null), "—");
});

Deno.test("メンション: 同じ人は 1 回だけ・ID の形でないものは出さない・完了のときは名前の文字にして再通知しない", () => {
  assertEquals(mentionLine([{ slack_user_id: "U012ABCDEF", name: "A" }, { slack_user_id: "U012ABCDEF", name: "A" }, { slack_user_id: "bad id", name: "B" }, { slack_user_id: null, name: "C" }], false), "<@U012ABCDEF>");
  const done = noticeParent({ label: "退職処理", date: "2026-11-30", store: "本店", name: "山田 太郎", status_code: "done", status_label: "完了（承認）", mentions: [{ slack_user_id: "U012ABCDEF", name: "本部A" }] });
  assert(!done.text.includes("<@"), "完了ではメンションしない");
  assertEquals(done.text, "【退職処理】11/30｜本店｜山田 太郎\n本部A　🟢 完了（承認）");
  assertEquals(noticeParent({ label: "勤怠確認", date: "2026-11-02", store: "じんべぇ 川崎", name: "山田 太郎", status_code: "todo", mentions: [] }).text, "【勤怠確認】11/2｜じんべぇ 川崎｜山田 太郎\n⚪ 未対応", "メンションできる人がいなくても、ほかの人は足さない");
});

Deno.test("親メッセージに区切りや改行を混ぜ込めない（氏名・店舗名に ｜ や改行やメンションの形があっても 2 行のまま）", () => {
  const p = noticeParent({ label: "入社登録", date: "2026-11-11", store: "本店｜別店", name: "山田\n<@U0HACKED11> 太郎", status_code: "alert" });
  assertEquals(p.text.split("\n").length, 2); assert(!p.text.includes("<@")); assertEquals(p.text.split("｜").length, 3);
});

Deno.test("スレッド: 詳細カード（渡した項目だけ＋管理画面へのリンク）・操作カード（ボタンはここだけ）・履歴 1 行・引き継ぎ", () => {
  const d = noticeDetail({ title: "賃金変更の申請", fields: [{ label: "適用開始日", value: "2027-01-01" }, { label: "段階", value: "本部確認待ち" }, { label: "空", value: "" }], admin_url: "https://example.com/admin" });
  assert(d.text.includes("*適用開始日*: 2027-01-01") && !d.text.includes("空") && JSON.stringify(d.blocks).includes("管理画面"));
  const c = noticeControl({ status_code: "waiting", status_label: "本部確認待ち", assignee_names: ["本部A"], unlinked_count: 2, buttons: [
    { text: "本部確認", action_id: "approval.confirm", value: "{\"case\":\"c1\"}", style: "primary" }, { text: "差し戻し", action_id: "approval.return", value: "{\"case\":\"c1\"}" }, { text: "管理画面で確認", action_id: "approval.link", value: "x", url: "https://example.com" }] });
  const el = (c.blocks as any[])[1].elements;
  assertEquals(el.map((e: any) => e.action_id), ["approval.confirm", "approval.return", "approval.link"]); assertEquals(el[0].value, "{\"case\":\"c1\"}");
  assert(JSON.stringify(c.blocks).includes("通知できていない人: 2 名"));
  assertEquals(noticeHistoryLine({ at: "2026-11-11T04:44:07Z", actor: "本部A", action: "本部確認", comment: "確認しました" }), "・11/11 13:44　本部A　本部確認「確認しました」");
  assertEquals(noticeHandover({ mentions: [{ slack_user_id: "U0PRESIDENT" }], message: "最終承認をお願いします" }), "<@U0PRESIDENT>　最終承認をお願いします");
});
