import { assert, assertEquals, assertNotEquals } from "jsr:@std/assert@1";
import {
  alertFixButton, alertFormRow, alertFormUrl, alertStatusMessage, ATTENDANCE_FORM_URL, BREAK_NOT_READY, breakDeclareArgs, fixApprovalSend, fixFormLinkText,
  fixRequestArgs, fixRequestedParentText, isFormLinkPress, isMissingRpc, isoToJstLocal, isUuid, jstLocalToIso, unixToIso,
} from "./attendance-fix-notify.ts";

const ALERT = "11111111-2222-4333-8444-555555555555";
const NID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
const USER = "99999999-8888-4777-8666-555555555555";

// ---- ボタン定義 ----
Deno.test("修正ボタン: url はフォーム＋?alert=<id>・action_id は従来どおり・value に form:1 の印と従来の項目", () => {
  const b = alertFixButton({ alertId: ALERT, notificationId: NID, title: "11/10（火）　テスト店　テスト 太郎", in: 1762758000, out: null, b1s: 1762765200, b1e: 1762768800 });
  assertEquals(b.type, "button");
  assertEquals(b.action_id, "attendance.alert.fix", "action_id は変えない（古いボタンと同じ入口）");
  assertEquals(b.url, `https://mirai-oss.github.io/ns-portal/kintai.html?alert=${ALERT}`);
  assertEquals(b.url, alertFormUrl(ALERT));
  assert(b.url.startsWith(ATTENDANCE_FORM_URL + "?alert="));
  assertEquals(b.text, { type: "plain_text", text: "✏️ 修正する（フォームを開く）", emoji: true });
  const v = JSON.parse(b.value);
  assertEquals(v, { alert_id: ALERT, notification_id: NID, in: 1762758000, out: null, title: "11/10（火）　テスト店　テスト 太郎", b1s: 1762765200, b1e: 1762768800, b2s: null, b2e: null, form: 1 });
  assert(!("style" in b), "色は付けない（従来どおり）");
});
Deno.test("修正ボタン: Slack の上限（value 2000 字・url 3000 字・文言 75 字）に収まる", () => {
  const b = alertFixButton({ alertId: ALERT, notificationId: NID, title: "あ".repeat(200), in: 1, out: 2, b1s: 3, b1e: 4, b2s: 5, b2e: 6 });
  assert(b.value.length <= 2000, `value ${b.value.length}`);
  assert(b.url.length <= 3000);
  assert([...b.text.text].length <= 75);
});
Deno.test("url 付きで押されたかの判定: form:1 だけ true。古いボタンの value・壊れた value は false", () => {
  assertEquals(isFormLinkPress(JSON.parse(alertFixButton({ alertId: ALERT, notificationId: NID, title: "t" }).value)), true);
  // 2026-11-12 より前のボタン（url なし）の value
  assertEquals(isFormLinkPress({ alert_id: ALERT, notification_id: NID, in: 1, out: 2, title: "t", b1s: null, b1e: null, b2s: null, b2e: null }), false);
  assertEquals(isFormLinkPress({ alert_id: ALERT, form: "1" }), false);
  assertEquals(isFormLinkPress(null), false);
  assertEquals(isFormLinkPress("form"), false);
  assertEquals(isFormLinkPress(undefined), false);
});
Deno.test("古いボタンへの返信: フォームのリンク（mrkdwn）と対象の見出し", () => {
  const t = fixFormLinkText(ALERT, "11/10（火）　テスト店　テスト 太郎");
  assert(t.startsWith(`✏️ <https://mirai-oss.github.io/ns-portal/kintai.html?alert=${ALERT}|修正フォームを開く>（11/10（火）　テスト店　テスト 太郎）\n`));
  assert(fixFormLinkText(ALERT, null).startsWith(`✏️ <${alertFormUrl(ALERT)}|修正フォームを開く>\n`));
});

// ---- 時刻 ----
Deno.test("JST の文字列 ⇔ ISO（op=day と同じ形）", () => {
  assertEquals(jstLocalToIso("2026-11-10T17:00"), "2026-11-10T17:00:00+09:00");
  assertEquals(jstLocalToIso("2026-11-11T00:10:30"), "2026-11-11T00:10:30+09:00");
  assertEquals(new Date(jstLocalToIso("2026-11-11T00:10")!).toISOString(), "2026-11-10T15:10:00.000Z");
  for (const bad of ["", "17:00", "2026-11-10", "2026-13-10T17:00", "2026-11-10T24:00", "2026-11-10T17:60", "2026-11-10T17:00Z", null, undefined, 5, {}]) assertEquals(jstLocalToIso(bad), null, String(bad));
  assertEquals(isoToJstLocal("2026-11-10T15:10:00+00:00"), "2026-11-11T00:10");
  assertEquals(isoToJstLocal("2026-11-10T08:00:00.000Z"), "2026-11-10T17:00");
  assertEquals(isoToJstLocal(null), null);
  assertEquals(isoToJstLocal("x"), null);
  // 往復
  assertEquals(isoToJstLocal(jstLocalToIso("2026-12-31T23:59")), "2026-12-31T23:59");
  assertEquals(unixToIso(1762758000), "2025-11-10T07:00:00.000Z");
  assertEquals(unixToIso("1762758000"), "2025-11-10T07:00:00.000Z");
  assertEquals(unixToIso(null), null);
  assertEquals(unixToIso(undefined), null);
  assertEquals(unixToIso("abc"), null);
});

// ---- RPC の引数 ----
Deno.test("fix_request の引数: 以前の slack-interact（モーダル送信）と同じ形・同じ値", () => {
  // 変更前のコードの写し（slack-interact/index.ts 144-151 行）
  const before = (meta: any, actor: any, start: number, end: number, reason: string, v: any, noBreak: boolean) => {
    const pick = (b: string) => noBreak ? null : (v[b]?.[b]?.selected_date_time ? new Date(Number(v[b][b].selected_date_time) * 1000).toISOString() : null);
    return {
      p_alert_id: meta.alert_id, p_actor: actor.user_id,
      p_clock_in: new Date(Number(start) * 1000).toISOString(), p_clock_out: new Date(Number(end) * 1000).toISOString(),
      p_reason: reason, p_via: "slack",
      p_break_start_1: pick("b1s"), p_break_end_1: pick("b1e"), p_break_start_2: pick("b2s"), p_break_end_2: pick("b2e"),
    };
  };
  const v: any = { b1s: { b1s: { selected_date_time: 1762765200 } }, b1e: { b1e: { selected_date_time: 1762768800 } }, b2s: { b2s: {} }, b2e: {} };
  for (const noBreak of [false, true]) {
    const pick = (b: string) => v[b]?.[b]?.selected_date_time ? unixToIso(v[b][b].selected_date_time) : null;
    const now = fixRequestArgs({ alertId: ALERT, actorId: USER, clockIn: unixToIso(1762758000)!, clockOut: unixToIso(1762790400)!, reason: "退勤の打刻忘れ", via: "slack",
      breaks: { b1s: pick("b1s"), b1e: pick("b1e"), b2s: pick("b2s"), b2e: pick("b2e") }, noBreak });
    assertEquals(now, before({ alert_id: ALERT }, { user_id: USER }, 1762758000, 1762790400, "退勤の打刻忘れ", v, noBreak));
    assertEquals(Object.keys(now), ["p_alert_id", "p_actor", "p_clock_in", "p_clock_out", "p_reason", "p_via", "p_break_start_1", "p_break_end_1", "p_break_start_2", "p_break_end_2"]);
  }
});
Deno.test("fix_request の引数: フォームから（JST の文字列）。同じ瞬間なら Slack と同じ時刻になる・no_break は休憩を全部 null", () => {
  const a = fixRequestArgs({ alertId: ALERT, actorId: USER, clockIn: jstLocalToIso("2026-11-10T17:00")!, clockOut: jstLocalToIso("2026-11-11T01:00")!, reason: "r", via: "form",
    breaks: { b1s: jstLocalToIso("2026-11-10T20:00"), b1e: jstLocalToIso("2026-11-10T21:00") } });
  assertEquals(a.p_via, "form");
  assertEquals(new Date(a.p_clock_in).getTime(), new Date("2026-11-10T08:00:00Z").getTime());
  assertEquals(new Date(a.p_clock_out).getTime() - new Date(a.p_clock_in).getTime(), 8 * 3600 * 1000);
  assertEquals([a.p_break_start_1, a.p_break_end_1, a.p_break_start_2, a.p_break_end_2], ["2026-11-10T20:00:00+09:00", "2026-11-10T21:00:00+09:00", null, null]);
  const nb = fixRequestArgs({ alertId: ALERT, actorId: USER, clockIn: "x", clockOut: "y", reason: "r", via: "form", breaks: { b1s: "a", b1e: "b", b2s: "c", b2e: "d" }, noBreak: true });
  assertEquals([nb.p_break_start_1, nb.p_break_end_1, nb.p_break_start_2, nb.p_break_end_2], [null, null, null, null]);
});

// ---- 通知の文面 ----
const REQ = { alertId: ALERT, summary: "11/10（火）　テスト店　テスト 太郎　17:00−退勤なし（0時間0分・休憩なし）", proposed: "17:00−翌01:00（8時間0分・休憩なし）", reason: "退勤の打刻忘れ", actorName: "店長 花子" };
Deno.test("元メッセージの書き換え文面: 以前の slack-interact と一字一句同じ", () => {
  const actor = { name: REQ.actorName }, data = { summary: REQ.summary, proposed: REQ.proposed, reason: REQ.reason }, when = "2026/11/11 10:05:00";
  const before = `📝 修正を申請しました（${actor.name}・${when}）\n${data.summary}\n→ 修正後 ${data.proposed}　理由: ${data.reason}\n承認待ち（マスター）`;
  assertEquals(fixRequestedParentText({ ...REQ, when }), before);
});
Deno.test("承認依頼: 以前の本文・ボタン・dedupe_key と同じ ＋ 抜けていた ref・username・icon_emoji が入る（2026-11-12 の修正）", () => {
  const ch = "user:" + USER;
  const s = fixApprovalSend({ ...REQ, notificationId: NID, channelKey: ch, source: "ef:slack-interact" });
  // 変更前に実際に送られていた項目（行末コメントに飲まれなかった分）の写し
  const data = { alert_id: ALERT, summary: REQ.summary, proposed: REQ.proposed, reason: REQ.reason }, actor = { name: REQ.actorName }, nid = NID;
  const val = JSON.stringify({ alert_id: data.alert_id, notification_id: nid });
  const before = {
    action: "send", notification_id: nid, channel_key: ch, event: "attendance_fix_request", source: "ef:slack-interact",
    text: `🙋 勤怠修正の承認依頼 ${data.summary} → ${data.proposed}`,
    blocks: [
      { type: "section", text: { type: "mrkdwn", text: `🙋 *勤怠修正の承認依頼*\n${data.summary}\n申請: ${actor.name}\n*修正後: ${data.proposed}*\n理由: ${data.reason}` } },
      { type: "actions", block_id: "attendance_fix", elements: [
        { type: "button", style: "primary", text: { type: "plain_text", text: "✅ 承認", emoji: true }, action_id: "attendance.fix.approve", value: val },
        { type: "button", style: "danger", text: { type: "plain_text", text: "❌ 却下", emoji: true }, action_id: "attendance.fix.reject", value: val },
      ] },
      { type: "context", elements: [{ type: "mrkdwn", text: `確認 \`${String(data.alert_id).slice(0, 8)}\`・承認すると管理システムの勤怠実績に反映（スマレジ側の打刻は別途修正）` }] },
    ],
    dedupe_key: `attendance_fix:${data.alert_id}:${ch}:${nid.slice(0, 8)}`,
  };
  const { ref, username, icon_emoji, ...rest } = s;
  assertEquals(rest, before, "以前から送れていた項目は変わらない");
  assertEquals(ref, { table: "sf_attendance_alerts", id: ALERT }, "台帳 notification_deliveries.ref_table / ref_id に入る");
  assertEquals(username, "勤怠確認");
  assertEquals(icon_emoji, ":alarm_clock:");
  // 打刻削除側（正しく送れていた）と同じ 3 項目
  assertEquals({ ref, username, icon_emoji }, { ref: { table: "sf_attendance_alerts", id: ALERT }, username: "勤怠確認", icon_emoji: ":alarm_clock:" });
});
Deno.test("承認依頼: JSON にしても ref・username・icon_emoji が残る（実際に送る形）／フォーム経由は source だけ違う", () => {
  const a = JSON.parse(JSON.stringify(fixApprovalSend({ ...REQ, notificationId: NID, channelKey: "hq.keiri_kanshi", source: "ef:slack-interact" })));
  for (const k of ["ref", "username", "icon_emoji", "dedupe_key", "blocks", "notification_id", "channel_key", "event", "source", "text", "action"]) assert(k in a, k);
  const f = fixApprovalSend({ ...REQ, notificationId: NID, channelKey: "hq.keiri_kanshi", source: "ef:attendance-request" });
  assertEquals({ ...f, source: "x" }, { ...fixApprovalSend({ ...REQ, notificationId: NID, channelKey: "hq.keiri_kanshi", source: "ef:slack-interact" }), source: "x" });
  // 2 度目の申請は別の通知 id → dedupe_key が変わる（重複扱いで送られない事故の防止）
  const g = fixApprovalSend({ ...REQ, notificationId: "bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee", channelKey: "hq.keiri_kanshi", source: "ef:slack-interact" });
  assertNotEquals(g.dedupe_key, f.dedupe_key);
  // ボタンの value は承認処理（attendance.fix.approve）が読む alert_id と notification_id
  assertEquals(JSON.parse((f.blocks[1] as any).elements[0].value), { alert_id: ALERT, notification_id: NID });
});

// ---- フォームに返す内容 ----
Deno.test("op=alert の中身: 勤怠実績の今の値を JST の文字列で返す・アラート後に変わっていれば changed_since_alert", () => {
  const alert = { id: ALERT, status: "open", request_kind: "fix", user_id: USER, store_id: "s1", work_date: "2026-11-10",
    clock_in: "2026-11-10T08:00:00+00:00", clock_out: null, break_start_1: null, break_end_1: null, break_start_2: null, break_end_2: null };
  const same = alertFormRow(alert, { clock_in: "2026-11-10T08:00:00.000Z", clock_out: null, worked_minutes: null, break_minutes: null, manual_fixed_at: null }, { user: "テスト 太郎", store: "テスト店" });
  assertEquals(same, { id: ALERT, status: "open", request_kind: "fix", user_id: USER, name: "テスト 太郎", store_id: "s1", store_name: "テスト店", work_date: "2026-11-10",
    clock_in: "2026-11-10T17:00", clock_out: null, break_start_1: null, break_end_1: null, break_start_2: null, break_end_2: null,
    worked_minutes: null, break_minutes: null, locked: false, changed_since_alert: false });
  // アラートの後に退勤が打たれた（翌 01:30）・休憩あり
  const later = alertFormRow(alert, { clock_in: "2026-11-10T08:00:00Z", clock_out: "2026-11-10T16:30:00Z", break_start_1: "2026-11-10T11:00:00Z", break_end_1: "2026-11-10T12:00:00Z", worked_minutes: "450", break_minutes: 60, manual_fixed_at: "2026-11-11T00:00:00Z" }, { user: null, store: null });
  assertEquals(later.clock_out, "2026-11-11T01:30");
  assertEquals([later.break_start_1, later.break_end_1], ["2026-11-10T20:00", "2026-11-10T21:00"]);
  assertEquals([later.worked_minutes, later.break_minutes, later.locked, later.changed_since_alert], [450, 60, true, true]);
  assertEquals([later.name, later.store_name], ["", ""]);
  assertEquals(alertFormRow({ ...alert, request_kind: null }, {}, { user: "a", store: "b" }).request_kind, "fix");
});
Deno.test("open 以外のアラートの説明: 状態ごとの文・削除申請は別の文", () => {
  assert(alertStatusMessage("confirmed").includes("確認済み"));
  assert(alertStatusMessage("fix_requested", "fix").includes("修正を申請済み"));
  assert(alertStatusMessage("fix_requested", "delete").includes("削除を申請済み"));
  assert(alertStatusMessage("approved", "fix").includes("反映済み"));
  assert(alertStatusMessage("approved", "delete").includes("削除が承認済み"));
  assert(alertStatusMessage("rejected").includes("却下"));
  assert(alertStatusMessage("cancelled").includes("取り消"));
  assert(alertStatusMessage("zzz").includes("zzz"));
});
Deno.test("uuid の判定", () => {
  assert(isUuid(ALERT));
  for (const bad of ["", "abc", ALERT + "0", ALERT.replace("1", "g"), "------------------------------------", null, 1]) assert(!isUuid(bad), String(bad));
});

// ---- 休憩の申告 ----
Deno.test("休憩の申告の引数: none は分数なし・short は 1〜59・理由 1〜300 字", () => {
  const base = { user_id: USER, work_date: "2026-11-10", reason: " 忙しくて取れなかった " };
  assertEquals(breakDeclareArgs({ ...base, kind: "none", minutes: 30 }, ALERT), { args: { p_user: USER, p_work_date: "2026-11-10", p_kind: "none", p_minutes: null, p_reason: "忙しくて取れなかった", p_actor: ALERT } });
  assertEquals(breakDeclareArgs({ ...base, kind: "short", minutes: "20" }, ALERT), { args: { p_user: USER, p_work_date: "2026-11-10", p_kind: "short", p_minutes: 20, p_reason: "忙しくて取れなかった", p_actor: ALERT } });
  assertEquals(breakDeclareArgs({ ...base, kind: "short", minutes: 59 }, ALERT), { args: { p_user: USER, p_work_date: "2026-11-10", p_kind: "short", p_minutes: 59, p_reason: "忙しくて取れなかった", p_actor: ALERT } });
  for (const m of [0, 60, -1, 1.5, "", null, undefined, "abc"]) assert("error" in breakDeclareArgs({ ...base, kind: "short", minutes: m }, ALERT), `minutes=${m}`);
  assert("error" in breakDeclareArgs({ ...base, kind: "long" }, ALERT));
  assert("error" in breakDeclareArgs({ ...base, kind: "none", user_id: "x" }, ALERT));
  assert("error" in breakDeclareArgs({ ...base, kind: "none", work_date: "2026/11/10" }, ALERT));
  assert("error" in breakDeclareArgs({ ...base, kind: "none", reason: "   " }, ALERT));
  assert("error" in breakDeclareArgs({ ...base, kind: "none", reason: "あ".repeat(301) }, ALERT));
  assert("args" in breakDeclareArgs({ ...base, kind: "none", reason: "あ".repeat(300) }, ALERT));
});
Deno.test("RPC がまだ無いときの判定（PGRST202 / 42883）と文言", () => {
  assert(isMissingRpc({ code: "PGRST202", message: "Could not find the function public.sf_break_exception_submit(p_actor, ...) in the schema cache" }));
  assert(isMissingRpc({ code: "42883", message: "function sf_break_exception_submit(...) does not exist" }));
  assert(isMissingRpc({ message: "Could not find the function public.sf_break_exception_submit" }));
  assert(!isMissingRpc({ code: "P0001", message: "この日の申告は、すでに出ています" }));
  assert(!isMissingRpc(null));
  assertEquals(BREAK_NOT_READY, "この機能はまだ使えません");
});

import { sameTimes } from "./attendance-fix-notify.ts";
Deno.test("変更が無い修正申請の判定: 分の単位まで同じなら同じ。休憩の有無・1 分の違いは変更", () => {
  const cur = { clock_in: "2026-11-10T06:00:00+00:00", clock_out: "2026-11-10T15:10:00+00:00", break_start_1: "2026-11-10T10:00:00+00:00", break_end_1: "2026-11-10T11:00:00+00:00", break_start_2: null, break_end_2: null };
  assertEquals(sameTimes(cur, { ...cur }), true);
  assertEquals(sameTimes(cur, { ...cur, clock_in: "2026-11-10T15:00:30+09:00" }), true, "秒の違い・時刻の書き方の違いは同じ扱い");
  assertEquals(sameTimes(cur, { ...cur, clock_out: "2026-11-10T15:11:00+00:00" }), false);
  assertEquals(sameTimes(cur, { ...cur, break_start_1: null, break_end_1: null }), false, "休憩なしにするのは変更");
  assertEquals(sameTimes({ ...cur, break_start_1: null, break_end_1: null }, cur), false, "休憩を足すのは変更");
  assertEquals(sameTimes(cur, { ...cur, break_start_2: "2026-11-10T12:00:00+00:00", break_end_2: "2026-11-10T12:10:00+00:00" }), false);
  assertEquals(sameTimes(null, cur), false, "いまの勤怠が無い（追加）ときは止めない");
});
