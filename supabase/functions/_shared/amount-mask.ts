// =============================================================
// 金額の表示を止める（2026-11-12）: 賃金額・交通費額などを Slack の親メッセージ・スレッドに出さない
//   方針（ユーザー確定 2026-11-11）: 金額は権限つきの管理画面で確認する。Slack には処理状況だけ。
//   notify-slack（Slack への唯一の出口）が、設定で指定されたチャンネルあての送信・更新にだけ適用する。
//   ボタンの value・action_id・url などは変えない（操作はそのまま動く）。日付・時刻・人数・分数は消さない。
// =============================================================
export const AMOUNT_MASK = "（金額は管理画面で確認）";

// ¥1,200 ／ ￥500 ／ 1,200円 ／ 500 円 ／ 6000円 ／ 1.5万円 を対象にする。「2026年」「11/10」「30分」「3件」「2 名」は対象外
const RE_YEN_PREFIX = /[¥￥]\s?\d[\d,]*(?:\.\d+)?(?:\s?[万千]?円)?/g;
const RE_YEN_SUFFIX = /\d[\d,]*(?:\.\d+)?\s?[万千]?円/g;

/** 文字列の中の金額を置き換える。同じ文で続けて出たときは 1 つにまとめる */
export function maskAmountsText(s: string): string {
  if (!s) return s;
  let out = s.replace(RE_YEN_PREFIX, AMOUNT_MASK).replace(RE_YEN_SUFFIX, AMOUNT_MASK);
  // 「*（金額…）*」のような飾りの残りと、連続を整える
  out = out.split(AMOUNT_MASK + AMOUNT_MASK).join(AMOUNT_MASK);
  return out;
}

// Slack のブロックのうち、人が読む文字が入る場所だけを書き換える（value・action_id・url・block_id・private_metadata・initial_* は触らない）
const TEXT_KEYS = new Set(["text", "alt_text", "title", "description", "label", "placeholder", "hint"]);
const SKIP_KEYS = new Set(["value", "action_id", "block_id", "url", "private_metadata", "callback_id", "type", "style", "image_url", "initial_value", "initial_option", "initial_date", "selected_option", "emoji"]);

export function maskAmountsDeep<T>(node: T): T {
  if (Array.isArray(node)) return node.map((x) => maskAmountsDeep(x)) as unknown as T;
  if (node && typeof node === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(node as Record<string, unknown>)) {
      if (SKIP_KEYS.has(k)) out[k] = v;
      else if (typeof v === "string") out[k] = TEXT_KEYS.has(k) ? maskAmountsText(v) : v;
      else out[k] = maskAmountsDeep(v);
    }
    return out as T;
  }
  return node;
}

/** そのチャンネルあての送信で金額を止めるか（設定: app_settings.slack_policy.hide_amount_channels）。設定が無ければ止めない＝これまでどおり */
export function shouldMaskChannel(policy: unknown, channelKey: string): boolean {
  const list = (policy as { hide_amount_channels?: unknown } | null | undefined)?.hide_amount_channels;
  return Array.isArray(list) && list.includes(channelKey);
}
