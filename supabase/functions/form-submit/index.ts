// 経費申請・見積もりの申請フォーム（ログイン不要のURLフォーム）。2026-11-04
// 合言葉（app_secrets.expense_form_token / quote_form_token）を知っている人だけが使える。申請者は名簿の実在IDのみ。
// 経費: 提出すると「承認待ち」で入る（承認者は経費申請の承認ルールで自動決定。社長・本部が申請履歴で承認）。
// 見積もり: 承認は無く、本部が申請履歴の「見積もり」で比較して見る。写真は非公開バケット(経費=report-photos / 見積=quote-photos)へ。
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info" };
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });
const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const MAX_PHOTO_BYTES = 4 * 1024 * 1024;
const OK_TYPE = /^(image\/[a-z0-9.+-]+|application\/pdf|application\/msword|application\/vnd\.ms-excel|application\/vnd\.openxmlformats-officedocument\.(spreadsheetml\.sheet|wordprocessingml\.document))$/;

function decodePhoto(s: string): { bytes: Uint8Array; type: string } | null {
  const m = /^data:([a-z0-9.+\/-]+);base64,(.+)$/i.exec(String(s ?? ""));
  if (!m || !OK_TYPE.test(m[1].toLowerCase())) return null;
  const bin = atob(m[2]);
  if (bin.length > MAX_PHOTO_BYTES) return null;
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return { bytes, type: m[1].toLowerCase() };
}
const extOf = (t: string) => (t.includes("png") ? "png" : t.includes("webp") ? "webp" : t.includes("pdf") ? "pdf" : t.includes("spreadsheetml") ? "xlsx" : t.includes("wordprocessingml") ? "docx" : t.includes("ms-excel") ? "xls" : t.includes("msword") ? "doc" : "jpg");
const rand = () => Math.random().toString(36).slice(2, 8);

async function uploadAll(sb: any, bucket: string, prefix: string, photos: unknown): Promise<string[]> {
  const out: string[] = [];
  for (const p of Array.isArray(photos) ? photos.slice(0, 5) : []) {
    const d = decodePhoto(p as string);
    if (!d) throw new Error("ファイルが大きすぎるか、形式が正しくありません（写真・PDF・Excel・Wordで1つ4MBまで）");
    const path = `${prefix}_${Date.now()}_${rand()}.${extOf(d.type)}`;
    const { error } = await sb.storage.from(bucket).upload(path, d.bytes, { contentType: d.type });
    if (error) throw new Error("写真の保存に失敗しました: " + error.message);
    out.push(path);
  }
  return out;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const body = await req.json().catch(() => ({}));
    const form = String(body.form ?? "");
    if (form !== "expense" && form !== "quote") return json({ ok: false, error: "bad form" }, 400);
    const sb = svc();
    const { data: sec } = await sb.from("app_secrets").select("value").eq("key", form + "_form_token").maybeSingle();
    const formToken = String(sec?.value ?? "").trim();
    if (!formToken || String(body.token ?? "").trim() !== formToken) return json({ ok: false, error: "unauthorized" }, 401);

    const { data: storeRows } = await sb.from("stores").select("id,name,corporation_id,sort_order").eq("is_active", true).order("sort_order");
    const stores = storeRows ?? [];

    if (body.action === "options") {
      const { data: staff } = await sb.from("users").select("id,name").eq("is_active", true).order("name");
      const out: any = { ok: true, stores: stores.map((s: any) => String(s.name)), staff: (staff ?? []).filter((u: any) => String(u.name ?? "").trim()).map((u: any) => ({ id: u.id, name: u.name })) };
      if (form === "expense") {
        const { data: cats } = await sb.from("expense_categories").select("id,name").eq("is_active", true).order("sort_order");
        out.categories = cats ?? [];
      }
      return json(out);
    }

    const store = stores.find((s: any) => String(s.name) === String(body.store ?? "").trim());
    if (!store) return json({ ok: false, error: "店舗を選んでください" }, 400);
    const date = String(body.date ?? "").trim();
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) return json({ ok: false, error: "日付を選んでください" }, 400);
    const now = Date.now(), d = new Date(date + "T00:00:00+09:00").getTime();
    if (isNaN(d) || d < now - 400 * 86400000 || d > now + 30 * 86400000) return json({ ok: false, error: "日付が範囲外です" }, 400);
    const requesterId = String(body.requesterId ?? "").trim();
    const { data: ru } = await sb.from("users").select("id,name").eq("id", requesterId).eq("is_active", true).maybeSingle();
    if (!ru) return json({ ok: false, error: "申請者を選んでください" }, 400);

    const since = new Date(now - 3600 * 1000).toISOString();
    const tbl = form === "expense" ? "expense_requests" : "quote_requests";
    const col = form === "expense" ? "created_at" : "submitted_at";
    const { count } = await sb.from(tbl).select("id", { count: "exact", head: true }).gte(col, since);
    if ((count ?? 0) >= 60) return json({ ok: false, error: "短時間に申請が集中しています。しばらく待ってからお試しください" }, 429);

    if (form === "quote") {
      const subject = String(body.subject ?? "").trim().slice(0, 200);
      if (!subject) return json({ ok: false, error: "何の見積もりか入力してください" }, 400);
      const opts = (Array.isArray(body.options) ? body.options : []).slice(0, 3);
      const used = opts.filter((o: any) => String(o?.vendor ?? "").trim() || Number(o?.amount) > 0 || (Array.isArray(o?.photos) && o.photos.length));
      if (!used.length) return json({ ok: false, error: "見積もりを1社以上入力してください" }, 400);
      const { data: q, error } = await sb.from("quote_requests")
        .insert({ quote_date: date, store_name: store.name, requester_id: ru.id, requester_name: ru.name, subject, note: String(body.note ?? "").trim().slice(0, 300) || null })
        .select("id").single();
      if (error) return json({ ok: false, error: "保存に失敗しました: " + error.message }, 500);
      try {
        let n = 0;
        for (const o of used) {
          n++;
          const paths = await uploadAll(sb, "quote-photos", `${q.id}/${n}`, o.photos);
          const amt = Number(o.amount);
          const { error: e2 } = await sb.from("quote_options").insert({
            request_id: q.id, sort_no: n, vendor_name: String(o.vendor ?? "").trim().slice(0, 100) || null,
            amount: isFinite(amt) && amt > 0 ? amt : null, note: String(o.note ?? "").trim().slice(0, 200) || null, photo_paths: paths,
          });
          if (e2) throw new Error(e2.message);
        }
      } catch (e) {
        await sb.from("quote_requests").delete().eq("id", q.id);   // 途中で失敗したら丸ごと取り消す（中途半端な申請を残さない）
        return json({ ok: false, error: String((e as Error).message ?? e) }, 500);
      }
      return json({ ok: true, id: q.id });
    }

    // ---- 経費申請 ----
    const amount = Number(body.amount);
    if (!isFinite(amount) || amount <= 0 || amount > 10000000) return json({ ok: false, error: "金額を正しく入力してください" }, 400);
    const purpose = String(body.purpose ?? "").trim().slice(0, 300);
    if (!purpose) return json({ ok: false, error: "何に使ったか入力してください" }, 400);
    const { data: approver } = await sb.rpc("expense_default_approver", { p_applicant_id: ru.id });
    if (!approver) return json({ ok: false, error: "承認者を自動設定できませんでした。本部に承認ルートの確認を依頼してください" }, 400);
    let corp = store.corporation_id as string | null;
    if (!corp) { const { data: c } = await sb.from("corporations").select("id").eq("corp_code", "nstyle").maybeSingle(); corp = c?.id ?? null; }
    const catId = String(body.categoryId ?? "").trim() || null;
    const { data: flow } = await sb.from("expense_flows").select("id").eq("is_default", true).limit(1).maybeSingle();
    const { data: er, error } = await sb.from("expense_requests").insert({
      applicant_id: ru.id, use_date: date, amount, purpose, category_id: catId, store_id: store.id, corporation_id: corp,
      memo: String(body.memo ?? "").trim().slice(0, 300) || null, status: "pending", approver_id: approver, flow_id: flow?.id ?? null, applied_at: new Date().toISOString(),
    }).select("id").single();
    if (error) return json({ ok: false, error: "保存に失敗しました: " + error.message }, 500);
    try {
      const paths = await uploadAll(sb, "report-photos", `${ru.id}/expense_form`, body.photos);
      for (const p of paths) await sb.from("expense_photos").insert({ request_id: er.id, storage_path: p, created_by: ru.id });
    } catch (e) {
      await sb.from("expense_requests").delete().eq("id", er.id);
      return json({ ok: false, error: String((e as Error).message ?? e) }, 500);
    }
    await sb.from("hq_notifications").insert({ recipient_id: approver, kind: "due_alert", title: "経費申請の承認をお願いします", body: `${ru.name}さん — ${purpose}（${Math.round(amount)}円）` });
    return json({ ok: true, id: er.id });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
