// 入社登録ワークフロー（Slack 一元管理 Phase 1・2026-11-09）の Slack 表示部品。
// onboarding-notify（親メッセージの作成・更新・スレッド投稿）から使う。業務ロジックは持たない（表示だけ）。
// 個人情報の扱い（ユーザー指示）: 住所・電話・生年月日・税情報は出さない。出すのは 氏名・区分・所属・入社日・スマレジ契約/ID・各項目の状態 だけ。

import { methodJa } from "./commute-judge.ts";
export type ItemState = "pending" | "running" | "completed" | "retry_wait" | "manual_required" | "manual_running" | "cancelled" | "failed";
export type ItemInfo = { state: ItemState; attempts?: number; last_error?: string | null; payload?: any; completed_at?: string | null; completion_source?: string | null };
export type WorkflowView = {
  id: string; user_id: string | null; status: string; hire_date: string | null; role: string | null;
  contract_id: string | null; contract_label: string | null; smaregi_staff_id: string | null; hq_task_id: string | null;
  user_name: string | null; store_names: string | null; items: Record<string, ItemInfo> | null;
  cancelled_reason?: string | null; completed_at?: string | null;
  // Phase 6 v2（2026-11-09）: 入社後の提出（年末調整・扶養家族）。入社登録の完了は止めない別トラック。
  //   実効ポリシー（雇用区分の標準ルール＋個別上書き）と状態（pending/submitted/approved/queued/synced/error/skipped/none/not_target）を持つ
  year_end?: PostJoinTrack | null;
  dependents?: PostJoinTrack | null;
};
export type PostJoinTrack = {
  status: string; target_year?: number | null; required?: boolean | null; remind_enabled?: boolean | null; deadline?: string | null; target?: boolean | null; form_enabled?: boolean | null;
  // 2026-11-10 v3: deadline＝社内期限（internal_deadline と同じ値。リマインド・必須管理に使う）／legal_deadline＝法定期限の目安（参考表示のみ）
  internal_deadline?: string | null; legal_deadline?: string | null; legal_deadline_basis?: string | null; legal_deadline_note?: string | null;
  source_of_required?: string | null; class?: string | null; submitted_at?: string | null; approved_at?: string | null; sync_status?: string | null; verified_at?: string | null;
  count?: number | null; synced?: number | null; relationships?: number[] | null;
};
export const RELATIONSHIP_LABEL: Record<number, string> = { 0: "本人", 1: "配偶者", 2: "息子", 3: "娘", 4: "父", 5: "母", 6: "兄", 7: "姉", 8: "弟", 9: "妹", 10: "祖父", 11: "祖母", 12: "孫", 13: "義父", 14: "義母", 99: "その他" };
export const POST_JOIN_STATUS_LABEL: Record<string, string> = { pending: "未提出", submitted: "提出済み（本部の承認待ち）", approved: "承認済み（スマレジ未反映）", queued: "スマレジ反映の順番待ち", synced: "スマレジ反映済み", error: "反映エラー", none: "扶養なし", skipped: "不要（本部確認済み）", not_target: "対象外" };
export const POST_JOIN_TRACK_LABEL: Record<string, string> = { year_end: "年末調整", dependents: "扶養家族" };
/** 必須／任意・期限の短い表示（例「必須・社内期限 11/30（法定の目安 12/14）」「任意」「対象外」）。社内期限と法定期限は別の概念（2026-11-10 ユーザー指示） */
export function postJoinPolicyText(t: PostJoinTrack | null | undefined): string {
  if (!t) return "任意";
  if (t.target === false || t.status === "not_target") return "対象外";
  if (t.form_enabled === false) return "フォーム停止中";
  const req = t.required ? "必須" : "任意";
  const legal = t.legal_deadline ? `（法定の目安 ${jpDate(t.legal_deadline).slice(5)}）` : "";
  const dl = t.deadline ? `・社内期限 ${jpDate(t.deadline).slice(5)}${legal}` : (legal ? `・法定の目安 ${jpDate(t.legal_deadline).slice(5)}` : "");
  const src = t.source_of_required === "override" ? "（個別設定）" : "";
  return `${req}${dl}${src}`;
}
/** 入社後の提出 2 件の表示行（個人情報なし: 件数と続柄だけ）。例「📝 扶養家族: 必須・期限 11/23（個別設定）・提出済み（本部の承認待ち）・2 人（配偶者・息子）」 */
export function postJoinLines(wf: WorkflowView): string[] {
  const ye: PostJoinTrack = wf.year_end ?? { status: "pending" }; const dp: PostJoinTrack = wf.dependents ?? { status: "pending" };
  const mark = (t: PostJoinTrack) => t.status === "synced" || t.status === "none" ? "✅" : t.status === "skipped" || t.status === "not_target" ? "➖" : t.status === "submitted" ? "📝" : t.status === "approved" || t.status === "queued" ? "⏳" : t.status === "error" ? "⚠️" : t.required ? "⬜" : "▫️";
  const rel = Array.isArray(dp.relationships) && dp.relationships.length ? `（${dp.relationships.map((r) => RELATIONSHIP_LABEL[r] ?? r).join("・")}）` : "";
  const yeYear = ye.target_year ? ` ${ye.target_year} 年度` : "";
  return [
    `${mark(ye)} 年末調整${yeYear}: ${postJoinPolicyText(ye)}・_${POST_JOIN_STATUS_LABEL[ye.status] ?? ye.status}_`,
    `${mark(dp)} 扶養家族: ${postJoinPolicyText(dp)}・_${POST_JOIN_STATUS_LABEL[dp.status] ?? dp.status}${dp.count ? `・${dp.count} 人${rel}${dp.synced ? `・反映 ${dp.synced} 人` : ""}` : ""}_`,
  ];
}

export const ITEM_ORDER: { key: string; label: string; phase: number }[] = [
  { key: "join_form", label: "入社フォーム", phase: 1 },
  { key: "smaregi_staff", label: "スマレジ従業員の作成", phase: 1 },
  { key: "wage", label: "賃金（時給・日給・月給）", phase: 1 },
  { key: "commute_check", label: "交通費の経路確認", phase: 2 },
  { key: "commute_set", label: "交通費の設定", phase: 2 },
  { key: "withholding_tax", label: "源泉所得税の設定", phase: 3 },
  { key: "web_payslip", label: "個別Web給与明細の表示設定", phase: 3 },
  { key: "email", label: "メールアドレス登録（スマレジ）", phase: 3 },
  { key: "smaregi_account", label: "本人のスマレジアカウント登録", phase: 5 },
  { key: "slack_link", label: "Slack 連携", phase: 1 },
];

export const ROLE_LABEL: Record<string, string> = { AL: "アルバイト", SHAIN: "社員", TENCHO: "店長", TEAM: "チーム長", HQ: "本部", CEO: "社長" };
export const WAGE_DIV_LABEL: Record<number, string> = { 0: "時給", 1: "日給", 2: "月給" };
export const STATE_EMOJI: Record<ItemState, string> = {
  pending: "⬜", running: "🔄", completed: "✅", retry_wait: "⏳", manual_required: "🙋", manual_running: "✍️", cancelled: "➖", failed: "⚠️",
};
export const STATE_LABEL: Record<ItemState, string> = {
  pending: "未", running: "処理中", completed: "完了", retry_wait: "再試行待ち", manual_required: "手動対応が必要", manual_running: "手動対応中", cancelled: "中止", failed: "失敗",
};

export const yen = (n: unknown) => (n === null || n === undefined || n === "" ? "" : "¥" + Number(n).toLocaleString("ja-JP"));
export const jpDate = (d: string | null | undefined) => (d ? String(d).slice(0, 10).replace(/-/g, "/") : "未設定");
export const nowJst = () => new Date().toLocaleString("ja-JP", { timeZone: "Asia/Tokyo", hour12: false, month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit" });

const NIPPO_URL = "https://mirai-oss.github.io/nippo/";
const TASKS_URL = "https://mirai-oss.github.io/ns-portal/tasks.html";

/** 賃金 1 行の説明文（例: 時給 ¥1,200（2026/11/10から・全事業所共通）） */
export function wageLine(r: { division: number; wage: number; holiday_wage?: number | null; effective_date: string; store_name?: string | null }): string {
  const target = r.division === 0 ? (r.store_name ? `${r.store_name}だけ` : "全事業所共通") : "";
  return `${WAGE_DIV_LABEL[r.division] ?? "賃金"} ${yen(r.wage)}${r.holiday_wage != null ? `（休日 ${yen(r.holiday_wage)}）` : ""}（${jpDate(r.effective_date)}から${target ? "・" + target : ""}）`;
}

/** 親メッセージの本文（text は通知・検索用の 1 行、blocks が表示） */
export function parentMessage(wf: WorkflowView, notificationId: string): { text: string; blocks: unknown[] } {
  const name = wf.user_name ?? "（氏名不明）";
  const kind = ROLE_LABEL[wf.role ?? ""] ?? wf.role ?? "";
  const stores = wf.store_names || "所属なし";
  const statusText = wf.status === "completed" ? "✅ 入社登録 完了" : wf.status === "cancelled" ? "⛔ 入社手続き 中止" : "🟢 入社登録 進行中";
  const items = wf.items ?? {};
  const lines = ITEM_ORDER.map(({ key, label, phase }) => {
    const it = items[key];
    const st: ItemState = (it?.state ?? "pending") as ItemState;
    let extra = "";
    // 完了の見分け: ✅=スマレジに保存し GET で一致確認済み（or システム判定）／☑️=本部タスクで人が手動 ✓（スマレジ反映は未確認）／✅+注記=保存したが照合できず
    const src = it?.completion_source ?? null;
    let emoji = STATE_EMOJI[st];
    if (st === "completed" && (src === "manual_check" || src === "manual_step")) { emoji = "☑️"; extra = "　_（本部タスクで手動 ✓・スマレジ反映は未確認）_"; }
    if (key === "wage" && st === "completed" && Array.isArray(it?.payload?.rows) && src !== "manual_check" && src !== "manual_step") {
      extra = "　" + it.payload.rows.map((r: any) => wageLine(r)).join("／") + (src === "smaregi_verified" ? "　_スマレジ照合済み_" : src === "smaregi_unverified" ? "　_（保存済み・照合は未確認）_" : "");
    }
    if ((st === "failed" || st === "manual_required") && it?.last_error) extra = `　_${String(it.last_error).slice(0, 80)}_`;
    if (st === "pending" && ["commute_set", "withholding_tax", "web_payslip"].includes(key)) extra = "　_（今は手作業。本部タスクの ✓ で反映）_";
    else if (st === "pending" && key === "email") extra = "　_（今は手作業。本部タスク工程①の完了で反映）_";
    else if (st === "pending" && key === "smaregi_account") extra = "　_（「🔎 スマレジ照合」で確認。API に項目が無いため管理画面の読み取りが要ります）_";
    else if (st === "pending" && phase > 1) extra = "　_（Phase 2 以降で自動化）_";
    return `${emoji} ${label}${extra}`;
  });
  const value = JSON.stringify({ workflow_id: wf.id, notification_id: notificationId });
  // Phase 6: 入社後の提出（年末調整・扶養家族）は別トラックとして下に並べる（完了判定には入れない）
  const postJoin = wf.status === "cancelled" ? [] : ["", "*入社後の提出*（入社登録の完了とは別。必須のものだけリマインド。任意は税法上の義務を免除するものではありません）", ...postJoinLines(wf)];
  // 2026-11-09 ユーザー指示「完了したか・途中で止まっているかがすぐ分かるように」: 先頭に 完了数／止まっている項目／次にやること を 1 行で
  const total = ITEM_ORDER.length;
  const done = ITEM_ORDER.filter(({ key }) => items[key]?.state === "completed").length;
  const blocked = ITEM_ORDER.filter(({ key }) => ["manual_required", "failed", "retry_wait"].includes(items[key]?.state ?? "")).map(({ key, label }) => `${label}${items[key]?.last_error ? `（${String(items[key].last_error).slice(0, 40)}）` : ""}`);
  const nextItem = ITEM_ORDER.find(({ key }) => (items[key]?.state ?? "pending") === "pending");
  const glance = wf.status === "completed" ? `✅ *完了*（${done}/${total}）`
    : wf.status === "cancelled" ? `⛔ *中止*${wf.cancelled_reason ? `（${wf.cancelled_reason}）` : ""}`
    : blocked.length ? `🛑 *止まっています*（${done}/${total} 完了）: ${blocked.join("・")}`
    : `🟢 *進行中*（${done}/${total} 完了）${nextItem ? `　▶ 次: ${nextItem.label}` : ""}`;
  const headEmoji = wf.status === "completed" ? "✅" : wf.status === "cancelled" ? "⛔" : blocked.length ? "🛑" : "🟢";
  const blocks: unknown[] = [
    { type: "header", text: { type: "plain_text", text: `${headEmoji} 入社登録：${name}さん`, emoji: true } },
    { type: "section", text: { type: "mrkdwn", text: glance } },
    { type: "section", fields: [
      { type: "mrkdwn", text: `*区分*\n${kind || "—"}` },
      { type: "mrkdwn", text: `*所属*\n${stores}` },
      { type: "mrkdwn", text: `*入社日*\n${jpDate(wf.hire_date)}` },
      { type: "mrkdwn", text: `*スマレジ*\n${wf.contract_label ?? wf.contract_id ?? "契約未定"}${wf.smaregi_staff_id ? `／従業員ID ${wf.smaregi_staff_id}` : "／未作成"}` },
    ] },
    { type: "section", text: { type: "mrkdwn", text: `*${statusText}*\n${lines.concat(postJoin).join("\n")}` } },
  ];
  if (wf.status !== "cancelled") {
    const actions: unknown[] = [
      { type: "button", style: "primary", text: { type: "plain_text", text: "💴 賃金を設定", emoji: true }, action_id: "hr.onboarding.wage", value },
      { type: "button", text: { type: "plain_text", text: "🚌 交通費を設定", emoji: true }, action_id: "hr.onboarding.commute.set", value },
      { type: "button", text: { type: "plain_text", text: "🧾 源泉所得税", emoji: true }, action_id: "hr.onboarding.tax", value },
      { type: "button", text: { type: "plain_text", text: "📨 本人へ連絡", emoji: true }, action_id: "hr.onboarding.contact", value },
      { type: "button", text: { type: "plain_text", text: "🔎 スマレジ照合", emoji: true }, action_id: "hr.onboarding.account.check", value },
      { type: "button", text: { type: "plain_text", text: "🔄 表示を更新", emoji: true }, action_id: "hr.onboarding.refresh", value },
      { type: "button", text: { type: "plain_text", text: "⛔ 中止", emoji: true }, action_id: "hr.onboarding.cancel", value, confirm: { title: { type: "plain_text", text: "入社手続きの中止" }, text: { type: "plain_text", text: "理由を選ぶ画面を開きます" }, confirm: { type: "plain_text", text: "開く" }, deny: { type: "plain_text", text: "やめる" } } },
    ];
    // URL ボタンも押下通知が slack-interact に届く（action_id は同じブロック内で一意にする必要がある→ .nippo / .task）
    if (wf.user_id) actions.push({ type: "button", text: { type: "plain_text", text: "従業員ページ", emoji: true }, action_id: "hr.onboarding.link.nippo", url: `${NIPPO_URL}?page=admin&u=${wf.user_id}`, value });
    if (wf.hq_task_id) actions.push({ type: "button", text: { type: "plain_text", text: "本部タスク", emoji: true }, action_id: "hr.onboarding.link.task", url: `${TASKS_URL}?task=${wf.hq_task_id}`, value });
    blocks.push({ type: "actions", block_id: "onboarding_actions", elements: actions });
  }
  blocks.push({ type: "context", elements: [{ type: "mrkdwn", text: `進捗・結果・エラーはこのスレッドに届きます。ワークフロー \`${wf.id.slice(0, 8)}\`・更新 ${nowJst()}` }] });
  return { text: `${headEmoji} 入社登録：${name}さん（${kind}／${stores}）${wf.status === "completed" ? " 完了" : wf.status === "cancelled" ? " 中止" : blocked.length ? ` 止まっています: ${blocked.join("・")}` : ` 進行中 ${done}/${total}`}`, blocks };
}

/** 賃金モーダル。contracts が 2 つ以上のときだけ契約の選択を出す */
export function wageModal(meta: { workflow_id: string; user_id: string; notification_id: string | null; contract_id?: string | null }, opts: {
  name: string; hire_date: string | null; contracts: { contract_id: string; label: string; staff_id: string }[];
}) {
  const today = new Date(Date.now() + 9 * 3600e3).toISOString().slice(0, 10);
  const initDate = opts.hire_date && /^\d{4}-\d{2}-\d{2}$/.test(opts.hire_date) ? opts.hire_date : today;
  const blocks: unknown[] = [
    { type: "section", text: { type: "mrkdwn", text: `*${opts.name}さん* の賃金を登録し、スマレジ・タイムカードの賃金設定に反映します。\n結果はスレッドに届きます。` } },
  ];
  if (opts.contracts.length > 1) {
    blocks.push({ type: "input", block_id: "contract", label: { type: "plain_text", text: "スマレジの契約（法人）" }, element: {
      type: "static_select", action_id: "contract", initial_option: { text: { type: "plain_text", text: opts.contracts[0].label }, value: opts.contracts[0].contract_id },
      options: opts.contracts.map((c) => ({ text: { type: "plain_text", text: c.label }, value: c.contract_id })),
    } });
  } else if (opts.contracts.length === 1) {
    blocks.push({ type: "context", elements: [{ type: "mrkdwn", text: `スマレジ: ${opts.contracts[0].label}（従業員ID ${opts.contracts[0].staff_id}）` }] });
  }
  blocks.push(
    { type: "input", block_id: "division", label: { type: "plain_text", text: "給与形態" }, element: {
      type: "static_select", action_id: "division", initial_option: { text: { type: "plain_text", text: "時給" }, value: "0" },
      options: [
        { text: { type: "plain_text", text: "時給" }, value: "0" },
        { text: { type: "plain_text", text: "日給（適用開始日は月初日）" }, value: "1" },
        { text: { type: "plain_text", text: "月給（適用開始日は月初日）" }, value: "2" },
      ],
    } },
    { type: "input", block_id: "date", label: { type: "plain_text", text: "適用開始日（初期値は入社日）" }, element: { type: "datepicker", action_id: "date", initial_date: initDate } },
    { type: "input", block_id: "wage", label: { type: "plain_text", text: "賃金（円）" }, element: { type: "number_input", action_id: "wage", is_decimal_allowed: false, min_value: "1", max_value: "100000000", placeholder: { type: "plain_text", text: "例: 1200" } } },
    { type: "context", elements: [{ type: "mrkdwn", text: "店舗別の時給・休日賃金は nippo の従業員ページ「💴 賃金設定」から入れてください。" }] },
  );
  return {
    type: "modal", callback_id: "hr.onboarding.wage.modal", private_metadata: JSON.stringify(meta),
    title: { type: "plain_text", text: "賃金の設定" }, submit: { type: "plain_text", text: "登録してスマレジに反映" }, close: { type: "plain_text", text: "やめる" },
    blocks,
  };
}

/** 適用開始日がスマレジ側の「初期設定」の日付に変わったとき（確認待ち）。確定か直すかを人が選ぶ */
export function wageDateAdjustedBlocks(wf: WorkflowView, notificationId: string | null, adjusted: { requested: string; applied: string; line: string }[], actorName: string) {
  const value = JSON.stringify({ workflow_id: wf.id, notification_id: notificationId, item_key: "wage" });
  const lines = adjusted.map((a) => `・${a.line}\n　　指定した適用開始日 ${jpDate(a.requested)} → スマレジに入った適用開始日 *${jpDate(a.applied)}*`).join("\n");
  return [
    { type: "section", text: { type: "mrkdwn", text: `🙋 *賃金はスマレジに保存されましたが、適用開始日が指定と違います*（${actorName}・${nowJst()}）\n${lines}\nスマレジが新しい従業員に自動で付ける「初期設定」の賃金行は適用開始時期を変えられないため、その日付で金額だけ更新されています。管理システム側の適用開始日もスマレジに合わせてあります。\nこの日付でよければ「確定」を、変えたい場合は「賃金を直す」（別の適用開始日で新しい行を追加）を押してください。` } },
    { type: "actions", block_id: "onboarding_wage_confirm", elements: [
      { type: "button", style: "primary", text: { type: "plain_text", text: "✅ この日付で確定", emoji: true }, action_id: "hr.onboarding.wage.confirm", value },
      { type: "button", text: { type: "plain_text", text: "💴 賃金を直す", emoji: true }, action_id: "hr.onboarding.wage", value },
    ] },
  ];
}

// =============================================================
// Phase 2（交通費）・Phase 3（UI ジョブ）・Phase 4（中止）の表示部品（2026-11-10）
// =============================================================
export const JUDGEMENT_LABEL: Record<string, string> = { auto_approvable: "自動承認できます", hq_review: "本部の確認が必要", person_review: "本人に確認が必要", search_failed: "経路検索ができません", approved: "承認済み", rejected: "差し戻し" };
export const PAY_TYPE_LABEL: Record<string, string> = { per_shift: "勤務回数ごと", per_day: "勤務日数ごと", monthly: "月額" };

/** 交通費の確認（経路候補・申請額・判定）。承認は人が押す */
export function commuteCheckBlocks(wf: WorkflowView, notificationId: string | null, c: {
  judgement: string; reasons: string[]; claimed: number | null; computed: { fare: number | null; summary: string; time_min: number | null; transfers: number | null } | null;
  reasonable: { fare: number | null; summary: string; time_min: number | null; transfers: number | null; uses_bus: boolean; teiki1?: number | null }[]; from: string; to: string; store_name?: string | null; method?: string | null; route_text?: string | null; uses_bus?: boolean | null;
  auto?: { mode: string; eligible: boolean; fare: number | null; reasons: string[] } | null;
  pay_hint?: { text: string } | null;
  pay_plan?: { text: string; policy: string; over_cap: boolean } | null; bus_allowed?: boolean;
}) {
  const value = JSON.stringify({ workflow_id: wf.id, notification_id: notificationId });
  const cands = c.reasonable.slice(0, 4).map((r, i) => `${i + 1}. ${r.summary}　${yen(r.fare)}／${r.time_min ?? "?"}分／乗換${r.transfers ?? "?"}${r.uses_bus ? "／バス" : ""}${r.teiki1 ? `／定期1か月 ${yen(r.teiki1)}` : ""}`).join("\n");
  const head = `🚃 *交通費の確認*（${c.from} → ${c.to}${c.store_name ? "・" + c.store_name : ""}）\n` +
    `本人の申告（参考）: *片道 ${c.claimed != null ? yen(c.claimed) : "なし"}*${c.method ? `／通勤手段: ${methodJa(c.method)}` : ""}${c.uses_bus ? "／バス利用" : ""}${c.route_text ? `\n本人の経路メモ: ${c.route_text.slice(0, 120)}` : ""}\n` +
    `検索の最安（合理的な経路）: *${c.computed ? yen(c.computed.fare) : "—"}*${c.pay_plan?.text ? `\n*支給額（会社ルール: IC・1 日上限あり）*\n${c.pay_plan.text}${c.bus_allowed ? "\n🚌 バス例外あり（バスを含めて検索）" : ""}` : c.pay_hint?.text ? `\n支給方法の目安: ${c.pay_hint.text}` : ""}\n判定（仮の基準）: *${JUDGEMENT_LABEL[c.judgement] ?? c.judgement}*\n${c.reasons.map((r) => "・" + r).join("\n")}`;
  const blocks: unknown[] = [
    { type: "section", text: { type: "mrkdwn", text: head } },
    ...(cands ? [{ type: "section", text: { type: "mrkdwn", text: "*経路の候補*\n" + cands } }] : []),
    { type: "actions", block_id: "onboarding_commute", elements: [
      // 2026-11-10 運用方針: 金額は会社のルール（IC 運賃）で本部が確定する。本人の申告額は参考（違うときだけ別ボタン）
      ...(c.computed?.fare != null ? [{ type: "button", style: "primary", text: { type: "plain_text", text: `✅ 経路を承認（IC 片道 ${yen(c.computed.fare)}）`, emoji: true }, action_id: "hr.onboarding.commute.approve_computed", value }] : []),
      ...(c.claimed != null && c.claimed !== c.computed?.fare ? [{ type: "button", ...(c.computed?.fare == null ? { style: "primary" } : {}), text: { type: "plain_text", text: `本人の申告額 ${yen(c.claimed)} で承認`, emoji: true }, action_id: "hr.onboarding.commute.approve", value }] : []),
      { type: "button", text: { type: "plain_text", text: "⚙️ 支給方法", emoji: true }, action_id: "hr.onboarding.commute.policy", value },
      { type: "button", text: { type: "plain_text", text: "🙋 本人に確認", emoji: true }, action_id: "hr.onboarding.commute.person", value },
      { type: "button", text: { type: "plain_text", text: "🔁 再検索", emoji: true }, action_id: "hr.onboarding.commute.research", value },
    ] },
    { type: "context", elements: [{ type: "mrkdwn", text: "最安というだけで否認はしません。承認すると次は「🚌 交通費を設定」（支給形態・適用開始日・金額）です。" }] },
  ];
  // 自動承認（既定 OFF＝記録だけ）: 有効化前は「もし有効なら自動承認したか」を参考表示する
  if (c.auto && c.auto.mode === "shadow") blocks.push({ type: "context", elements: [{ type: "mrkdwn", text: `🤖 自動承認（未有効化・記録のみ）: ${c.auto.eligible ? "条件を満たします" : "対象外"}　_${c.auto.reasons.slice(0, 3).join("／").slice(0, 200)}_` }] });
  return blocks;
}

/** 自動承認したときのスレッド投稿（取り消しボタン付き。2026-11-09・auto_approve.enabled=true のときだけ使われる） */
export function autoApprovedBlocks(wf: WorkflowView, notificationId: string | null, a: { fare: number; reasons: string[]; from: string; to: string; computed_fare: number | null }) {
  const value = JSON.stringify({ workflow_id: wf.id, notification_id: notificationId });
  return [
    { type: "section", text: { type: "mrkdwn", text: `🤖 *交通費を自動承認しました*（片道 *${yen(a.fare)}*・${nowJst()}）\n${a.from} → ${a.to}／API 算出額 ${a.computed_fare != null ? yen(a.computed_fare) : "—"}\n${a.reasons.map((r) => "・" + r).join("\n")}\n▶ 次: 親メッセージの「🚌 交通費を設定」` } },
    { type: "actions", block_id: "onboarding_commute_auto", elements: [
      { type: "button", text: { type: "plain_text", text: "↩️ 取り消して本部で確認", emoji: true }, action_id: "hr.onboarding.commute.undo", value, confirm: { title: { type: "plain_text", text: "自動承認の取り消し" }, text: { type: "plain_text", text: "承認を取り消し、「本部の確認が必要」に戻します" }, confirm: { type: "plain_text", text: "取り消す" }, deny: { type: "plain_text", text: "やめる" } } },
    ] },
  ];
}

// ---- 本人への連絡（Phase 2 後半・2026-11-09）。既定 person_notify_enabled=false＝文面をスレッドに出すだけ（人がコピーして送る） ----
export const CONTACT_KIND_LABEL: Record<string, string> = { commute_question: "交通費の経路確認", welcome: "入社手続きの案内（Slack/スマレジ登録のお願い）", stale_nudge: "手続きが止まっている人へのお願い", post_join_form: "扶養・年末調整フォームのお願い", custom: "自由入力" };
export const POST_JOIN_FORM_URL = "https://mirai-oss.github.io/nippo/?page=settings#postjoin";
/** 連絡文のひな型（個人情報は入れない。金額・経路メモ・氏名だけ） */
export function personContactTemplate(kind: string, ctx: { name: string; claimed?: number | null; computed?: number | null; route_text?: string | null; store_name?: string | null; stale_items?: string[]; nippo_url?: string; deadline?: string | null }): string {
  const n = ctx.name || "";
  const nippo = ctx.nippo_url ?? NIPPO_URL;
  switch (kind) {
    case "commute_question":
      return `${n}さん、お疲れさまです。N-Style 本部です。\n入社手続きの交通費について確認させてください。\n` +
        `ご申請の片道 ${ctx.claimed != null ? yen(ctx.claimed) : "（未記入）"}${ctx.route_text ? `（経路: ${ctx.route_text.slice(0, 80)}）` : ""} に対し、経路検索では片道 ${ctx.computed != null ? yen(ctx.computed) : "—"} の経路が見つかりました。\n` +
        `いつも使う経路（最寄り駅・乗る路線・乗換駅）と片道の金額を、この返信で教えてください。定期を使う場合はその旨もお願いします。`;
    case "welcome":
      return `${n}さん、入社手続きのご登録ありがとうございます。N-Style 本部です。\n次の 2 つをお願いします。\n` +
        `① Slack の登録: 届いている招待メールから参加してください（届いていなければ返信で教えてください）。\n` +
        `② スマレジ・タイムカードの登録: スマレジから届くメールの案内に沿って本人登録を済ませてください。\n` +
        `分からないことがあれば、このまま返信してください。`;
    case "post_join_form":
      return `${n}さん、お疲れさまです。N-Style 本部です。\n${ctx.stale_items && ctx.stale_items.length ? `${ctx.stale_items.join("・")}の情報の登録をお願いします` : "年末調整と扶養家族の情報の登録をお願いします"}（扶養家族がいない場合も「いない」で送ってください）。${ctx.deadline ? `社内の期限は ${ctx.deadline} です。` : ""}\n` +
        `▶ ${nippo.replace(/\/$/, "")}/?page=settings#postjoin（ログイン後の「設定」ページ）\n` +
        `スマレジ・タイムカードの画面と同じ項目です。5 分ほどで終わります。分からない項目はそのまま送って、返信で教えてください。`;
    case "stale_nudge":
      return `${n}さん、お疲れさまです。N-Style 本部です。\n入社手続きで止まっている項目があります: ${(ctx.stale_items ?? []).join("・") || "—"}\n` +
        `お手数ですが対応をお願いします。やり方が分からなければ返信で教えてください。`;
    default:
      return `${n}さん、お疲れさまです。N-Style 本部です。\n`;
  }
}
/** 本人連絡モーダル（種類・文面。送信先は本人の Slack（紐づけ済みなら）→ LINE（連携済みなら）の順） */
export function personContactModal(meta: { workflow_id: string; notification_id: string | null }, opts: { name: string; kind: string; text: string; channels: string[]; live: boolean }) {
  const options = Object.entries(CONTACT_KIND_LABEL).map(([v, t]) => ({ text: { type: "plain_text", text: t }, value: v }));
  const initial = options.find((o) => o.value === opts.kind) ?? options[0];
  return {
    type: "modal", callback_id: "hr.onboarding.contact.modal", private_metadata: JSON.stringify(meta),
    title: { type: "plain_text", text: "本人へ連絡" }, submit: { type: "plain_text", text: opts.live ? "送信する" : "文面を作る" }, close: { type: "plain_text", text: "やめる" },
    blocks: [
      { type: "section", text: { type: "mrkdwn", text: `*${opts.name}さん* への連絡。送信先: ${opts.channels.length ? opts.channels.join(" → ") : "（Slack も LINE も未連携＝文面だけ作ります）"}\n${opts.live ? "送信すると本人に届きます。" : "ℹ️ 本人への自動送信はまだ有効化されていません。文面をスレッドに出すので、コピーして送ってください。"}` } },
      { type: "input", block_id: "kind", label: { type: "plain_text", text: "種類（変えると文面のひな型が変わります。変えたあとは一度閉じて開き直してください）" }, element: { type: "static_select", action_id: "kind", initial_option: initial, options } },
      { type: "input", block_id: "text", label: { type: "plain_text", text: "文面（直して OK）" }, element: { type: "plain_text_input", action_id: "text", multiline: true, max_length: 1500, initial_value: opts.text } },
    ],
  };
}
/** 連絡の結果（スレッド） */
export function personContactResultBlocks(wf: WorkflowView, a: { kind: string; channel: string | null; sent: boolean; text: string; error?: string | null; actor: string }) {
  const head = a.sent ? `📨 *本人へ送信しました*（${a.channel}・${a.actor}・${nowJst()}）` : a.channel ? `📨 *本人への連絡文を作りました*（自動送信は未有効化。${a.channel} で送ってください・${a.actor}・${nowJst()}）` : `📨 *本人への連絡文を作りました*（Slack・LINE とも未連携。別の方法で送ってください・${a.actor}・${nowJst()}）`;
  return [
    { type: "section", text: { type: "mrkdwn", text: `${head}\n種類: ${CONTACT_KIND_LABEL[a.kind] ?? a.kind}${a.error ? `\n⚠️ ${a.error}` : ""}` } },
    { type: "section", text: { type: "mrkdwn", text: "```" + a.text.slice(0, 1800) + "```" } },
  ];
}

// ---- 停滞アラート（Phase 5・2026-11-09）。onboarding_alerts.enabled=false のあいだは送らず、結果だけ返す ----
export function staleAlertThreadText(items: { label: string; state: string; hours: number; last_error?: string | null }[], hireDate: string | null): string {
  const lines = items.map((i) => `・${i.label}: ${STATE_LABEL[i.state as ItemState] ?? i.state}（${Math.floor(i.hours)} 時間）${i.last_error ? `　_${String(i.last_error).slice(0, 60)}_` : ""}`);
  return `⏰ *入社手続きが止まっています*（入社日 ${jpDate(hireDate)}・${nowJst()}）\n${lines.join("\n")}\n▶ 担当の方は親メッセージのボタンから進めるか、本部タスクで ✓ を付けてください。`;
}
export function staleAlertSummaryBlocks(rows: { name: string; hire_date: string | null; items: string[]; hours: number; link?: string | null }[]) {
  const lines = rows.map((r) => `・*${r.name}*さん（入社日 ${jpDate(r.hire_date)}）: ${r.items.join("・")}　最長 ${Math.floor(r.hours)} 時間${r.link ? `　<${r.link}|従業員ページ>` : ""}`);
  return [
    { type: "section", text: { type: "mrkdwn", text: `⏰ *入社手続きの停滞一覧*（${rows.length} 人・${nowJst()}）\n${lines.join("\n").slice(0, 2800)}` } },
    { type: "context", elements: [{ type: "mrkdwn", text: "各人のスレッドにも同じ内容を出しています。止まっている理由が分かる場合はスレッドに書いてください。" }] },
  ];
}


/** 交通費の設定モーダル（支給形態・適用開始日・適用事業所・金額・上限） */
export function commuteSettingModal(meta: { workflow_id: string; user_id: string; notification_id: string | null; contract_id: string | null }, opts: {
  name: string; hire_date: string | null; approved_fare: number | null; stores: { id: string; name: string }[]; cap_default: number | null; cap_unit: string;
  plan?: { recommend?: { pay_type: string; amount: number; reason: string } | null; text?: string; monthly_cap?: number | null; monthly_cap_source?: string } | null;
}) {
  // 月額上限の初期値: 計算結果（支給方法・雇用区分・個別設定に連動）があればそれを使う。無ければ従来の既定（アルバイト 6,000）
  const capInit: number | null = opts.plan && opts.plan.monthly_cap_source ? (opts.plan.monthly_cap ?? null) : opts.cap_default;
  const PT: Record<string, string> = { per_shift: "勤務回数ごと", per_day: "勤務日数ごと", monthly: "月額" };
  const initType = opts.plan?.recommend?.pay_type && PT[opts.plan.recommend.pay_type] ? opts.plan.recommend.pay_type : "per_day";   // 会社の標準は「勤務日数ごと」（1 日あたり・上限 500 円）
  const initAmount = opts.plan?.recommend?.amount ?? (opts.approved_fare != null ? Math.min(opts.approved_fare * 2, 500) : null);
  const today = new Date(Date.now() + 9 * 3600e3).toISOString().slice(0, 10);
  const initDate = opts.hire_date && /^\d{4}-\d{2}-\d{2}$/.test(opts.hire_date) ? opts.hire_date : today;
  return {
    type: "modal", callback_id: "hr.onboarding.commute.set.modal", private_metadata: JSON.stringify(meta),
    title: { type: "plain_text", text: "交通費の設定" }, submit: { type: "plain_text", text: "登録してスマレジに反映" }, close: { type: "plain_text", text: "やめる" },
    blocks: [
      { type: "section", text: { type: "mrkdwn", text: `*${opts.name}さん* の交通費をスマレジに設定します（API では書けないため Mac の自動操作で反映。結果はスレッドに届きます）。${opts.approved_fare != null ? `\n承認済みの片道額: *${yen(opts.approved_fare)}*` : ""}${opts.plan?.text ? `\n${opts.plan.text}` : ""}${opts.plan?.recommend ? `\n▶ 初期値: ${PT[opts.plan.recommend.pay_type] ?? opts.plan.recommend.pay_type} ${yen(opts.plan.recommend.amount)}（${opts.plan.recommend.reason}）` : ""}` } },
      { type: "input", block_id: "pay_type", label: { type: "plain_text", text: "支給形態" }, element: { type: "static_select", action_id: "pay_type", initial_option: { text: { type: "plain_text", text: PT[initType] }, value: initType }, options: [
        { text: { type: "plain_text", text: "勤務日数ごと" }, value: "per_day" }, { text: { type: "plain_text", text: "勤務回数ごと" }, value: "per_shift" }, { text: { type: "plain_text", text: "月額" }, value: "monthly" } ] } },
      { type: "input", block_id: "date", label: { type: "plain_text", text: "適用開始日（初期値は入社日）" }, element: { type: "datepicker", action_id: "date", initial_date: initDate } },
      { type: "input", block_id: "scope", label: { type: "plain_text", text: "適用事業所" }, element: { type: "static_select", action_id: "scope", initial_option: { text: { type: "plain_text", text: "全事業所" }, value: "all" }, options: [
        { text: { type: "plain_text", text: "全事業所" }, value: "all" }, ...opts.stores.slice(0, 20).map((s) => ({ text: { type: "plain_text", text: `${s.name} だけ` }, value: `store:${s.id}` })) ] } },
      { type: "input", block_id: "amount", label: { type: "plain_text", text: "金額（円）。勤務日数ごと／回数ごと＝1 日（1 回）の往復額（上限適用後）、月額＝定期 1 か月分" }, element: { type: "number_input", action_id: "amount", is_decimal_allowed: false, min_value: "0", max_value: "999999", ...(initAmount != null ? { initial_value: String(initAmount) } : {}) } },
      { type: "input", optional: true, block_id: "cap", label: { type: "plain_text", text: `上限（円・任意${opts.cap_unit === "unknown" ? "。単位はスマレジ仕様の確認中" : opts.cap_unit === "month" ? "・月額" : "・1回"}）` }, element: { type: "number_input", action_id: "cap", is_decimal_allowed: false, min_value: "0", max_value: "999999", ...(capInit != null ? { initial_value: String(capInit) } : {}) } },
      { type: "input", optional: true, block_id: "note", label: { type: "plain_text", text: "メモ（任意）" }, element: { type: "plain_text_input", action_id: "note", max_length: 200 } },
    ],
  };
}

/** UI ジョブ（Mac の自動操作）の結果。失敗（打ち切り）なら再実行・手動対応のボタン */
export function uiJobResultBlocks(wf: WorkflowView, notificationId: string | null, job: { id: string; kind: string; status: string; attempts: number; max_attempts: number; error?: string | null; error_kind?: string | null; dry_run?: boolean }, verified: boolean | null, summary: string) {
  const value = JSON.stringify({ workflow_id: wf.id, notification_id: notificationId, job_id: job.id, kind: job.kind });
  const label: Record<string, string> = { smaregi_commute: "交通費", smaregi_tax: "源泉所得税", smaregi_payslip: "個別Web給与明細", smaregi_email: "メールアドレス", smaregi_read: "読み取り", smaregi_year_end: "年末調整", smaregi_dependents: "扶養家族", smaregi_store: "事業所" };
  const name = label[job.kind] ?? job.kind;
  if (job.status === "success") {
    return [{ type: "section", text: { type: "mrkdwn", text: `${verified === false ? "⚠️" : "✅"} *${name}をスマレジに${job.dry_run ? "読み取りました" : "設定しました"}*（自動操作・${nowJst()}）\n${summary}\n${verified === true ? "🔍 保存後にスマレジから読み直して一致を確認しました" : verified === false ? "⚠️ 保存後の読み直しで値が一致しません。スマレジ管理画面で確認してください" : "ℹ️ 照合は行っていません"}` } }];
  }
  const final = job.status === "failed";
  // 書き込み前の 3 点確認（契約ID・従業員ID・所属事業所）で中止したとき（2026-11-09 ユーザー指示）: 再試行ボタンは出さず手動対応へ
  if (final && job.error_kind === "screen_changed" && /^事前確認/.test(String(job.error ?? ""))) {
    return [{ type: "section", text: { type: "mrkdwn", text: `🛑 *${name}: 書き込み前の確認で中止しました*（契約／従業員ID／所属のどれかが一致せず・${nowJst()}）\n理由: ${String(job.error).slice(0, 300)}\n何も書き込んでいません。本部タスクに「手動対応」の工程を足しました。スマレジ側の契約・従業員・所属を確認してから、管理画面で入力してください（自動の再試行はしません）` } }];
  }
  return [
    { type: "section", text: { type: "mrkdwn", text: `${final ? "🙋" : "⏳"} *${name}の自動設定が${final ? "失敗しました（手動対応が必要）" : "失敗し、あとで再試行します"}*（${job.attempts}/${job.max_attempts} 回・${nowJst()}）\n理由: ${(job.error ?? "不明").slice(0, 300)}${job.error_kind ? `（${job.error_kind}）` : ""}${final ? "\n本部タスクに「手動対応」の工程を追加しました。スマレジ管理画面で設定したら、その工程を完了にしてください（GET で照合します）。" : ""}` } },
    ...(final ? [{ type: "actions", block_id: "onboarding_ui_retry", elements: [
      { type: "button", style: "primary", text: { type: "plain_text", text: "🔁 もう一度自動で試す", emoji: true }, action_id: "hr.onboarding.ui.retry", value },
    ] }] : []),
  ];
}

/** 入社手続き中止モーダル */
export function cancelModal(meta: { workflow_id: string; notification_id: string | null }, name: string) {
  return {
    type: "modal", callback_id: "hr.onboarding.cancel.modal", private_metadata: JSON.stringify(meta),
    title: { type: "plain_text", text: "入社手続きの中止" }, submit: { type: "plain_text", text: "中止する" }, close: { type: "plain_text", text: "やめる" },
    blocks: [
      { type: "section", text: { type: "mrkdwn", text: `*${name}さん* の入社手続きを中止します。未完了の項目と自動操作は止まります。スマレジの従業員は削除しません（必要なら管理画面で利用 OFF）。` } },
      { type: "input", block_id: "reason", label: { type: "plain_text", text: "理由" }, element: { type: "static_select", action_id: "reason", options: [
        { text: { type: "plain_text", text: "本人から入社辞退" }, value: "declined_by_person" }, { text: { type: "plain_text", text: "採用後連絡不通" }, value: "no_contact_after_hire" },
        { text: { type: "plain_text", text: "入社登録途中離脱" }, value: "dropped_during_registration" }, { text: { type: "plain_text", text: "会社都合中止" }, value: "company_reason" }, { text: { type: "plain_text", text: "その他" }, value: "other" } ] } },
      { type: "input", optional: true, block_id: "note", label: { type: "plain_text", text: "メモ（任意）" }, element: { type: "plain_text_input", action_id: "note", multiline: true, max_length: 300 } },
    ],
  };
}

/** 失敗時のスレッド投稿（再試行・賃金を直すボタン付き） */
export function wageFailedBlocks(wf: WorkflowView, notificationId: string | null, error: string, actorName: string) {
  const value = JSON.stringify({ workflow_id: wf.id, notification_id: notificationId, item_key: "wage" });
  return [
    { type: "section", text: { type: "mrkdwn", text: `⚠️ *賃金のスマレジ反映に失敗しました*（${actorName}・${nowJst()}）\n${error.slice(0, 600)}\n管理システムには保存済み（反映待ち）です。` } },
    { type: "actions", block_id: "onboarding_wage_retry", elements: [
      { type: "button", style: "primary", text: { type: "plain_text", text: "🔁 もう一度反映", emoji: true }, action_id: "hr.onboarding.retry", value },
      { type: "button", text: { type: "plain_text", text: "💴 賃金を直す", emoji: true }, action_id: "hr.onboarding.wage", value },
    ] },
  ];
}

// ---- Phase 6（2026-11-09）: 源泉所得税の設定モーダル（スマレジの「源泉所得税設定を追加」と同じ 4 項目・同じ文言）----
export function taxSettingModal(meta: { workflow_id: string; notification_id: string | null }, opts: { name: string; application_ym: string; tax_category: "kou" | "otsu"; spouse_division: number; dependents_count: number; note?: string | null }) {
  const spouseOpts = [
    { text: { type: "plain_text", text: "対象でない" }, value: "0" },
    { text: { type: "plain_text", text: "源泉控除対象(配偶者控除対象)" }, value: "1" },
    { text: { type: "plain_text", text: "源泉控除対象(配偶者特別控除対象)" }, value: "2" },
  ];
  const typeOpts = [{ text: { type: "plain_text", text: "甲" }, value: "kou" }, { text: { type: "plain_text", text: "乙" }, value: "otsu" }];
  return {
    type: "modal", callback_id: "hr.onboarding.tax.modal", private_metadata: JSON.stringify(meta),
    title: { type: "plain_text", text: "源泉所得税設定を追加" }, submit: { type: "plain_text", text: "追加してスマレジに反映" }, close: { type: "plain_text", text: "キャンセル" },
    blocks: [
      { type: "section", text: { type: "mrkdwn", text: `*${opts.name}さん* の源泉所得税（スマレジ・タイムカードの「源泉所得税設定を追加」と同じ項目です）${opts.note ? `\n${opts.note}` : ""}` } },
      { type: "input", block_id: "ym", label: { type: "plain_text", text: "適用開始月（例）2026/11）" }, element: { type: "plain_text_input", action_id: "ym", initial_value: opts.application_ym, placeholder: { type: "plain_text", text: "2026/11" }, max_length: 7 } },
      { type: "input", block_id: "type", label: { type: "plain_text", text: "区分" }, element: { type: "static_select", action_id: "type", initial_option: typeOpts[opts.tax_category === "otsu" ? 1 : 0], options: typeOpts } },
      { type: "input", block_id: "spouse", label: { type: "plain_text", text: "源泉控除対象配偶者区分" }, element: { type: "static_select", action_id: "spouse", initial_option: spouseOpts[[0, 1, 2].includes(opts.spouse_division) ? opts.spouse_division : 0], options: spouseOpts } },
      { type: "input", block_id: "dep", label: { type: "plain_text", text: "源泉控除対象親族の数（人）" }, element: { type: "number_input", action_id: "dep", is_decimal_allowed: false, min_value: "0", max_value: "20", initial_value: String(Math.max(0, opts.dependents_count | 0)) } },
      { type: "context", elements: [{ type: "mrkdwn", text: "初期値: 適用開始月＝入社月、配偶者区分＝本人提出の年末調整（配偶者あり→配偶者控除対象）、親族の数＝本人提出の扶養家族の人数。違っていれば直してください。" }] },
    ],
  };
}
/** 本人が年末調整／扶養家族を提出したときのスレッド投稿（個人情報なし）＋「承認してスマレジへ」「差し戻し」「スマレジと比較」ボタン（方針⑦: 承認後に反映） */
export function postJoinSubmittedBlocks(wf: WorkflowView, notificationId: string | null, kind: "year_end" | "dependents", info: { count?: number | null; relationships?: number[] | null; spouse_flag?: boolean | null; student_flag?: boolean | null; via?: string | null; target_year?: number | null; policy?: PostJoinTrack | null; status?: string | null }) {
  const value = JSON.stringify({ workflow_id: wf.id, notification_id: notificationId, track: kind, target_year: info.target_year ?? null });
  const rel = Array.isArray(info.relationships) && info.relationships.length ? info.relationships.map((r) => RELATIONSHIP_LABEL[r] ?? r).join("・") : "";
  const pol = info.policy ? `（${postJoinPolicyText(info.policy)}）` : "";
  const head = kind === "year_end"
    ? `📝 *本人が年末調整${info.target_year ? ` ${info.target_year} 年度` : ""}の情報を提出しました*${pol}（${nowJst()}）\n配偶者: ${info.spouse_flag ? "あり" : "なし"}／勤労学生: ${info.student_flag ? "該当" : "該当しない"}（金額などは nippo の従業員編集で確認）`
    : info.count ? `📝 *本人が扶養家族を提出しました*${pol}（${info.count} 人・${rel}・${nowJst()}）\n氏名・住所は nippo の従業員編集で確認（Slack には出しません）` : `📝 *本人が「扶養家族なし」で提出しました*${pol}（${nowJst()}）`;
  const blocks: unknown[] = [{ type: "section", text: { type: "mrkdwn", text: head } }];
  const st = info.status ?? "submitted";
  if (st === "submitted" && (kind === "year_end" || info.count)) {
    blocks.push({ type: "actions", block_id: `onboarding_post_join_${kind}`, elements: [
      { type: "button", style: "primary", text: { type: "plain_text", text: "✅ 承認してスマレジへ", emoji: true }, action_id: `hr.onboarding.${kind === "year_end" ? "yearend" : "dependents"}.approve`, value },
      { type: "button", text: { type: "plain_text", text: "↩️ 差し戻し", emoji: true }, action_id: `hr.onboarding.${kind === "year_end" ? "yearend" : "dependents"}.reject`, value },
      { type: "button", text: { type: "plain_text", text: "🔎 スマレジと比較", emoji: true }, action_id: `hr.onboarding.${kind === "year_end" ? "yearend" : "dependents"}.compare`, value },
      ...(kind === "dependents" ? [{ type: "button", text: { type: "plain_text", text: "🧾 源泉所得税を更新", emoji: true }, action_id: "hr.onboarding.tax", value }] : []),
    ] });
  } else if (st === "approved" || st === "error") {
    blocks.push({ type: "actions", block_id: `onboarding_post_join_${kind}_sync`, elements: [
      { type: "button", style: "primary", text: { type: "plain_text", text: kind === "year_end" ? "🧾 年末調整をスマレジに反映" : "👪 扶養家族をスマレジに反映", emoji: true }, action_id: kind === "year_end" ? "hr.onboarding.yearend.sync" : "hr.onboarding.dependents.sync", value },
      { type: "button", text: { type: "plain_text", text: "↩️ 差し戻し", emoji: true }, action_id: `hr.onboarding.${kind === "year_end" ? "yearend" : "dependents"}.reject`, value },
    ] });
  } else if (st === "none") {
    blocks.push({ type: "context", elements: [{ type: "mrkdwn", text: "扶養なしのためスマレジへの反映はありません。源泉所得税の「親族の数」は 0 のままで OK です。" }] });
  }
  return blocks;
}
/** 年末調整: 本人提出とスマレジ（API）の差分表示（金額・区分だけ。氏名は出さない） */
export function yearEndCompareText(submitted: Record<string, unknown>, smaregi: Record<string, unknown> | null): string {
  if (!smaregi) return "スマレジ側の値を読めませんでした";
  const rows: [string, unknown, unknown][] = [
    ["配偶者の有無", submitted.spouse_flag ? "あり" : "なし", smaregi.spouseFlag ? "あり" : "なし"],
    ["合計所得見積額", yen(submitted.estimate_income ?? 0), yen(smaregi.estimateIncome ?? 0)],
    ["退職所得", yen(submitted.retirement_income ?? 0), yen(smaregi.retirementIncome ?? 0)],
    ["障害者", submitted.handicapped_division, smaregi.handicappedDivision],
    ["寡婦/ひとり親", submitted.widow_division2, smaregi.widowDivision2],
    ["勤労学生", submitted.student_flag ? "該当" : "該当しない", smaregi.studentFlag ? "該当" : "該当しない"],
    ["世帯主 続柄", submitted.household_header_relationship != null ? RELATIONSHIP_LABEL[Number(submitted.household_header_relationship)] ?? submitted.household_header_relationship : "—", smaregi.householdHeaderRelationship != null ? RELATIONSHIP_LABEL[Number(smaregi.householdHeaderRelationship)] ?? smaregi.householdHeaderRelationship : "—"],
  ];
  return rows.map(([k, a, b]) => `${String(a) === String(b) ? "・" : "⚠️"} ${k}: 提出 ${a} ／ スマレジ ${b}`).join("\n");
}

/** 支給方法（個別設定）のモーダル（2026-11-10・会社ルール）: 基本は 1 日上限 500 円。超える人は定期代支給か全額支給。月の出勤日数の見込み・バス例外。理由つきで履歴に残る */
export function commutePolicyModal(meta: { workflow_id: string; user_id: string; notification_id: string | null }, opts: { name: string; policy: string; bus_exception: boolean; cap: number; plan_text?: string | null; bus_request?: string | null; monthly_cap_override?: number | null; standard_note?: string }) {
  const options = [
    { text: { type: "plain_text", text: `1 日上限 ${yen(opts.cap)}（往復・基本）` }, value: "daily_cap" },
    { text: { type: "plain_text", text: "定期代支給（月額・本部承認）" }, value: "teiki" },
    { text: { type: "plain_text", text: "全額支給（1 日上限なし・本部承認）" }, value: "full" },
  ];
  return {
    type: "modal", callback_id: "hr.onboarding.commute.policy.modal", private_metadata: JSON.stringify(meta),
    title: { type: "plain_text", text: "交通費の支給方法" }, submit: { type: "plain_text", text: "保存して再計算" }, close: { type: "plain_text", text: "やめる" },
    blocks: [
      { type: "section", text: { type: "mrkdwn", text: `*${opts.name}さん* の支給方法を決めます。基本は「1 日上限 ${yen(opts.cap)}（往復）」。支給方法と金額を決められるのは本部だけです（従業員は選べません）。定期代支給・全額支給・バス例外は理由が必要で、履歴に残ります。保存すると経路を再検索して計算し直します。${opts.bus_request ? `\n🚌 本人からのバス利用の申請: ${opts.bus_request.slice(0, 200)}` : ""}${opts.plan_text ? `\n_いまの計算_\n${opts.plan_text}` : ""}` } },
      { type: "input", block_id: "policy", label: { type: "plain_text", text: "支給方法" }, element: { type: "static_select", action_id: "policy", initial_option: options.find((o) => o.value === opts.policy) ?? options[0], options } },
      { type: "input", optional: true, block_id: "mcap", label: { type: "plain_text", text: "月額上限の個別設定（円・空欄＝標準）" }, hint: { type: "plain_text", text: opts.standard_note ?? "標準: アルバイトの基本＝6,000 円／社員の基本＝なし／定期代・全額支給＝なし。入力するとその金額がスマレジの月額上限になります（理由必須）" }, element: { type: "number_input", action_id: "mcap", is_decimal_allowed: false, min_value: "0", max_value: "999999", ...(opts.monthly_cap_override != null ? { initial_value: String(opts.monthly_cap_override) } : {}) } },
      { type: "input", optional: true, block_id: "bus", label: { type: "plain_text", text: "バス（原則は認めない。本人の理由申請を確認して承認）" }, element: { type: "checkboxes", action_id: "bus", options: [{ text: { type: "plain_text", text: "この人はバス利用を例外として認める" }, value: "yes" }], ...(opts.bus_exception ? { initial_options: [{ text: { type: "plain_text", text: "この人はバス利用を例外として認める" }, value: "yes" }] } : {}) } },
      { type: "input", optional: true, block_id: "reason", label: { type: "plain_text", text: "理由（基本ルールと違う扱いにするときは必須）" }, element: { type: "plain_text_input", action_id: "reason", max_length: 200 } },
    ],
  };
}
