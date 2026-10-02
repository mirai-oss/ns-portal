// 店舗間の仕入れ移動：現場向け公開フォームの送信（2026-10-05・GAS/スプレッドシート経由をやめる
// Supabase直結化の一環）。ログイン不要・ブラウザから直接このEdge Functionを叩く。
//
// これまでtori-dashboard（GAS）の costTransferPublicSubmit が担っていた役割をそのまま移植:
//   1) 公開リンクのトークン（app_secrets.cost_transfer_form_token）を照合
//   2) 入力検証（移動元≠移動先・品目1つ以上 等）
//   3) 金額はクライアント送信値を一切信用せず、cost_transfer_items（品目マスタ）の単価×数量から
//      サーバー側で必ず再計算する（改ざん防止。既存踏襲）
//   4) cost_transfer_requests へ status:'pending' で1行INSERT（DB_PL相当のデータには一切触れない。
//      承認は引き続き社長・本部がtori-dashboardの管理画面＝GAS経由で行う）
//   5) 発注グループLINEへベストエフォートで通知（失敗しても申請自体は成功のまま。_shared/line.ts）
import { createClient } from "npm:@supabase/supabase-js@2";
import { linePushOrderGroup } from "../_shared/line.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });

const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

async function getSecret(sb: any, key: string): Promise<string> {
  const { data } = await sb.from("app_secrets").select("value").eq("key", key).maybeSingle();
  return (data?.value ?? "").trim();
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const body = await req.json().catch(() => ({}));
    const sb = svc();

    const formToken = await getSecret(sb, "cost_transfer_form_token");
    if (!formToken || String(body.token ?? "").trim() !== formToken) {
      return json({ ok: false, error: "unauthorized" }, 401);
    }

    const date = String(body.date ?? "").trim();
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) return json({ ok: false, error: "移動日が不正です" }, 400);

    const fromStore = String(body.fromStore ?? "").trim();
    const toStore = String(body.toStore ?? "").trim();
    if (!fromStore || !toStore) return json({ ok: false, error: "移動元・移動先の店舗を選んでください" }, 400);
    if (fromStore === toStore) return json({ ok: false, error: "移動元と移動先は別の店舗にしてください" }, 400);

    const itemsIn = Array.isArray(body.items) ? body.items : [];
    if (!itemsIn.length) return json({ ok: false, error: "商品を1つ以上追加してください" }, 400);

    const { data: masterRows } = await sb.from("cost_transfer_items").select("name,unit_price").eq("active", true);
    const priceByName: Record<string, number> = {};
    (masterRows ?? []).forEach((r: any) => { priceByName[r.name] = Number(r.unit_price) || 0; });

    const items: Array<{ name: string; qty: number; unitPrice: number; amount: number }> = [];
    let total = 0;
    for (const raw of itemsIn) {
      const name = String(raw?.name ?? "").trim();
      const qty = Number(raw?.qty);
      if (!name || !Object.prototype.hasOwnProperty.call(priceByName, name)) {
        return json({ ok: false, error: `品目「${name}」は選択できません（削除・無効化された可能性があります。画面を更新してやり直してください）` }, 400);
      }
      if (!isFinite(qty) || qty <= 0) return json({ ok: false, error: `「${name}」の数量を正しく入力してください` }, 400);
      const unitPrice = priceByName[name];
      const amount = Math.round(unitPrice * qty);
      items.push({ name, qty, unitPrice, amount });
      total += amount;
    }

    const note = String(body.note ?? "").trim().slice(0, 300);
    const { data: inserted, error } = await sb
      .from("cost_transfer_requests")
      .insert({ transfer_date: date, from_store: fromStore, to_store: toStore, items, total, note, status: "pending" })
      .select("id")
      .single();
    if (error) return json({ ok: false, error: "保存に失敗しました: " + String(error.message ?? error) }, 500);

    linePushOrderGroup(sb, { date, fromStore, toStore, items, note }).catch(() => {}); // ベストエフォート（失敗しても申請自体は成功のまま）

    return json({ ok: true, id: inserted.id, total });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
