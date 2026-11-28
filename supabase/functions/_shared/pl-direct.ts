// 2026-11-28: 請求書の削除・仕訳の削除/解除のとき、PL へ直接書いた行（source_key='inv:<請求書ID>:<反映ID>:…'）も取り消す。
// 残ると、登録し直したときに PL が二重になる。
export async function clearDirectPlForInvoice(db: any, invoiceId: string): Promise<{ ok: true; removed: number } | { ok: false; error: string }> {
  const { data, error } = await db.from("pl_entries").select("id, source_key").like("source_key", `inv:${invoiceId}:%`).is("deleted_at", null);
  if (error) return { ok: false, error: "PLの反映状況を確認できませんでした: " + error.message };
  if (!data?.length) return { ok: true, removed: 0 };
  const { data: res, error: delErr } = await db.rpc("pl_entries_delete", { p_ids: data.map((x: any) => x.id), p_actor: "invoice-direct" });
  if (delErr || res?.ok === false) return { ok: false, error: "PLの行を取り消せませんでした: " + (delErr?.message ?? res?.error ?? "") };
  const reflIds = [...new Set(data.map((x: any) => String(x.source_key).split(":")[2]).filter(Boolean))];
  if (reflIds.length) {
    const { error: rErr } = await db.from("invoice_pl_reflections").delete().in("id", reflIds as string[]).eq("invoice_id", invoiceId);
    if (rErr) return { ok: false, error: "PLの行は取り消しましたが、反映の記録を消せませんでした: " + rErr.message };
  }
  const { count } = await db.from("invoice_pl_reflections").select("id", { count: "exact", head: true }).eq("invoice_id", invoiceId);
  if (!count) await db.from("invoices").update({ pl_fee_reflected_at: null, pl_fee_reflected_by: null }).eq("id", invoiceId);
  return { ok: true, removed: data.length };
}
