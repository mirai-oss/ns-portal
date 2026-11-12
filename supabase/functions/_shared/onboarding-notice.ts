// =============================================================
// 入社登録の Slack 通知「新しい形」（2026-11-21。共通の形＝親は 1 行・詳細と操作はスレッド。お手本は勤怠確認 attendance-alert-notice.ts）
//   親メッセージ    = 1 行だけ（状態の印・「入社登録」・氏名・入社日・いまの状態）＋［詳細を確認］（完了・中止のあとも残す）。1 人の入社に親は 1 つ。
//   スレッド 1 通目 = 「状況カード」（10 項目の一覧・入社後の提出・いま押せるボタン）。変化のたびに同じカードを書き換える（増やさない）。
//   スレッドの返信  = 人の対応が要るもの（失敗・確認待ち・承認待ち・本人への連絡）と、人が行った操作の記録（だれが・いつ）だけ。
//                     自動処理の成功・途中経過は、状況カードの書き換えだけ（返信しない）。
//   金額（賃金額・交通費の金額）と、氏名以外の個人情報（住所・電話・メール・税情報・扶養の続柄）は、このファイルの文面に入れない。
//
//   ここは「文面を組み立てるだけ」（DB にも Slack にも触らない＝単体でテストできる）。送る処理は onboarding-notify。
//   今までの形（v1）の部品 onboarding-blocks.ts は変更していない。どちらの形で出すかは、入社登録ごとの控え
//   onboarding_workflows.slack_notice_format（null・'v1'＝今までの形／'v2'＝新しい形）で決まる。作ったときの形のまま最後まで動く。
// =============================================================
import { ITEM_ORDER, ROLE_LABEL, STATE_EMOJI, STATE_LABEL, POST_JOIN_STATUS_LABEL, postJoinPolicyText, wageApprovalMark, jpDate, nowJst, type ItemInfo, type ItemState, type PostJoinTrack, type WorkflowView } from "./onboarding-blocks.ts";
import { findAmountLeaks, hasAmountLeak, maskAmountsText } from "./amount-mask.ts";

// onboarding-blocks.ts の同じ値（あちらは公開していないので、ここにも置く）
const NIPPO_URL = "https://mirai-oss.github.io/nippo/";
const TASKS_URL = "https://mirai-oss.github.io/ns-portal/tasks.html";

// ---- 1. どちらの形で出すか -----------------------------------------------------------
export type NoticeFormat = "v1" | "v2";
/**
 * 新しく親メッセージを作るときの形を決める。
 *   列が無い（SQL 未適用）→ 必ず v1 ／ 呼び出しの指定（テスト用の入社登録だけ新しい形で試すため）→ 設定 app_settings.onboarding_slack.format → v1
 * すでに親メッセージがある入社登録には使わない（そちらは rowFormat＝作ったときの形）。
 */
export function pickFormat(o: { body?: unknown; setting?: unknown; columnsReady: boolean }): NoticeFormat {
  if (!o.columnsReady) return "v1";
  if (o.body === "v1" || o.body === "v2") return o.body;
  return (o.setting as { format?: unknown } | null | undefined)?.format === "v2" ? "v2" : "v1";
}
/** 入社登録の行に控えてある形。控えが無い（今までの入社登録・列が無い）は v1 */
export function rowFormat(row: { slack_notice_format?: unknown } | null | undefined): NoticeFormat {
  return row?.slack_notice_format === "v2" ? "v2" : "v1";
}

// ---- 2. 状態 ------------------------------------------------------------------------
const clean = (s: unknown, max = 40) => String(s ?? "").replace(/[\n\r|｜<>]/g, " ").trim().slice(0, max);
/** "2026-11-20" → "11/20"。読めなければ null（＝日付を出さない） */
export function monthDay(d: string | null | undefined): string | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(d ?? ""));
  return m ? `${Number(m[2])}/${Number(m[3])}` : null;
}
// 人の対応が要る状態（再試行待ち retry_wait は自動でやり直すので、ここには入れない）
const NEED_PERSON = ["manual_required", "failed"];
export type NoticeState = {
  code: "progress" | "alert" | "done" | "cancelled"; mark: string; done: boolean;
  doneCount: number; total: number; blocked: { key: string; label: string }[]; next: string | null;
};
export function noticeState(wf: Pick<WorkflowView, "status" | "items">): NoticeState {
  const items = wf.items ?? {};
  const total = ITEM_ORDER.length;
  const doneCount = ITEM_ORDER.filter(({ key }) => items[key]?.state === "completed").length;
  const blocked = ITEM_ORDER.filter(({ key }) => NEED_PERSON.includes(items[key]?.state ?? "")).map(({ key, label }) => ({ key, label }));
  const next = ITEM_ORDER.find(({ key }) => (items[key]?.state ?? "pending") === "pending")?.label ?? null;
  const base = { doneCount, total, blocked, next };
  if (wf.status === "completed") return { code: "done", mark: "✅", done: true, ...base };
  if (wf.status === "cancelled") return { code: "cancelled", mark: "⛔", done: true, ...base };
  if (blocked.length) return { code: "alert", mark: "🛑", done: false, ...base };
  return { code: "progress", mark: "🟢", done: false, ...base };
}

// ---- 3. 親メッセージ（1 行） ----------------------------------------------------------
/**
 * 例: 🟢 入社登録｜山田太郎｜入社 11/20｜進行中 ／ 🛑 入社登録｜山田太郎｜入社 11/20｜要対応 ／ ✅ 入社登録｜山田太郎｜入社 11/20｜完了 ／ ⛔ 入社登録｜山田太郎｜入社 11/20｜中止
 * 氏名・入社日・いまの状態が 1 行で分かる（2026-11-12 ユーザー決定: 要対応のときも入社日を出す）。入社日が無いときは日付だけ省く（🟢 入社登録｜山田太郎｜進行中）。区分・所属・項目の一覧・操作ボタンは出さない。
 * 「詳細を確認」は、スレッド（状況カード）を開くリンクのボタン。完了・中止のあとも残す（2026-11-12 ユーザー決定）。リンクが無いときはボタンなし（Slack 標準の「○件の返信」から開ける）。
 */
export function parentLine(wf: Pick<WorkflowView, "id" | "status" | "items" | "user_name" | "hire_date">, notificationId: string, o: { permalink?: string | null } = {}): { text: string; blocks: unknown[] } {
  const st = noticeState(wf);
  const md = monthDay(wf.hire_date);
  const word = st.code === "done" ? "完了" : st.code === "cancelled" ? "中止" : st.code === "alert" ? "要対応" : "進行中";
  const text = `${st.mark} 入社登録｜${clean(wf.user_name, 30) || "（氏名不明）"}${md ? `｜入社 ${md}` : ""}｜${word}`;
  const blocks: unknown[] = [{ type: "section", text: { type: "mrkdwn", text } }];
  if (o.permalink) {
    blocks.push({ type: "actions", block_id: "onboarding_open", elements: [
      // URL ボタンの押下通知は slack-interact の hr.onboarding.link*（何もしない）が受ける
      { type: "button", text: { type: "plain_text", text: "詳細を確認", emoji: true }, action_id: "hr.onboarding.link.open", url: o.permalink, value: JSON.stringify({ workflow_id: wf.id, notification_id: notificationId }) },
    ] });
  }
  return { text, blocks };
}

// ---- 4. 状況カード（スレッドの 1 通目） ------------------------------------------------
// 賃金・交通費は、金額の代わりに処理状況の言葉を出す（今までの「金額を出さない表示」と同じ言葉）
const AMOUNT_ITEM_WORD: Record<string, [string, string]> = { wage: ["賃金設定待ち", "賃金設定済み"], commute_check: ["交通費確認待ち", "交通費確認済み"], commute_set: ["交通費設定待ち", "交通費設定済み"] };
const CANCEL_REASON_LABEL: Record<string, string> = { declined_by_person: "本人から入社辞退", no_contact_after_hire: "採用後連絡不通", dropped_during_registration: "入社登録途中離脱", company_reason: "会社都合中止", other: "その他" };
const HIDDEN_REASON = "理由は管理システムで確認";

function itemLine(key: string, label: string, it: ItemInfo | undefined, notes: boolean): string {
  const st: ItemState = (it?.state ?? "pending") as ItemState;
  const src = it?.completion_source ?? null;
  const manualDone = st === "completed" && (src === "manual_check" || src === "manual_step");
  let emoji = manualDone ? "☑️" : STATE_EMOJI[st] ?? "⬜";
  let word = AMOUNT_ITEM_WORD[key] ? (st === "completed" ? AMOUNT_ITEM_WORD[key][1] : st === "cancelled" ? STATE_LABEL[st] : AMOUNT_ITEM_WORD[key][0]) : (STATE_LABEL[st] ?? st);
  let note = "";
  if (manualDone) note = "本部タスクで手動 ✓・スマレジ反映は未確認";
  else if (key === "wage" && st === "completed") note = src === "smaregi_verified" ? "スマレジ照合済み" : src === "smaregi_unverified" ? "保存済み・照合は未確認" : "";
  else if (st === "running" && it?.payload?.verify === "pending") note = "スマレジに入力済み・照合待ち";
  else if (st === "pending" && key === "smaregi_staff") note = "従業員ページから作成できます";
  // 入社時の賃金の承認: 社長の承認待ち・却下・承認済み（反映中）
  const apv = key === "wage" ? wageApprovalMark(it) : null;
  if (apv) { emoji = apv.emoji; word = apv.label; note = apv.note; }
  else if (NEED_PERSON.includes(st) && it?.last_error) note = String(it.last_error).replace(/\s+/g, " ").slice(0, 80);
  const head = `${emoji} ${label}：${word}`;
  if (!note) return head;
  if (!notes) return NEED_PERSON.includes(st) ? `${head}（${HIDDEN_REASON}）` : head;
  // 理由の文に金額らしいものがあれば、理由ごと出さない（項目の言葉とつながって金額に見える場合も含む）
  const line = `${head}（${maskAmountsText(note)}）`;
  return hasAmountLeak(line) || line.includes("（金額は管理画面で確認）") ? `${head}（${HIDDEN_REASON}）` : line;
}
// 入社後の提出（年末調整・扶養家族）: 必須／任意・期限・状態だけ（人数・続柄は出さない）
function postJoinLine(label: string, t: PostJoinTrack | null | undefined): string {
  const x: PostJoinTrack = t ?? { status: "pending" };
  const mark = x.status === "synced" || x.status === "none" ? "✅" : x.status === "skipped" || x.status === "not_target" ? "➖" : x.status === "submitted" ? "📝" : x.status === "approved" || x.status === "queued" ? "⏳" : x.status === "error" ? "⚠️" : x.required ? "⬜" : "▫️";
  return `${mark} ${label}：${postJoinPolicyText(x)}・${POST_JOIN_STATUS_LABEL[x.status] ?? x.status}`;
}
const btn = (text: string, actionId: string, value: string, extra: Record<string, unknown> = {}) => ({ type: "button", ...extra, text: { type: "plain_text", text, emoji: true }, action_id: actionId, value });

/**
 * いま押せる操作（進行中のあいだだけ。完了・中止のあとは出さない）。承認のボタンはここには無い（承認は、申請があったときのスレッドの返信に付く）。
 *   need = いま必要な設定（まだ済んでいないものだけ）／more = その他
 * ボタンの名前（action_id）と value（workflow_id・notification_id＝親メッセージの台帳の番号）は、今までの形と同じ。
 */
export function cardActions(wf: WorkflowView, notificationId: string): { need: unknown[]; more: unknown[] } {
  if (noticeState(wf).done) return { need: [], more: [] };
  const items = wf.items ?? {};
  const st = (k: string) => (items[k]?.state ?? "pending") as string;
  const open = (k: string) => ["pending", "failed", "manual_required"].includes(st(k));
  const value = JSON.stringify({ workflow_id: wf.id, notification_id: notificationId });
  const need: unknown[] = [], more: unknown[] = [];
  const apv = wageApprovalMark(items.wage);
  // 賃金: 社長の承認待ち・反映中のあいだは出さない（却下されたら入れ直しのために出す）
  if (open("wage") && !(apv && items.wage?.payload?.approval === "pending")) need.push(btn("💴 賃金を設定", "hr.onboarding.wage", value));
  // 交通費の設定: 経路と片道額の承認が済んでから（承認の前は押しても進めない）
  const commuteApproved = st("commute_check") === "completed";
  if (commuteApproved && open("commute_set")) need.push(btn("🚌 交通費を設定", "hr.onboarding.commute.set", value));
  if (open("withholding_tax")) need.push(btn("🧾 源泉所得税", "hr.onboarding.tax", value));
  if (need.length) (need[0] as Record<string, unknown>).style = "primary";
  more.push(btn("📨 本人へ連絡", "hr.onboarding.contact", value), btn("🔎 スマレジ照合", "hr.onboarding.account.check", value), btn("🔄 表示を更新", "hr.onboarding.refresh", value));
  // 設定済みの交通費の入れ直し（入れ直せる画面が Slack にしか無いため、その他に残す。反映の途中は出さない）
  if (commuteApproved && st("commute_set") === "completed") more.push(btn("🚌 交通費を入れ直す", "hr.onboarding.commute.set", value));
  more.push(btn("⛔ 中止", "hr.onboarding.cancel", value, { confirm: { title: { type: "plain_text", text: "入社手続きの中止" }, text: { type: "plain_text", text: "理由を選ぶ画面を開きます" }, confirm: { type: "plain_text", text: "開く" }, deny: { type: "plain_text", text: "やめる" } } }));
  return { need, more };
}

function buildCard(wf: WorkflowView, notificationId: string, notes: boolean): { text: string; blocks: unknown[] } {
  const st = noticeState(wf);
  const items = wf.items ?? {};
  const name = clean(wf.user_name, 30) || "（氏名不明）";
  const kind = ROLE_LABEL[wf.role ?? ""] ?? wf.role ?? "";
  const reason = wf.cancelled_reason ? (CANCEL_REASON_LABEL[wf.cancelled_reason] ?? "") : "";
  const blockedText = st.blocked.map((b) => b.label).join("・");
  const situation = st.code === "done" ? `✅ 完了（${st.doneCount}/${st.total}）`
    : st.code === "cancelled" ? `⛔ 中止${reason ? `（${reason}）` : ""}`
    : st.code === "alert" ? `🛑 要対応（${st.doneCount}/${st.total} 完了）: ${blockedText}`
    : `🟢 進行中（${st.doneCount}/${st.total} 完了）${st.next ? `　▶ 次: ${st.next}` : ""}`;
  const head = [
    "*【入社登録】*",
    `氏名：${name}${kind ? `（${kind}）` : ""}`,
    `所属：${clean(wf.store_names, 80) || "所属なし"}`,
    `入社日：${jpDate(wf.hire_date)}`,
    `スマレジ：${clean(wf.contract_label ?? wf.contract_id, 30) || "契約未定"}${wf.smaregi_staff_id ? `／従業員ID ${wf.smaregi_staff_id}` : "／未作成"}`,
    `状況：${situation}`,
  ];
  const lines = ITEM_ORDER.map(({ key, label }) => itemLine(key, label, items[key], notes));
  const blocks: unknown[] = [
    { type: "section", text: { type: "mrkdwn", text: head.join("\n") } },
    { type: "section", text: { type: "mrkdwn", text: ["*【登録状況】*", ...lines].join("\n") } },
  ];
  if (wf.status !== "cancelled") {
    const ye = wf.year_end ?? null;
    blocks.push({ type: "section", text: { type: "mrkdwn", text: ["*【入社後の提出】*（入社登録の完了とは別）", postJoinLine(`年末調整${ye?.target_year ? ` ${ye.target_year} 年度` : ""}`, ye), postJoinLine("扶養家族", wf.dependents ?? null)].join("\n") } });
  }
  const a = cardActions(wf, notificationId);
  if (a.need.length) blocks.push({ type: "actions", block_id: "onboarding_actions", elements: a.need });
  if (a.more.length) blocks.push({ type: "actions", block_id: "onboarding_actions_more", elements: a.more });
  const links = [wf.user_id ? `<${NIPPO_URL}?page=admin&u=${wf.user_id}|従業員ページ>` : "", wf.hq_task_id ? `<${TASKS_URL}?task=${wf.hq_task_id}|本部タスク>` : ""].filter(Boolean).join("・");
  blocks.push({ type: "context", elements: [{ type: "mrkdwn", text: `${links ? links + "　" : ""}金額と内容は管理システムで確認（Slack には出しません）。このカードは進むたびに書き換わります。ワークフロー \`${wf.id.slice(0, 8)}\`・更新 ${nowJst()}` }] });
  return { text: `【入社登録】${name}　${situation}`.slice(0, 300), blocks };
}
/**
 * 状況カード。10 項目の一覧（済／未／待ちの言葉だけ。金額なし）・入社後の提出・いま押せるボタン。
 * 失敗の理由（last_error）に金額らしいものが混ざっていたら、理由を出さない形に組み直す（出口の検査で送信が止まらないようにする）。
 */
export function statusCard(wf: WorkflowView, notificationId: string): { text: string; blocks: unknown[] } {
  const c = buildCard(wf, notificationId, true);
  return findAmountLeaks(c.text, c.blocks).length ? buildCard(wf, notificationId, false) : c;
}

// ---- 5. スレッドの返信（新しい形だけの文面。金額・税の内容・メールは入れない） -----------------
const CARD = "状況カード（スレッドの先頭）";
/** 今までの形の文面をそのまま返信に使うときの言い換え（親メッセージにボタンが無くなるため）。ボタンの value・action_id・url は触らない */
export function threadWording<T>(node: T): T {
  if (typeof node === "string") {
    return node
      .replaceAll("親メッセージの「", `${CARD}の「`).replaceAll("親メッセージのボタン", `${CARD}のボタン`)
      .replaceAll("結果はこのスレッドに届きます", `結果は${CARD}に出ます（うまくいかなかったときだけ、ここに届きます）`) as unknown as T;
  }
  if (Array.isArray(node)) return node.map((x) => threadWording(x)) as unknown as T;
  if (node && typeof node === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(node as Record<string, unknown>)) out[k] = ["value", "action_id", "block_id", "url", "type", "style"].includes(k) ? v : threadWording(v);
    return out as T;
  }
  return node;
}
/**
 * 賃金をスマレジに反映できたあと。照合まで一致＝自動処理の成功なので返信しない（null）。ただし人が操作したときは 1 行の記録を残す。
 * 照合できなかった・一致しなかったときは、確認のお願いを出す。recorded=true は、同じ操作の記録（社長の承認）をすでに出しているとき。
 */
export function wageSyncedNote(o: { who: string; when: string; verified: boolean | null; verifyNote: string; human: boolean; recorded?: boolean }): string | null {
  if (o.verified === true) return o.human && !o.recorded ? `💴 賃金をスマレジに反映しました（${o.who}・${o.when}）。読み直して一致を確認済みです` : null;
  return `⚠️ 賃金はスマレジに保存しましたが、${o.verified === false ? "読み直した値が一致しません" : "照合ができていません"}（${o.who}・${o.when}）\n${maskAmountsText(String(o.verifyNote ?? "")).slice(0, 200)}\nスマレジ管理画面で確認してください`;
}
/** 交通費の承認・本人確認・差し戻し（人の操作の記録）。金額は出さない。次に人がやることがあるときだけ案内を足す */
export function commuteDecidedNote(o: { decision: string; who: string; when: string; note?: string | null; oneStep?: string | null }): string {
  const memo = (label: string) => (o.note ? `\n${label}: ${maskAmountsText(String(o.note)).slice(0, 200)}` : "");
  if (o.decision === "approved") {
    const os = String(o.oneStep ?? "");
    const next = os === "saved" ? "\n会社のルールの初期値で、交通費の設定も登録しました"
      : os === "already_set" || os === "item_in_progress" ? ""
      : os === "no_teiki" ? `\n▶ 次: 定期代が検索で取れていないため、設定は自動で登録していません。${CARD}の「🚌 交通費を設定」で金額を入れてください`
      : os === "no_contract" ? `\n▶ 次: スマレジの従業員登録がまだのため、設定は登録していません。登録のあと、${CARD}の「🚌 交通費を設定」から入れてください`
      : `\n▶ 次: ${CARD}の「🚌 交通費を設定」で、スマレジに入れる値（支給形態・適用開始日・金額）を決めてください`;
    return `✅ 交通費の経路と片道額を承認しました（${o.who}・${o.when}）${memo("メモ")}${next}`;
  }
  if (o.decision === "person_review") return `🙋 本人に経路と金額を確認することにしました（${o.who}・${o.when}）。返答が来たらスレッドに書き、「🔁 再検索」または承認のボタンを押してください`;
  return `↩️ 交通費を差し戻しました（${o.who}・${o.when}）${memo("理由")}`;
}
/**
 * 交通費の設定を登録したあと。
 *   自動反映が有効化されていない（manual）＝人がスマレジに入力する必要がある → 出す
 *   承認と同時の自動登録（oneStep）＝承認の記録に書いてあるので出さない（null）
 *   人が入力画面から登録した ＝ 1 行の記録
 */
export function commuteSettingNote(o: { who: string; when: string; manual: boolean; oneStep: boolean }): string | null {
  if (o.manual) return `🙋 交通費の設定を登録しました（${o.who}・${o.when}）。スマレジへの自動反映は、まだ有効化されていません。金額は管理システム（従業員ページ）で確認して、スマレジ管理画面に入力し、本部タスクの「交通費」に ✓ を付けてください`;
  if (o.oneStep) return null;
  return `🚌 交通費の設定を登録しました（${o.who}・${o.when}）。スマレジへは自動で反映します（結果は${CARD}に出ます）`;
}
/** 源泉所得税の設定を登録したあと（人の操作の記録）。区分・配偶者・親族の数は出さない */
export function taxSettingNote(o: { who: string; when: string; manual: boolean }): string {
  return o.manual
    ? `🙋 源泉所得税の設定を登録しました（${o.who}・${o.when}）。スマレジへの自動反映は、まだ有効化されていません。内容は管理システムで確認して、スマレジ管理画面（給与設定 → 源泉所得税設定を追加）に入力し、本部タスクの「源泉所得税」に ✓ を付けてください`
    : `🧾 源泉所得税の設定を登録しました（${o.who}・${o.when}）。スマレジへは自動で反映します（結果は${CARD}に出ます）`;
}
/** 「🔎 スマレジ照合」を人が押したあとの記録。項目の名前だけ（メール・区分・金額は出さない）。warnings は ⚠️ で始まる行だけ渡す */
export function accountCheckNote(o: { who: string; when: string; done: string[]; warnings?: string[] }): string {
  const w = (o.warnings ?? []).map((x) => maskAmountsText(String(x)).slice(0, 160));
  return `🔎 スマレジ照合をしました（${o.who}・${o.when}）: ${o.done.length ? `${o.done.join("・")} の登録を確認しました` : "新しく確認できた項目はありません"}。結果は${CARD}に出ています${w.length ? "\n" + w.join("\n") : ""}`;
}
/**
 * スマレジ画面の自動操作（UI ジョブ）の結果を、スレッドに返信するか。
 *   失敗して手動対応になった／保存後の照合が一致しない／5 回読み直せず確認の工程を足した ＝ 人の対応が要る → 出す
 *   人が頼んだ読み取り（扶養の比較など snapshot）の結果 → 出す
 *   成功（照合一致）・照合待ち・あとで再試行・定期の読み取り ＝ 自動処理の成功と途中経過 → 出さない（状況カードの書き換えだけ）
 */
export function uiJobNeedsPost(o: { status: string; dryRun: boolean; verified: boolean | null; escalated: boolean; snapshot: boolean }): boolean {
  if (o.status === "failed") return true;
  if (o.status !== "success") return false;
  if (o.dryRun) return o.snapshot;
  if (o.verified === false) return true;
  return o.verified === null && o.escalated;
}
/** UI ジョブの結果を返信するときの「内容」の行（設定の中身＝金額・税の区分・メールは出さない） */
export const UI_JOB_SUMMARY_V2 = "内容は管理システム（従業員ページ）で確認してください";
