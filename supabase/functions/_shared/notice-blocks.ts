// =============================================================
// Slack 通知の共通の形（2026-11-12）: 親メッセージは 2 行、詳細・操作・履歴はスレッド
//   設計: docs/設計書_Slack通知の共通フォーマット_2026-11-11.md
//   ここは「文面を組み立てるだけ」の部品（DB にも Slack にも触らない＝単体でテストできる）。
//   親メッセージには 種別・日付・店舗・氏名・いまの担当・進捗 だけ。金額・口座番号・変更前後・ボタン・履歴は出さない。
// =============================================================
export type StatusCode = "todo" | "waiting" | "doing" | "done" | "alert";
export const STATUS: Record<StatusCode, { mark: string; label: string }> = {
  todo: { mark: "⚪", label: "未対応" },
  waiting: { mark: "🟡", label: "確認待ち" },
  doing: { mark: "🔵", label: "対応中" },
  done: { mark: "🟢", label: "完了" },
  alert: { mark: "🔴", label: "要対応" },
};

export type NoticeParent = {
  emoji?: string; label: string;           // 通知種別（【】の中）
  date: string | null;                     // YYYY-MM-DD
  store: string | null; name: string | null;
  status_code: StatusCode; status_label?: string | null;   // 段階の言葉（本部確認待ち・社長承認待ち など）。無ければ基本の言葉
  mentions?: { slack_user_id?: string | null; name?: string | null }[];   // いま対応すべき人だけ
};

/** 2026-11-02 → 11/2 */
export const shortDate = (d: string | null | undefined): string => {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(d ?? ""));
  return m ? `${Number(m[2])}/${Number(m[3])}` : "—";
};
const clean = (s: string | null | undefined, max = 30) => String(s ?? "").replace(/[\n\r|｜<>]/g, " ").trim().slice(0, max) || "—";

/** 担当の並び。進行中は実ユーザー ID のメンション、完了は名前の文字（再通知しない）。同じ人は 1 回だけ */
export function mentionLine(mentions: NoticeParent["mentions"], closed: boolean): string {
  const seen = new Set<string>(); const out: string[] = [];
  for (const m of mentions ?? []) {
    const id = String(m.slack_user_id ?? "").trim(); const key = id || "n:" + String(m.name ?? "");
    if (!key || key === "n:" || seen.has(key)) continue; seen.add(key);
    if (closed) { if (m.name) out.push(clean(m.name, 20)); }
    else if (/^[UW][A-Z0-9]{6,}$/.test(id)) out.push(`<@${id}>`);
  }
  return out.join(" ");
}

/** 親メッセージ（2 行）。text にも blocks にも同じ内容を入れる（更新のときに形が崩れない） */
export function noticeParent(p: NoticeParent): { text: string; blocks: unknown[] } {
  const st = STATUS[p.status_code] ?? STATUS.todo; const closed = p.status_code === "done";
  const line1 = `${p.emoji ? p.emoji : ""}【${clean(p.label, 20)}】${shortDate(p.date)}｜${clean(p.store, 20)}｜${clean(p.name, 30)}`;
  const who = mentionLine(p.mentions, closed);
  const line2 = `${who ? who + "　" : ""}${st.mark} ${clean(p.status_label || st.label, 40)}`;
  const text = `${line1}\n${line2}`;
  return { text, blocks: [{ type: "section", text: { type: "mrkdwn", text } }] };
}

/** スレッドの 1 通目: 詳細カード。fields は種類ごとの「出してよい項目」だけを渡す（金額・口座番号・住所は渡さない） */
export function noticeDetail(d: { title: string; fields: { label: string; value: string | null | undefined }[]; admin_url?: string | null; note?: string | null }): { text: string; blocks: unknown[] } {
  const rows = d.fields.filter((f) => f.value !== null && f.value !== undefined && String(f.value) !== "").map((f) => `*${clean(f.label, 20)}*: ${String(f.value).slice(0, 200)}`);
  const body = `*${clean(d.title, 60)}*\n${rows.join("\n")}${d.note ? `\n_${String(d.note).slice(0, 200)}_` : ""}`;
  const blocks: unknown[] = [{ type: "section", text: { type: "mrkdwn", text: body } }];
  if (d.admin_url) blocks.push({ type: "context", elements: [{ type: "mrkdwn", text: `金額などの詳しい内容は、権限のある人だけが <${d.admin_url}|管理画面> で確認できます。` }] });
  return { text: body, blocks };
}

/** スレッドの 2 通目: 操作カード（いまの段階で押せるボタンだけ。段階が変わったら同じメッセージを更新する） */
export function noticeControl(c: { status_code: StatusCode; status_label?: string | null; assignee_names?: string[]; buttons: { text: string; action_id: string; value: string; style?: "primary" | "danger"; url?: string }[]; unlinked_count?: number }): { text: string; blocks: unknown[] } {
  const st = STATUS[c.status_code] ?? STATUS.todo;
  const head = `${st.mark} *${clean(c.status_label || st.label, 40)}*${c.assignee_names?.length ? `　担当: ${c.assignee_names.map((n) => clean(n, 20)).join("・")}` : ""}`;
  const blocks: unknown[] = [{ type: "section", text: { type: "mrkdwn", text: head } }];
  if (c.buttons.length) blocks.push({ type: "actions", block_id: "notice_control", elements: c.buttons.slice(0, 5).map((b) => ({ type: "button", text: { type: "plain_text", text: b.text.slice(0, 30), emoji: true }, action_id: b.action_id, value: b.value, ...(b.style ? { style: b.style } : {}), ...(b.url ? { url: b.url } : {}) })) });
  if (c.unlinked_count) blocks.push({ type: "context", elements: [{ type: "mrkdwn", text: `Slack と紐付いていないため通知できていない人: ${c.unlinked_count} 名（確認のタスクを作成しています）` }] });
  return { text: head, blocks };
}

/** 履歴 1 行（だれが・いつ・何をしたか） */
export function noticeHistoryLine(h: { at: string; actor: string | null; action: string; comment?: string | null }): string {
  const t = new Date(h.at); const jst = new Date(t.getTime() + 9 * 3600e3);
  const when = isNaN(t.getTime()) ? "" : `${jst.getUTCMonth() + 1}/${jst.getUTCDate()} ${String(jst.getUTCHours()).padStart(2, "0")}:${String(jst.getUTCMinutes()).padStart(2, "0")}`;
  return `・${when}　${clean(h.actor, 20)}　${clean(h.action, 30)}${h.comment ? `「${String(h.comment).slice(0, 120)}」` : ""}`;
}

/** 担当の引き継ぎ・リマインド（スレッドへの返信。ここでだけメンションの通知が飛ぶ） */
export function noticeHandover(h: { mentions: NoticeParent["mentions"]; message: string }): string {
  const who = mentionLine(h.mentions, false);
  return `${who ? who + "　" : ""}${String(h.message).slice(0, 200)}`;
}
