// =============================================================
// 金額の表示を止める（2026-11-12）: 賃金額・交通費額などを Slack の親メッセージ・スレッドに出さない
//   方針（ユーザー確定 2026-11-11）: 金額は権限つきの管理画面で確認する。Slack には処理状況だけ。
//   notify-slack（Slack への唯一の出口）が、設定で指定されたチャンネルあての送信・更新にだけ適用する。
//   ボタンの value・action_id・url などは変えない（操作はそのまま動く）。日付・時刻・人数・分数は消さない。
// =============================================================
export const AMOUNT_MASK = "（金額は管理画面で確認）";

// ¥1,200 ／ ￥500 ／ 1,200円 ／ 500 円 ／ 6000円 ／ 1.5万円（全角の数字も）を対象にする。
//   消すのは「¥ が前に付く数字」「円 が後ろに付く数字」だけ。日付・時刻・人数・件数・分・番号（「2026年」「11/10」「10:30」「30分」「3件」「2 名」「ID 380」）は対象外
const D = "[0-9０-９]", C = "[,，]";
const RE_YEN_PREFIX = new RegExp(`[¥￥]\\s?${D}(?:${D}|${C})*(?:[.．]${D}+)?(?:\\s?[万千]?円)?`, "g");
const RE_YEN_SUFFIX = new RegExp(`${D}(?:${D}|${C})*(?:[.．]${D}+)?\\s?[万千]?円`, "g");

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

// ---- 消し残りの検査（2026-11-12 ユーザー指示: 想定外の金額が残っていたら、送信を止める） ----
//   maskAmountsText / maskAmountsDeep で消したあとの文面を調べる。金額らしいものが残っていたら、その場所の名前を返す（金額そのものは返さない）。
//   見るもの: ① ¥・円 つきの数字の残り（飾りの記号 * _ ~ ` で分断されたものを含む）② 「◯万」③ 賃金・交通費の言葉のすぐ後ろにある 3 桁以上の数字（単位なし。例「時給 1200」「片道 420」。
//             あいだに ID・番号 とある場合は番号なので対象外）④ データの形のまま出た数字（"鍵":500 のような書き方）
//   日付・時刻・件数など（数字のあとに 年 月 日 時 分 件 名 人 が続くもの、/ - : のあとにまた数字が続くもの）は対象外
const LEAK_WORDS = "時給|日給|月給|賃金|給与|給料|基本給|手当|交通費|通勤費|定期|運賃|片道|往復|支給額|控除額|金額|差額|単価|上限";
const RE_LEAK_YEN = new RegExp(`[¥￥]\\s?${D}|${D}\\s?[万千]?円`);
const RE_LEAK_MAN = new RegExp(`${D}\\s?万(?![件人名回個歩年])`);
const RE_LEAK_WORD = new RegExp(`(?:${LEAK_WORDS})(?:(?!ID|ＩＤ|番号|No|№)[^0-9０-９]){0,12}${D}(?:${D}|${C}){2,}(?!(?:${D}|${C})*\\s?(?:年|月|日|時|分|秒|件|名|人|回|番|号|歳|か月|ヶ月|カ月|%|％|[/／\\-:：.．]${D}))`);
const RE_LEAK_JSON = new RegExp(`["”][\\s]*[:：][\\s]*${D}{3,}`);
export function hasAmountLeak(s: string): boolean {
  if (!s) return false;
  const t = s.replace(/[*_~`]/g, "");
  return RE_LEAK_YEN.test(t) || RE_LEAK_MAN.test(t) || RE_LEAK_WORD.test(t) || RE_LEAK_JSON.test(t);
}
/** 消したあとの本文・ブロックに金額らしいものが残っている場所（例 "text"・"blocks[1].text.text"）。空なら問題なし */
export function findAmountLeaks(text: string | null | undefined, blocks: unknown): string[] {
  const out: string[] = [];
  if (text && hasAmountLeak(text)) out.push("text");
  const walk = (node: unknown, path: string) => {
    if (Array.isArray(node)) { node.forEach((x, i) => walk(x, `${path}[${i}]`)); return; }
    if (node && typeof node === "object") {
      for (const [k, v] of Object.entries(node as Record<string, unknown>)) {
        if (SKIP_KEYS.has(k)) continue;
        if (typeof v === "string") { if (TEXT_KEYS.has(k) && hasAmountLeak(v)) out.push(`${path}.${k}`); }
        else walk(v, `${path}.${k}`);
      }
    }
  };
  if (blocks) walk(blocks, "blocks");
  return out;
}
