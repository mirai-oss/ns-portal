// 給与振込の自動照合・第 1 段階（マネーフォワードの総額照合）の「判定だけ」の部品（下書き・2026-11-13）
//   ここには通信も DB も無い（純粋な関数だけ）。Edge Function payroll-transfer-recon から使う。
//   決まり:
//     ・候補＝摘要に「WEB総振」（全角・半角・空白のゆれは吸収）を含み、取引日が振込指定日の前後 windowDays 日以内の、預金からの出金。
//     ・「記録してよい」のは、登録した出金口座からの出金で、金額がバッチの合計とぴったり同じ候補が、ちょうど 1 件で、その取引日が振込指定日と同じときだけ。
//     ・0 件・2 件以上・出金口座が未登録・口座が違う・金額が合わない（手数料が混ざっている疑いを含む）・日付がずれている → 記録しない（理由を返す）。
//     ・総額が合っても、従業員ごとの行は完了にしない（それは DB の決まり。ここは「どの出金を記録するか」だけを決める）。
//   金額・摘要をログに出す処理は、この部品にも呼ぶ側にも置かない。

/** 預金からの出金 1 行（fetchOutflows の結果に、預金側の「科目名/補助科目名」と、仕訳の中の順番を足したもの） */
export type MfOutflow = {
  journal_id: string;
  branch_no: number;          // 同じ仕訳の中で、預金からの出金の行の何番目か（0 始まり）
  transaction_date: string;   // YYYY-MM-DD
  amount: number;
  deposit_account: string;    // 預金側の「科目名/補助科目名」（補助科目が無ければ科目名だけ）
  remark: string;
};

export type BatchForMf = {
  batch_id: string;
  scheduled_date: string;     // 振込指定日 YYYY-MM-DD
  expected_total: number;     // 振込予定の合計
  expected_count?: number;    // 振込予定の人数（手数料の疑いの目安にだけ使う）
};

export type MfReason =
  | "matched_one"                      // 記録してよい（ちょうど 1 件）
  | "no_candidate"                     // 「WEB総振」の出金が、期間内に 1 件も無い（まだ仕訳になっていないことがある）
  | "deposit_account_not_configured"   // その法人の出金口座（預金名）が設定に登録されていない
  | "deposit_account_mismatch"         // 「WEB総振」の出金はあるが、登録した出金口座からではない
  | "amount_mismatch"                  // 登録した口座からの出金はあるが、金額が合わない
  | "amount_mismatch_fee_suspected"    // 出金のほうが少しだけ多い（振込手数料が同じ出金に混ざっている疑い）
  | "multiple_candidates"              // 金額がぴったりの候補が 2 件以上（どれか決められない）
  | "date_mismatch"                    // 金額がぴったりの候補は 1 件だが、取引日が振込指定日と違う
  | "invalid_batch";                   // バッチの日付・合計が読めない

export type MfCandidate = MfOutflow & {
  account_ok: boolean;        // 登録した出金口座からの出金か
  amount_exact: boolean;      // 金額がバッチの合計とぴったり同じか
  date_exact: boolean;        // 取引日が振込指定日と同じか
  diff: number;               // 出金額 − バッチの合計
  day_diff: number;           // 取引日 − 振込指定日（日）
  registered_account: string | null;   // 一致した「登録名」（DB へ渡すのはこの書き方）
};

export type MfJudgement = {
  decision: "record" | "none";
  reason: MfReason;
  pick: MfCandidate | null;   // decision = "record" のときだけ
  candidates: MfCandidate[];  // 「WEB総振」＋期間内の候補すべて（試し実行で返す用）
  counts: { webSofuri: number; accountOk: number; exact: number };
};

const DAY = 86400e3;
export const WEB_SOFURI = "WEB総振";
/** 摘要をそろえる（全角・半角をそろえ、大文字にし、空白を取る）。DB の payroll_recon_kana_norm と同じ考え方 */
export const normRemark = (t: unknown): string => String(t ?? "").normalize("NFKC").toUpperCase().replace(/\s+/g, "");
/** 摘要が「WEB総振」を含むか（ＷＥＢ総振・Web 総振・ｗｅｂ総振 なども拾う） */
export const isWebSofuri = (remark: unknown): boolean => normRemark(remark).includes(WEB_SOFURI);
/** 預金の名前をそろえる（全角・半角と空白の違いだけを無くす。大文字・小文字はそのまま） */
export const normAccount = (t: unknown): string => String(t ?? "").normalize("NFKC").replace(/\s+/g, "");

const isYmd = (s: unknown): s is string => typeof s === "string" && /^\d{4}-\d{2}-\d{2}$/.test(s) && !isNaN(Date.parse(s));
const dayDiff = (a: string, b: string) => Math.round((Date.parse(a) - Date.parse(b)) / DAY);

/** 候補を探す期間（振込指定日の前後 windowDays 日） */
export function scanRange(scheduledDate: string, windowDays = 3): { start: string; end: string } {
  const t = Date.parse(scheduledDate), w = Math.max(0, Math.floor(windowDays));
  return { start: new Date(t - w * DAY).toISOString().slice(0, 10), end: new Date(t + w * DAY).toISOString().slice(0, 10) };
}

/**
 * fetchOutflows（既存・変更なし）の 1 行から、預金側の「科目名/補助科目名」を取り出す。
 * 既存の関数は相手側の補助科目しか返さないが、summary（dir="out" のとき「相手側 ／ 預金側」）の後ろ半分に、預金側の「科目名/補助科目名 金額円」が入っている。
 * 取り出せないときは ""（＝口座が分からない → 登録名と一致しないので、記録されない）。
 */
export function depositAccountFromSummary(summary: unknown): string {
  const s = String(summary ?? ""), i = s.lastIndexOf(" ／ ");
  if (i < 0) return "";
  const m = s.slice(i + 3).match(/^(.*\S)\s+-?[\d,.\s  ]+円$/);
  return m ? m[1].trim() : "";
}

/** fetchOutflows の結果を、照合用の形にする（預金側の名前と、同じ仕訳の中の順番を足す）。既存の関数・型は変えない */
export function toMfOutflows(outflows: { journal_id: string; transaction_date: string; amount: number; remark: string; summary: string }[]): MfOutflow[] {
  const seen = new Map<string, number>();
  return outflows.map((o) => {
    const n = seen.get(o.journal_id) ?? 0; seen.set(o.journal_id, n + 1);
    return { journal_id: String(o.journal_id), branch_no: n, transaction_date: o.transaction_date, amount: Number(o.amount), deposit_account: depositAccountFromSummary(o.summary), remark: o.remark ?? "" };
  });
}

/**
 * バッチ 1 つと、MF の出金の一覧を比べて、「どの出金を総額照合として記録してよいか」を決める。
 * depositAccounts＝その法人の出金口座として登録した預金名（app_settings.payroll_transfer_recon.corps.<法人 ID>.mf_deposit_accounts）。
 */
export function judgeMfTotal(batch: BatchForMf, outflows: MfOutflow[], opts: { depositAccounts?: unknown; windowDays?: number } = {}): MfJudgement {
  const none = (reason: MfReason, candidates: MfCandidate[] = [], counts = { webSofuri: 0, accountOk: 0, exact: 0 }): MfJudgement => ({ decision: "none", reason, pick: null, candidates, counts });
  const total = Number(batch?.expected_total);
  if (!batch || !isYmd(batch.scheduled_date) || !Number.isFinite(total) || !(total > 0)) return none("invalid_batch");
  const windowDays = Math.max(0, Math.floor(Number.isFinite(Number(opts.windowDays)) ? Number(opts.windowDays) : 3));
  const registered = (Array.isArray(opts.depositAccounts) ? opts.depositAccounts : []).filter((x): x is string => typeof x === "string" && x.trim() !== "");
  const regByNorm = new Map(registered.map((r) => [normAccount(r), r]));

  const candidates: MfCandidate[] = [];
  for (const o of outflows ?? []) {
    const amount = Number(o?.amount);
    if (!o || !isYmd(o.transaction_date) || !Number.isFinite(amount) || !(amount > 0) || !o.journal_id) continue;
    if (!isWebSofuri(o.remark)) continue;
    const dd = dayDiff(o.transaction_date, batch.scheduled_date);
    if (Math.abs(dd) > windowDays) continue;
    const reg = o.deposit_account ? (regByNorm.get(normAccount(o.deposit_account)) ?? null) : null;
    candidates.push({ ...o, amount, account_ok: reg !== null, amount_exact: amount === total, date_exact: dd === 0, diff: amount - total, day_diff: dd, registered_account: reg });
  }
  candidates.sort((a, b) => Math.abs(a.day_diff) - Math.abs(b.day_diff) || Math.abs(a.diff) - Math.abs(b.diff) || a.journal_id.localeCompare(b.journal_id) || a.branch_no - b.branch_no);

  const accountOk = candidates.filter((c) => c.account_ok);
  const exact = accountOk.filter((c) => c.amount_exact);
  const counts = { webSofuri: candidates.length, accountOk: accountOk.length, exact: exact.length };

  if (registered.length === 0) return none("deposit_account_not_configured", candidates, counts);
  if (candidates.length === 0) return none("no_candidate", candidates, counts);
  if (accountOk.length === 0) return none("deposit_account_mismatch", candidates, counts);
  if (exact.length === 0) {
    // 出金のほうが少しだけ多い＝手数料が同じ出金に混ざっている疑い（目安: 1 人あたり 1,000 円まで。人数が分からないときは合計の 2% まで）
    const cap = Number(batch.expected_count) > 0 ? Number(batch.expected_count) * 1000 : total * 0.02;
    const fee = accountOk.some((c) => c.diff > 0 && c.diff <= cap);
    return none(fee ? "amount_mismatch_fee_suspected" : "amount_mismatch", candidates, counts);
  }
  if (exact.length >= 2) return none("multiple_candidates", candidates, counts);
  const pick = exact[0];
  if (!pick.date_exact) return none("date_mismatch", candidates, counts);
  return { decision: "record", reason: "matched_one", pick, candidates, counts };
}

/** 理由を、やさしい言葉にする（画面・返り値用。金額は入れない） */
export function reasonText(reason: string): string {
  switch (reason) {
    case "matched_one": return "合計がぴったり同じ出金が 1 件だけ見つかりました";
    case "no_candidate": return "マネーフォワードに「WEB総振」の出金が、まだ見つかりません（銀行の明細が仕訳になるまで待ちます）";
    case "deposit_account_not_configured": return "この法人の出金口座（預金の名前）が、まだ設定に登録されていません";
    case "deposit_account_mismatch": return "「WEB総振」の出金はありますが、登録した出金口座からの出金ではありません";
    case "amount_mismatch": return "出金はありますが、金額が振込予定の合計と合いません";
    case "amount_mismatch_fee_suspected": return "出金のほうが少しだけ多いです（振込手数料が同じ出金に入っているかもしれません）。自動では記録しません";
    case "multiple_candidates": return "合計がぴったり同じ出金が 2 件以上あります。どれか決められないので、自動では記録しません";
    case "date_mismatch": return "合計が同じ出金は 1 件ありますが、日付が振込指定日と違います。自動では記録しません";
    case "invalid_batch": return "振込バッチの日付か合計が読めません";
    case "mf_journal_used_by_other_batch": return "この出金は、すでに別の振込バッチの照合に使われています";
    case "tenant_unknown": return "この法人が、マネーフォワードのどの事業者か分かりません（設定が必要です）";
    case "mf_fetch_failed": return "マネーフォワードの仕訳を読めませんでした";
    case "db_error": return "記録のときにエラーになりました";
    default: return reason;
  }
}
