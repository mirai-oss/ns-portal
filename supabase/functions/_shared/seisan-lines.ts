// 請求書の反映を取り消す・請求書を削除するときに、業務委託精算書へ入れた行も消す（2026-11-26）。
// 従来は管理システム側の記録だけを消していたため、精算書に行が残り、登録し直すと二重計上になっていた。
export type SeisanReflection = {
  reflection_route?: string | null; seisan_store_name?: string | null; seisan_line_key?: string | null;
  year_month?: string | null; sheet_synced_at?: string | null;
};

// call: 精算GASの関数を呼ぶ（戻り値は sd_apiRemoveExternalLine の結果）
export async function removeSeisanLines(
  refls: SeisanReflection[], token: string | undefined,
  call: (fn: string, args: unknown[]) => Promise<any>,
): Promise<{ ok: true; removed: number } | { ok: false; error: string }> {
  // 精算書に実際に入ったことがある行だけが対象
  const targets = refls.filter((r) => r.reflection_route === "seisan" && r.seisan_line_key && r.seisan_store_name && r.sheet_synced_at);
  if (!targets.length) return { ok: true, removed: 0 };
  if (!token) return { ok: false, error: "PL_SYNC_TOKEN が未設定です" };
  let removed = 0;
  for (const r of targets) {
    const month = String(r.year_month ?? "").slice(0, 7);
    try {
      const res = await call("sd_apiRemoveExternalLine", [token, r.seisan_store_name, month, r.seisan_line_key]);
      if (!res || res.ok === false) return { ok: false, error: res?.error || "精算書側で行を消せませんでした" };
      const x = res.result ?? res;
      if (x.locked) return { ok: false, error: `${r.seisan_store_name}: ${x.reason || `${month}分は確定済みのため、精算書の行を消せません`}` };
      if (x.removed) removed += Number(x.rows ?? 1);
    } catch (e) {
      return { ok: false, error: "精算書を呼び出せませんでした: " + String((e as Error)?.message ?? e) };
    }
  }
  return { ok: true, removed };
}


// 2026-11-27: 発行（送信）済み・振込済みの月は、請求書の側から精算書を変えない。変えられない理由を返す（無ければ null）
export async function seisanFrozen(db: any, refls: SeisanReflection[]): Promise<{ ok: true } | { ok: false; error: string }> {
  const seen = new Set<string>();
  for (const r of refls) {
    if (r.reflection_route !== "seisan" || !r.seisan_store_name || !r.sheet_synced_at) continue;
    const month = String(r.year_month ?? "").slice(0, 7), key = `${r.seisan_store_name}|${month}`;
    if (seen.has(key)) continue;
    seen.add(key);
    const { data: st, error: e1 } = await db.from("settle_stores").select("store_key").eq("name", r.seisan_store_name).maybeSingle();
    if (e1 || !st) return { ok: false, error: `精算書の状態を確認できませんでした（${r.seisan_store_name}）` };
    const { data: why, error: e2 } = await db.rpc("settle_frozen_reason", { p_key: st.store_key, p_month: month });
    if (e2) return { ok: false, error: "精算書の状態を確認できませんでした: " + e2.message };
    if (why) return { ok: false, error: `${r.seisan_store_name}: ${why}直す場合は精算ダッシュボードで確認して行ってください。` };
  }
  return { ok: true };
}

// この請求書が精算書へ入れた行と、その反映記録をまとめて外す（仕訳の削除・解除、入れ直しの前に使う）
export async function clearSeisanForInvoice(
  db: any, invoiceId: string, token: string | undefined, call: (fn: string, args: unknown[]) => Promise<any>,
): Promise<{ ok: true; removed: number } | { ok: false; error: string }> {
  const { data, error } = await db.from("invoice_pl_reflections")
    .select("id, reflection_route, seisan_store_name, seisan_line_key, year_month, sheet_synced_at").eq("invoice_id", invoiceId).eq("reflection_route", "seisan");
  if (error) return { ok: false, error: "精算書への登録状況を確認できませんでした: " + error.message };
  const refls = (data ?? []) as (SeisanReflection & { id: string })[];
  if (!refls.length) return { ok: true, removed: 0 };
  const free = await seisanFrozen(db, refls);
  if (!free.ok) return free;
  const cleared = await removeSeisanLines(refls, token, call);
  if (!cleared.ok) return cleared;
  const { error: delErr } = await db.from("invoice_pl_reflections").delete().in("id", refls.map((r) => r.id));
  if (delErr) return { ok: false, error: "精算書の行は消しましたが、反映の記録を消せませんでした: " + delErr.message };
  await db.from("invoices").update({ pl_fee_seisan_synced_at: null }).eq("id", invoiceId);
  const { count } = await db.from("invoice_pl_reflections").select("id", { count: "exact", head: true }).eq("invoice_id", invoiceId);
  if (!count) await db.from("invoices").update({ pl_fee_reflected_at: null, pl_fee_reflected_by: null }).eq("id", invoiceId);
  return cleared;
}

// 精算ダッシュボードのサーバー間の呼び出し（{ok,result} の包みを外して返す）
export async function seisanApiCall(fn: string, args: unknown[]) {
  const res = await fetch("https://uuvsxzhpxtghojoubjcc.supabase.co/functions/v1/seisan-api", { method: "POST", headers: { "Content-Type": "text/plain;charset=utf-8" }, body: JSON.stringify({ fn, args }) });
  const outer: any = await res.json().catch(() => null);
  if (!outer) throw new Error("精算書APIの応答を読めませんでした");
  if (outer.ok === false) return { ok: false, error: outer.error };
  return outer.result ?? outer;
}
