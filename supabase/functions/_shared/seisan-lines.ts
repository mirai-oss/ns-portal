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
      if (x.locked) return { ok: false, error: `${r.seisan_store_name} の${month}分は振込済みのため、精算書の行を消せません` };
      if (x.removed) removed += Number(x.rows ?? 1);
    } catch (e) {
      return { ok: false, error: "精算書を呼び出せませんでした: " + String((e as Error)?.message ?? e) };
    }
  }
  return { ok: true, removed };
}

