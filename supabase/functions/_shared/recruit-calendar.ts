// =============================================================
// 採用管理: 面接の予定（Google カレンダー・Meet）を作る・直す・消す（2026-11-28 下書き・本番未適用）
//   いまの管理システムの画面（nippo/index.html の meetIssue・gasDeleteEvent）と同じ GAS のウェブアプリを、同じ中身で呼ぶ。GAS の側は変えない。
//   呼ぶのは recruit-action だけ。しかも、カレンダーが本番モード（app_settings.recruit_actions.calendar_mode = live）のときだけ。既定は試しモード＝ここは呼ばれない。
//   GAS の URL・合言葉・カレンダーの番号は、DB の app_secrets（gas_url / gas_key / gas_cal）にある（画面も同じ値を使っている）。値は、返事にも記録にも出さない。
// =============================================================
export type GasConfig = { url: string; key: string; cal: string };
export type MeetArgs = { name: string; start: string; eventId: string; mode: "online" | "onsite"; place: string; address: string; interviewer: string };
export type MeetResult = { ok: boolean; url: string | null; event_id: string | null; updated: boolean; why: string | null };
export type FetchLike = (url: string, init: RequestInit) => Promise<Response>;

async function post(cfg: GasConfig, body: Record<string, unknown>, fetchFn: FetchLike, timeoutMs: number) {
  // 画面と同じ送り方（text/plain の JSON）。GAS はログイン画面などの HTML を返すことがあるので、JSON として読めなければ失敗にする
  const res = await fetchFn(cfg.url, { method: "POST", headers: { "Content-Type": "text/plain;charset=utf-8" }, body: JSON.stringify({ key: cfg.key, calendar_id: cfg.cal || "primary", ...body }), signal: AbortSignal.timeout(timeoutMs) });
  const txt = await res.text().catch(() => "");
  try { return JSON.parse(txt) as Record<string, unknown>; } catch (_e) { return null; }
}

/** 予定を作る／直す（eventId があれば、その予定の日時を直す＝ Meet の URL は変わらない）。対面は URL が無いのが正常 */
export async function gasMeet(cfg: GasConfig, a: MeetArgs, fetchFn: FetchLike = fetch, timeoutMs = 20000): Promise<MeetResult> {
  const fail = (why: string): MeetResult => ({ ok: false, url: null, event_id: null, updated: false, why });
  if (!cfg?.url) return fail("カレンダーの設定（GAS の URL）がありません");
  let j: Record<string, unknown> | null;
  try {
    j = await post(cfg, { action: "meet", name: a.name || "面接", start: a.start, minutes: 30, event_id: a.eventId || "", mode: a.mode, place: a.place || "", address: a.address || "", interviewer: a.interviewer || "", note: "管理システム（recruit-action）から作成" }, fetchFn, timeoutMs);
  } catch (e) { return fail("GAS に届きませんでした: " + String((e as Error)?.name ?? e).slice(0, 60)); }
  if (!j) return fail("GAS の返事が読めませんでした");
  if (!j.ok) return fail("GAS 側で失敗: " + String(j.error ?? "不明").slice(0, 120));
  const eventId = typeof j.event_id === "string" && j.event_id ? j.event_id : null;
  if (a.mode === "onsite") return { ok: true, url: null, event_id: eventId, updated: !!j.updated, why: null };
  if (typeof j.url !== "string" || !j.url) return { ok: false, url: null, event_id: eventId, updated: !!j.updated, why: "予定は作られましたが、Meet の URL が返りませんでした" };
  return { ok: true, url: j.url, event_id: eventId, updated: !!j.updated, why: null };
}

/** 予定を消す（すでに消えていても、失敗にはしない＝画面と同じ） */
export async function gasDelete(cfg: GasConfig, eventId: string, fetchFn: FetchLike = fetch, timeoutMs = 20000): Promise<{ ok: boolean; why: string | null }> {
  if (!eventId) return { ok: true, why: null };
  if (!cfg?.url) return { ok: false, why: "カレンダーの設定（GAS の URL）がありません" };
  try {
    const j = await post(cfg, { action: "delete_event", event_id: eventId }, fetchFn, timeoutMs);
    if (!j) return { ok: false, why: "GAS の返事が読めませんでした" };
    return j.ok === false ? { ok: false, why: "GAS 側で失敗: " + String(j.error ?? "不明").slice(0, 120) } : { ok: true, why: null };
  } catch (e) { return { ok: false, why: "GAS に届きませんでした: " + String((e as Error)?.name ?? e).slice(0, 60) }; }
}

// ---- 2026-12-03 カレンダーの空きの確かめ（社長の指示: 面接担当者の予定が重ならないように） ----
//   ★ いまの GAS には、この入口（action: "busy"）が無い（画面が呼んでいるのは meet と delete_event だけ）。GAS に足すコードと手順は、scratchpad ob18/stage4/GASに足すコード_カレンダーの空き.md。
//   足すまでは、設定 recruit_actions.calendar_busy_check を false のままにする（＝ここは呼ばれない）。呼んで、GAS が知らない・読めない返事なら「確かめられなかった」として、面接の確定は止めない。
export type BusyResult = { checked: boolean; busy: boolean; why: string | null };
/** その時間に、面接のカレンダーに別の予定があるか。excludeEventId＝いまの面接の予定（日時の変更のとき、自分自身を数えない） */
export async function gasBusy(cfg: GasConfig, a: { start: string; minutes: number; excludeEventId: string }, fetchFn: FetchLike = fetch, timeoutMs = 15000): Promise<BusyResult> {
  if (!cfg?.url) return { checked: false, busy: false, why: "カレンダーの設定（GAS の URL）がありません" };
  try {
    const j = await post(cfg, { action: "busy", start: a.start, minutes: a.minutes, exclude_event_id: a.excludeEventId || "" }, fetchFn, timeoutMs);
    if (!j || j.ok !== true || typeof j.busy !== "boolean") return { checked: false, busy: false, why: !j ? "GAS の返事が読めませんでした" : "GAS が、空きの確かめに対応していません: " + String(j.error ?? "不明").slice(0, 80) };
    return { checked: true, busy: j.busy, why: null };
  } catch (e) { return { checked: false, busy: false, why: "GAS に届きませんでした: " + String((e as Error)?.name ?? e).slice(0, 60) }; }
}
