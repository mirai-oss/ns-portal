// 入社登録のLINE通知への返信で賃金（時給・月給）を登録する処理の本体（担当B・2026-10-17）。line-webhook から呼ばれる。
// 流れ: 返信を読み取る → 確認メッセージ（「はい」で登録）→ 「はい」で employee_wage_settings に保存 → smaregi-sync(wage_push)でスマレジへ反映。
// 判定の原則（普通のLINEのやりとりを邪魔しない）: 送り主が「本部・社長・マスター（LINE連携済み）」で、かつ
//   ①通知メッセージへの返信（引用）／②先頭に承認待ちの人の名前／③文面が賃金の書き方に完全に合う（かつ承認待ちが1人だけ）
//   のいずれかのときだけ反応する。それ以外は false を返し、従来の処理（求人・連携の合言葉など）へ渡す。
import { parseWageReply, describeItems, yesNo, monthStart, norm, type Store, type WageItem } from "./wage-line.ts";

export interface PendingReq { id: string; user_id: string; name: string }
export interface WageDb {
  findApprover(lineId: string): Promise<{ id: string; name: string } | null>;
  getConfirm(lineId: string): Promise<{ request_id: string; parsed: { items: WageItem[] } } | null>;
  setConfirm(lineId: string, requestId: string, parsed: { items: WageItem[] }): Promise<void>;
  clearConfirm(lineId: string): Promise<void>;
  pendingRequests(): Promise<PendingReq[]>;
  requestByMessage(lineId: string, messageId: string): Promise<string | null>;
  activeStores(): Promise<Store[]>;
  getRequest(id: string): Promise<(PendingReq & { status: string }) | null>;
  applyWages(req: PendingReq, items: WageItem[], doneBy: string): Promise<{ ok: boolean; stage?: "no_link" | "save" | "push"; error?: string; contractLabel?: string; effective?: string[] }>;
  otherRecipients(requestId: string, exceptLineId: string): Promise<string[]>;
}

const HELP = "書き方の例:\n・時給 1200\n・時給 1200 休日 1300\n・月給 250000\n・新橋 1400（その店舗だけの時給）";

export async function handleWageReply(
  db: WageDb,
  ev: { message?: { text?: string; quotedMessageId?: string } ; source?: { userId?: string } },
  say: (text: string) => Promise<void>,
  push: (to: string, text: string) => Promise<void>,
): Promise<boolean> {
  const lineId = ev.source?.userId ?? ""; const text = String(ev.message?.text ?? "");
  if (!lineId || !text.trim()) return false;
  const approver = await db.findApprover(lineId);
  if (!approver) return false;

  // ---- 確認待ちへの「はい」「いいえ」 ----
  const yn = yesNo(text);
  if (yn) {
    const pc = await db.getConfirm(lineId);
    if (!pc) return false;
    if (yn === "no") { await db.clearConfirm(lineId); await say("取り消しました。もう一度、金額を送ってください。\n" + HELP); return true; }
    const req = await db.getRequest(pc.request_id);
    if (!req || req.status !== "pending") { await db.clearConfirm(lineId); await say("この方の賃金は、すでに登録済みか、対象外になっています。"); return true; }
    const r = await db.applyWages(req, pc.parsed.items, approver.id);
    if (r.ok) {
      await db.clearConfirm(lineId);
      await say(`✅ ${req.name}さんの賃金を登録し、スマレジにも反映しました。\n${describeItems(pc.parsed.items)}${r.effective?.length ? "\n適用開始日: " + [...new Set(r.effective)].join("・") : ""}`);
      for (const to of await db.otherRecipients(req.id, lineId)) await push(to, `${req.name}さんの賃金は、${approver.name}さんが登録しました。`);
    } else if (r.stage === "no_link") {
      await say(`${req.name}さんは、まだスマレジに登録されていないため、反映できません。\n管理システム（従業員編集）で「スマレジに登録」をしてから、もう一度「はい」を送ってください。`);
    } else if (r.stage === "push") {
      await db.clearConfirm(lineId);
      await say(`管理システムには保存しましたが、スマレジへの反映に失敗しました。\n${r.error ?? ""}\n従業員編集の「💴 賃金設定」から「もう一度反映」できます。`);
    } else {
      await say(`登録できませんでした。${r.error ?? ""}`);
    }
    return true;
  }

  // ---- 賃金の返信かどうかの判定 ----
  const reqs = await db.pendingRequests();
  if (!reqs.length) return false;
  const quoted = ev.message?.quotedMessageId ? await db.requestByMessage(lineId, ev.message.quotedMessageId) : null;
  const stores = await db.activeStores();
  const pr = parseWageReply(text, stores, reqs.map((r) => r.name));
  const isStrict = pr.items.length > 0 && pr.errors.length === 0;
  const intended = !!quoted || pr.nameHit !== null || isStrict;
  if (!intended) return false;

  let target: PendingReq | null = null;
  if (quoted) target = reqs.find((r) => r.id === quoted) ?? null;
  else if (pr.nameHit !== null) target = reqs[pr.nameHit];
  else if (reqs.length === 1) target = reqs[0];

  if (pr.errors.length || !pr.items.length) {
    await say("読み取れませんでした。\n" + pr.errors.map((e) => "・" + e).join("\n") + "\n\n" + HELP);
    return true;
  }
  if (!target) {
    await say(`どの方の賃金か分かりません。承認待ち: ${reqs.map((r) => r.name).join("・")}\n通知メッセージを「返信」するか、先頭に名前を付けて送り直してください。\n例: ${reqs[0].name} 時給 1200`);
    return true;
  }
  await db.setConfirm(lineId, target.id, { items: pr.items });
  await say(`${target.name}さんの賃金:\n${describeItems(pr.items)}\n\nこれでスマレジに登録します。よければ「はい」、直すときは金額を送り直してください。`);
  return true;
}

// ---- 本物のDB実装（service_role のsupabase-js）----
export function makeDb(sb: any, supabaseUrl: string, serviceKey: string): WageDb {
  const jstToday = () => new Date(Date.now() + 9 * 3600e3).toISOString().slice(0, 10);
  return {
    async findApprover(lineId) {
      const { data } = await sb.from("users").select("id,name,role,is_master,is_active").eq("line_user_id", lineId).maybeSingle();
      return data && data.is_active && (data.is_master || ["CEO", "HQ"].includes(data.role)) ? { id: data.id, name: data.name } : null;
    },
    async getConfirm(lineId) {
      const { data } = await sb.from("hr_wage_pending_confirm").select("request_id,parsed,created_at").eq("line_user_id", lineId).maybeSingle();
      if (!data) return null;
      if (Date.now() - new Date(data.created_at).getTime() > 3 * 3600e3) { await sb.from("hr_wage_pending_confirm").delete().eq("line_user_id", lineId); return null; } // 3時間で失効
      return { request_id: data.request_id, parsed: data.parsed };
    },
    async setConfirm(lineId, requestId, parsed) {
      await sb.from("hr_wage_pending_confirm").upsert({ line_user_id: lineId, request_id: requestId, parsed, created_at: new Date().toISOString() });
    },
    async clearConfirm(lineId) { await sb.from("hr_wage_pending_confirm").delete().eq("line_user_id", lineId); },
    async pendingRequests() {
      const { data } = await sb.from("hr_wage_requests").select("id,user_id,created_at,users(name)").eq("status", "pending").order("created_at");
      return (data ?? []).map((r: any) => ({ id: r.id, user_id: r.user_id, name: r.users?.name ?? "" }));
    },
    async requestByMessage(lineId, messageId) {
      const { data } = await sb.from("hr_wage_request_msgs").select("request_id").eq("line_user_id", lineId).eq("message_id", messageId).maybeSingle();
      return data?.request_id ?? null;
    },
    async activeStores() { const { data } = await sb.from("stores").select("id,name").eq("is_active", true); return (data ?? []) as Store[]; },
    async getRequest(id) {
      const { data } = await sb.from("hr_wage_requests").select("id,user_id,status,users(name)").eq("id", id).maybeSingle();
      return data ? { id: data.id, user_id: data.user_id, status: data.status, name: data.users?.name ?? "" } : null;
    },
    async otherRecipients(requestId, exceptLineId) {
      const { data } = await sb.from("hr_wage_request_msgs").select("line_user_id").eq("request_id", requestId).neq("line_user_id", exceptLineId);
      return (data ?? []).map((r: any) => r.line_user_id);
    },
    async applyWages(req, items, doneBy) {
      // 反映先の契約: その人の有効なスマレジ連携（主契約優先）
      const { data: links } = await sb.from("employee_smaregi_links").select("contract_id,is_primary,effective_to,created_at").eq("user_id", req.user_id);
      const act = (links ?? []).filter((l: any) => !l.effective_to || l.effective_to >= jstToday()).sort((a: any, b: any) => Number(b.is_primary) - Number(a.is_primary) || String(a.created_at).localeCompare(String(b.created_at)));
      if (!act.length) return { ok: false, stage: "no_link" };
      const contract = act[0].contract_id;
      const { data: prof } = await sb.from("employee_profiles").select("hire_date").eq("user_id", req.user_id).maybeSingle();
      const base = prof?.hire_date && prof.hire_date > "2000-01-01" ? prof.hire_date : jstToday();
      const effective: string[] = [];
      for (const it of items) {
        const date = it.division === 2 ? monthStart(base) : base;
        effective.push(date);
        let q = sb.from("employee_wage_settings").select("id").eq("user_id", req.user_id).eq("contract_id", contract).eq("division", it.division).eq("effective_date", date);
        q = it.store_id ? q.eq("store_id", it.store_id) : q.is("store_id", null);
        const { data: ex } = await q.maybeSingle();
        if (ex?.id) {
          const { error } = await sb.from("employee_wage_settings").update({ wage: it.wage, holiday_wage: it.holiday_wage, sync_status: "pending", sync_error: null, updated_at: new Date().toISOString() }).eq("id", ex.id);
          if (error) return { ok: false, stage: "save", error: error.message };
        } else {
          const { error } = await sb.from("employee_wage_settings").insert({ user_id: req.user_id, contract_id: contract, division: it.division, store_id: it.store_id, wage: it.wage, holiday_wage: it.holiday_wage, effective_date: date, created_by: doneBy });
          if (error) return { ok: false, stage: "save", error: error.message };
        }
      }
      await sb.from("hr_wage_requests").update({ status: "done", done_at: new Date().toISOString(), done_by: doneBy }).eq("id", req.id);
      const res = await fetch(`${supabaseUrl}/functions/v1/smaregi-sync`, {
        method: "POST",
        headers: { Authorization: `Bearer ${serviceKey}`, apikey: serviceKey, "Content-Type": "application/json" },
        body: JSON.stringify({ action: "wage_push", user_id: req.user_id, contract_id: contract }),
      });
      const j = await res.json().catch(() => ({}));
      if (!j.ok) return { ok: false, stage: "push", error: String(j.error ?? (j.results ?? []).filter((x: any) => !x.ok).map((x: any) => x.error).join(" / ") ?? "").slice(0, 300) };
      return { ok: true, effective };
    },
  };
}
export { norm };
