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
//   デプロイ: supabase functions deploy onboarding-notify --no-verify-jwt --project-ref uuvsxzhpxtghojoubjcc --yes（関数内で認証するため）
// =============================================================
import { createClient } from "npm:@supabase/supabase-js@2";
import { parentMessage, wageFailedBlocks, wageDateAdjustedBlocks, wageLine, nowJst, type WorkflowView } from "../_shared/onboarding-blocks.ts";

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
