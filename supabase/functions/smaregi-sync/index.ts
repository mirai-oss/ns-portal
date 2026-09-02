// スマレジ・タイムカード連携＋通知中継 Edge Function (smaregi-sync) v2.6.14
// v2.6.7: 性別 / 社員番号(自動採番) / 管理者メモ(緊急連絡先・自由項目) をスマレジへ送信
// ※ verify_jwt は OFF にすること（invite_staffs を未ログインの入社者が呼ぶため）。
//    各アクション内で JWT / 招待トークンによる認可チェックを行う。
// actions:
//   { action: "test" }                → 事業所/従業員区分一覧（CEO/HQのみ・疎通確認）
//   { action: "sync", user_id }      → employee_profiles を読みスマレジに従業員登録（本人 or CEO/HQ）
//   { action: "terminate", user_id, date } → 退職日をスマレジへ反映＋打刻の利用ON/OFF（CEO/HQのみ）
//   { action: "notify_chatwork", secret, room, text, token } → Chatworkへメッセージ送信（DBからの中継用）
//   { action: "staffs" }              → スマレジ登録済みスタッフ一覧＋メール有無（CEO/HQのみ）
//   { action: "invite", staff_id, role, store_ids, days, send_email }
//                                     → スマレジスタッフ紐付きの招待を発行し、必要ならResendでメール送信（CEO/HQのみ）
//   { action: "invite_staffs", invite_token }
//                                    → 未連携スタッフの名前一覧（有効な招待トークン必須・未ログイン可）
import { createClient } from "npm:@supabase/supabase-js@2";

const IS_PROD = Deno.env.get("SMAREGI_ENV") === "prod";
const ID_BASE = IS_PROD ? "https://id.smaregi.jp" : "https://id.smaregi.dev";
const API_BASE = IS_PROD ? "https://api.smaregi.jp" : "https://api.smaregi.dev";
const CONTRACT = Deno.env.get("SMAREGI_CONTRACT_ID") ?? "";
const CID = Deno.env.get("SMAREGI_CLIENT_ID") ?? "";
const SECRET = Deno.env.get("SMAREGI_CLIENT_SECRET") ?? "";
const SCOPES = "timecard.staffs:read timecard.staffs:write timecard.stores:read timecard.settings:read";
const APP_URL = Deno.env.get("APP_URL") ?? "https://mirai-oss.github.io/nippo/";
const RESEND_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const RESEND_FROM = Deno.env.get("RESEND_FROM") ?? "鳥一代グループ 日報システム <onboarding@resend.dev>";

const cors: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });

const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

function jwtUid(req: Request): string {
  try {
    const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    return JSON.parse(atob(jwt.split(".")[1].replace(/-/g, "+").replace(/_/g, "/"))).sub ?? "";
  } catch (_) { return ""; }
}
async function callerRole(req: Request): Promise<{ uid: string; role: string }> {
  const uid = jwtUid(req);
  if (!uid) return { uid: "", role: "" };
  const { data } = await svc().from("users").select("role,is_active").eq("id", uid).single();
  return { uid, role: data && data.is_active ? data.role : "" };
}

async function getToken(): Promise<string> {
  const res = await fetch(`${ID_BASE}/app/${CONTRACT}/token`, {
    method: "POST",
    headers: {
      Authorization: "Basic " + btoa(`${CID}:${SECRET}`),
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: "grant_type=client_credentials&scope=" + encodeURIComponent(SCOPES),
  });
  const j = await res.json();
  if (!res.ok || !j.access_token) throw new Error("token error: " + JSON.stringify(j));
  return j.access_token;
}

const api = (token: string, path: string, init: RequestInit = {}) =>
  fetch(`${API_BASE}/${CONTRACT}/timecard${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      ...(init.headers ?? {}),
    },
  });

// スタッフ全件（ページング・退職者除外）
async function fetchAllStaffs(token: string) {
  const clsRaw = await api(token, "/employee_classifications").then((r) => r.json());
  const clsArr = Array.isArray(clsRaw) ? clsRaw : (clsRaw?.employeeClassifications ?? []);
  const clsMap: Record<string, string> = {};
  for (const c of clsArr) clsMap[String(c.employeeClassificationId)] = c.employeeClassificationName;
  const staffs: any[] = [];
  for (let page = 1; page <= 20; page++) {
    const r = await api(token, `/staffs?limit=100&page=${page}`);
    const raw = await r.json().catch(() => null);
    if (!r.ok) throw new Error("staffs error: " + JSON.stringify(raw));
    const arr = Array.isArray(raw) ? raw : (raw?.staffs ?? []);
    for (const s of arr) {
      if (String(s.termination ?? "0") === "1") continue; // 退職者は除外
      staffs.push({
        staffId: String(s.staffId),
        name: s.staffName ?? "",
        kana: s.staffKana ?? "",
        mail: s.mail ?? "",
        classification: clsMap[String(s.employeeClassificationId)] ?? "",
      });
    }
    const pageCount = Array.isArray(raw) ? (arr.length < 100 ? page : page + 1) : (raw?.pageCount ?? page);
    if (page >= Number(pageCount) || arr.length === 0) break;
  }
  return staffs;
}

// 2026-09-02追加: スタッフがスマレジ・タイムカード上でどの事業所（店舗）に所属しているかを取得。
// /staffs のスタッフ一覧レスポンス自体には所属店舗の項目が無いため、クエリパラメータ
// store_id で店舗ごとに絞り込んだ一覧を店舗の数だけ呼び、staffId→所属店舗(複数可)の対応表を作る。
// ユーザー要望「事業所で分かれるようにできない？」（一括招待でどの店舗を選べばいいか分からない）への対応。
// storeList: [{ id: 内部store UUID, smaregiStoreId: スマレジ側のstore_id(文字列) }]
async function fetchStaffStoreMap(token: string, storeList: { id: string; smaregiStoreId: string }[]) {
  const map: Record<string, string[]> = {}; // staffId -> [内部store UUID, ...]
  for (const st of storeList) {
    if (!st.smaregiStoreId) continue;
    try {
      for (let page = 1; page <= 5; page++) {
        const r = await api(token, `/staffs?store_id=${encodeURIComponent(st.smaregiStoreId)}&limit=100&page=${page}`);
        const raw = await r.json().catch(() => null);
        if (!r.ok) break;
        const arr = Array.isArray(raw) ? raw : (raw?.staffs ?? []);
        for (const s of arr) {
          const sid = String(s.staffId);
          (map[sid] = map[sid] ?? []).push(st.id);
        }
        const pageCount = Array.isArray(raw) ? (arr.length < 100 ? page : page + 1) : (raw?.pageCount ?? page);
        if (page >= Number(pageCount) || arr.length === 0) break;
      }
    } catch (_) { /* この店舗だけ取得できなくても他の店舗は続行 */ }
  }
  return map;
}

// v2.6.14: スマレジ側で使用中の社員番号を集める（重複を避けるため。退職者も含める）
async function fetchStaffCodes(token: string): Promise<Set<string>> {
  const set = new Set<string>();
  try {
    for (let page = 1; page <= 20; page++) {
      const r = await api(token, `/staffs?limit=100&page=${page}`);
      const raw = await r.json().catch(() => null);
      if (!r.ok) break;
      const arr = Array.isArray(raw) ? raw : (raw?.staffs ?? []);
      for (const s of arr) if (s.staffCode) set.add(String(s.staffCode).trim());
      const pageCount = Array.isArray(raw) ? (arr.length < 100 ? page : page + 1) : (raw?.pageCount ?? page);
      if (page >= Number(pageCount) || arr.length === 0) break;
    }
  } catch (_) { /* 取得できなければ重複チェックはスキップ */ }
  return set;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const body = await req.json().catch(() => ({}));

    // ---- 未連携スタッフの名前一覧（未ログイン・有効な招待トークン必須） ----
    if (body.action === "invite_staffs") {
      const t = String(body.invite_token ?? "");
      if (!t) return json({ ok: false, error: "invite_token required" }, 400);
      const sb = svc();
      const { data: inv } = await sb.from("invitations").select("id,used_at,expires_at").eq("token", t).maybeSingle();
      if (!inv || inv.used_at || new Date(inv.expires_at) < new Date()) {
        return json({ ok: false, error: "invalid invite" }, 403);
      }
      const token = await getToken();
      const staffs = await fetchAllStaffs(token);
      const { data: profs } = await sb.from("employee_profiles").select("smaregi_staff_id").not("smaregi_staff_id", "is", null);
      const linked = new Set((profs ?? []).map((p: any) => String(p.smaregi_staff_id)));
      // 未連携のみ・個人情報は名前とフリガナだけ返す
      const list = staffs.filter((s) => !linked.has(s.staffId)).map((s) => ({ staffId: s.staffId, name: s.name, kana: s.kana }));
      return json({ ok: true, staffs: list });
    }

    // ---- 以下は要ログイン ----
    const caller = await callerRole(req);
    const isAdmin = caller.role === "CEO" || caller.role === "HQ";

    if (body.action === "test") {
      if (!isAdmin) return json({ ok: false, error: "forbidden" }, 403);
      const token = await getToken();
      const [stores, cls] = await Promise.all([
        api(token, "/stores").then((r) => r.json()),
        api(token, "/employee_classifications").then((r) => r.json()),
      ]);
      return json({ ok: true, env: IS_PROD ? "prod" : "dev", contract: CONTRACT, stores, classifications: cls });
    }

    if (body.action === "staffs") {
      if (!isAdmin) return json({ ok: false, error: caller.uid ? "forbidden" : "unauthorized" }, caller.uid ? 403 : 401);
      const token = await getToken();
      const [staffs, { data: storeRows }] = await Promise.all([
        fetchAllStaffs(token),
        svc().from("stores").select("id,smaregi_store_id").not("smaregi_store_id", "is", null),
      ]);
      // 2026-09-02追加: 店舗（事業所）ごとの所属を付与（一括招待画面での絞り込み用）
      const storeMap = await fetchStaffStoreMap(
        token,
        (storeRows ?? []).map((s: any) => ({ id: s.id, smaregiStoreId: String(s.smaregi_store_id) })),
      );
      for (const s of staffs) s.storeIds = storeMap[s.staffId] ?? [];
      return json({ ok: true, staffs });
    }

    // ---- スマレジスタッフ紐付き招待の発行（＋Resendメール送信） ----
    if (body.action === "invite") {
      if (!isAdmin) return json({ ok: false, error: "forbidden" }, 403);
      const staffId = String(body.staff_id ?? "");
      const role = String(body.role ?? "");
      if (!staffId) return json({ ok: false, error: "staff_id required" }, 400);
      if (!["AL", "SHAIN", "TENCHO", "TEAM", "HQ", "CEO"].includes(role)) {
        return json({ ok: false, error: "invalid role" }, 400);
      }
      const storeIds = Array.isArray(body.store_ids) ? body.store_ids : [];
      const days = Math.max(1, Number(body.days ?? 7));
      const sb = svc();

      // 既に連携済みでないか確認
      const { data: exists } = await sb.from("employee_profiles").select("user_id").eq("smaregi_staff_id", staffId).maybeSingle();
      if (exists) return json({ ok: false, error: "このスタッフは既にアプリと連携済みです" }, 409);

      // スタッフ詳細（メール・氏名）
      const token = await getToken();
      const sRes = await api(token, `/staffs/${staffId}`);
      const sRaw = await sRes.json().catch(() => null);
      if (!sRes.ok) return json({ ok: false, error: sRaw ?? `HTTP ${sRes.status}` }, 500);
      const staff = Array.isArray(sRaw) ? sRaw[0] : (sRaw?.staffId ? sRaw : (sRaw?.staffs?.[0] ?? sRaw));
      const sName = staff?.staffName ?? "";
      const sKana = staff?.staffKana ?? "";
      const sMail = String(staff?.mail ?? "").trim();

      // 招待発行
      const tok = Array.from(crypto.getRandomValues(new Uint8Array(16))).map((b) => b.toString(16).padStart(2, "0")).join("");
      const { error: ie } = await sb.from("invitations").insert({
        token: tok, role, store_ids: storeIds,
        note: "スマレジ連携: " + sName,
        created_by: caller.uid,
        expires_at: new Date(Date.now() + days * 86400000).toISOString(),
        smaregi_staff_id: staffId, smaregi_staff_name: sName, smaregi_staff_kana: sKana,
      });
      if (ie) return json({ ok: false, error: ie.message }, 500);
      const url = APP_URL + "?invite=" + tok;

      // メール送信（Resend）
      let emailed = false, emailError: string | null = null;
      if (body.send_email) {
        if (!sMail) emailError = "スマレジにメールアドレスが登録されていません";
        else if (!RESEND_KEY) emailError = "RESEND_API_KEY が未設定です";
        else {
          const html = `<div style="font-family:sans-serif;max-width:560px;margin:0 auto;line-height:1.8">
            <h2 style="color:#2b6cb0">🐔 鳥一代グループ 日報・週報システム</h2>
            <p>${sName} さん</p>
            <p>お疲れさまです。本部です。<br>
            スマレジ・タイムカードに登録されているあなたのアカウントを、日報・週報システムと連携するため、以下のリンクからアカウント登録をお願いします。</p>
            <p style="margin:24px 0"><a href="${url}" style="background:#2b6cb0;color:#fff;padding:12px 24px;border-radius:8px;text-decoration:none;font-weight:bold">アカウント登録をはじめる</a></p>
            <p style="font-size:13px;color:#666">・リンクの有効期限は ${days} 日間です<br>
            ・役職と所属店舗は本部側で設定済みです<br>
            ・登録するとスマレジ・タイムカードと自動で連携されます<br>
            ・このメールに心当たりがない場合は破棄してください</p>
            <p style="font-size:12px;color:#999">リンクが開けない場合はこのURLをブラウザに貼り付けてください:<br>${url}</p>
          </div>`;
          const mres = await fetch("https://api.resend.com/emails", {
            method: "POST",
            headers: { Authorization: `Bearer ${RESEND_KEY}`, "Content-Type": "application/json" },
            body: JSON.stringify({
              from: RESEND_FROM, to: [sMail],
              subject: "【鳥一代グループ】日報システム アカウント登録のご案内",
              html,
            }),
          });
          const mj = await mres.json().catch(() => ({}));
          if (mres.ok && mj.id) emailed = true;
          else emailError = "メール送信エラー: " + JSON.stringify(mj).slice(0, 300);
        }
      }
      return json({ ok: true, url, token: tok, mail: sMail, emailed, email_error: emailError });
    }

    // v2.6.10: Chatworkへメッセージ送信（DBから呼ばれる。合言葉で認証）
    // ※ pg_net は application/json しか送れず、Chatwork は form-urlencoded を要求するため中継する
    // 2026-08-21: ハードコードだった合言葉をapp_secrets参照に変更（新旧どちらも許可。R6対応）
    if (body.action === "notify_chatwork") {
      const { data: secretRows } = await svc().from("app_secrets").select("key,value")
        .in("key", ["checklist_intake_secret", "checklist_intake_secret_prev"]);
      const secretVals = (secretRows ?? []).map((r: any) => (r.value ?? "").trim());
      if (!secretVals.includes(String(body.secret ?? "").trim())) {
        return json({ ok: false, error: "forbidden" }, 403);
      }
      const room = String(body.room ?? "").trim();
      const text = String(body.text ?? "");
      const cwToken = String(body.token ?? "").trim();
      if (!room || !text || !cwToken) return json({ ok: false, error: "room/text/token required" }, 400);
      const cwRes = await fetch(`https://api.chatwork.com/v2/rooms/${room}/messages`, {
        method: "POST",
        headers: {
          "x-chatworktoken": cwToken,
          "Content-Type": "application/x-www-form-urlencoded",
        },
        // self_unread=1 で「未読」として投稿する（通知バッジが鳴るようにするため）
        body: new URLSearchParams({ body: text, self_unread: "1" }).toString(),
      });
      const cwBody = await cwRes.text();
      // 結果をログに残す（アプリから確認できるように）
      try {
        const sb2 = svc();
        await sb2.from("lark_log").insert({
          ok: cwRes.ok,
          message: text.slice(0, 300),
          detail: `Chatwork room=${room} / HTTP ${cwRes.status} / ${cwBody.slice(0, 200)}`,
        });
      } catch (_) { /* ログ失敗は無視 */ }
      return json({ ok: cwRes.ok, status: cwRes.status, body: cwBody.slice(0, 300) });
    }

    // v2.6.8: 退職日をスマレジへ反映（打刻も利用OFFにする）
    if (body.action === "terminate") {
      if (!isAdmin) return json({ ok: false, error: caller.uid ? "forbidden" : "unauthorized" }, caller.uid ? 403 : 401);
      const uid = String(body.user_id ?? "");
      const date = body.date ? String(body.date) : null;
      if (!uid) return json({ ok: false, error: "user_id required" }, 400);
      const sb = svc();
      const { data: prof } = await sb.from("employee_profiles").select("smaregi_staff_id").eq("user_id", uid).single();
      const staffId = prof?.smaregi_staff_id;
      if (!staffId) return json({ ok: true, skipped: "スマレジ未連携のためスキップ" });

      const token = await getToken();
      const res = await api(token, `/staffs/${staffId}`, {
        method: "PATCH",
        body: JSON.stringify({ terminationDate: date }),
      });
      const j = await res.json().catch(() => ({}));
      if (!res.ok) return json({ ok: false, status: res.status, error: j }, 500);

      // 退職日を設定したときは打刻も利用OFF、取り消したときはON（失敗しても退職処理自体は成功扱い）
      let activeResult = "skip";
      try {
        const ar = await api(token, `/staffs/${staffId}/active`, {
          method: "PUT",
          body: JSON.stringify({ activeFlag: date ? false : true }),
        });
        activeResult = ar.ok ? "ok" : `HTTP ${ar.status}`;
      } catch (_) { activeResult = "error"; }

      return json({ ok: true, staffId, terminationDate: date, active: activeResult });
    }

    if (body.action === "sync") {
      const uid = body.user_id;
      if (!uid) return json({ ok: false, error: "user_id required" }, 400);
      // 本人 or CEO/HQ のみ
      if (!caller.uid || (caller.uid !== uid && !isAdmin)) {
        return json({ ok: false, error: "forbidden" }, 403);
      }
      const sb = svc();
      const { data: prof } = await sb.from("employee_profiles").select("*").eq("user_id", uid).single();
      const { data: user } = await sb.from("users").select("name, role").eq("id", uid).single();
      if (!prof || !user) return json({ ok: false, error: "profile not found" }, 404);
      // 既に連携済みなら二重登録しない
      if (prof.smaregi_sync_status === "synced" && prof.smaregi_staff_id) {
        return json({ ok: true, staffId: prof.smaregi_staff_id, already: true });
      }

      const token = await getToken();
      // 役職 → スマレジ従業員区分（名前一致、なければ先頭）
      const cls = await api(token, "/employee_classifications").then((r) => r.json());
      const roleMap: Record<string, string> = {
        AL: "アルバイト", SHAIN: "正社員", TENCHO: "正社員", TEAM: "管理職", HQ: "管理職", CEO: "管理職",
      };
      const want = roleMap[user.role] ?? "";
      const pick = Array.isArray(cls) && cls.length
        ? (cls.find((c: any) => c.employeeClassificationName === want) ?? cls[0])
        : null;
      if (!pick) {
        await sb.from("employee_profiles").update({ smaregi_sync_status: "error", smaregi_error: "従業員区分が取得できません" }).eq("user_id", uid);
        return json({ ok: false, error: "no employee classification" }, 500);
      }

      const payload: Record<string, unknown> = {
        staffName: String(user.name).slice(0, 50),
        staffKana: String(prof.name_kana || "ミトウロク").slice(0, 50),
        employeeClassificationId: String(pick.employeeClassificationId),
      };
      if (prof.birth_date) payload.birthday = prof.birth_date;
      if (prof.phone) payload.phone = String(prof.phone).replace(/[^0-9+-]/g, "").slice(0, 15);
      if (prof.postal_code) payload.postCode = String(prof.postal_code).slice(0, 10);
      if (prof.address) payload.address = String(prof.address).slice(0, 200);
      if (prof.hire_date) payload.hireDate = prof.hire_date;

      // v2.6.7-1: 性別（未入力ならスマレジ側の既定「未選択」）
      const genderMap: Record<string, string> = { male: "0", female: "1", none: "9" };
      if (prof.gender && genderMap[prof.gender]) payload.gender = genderMap[prof.gender];

      // v2.6.7-3 / v2.6.14: 社員番号（スマレジ側と重複しない番号を選ぶ）
      let staffCode: string | null = prof.staff_code ?? null;
      if (!staffCode) {
        const { data: sc } = await sb.rpc("next_staff_code");
        if (sc) staffCode = String(sc);
      }
      if (staffCode) {
        const used = await fetchStaffCodes(token);
        let guard = 0;
        while (used.has(staffCode) && guard++ < 500) {
          const m = staffCode.match(/^(\d{4})-(\d+)$/);
          staffCode = m ? `${m[1]}-${String(Number(m[2]) + 1).padStart(4, "0")}` : `${staffCode}-2`;
        }
        await sb.from("employee_profiles").update({ staff_code: staffCode }).eq("user_id", uid);
        payload.staffCode = String(staffCode).slice(0, 255);
      }

      // v2.6.7-2: 緊急連絡先・自由項目（銀行情報など）を管理者メモへ
      const memoLines: string[] = [];
      const emg = [prof.emergency_name, prof.emergency_relation ? `（${prof.emergency_relation}）` : "", prof.emergency_phone]
        .filter(Boolean).join(" ").trim();
      if (emg) memoLines.push("【緊急連絡先】" + emg);
      const extra = prof.extra && typeof prof.extra === "object" ? prof.extra : null;
      if (extra) {
        for (const [k, v] of Object.entries(extra)) {
          if (v == null || v === "") continue;
          const val = Array.isArray(v) ? `${v.length}件の添付（アプリで確認）` : String(v);
          memoLines.push(`【${String(k).slice(0, 40)}】${val.slice(0, 200)}`);
        }
      }
      memoLines.push("※ 日報システムから自動登録（" + new Date().toLocaleDateString("ja-JP") + "）");
      const adminMemo = memoLines.join("\n").slice(0, 1000);
      if (adminMemo) payload.adminMemo = adminMemo;

      let res = await api(token, "/staffs", { method: "POST", body: JSON.stringify(payload) });
      let j = await res.json().catch(() => ({}));
      // v2.6.14: 社員番号の重複で弾かれたら、社員番号を外して登録し直す（登録自体を優先）
      if (res.status === 400 && String(j?.detail ?? "").includes("社員番号") && payload.staffCode) {
        delete payload.staffCode;
        await sb.from("employee_profiles").update({ staff_code: null }).eq("user_id", uid);
        res = await api(token, "/staffs", { method: "POST", body: JSON.stringify(payload) });
        j = await res.json().catch(() => ({}));
      }
      if (res.status === 201 && j.staffId) {
        await sb.from("employee_profiles").update({ smaregi_sync_status: "synced", smaregi_staff_id: String(j.staffId), smaregi_error: null }).eq("user_id", uid);
        return json({ ok: true, staffId: j.staffId });
      }
      await sb.from("employee_profiles").update({ smaregi_sync_status: "error", smaregi_error: (JSON.stringify(j) || `HTTP ${res.status}`).slice(0, 500) }).eq("user_id", uid);
      return json({ ok: false, status: res.status, error: j }, 500);
    }

    return json({ ok: false, error: "unknown action" }, 400);
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});