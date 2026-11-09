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
    if ((st === "failed" || st === "manual_required") && it?.last_error) extra = `　_${String(it.last_error).slice(0, 80)}_`;
    if (st === "pending" && ["commute_set", "withholding_tax", "web_payslip"].includes(key)) extra = "　_（今は手作業。本部タスクの ✓ で反映）_";
    else if (st === "pending" && key === "email") extra = "　_（今は手作業。本部タスク工程①の完了で反映）_";
    else if (st === "pending" && key === "smaregi_account") extra = "　_（「🔎 スマレジ照合」で確認。API に項目が無いため管理画面の読み取りが要ります）_";
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
      { type: "button", text: { type: "plain_text", text: "🚌 交通費を設定", emoji: true }, action_id: "hr.onboarding.commute.set", value },
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
  return { text: `入社登録：${name}さん（${kind}／${stores}）${wf.status === "completed" ? " 完了" : ""}`, blocks };
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
}) {
  const value = JSON.stringify({ workflow_id: wf.id, notification_id: notificationId });
  const cands = c.reasonable.slice(0, 4).map((r, i) => `${i + 1}. ${r.summary}　${yen(r.fare)}／${r.time_min ?? "?"}分／乗換${r.transfers ?? "?"}${r.uses_bus ? "／バス" : ""}${r.teiki1 ? `／定期1か月 ${yen(r.teiki1)}` : ""}`).join("\n");
  const head = `🚃 *交通費の確認*（${c.from} → ${c.to}${c.store_name ? "・" + c.store_name : ""}）\n` +
    `本人の申請: *片道 ${c.claimed != null ? yen(c.claimed) : "未申請"}*${c.method ? `／通勤手段: ${c.method}` : ""}${c.uses_bus ? "／バス利用" : ""}${c.route_text ? `\n本人の経路メモ: ${c.route_text.slice(0, 120)}` : ""}\n` +
    `検索の最安（合理的な経路）: *${c.computed ? yen(c.computed.fare) : "—"}*\n判定（仮の基準）: *${JUDGEMENT_LABEL[c.judgement] ?? c.judgement}*\n${c.reasons.map((r) => "・" + r).join("\n")}`;
  const blocks: unknown[] = [
    { type: "section", text: { type: "mrkdwn", text: head } },
    ...(cands ? [{ type: "section", text: { type: "mrkdwn", text: "*経路の候補*\n" + cands } }] : []),
    { type: "actions", block_id: "onboarding_commute", elements: [
      { type: "button", style: "primary", text: { type: "plain_text", text: c.claimed != null ? `✅ 申請額 ${yen(c.claimed)} で承認` : "✅ 承認（金額を入力）", emoji: true }, action_id: "hr.onboarding.commute.approve", value },
      ...(c.computed?.fare != null && c.claimed != null && c.computed.fare !== c.claimed ? [{ type: "button", text: { type: "plain_text", text: `✅ 検索額 ${yen(c.computed.fare)} で承認`, emoji: true }, action_id: "hr.onboarding.commute.approve_computed", value }] : []),
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
export const CONTACT_KIND_LABEL: Record<string, string> = { commute_question: "交通費の経路確認", welcome: "入社手続きの案内（Slack/スマレジ登録のお願い）", stale_nudge: "手続きが止まっている人へのお願い", custom: "自由入力" };
/** 連絡文のひな型（個人情報は入れない。金額・経路メモ・氏名だけ） */
export function personContactTemplate(kind: string, ctx: { name: string; claimed?: number | null; computed?: number | null; route_text?: string | null; store_name?: string | null; stale_items?: string[]; nippo_url?: string }): string {
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
}) {
  const today = new Date(Date.now() + 9 * 3600e3).toISOString().slice(0, 10);
  const initDate = opts.hire_date && /^\d{4}-\d{2}-\d{2}$/.test(opts.hire_date) ? opts.hire_date : today;
  return {
    type: "modal", callback_id: "hr.onboarding.commute.set.modal", private_metadata: JSON.stringify(meta),
    title: { type: "plain_text", text: "交通費の設定" }, submit: { type: "plain_text", text: "登録してスマレジに反映" }, close: { type: "plain_text", text: "やめる" },
    blocks: [
      { type: "section", text: { type: "mrkdwn", text: `*${opts.name}さん* の交通費をスマレジに設定します（API では書けないため Mac の自動操作で反映。結果はスレッドに届きます）。${opts.approved_fare != null ? `\n承認済みの片道額: *${yen(opts.approved_fare)}*` : ""}` } },
      { type: "input", block_id: "pay_type", label: { type: "plain_text", text: "支給形態" }, element: { type: "static_select", action_id: "pay_type", initial_option: { text: { type: "plain_text", text: "勤務回数ごと" }, value: "per_shift" }, options: [
        { text: { type: "plain_text", text: "勤務回数ごと" }, value: "per_shift" }, { text: { type: "plain_text", text: "勤務日数ごと" }, value: "per_day" }, { text: { type: "plain_text", text: "月額" }, value: "monthly" } ] } },
      { type: "input", block_id: "date", label: { type: "plain_text", text: "適用開始日（初期値は入社日）" }, element: { type: "datepicker", action_id: "date", initial_date: initDate } },
      { type: "input", block_id: "scope", label: { type: "plain_text", text: "適用事業所" }, element: { type: "static_select", action_id: "scope", initial_option: { text: { type: "plain_text", text: "全事業所" }, value: "all" }, options: [
        { text: { type: "plain_text", text: "全事業所" }, value: "all" }, ...opts.stores.slice(0, 20).map((s) => ({ text: { type: "plain_text", text: `${s.name} だけ` }, value: `store:${s.id}` })) ] } },
      { type: "input", block_id: "amount", label: { type: "plain_text", text: "金額（円）。勤務回数ごと＝往復額、月額＝1か月分" }, element: { type: "number_input", action_id: "amount", is_decimal_allowed: false, min_value: "0", max_value: "999999", ...(opts.approved_fare != null ? { initial_value: String(opts.approved_fare * 2) } : {}) } },
      { type: "input", optional: true, block_id: "cap", label: { type: "plain_text", text: `上限（円・任意${opts.cap_unit === "unknown" ? "。単位はスマレジ仕様の確認中" : opts.cap_unit === "month" ? "・月額" : "・1回"}）` }, element: { type: "number_input", action_id: "cap", is_decimal_allowed: false, min_value: "0", max_value: "999999", ...(opts.cap_default != null ? { initial_value: String(opts.cap_default) } : {}) } },
      { type: "input", optional: true, block_id: "note", label: { type: "plain_text", text: "メモ（任意）" }, element: { type: "plain_text_input", action_id: "note", max_length: 200 } },
    ],
  };
}

/** UI ジョブ（Mac の自動操作）の結果。失敗（打ち切り）なら再実行・手動対応のボタン */
export function uiJobResultBlocks(wf: WorkflowView, notificationId: string | null, job: { id: string; kind: string; status: string; attempts: number; max_attempts: number; error?: string | null; error_kind?: string | null; dry_run?: boolean }, verified: boolean | null, summary: string) {
  const value = JSON.stringify({ workflow_id: wf.id, notification_id: notificationId, job_id: job.id, kind: job.kind });
  const label: Record<string, string> = { smaregi_commute: "交通費", smaregi_tax: "源泉所得税", smaregi_payslip: "個別Web給与明細", smaregi_email: "メールアドレス", smaregi_read: "読み取り" };
  const name = label[job.kind] ?? job.kind;
  if (job.status === "success") {
    return [{ type: "section", text: { type: "mrkdwn", text: `${verified === false ? "⚠️" : "✅"} *${name}をスマレジに${job.dry_run ? "読み取りました" : "設定しました"}*（自動操作・${nowJst()}）\n${summary}\n${verified === true ? "🔍 保存後にスマレジから読み直して一致を確認しました" : verified === false ? "⚠️ 保存後の読み直しで値が一致しません。スマレジ管理画面で確認してください" : "ℹ️ 照合は行っていません"}` } }];
  }
  const final = job.status === "failed";
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
