// 採用: LINE 未連携の Indeed 応募者へ、合言葉入りの「LINE の案内文」を作って見せる（2026-11-20・待ち行列 9 番の案 C）。
//   ここは文面と窓を作るだけ。応募者へは何も送らない（担当者がコピーして、Indeed の画面で送る）。
//   見せるのは、ボタンを押した本人の窓だけ（権限は既存の can_see_applicant）。電話・メールは使わない
import { clean } from "./recruit-notice.ts";
import type { RecruitDeps, RecruitOutcome } from "./recruit-actions.ts";

export type InviteInfo = { ok: boolean; code?: string; message?: string; name?: string; linked?: boolean; line_code?: string | null; oa?: string | null; indeed_url?: string | null };

const plain = (text: string) => ({ type: "plain_text", text, emoji: true });
const isUuid = (s: unknown): s is string => typeof s === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s);

/** 1 タップで「文字が入った状態の LINE」が開くリンク（応募フォームの完了画面と同じ作り） */
export function lineLink(oa: string, code: string): string {
  return `https://line.me/R/oaMessage/${encodeURIComponent(oa)}/?${encodeURIComponent(code)}`;
}

/** Indeed のメッセージに貼り付ける案内文 */
export function inviteText(o: { name: string; oa: string; code: string }): string {
  const nm = clean(o.name, 30);
  return [
    ...(nm ? [`${nm} 様`, ""] : []),
    "ご応募ありがとうございます。",
    "面接のご連絡は LINE で行っております。",
    "お手数ですが、下のリンクを押すと LINE が開きます。文字が入った状態になりますので、そのまま送信してください。",
    "",
    lineLink(o.oa, o.code),
    "",
    `リンクが開けない場合は、公式 LINE（${o.oa}）に、次の合言葉を送ってください。`,
    `合言葉：${o.code}`,
    "",
    "ご不明な点があれば、このメッセージにご返信ください。",
  ].join("\n");
}

/** 案内文の窓（見るだけ。送信ボタンは無い）。コードブロックは、右上のコピーで 1 回でコピーできる */
export function inviteModal(o: { name: string; text: string; indeedUrl?: string | null }): Record<string, unknown> {
  const fence = "```";
  const blocks: unknown[] = [
    { type: "section", text: { type: "mrkdwn", text: `*${clean(o.name, 30)} さん* へ送る、LINE の案内文です。下の枠をコピーして、Indeed のメッセージに貼り付けて送ってください。` } },
    { type: "section", text: { type: "mrkdwn", text: fence + o.text.split(fence).join("'''") + fence } },
    { type: "context", elements: [{ type: "mrkdwn", text: "この画面から応募者へは送られません（送るのは、Indeed の画面です）。送ったあとは、本人が LINE に送ると自動でつながります。" }] },
  ];
  if (o.indeedUrl && /^https:\/\//.test(o.indeedUrl)) blocks.push({ type: "actions", elements: [{ type: "button", text: plain("Indeed のページを開く"), url: o.indeedUrl, action_id: "recruit.invite.indeed" }] });
  return { type: "modal", title: plain("LINE 案内文"), close: plain("閉じる"), blocks };
}

/** ［LINE 案内文］を押したとき: 権限は inviteInfo（can_see_applicant）が確かめる。連携済み・合言葉なしは理由を返す */
export async function inviteOpen(deps: RecruitDeps, value: { applicant_id?: unknown }): Promise<RecruitOutcome> {
  const id = value?.applicant_id;
  if (!isUuid(id)) return { kind: "ephemeral", text: "応募者の番号が読めませんでした。カードを更新してから、もう一度押してください。" };
  if (!deps.inviteInfo) return { kind: "ephemeral", text: "この操作は、いまは使えません。管理画面から操作してください。" };
  const r = await deps.inviteInfo(id);
  if (!r?.ok) return { kind: "ephemeral", text: r?.code === "denied" ? "この応募者の案内は、あなたの権限では見られません。" : String(r?.message ?? "案内文を作れませんでした") };
  if (r.linked) return { kind: "ephemeral", text: "この応募者は、すでに LINE とつながっています。案内は要りません。" };
  if (!r.line_code) return { kind: "ephemeral", text: "合言葉がまだ発行されていません。管理画面の応募者ページで「合言葉を発行する」を押してください。" };
  if (!r.oa) return { kind: "ephemeral", text: "求人用 LINE の設定（公式アカウントの ID）が見つかりません。管理画面の設定で確認してください。" };
  return { kind: "modal", view: inviteModal({ name: String(r.name ?? ""), text: inviteText({ name: String(r.name ?? ""), oa: r.oa, code: r.line_code }), indeedUrl: r.indeed_url ?? null }) };
}
