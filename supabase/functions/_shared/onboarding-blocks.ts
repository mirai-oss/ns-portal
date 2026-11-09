// 入社登録ワークフロー（Slack 一元管理 Phase 1・2026-11-09）の Slack 表示部品。
// onboarding-notify（親メッセージの作成・更新・スレッド投稿）から使う。業務ロジックは持たない（表示だけ）。
// 個人情報の扱い（ユーザー指示）: 住所・電話・生年月日・税情報は出さない。出すのは 氏名・区分・所属・入社日・スマレジ契約/ID・各項目の状態 だけ。

export type ItemState = "pending" | "running" | "completed" | "retry_wait" | "manual_required" | "manual_running" | "cancelled" | "failed";
export type ItemInfo = { state: ItemState; attempts?: number; last_error?: string | null; payload?: any; completed_at?: string | null; completion_source?: string | null };
export type WorkflowView = {
  id: string; user_id: string | null; status: string; hire_date: string | null; role: string | null;
  contract_id: string | null; contract_label: string | null; smaregi_staff_id: string | null; hq_task_id: string | null;
  user_name: string | null; store_names: string | null; items: Record<string, ItemInfo> | null;
  cancelled_reason?: string | null; completed_at?: string | null;
};

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
    if (st === "failed" && it?.last_error) extra = `　_${String(it.last_error).slice(0, 80)}_`;
    if (st === "pending" && ["commute_set", "withholding_tax", "web_payslip"].includes(key)) extra = "　_（今は手作業。本部タスクの ✓ で反映）_";
    else if (st === "pending" && key === "email") extra = "　_（今は手作業。本部タスク工程①の完了で反映）_";
    else if (st === "pending" && phase > 1) extra = "　_（Phase 2 以降で自動化）_";
    return `${emoji} ${label}${extra}`;
  });
  const value = JSON.stringify({ workflow_id: wf.id, notification_id: notificationId });
  const blocks: unknown[] = [
    { type: "header", text: { type: "plain_text", text: `🧑‍💼 入社登録：${name}さん`, emoji: true } },
    { type: "section", fields: [
      { type: "mrkdwn", text: `*区分*\n${kind || "—"}` },
      { type: "mrkdwn", text: `*所属*\n${stores}` },
      { type: "mrkdwn", text: `*入社日*\n${jpDate(wf.hire_date)}` },
      { type: "mrkdwn", text: `*スマレジ*\n${wf.contract_label ?? wf.contract_id ?? "契約未定"}${wf.smaregi_staff_id ? `／従業員ID ${wf.smaregi_staff_id}` : "／未作成"}` },
    ] },
    { type: "section", text: { type: "mrkdwn", text: `*${statusText}*\n${lines.join("\n")}` } },
  ];
  if (wf.status !== "cancelled") {
    const actions: unknown[] = [
      { type: "button", style: "primary", text: { type: "plain_text", text: "💴 賃金を設定", emoji: true }, action_id: "hr.onboarding.wage", value },
      { type: "button", text: { type: "plain_text", text: "🔄 表示を更新", emoji: true }, action_id: "hr.onboarding.refresh", value },
    ];
    // URL ボタンも押下通知が slack-interact に届く（action_id は同じブロック内で一意にする必要がある→ .nippo / .task）
    if (wf.user_id) actions.push({ type: "button", text: { type: "plain_text", text: "従業員ページ", emoji: true }, action_id: "hr.onboarding.link.nippo", url: `${NIPPO_URL}?page=admin&u=${wf.user_id}`, value });
    if (wf.hq_task_id) actions.push({ type: "button", text: { type: "plain_text", text: "本部タスク", emoji: true }, action_id: "hr.onboarding.link.task", url: `${TASKS_URL}?task=${wf.hq_task_id}`, value });
    blocks.push({ type: "actions", block_id: "onboarding_actions", elements: actions });
  }
  blocks.push({ type: "context", elements: [{ type: "mrkdwn", text: `進捗・結果・エラーはこのスレッドに届きます。ワークフロー \`${wf.id.slice(0, 8)}\`・更新 ${nowJst()}` }] });
  return { text: `入社登録：${name}さん（${kind}／${stores}）${wf.status === "completed" ? " 完了" : ""}`, blocks };
}

/** 賃金モーダル。contracts が 2 つ以上のときだけ契約の選択を出す */
export function wageModal(meta: { workflow_id: string; user_id: string; notification_id: string | null }, opts: {
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
