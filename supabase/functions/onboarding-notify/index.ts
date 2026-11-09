// =============================================================
// onboarding-notify — 入社登録ワークフローの Slack 一元管理（Phase 1・2026-11-09）
//   役割: 従業員ごとの「親メッセージ」を人事チャンネル（slack_channels 'hq.jinji' = C0CFE1Y9HC7）に 1 つ作り、
//         進捗・設定結果・エラー・対応履歴を同じスレッドに流す。賃金のスマレジ反映（wage_push）と反映後の照合（wage_pull）もここで行う。
//   設計: docs/調査報告_入社登録Slack一元化_2026-11-08.md §5・§12、承認条件 2026-11-09 ①〜⑪
//   鉄則: DB の状態は RPC（onboarding_start / onboarding_set_item / hr_save_wage）経由でしか変えない。Slack 送信は notify-slack 経由のみ。
//
//   認証（いずれか）: Authorization: Bearer <service_role>（hr-wage-notify・slack-interact から）／ x-notify-secret: <NOTIFY_SLACK_SECRET>（DB・運用スクリプト）
//   body.op:
//     open       { user_id, source? }                 入社フォーム完了後に呼ぶ。ワークフロー行を作り（冪等）、親メッセージが無ければ作る
//     refresh    { workflow_id }                       親メッセージを今の状態で描き直す
//     thread     { workflow_id, text, blocks?, event? } スレッドに 1 件投稿
//     wage_sync  { workflow_id, actor_id, contract_id? } 反映待ちの賃金を smaregi-sync wage_push → wage_pull で照合 → 項目を完了/失敗 → スレッド＋親更新
//     status     { workflow_id | user_id }             状態を返す（確認用）
//   2026-11-09（Phase 5 の土台。★ いずれも既定フラグ OFF＝本人に自動送信しない・停滞アラートを送らない）:
//     person_contact { workflow_id, kind, text?, actor_id }  本人への連絡（onboarding_alerts.person_notify_enabled=true のときだけ Slack DM → LINE の順で送る。false は文面をスレッドに出すだけ）
//     account_check  { workflow_id, actor_id }               スマレジ GET（staff_get）でメール・源泉・Web明細・交通費の登録を照合し、登録済みなら項目を自動 ✓。本人アカウント登録状況は API に項目が無い → UI 読み取りジョブ（account_ui_read_enabled=true のとき）
//     stale_alert    { dry_run? }                            停滞アラート（pg_cron から）。onboarding_alerts.enabled=false か dry_run なら候補を返すだけで送らない
//     commute_check は auto_approve.enabled=true のときだけ自動承認（取り消しボタン付き）。既定は shadow＝参考表示と記録だけ
//   2026-11-09 Phase 6（扶養・年末調整・事業所）:
//     post_join_submitted { user_id, kind: 'year_end'|'dependents' }   本人提出のあと（nippo から呼べないので、本部の「🔄 表示を更新」か cron の post_join_remind が拾う／slack-interact 経由）スレッドに「📝 提出」＋「スマレジに反映」ボタン
//     tax_setting_saved   { workflow_id, actor_id }                      源泉所得税の設定（RPC onboarding_set_tax_setting）のあと。スレッドに内容
//     post_join_remind    { dry_run? }                                   未提出者へのリマインド（v2: 必須かつ未完了だけ＝RPC onboarding_post_join_targets。post_join_remind_enabled=false なら候補だけ返す）
//     post_join_decided   { workflow_id, track, target_year?, decision 'approved'|'rejected', actor_id, note?, job? }  本部の承認／差し戻しのあと（slack-interact から）
//     post_join_compare   { workflow_id, track, target_year?, actor_id }     年末調整＝API と提出内容の差分をスレッドへ／扶養＝読むだけジョブ（snapshot）を積む
//     post_join_snapshot  { workflow_id|user_id, actor_id }                   既存従業員: スマレジの内容を 1 人ぶん取り込む（年末調整＝API、扶養＝読むだけジョブ）。本人の提出状況は変えない
//     ui_job_result は kind smaregi_year_end（staff_get.yearEnd と照合）/ smaregi_dependents（画面の行数と照合）/ smaregi_store（対応表に登録して hq.jinji へ）にも対応
//   デプロイ: supabase functions deploy onboarding-notify --no-verify-jwt --project-ref uuvsxzhpxtghojoubjcc --yes（関数内で認証するため）
// =============================================================
import { createClient } from "npm:@supabase/supabase-js@2";
import { parentMessage, wageFailedBlocks, wageDateAdjustedBlocks, wageLine, nowJst, commuteCheckBlocks, uiJobResultBlocks, autoApprovedBlocks, personContactTemplate, personContactResultBlocks, staleAlertThreadText, staleAlertSummaryBlocks, postJoinSubmittedBlocks, yearEndCompareText, POST_JOIN_TRACK_LABEL, POST_JOIN_STATUS_LABEL, RELATIONSHIP_LABEL, ITEM_ORDER, PAY_TYPE_LABEL, JUDGEMENT_LABEL, yen, jpDate, type WorkflowView } from "../_shared/onboarding-blocks.ts";
import { linePush } from "../_shared/line.ts";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info, x-notify-secret" };
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const svc = () => createClient(SUPABASE_URL, SERVICE_KEY);

function authorized(req: Request): boolean {
  const secret = (Deno.env.get("NOTIFY_SLACK_SECRET") ?? "").trim();
  const hdr = (req.headers.get("x-notify-secret") ?? "").trim();
  if (secret && hdr && secret === hdr) return true;
  const bearer = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  return !!bearer && bearer === SERVICE_KEY;
}

// ---- notify-slack（唯一の Slack 出口）----
async function slackSend(body: Record<string, unknown>): Promise<any> {
  const res = await fetch(`${SUPABASE_URL}/functions/v1/notify-slack`, {
    method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${SERVICE_KEY}`, apikey: SERVICE_KEY },
    body: JSON.stringify(body),
  });
  return await res.json().catch(() => ({ ok: false, error: `HTTP ${res.status}` }));
}
const BOT = { username: "入社手続き", icon_emoji: ":briefcase:" };

async function loadView(sb: any, workflowId: string): Promise<WorkflowView | null> {
  const { data } = await sb.from("onboarding_workflow_v").select("*").eq("id", workflowId).maybeSingle();
  return (data as WorkflowView) ?? null;
}
async function event(sb: any, wf: WorkflowView, kind: string, payload: unknown, actorId: string | null = null, itemKey: string | null = null) {
  await sb.from("onboarding_events").insert({ workflow_id: wf.id, item_key: itemKey, kind, actor_id: actorId, via: "auto", payload });
}

// 親メッセージが無ければ作る。戻り値: 作ったか
async function ensureParent(sb: any, wf: WorkflowView): Promise<{ created: boolean; error?: string }> {
  const { data: row } = await sb.from("onboarding_workflows").select("slack_parent_ts,slack_parent_notification_id,slack_channel_key").eq("id", wf.id).maybeSingle();
  if (row?.slack_parent_ts) return { created: false };
  const nid = crypto.randomUUID();
  const msg = parentMessage(wf, nid);
  const r = await slackSend({
    action: "send", notification_id: nid, channel_key: row?.slack_channel_key ?? "hq.jinji", event: "onboarding_parent", source: "ef:onboarding-notify",
    text: msg.text, blocks: msg.blocks, dedupe_key: `onboarding:${wf.id}:parent`, ref: { table: "onboarding_workflows", id: wf.id }, ...BOT,
  });
  if (!r?.ok || !r.ts) return { created: false, error: r?.error ?? "Slack に送れませんでした" };
  await sb.from("onboarding_workflows").update({ slack_parent_notification_id: r.notification_id ?? nid, slack_parent_ts: r.ts, slack_channel_id: r.slack_channel_id ?? null, updated_at: new Date().toISOString() }).eq("id", wf.id);
  await event(sb, wf, "slack.parent", { notification_id: r.notification_id ?? nid, ts: r.ts, status: r.status });
  return { created: r.status !== "duplicate" };
}
async function refreshParent(sb: any, wf: WorkflowView): Promise<boolean> {
  const { data: row } = await sb.from("onboarding_workflows").select("slack_parent_notification_id").eq("id", wf.id).maybeSingle();
  if (!row?.slack_parent_notification_id) return false;
  const msg = parentMessage(wf, row.slack_parent_notification_id);
  const r = await slackSend({ action: "update", notification_id: row.slack_parent_notification_id, text: msg.text, blocks: msg.blocks });
  return !!r?.ok;
}
async function thread(sb: any, wf: WorkflowView, text: string, blocks?: unknown[], ev = "onboarding_thread"): Promise<any> {
  const { data: row } = await sb.from("onboarding_workflows").select("slack_parent_ts,slack_channel_key").eq("id", wf.id).maybeSingle();
  if (!row?.slack_parent_ts) return { ok: false, error: "親メッセージがありません" };
  return await slackSend({ action: "send", channel_key: row.slack_channel_key ?? "hq.jinji", thread_ts: row.slack_parent_ts, event: ev, source: "ef:onboarding-notify", text, ...(blocks ? { blocks } : {}), ref: { table: "onboarding_workflows", id: wf.id }, ...BOT });
}
async function setItem(sb: any, wfId: string, item: string, state: string, payload: unknown, actorId: string | null, via: string, error: string | null = null) {
  const { data, error: e } = await sb.rpc("onboarding_set_item", { p_workflow: wfId, p_item: item, p_state: state, p_payload: payload, p_actor: actorId, p_via: via, p_error: error });
  if (e) throw new Error(`onboarding_set_item: ${e.message}`);
  return data;
}
async function smaregi(action: string, body: Record<string, unknown>): Promise<any> {
  const res = await fetch(`${SUPABASE_URL}/functions/v1/smaregi-sync`, {
    method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${SERVICE_KEY}`, apikey: SERVICE_KEY },
    body: JSON.stringify({ action, ...body }),
  });
  const j = await res.json().catch(() => null);
  return j ?? { ok: false, error: `HTTP ${res.status}` };
}
async function actorName(sb: any, id: string | null): Promise<string> {
  if (!id) return "自動";
  const { data } = await sb.from("users").select("name").eq("id", id).maybeSingle();
  return data?.name ?? "本部";
}

async function alertSettings(sb: any): Promise<Record<string, any>> {
  const { data } = await sb.from("app_settings").select("value").eq("key", "onboarding_alerts").maybeSingle();
  return data?.value ?? {};
}
// 本人の連絡先（Slack 紐づけ・LINE 連携）。値そのものは返さず「使えるか」と送信に必要な ID だけ
async function personChannels(sb: any, userId: string): Promise<{ slack: boolean; line_user_id: string | null }> {
  const [{ data: us }, { data: u }] = await Promise.all([
    sb.from("user_slack").select("slack_user_id").eq("user_id", userId).maybeSingle(),
    sb.from("users").select("line_user_id").eq("id", userId).maybeSingle(),
  ]);
  return { slack: !!us?.slack_user_id, line_user_id: u?.line_user_id ?? null };
}
const jstHour = () => Number(new Date().toLocaleString("en-US", { timeZone: "Asia/Tokyo", hour: "2-digit", hour12: false }).replace(/\D/g, "")) % 24;

// ---- op=open ----
async function opOpen(sb: any, userId: string, source: string) {
  const { data, error } = await sb.rpc("onboarding_start", { p_user: userId, p_source: source, p_actor: null });
  if (error) return json({ ok: false, error: `onboarding_start: ${error.message}` }, 500);
  if (!data?.ok) return json({ ok: false, error: data?.error ?? "開始できません" }, 400);
  const wfId: string = data.workflow.id;
  const wf = await loadView(sb, wfId);
  if (!wf) return json({ ok: false, error: "ワークフローを読めません" }, 500);
  const p = await ensureParent(sb, wf);
  if (p.error) return json({ ok: false, workflow_id: wfId, created: data.created, error: p.error }, 502);
  if (p.created) {
    const it = wf.items ?? {};
    const lines = [
      `📝 入社フォーム 送信済み（${nowJst()}）`,
      wf.smaregi_staff_id ? `✅ スマレジ従業員 作成済み（${wf.contract_label ?? wf.contract_id ?? ""}／ID ${wf.smaregi_staff_id}）` : "⚠️ スマレジ従業員はまだ作成されていません（nippo の従業員ページから作成できます）",
      it.slack_link?.state === "completed" ? "✅ Slack 連携 済み" : "⬜ Slack 連携 未（招待は自動で送られます）",
      wf.hq_task_id ? "🗂 本部タスク「入社登録」と連動しています（賃金などが完了すると自動で ✓）" : "ℹ️ 本部タスクはまだ見つかりません（作成されたら次の更新で連動）",
      "",
      "▶ 次: 上の「💴 賃金を設定」から賃金を登録してください（スマレジに自動反映されます）",
    ];
    await thread(sb, wf, lines.join("\n"), undefined, "onboarding_opened");
  }
  return json({ ok: true, workflow_id: wfId, created: data.created, parent_created: p.created, hq_task_id: wf.hq_task_id });
}

// ---- op=wage_sync ----
async function opWageSync(sb: any, wfId: string, actorId: string | null, contractId: string | null) {
  const wf = await loadView(sb, wfId);
  if (!wf || !wf.user_id) return json({ ok: false, error: "ワークフローが見つかりません" }, 404);
  const C = contractId ?? wf.contract_id;
  if (!C) return json({ ok: false, error: "スマレジの契約が決まっていません" }, 400);
  const who = await actorName(sb, actorId);
  await setItem(sb, wfId, "wage", "running", { contract_id: C, requested_by: actorId }, actorId, actorId ? "slack" : "auto");
  const push = await smaregi("wage_push", { user_id: wf.user_id, contract_id: C });
  const results: any[] = Array.isArray(push?.results) ? push.results : [];
  const failed = results.filter((x) => !x.ok);
  if (!push?.ok) {
    const err = failed.map((x) => x.error).filter(Boolean).join(" / ") || push?.error || "スマレジへの反映に失敗しました";
    await setItem(sb, wfId, "wage", "failed", { contract_id: C, results }, actorId, actorId ? "slack" : "auto", String(err).slice(0, 300));
    const wf2 = (await loadView(sb, wfId)) ?? wf;
    const { data: pn } = await sb.from("onboarding_workflows").select("slack_parent_notification_id").eq("id", wfId).maybeSingle();
    await thread(sb, wf2, `⚠️ 賃金のスマレジ反映に失敗: ${String(err).slice(0, 200)}`, wageFailedBlocks(wf2, pn?.slack_parent_notification_id ?? null, String(err), who), "onboarding_wage_failed");
    await refreshParent(sb, wf2);
    return json({ ok: false, error: err, results });
  }
  // 反映した行と、反映後の照合（スマレジを GET し直して 金額・適用開始日 が一致するか）
  const { data: rows } = await sb.from("employee_wage_settings").select("id,division,store_id,wage,holiday_wage,effective_date,smaregi_wage_apply_id,sync_status").eq("user_id", wf.user_id).eq("contract_id", C).order("effective_date");
  const storeIds = [...new Set((rows ?? []).map((r: any) => r.store_id).filter(Boolean))];
  const names: Record<string, string> = {};
  if (storeIds.length) { const { data: st } = await sb.from("stores").select("id,name").in("id", storeIds); (st ?? []).forEach((s: any) => { names[s.id] = s.name; }); }
  const pushedIds = new Set(results.filter((x) => x.ok).map((x) => String(x.id)));
  const pushedRows = (rows ?? []).filter((r: any) => pushedIds.has(String(r.id)));
  let verified: boolean | null = null; let verifyNote = "";
  try {
    const pull = await smaregi("wage_pull", { user_id: wf.user_id, contract_id: C });
    if (pull?.ok && Array.isArray(pull.wages)) {
      const bad = pushedRows.filter((r: any) => !pull.wages.some((w: any) => String(w.id) === String(r.smaregi_wage_apply_id) && Number(w.wage) === Number(r.wage) && String(w.effectiveDate) === String(r.effective_date)));
      verified = bad.length === 0;
      if (!verified) verifyNote = `照合で一致しない行があります（${bad.length} 件）。スマレジ側は適用開始日を「初期設定」の日付に合わせることがあります`;
    } else verifyNote = `照合できませんでした: ${pull?.error ?? "不明"}`;
  } catch (e) { verifyNote = `照合できませんでした: ${String(e).slice(0, 120)}`; }
  const payloadRows = pushedRows.map((r: any) => ({ division: r.division, wage: r.wage, holiday_wage: r.holiday_wage, effective_date: r.effective_date, store_name: r.store_id ? names[r.store_id] ?? null : null, wageApplyId: r.smaregi_wage_apply_id }));
  // 全行が synced のときだけ完了（failed が混ざれば失敗）
  const pending = (rows ?? []).filter((r: any) => r.sync_status !== "synced");
  // 2026-11-09: 救済処理で適用開始日がスマレジ側（初期設定）の日付に変わった行がある → 「成功」にせず確認待ち（manual_required）。人が「✅ この日付で確定」を押すと完了
  const adjusted = results.filter((x) => x.ok && x.date_adjusted).map((x) => {
    const row = payloadRows.find((p: any) => String(p.wageApplyId) === String(x.wageApplyId)) ?? (rows ?? []).find((r: any) => String(r.id) === String(x.id));
    return { requested: String(x.date_adjusted.requested), applied: String(x.date_adjusted.applied), line: row ? wageLine(row) : "賃金" };
  });
  if (!pending.length && adjusted.length) {
    const err = `適用開始日がスマレジ側の初期設定の日付に変わりました（${adjusted.map((a) => `${a.requested}→${a.applied}`).join("、")}）。確認待ち`;
    await setItem(sb, wfId, "wage", "manual_required", { contract_id: C, rows: payloadRows, verified, date_adjusted: adjusted }, actorId, actorId ? "slack" : "auto", err);
    const wf2 = (await loadView(sb, wfId)) ?? wf;
    const { data: pn } = await sb.from("onboarding_workflows").select("slack_parent_notification_id").eq("id", wfId).maybeSingle();
    await thread(sb, wf2, `🙋 賃金はスマレジに保存されましたが適用開始日が指定と違います（確認待ち）`, wageDateAdjustedBlocks(wf2, pn?.slack_parent_notification_id ?? null, adjusted, who), "onboarding_wage_date_adjusted");
    await refreshParent(sb, wf2);
    return json({ ok: true, pushed: push.pushed, verified, rows: payloadRows, date_adjusted: adjusted, state: "manual_required" });
  }
  if (pending.length) {
    const err = pending.map((r: any) => r.sync_error).filter(Boolean).join(" / ") || "未反映の行があります";
    await setItem(sb, wfId, "wage", "failed", { contract_id: C, rows: payloadRows, verified }, actorId, actorId ? "slack" : "auto", String(err).slice(0, 300));
  } else {
    await setItem(sb, wfId, "wage", "completed", { contract_id: C, rows: payloadRows, verified, verified_at: new Date().toISOString() }, actorId, actorId ? "slack" : "auto");
  }
  const wf2 = (await loadView(sb, wfId)) ?? wf;
  const text = pending.length
    ? `⚠️ 一部の賃金が未反映です（${who}・${nowJst()}）\n` + pending.map((r: any) => `・${wageLine({ ...r, store_name: r.store_id ? names[r.store_id] : null })}: ${r.sync_error ?? "未反映"}`).join("\n")
    : `✅ 賃金をスマレジに反映しました（${who}・${nowJst()}）\n` + payloadRows.map((r: any) => `・${wageLine(r)}　スマレジ賃金設定ID ${r.wageApplyId ?? "—"}`).join("\n") +
      `\n${verified === true ? "🔍 反映後にスマレジから読み直して一致を確認しました" : verified === false ? "⚠️ " + verifyNote : "ℹ️ " + verifyNote}` +
      (wf2.hq_task_id ? "\n🗂 本部タスク「給与・明細設定を入力」の「時給」に ✓ を付けました" : "");
  await thread(sb, wf2, text, undefined, pending.length ? "onboarding_wage_partial" : "onboarding_wage_synced");
  await refreshParent(sb, wf2);
  return json({ ok: pending.length === 0, pushed: push.pushed, verified, rows: payloadRows, pending: pending.length });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ ok: false, error: "POSTのみ" }, 405);
  if (!authorized(req)) return json({ ok: false, error: "unauthorized" }, 401);
  const body = await req.json().catch(() => ({}));
  const sb = svc();
  const isUuid = (s: unknown) => typeof s === "string" && /^[0-9a-f-]{36}$/i.test(s);
  try {
    switch (String(body.op ?? "")) {
      case "open": {
        if (!isUuid(body.user_id)) return json({ ok: false, error: "user_id が不正です" }, 400);
        return await opOpen(sb, body.user_id, String(body.source ?? "nippo"));
      }
      case "refresh": {
        if (!isUuid(body.workflow_id)) return json({ ok: false, error: "workflow_id が不正です" }, 400);
        const wf = await loadView(sb, body.workflow_id);
        if (!wf) return json({ ok: false, error: "見つかりません" }, 404);
        const p = await ensureParent(sb, wf);
        const ok = p.created ? true : await refreshParent(sb, wf);
        return json({ ok, parent_created: p.created, error: p.error });
      }
      case "thread": {
        if (!isUuid(body.workflow_id) || !body.text) return json({ ok: false, error: "workflow_id と text が必要です" }, 400);
        const wf = await loadView(sb, body.workflow_id);
        if (!wf) return json({ ok: false, error: "見つかりません" }, 404);
        const r = await thread(sb, wf, String(body.text).slice(0, 3900), Array.isArray(body.blocks) ? body.blocks : undefined, String(body.event ?? "onboarding_thread"));
        return json({ ok: !!r?.ok, error: r?.error ?? null, ts: r?.ts ?? null });
      }
      case "wage_sync": {
        if (!isUuid(body.workflow_id)) return json({ ok: false, error: "workflow_id が不正です" }, 400);
        return await opWageSync(sb, body.workflow_id, isUuid(body.actor_id) ? body.actor_id : null, body.contract_id ? String(body.contract_id) : null);
      }
      case "wage_save_sync": {
        // 2026-11-09: Slack のモーダル送信は 3 秒以内に返事が要る（スマホは特に厳しい）ため、保存（RPC hr_save_wage）と反映を slack-interact の返事の後ろ＝ここで行う。
        //   保存エラー（権限・重複・月初日など）はモーダルに出せないので、スレッドに ⚠️＋「💴 賃金を直す」で知らせる
        if (!isUuid(body.workflow_id) || !isUuid(body.actor_id)) return json({ ok: false, error: "workflow_id と actor_id が必要です" }, 400);
        const wf = await loadView(sb, body.workflow_id);
        if (!wf?.user_id) return json({ ok: false, error: "見つかりません" }, 404);
        const division = Number(body.division), wage = Number(body.wage), date = String(body.date ?? ""), C = body.contract_id ? String(body.contract_id) : wf.contract_id;
        const who = await actorName(sb, body.actor_id);
        const { data, error } = await sb.rpc("hr_save_wage", { p_user: wf.user_id, p_contract: C, p_division: division, p_store: null, p_wage: wage, p_holiday: null, p_date: date, p_actor: body.actor_id });
        if (error || !data?.ok) {
          const msg = error?.message ?? "保存できませんでした";
          const { data: pn } = await sb.from("onboarding_workflows").select("slack_parent_notification_id").eq("id", wf.id).maybeSingle();
          await event(sb, wf, "wage.save_failed", { division, wage, date, contract_id: C, error: msg }, body.actor_id, "wage");
          await thread(sb, wf, `⚠️ 賃金を保存できませんでした: ${msg}`, [
            { type: "section", text: { type: "mrkdwn", text: `⚠️ *賃金を保存できませんでした*（${who}・${nowJst()}）\n入力: ${wageLine({ division, wage, effective_date: date })}\n理由: ${msg.slice(0, 300)}` } },
            { type: "actions", block_id: "onboarding_wage_fix", elements: [{ type: "button", style: "primary", text: { type: "plain_text", text: "💴 賃金を直す", emoji: true }, action_id: "hr.onboarding.wage", value: JSON.stringify({ workflow_id: wf.id, notification_id: pn?.slack_parent_notification_id ?? null }) }] },
          ], "onboarding_wage_save_failed");
          return json({ ok: false, error: msg });
        }
        return await opWageSync(sb, body.workflow_id, body.actor_id, C);
      }
      case "wage_confirm": {
        // 「✅ この日付で確定」: manual_required（適用開始日の差異）の賃金項目を、人の確認のうえ完了にする（payload の rows/verified はそのまま）
        if (!isUuid(body.workflow_id) || !isUuid(body.actor_id)) return json({ ok: false, error: "workflow_id と actor_id が必要です" }, 400);
        const wf = await loadView(sb, body.workflow_id);
        if (!wf) return json({ ok: false, error: "見つかりません" }, 404);
        const it = wf.items?.wage;
        if (it?.state !== "manual_required") return json({ ok: false, error: `賃金の項目は確認待ちではありません（${it?.state ?? "なし"}）` }, 409);
        const who = await actorName(sb, body.actor_id);
        await setItem(sb, body.workflow_id, "wage", "completed", { ...(it.payload ?? {}), confirmed_by: body.actor_id, confirmed_at: new Date().toISOString() }, body.actor_id, "slack");
        const wf2 = (await loadView(sb, body.workflow_id)) ?? wf;
        const rows: any[] = Array.isArray(it.payload?.rows) ? it.payload.rows : [];
        await thread(sb, wf2, `✅ 適用開始日の差異を確認し、賃金を確定しました（${who}・${nowJst()}）\n` + rows.map((r) => `・${wageLine(r)}`).join("\n") + (wf2.hq_task_id ? "\n🗂 本部タスク「時給」に ✓ を付けました" : ""), undefined, "onboarding_wage_confirmed");
        await refreshParent(sb, wf2);
        return json({ ok: true });
      }
      // ---- Phase 2: 交通費 ----
      case "commute_check": {
        // 経路検索（EF commute-route）→ 判定をスレッドへ（承認は人が押す）
        if (!isUuid(body.workflow_id)) return json({ ok: false, error: "workflow_id が不正です" }, 400);
        const wf = await loadView(sb, body.workflow_id);
        if (!wf?.user_id) return json({ ok: false, error: "見つかりません" }, 404);
        const res = await fetch(`${SUPABASE_URL}/functions/v1/commute-route`, { method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${SERVICE_KEY}`, apikey: SERVICE_KEY }, body: JSON.stringify({ user_id: wf.user_id, store_id: body.store_id ?? null }) });
        const r = await res.json().catch(() => ({ ok: false, error: `HTTP ${res.status}` }));
        const { data: cm } = await sb.from("employee_commute").select("method,route_text,uses_bus,claimed_oneway_fare,judgement").eq("user_id", wf.user_id).maybeSingle();
        const { data: pn } = await sb.from("onboarding_workflows").select("slack_parent_notification_id").eq("id", wf.id).maybeSingle();
        const nid = pn?.slack_parent_notification_id ?? null;
        if (!r?.ok) {
          const value = JSON.stringify({ workflow_id: wf.id, notification_id: nid });
          await thread(sb, wf, `🚃 交通費の経路検索ができませんでした: ${r?.error ?? "不明"}`, [
            { type: "section", text: { type: "mrkdwn", text: `🚃 *交通費の経路検索ができませんでした*（${nowJst()}）\n${String(r?.error ?? "不明").slice(0, 300)}\n本人の申請: 片道 ${cm?.claimed_oneway_fare != null ? yen(cm.claimed_oneway_fare) : "未申請"}${cm?.route_text ? `／経路メモ: ${cm.route_text.slice(0, 100)}` : ""}\n経路は人が確認して承認してください。` } },
            { type: "actions", block_id: "onboarding_commute", elements: [
              { type: "button", style: "primary", text: { type: "plain_text", text: cm?.claimed_oneway_fare != null ? `✅ 申請額 ${yen(cm.claimed_oneway_fare)} で承認` : "✅ 承認（金額を入力）", emoji: true }, action_id: "hr.onboarding.commute.approve", value },
              { type: "button", text: { type: "plain_text", text: "🙋 本人に確認", emoji: true }, action_id: "hr.onboarding.commute.person", value },
              { type: "button", text: { type: "plain_text", text: "🔁 再検索", emoji: true }, action_id: "hr.onboarding.commute.research", value },
            ] },
          ], "onboarding_commute_failed");
          await refreshParent(sb, (await loadView(sb, wf.id)) ?? wf);
          return json({ ok: false, error: r?.error, judgement: "search_failed" });
        }
        await thread(sb, wf, `🚃 交通費の確認: ${JUDGEMENT_LABEL[r.judgement] ?? r.judgement}（申請 ${cm?.claimed_oneway_fare != null ? yen(cm.claimed_oneway_fare) : "未申請"}／検索最安 ${r.computed ? yen(r.computed.fare) : "—"}）`,
          commuteCheckBlocks(wf, nid, { judgement: r.judgement, reasons: r.reasons ?? [], claimed: r.claimed ?? null, computed: r.computed ?? null, reasonable: r.reasonable ?? [], from: r.from, to: r.to, store_name: r.store?.name, method: cm?.method, route_text: cm?.route_text, uses_bus: cm?.uses_bus, auto: r.auto ?? null }), "onboarding_commute_check");
        // 自動承認（2026-11-09）: app_settings.commute_rules.auto_approve.enabled=true のときだけ。条件は commute-route（autoJudge）が判定し、金額は本人の申請額（≦ API 算出額）。既に承認済みなら触らない
        let autoApproved = false;
        if (r.auto?.mode === "live" && r.auto.eligible && r.auto.fare != null && cm && (cm as any).judgement !== "approved") {
          const { data: d, error: de } = await sb.rpc("onboarding_commute_decide", { p_user: wf.user_id, p_decision: "approved", p_fare: r.auto.fare, p_note: "自動承認（申請額 ≦ API 算出額・規定内）", p_actor: null });
          if (!de && d?.ok) {
            autoApproved = true;
            await event(sb, wf, "commute.auto_approved", { fare: r.auto.fare, reasons: r.auto.reasons, computed_fare: r.computed?.fare ?? null }, null, "commute_check");
            await thread(sb, wf, `🤖 交通費を自動承認しました（片道 ${yen(r.auto.fare)}）`, autoApprovedBlocks(wf, nid, { fare: r.auto.fare, reasons: r.auto.reasons ?? [], from: r.from, to: r.to, computed_fare: r.computed?.fare ?? null }), "onboarding_commute_auto_approved");
          } else {
            await thread(sb, wf, `⚠️ 自動承認の条件を満たしましたが記録できませんでした（${de?.message ?? "不明"}）。上のボタンで承認してください`, undefined, "onboarding_commute_auto_failed");
          }
        }
        await refreshParent(sb, (await loadView(sb, wf.id)) ?? wf);
        return json({ ok: true, judgement: r.judgement, computed: r.computed?.fare ?? null, claimed: r.claimed ?? null, auto: r.auto ?? null, auto_approved: autoApproved });
      }
      case "commute_decided": {
        // RPC onboarding_commute_decide のあと（slack-interact から）。スレッド＋親更新
        if (!isUuid(body.workflow_id)) return json({ ok: false, error: "workflow_id が不正です" }, 400);
        const wf = await loadView(sb, body.workflow_id);
        if (!wf) return json({ ok: false, error: "見つかりません" }, 404);
        const who = await actorName(sb, isUuid(body.actor_id) ? body.actor_id : null);
        const d = String(body.decision ?? "");
        const text = d === "approved" ? `✅ 交通費の片道額を *${yen(body.fare)}* で承認しました（${who}・${nowJst()}）${body.note ? `\nメモ: ${String(body.note).slice(0, 200)}` : ""}\n▶ 次: 親メッセージの「🚌 交通費を設定」でスマレジに入れる値（支給形態・適用開始日・金額）を決めてください`
          : d === "person_review" ? `🙋 本人に経路と金額を確認することにしました（${who}・${nowJst()}）。本人への連絡（LINE/メール）は Phase 2 後半で自動化。返答が来たらスレッドに書き、「🔁 再検索」または「✅ 承認」を押してください`
          : `↩️ 交通費を差し戻しました（${who}・${nowJst()}）${body.note ? `\n理由: ${String(body.note).slice(0, 200)}` : ""}`;
        await thread(sb, wf, text, undefined, "onboarding_commute_decided");
        await refreshParent(sb, wf);
        return json({ ok: true });
      }
      case "commute_setting_saved": {
        if (!isUuid(body.workflow_id) || !isUuid(body.setting_id)) return json({ ok: false, error: "workflow_id と setting_id が必要です" }, 400);
        const wf = await loadView(sb, body.workflow_id);
        if (!wf) return json({ ok: false, error: "見つかりません" }, 404);
        const { data: s } = await sb.from("employee_commute_settings").select("*").eq("id", body.setting_id).maybeSingle();
        const who = await actorName(sb, isUuid(body.actor_id) ? body.actor_id : null);
        const scope = s?.scope === "per_store" ? "事業所別" : "全事業所";
        const line = `・${PAY_TYPE_LABEL[s?.pay_type] ?? s?.pay_type}／${scope}／${s?.scope === "per_store" ? JSON.stringify(s?.store_amounts) : yen(s?.amount)}${s?.cap_amount != null ? `／上限 ${yen(s.cap_amount)}` : ""}（${jpDate(s?.effective_date)}から）`;
        const tail = s?.sync_status === "manual"
          ? `🙋 スマレジへの自動反映はまだ有効化されていません（実機検証後に有効化）。*スマレジ管理画面でこの値を入力*し、本部タスクの「交通費」に ✓ を付けてください`
          : `⏳ Mac の自動操作でスマレジに反映します（数分〜）。結果はこのスレッドに届きます${body.duplicate ? "\nℹ️ 同じ人の未完了ジョブがあるため、そのジョブに相乗りします" : ""}`;
        await thread(sb, wf, `🚌 交通費の設定を登録しました（${who}・${nowJst()}）\n${line}\n${tail}`, undefined, "onboarding_commute_setting");
        await refreshParent(sb, wf);
        return json({ ok: true });
      }
      // ---- Phase 3: UI ジョブの結果（Mac から）: GET で照合 → 項目の状態 → スレッド → 親更新 ----
      case "ui_job_result": {
        if (!isUuid(body.job_id)) return json({ ok: false, error: "job_id が不正です" }, 400);
        const { data: job } = await sb.from("ui_automation_jobs").select("*").eq("id", body.job_id).maybeSingle();
        if (!job) return json({ ok: false, error: "ジョブが見つかりません" }, 404);
        const wf = job.workflow_id ? await loadView(sb, job.workflow_id) : null;
        if (!wf && job.kind === "smaregi_store") {
          // 事業所の作成（店舗ジョブ）: 成功なら対応表（store_external_mappings）に登録し、人事チャンネルへ
          const p = job.payload ?? {}; const ext = String((job.result as any)?.external_store_id ?? "");
          let line = "";
          if (job.status === "success" && ext) {
            const { data: m, error: me } = await sb.rpc("smaregi_store_mapping_upsert", { p_store: p.store_id, p_contract: job.contract_id, p_external_store_id: ext, p_name: p.store_name });
            line = me ? `⚠️ 事業所『${p.store_name}』はスマレジに作成しましたが対応表に登録できませんでした（${me.message}）` : `🏪 スマレジ・タイムカード（${job.contract_id}）に事業所『${p.store_name}』を作成しました（事業所ID ${ext}${m?.exists ? "・対応表は登録済み" : "・対応表に登録"}）。所属の同期は次回の smaregi-affiliation-sync から有効です`;
          } else if (job.status === "success") line = `⚠️ 事業所『${p.store_name}』を作成しましたが新しい事業所IDが読めませんでした。スマレジの事業所一覧を確認し、nippo の店舗管理で紐付けてください`;
          else if (job.status === "failed") line = `🙋 事業所『${p.store_name}』の自動作成に失敗（${String(job.error ?? "").slice(0, 160)}）。スマレジ管理画面「事業所 → 新しい事業所を作成」で手で作ってください`;
          else line = `⏳ 事業所『${p.store_name}』の自動作成に失敗し、あとで再試行します（${job.attempts}/${job.max_attempts}）`;
          await slackSend({ action: "send", channel_key: "hq.jinji", event: "onboarding_store_job", source: "ef:onboarding-notify", text: line, ref: { table: "ui_automation_jobs", id: job.id }, ...BOT });
          return json({ ok: true, status: job.status, external_store_id: ext || null });
        }
        if (!wf) return json({ ok: true, note: "ワークフロー無しのジョブ（通知なし）" });
        const { data: pn } = await sb.from("onboarding_workflows").select("slack_parent_notification_id").eq("id", wf.id).maybeSingle();
        let verified: boolean | null = null; let summary = "";
        if (job.status === "success" && !job.dry_run) {
          // 保存後の照合: スマレジ GET（smaregi-sync staff_get）と指示値を比べる
          const g = await smaregi("staff_get", { smaregi_staff_id: job.smaregi_staff_id, contract_id: job.contract_id });
          if (g?.ok) {
            const p = job.payload ?? {};
            if (job.kind === "smaregi_commute") {
              const div = { per_shift: "0", monthly: "1", per_day: "2" }[p.pay_type as string];
              // 管理画面の適用開始は「月」単位（YYYY/MM → API は月初日）なので年月で照合（2026-11-09 立会いで確認）
              const hit = (g.transportationCostApply ?? []).find((t: any) => String(t.division) === div && String(t.effectiveDate ?? "").slice(0, 7) === String(p.effective_date ?? "").slice(0, 7) && Number(t.transportationCost) === Number(p.amount) && (p.cap_amount == null || Number(t.transportationCostLimit ?? -1) === Number(p.cap_amount)));
              verified = !!hit; summary = `${PAY_TYPE_LABEL[p.pay_type] ?? p.pay_type}／${yen(p.amount)}${p.cap_amount != null ? `／上限 ${yen(p.cap_amount)}（月額）` : ""}（${String(p.effective_date ?? "").slice(0, 7).replace("-", "/")} から）`;
            } else if (job.kind === "smaregi_tax") {
              const t = { kou: 1, otsu: 2 }[p.tax_category as string];
              const hit = (g.withholdingIncomeTaxes ?? []).find((x: any) => Number(x.type) === t && (p.dependents_count == null || Number(x.dependent) === Number(p.dependents_count)) && (!p.application_ym || String(x.applicationYm ?? "").slice(0, 7) === String(p.application_ym).slice(0, 7)));
              verified = !!hit; summary = `区分 ${p.tax_category === "kou" ? "甲" : "乙"}${p.dependents_count != null ? `／扶養 ${p.dependents_count} 人` : ""}${p.application_ym ? `（${String(p.application_ym).slice(0, 7).replace("-", "/")} から）` : ""}`;
            } else if (job.kind === "smaregi_payslip") {
              verified = g.personalWebStatementScreenDisplayFlag === (p.flag !== false); summary = `個別Web給与明細の表示 ${p.flag !== false ? "ON" : "OFF"}`;
            } else if (job.kind === "smaregi_year_end") {
              // 年末調整: API（GET staffs）の年末調整項目と指示値を照合（世帯主名は先頭 1 文字だけ比べる）
              const y = g.yearEnd ?? {};
              const same = (a: unknown, b: unknown) => String(a ?? "") === String(b ?? "");
              // 実機（2026-11-09）: API は studentFlag "0"／estimateIncome "0"／handicappedDivision "1" のように文字列で返す → "0" を true にしないよう真偽値は明示的に解釈
              const bool = (v: unknown) => v === true || v === 1 || v === "1" || v === "true";
              const checks = [same(y.householdHeaderRelationship ?? "", p.household_header_relationship ?? ""), same(bool(y.spouseFlag), bool(p.spouse_flag)), same(Number(y.estimateIncome ?? 0), Number(p.estimate_income ?? 0)),
                same(Number(y.retirementIncome ?? 0), Number(p.retirement_income ?? 0)), same(Number(y.handicappedDivision ?? 1), Number(p.handicapped_division ?? 1)), same(Number(y.widowDivision2 ?? 1), Number(p.widow_division2 ?? 1)), same(bool(y.studentFlag), bool(p.student_flag)),
                !p.household_header_name || same(String(y.householdHeaderName ?? "").slice(0, 1), String(p.household_header_name).slice(0, 1))];
              verified = checks.every(Boolean); summary = `年末調整（配偶者 ${p.spouse_flag ? "あり" : "なし"}・合計所得見積額 ${yen(p.estimate_income ?? 0)}・勤労学生 ${p.student_flag ? "該当" : "該当しない"}）`;
              await sb.from("employee_year_end").update({ sync_status: verified ? "synced" : "error", sync_error: verified ? null : "保存後の照合で不一致", verified_at: verified ? new Date().toISOString() : null, verified_value: y, updated_at: new Date().toISOString() }).eq("ui_job_id", job.id);
              await sb.from("employee_post_join_status").update({ status: verified ? "synced" : "error", updated_at: new Date().toISOString() }).eq("user_id", job.user_id).eq("track", "year_end").eq("target_year", Number(p.target_year ?? new Date().getFullYear()));
            } else if (job.kind === "smaregi_dependents") {
              // 扶養: API に項目が無い → Mac が保存後に画面を読み直し、氏名・続柄・生年月日で突き合わせた結果（rows_matched / rows_unmatched）で判定（方針⑦）。無ければ行数で判定
              const want = Array.isArray(p.rows) ? p.rows.length : 0; const res: any = job.result ?? {};
              const matched = Number(res.rows_matched ?? -1), unmatched = Number(res.rows_unmatched ?? -1), got = Number(res.rows_after ?? -1);
              verified = want > 0 && (matched >= 0 ? (matched >= want && unmatched === 0) : got >= want);
              summary = `扶養家族 ${want} 人（${matched >= 0 ? `氏名・続柄・生年月日の一致 ${matched} 人／不一致 ${Math.max(unmatched, 0)} 人` : `画面の行数 ${got < 0 ? "不明" : got}`}）`;
              if (verified) await sb.from("employee_dependents").update({ smaregi_synced_at: new Date().toISOString(), updated_at: new Date().toISOString() }).eq("ui_job_id", job.id).eq("is_active", true);
              await sb.from("employee_post_join_status").update({ status: verified ? "synced" : "error", updated_at: new Date().toISOString() }).eq("user_id", job.user_id).eq("track", "dependents").eq("target_year", 0);
            } else if (job.kind === "smaregi_email") {
              // 立会いで確認: 管理画面で入れたメールは本人が登録を完了するまで API の mail に出ない（仮メール）。UI で保存できていれば「仮登録」として完了扱い
              const tmp = !!(job.result as any)?.tmp_email_set;
              verified = !!g.mail_set || tmp; summary = g.mail_set ? `メールアドレス（${g.mail_masked ?? "—"}）` : tmp ? `メールアドレス（仮登録。本人が認証メールの URL から登録を完了すると確定）` : "メールアドレス（未設定）";
            }
            if (verified !== null && job.item_key) {
              await setItem(sb, wf.id, job.item_key, verified ? "completed" : "failed", { ui_job_id: job.id, verified, result: job.result }, null, "auto", verified ? null : "保存後の照合で不一致（スマレジの値が指示と違う）");
              if (job.kind === "smaregi_commute") await sb.from("employee_commute_settings").update({ sync_status: verified ? "synced" : "error", sync_error: verified ? null : "保存後の照合で不一致", verified_at: verified ? new Date().toISOString() : null, verified_value: g.transportationCostApply ?? null, updated_at: new Date().toISOString() }).eq("ui_job_id", job.id);
              if (job.kind === "smaregi_tax") await sb.from("employee_tax_settings").update({ sync_status: verified ? "synced" : "error", sync_error: verified ? null : "保存後の照合で不一致", verified_at: verified ? new Date().toISOString() : null, verified_value: g.withholdingIncomeTaxes ?? null, updated_at: new Date().toISOString() }).eq("ui_job_id", job.id);
            }
          } else summary = `（照合できず: ${g?.error ?? "不明"}）`;
        } else if (job.status === "success" && job.dry_run) {
          const rr: any = job.result ?? {};
          summary = `読み取り結果: ${JSON.stringify({ ...rr, dependents_rows: Array.isArray(rr.dependents_rows) ? `${rr.dependents_rows.length} 行（氏名は Slack に出しません）` : undefined, screenshot: undefined }).slice(0, 300)}`;
          // 読むだけジョブが扶養の表（氏名・続柄・生年月日）を返したら、その 1 人ぶんだけ参考値（snapshot）として取り込む。提出状況は変えない（方針⑥。一括禁止）
          if (job.kind === "smaregi_read" && Array.isArray(rr.dependents_rows) && job.user_id) {
            const { error: ie } = await sb.rpc("post_join_import_snapshot", { p_user: job.user_id, p_year_end: null, p_dependents: rr.dependents_rows, p_actor: null, p_year: null });
            const { data: mine } = await sb.from("employee_dependents").select("name,relationship,birthday").eq("user_id", job.user_id).eq("is_active", true).neq("source", "smaregi_snapshot");
            const key = (x: any) => `${String(x?.name ?? "").replace(/\s+/g, "")}|${x?.relationship ?? ""}|${String(x?.birthday ?? "").slice(0, 10)}`;
            const smr = new Set(rr.dependents_rows.map(key)); const ours = (mine ?? []).map(key);
            const onlyOurs = ours.filter((k) => !smr.has(k)).length, onlySmr = rr.dependents_rows.filter((x: any) => !ours.includes(key(x))).length;
            summary += ie ? `／扶養の取り込みに失敗（${ie.message}）` : `／扶養: スマレジ ${rr.dependents_rows.length} 人を参考値として取り込み${mine?.length ? `（提出 ${mine.length} 人と比べて 提出のみ ${onlyOurs}・スマレジのみ ${onlySmr}）` : "（本人の提出はまだ）"}`;
          }
          // 読むだけジョブ（smaregi_read）が「本人アカウント登録状況」を返したら項目を判定（★ 画面の項目名・値は立会いで確定。Mac 側 tasks/smaregi-ui-settings.js の readOnly が account_status を返す前提）
          const acc = String((job.result as any)?.account_status ?? "");
          if (job.kind === "smaregi_read" && acc) {
            const it = wf.items?.smaregi_account;
            const accJp = String((job.result as any)?.account_status_jp ?? acc);
            if (/registered|登録済/.test(acc) && it?.state !== "completed") { await setItem(sb, wf.id, "smaregi_account", "completed", { ui_job_id: job.id, account_status: acc, verified: true }, null, "auto"); summary += "／本人アカウント: 登録済み → ✅"; }
            else if (!/registered|登録済/.test(acc)) summary += `／本人アカウント: ${accJp}${acc === "invited" ? "（本人が認証メールの URL から登録を完了すると ✅）" : ""}`;
          }
        } else if (job.status === "failed") {
          const preCheck = job.error_kind === "screen_changed" && /^事前確認/.test(String(job.error ?? ""));
          const title = `手動対応${preCheck ? "（書き込み前の確認で中止）" : ""}: ${({ smaregi_commute: "交通費", smaregi_tax: "源泉所得税", smaregi_payslip: "個別Web給与明細", smaregi_email: "メールアドレス", smaregi_year_end: "年末調整", smaregi_dependents: "扶養家族" } as Record<string, string>)[job.kind] ?? job.kind}をスマレジ管理画面で設定`;
          await sb.rpc("onboarding_add_manual_step", { p_workflow: wf.id, p_title: title, p_reason: String(job.error ?? "").slice(0, 200) });
          if (job.kind === "smaregi_year_end") await sb.from("employee_post_join_status").update({ status: "error", updated_at: new Date().toISOString() }).eq("user_id", job.user_id).eq("track", "year_end").eq("target_year", Number((job.payload as any)?.target_year ?? new Date().getFullYear()));
          if (job.kind === "smaregi_dependents") await sb.from("employee_post_join_status").update({ status: "error", updated_at: new Date().toISOString() }).eq("user_id", job.user_id).eq("track", "dependents").eq("target_year", 0);
        }
        await thread(sb, wf, `${job.status === "success" ? "✅" : job.status === "failed" ? (job.error_kind === "screen_changed" && /^事前確認/.test(String(job.error ?? "")) ? "🛑" : "🙋") : "⏳"} スマレジ自動設定（${job.kind}）: ${job.status}${verified === true ? "・照合一致" : verified === false ? "・照合不一致" : ""}`, uiJobResultBlocks(wf, pn?.slack_parent_notification_id ?? null, job, verified, summary), "onboarding_ui_job");
        await refreshParent(sb, (await loadView(sb, wf.id)) ?? wf);
        return json({ ok: true, status: job.status, verified });
      }
      // ---- Phase 4: 中止のあと ----
      case "cancelled": {
        if (!isUuid(body.workflow_id)) return json({ ok: false, error: "workflow_id が不正です" }, 400);
        const wf = await loadView(sb, body.workflow_id);
        if (!wf) return json({ ok: false, error: "見つかりません" }, 404);
        const who = await actorName(sb, isUuid(body.actor_id) ? body.actor_id : null);
        const label: Record<string, string> = { declined_by_person: "本人から入社辞退", no_contact_after_hire: "採用後連絡不通", dropped_during_registration: "入社登録途中離脱", company_reason: "会社都合中止", other: "その他" };
        await thread(sb, wf, `⛔ 入社手続きを中止しました（${who}・${nowJst()}）\n理由: ${label[String(body.reason)] ?? body.reason}${body.note ? `\nメモ: ${String(body.note).slice(0, 300)}` : ""}\n未完了の項目と自動操作は止めました。スマレジの従業員は削除していません（必要なら管理画面で利用 OFF）。本部タスクは手で完了または削除してください。`, undefined, "onboarding_cancelled");
        await refreshParent(sb, wf);
        return json({ ok: true });
      }
      // ---- Phase 2 後半: 本人への連絡（2026-11-09）。既定 person_notify_enabled=false＝文面を作ってスレッドに出すだけ ----
      case "person_contact": {
        if (!isUuid(body.workflow_id)) return json({ ok: false, error: "workflow_id が不正です" }, 400);
        const wf = await loadView(sb, body.workflow_id);
        if (!wf?.user_id) return json({ ok: false, error: "見つかりません" }, 404);
        const kind = String(body.kind ?? "custom");
        const settings = await alertSettings(sb);
        const live = settings.person_notify_enabled === true;
        const who = await actorName(sb, isUuid(body.actor_id) ? body.actor_id : null);
        const { data: cm } = await sb.from("employee_commute").select("claimed_oneway_fare,computed_oneway_fare,route_text").eq("user_id", wf.user_id).maybeSingle();
        const stale = Object.entries(wf.items ?? {}).filter(([, v]: any) => ["pending", "manual_required", "failed", "retry_wait"].includes(v?.state)).map(([k]) => ITEM_ORDER.find((o) => o.key === k)?.label ?? k);
        const text = String(body.text ?? "").trim() || personContactTemplate(kind, { name: wf.user_name ?? "", claimed: cm?.claimed_oneway_fare ?? null, computed: cm?.computed_oneway_fare ?? null, route_text: cm?.route_text ?? null, store_name: wf.store_names, stale_items: stale });
        const ch = await personChannels(sb, wf.user_id);
        const order: string[] = Array.isArray(settings.person_channel_order) ? settings.person_channel_order : ["slack", "line"];
        const available = order.filter((c) => (c === "slack" && ch.slack) || (c === "line" && !!ch.line_user_id)).map((c) => (c === "slack" ? "Slack" : "LINE"));
        let sent = false; let channel: string | null = available[0] ?? null; let err: string | null = null;
        if (live && available.length) {
          for (const c of order) {
            if (c === "slack" && ch.slack) {
              const r = await slackSend({ action: "send", channel_key: `user:${wf.user_id}`, event: "onboarding_person_contact", source: "ef:onboarding-notify", text, ref: { table: "onboarding_workflows", id: wf.id }, ...BOT });
              if (r?.ok) { sent = true; channel = "Slack"; break; } err = `Slack: ${r?.error ?? "失敗"}`;
            } else if (c === "line" && ch.line_user_id) {
              const { data: tk } = await sb.from("app_secrets").select("value").eq("key", "line_channel_token").maybeSingle();
              if (!tk?.value) { err = "LINE: トークン未設定"; continue; }
              const r = await linePush(String(tk.value).trim(), ch.line_user_id, text);
              if (r.ok) { sent = true; channel = "LINE"; break; } err = `LINE: ${r.status} ${r.body}`;
            }
          }
        }
        await event(sb, wf, "person.contact", { kind, channel, sent, live, text, error: err }, isUuid(body.actor_id) ? body.actor_id : null, kind === "commute_question" ? "commute_check" : null);
        await thread(sb, wf, sent ? `📨 本人へ送信（${channel}）: ${text.slice(0, 80)}` : `📨 本人への連絡文を作成（${channel ?? "送信先なし"}）`, personContactResultBlocks(wf, { kind, channel, sent, text, error: err, actor: who }), "onboarding_person_contact");
        return json({ ok: true, sent, channel, live, available, text });
      }
      // ---- Phase 5: スマレジ GET で API 非対応項目（メール・源泉・Web 明細・交通費）の登録を照合し、登録済みなら項目を ✓。本人アカウントは UI 読み取りへ ----
      case "account_check": {
        if (!isUuid(body.workflow_id)) return json({ ok: false, error: "workflow_id が不正です" }, 400);
        const wf = await loadView(sb, body.workflow_id);
        if (!wf?.user_id) return json({ ok: false, error: "見つかりません" }, 404);
        const who = await actorName(sb, isUuid(body.actor_id) ? body.actor_id : null);
        const actor = isUuid(body.actor_id) ? body.actor_id : null;
        if (!wf.smaregi_staff_id || !wf.contract_id) { await thread(sb, wf, `🔎 スマレジ照合: スマレジ従業員がまだ作成されていません（${who}・${nowJst()}）`, undefined, "onboarding_account_check"); return json({ ok: false, error: "スマレジ未作成" }); }
        const g = await smaregi("staff_get", { smaregi_staff_id: wf.smaregi_staff_id, contract_id: wf.contract_id });
        if (!g?.ok) { await thread(sb, wf, `🔎 スマレジ照合に失敗: ${g?.error ?? "不明"}（${who}・${nowJst()}）`, undefined, "onboarding_account_check"); return json({ ok: false, error: g?.error }); }
        const items = wf.items ?? {};
        const lines: string[] = []; const done: string[] = [];
        const mark = async (key: string, ok: boolean, label: string, detail: string, payload: Record<string, unknown>) => {
          const st = items[key]?.state;
          if (ok && st !== "completed" && st !== "cancelled") { await setItem(sb, wf.id, key, "completed", { ...payload, verified: true, verified_by: "staff_get", verified_at: new Date().toISOString() }, actor, actor ? "slack" : "auto"); done.push(label); }
          lines.push(`${ok ? "✅" : "⬜"} ${label}: ${detail}`);
        };
        // 実機で確認（2026-11-09・従業員 378）: 未設定でもスマレジは transportationCostApply に「division 0・金額 0・effectiveDate 1970-01-01」の初期行を返す → 金額 0 かつ 1970 年の行は「未登録」とみなす
        const tcAll: any[] = Array.isArray(g.transportationCostApply) ? g.transportationCostApply : [];
        const tc: any[] = tcAll.filter((t) => Number(t?.transportationCost ?? 0) > 0 || (String(t?.effectiveDate ?? "").slice(0, 4) > "1990" && t?.transportationCostLimit != null));
        const wt: any[] = (Array.isArray(g.withholdingIncomeTaxes) ? g.withholdingIncomeTaxes : []).filter((x: any) => x && (Number(x.type) === 1 || Number(x.type) === 2));
        await mark("email", !!g.mail_set, "メールアドレス", g.mail_set ? `登録済み（${g.mail_masked ?? "***"}）` : "未登録", { mail_masked: g.mail_masked ?? null });
        await mark("withholding_tax", wt.length > 0, "源泉所得税", wt.length ? `登録済み（区分 ${wt.map((x) => (Number(x.type) === 1 ? "甲" : Number(x.type) === 2 ? "乙" : x.type)).join("/")}）` : "未登録", { withholding: wt.map((x) => ({ type: x.type, dependent: x.dependent, applicationYm: x.applicationYm })) });
        await mark("web_payslip", g.personalWebStatementScreenDisplayFlag === true, "個別Web給与明細の表示", g.personalWebStatementScreenDisplayFlag === true ? "ON" : g.personalWebStatementScreenDisplayFlag === false ? "OFF（未設定）" : "不明", { flag: g.personalWebStatementScreenDisplayFlag ?? null });
        await mark("commute_set", tc.length > 0, "交通費", tc.length ? `登録済み（${tc.map((t) => `${({ "0": "勤務回数ごと", "1": "月額", "2": "勤務日数ごと" } as Record<string, string>)[String(t.division)] ?? t.division} ${yen(t.transportationCost)}${t.transportationCostLimit != null ? `／上限 ${yen(t.transportationCostLimit)}` : ""}`).join("、")}）` : "未登録", { transportation: tc });
        // 本人アカウント登録状況: API（GET staffs）に項目が無い（2026-11-09 公開リファレンスで確認）→ 管理画面の読み取りジョブ（立会い後・account_ui_read_enabled=true）
        const settings = await alertSettings(sb);
        let accNote = "";
        if (items.smaregi_account?.state === "completed") accNote = "✅ 本人アカウント登録: 確認済み";
        else if (settings.account_ui_read_enabled === true) {
          const { data: jb, error: je } = await sb.rpc("ui_job_enqueue", { p_workflow: wf.id, p_kind: "smaregi_read", p_payload: { read: ["account_status"] }, p_actor: actor, p_dry_run: true });
          accNote = je ? `⚠️ 本人アカウント登録: 読み取りジョブを作れません（${je.message}）` : jb?.ok ? `⏳ 本人アカウント登録: 管理画面の読み取りジョブを登録しました${jb.duplicate ? "（既に待機中）" : ""}（Mac の自動操作が結果を返します）` : `⚠️ 本人アカウント登録: ${jb?.error ?? "読み取りジョブを作れません"}`;
        } else accNote = "⬜ 本人アカウント登録: API に項目が無いため自動確認できません（管理画面の読み取りは立会い後に有効化）。管理画面で確認し本部タスクで ✓";
        lines.push(accNote);
        if (g.activeFlag !== null && g.activeFlag !== undefined) lines.push(`ℹ️ スマレジの利用: ${String(g.activeFlag) === "1" || g.activeFlag === true ? "利用可能" : "利用不可"}${g.terminationFlag && String(g.terminationFlag) === "1" ? "・退職済み" : ""}`);
        await event(sb, wf, "account.checked", { done, mail_set: !!g.mail_set, tax: wt.length, payslip: g.personalWebStatementScreenDisplayFlag ?? null, commute: tc.length }, actor);
        await thread(sb, wf, `🔎 スマレジ照合（${who}・${nowJst()}）\n${lines.join("\n")}${done.length ? `\n→ ${done.join("・")} を ✅ にしました（スマレジ GET で登録を確認）` : ""}`, undefined, "onboarding_account_check");
        await refreshParent(sb, (await loadView(sb, wf.id)) ?? wf);
        return json({ ok: true, done, lines });
      }
      // ---- Phase 5: 停滞アラート（pg_cron → onboarding_stale_alert_trigger）。enabled=false か dry_run は候補を返すだけ ----
      case "stale_alert": {
        const settings = await alertSettings(sb);
        const staleH = Number(settings.stale_hours ?? 48), repeatH = Number(settings.repeat_hours ?? 24);
        const qFrom = Number(settings.quiet_from ?? 22), qTo = Number(settings.quiet_to ?? 8);
        const ignore: string[] = Array.isArray(settings.ignore_items) ? settings.ignore_items : [];
        const h = jstHour();
        const quiet = qFrom > qTo ? (h >= qFrom || h < qTo) : (h >= qFrom && h < qTo);
        const { data: rows } = await sb.from("onboarding_stale_v").select("*").gte("hours_stalled", staleH);
        const byWf = new Map<string, any[]>();
        for (const r of rows ?? []) { if (ignore.includes(r.item_key)) continue; const a = byWf.get(r.workflow_id) ?? []; a.push(r); byWf.set(r.workflow_id, a); }
        const ids = [...byWf.keys()];
        const { data: wfs } = ids.length ? await sb.from("onboarding_workflows").select("id,last_stale_alert_at,slack_parent_ts,user_id").in("id", ids) : { data: [] };
        const cutoff = Date.now() - repeatH * 3600_000;
        const targets = (wfs ?? []).filter((w: any) => !w.last_stale_alert_at || new Date(w.last_stale_alert_at).getTime() < cutoff);
        const candidates = targets.map((w: any) => { const its = byWf.get(w.id) ?? []; return { workflow_id: w.id, user_name: its[0]?.user_name ?? null, hire_date: its[0]?.hire_date ?? null, user_id: w.user_id, has_parent: !!w.slack_parent_ts, items: its.map((i: any) => ({ key: i.item_key, label: ITEM_ORDER.find((o) => o.key === i.item_key)?.label ?? i.item_key, state: i.state, hours: Number(i.hours_stalled), last_error: i.last_error })), hours: Math.max(...its.map((i: any) => Number(i.hours_stalled))) }; });
        const live = settings.enabled === true && body.dry_run !== true;
        if (!live) return json({ ok: true, sent: false, reason: settings.enabled !== true ? "disabled" : "dry_run", quiet, candidates });
        if (quiet) return json({ ok: true, sent: false, reason: "quiet_hours", candidates });
        const summary: any[] = [];
        for (const c of candidates) {
          const wf = await loadView(sb, c.workflow_id); if (!wf) continue;
          if (c.has_parent) await thread(sb, wf, staleAlertThreadText(c.items, wf.hire_date), undefined, "onboarding_stale_alert");
          await sb.from("onboarding_workflows").update({ last_stale_alert_at: new Date().toISOString(), updated_at: new Date().toISOString() }).eq("id", c.workflow_id);
          await event(sb, wf, "stale.alerted", { items: c.items.map((i: any) => i.key), hours: c.hours });
          summary.push({ name: wf.user_name ?? "（氏名不明）", hire_date: wf.hire_date, items: c.items.map((i: any) => i.label), hours: c.hours, link: wf.user_id ? `https://mirai-oss.github.io/nippo/?page=admin&u=${wf.user_id}` : null });
        }
        if (summary.length) await slackSend({ action: "send", channel_key: settings.channel_key ?? "hq.jinji", event: "onboarding_stale_summary", source: "ef:onboarding-notify", text: `⏰ 入社手続きの停滞 ${summary.length} 人`, blocks: staleAlertSummaryBlocks(summary), dedupe_key: `onboarding:stale:${new Date().toISOString().slice(0, 10)}`, ...BOT });
        return json({ ok: true, sent: true, count: summary.length, candidates });
      }
      // ---- Phase 6: 本人提出（年末調整・扶養）のあと ----
      case "post_join_submitted": {
        const kind = String(body.kind ?? "");
        if (!["year_end", "dependents"].includes(kind)) return json({ ok: false, error: "kind は year_end か dependents" }, 400);
        let wf: WorkflowView | null = null;
        if (isUuid(body.workflow_id)) wf = await loadView(sb, body.workflow_id);
        else if (isUuid(body.user_id)) { const { data } = await sb.from("onboarding_workflow_v").select("*").eq("user_id", body.user_id).maybeSingle(); wf = (data as WorkflowView) ?? null; }
        if (!wf?.user_id) return json({ ok: false, error: "ワークフローが見つかりません" }, 404);
        const { data: pn } = await sb.from("onboarding_workflows").select("slack_parent_notification_id").eq("id", wf.id).maybeSingle();
        const info: any = {};
        const year = Number.isInteger(body.target_year) ? Number(body.target_year) : null;
        const { data: pol } = await sb.rpc("post_join_effective_i", { p_user: wf.user_id, p_track: kind, p_year: kind === "year_end" ? year : 0 });
        info.policy = pol ?? null; info.status = pol?.status ?? "submitted"; info.target_year = kind === "year_end" ? (pol?.target_year ?? year) : null;
        if (kind === "year_end") { const { data: y } = await sb.from("employee_year_end").select("spouse_flag,student_flag,submitted_via").eq("user_id", wf.user_id).eq("target_year", info.target_year ?? pol?.target_year).maybeSingle(); Object.assign(info, { spouse_flag: y?.spouse_flag ?? null, student_flag: y?.student_flag ?? null, via: y?.submitted_via ?? null }); }
        else { const { data: ds } = await sb.from("employee_dependents").select("relationship").eq("user_id", wf.user_id).eq("is_active", true).neq("source", "smaregi_snapshot"); Object.assign(info, { count: (ds ?? []).length, relationships: (ds ?? []).map((d: any) => d.relationship) }); }
        await thread(sb, wf, kind === "year_end" ? `📝 本人が年末調整${info.target_year ? ` ${info.target_year} 年度` : ""}の情報を提出しました` : `📝 本人が扶養家族を提出しました（${info.count ?? 0} 人）`, postJoinSubmittedBlocks(wf, pn?.slack_parent_notification_id ?? null, kind as "year_end" | "dependents", info), "onboarding_post_join_submitted");
        await event(sb, wf, "post_join.notified", { kind, ...info });
        await refreshParent(sb, wf);
        return json({ ok: true, kind, info });
      }
      // 承認／差し戻しのあと（slack-interact が RPC を呼んだあとに通知）
      case "post_join_decided": {
        if (!isUuid(body.workflow_id)) return json({ ok: false, error: "workflow_id が不正です" }, 400);
        const wf = await loadView(sb, body.workflow_id);
        if (!wf?.user_id) return json({ ok: false, error: "見つかりません" }, 404);
        const who = await actorName(sb, isUuid(body.actor_id) ? body.actor_id : null);
        const track = String(body.track ?? ""); const label = POST_JOIN_TRACK_LABEL[track] ?? track; const yr = body.target_year ? ` ${body.target_year} 年度` : "";
        const j = body.job ?? null;
        const text = body.decision === "approved"
          ? `✅ ${label}${yr}の提出を承認しました（${who}・${nowJst()}）${body.note ? `\nメモ: ${String(body.note).slice(0, 200)}` : ""}\n` +
            (j === null ? "（扶養なしのためスマレジへの反映はありません）" : j?.ok ? `⏳ Mac の自動操作でスマレジに反映します（数分〜）。結果はこのスレッドに届きます${j.duplicate ? "（既に待機中のジョブがあります）" : ""}` : `🙋 スマレジへの自動反映は未有効化です。*スマレジ管理画面（${track === "year_end" ? "年末調整 → 設定を編集" : "扶養設定 → 設定を編集 → 扶養親族を追加"}）に nippo の従業員編集の内容を入力*してください${j?.error ? `（${String(j.error).slice(0, 120)}）` : ""}`)
          : `↩️ ${label}${yr}の提出を差し戻しました（${who}・${nowJst()}）${body.note ? `\n理由: ${String(body.note).slice(0, 200)}` : ""}\n本人に「📨 本人へ連絡」で直してもらう内容を伝えてください（提出内容は残っています）`;
        await thread(sb, wf, text, undefined, "onboarding_post_join_decided");
        await refreshParent(sb, wf);
        return json({ ok: true });
      }
      // スマレジと比較: 年末調整＝API の値と提出内容の差分。扶養＝読むだけジョブ（画面の表を読む）を積む
      case "post_join_compare": {
        if (!isUuid(body.workflow_id)) return json({ ok: false, error: "workflow_id が不正です" }, 400);
        const wf = await loadView(sb, body.workflow_id);
        if (!wf?.user_id) return json({ ok: false, error: "見つかりません" }, 404);
        const who = await actorName(sb, isUuid(body.actor_id) ? body.actor_id : null);
        const track = String(body.track ?? "");
        if (!wf.smaregi_staff_id || !wf.contract_id) { await thread(sb, wf, `🔎 比較: スマレジ従業員がまだ作成されていません（${who}）`, undefined, "onboarding_post_join_compare"); return json({ ok: false, error: "スマレジ未作成" }); }
        if (track === "year_end") {
          const { data: pol } = await sb.rpc("post_join_effective_i", { p_user: wf.user_id, p_track: "year_end", p_year: Number.isInteger(body.target_year) ? body.target_year : null });
          const year = pol?.target_year;
          const [{ data: y }, g] = await Promise.all([sb.from("employee_year_end").select("*").eq("user_id", wf.user_id).eq("target_year", year).maybeSingle(), smaregi("staff_get", { smaregi_staff_id: wf.smaregi_staff_id, contract_id: wf.contract_id })]);
          if (!g?.ok) { await thread(sb, wf, `🔎 比較に失敗: ${g?.error ?? "不明"}（${who}）`, undefined, "onboarding_post_join_compare"); return json({ ok: false, error: g?.error }); }
          if (g.yearEnd) await sb.rpc("post_join_import_snapshot", { p_user: wf.user_id, p_year_end: g.yearEnd, p_dependents: null, p_actor: isUuid(body.actor_id) ? body.actor_id : null, p_year: year });
          const text = y ? `🔎 *年末調整 ${year} 年度: 提出内容 と スマレジの今の値*（${who}・${nowJst()}）\n${yearEndCompareText(y, g.yearEnd ?? null)}` : `🔎 年末調整 ${year} 年度: 本人の提出はまだありません。スマレジの今の値を参考値として取り込みました（本人フォームの初期値に出ます）`;
          await thread(sb, wf, text, undefined, "onboarding_post_join_compare");
          return json({ ok: true, snapshot: !!g.yearEnd });
        }
        const { data: jb, error: je } = await sb.rpc("ui_job_enqueue", { p_workflow: wf.id, p_kind: "smaregi_read", p_payload: { read: ["dependents"], snapshot: true }, p_actor: isUuid(body.actor_id) ? body.actor_id : null, p_dry_run: true });
        await thread(sb, wf, je ? `🔎 扶養家族の読み取りジョブを作れません（${je.message}）` : jb?.ok ? `🔎 扶養家族: スマレジ管理画面の扶養設定を読み取るジョブを登録しました（${who}・${nowJst()}）。読めたら参考値として取り込み、提出内容との差をこのスレッドに出します${jb.duplicate ? "（既に待機中）" : ""}` : `🔎 扶養家族: ${jb?.error ?? "読み取りジョブを作れません"}`, undefined, "onboarding_post_join_compare");
        return json({ ok: !je && !!jb?.ok, job: jb ?? null });
      }
      // 既存従業員: スマレジの内容を 1 人ぶん取り込む（年末調整＝API・扶養＝読むだけジョブ）。本人の提出状況は変えない（方針⑥）
      case "post_join_snapshot": {
        let wf: WorkflowView | null = null;
        if (isUuid(body.workflow_id)) wf = await loadView(sb, body.workflow_id);
        else if (isUuid(body.user_id)) { const { data } = await sb.from("onboarding_workflow_v").select("*").eq("user_id", body.user_id).maybeSingle(); wf = (data as WorkflowView) ?? null; }
        const userId = wf?.user_id ?? (isUuid(body.user_id) ? body.user_id : null);
        if (!userId) return json({ ok: false, error: "user_id か workflow_id" }, 400);
        const { data: link } = await sb.from("employee_smaregi_links").select("contract_id,smaregi_staff_id").eq("user_id", userId).is("effective_to", null).order("is_primary", { ascending: false }).limit(1).maybeSingle();
        if (!link) return json({ ok: false, error: "スマレジに紐づいていません" });
        const g = await smaregi("staff_get", { smaregi_staff_id: String(link.smaregi_staff_id), contract_id: link.contract_id });
        if (!g?.ok) return json({ ok: false, error: g?.error ?? "取得失敗" });
        const { data: imp, error: ie } = await sb.rpc("post_join_import_snapshot", { p_user: userId, p_year_end: g.yearEnd ?? null, p_dependents: null, p_actor: isUuid(body.actor_id) ? body.actor_id : null, p_year: null });
        let job: any = null;
        if (wf) { const { data: jb } = await sb.rpc("ui_job_enqueue", { p_workflow: wf.id, p_kind: "smaregi_read", p_payload: { read: ["dependents"], snapshot: true }, p_actor: isUuid(body.actor_id) ? body.actor_id : null, p_dry_run: true }); job = jb ?? null; }
        if (wf) await thread(sb, wf, `📥 スマレジの内容を参考値として取り込みました（年末調整: ${g.yearEnd ? "取得" : "なし"}／扶養: ${job?.ok ? "読み取りジョブを登録" : "ワークフロー無しのため手動"}）。本人の提出状況は変えていません`, undefined, "onboarding_post_join_snapshot");
        return json({ ok: !ie, imported: imp ?? null, job, error: ie?.message });
      }
      case "tax_setting_saved": {
        if (!isUuid(body.workflow_id)) return json({ ok: false, error: "workflow_id が不正です" }, 400);
        const wf = await loadView(sb, body.workflow_id);
        if (!wf?.user_id) return json({ ok: false, error: "見つかりません" }, 404);
        const { data: t } = await sb.from("employee_tax_settings").select("tax_category,application_ym,spouse_deduction_division,dependents_count,sync_status,sync_error").eq("user_id", wf.user_id).maybeSingle();
        const who = await actorName(sb, isUuid(body.actor_id) ? body.actor_id : null);
        const spouse = ({ 0: "対象でない", 1: "源泉控除対象(配偶者控除対象)", 2: "源泉控除対象(配偶者特別控除対象)" } as Record<number, string>)[Number(t?.spouse_deduction_division ?? 0)] ?? "—";
        const line = `・適用開始月 ${String(t?.application_ym ?? "").replace("-", "/")}／区分 ${t?.tax_category === "otsu" ? "乙" : "甲"}／配偶者区分 ${spouse}／親族の数 ${t?.dependents_count ?? 0} 人`;
        const tail = t?.sync_status === "manual" ? "🙋 スマレジへの自動反映はまだ有効化されていません。*スマレジ管理画面（給与設定 → 源泉所得税設定を追加）にこの値を入力*し、本部タスクの「源泉所得税」に ✓ を付けてください" : "⏳ Mac の自動操作でスマレジに反映します（数分〜）。結果はこのスレッドに届きます";
        await thread(sb, wf, `🧾 源泉所得税の設定を登録しました（${who}・${nowJst()}）\n${line}\n${tail}`, undefined, "onboarding_tax_setting");
        await refreshParent(sb, wf);
        return json({ ok: true });
      }
      case "post_join_remind": {
        // v2: 必須かつ未完了（RPC onboarding_post_join_targets＝雇用区分の標準ルール＋個別上書き、期限前後で間隔が変わる）。既定 OFF。Slack DM → LINE の順
        const settings = await alertSettings(sb);
        const startDays = Number(settings.post_join_remind_days ?? 3);
        const { data: targets, error: te } = await sb.rpc("onboarding_post_join_targets", { p_now: new Date().toISOString(), p_start_days: startDays });
        if (te) return json({ ok: false, error: te.message }, 500);
        // 1 人にまとめる（扶養・年末調整の両方が対象なら 1 通）
        const byUser = new Map<string, any>();
        for (const t of targets ?? []) { const a = byUser.get(t.user_id) ?? { ...t, tracks: [] as any[] }; a.tracks.push(t); byUser.set(t.user_id, a); }
        const due = [...byUser.values()];
        const live = settings.post_join_remind_enabled === true && body.dry_run !== true;
        const h = jstHour(); const qFrom = Number(settings.quiet_from ?? 22), qTo = Number(settings.quiet_to ?? 8);
        const quiet = qFrom > qTo ? (h >= qFrom || h < qTo) : (h >= qFrom && h < qTo);
        const summarize = (u: any) => ({ user_id: u.user_id, name: u.name, class: u.class, hire_date: u.hire_date, tracks: u.tracks.map((t: any) => ({ track: t.track, target_year: t.target_year, deadline: t.deadline, required_source: t.required_source, interval_days: t.interval_days, remind_count: t.remind_count })), has_slack: u.has_slack, has_line: u.has_line });
        if (!live) return json({ ok: true, sent: 0, reason: settings.post_join_remind_enabled !== true ? "disabled" : "dry_run", candidates: due.map(summarize) });
        if (quiet) return json({ ok: true, sent: 0, reason: "quiet_hours", candidates: due.length });
        let sent = 0; const results: any[] = [];
        for (const u of due) {
          const wf = u.workflow_id ? await loadView(sb, u.workflow_id) : null;
          const items = u.tracks.map((t: any) => POST_JOIN_TRACK_LABEL[t.track] + (t.target_year ? ` ${t.target_year} 年度` : ""));
          const deadlines = u.tracks.map((t: any) => t.deadline).filter(Boolean).sort();
          const text = personContactTemplate("post_join_form", { name: u.name ?? "", stale_items: items, deadline: deadlines[0] ? jpDate(deadlines[0]) : null });
          const ch = await personChannels(sb, u.user_id);
          let channel: string | null = null; let ok = false; let err: string | null = null;
          if (ch.slack) { const r = await slackSend({ action: "send", channel_key: `user:${u.user_id}`, event: "onboarding_post_join_remind", source: "ef:onboarding-notify", text, ref: wf ? { table: "onboarding_workflows", id: wf.id } : undefined, ...BOT }); ok = !!r?.ok; channel = "Slack"; err = ok ? null : r?.error ?? "失敗"; }
          if (!ok && ch.line_user_id) { const { data: tk } = await sb.from("app_secrets").select("value").eq("key", "line_channel_token").maybeSingle(); if (tk?.value) { const r = await linePush(String(tk.value).trim(), ch.line_user_id, text); ok = r.ok; channel = "LINE"; err = ok ? null : `${r.status}`; } }
          if (ok) { sent++; for (const t of u.tracks) await sb.rpc("onboarding_post_join_reminded", { p_user: u.user_id, p_track: t.track, p_year: t.target_year ?? 0 }); }
          if (wf) {
            await event(sb, wf, "post_join.reminded", { channel, sent: ok, tracks: u.tracks.map((t: any) => t.track), error: err });
            await thread(sb, wf, ok ? `📨 ${items.join("・")}のフォームのお願いを本人へ送りました（${channel}・${(u.tracks[0]?.remind_count ?? 0) + 1} 回目・必須: ${u.tracks.map((t: any) => t.required_source === "override" ? "個別設定" : "標準ルール").join("/")}）` : `⚠️ ${items.join("・")}のフォームのお願いを送れませんでした（Slack/LINE とも未連携か失敗: ${err ?? "連絡先なし"}）。店長から声かけをお願いします`, undefined, "onboarding_post_join_remind");
          }
          results.push({ user_id: u.user_id, channel, sent: ok, tracks: u.tracks.length });
        }
        return json({ ok: true, sent, results });
      }
      case "status": {
        let q = sb.from("onboarding_workflow_v").select("*");
        if (isUuid(body.workflow_id)) q = q.eq("id", body.workflow_id); else if (isUuid(body.user_id)) q = q.eq("user_id", body.user_id); else return json({ ok: false, error: "workflow_id か user_id" }, 400);
        const { data } = await q.maybeSingle();
        return json({ ok: !!data, workflow: data ?? null });
      }
      default: return json({ ok: false, error: "不明な op" }, 400);
    }
  } catch (e) {
    return json({ ok: false, error: String((e as Error).message ?? e).slice(0, 300) }, 500);
  }
});
