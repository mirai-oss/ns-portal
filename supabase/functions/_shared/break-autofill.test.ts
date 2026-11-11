import { assertEquals, assert } from "jsr:@std/assert@1";
import { DEFAULT_AUTOFILL as C, buildPayload, estimateBreak, jstIso, nightOverlapMinutes, preCheck, verifyAfter } from "./break-autofill.ts";
const j = (s: string) => new Date(s + "+09:00").toISOString();   // JST の日時 → ISO
const hm = (iso: string) => jstIso(iso).slice(0, 16).replace("T", " ");

Deno.test("6 時間を超える勤務だけ・60 分・勤務の中央（5 分きざみ）", () => {
  const e = estimateBreak(j("2026-11-10T15:00:00"), j("2026-11-11T00:00:00")); assert(e.ok);
  // 15:00〜翌 0:00（9 時間）の中央は 19:00〜20:00（深夜にかからない）
  assertEquals([hm(e.start), hm(e.end), e.minutes, e.placement], ["2026-11-10 19:00", "2026-11-10 20:00", 60, "middle"]);
  assertEquals(estimateBreak(j("2026-11-10T10:00:00"), j("2026-11-10T16:00:00")), { ok: false, reason: "too_short" });   // ちょうど 6 時間は対象外
  const s = estimateBreak(j("2026-11-10T10:00:00"), j("2026-11-10T16:01:00")); assert(s.ok);                            // 6 時間 1 分は対象
  assertEquals([hm(s.start), hm(s.end)], ["2026-11-10 12:30", "2026-11-10 13:30"]);
  const odd = estimateBreak(j("2026-11-10T09:07:00"), j("2026-11-10T18:22:00")); assert(odd.ok);
  assertEquals(new Date(odd.start).getUTCMinutes() % 5, 0, "5 分きざみ");
  assertEquals(estimateBreak(j("2026-11-10T18:00:00"), j("2026-11-10T09:00:00")), { ok: false, reason: "invalid" });
});

Deno.test("出勤から 1 時間以内・退勤まで 1 時間以内には置かない", () => {
  for (const [a, b] of [["2026-11-10T09:00:00", "2026-11-10T15:30:00"], ["2026-11-10T11:00:00", "2026-11-10T23:00:00"], ["2026-11-10T14:00:00", "2026-11-11T01:30:00"]]) {
    const e = estimateBreak(j(a), j(b)); assert(e.ok);
    assert(new Date(e.start).getTime() - new Date(j(a)).getTime() >= 60 * 60000, "出勤から 1 時間以上あと");
    assert(new Date(j(b)).getTime() - new Date(e.end).getTime() >= 60 * 60000, "退勤の 1 時間以上まえ");
  }
});

Deno.test("深夜（22 時〜翌 5 時）には置かない: 前に寄せる・後ろに寄せる・避けられなければ補完しない", () => {
  // 17:00〜翌 3:00: 中央は 21:30〜22:30 → 深夜の前（21:00〜22:00）に寄せる
  const a = estimateBreak(j("2026-11-10T17:00:00"), j("2026-11-11T03:00:00")); assert(a.ok);
  assertEquals([hm(a.start), hm(a.end), a.placement], ["2026-11-10 21:00", "2026-11-10 22:00", "before_night"]);
  assertEquals(nightOverlapMinutes(new Date(a.start).getTime(), new Date(a.end).getTime(), C), 0);
  // 0:00〜8:00: 中央は 3:30〜4:30 → 深夜の後（5:00〜6:00）
  const b = estimateBreak(j("2026-11-10T00:00:00"), j("2026-11-10T08:00:00")); assert(b.ok);
  assertEquals([hm(b.start), hm(b.end), b.placement], ["2026-11-10 05:00", "2026-11-10 06:00", "after_night"]);
  // 21:30〜翌 5:30: 深夜を避ける場所が無い → 補完しない（人が決める）
  assertEquals(estimateBreak(j("2026-11-10T21:30:00"), j("2026-11-11T05:30:00")), { ok: false, reason: "night_only" });
  assertEquals(nightOverlapMinutes(new Date(j("2026-11-10T21:30:00")).getTime(), new Date(j("2026-11-10T22:30:00")).getTime(), C), 30);
});

const hub = { clock_in: j("2026-11-10T15:00:00"), clock_out: j("2026-11-11T00:00:00") };
const rec = (o: Record<string, unknown> = {}) => ({ shiftResultId: 123, attendance: "2026-11-10T15:00:00+09:00", leaving: "2026-11-11T00:00:00+09:00", breakStartTime1: "", breakEndTime1: "", breakStartTime2: "", breakEndTime2: "", dutyMinute: 540, tardyFlag: "", earlyLeavingFlag: "1", ...o });
Deno.test("スマレジのいまの実績を見て決める: 二重登録・二重控除・競合を防ぐ", () => {
  assertEquals(preCheck(rec(), hub), { ok: true });
  assertEquals(preCheck(null, hub), { ok: false, status: "conflict", reason: "not_found" });
  assertEquals(preCheck(rec({ leaving: "" }), hub), { ok: false, status: "conflict", reason: "not_left" });
  // 休憩がもう入っている（打刻・スマレジ側の自動設定・だれかの修正）→ 上書きしない
  assertEquals(preCheck(rec({ breakStartTime1: "2026-11-10T19:00:00+09:00", breakEndTime1: "2026-11-10T19:45:00+09:00" }), hub), { ok: false, status: "skipped", reason: "has_break" });
  assertEquals(preCheck(rec({ breakStartTime2: "2026-11-10T21:00:00+09:00" }), hub), { ok: false, status: "skipped", reason: "has_break" });
  // 出勤・退勤がスマレジで直されている → 競合
  assertEquals(preCheck(rec({ leaving: "2026-11-10T23:30:00+09:00" }), hub), { ok: false, status: "conflict", reason: "time_changed" });
  // 休憩の時刻は無いのに、勤務時間が 60 分短い → スマレジ側で自動で引かれている疑い → 補完しない（二重控除の防止）
  assertEquals(preCheck(rec({ dutyMinute: 480 }), hub), { ok: false, status: "skipped", reason: "deducted" });
  assertEquals(preCheck(rec({ dutyMinute: 535 }), hub), { ok: true }, "丸めの差（数分）は気にしない");
  assertEquals(preCheck(rec({ dutyMinute: null }), hub), { ok: true });
});

Deno.test("スマレジへ送る中身: 出勤・退勤・遅刻早退はスマレジの値のまま。休憩 1 だけ入れる。書いたあとの読み直し", () => {
  const e = estimateBreak(hub.clock_in, hub.clock_out); assert(e.ok);
  const p = buildPayload("2026-11-10", rec(), e);
  assertEquals(p, { shiftDate: "2026-11-10", division: "result", attendance: "2026-11-10T15:00:00+09:00", leaving: "2026-11-11T00:00:00+09:00",
    breakStartTime1: "2026-11-10T19:00:00+09:00", breakEndTime1: "2026-11-10T20:00:00+09:00", breakStartTime2: null, breakEndTime2: null, earlyLeavingFlag: "1" });
  assert(verifyAfter(rec({ breakStartTime1: "2026-11-10T19:00:00+09:00", breakEndTime1: "2026-11-10T20:00:00+09:00", dutyMinute: 480 }), hub, e));
  assert(!verifyAfter(rec(), hub, e), "休憩が入っていなければ失敗");
  assert(!verifyAfter(rec({ breakStartTime1: "2026-11-10T19:00:00+09:00", breakEndTime1: "2026-11-10T20:00:00+09:00", breakStartTime2: "2026-11-10T21:00:00+09:00" }), hub, e));
  assertEquals(jstIso("2026-11-10T15:00:00.000Z"), "2026-11-11T00:00:00+09:00");
});
