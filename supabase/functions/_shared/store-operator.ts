// 店舗の「運営会社」を月ごとに引く（黒霧屋 新横浜の運営変更 2026-11-01・設計メモ_スマレジ複数契約対応 §7/§10）。
// 「使い分け」店舗(seisan_pl_categories_target)の経路判定（請求書の宛先法人＝運営法人ならPL直接・違えば精算書）は、
// これまで店舗マスタの stores.corporation_id（現在の1つの値）を使っていた。運営会社が時期で変わる店舗は、その月の運営会社で判定する。
// 安全のため、運営法人が時期で変わる店舗（運営関係の行に法人が2つ以上ある店舗）だけを対象にし、それ以外は従来どおり stores.corporation_id を使う。
export async function operatorCorpMap(db: any, storeIds: string[], ym: string | null | undefined): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  if (!storeIds.length) return out;
  const { data: rels } = await db.from("store_operation_relations").select("store_id, operator_entity_type, operator_entity_id, effective_from, effective_to")
    .in("store_id", storeIds).eq("operator_entity_type", "corporation");
  const jstToday = new Date(Date.now() + 9 * 3600e3).toISOString().slice(0, 10);
  const m = String(ym ?? "").slice(0, 7);
  const monthStart = m ? `${m}-01` : jstToday;
  const monthEnd = m ? new Date(Date.UTC(Number(m.slice(0, 4)), Number(m.slice(5, 7)), 0)).toISOString().slice(0, 10) : jstToday;
  for (const sid of storeIds) {
    const rs = (rels ?? []).filter((r: any) => r.store_id === sid);
    if (new Set(rs.map((r: any) => r.operator_entity_id)).size < 2) continue;   // 運営法人が変わらない店舗は従来どおり（storesの法人）
    const hit = rs.filter((r: any) => r.effective_from <= monthEnd && (!r.effective_to || r.effective_to >= monthStart)).sort((a: any, b: any) => (a.effective_from < b.effective_from ? 1 : -1))[0];
    if (hit) out.set(sid, hit.operator_entity_id);
  }
  return out;
}
