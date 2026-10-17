// スマレジ・タイムカード連携＋通知中継 Edge Function (smaregi-sync) v2.6.14
// v2.6.7: 性別 / 社員番号(自動採番) / 管理者メモ(緊急連絡先・自由項目) をスマレジへ送信
// ※ verify_jwt は OFF にすること（invite_staffs を未ログインの入社者が呼ぶため）。
//    各アクション内で JWT / 招待トークンによる認可チェックを行う。
// actions:
//   { action: "test" }                → 事業所/従業員区分一覧（CEO/HQのみ・疎通確認）
//   { action: "sync", user_id }      → employee_profiles を読みスマレジに従業員登録（本人 or CEO/HQ）
//   { action: "terminate", user_id, date, deactivate?, deactivate_only? } → 退職日をスマレジへ反映＋打刻の利用ON/OFF（CEO/HQ。terminateのみservice_roleも可）
//   { action: "notify_chatwork", secret, room, text, token } → Chatworkへメッセージ送信（DBからの中継用）
//   { action: "staffs" }              → スマレジ登録済みスタッフ一覧＋メール有無（CEO/HQのみ）
//   { action: "invite", staff_id, role, store_ids, days, send_email }
//                                     → スマレジスタッフ紐付きの招待を発行し、必要ならResendでメール送信（CEO/HQのみ）
//   { action: "invite_staffs", invite_token }
//                                    → 未連携スタッフの名前一覧（有効な招待トークン必須・未ログイン可）
//   { action: "pull_profiles", user_id? } → 2026-09-05追加。スマレジ側の住所・生年月日・電話番号・
//     郵便番号・性別・入社日をemployee_profilesへ取り込む（プル方向。push_profileの逆）。
//     user_id省略時は連携済み全員が対象（CEO/HQのみ）。既に入力済みの項目は上書きしない
//   { action: "push_profile", user_id } → 2026-09-05追加。nippo側のemployee_profilesの内容を
//     連携済みのスマレジへ反映（プッシュ方向。既に連携済みの人が対象。本人 or CEO/HQ）
import { createClient } from "npm:@supabase/supabase-js@2";
import { loadContracts, loadStoreMap, loadStoreMapPending, ID_BASE, API_BASE, fetchRoles, pickRoleId, putStaffStore, wantedRoleName } from "../_shared/smaregi-contracts.ts";

// 2026-10-17 担当D: 複数契約対応。契約は引数contract_id（省略時は既定の契約＝トーホー）で指定する。
// sync(入社登録)・terminate(退職)・push_profile・test・staffs が契約ごとに動く。invite/invite_staffs（スマレジ→ポータルの招待）は
// invitationsに契約の列が無いため既定の契約のみ（LiveGateの人は管理システムの入社登録=sync→employee_smaregi_linksで連携する）。
const IS_PROD = Deno.env.get("SMAREGI_ENV") === "prod";
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

async function getToken(C: string): Promise<string> {
  const res = await fetch(`${ID_BASE}/app/${C}/token`, {
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

const api = (C: string, token: string, path: string, init: RequestInit = {}) =>
  fetch(`${API_BASE}/${C}/timecard${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      ...(init.headers ?? {}),
    },
  });

// スタッフ全件（ページング・退職者除外）
async function fetchAllStaffs(C: string, token: string) {
  const clsRaw = await api(C, token, "/employee_classifications").then((r) => r.json());
  const clsArr = Array.isArray(clsRaw) ? clsRaw : (clsRaw?.employeeClassifications ?? []);
  const clsMap: Record<string, string> = {};
  for (const c of clsArr) clsMap[String(c.employeeClassificationId)] = c.employeeClassificationName;
  const staffs: any[] = [];
  for (let page = 1; page <= 20; page++) {
    const r = await api(C, token, `/staffs?limit=100&page=${page}`);
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
        // 2026-09-05追加: 個人情報の取り込み(pull_profiles)用。/staffs一覧の時点で既に返ってきている
        // フィールドなので、ページング済みのこの一覧をそのまま使い回す（個別に/staffs/{id}を叩き直さない）
        postCode: s.postCode ?? null,
        address: s.address ?? null,
        phone: s.phone ?? null,
        birthday: s.birthday ?? null,
        gender: s.gender ?? null,
        hireDate: s.hireDate ?? null,
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
async function fetchStaffStoreMap(C: string, token: string, storeList: { id: string; smaregiStoreId: string }[]) {
  const map: Record<string, string[]> = {}; // staffId -> [内部store UUID, ...]
  for (const st of storeList) {
    if (!st.smaregiStoreId) continue;
    try {
      for (let page = 1; page <= 5; page++) {
        const r = await api(C, token, `/staffs?store_id=${encodeURIComponent(st.smaregiStoreId)}&limit=100&page=${page}`);
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
async function fetchStaffCodes(C: string, token: string): Promise<Set<string>> {
  const set = new Set<string>();
  try {
    for (let page = 1; page <= 20; page++) {
      const r = await api(C, token, `/staffs?limit=100&page=${page}`);
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

    // 契約の解決（契約IDは契約マスタに登録済みのものだけ許可。省略時は既定の契約＝トーホー）
    const allContracts = await loadContracts(svc());
    const reqContract = body.contract_id
      ? allContracts.find((x) => x.contract_id === String(body.contract_id))
      : (allContracts.find((x) => x.is_default) ?? allContracts[0]);
    if (!reqContract) return json({ ok: false, error: body.contract_id ? "未登録のスマレジ契約IDです" : "有効なスマレジ契約がありません" }, 400);
    const C = reqContract.contract_id;
    const IS_DEFAULT = reqContract.is_default;

    // ---- 未連携スタッフの名前一覧（未ログイン・有効な招待トークン必須） ----
    if (body.action === "invite_staffs") {
      const t = String(body.invite_token ?? "");
      if (!t) return json({ ok: false, error: "invite_token required" }, 400);
      const sb = svc();
      const { data: inv } = await sb.from("invitations").select("id,used_at,expires_at").eq("token", t).maybeSingle();
      if (!inv || inv.used_at || new Date(inv.expires_at) < new Date()) {
        return json({ ok: false, error: "invalid invite" }, 403);
      }
      const token = await getToken(C);
      const staffs = await fetchAllStaffs(C, token);
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
      const token = await getToken(C);
      const [stores, cls] = await Promise.all([
        api(C, token, "/stores").then((r) => r.json()),
        api(C, token, "/employee_classifications").then((r) => r.json()),
      ]);
      return json({ ok: true, env: IS_PROD ? "prod" : "dev", contract: C, stores, classifications: cls });
    }

    if (body.action === "staffs") {
      if (!isAdmin) return json({ ok: false, error: caller.uid ? "forbidden" : "unauthorized" }, caller.uid ? 403 : 401);
      const token = await getToken(C);
      const [staffs, smStoreMap] = await Promise.all([
        fetchAllStaffs(C, token),
        loadStoreMapPending(svc(), reqContract), // スマレジの事業所ID→店舗UUID（契約ごと）
      ]);
      // 2026-09-02追加: 店舗（事業所）ごとの所属を付与（一括招待画面での絞り込み用）
      const storeMap = await fetchStaffStoreMap(
        C, token,
        Object.entries(smStoreMap).map(([smId, id]) => ({ id, smaregiStoreId: String(smId) })),
      );
      for (const s of staffs) s.storeIds = storeMap[s.staffId] ?? [];
      return json({ ok: true, staffs });
    }

    // ---- 2026-09-05追加: スマレジの個人情報(住所・生年月日・電話番号等)をemployee_profilesへ
    //   取り込む（プル方向。既存のaction:"sync"はnippo→スマレジへの一方向pushのみで、
    //   スマレジ側が既に持っている個人情報をnippo側へ反映する経路が無かった＝ユーザー指摘に対応）。
    //   安全のため「現在空欄の項目だけ埋める」方式（既に入力済みの値は絶対に上書きしない）。
    //   body: { action:"pull_profiles", user_id? }  user_id省略時は連携済み全員（CEO/HQのみ）
    if (body.action === "pull_profiles") {
      // 2026-09-05追加: 日次の自動実行（GitHub Actions・smaregi-payroll-sync.ymlと同じ方式）から
      // service_roleキーで呼べるようにする（このアクションだけの限定的なバイパス）
      const isServiceRole = (req.headers.get("Authorization") ?? "").includes(Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? " ");
      if (!isAdmin && !isServiceRole) return json({ ok: false, error: caller.uid ? "forbidden" : "unauthorized" }, caller.uid ? 403 : 401);
      const sb = svc();
      const uid = body.user_id ? String(body.user_id) : null;
      let profQuery = sb.from("employee_profiles").select("user_id,smaregi_staff_id,name_kana,birth_date,phone,postal_code,address,gender,hire_date").not("smaregi_staff_id", "is", null);
      if (uid) profQuery = profQuery.eq("user_id", uid);
      const { data: profs } = await profQuery;
      if (!profs || !profs.length) return json({ ok: true, updated: [], skipped: [], errorCount: 0, errors: [] });

      const token = await getToken(C);
      const staffs = await fetchAllStaffs(C, token);
      const byStaffId: Record<string, any> = {};
      for (const s of staffs) byStaffId[s.staffId] = s;

      const genderFromCode = (g: unknown): string | null => {
        const v = String(g ?? "");
        if (v === "0") return "male";
        if (v === "1") return "female";
        return null; // 未選択・不明なコードは無理に埋めない
      };

      const updated: any[] = [];
      const skipped: any[] = [];
      const errors: string[] = [];
      for (const p of profs) {
        const s = byStaffId[String(p.smaregi_staff_id)];
        if (!s) { skipped.push({ user_id: p.user_id, reason: "スマレジ側で見つかりません（退職済み等）" }); continue; }
        const patch: Record<string, unknown> = {};
        if (!p.name_kana && s.kana) patch.name_kana = s.kana;
        if (!p.birth_date && s.birthday) patch.birth_date = s.birthday;
        if (!p.phone && s.phone) patch.phone = s.phone;
        if (!p.postal_code && s.postCode) patch.postal_code = s.postCode;
        if (!p.address && s.address) patch.address = s.address;
        if (!p.gender && genderFromCode(s.gender)) patch.gender = genderFromCode(s.gender);
        if (!p.hire_date && s.hireDate) patch.hire_date = s.hireDate;
        if (!Object.keys(patch).length) { skipped.push({ user_id: p.user_id, reason: "埋める項目がありません（既に入力済み、またはスマレジ側も未入力）" }); continue; }
        patch.updated_at = new Date().toISOString();
        const { error } = await sb.from("employee_profiles").update(patch).eq("user_id", p.user_id);
        if (error) { errors.push(`${p.user_id}: ${error.message}`); continue; }
        updated.push({ user_id: p.user_id, filled: Object.keys(patch).filter((k) => k !== "updated_at") });
      }
      return json({ ok: true, updated, updatedCount: updated.length, skipped, skippedCount: skipped.length, errorCount: errors.length, errors });
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
      const token = await getToken(C);
      const sRes = await api(C, token, `/staffs/${staffId}`);
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
    // 2026-10-03(Sync7・退職申請承認): 在籍判定を「退職日の翌日に自動停止」へ変えたため、任意引数を2つ追加
    //   deactivate      … 既定true(従来動作＝退職日の登録＋打刻OFF)。falseなら退職日だけ送り打刻は止めない（承認時に使う）
    //   deactivate_only … trueなら退職日は送らず打刻OFF(activeFlag:false)だけ行う（退職日の翌日の自動処理が使う）
    //   既存の呼び出し元（従業員編集の退職日カード等）は引数なし＝従来どおり。
    // 認可: CEO/HQのJWTに加え、毎日の自動処理(GitHub Actions)がservice_roleキーで呼べるようにした（attendance-syncと同じ方式）。
    //   ※service_role許可はこのterminateアクションだけ。他のアクションは従来どおりCEO/HQのみ
    if (body.action === "terminate") {
      const isService = (req.headers.get("Authorization") ?? "").includes(Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? " ");
      if (!isAdmin && !isService) return json({ ok: false, error: caller.uid ? "forbidden" : "unauthorized" }, caller.uid ? 403 : 401);
      const uid = String(body.user_id ?? "");
      const date = body.date ? String(body.date) : null;
      const deactivate = body.deactivate !== false;
      const deactivateOnly = body.deactivate_only === true;
      if (!uid) return json({ ok: false, error: "user_id required" }, 400);
      const sb = svc();
      // 対象の契約: contract_id指定があればその契約だけ（移籍＝旧契約だけ終了）、省略なら有効なリンクすべて（退職＝全契約を終了）
      // deactivate_only（退職日の翌日の自動の打刻OFF）は、退職日でリンクが閉じた後に呼ばれるため、閉じたリンクも対象にする
      const { data: linkRowsAll } = await sb.from("employee_smaregi_links").select("contract_id,smaregi_staff_id,effective_to").eq("user_id", uid);
      const linkRows = (linkRowsAll ?? []).filter((l: any) => deactivateOnly || !l.effective_to);
      let targets: { contract: string; staffId: string }[] = linkRows.map((l: any) => ({ contract: l.contract_id, staffId: String(l.smaregi_staff_id) }));
      if (!targets.length) { // リンク表が未整備の環境向けの互換（employee_profilesの主契約）
        const { data: prof } = await sb.from("employee_profiles").select("smaregi_staff_id").eq("user_id", uid).single();
        if (prof?.smaregi_staff_id) targets = [{ contract: allContracts.find((x) => x.is_default)?.contract_id ?? C, staffId: String(prof.smaregi_staff_id) }];
      }
      if (body.contract_id) targets = targets.filter((t) => t.contract === C);
      if (!targets.length) return json({ ok: true, skipped: "スマレジ未連携のためスキップ" });

      const results: any[] = [];
      for (const t of targets) {
        const token = await getToken(t.contract);
        if (!deactivateOnly) {
          const res = await api(t.contract, token, `/staffs/${t.staffId}`, {
            method: "PATCH",
            body: JSON.stringify({ terminationDate: date }),
          });
          const j = await res.json().catch(() => ({}));
          if (!res.ok) return json({ ok: false, contract: t.contract.slice(-3), status: res.status, error: j }, 500);
        }

        // 退職日を設定したときは打刻も利用OFF、取り消したときはON（失敗しても退職処理自体は成功扱い）。
        // deactivate=false(承認時)は打刻を触らない。deactivate_only=trueは必ず打刻OFF
        let activeResult = "skip";
        if (deactivateOnly || deactivate) {
          try {
            const ar = await api(t.contract, token, `/staffs/${t.staffId}/active`, {
              method: "PUT",
              body: JSON.stringify({ activeFlag: deactivateOnly ? false : (date ? false : true) }),
            });
            activeResult = ar.ok ? "ok" : `HTTP ${ar.status}`;
          } catch (_) { activeResult = "error"; }
        }
        if (deactivateOnly && activeResult !== "ok") return json({ ok: false, staffId: t.staffId, active: activeResult, error: "打刻OFFに失敗しました" }, 500);
        // リンクの期間を更新（退職日を入れたら有効期間をその日で閉じる。取り消し=null指定なら再び有効に）
        if (!deactivateOnly && linkRows.length) {
          if (date) await sb.from("employee_smaregi_links").update({ effective_to: date }).eq("user_id", uid).eq("contract_id", t.contract).is("effective_to", null);
        }
        results.push({ contract: t.contract.slice(-3), staffId: t.staffId, active: activeResult });
      }
      return json({ ok: true, staffId: results[0]?.staffId, terminationDate: deactivateOnly ? undefined : date, active: results[0]?.active, contracts: results });
    }

    // 2026-09-05追加: nippo側で住所・生年月日・電話番号等を編集したら、既に連携済みの
    // スマレジ側にもその場で反映する（nippo→スマレジのpush。pull_profilesの逆方向）。
    // ユーザー要望「どちらかを修正したら同期されるようにしたい」への対応（の半分）。
    // 既に連携済みの人が対象（未連携なら"sync"で新規登録する側の役目のため何もしない）
    if (body.action === "push_profile") {
      const uid = String(body.user_id ?? "");
      if (!uid) return json({ ok: false, error: "user_id required" }, 400);
      if (!caller.uid || (caller.uid !== uid && !isAdmin)) return json({ ok: false, error: "forbidden" }, 403);
      const sb = svc();
      const { data: prof } = await sb.from("employee_profiles").select("*").eq("user_id", uid).maybeSingle();
      // 反映先: 有効な契約リンクすべて（兼務の人は両方の契約のスマレジへ）。リンク表が未整備なら主契約のみ
      const { data: pLinks } = await sb.from("employee_smaregi_links").select("contract_id,smaregi_staff_id").eq("user_id", uid).is("effective_to", null);
      let pushTargets: { contract: string; staffId: string }[] = (pLinks ?? []).map((l: any) => ({ contract: l.contract_id, staffId: String(l.smaregi_staff_id) }));
      if (!pushTargets.length && prof?.smaregi_staff_id) pushTargets = [{ contract: allContracts.find((x) => x.is_default)?.contract_id ?? C, staffId: String(prof.smaregi_staff_id) }];
      if (body.contract_id) pushTargets = pushTargets.filter((t) => t.contract === C);
      if (!prof || !pushTargets.length) return json({ ok: true, skipped: "スマレジ未連携のためスキップ" });

      const patch: Record<string, unknown> = {};
      if (prof.name_kana) patch.staffKana = String(prof.name_kana).slice(0, 50);
      if (prof.birth_date) patch.birthday = prof.birth_date;
      if (prof.phone) patch.phone = String(prof.phone).replace(/[^0-9+-]/g, "").slice(0, 15);
      if (prof.postal_code) patch.postCode = String(prof.postal_code).slice(0, 10);
      if (prof.address) patch.address = String(prof.address).slice(0, 200);
      if (prof.hire_date) patch.hireDate = prof.hire_date;
      const genderMap: Record<string, string> = { male: "0", female: "1", none: "9" };
      if (prof.gender && genderMap[prof.gender]) patch.gender = genderMap[prof.gender];
      if (!Object.keys(patch).length) return json({ ok: true, skipped: "反映する項目がありません" });

      const pushed: any[] = [];
      for (const t of pushTargets) {
        const token = await getToken(t.contract);
        const res = await api(t.contract, token, `/staffs/${t.staffId}`, { method: "PATCH", body: JSON.stringify(patch) });
        const j = await res.json().catch(() => ({}));
        if (!res.ok) return json({ ok: false, contract: t.contract.slice(-3), status: res.status, error: j }, 500);
        pushed.push({ contract: t.contract.slice(-3), staffId: t.staffId });
      }
      return json({ ok: true, staffId: pushed[0].staffId, pushed: Object.keys(patch), contracts: pushed });
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
      // 既に連携済みなら二重登録しない（v2.6.14まではここで終わっていたが、2026-09-05追記:
      // 個人情報の更新は上のaction:"push_profile"が担当するようになったため、ここでの役割は
      // 「初回のスマレジ新規登録」のみに変更なし）
      // 2026-10-17: 契約ごとに判定。既定の契約は従来どおりemployee_profiles、それ以外の契約はemployee_smaregi_linksの有効行
      if (IS_DEFAULT) {
        if (prof.smaregi_sync_status === "synced" && prof.smaregi_staff_id) {
          return json({ ok: true, staffId: prof.smaregi_staff_id, already: true, contract_id: C });
        }
      } else {
        const { data: existLink } = await sb.from("employee_smaregi_links").select("smaregi_staff_id").eq("user_id", uid).eq("contract_id", C).is("effective_to", null).maybeSingle();
        if (existLink) return json({ ok: true, staffId: existLink.smaregi_staff_id, already: true, contract_id: C });
      }

      const token = await getToken(C);
      // 役職 → スマレジ従業員区分（名前一致、なければ先頭）
      const cls = await api(C, token, "/employee_classifications").then((r) => r.json());
      const roleMap: Record<string, string> = {
        AL: "アルバイト", SHAIN: "正社員", TENCHO: "正社員", TEAM: "管理職", HQ: "管理職", CEO: "管理職",
      };
      const want = roleMap[user.role] ?? "";
      const pick = Array.isArray(cls) && cls.length
        ? (cls.find((c: any) => c.employeeClassificationName === want) ?? cls[0])
        : null;
      if (!pick) {
        if (IS_DEFAULT) await sb.from("employee_profiles").update({ smaregi_sync_status: "error", smaregi_error: "従業員区分が取得できません" }).eq("user_id", uid);
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
        const used = await fetchStaffCodes(C, token);
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

      let res = await api(C, token, "/staffs", { method: "POST", body: JSON.stringify(payload) });
      let j = await res.json().catch(() => ({}));
      // v2.6.14: 社員番号の重複で弾かれたら、社員番号を外して登録し直す（登録自体を優先）
      if (res.status === 400 && String(j?.detail ?? "").includes("社員番号") && payload.staffCode) {
        delete payload.staffCode;
        await sb.from("employee_profiles").update({ staff_code: null }).eq("user_id", uid);
        res = await api(C, token, "/staffs", { method: "POST", body: JSON.stringify(payload) });
        j = await res.json().catch(() => ({}));
      }
      if (res.status === 201 && j.staffId) {
        if (IS_DEFAULT) {
          // 既定の契約: 従来どおり主契約の写し(employee_profiles)へ。トリガーがトーホー契約のリンクにも反映する
          await sb.from("employee_profiles").update({ smaregi_sync_status: "synced", smaregi_staff_id: String(j.staffId), smaregi_error: null }).eq("user_id", uid);
        } else {
          // それ以外の契約（LiveGate等）: employee_profilesの主契約は変えず、従業員×契約リンクへ保存（兼務なら有効行が2本並ぶ）
          const { error: lerr } = await sb.from("employee_smaregi_links").insert({ user_id: uid, contract_id: C, smaregi_staff_id: String(j.staffId), is_primary: false });
          if (lerr) return json({ ok: false, staffId: j.staffId, contract_id: C, error: "スマレジには登録しましたが、リンクの保存に失敗しました: " + lerr.message }, 500);
        }
        return json({ ok: true, staffId: j.staffId, contract_id: C });
      }
      if (IS_DEFAULT) await sb.from("employee_profiles").update({ smaregi_sync_status: "error", smaregi_error: (JSON.stringify(j) || `HTTP ${res.status}`).slice(0, 500) }).eq("user_id", uid);
      return json({ ok: false, status: res.status, contract_id: C, error: j }, 500);
    }

    // ---- 2026-10-17 担当B: 所属店舗（管理システム）とスマレジの所属事業所を、1人×1契約で今すぐ一致させる（従業員編集の「今すぐ同期」）----
    //   { action:"store_sync", user_id, contract_id?, direction:"portal_to_smaregi"|"smaregi_to_portal", dry_run? }
    //   direction=portal_to_smaregi: 管理システムの所属を正にして、スマレジへ PUT/DELETE /staffs/{id}/staff_stores/{store_id}（既定。設計メモ§11-5＝基本は管理システムが正本）
    //   direction=smaregi_to_portal: スマレジの所属を正にして、管理システムの user_stores をこの契約の店舗の範囲で置き換える
    //   dry_run=true: 何も変えず、スマレジの最新の所属（事業所ごとの所属スタッフ一覧を店舗数ぶん呼んで判定）と差分だけ返す
    //   比べる範囲は「この契約に対応のある店舗」だけ（兼務の人のトーホー側・LiveGate側を混ぜない）。除外リスト(smaregi_store_ignore)の事業所は無視。
    //   安全弁: 正にする側の所属が0件のときは、反対側を全部消してしまうため実行しない。
    //   結果は同期台帳 staff_store_sync（この人×契約の行を作り直す）と スナップショット(smaregi_staff_stores_snapshot)のこの人の行に反映する。
    //   ※スマレジの staff_stores 書き込みAPIは本番で未検証（初回は立会いで dry_run→実行）。認可: CEO/HQ
    if (body.action === "store_sync") {
      if (!isAdmin) return json({ ok: false, error: "forbidden" }, 403);
      const uid = String(body.user_id ?? "");
      if (!uid) return json({ ok: false, error: "user_id required" }, 400);
      const direction = String(body.direction ?? "portal_to_smaregi");
      if (!["portal_to_smaregi", "smaregi_to_portal"].includes(direction)) return json({ ok: false, error: "direction が不正です" }, 400);
      const dry = body.dry_run === true;
      const sb = svc();
      // スタッフID（その契約の有効なリンク。既定の契約はリンク表が無い環境のためemployee_profilesへ互換フォールバック）
      let staffId = "";
      const { data: lk } = await sb.from("employee_smaregi_links").select("smaregi_staff_id").eq("user_id", uid).eq("contract_id", C).is("effective_to", null).maybeSingle();
      if (lk?.smaregi_staff_id) staffId = String(lk.smaregi_staff_id);
      else if (IS_DEFAULT) {
        const { data: pr } = await sb.from("employee_profiles").select("smaregi_staff_id").eq("user_id", uid).maybeSingle();
        if (pr?.smaregi_staff_id) staffId = String(pr.smaregi_staff_id);
      }
      if (!staffId) return json({ ok: false, error: "この契約のスマレジにまだ登録されていません" }, 400);

      const storeMap = await loadStoreMapPending(sb, reqContract); // スマレジの事業所ID → 店舗UUID（この契約のもの。今日が空なら予約済みの対応）
      const portalForContract = new Set(Object.values(storeMap));
      const reverse: Record<string, string> = {};            // 店舗UUID → スマレジの事業所ID
      for (const [smId, stId] of Object.entries(storeMap)) if (!reverse[stId]) reverse[stId] = smId;
      const { data: ign } = await sb.from("smaregi_store_ignore").select("store_id").eq("contract_id", C);
      const ignored = new Set((ign ?? []).map((r: any) => String(r.store_id)));

      const token = await getToken(C);
      // スマレジ側の所属（最新）: この人の所属を直接読む。
      //   ※ /staffs?store_id= は所属者が0人の事業所だと全員を返すことがあり、「既に所属している」と誤判定して書き込みが行われなかったため使わない
      const smaregiNow = new Set<string>();            // スマレジの事業所ID（除外を除く）
      const ssRes = await api(C, token, `/staff_stores?staff_id=${encodeURIComponent(staffId)}`);
      const ssRaw = await ssRes.json().catch(() => null);
      if (!ssRes.ok) return json({ ok: false, error: "スマレジの所属を取得できません(" + ssRes.status + "): " + JSON.stringify(ssRaw).slice(0, 160) }, 500);
      for (const x of (Array.isArray(ssRaw) ? ssRaw : (ssRaw?.staffStores ?? []))) {
        const sid = String(x.storeId);
        if (String(x.staffId) === staffId && !ignored.has(sid)) smaregiNow.add(sid);
      }
      const smaregiStoreIds = new Set<string>();       // 店舗UUIDに変換できたもの
      const unmapped: string[] = [];
      for (const sid of smaregiNow) { if (storeMap[sid]) smaregiStoreIds.add(storeMap[sid]); else unmapped.push(sid); }
      const { data: us } = await sb.from("user_stores").select("store_id").eq("user_id", uid);
      const portalIds = new Set<string>((us ?? []).map((r: any) => r.store_id).filter((x: string) => portalForContract.has(x)));
      const onlyPortal = [...portalIds].filter((x) => !smaregiStoreIds.has(x));
      const onlySmaregi = [...smaregiStoreIds].filter((x) => !portalIds.has(x));
      const allIds = [...new Set([...onlyPortal, ...onlySmaregi])];
      const names: Record<string, string> = {};
      if (allIds.length) { const { data: nm } = await sb.from("stores").select("id,name").in("id", allIds); (nm ?? []).forEach((r: any) => { names[r.id] = r.name; }); }
      const label = (ids: string[]) => ids.map((i) => names[i] ?? i);
      const diff = { only_portal: label(onlyPortal), only_smaregi: label(onlySmaregi), unmapped_smaregi_stores: unmapped, in_sync: !onlyPortal.length && !onlySmaregi.length };
      if (dry) return json({ ok: true, dry_run: true, contract_id: C, staffId, ...diff });
      if (diff.in_sync) { /* 既に一致。台帳だけ最新にする */ }

      let addedToSmaregi = 0, removedFromSmaregi = 0, addedToPortal = 0, removedFromPortal = 0;
      if (direction === "portal_to_smaregi") {
        if (!portalIds.size && smaregiStoreIds.size) return json({ ok: false, error: "管理システム側のこの契約の所属が0件のため実行しません（スマレジの所属を全部消してしまうため）。反対向き（スマレジに合わせる）を選ぶか、所属を登録してください" }, 400);
        // 追加には役割ID(roleId)が必須。区分に合う役割（AL=アルバイト／それ以外=社員）を、追加先の事業所ごとに引く
        const { data: urole } = await sb.from("users").select("role").eq("id", uid).maybeSingle();
        const roles = onlyPortal.length ? await fetchRoles(C, token, onlyPortal.map((st) => reverse[st])) : [];
        for (const st of onlyPortal) {
          const smId = reverse[st];
          const roleId = pickRoleId(roles, smId, wantedRoleName(urole?.role));
          if (!roleId) return json({ ok: false, error: `スマレジの事業所${smId}に役割「${wantedRoleName(urole?.role)}」が見つかりません`, added: addedToSmaregi, removed: removedFromSmaregi }, 500);
          const r = await putStaffStore(C, token, staffId, smId, roleId);
          if (!r.ok) return json({ ok: false, error: `スマレジへの所属追加に失敗(${r.status}): ${r.text}`, added: addedToSmaregi, removed: removedFromSmaregi }, 500);
          addedToSmaregi++;
        }
        for (const st of onlySmaregi) {
          const smId = reverse[st];
          const r = await api(C, token, `/staffs/${staffId}/staff_stores/${encodeURIComponent(smId)}`, { method: "DELETE" });
          if (!r.ok) return json({ ok: false, error: `スマレジからの所属解除に失敗(${r.status}): ${(await r.text()).slice(0, 200)}`, added: addedToSmaregi, removed: removedFromSmaregi }, 500);
          removedFromSmaregi++;
        }
      } else {
        if (!smaregiStoreIds.size && portalIds.size) return json({ ok: false, error: "スマレジ側のこの契約の所属が0件のため実行しません（管理システムの所属を全部消してしまうため）" }, 400);
        for (const st of onlySmaregi) {
          const { error } = await sb.from("user_stores").insert({ user_id: uid, store_id: st });
          if (error) return json({ ok: false, error: "管理システムへの所属追加に失敗: " + error.message }, 500);
          addedToPortal++;
        }
        for (const st of onlyPortal) {
          const { error } = await sb.from("user_stores").delete().eq("user_id", uid).eq("store_id", st);
          if (error) return json({ ok: false, error: "管理システムの所属解除に失敗: " + error.message }, 500);
          removedFromPortal++;
        }
      }
      // 台帳・スナップショットを「一致した状態」に更新（この人×契約）
      const finalIds = direction === "portal_to_smaregi" ? [...portalIds] : [...smaregiStoreIds];
      const now = new Date().toISOString();
      await sb.from("staff_store_sync").delete().eq("user_id", uid).eq("contract_id", C);
      if (finalIds.length) {
        await sb.from("staff_store_sync").insert(finalIds.map((st) => ({ user_id: uid, contract_id: C, store_id: st, smaregi_staff_id: staffId, smaregi_store_id: reverse[st] ?? null, last_synced_at: now, synced_hash: null })));
      }
      // 所属のズレ一覧(未読バッジ用)から、この人×契約の行を消す（次の日次実行を待たずにバッジを減らす）
      await sb.from("staff_store_mismatch").delete().eq("user_id", uid).eq("contract_id", C);
      await sb.from("smaregi_staff_stores_snapshot").delete().eq("contract_id", C).eq("smaregi_staff_id", staffId);
      const snapIds = finalIds.map((st) => reverse[st]).filter(Boolean);
      if (snapIds.length) await sb.from("smaregi_staff_stores_snapshot").insert(snapIds.map((sm) => ({ contract_id: C, smaregi_staff_id: staffId, smaregi_store_id: sm, fetched_at: now })));
      return json({ ok: true, contract_id: C, staffId, direction, added_to_smaregi: addedToSmaregi, removed_from_smaregi: removedFromSmaregi, added_to_portal: addedToPortal, removed_from_portal: removedFromPortal, ...diff });
    }

    // ---- 2026-10-17 担当B: 賃金設定（時給・月給）の反映／取り込み。管理システム employee_wage_settings が正本 → スマレジ wage_apply ----
    //   { action:"wage_push", user_id, contract_id? }  反映待ち(pending)・失敗(error)の行をスマレジへ。時給=division 0（店舗なし=事業所未指定／店舗あり=事業所別settings）・月給=division 2。
    //     既にスマレジの賃金設定ID(smaregi_wage_apply_id)がある行は PUT で更新、無ければ POST。POSTが400（同じ適用開始日の重複など）なら、
    //     スマレジ側の既存設定（GET /staffs/{id} の wageApply）から同じ 区分×事業所×適用開始日 を探して PUT する。1行ずつ結果を表へ保存（失敗しても他の行は続行）
    //   { action:"wage_pull", user_id, contract_id?, import? }  スマレジの現在の賃金設定(wageApply)を返す。import=true なら、管理システムに無い行を synced として取り込む
    //     （管理システム側に反映待ちの行がある 区分×事業所×適用開始日 は上書きしない＝ズレとして返す）。日給(1)・営業時間帯別(3)は対象外（件数だけ返す）
    //   { action:"wage_update", user_id, contract_id, id, wage?, holiday_wage?, effective_date? }  既存の賃金設定の金額・休日賃金・適用開始日を直して、スマレジへも反映（区分・店舗は変えない＝変えるときは削除して入れ直す）
    //   { action:"wage_delete", user_id, contract_id, id }  スマレジの賃金設定を削除(DELETE /staffs/{id}/wage_apply/{wage_apply_id}。404は削除済み扱い)してから管理システムの行を消す
    //   ※スマレジの賃金設定API（POST/PUT/DELETE /staffs/{id}/wage_apply）。POST/PUT は本番で確認済み(2026-10-17)。認可: CEO/HQ
    if (body.action === "wage_push" || body.action === "wage_pull" || body.action === "wage_update" || body.action === "wage_delete") {
      // 認可: CEO/HQ。加えて wage_push だけは service_role キーからも呼べる（LINEの返信で賃金を登録する line-webhook が内部から呼ぶ。賃金の保存と本人確認はline-webhook側で済んでいる）
      const isServiceWage = body.action === "wage_push" && (req.headers.get("Authorization") ?? "").includes(Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? " ");
      if (!isAdmin && !isServiceWage) return json({ ok: false, error: "forbidden" }, 403);
      const uid = String(body.user_id ?? "");
      if (!uid) return json({ ok: false, error: "user_id required" }, 400);
      const sb = svc();
      let staffId = "";
      const { data: lk } = await sb.from("employee_smaregi_links").select("smaregi_staff_id").eq("user_id", uid).eq("contract_id", C).is("effective_to", null).maybeSingle();
      if (lk?.smaregi_staff_id) staffId = String(lk.smaregi_staff_id);
      else if (IS_DEFAULT) {
        const { data: pr } = await sb.from("employee_profiles").select("smaregi_staff_id").eq("user_id", uid).maybeSingle();
        if (pr?.smaregi_staff_id) staffId = String(pr.smaregi_staff_id);
      }
      if (!staffId) return json({ ok: false, error: "この契約のスマレジにまだ登録されていません" }, 400);
      const storeMap = await loadStoreMapPending(sb, reqContract);   // スマレジの事業所ID → 店舗UUID（今日が空なら予約済みの対応）
      const reverse: Record<string, string> = {};              // 店舗UUID → スマレジの事業所ID
      for (const [smId, stId] of Object.entries(storeMap)) if (!reverse[stId]) reverse[stId] = smId;
      const token = await getToken(C);
      const errText = async (r: Response) => { const t = await r.text(); try { const j = JSON.parse(t); return `${j.title ?? ""} ${j.detail ?? ""}`.trim() || t.slice(0, 200); } catch (_) { return t.slice(0, 200); } };
      // スマレジの現在の賃金設定（正規化）
      const fetchWageApply = async () => {
        const r = await api(C, token, `/staffs/${staffId}`);
        const raw = await r.json().catch(() => null);
        if (!r.ok) throw new Error(`スマレジの従業員情報を取得できません(${r.status}): ${JSON.stringify(raw).slice(0, 160)}`);
        const st = Array.isArray(raw) ? raw[0] : raw;
        const list: any[] = st?.wageApply ?? [];
        return list.map((w) => ({
          id: String(w.wageApplyId), division: Number(w.division), storeId: w.storeId ? String(w.storeId) : null,
          effectiveDate: String(w.effectiveDate ?? "").slice(0, 10), wage: Number(w.wage), holidayWage: w.holidayWage === null || w.holidayWage === undefined || w.holidayWage === "" ? null : Number(w.holidayWage),
        }));
      };

      if (body.action === "wage_pull") {
        let list;
        try { list = await fetchWageApply(); } catch (e) { return json({ ok: false, error: String((e as Error).message ?? e) }, 500); }
        const { data: mine } = await sb.from("employee_wage_settings").select("*").eq("user_id", uid).eq("contract_id", C);
        const keyOf = (division: number, storeUuid: string | null, d: string) => `${division}|${storeUuid ?? ""}|${d}`;
        const have: Record<string, any> = {};
        for (const m of mine ?? []) have[keyOf(m.division, m.store_id, m.effective_date)] = m;
        const names: Record<string, string> = {};
        const { data: stn } = await sb.from("stores").select("id,name"); (stn ?? []).forEach((x: any) => { names[x.id] = x.name; });
        const out: any[] = []; let imported = 0, skipped = 0, conflicts = 0, unsupported = 0;
        for (const w of list) {
          if (![0, 2].includes(w.division)) { unsupported++; out.push({ ...w, note: "日給・営業時間帯別は取り込み対象外" }); continue; }
          const storeUuid = w.storeId ? (storeMap[w.storeId] ?? null) : null;
          if (w.storeId && !storeUuid) { skipped++; out.push({ ...w, note: "管理システムに対応する店舗がありません" }); continue; }
          const k = keyOf(w.division, storeUuid, w.effectiveDate), ex = have[k];
          const row = { ...w, store_id: storeUuid, store_name: storeUuid ? names[storeUuid] : null };
          if (ex && (ex.wage !== w.wage || (ex.holiday_wage ?? null) !== (w.holidayWage ?? null))) {
            if (ex.sync_status === "synced") { // 管理システムも反映済み扱い→スマレジの値を正として更新
              if (body.import === true) await sb.from("employee_wage_settings").update({ wage: w.wage, holiday_wage: w.holidayWage, smaregi_wage_apply_id: w.id, synced_at: new Date().toISOString(), updated_at: new Date().toISOString() }).eq("id", ex.id);
              imported += body.import === true ? 1 : 0; out.push({ ...row, note: "スマレジの値で更新" + (body.import === true ? "" : "（未実行）") });
            } else { conflicts++; out.push({ ...row, note: `管理システム側に未反映の値があります（${ex.wage}円）` }); }
          } else if (!ex) {
            if (body.import === true) {
              await sb.from("employee_wage_settings").insert({ user_id: uid, contract_id: C, division: w.division, store_id: storeUuid, wage: w.wage, holiday_wage: w.division === 0 ? w.holidayWage : null, effective_date: w.effectiveDate, smaregi_wage_apply_id: w.id, sync_status: "synced", synced_at: new Date().toISOString() });
              imported++;
            }
            out.push({ ...row, note: body.import === true ? "取り込みました" : "取り込み対象" });
          } else {
            if (!ex.smaregi_wage_apply_id && body.import === true) await sb.from("employee_wage_settings").update({ smaregi_wage_apply_id: w.id, sync_status: "synced", sync_error: null, synced_at: new Date().toISOString() }).eq("id", ex.id);
            out.push({ ...row, note: "一致" });
          }
        }
        return json({ ok: true, contract_id: C, staffId, count: list.length, imported, skipped, conflicts, unsupported, wages: out });
      }

      // ---- wage_update / wage_delete（1行の修正・削除）----
      if (body.action === "wage_delete" || body.action === "wage_update") {
        const id = String(body.id ?? "");
        const { data: row } = await sb.from("employee_wage_settings").select("*").eq("id", id).eq("user_id", uid).eq("contract_id", C).maybeSingle();
        if (!row) return json({ ok: false, error: "賃金設定が見つかりません" }, 404);
        if (body.action === "wage_delete") {
          if (row.smaregi_wage_apply_id) {
            const dr = await api(C, token, `/staffs/${staffId}/wage_apply/${encodeURIComponent(String(row.smaregi_wage_apply_id))}`, { method: "DELETE" });
            if (!dr.ok && dr.status !== 404) return json({ ok: false, error: `スマレジの賃金設定を削除できません(${dr.status}): ${await errText(dr)}` }, 500);
          }
          const { error: de } = await sb.from("employee_wage_settings").delete().eq("id", id);
          if (de) return json({ ok: false, error: "管理システムの行を削除できません: " + de.message }, 500);
          return json({ ok: true, deleted: true });
        }
        // wage_update: 検証して行を更新（反映待ちへ）→ 下の wage_push と同じ処理でこの1行だけ反映
        const wage = body.wage === undefined ? row.wage : Number(body.wage);
        const holiday = body.holiday_wage === undefined ? row.holiday_wage : (body.holiday_wage === null || body.holiday_wage === "" ? null : Number(body.holiday_wage));
        const date = body.effective_date === undefined ? row.effective_date : String(body.effective_date).slice(0, 10);
        if (!Number.isInteger(wage) || wage <= 0 || wage > 100000000) return json({ ok: false, error: "金額が不正です" }, 400);
        if (row.division === 0 && wage > 100000) return json({ ok: false, error: `時給が大きすぎます（${wage}円）。月給は「月給」で入力してください` }, 400);
        if (holiday !== null && (!Number.isInteger(holiday) || holiday < 0)) return json({ ok: false, error: "休日賃金が不正です" }, 400);
        if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || date < "2000-01-01") return json({ ok: false, error: "適用開始日が不正です" }, 400);
        if (row.division === 2 && date.slice(8) !== "01") return json({ ok: false, error: "月給の適用開始日は月初日（1日）にしてください" }, 400);
        const { error: ue } = await sb.from("employee_wage_settings").update({ wage, holiday_wage: row.division === 0 ? holiday : null, effective_date: date, sync_status: "pending", sync_error: null, updated_at: new Date().toISOString() }).eq("id", id);
        if (ue) return json({ ok: false, error: /duplicate|unique/i.test(ue.message) ? "同じ条件（区分・店舗・適用開始日）の賃金設定が既にあります" : ue.message }, 400);
        body.id = id; // ↓で、この1行だけを反映
      }

      // ---- wage_push ----
      let rowsQ = sb.from("employee_wage_settings").select("*").eq("user_id", uid).eq("contract_id", C).in("sync_status", ["pending", "error"]);
      if (body.action === "wage_update" && body.id) rowsQ = rowsQ.eq("id", String(body.id));
      const { data: rows } = await rowsQ.order("effective_date");
      if (!rows?.length) return json({ ok: true, contract_id: C, staffId, pushed: 0, failed: 0, results: [] });
      const results: any[] = [];
      let existing: any[] | null = null;
      const mark = async (id: string, patch: Record<string, unknown>) => { await sb.from("employee_wage_settings").update({ ...patch, updated_at: new Date().toISOString() }).eq("id", id); };
      for (const r of rows) {
        try {
          let applyId: string | null = r.smaregi_wage_apply_id ? String(r.smaregi_wage_apply_id) : null;
          const smStore = r.store_id ? (reverse[r.store_id] ?? null) : null;
          if (r.division === 0 && r.store_id && !smStore) throw new Error("この契約に対応するスマレジの事業所がありません（店舗の対応を確認してください）");
          const putBody: Record<string, unknown> = r.division === 2
            ? { division: 2, effectiveDate: r.effective_date, wage: r.wage }
            : { division: 0, effectiveDate: r.effective_date, wage: r.wage, ...(smStore ? { storeId: smStore } : {}), ...(r.holiday_wage !== null && r.holiday_wage !== undefined ? { holidayWage: r.holiday_wage } : {}) };
          const put = async (id: string) => {
            const rr = await api(C, token, `/staffs/${staffId}/wage_apply/${encodeURIComponent(id)}`, { method: "PUT", body: JSON.stringify(putBody) });
            if (!rr.ok) throw new Error(`賃金設定の更新に失敗(${rr.status}): ${await errText(rr)}`);
          };
          if (applyId) {
            await put(applyId);
          } else {
            const postBody = r.division === 2
              ? { division: 2, effectiveDate: r.effective_date, wage: r.wage }
              : smStore
                ? { division: 0, effectiveDate: r.effective_date, settings: [{ storeId: smStore, wage: r.wage, ...(r.holiday_wage !== null && r.holiday_wage !== undefined ? { holidayWage: r.holiday_wage } : {}) }] }
                : { division: 0, effectiveDate: r.effective_date, wage: r.wage };
            const rr = await api(C, token, `/staffs/${staffId}/wage_apply`, { method: "POST", body: JSON.stringify(postBody) });
            if (rr.status === 201) {
              const j = await rr.json().catch(() => ({}));
              applyId = String((j.wageApplyIds ?? [])[0] ?? "") || null;
              // 事業所未指定の時給は、登録時に休日賃金を送れないため、休日賃金があれば作成直後に更新で入れる
              if (applyId && r.division === 0 && !smStore && r.holiday_wage !== null && r.holiday_wage !== undefined) await put(applyId);
            } else if (rr.status === 400) { // 同じ適用開始日の設定が既にある等: 既存を探して更新
              if (!existing) existing = await fetchWageApply();
              const hit = existing.find((w) => w.division === r.division && (w.storeId ?? null) === (smStore ?? null) && w.effectiveDate === r.effective_date);
              if (!hit) throw new Error(`賃金設定の登録に失敗(400): ${await errText(rr)}`);
              applyId = hit.id; await put(hit.id);
            } else throw new Error(`賃金設定の登録に失敗(${rr.status}): ${await errText(rr)}`);
          }
          await mark(r.id, { sync_status: "synced", sync_error: null, synced_at: new Date().toISOString(), smaregi_wage_apply_id: applyId });
          results.push({ id: r.id, ok: true, wageApplyId: applyId });
        } catch (e) {
          const msg = String((e as Error).message ?? e).slice(0, 300);
          await mark(r.id, { sync_status: "error", sync_error: msg });
          results.push({ id: r.id, ok: false, error: msg });
        }
      }
      const failed = results.filter((x) => !x.ok).length;
      return json({ ok: failed === 0, contract_id: C, staffId, pushed: results.length - failed, failed, results }, failed ? 500 : 200);
    }

    return json({ ok: false, error: "unknown action" }, 400);
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});