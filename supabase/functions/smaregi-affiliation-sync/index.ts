// 所属店舗（管理システム user_stores）と所属事業所（スマレジ・タイムカード）の双方向同期ジョブ
// （2026-10-17・担当D・設計メモ_スマレジ複数契約対応 §11-2 / §11-5）
//
// 契約ごと（smaregi_contracts の有効な契約すべて）に、スマレジの「事業所×所属スタッフ」を読み、
// 管理システム(M)・スマレジ(S)・前回同期した台帳(L = staff_store_sync) の3点で比べる。
//   M==S                       → 何もしない（台帳だけ最新化）
//   管理システム側だけ変更      → スマレジへ反映（PUT/DELETE /staffs/{id}/staff_stores/{store}）
//   スマレジ側だけ変更          → 管理システムの user_stores へ取り込み（Larkに通知）
//   両方変更（衝突）            → 止めずに同期。管理システムを優先してスマレジへ反映し、上書きしたスマレジ側の変更をログとLarkに残す
//   台帳が無い（初めて）        → 管理システム優先で反映。ただし管理システム側が0件ならスマレジの所属を取り込む（スマレジを空にしない）
//   安全弁: 反映先を空にする操作はしない／1回の変更人数が上限(既定40)を超えたら反映せず止める（force=trueで解除）
// 事業所の対応（スマレジの事業所→管理システムの店舗）が無いものは変更せず隔離（ログ+Lark）。除外リスト(smaregi_store_ignore)は無視。
//   - スマレジに新しい事業所が出た → 名前が管理システムの店舗(その契約の運営法人の店舗)と完全一致で1件だけなら store_external_mappings に自動登録。
//     一致しなければ隔離してLarkへ（人が「この店舗」or「新規店舗」を選ぶ）。自動登録できたとき、その店舗の「事業所を作成してください」タスクは自動完了にする。
//   - 管理システムに店舗が増えたのにスマレジに事業所が無い → 本部タスク「スマレジ・タイムカードに事業所『○○』を作成してください（契約: ○○）」を1回だけ自動発行。
//
// 呼び出し: POST { mode?: "report"|"apply"（既定report）, contract_id?: string, user_id?: string（その1人だけ。初回の立会い確認用）, allow_empty?: boolean（user_id指定時のみ。管理システムの所属が0件のとき、スマレジの所属も全部外す）, cutover_apply?: boolean（運営変更の後始末だけ実行する。mode=reportでも）, force?: boolean }
//   report=試行（スマレジにも user_stores にも書かない。同期ログとLarkだけ）／apply=実際に反映
// 認可: service_role直呼び、または CEO/HQ のJWT。
// 応答は件数のみ（公開リポジトリのActionsログに氏名・店舗名を残さない）。名前を含む詳細はLark(社内)と staff_store_sync_log にだけ出す。
import { createClient } from "npm:@supabase/supabase-js@2";
import { loadContracts, getContractToken, loadLinks, loadStoreMap, loadStoreMapPending, API_BASE, fetchRoles, pickRoleId, putStaffStore, wantedRoleName } from "../_shared/smaregi-contracts.ts";
import { larkPost } from "../_shared/cockpit.ts";

const SCOPES = "timecard.staffs:read timecard.staffs:write timecard.stores:read";
const MAX_CHANGED_USERS = 40;

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

const tcApi = (c: string, token: string, path: string, init: RequestInit = {}) =>
  fetch(`${API_BASE}/${c}/timecard${path}`, { ...init, headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", ...(init.headers ?? {}) } });

async function pagedGet(c: string, token: string, path: string, listKey: string): Promise<any[]> {
  const out: any[] = [];
  for (let page = 1; page <= 30; page++) {
    const sep = path.includes("?") ? "&" : "?";
    const r = await tcApi(c, token, `${path}${sep}limit=100&page=${page}`);
    const raw = await r.json().catch(() => null);
    if (!r.ok) throw new Error(`GET ${path} ${r.status}: ${JSON.stringify(raw).slice(0, 160)}`);
    const arr = Array.isArray(raw) ? raw : (raw?.[listKey] ?? []);
    out.push(...arr);
    const pageCount = Array.isArray(raw) ? (arr.length < 100 ? page : page + 1) : (raw?.pageCount ?? page);
    if (page >= Number(pageCount) || arr.length === 0) break;
  }
  return out;
}

const eq = (a: Set<string>, b: Set<string>) => a.size === b.size && [...a].every((x) => b.has(x));
const minus = (a: Set<string>, b: Set<string>) => [...a].filter((x) => !b.has(x));
const norm = (s: string) => String(s ?? "").replace(/[\s　]/g, "");

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const sb = svc();
    const body = await req.json().catch(() => ({}));
    const authHeader = req.headers.get("Authorization") ?? "";
    const isServiceRole = authHeader.includes(Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? " ");
    if (!isServiceRole) {
      const uid = jwtUid(req);
      const { data: u } = await sb.from("users").select("role,is_active,is_master").eq("id", uid).maybeSingle();
      if (!u?.is_active || !(u.is_master || ["CEO", "HQ"].includes(u.role))) return json({ ok: false, error: "権限がありません（CEO/HQのみ）" }, 403);
    }
    const mode: "report" | "apply" = body.mode === "apply" ? "apply" : "report";
    const apply = mode === "apply";
    const force = body.force === true;
    const runId = crypto.randomUUID();
    const today = new Date(Date.now() + 9 * 3600 * 1000).toISOString().slice(0, 10); // JSTの今日
    const contracts = await loadContracts(sb, body.contract_id ? String(body.contract_id) : undefined);

    const log = async (contract_id: string, user_id: string | null, kind: string, detail: Record<string, unknown>) => {
      await sb.from("staff_store_sync_log").insert({ run_id: runId, mode, contract_id, user_id, kind, detail });
    };

    // 店舗名・ユーザー名（Lark用。応答には出さない）
    const { data: allStores } = await sb.from("stores").select("id,name,sort_order,is_active");
    const storeName: Record<string, string> = {}; const storeSort: Record<string, number> = {};
    (allStores ?? []).forEach((s: any) => { storeName[s.id] = s.name; storeSort[s.id] = s.sort_order ?? 9999; });

    const larkLines: string[] = [];
    const summary: any[] = [];

    for (const c of contracts) {
      const label = c.label ?? c.contract_id.slice(-3);
      const cs: any = { contract: "…" + c.contract_id.slice(-3), users: 0, in_sync: 0, push: 0, import: 0, conflict_overwritten: 0, skipped: 0, errors: 0,
        unmapped_stores: 0, new_stores: 0, auto_mapped: 0, tasks_created: 0, tasks_done: 0, aborted: "" };
      try {
        const token = await getContractToken(c.contract_id, SCOPES);

        // ---- 1) スマレジの現状（事業所と、事業所ごとの所属スタッフ） ----
        const smStores = await pagedGet(c.contract_id, token, "/stores", "stores");
        const smStoreList = smStores.map((s: any) => ({ id: String(s.storeId), name: String(s.storeName ?? "") }));
        const staffStores = new Map<string, Set<string>>();   // smaregi_staff_id → 事業所ID
        const smTerminated = new Set<string>();               // スマレジ側で退職扱い(termination=1)のスタッフID（所属は一覧に出ないため同期しない）
        let fetchFailed = 0;
        for (const st of smStoreList) {
          try {
            // 注意: /staffs?store_id= は所属者が0人の事業所だと全員を返すことがあるため使わない。/staff_stores?store_id= で読む
            const rows = await pagedGet(c.contract_id, token, `/staff_stores?store_id=${encodeURIComponent(st.id)}`, "staffStores");
            for (const s of rows) {
              const k = String(s.staffId);
              if (String(s.staff?.terminationFlag ?? "0") === "1") { smTerminated.add(k); continue; }
              if (!staffStores.has(k)) staffStores.set(k, new Set());
              staffStores.get(k)!.add(st.id);
            }
          } catch (_) { fetchFailed++; }
        }
        if (fetchFailed) { cs.aborted = `事業所${fetchFailed}件の所属取得に失敗`; cs.errors++; await log(c.contract_id, null, "error", { reason: cs.aborted }); summary.push(cs); larkLines.push(`⚠️ ${label}: ${cs.aborted}のため今日の同期を見送りました`); continue; }

        // ---- 2) 事業所の検知（新規・対応なし） ----
        const { data: ign } = await sb.from("smaregi_store_ignore").select("store_id").eq("contract_id", c.contract_id);
        const ignored = new Set((ign ?? []).map((r: any) => String(r.store_id)));
        const { data: prevSnap } = await sb.from("smaregi_stores_snapshot").select("store_id").eq("contract_id", c.contract_id);
        const prevIds = new Set((prevSnap ?? []).map((r: any) => String(r.store_id)));

        let storeMap = body.pending === true ? await loadStoreMapPending(sb, c) : await loadStoreMap(sb, c, today);   // 事業所ID → 店舗UUID（pending=trueは運営変更前の先行テスト用）
        const unmappedSm = smStoreList.filter((s) => !ignored.has(s.id) && !storeMap[s.id]);

        // 新規の事業所で、名前が一致する店舗(その契約の運営法人の店舗)が1件だけなら自動で対応づける
        if (unmappedSm.length && c.corporation_id) {
          const { data: ops } = await sb.from("v_store_current_relations").select("store_id,store_name,operator_entity_type,operator_entity_id,store_is_active")
            .eq("operator_entity_type", "corporation").eq("operator_entity_id", c.corporation_id).eq("store_is_active", true);
          const mappedStoreIds = new Set(Object.values(storeMap));
          for (const sm of [...unmappedSm]) {
            const hits = (ops ?? []).filter((o: any) => norm(o.store_name) === norm(sm.name) && !mappedStoreIds.has(o.store_id));
            if (hits.length !== 1) continue;
            if (apply) {
              const { error } = await sb.from("store_external_mappings").insert({
                store_id: hits[0].store_id, source_system: "smaregi_timecard", external_store_id: sm.id, external_store_name: sm.name,
                corporation_hint: c.corporation_hint, effective_from: today, is_active: true, note: "smaregi-affiliation-sync 自動登録(名前一致)",
              });
              if (error) { cs.errors++; await log(c.contract_id, null, "error", { reason: "自動対応づけ失敗: " + error.message, smaregi_store: sm.id }); continue; }
              storeMap[sm.id] = hits[0].store_id; mappedStoreIds.add(hits[0].store_id);
              unmappedSm.splice(unmappedSm.findIndex((x) => x.id === sm.id), 1);
              // 「事業所を作成してください」タスクがあれば自動完了
              const { data: tl } = await sb.from("smaregi_store_task_links").select("task_id").eq("store_id", hits[0].store_id).eq("contract_id", c.contract_id).maybeSingle();
              if (tl?.task_id) {
                await sb.from("hq_tasks").update({ status: "done", completed_at: new Date().toISOString() }).eq("id", tl.task_id).neq("status", "done");
                cs.tasks_done++; await log(c.contract_id, null, "task_done", { store: hits[0].store_name });
              }
            }
            cs.auto_mapped++;
            await log(c.contract_id, null, "auto_mapped", { smaregi_store: sm.id, smaregi_store_name: sm.name, store: hits[0].store_name, applied: apply });
            larkLines.push(`${apply ? "✅" : "（試行）"} ${label}: スマレジの事業所「${sm.name}」(ID ${sm.id}) を管理システムの店舗「${hits[0].store_name}」に自動で対応づけました`);
          }
        }
        cs.unmapped_stores = unmappedSm.length;
        for (const sm of unmappedSm) {
          await log(c.contract_id, null, "unmapped_store", { smaregi_store: sm.id, smaregi_store_name: sm.name, is_new: prevIds.size > 0 && !prevIds.has(sm.id) });
        }
        const newOnes = smStoreList.filter((s) => prevIds.size > 0 && !prevIds.has(s.id) && !ignored.has(s.id));
        cs.new_stores = newOnes.length;
        for (const sm of newOnes) {
          if (storeMap[sm.id]) continue; // 自動で対応づけた分は上で通知済み
          larkLines.push(`🆕 ${label}: スマレジに新しい事業所「${sm.name}」(ID ${sm.id}) ができましたが、管理システムの店舗と対応がありません。店舗を選ぶか新規店舗として作成してください（それまでこの事業所の所属は同期しません）`);
        }

        // ---- 3.0) 運営変更の後始末（11/1以降に動く。店舗の対応の期間が終わった後だけ働く）----
        //   X1: 対応の期間が終わった事業所（例: トーホーの黒霧屋＝10/31まで）に、まだ所属している「有効な契約リンクの人」（兼務で残る人）の所属を外す
        //   X2: 契約リンクが終わった（effective_to＜今日）のに、スマレジ側でまだ打刻ONのスタッフ（移籍した人のトーホー側）の打刻をOFFにする
        //   どちらも「直近31日以内に終わったもの」だけが対象。管理システムのアカウント(users)・所属店舗(user_stores)は触らない
        //   実行は mode=apply または cutover_apply=true のときだけ（それ以外は試行＝ログとLarkのみ）
        {
          const cutApply = apply || body.cutover_apply === true;
          const since = new Date(Date.now() + 9 * 3600 * 1000 - 31 * 86400000).toISOString().slice(0, 10);
          const { data: mps } = await sb.from("store_external_mappings").select("external_store_id,store_id,corporation_hint,effective_to,is_active")
            .eq("source_system", "smaregi_timecard").lt("effective_to", today).gte("effective_to", since);
          const expiredSm = new Set<string>((mps ?? []).filter((m: any) => m.is_active !== false && (m.corporation_hint ? m.corporation_hint === c.corporation_hint : c.is_default)).map((m: any) => String(m.external_store_id)));
          const activeLinks = await loadLinks(sb, c.contract_id, today, today);
          const activeStaff = new Map<string, string>(); activeLinks.forEach((l: any) => activeStaff.set(String(l.smaregi_staff_id), l.user_id));
          const { data: nmU } = activeLinks.length ? await sb.from("users").select("id,name").in("id", activeLinks.map((l: any) => l.user_id)) : { data: [] as any[] };
          const nmX: Record<string, string> = {}; (nmU ?? []).forEach((r: any) => { nmX[r.id] = r.name; });
          for (const sid of expiredSm) {
            const sname = smStoreList.find((x) => x.id === sid)?.name ?? sid;
            for (const [staffId, set] of staffStores) {
              if (!set.has(sid) || !activeStaff.has(staffId)) continue;
              const uid = activeStaff.get(staffId)!;
              try {
                if (cutApply) {
                  const r = await tcApi(c.contract_id, token, `/staffs/${staffId}/staff_stores/${encodeURIComponent(sid)}`, { method: "DELETE" });
                  if (!r.ok) throw new Error(`所属解除に失敗(${r.status}): ${(await r.text()).slice(0, 120)}`);
                  set.delete(sid);
                }
                cs.retired_memberships = (cs.retired_memberships ?? 0) + 1;
                await log(c.contract_id, uid, "push", { removed: [sname], reason: "運営変更: 店舗の対応期間が終了", applied: cutApply });
                larkLines.push(`${cutApply ? "🔚" : "（試行）"} ${label}: ${nmX[uid] ?? uid}さんの「${sname}」の所属をスマレジから外しました（この契約での運営が終わったため）`);
              } catch (e) {
                cs.errors++; await log(c.contract_id, uid, "error", { reason: String((e as Error).message ?? e).slice(0, 200) });
              }
            }
          }
          const { data: closed } = await sb.from("employee_smaregi_links").select("user_id,smaregi_staff_id,effective_to,users(name,is_active)")
            .eq("contract_id", c.contract_id).lt("effective_to", today).gte("effective_to", since);
          for (const l of closed ?? []) {
            if ((l as any).users?.is_active === false) continue; // 退職（アカウント停止）の人は毎朝の退職処理が担当
            const stf = String((l as any).smaregi_staff_id);
            try {
              const gr = await tcApi(c.contract_id, token, `/staffs/${stf}`);
              const gj = await gr.json().catch(() => null);
              if (!gr.ok) throw new Error(`従業員を取得できません(${gr.status})`);
              if (String(gj?.activeFlag ?? "0") !== "1") continue; // 既に打刻OFF
              if (cutApply) {
                const ar = await tcApi(c.contract_id, token, `/staffs/${stf}/active`, { method: "PUT", body: JSON.stringify({ activeFlag: false }) });
                if (!ar.ok) throw new Error(`打刻OFFに失敗(${ar.status})`);
              }
              cs.deactivated = (cs.deactivated ?? 0) + 1;
              await log(c.contract_id, (l as any).user_id, "push", { removed: [], reason: "契約終了日を過ぎたため打刻をOFF（移籍）", applied: cutApply });
              larkLines.push(`${cutApply ? "⏹" : "（試行）"} ${label}: ${(l as any).users?.name ?? ""}さんのこの契約での打刻をOFFにしました（契約終了日 ${String((l as any).effective_to).slice(0, 10)}）`);
            } catch (e) {
              cs.errors++; await log(c.contract_id, (l as any).user_id, "error", { reason: String((e as Error).message ?? e).slice(0, 200) });
            }
          }
        }

        // ---- 3) 人ごとの3点比較 ----
        const reverse: Record<string, string> = {};   // 店舗UUID → 事業所ID
        for (const [smId, stId] of Object.entries(storeMap)) if (!reverse[stId]) reverse[stId] = smId;
        const contractStoreIds = new Set(Object.keys(reverse));

        const onlyUser = body.user_id ? String(body.user_id) : "";
        const links = (await loadLinks(sb, c.contract_id, today, today)).filter((l: any) => !onlyUser || l.user_id === onlyUser);
        const userIds = links.map((l: any) => l.user_id);
        const { data: usAll } = userIds.length ? await sb.from("user_stores").select("user_id,store_id,is_primary").in("user_id", userIds) : { data: [] as any[] };
        const { data: ledgerAll } = userIds.length ? await sb.from("staff_store_sync").select("user_id,store_id,smaregi_staff_id").eq("contract_id", c.contract_id).in("user_id", userIds) : { data: [] as any[] };
        const { data: userNames } = userIds.length ? await sb.from("users").select("id,name,role").in("id", userIds) : { data: [] as any[] };
        // 退職日を過ぎた人・無効化されたユーザーは同期の対象外（スマレジ側も退職扱いで所属が無く、店舗を足しても意味がないため）
        const { data: profs } = userIds.length ? await sb.from("employee_profiles").select("user_id,termination_date").in("user_id", userIds) : { data: [] as any[] };
        const terminated = new Set((profs ?? []).filter((r: any) => r.termination_date && r.termination_date < today).map((r: any) => r.user_id));
        const uname: Record<string, string> = {}; const urole: Record<string, string> = {};
        (userNames ?? []).forEach((r: any) => { uname[r.id] = r.name; urole[r.id] = r.role; });

        type Plan = { userId: string; staffId: string; M: Set<string>; S: Set<string>; L: Set<string> | null; kind: "push" | "import" | "conflict" | "skip" | "none"; reason?: string };
        const plans: Plan[] = [];
        for (const lk of links) {
          const userId = lk.user_id as string;
          if (smTerminated.has(String(lk.smaregi_staff_id))) { cs.smaregi_terminated = (cs.smaregi_terminated ?? 0) + 1; continue; }
          if (terminated.has(userId) || lk.users?.is_active === false) { cs.terminated = (cs.terminated ?? 0) + 1; continue; }
          cs.users++; const staffId = String(lk.smaregi_staff_id);
          const M = new Set<string>((usAll ?? []).filter((r: any) => r.user_id === userId && contractStoreIds.has(r.store_id)).map((r: any) => r.store_id));
          const smNow = staffStores.get(staffId) ?? new Set<string>();
          const S = new Set<string>(); [...smNow].forEach((sid) => { if (!ignored.has(sid) && storeMap[sid]) S.add(storeMap[sid]); });
          const led = (ledgerAll ?? []).filter((r: any) => r.user_id === userId);
          const ledgerValid = led.length > 0 && led.every((r: any) => String(r.smaregi_staff_id ?? "") === staffId);
          const L = ledgerValid ? new Set<string>(led.map((r: any) => r.store_id).filter((x: string) => contractStoreIds.has(x))) : null;

          if (eq(M, S)) { plans.push({ userId, staffId, M, S, L, kind: "none" }); continue; }
          if (L === null) {
            if (M.size === 0) plans.push({ userId, staffId, M, S, L, kind: "import", reason: "初回・管理システム側に所属なし" });
            else plans.push({ userId, staffId, M, S, L, kind: "push", reason: "初回・管理システム優先" });
            continue;
          }
          const mCh = !eq(M, L), sCh = !eq(S, L);
          if (mCh && !sCh) plans.push({ userId, staffId, M, S, L, kind: M.size === 0 && !(onlyUser && body.allow_empty === true) ? "skip" : "push", reason: M.size === 0 ? (onlyUser && body.allow_empty === true ? "管理システム側の所属が0件（ユーザー許可・この1人のみ）" : "管理システム側が0件のためスマレジを空にしない") : undefined });
          else if (!mCh && sCh) plans.push({ userId, staffId, M, S, L, kind: S.size === 0 ? "skip" : "import", reason: S.size === 0 ? "スマレジ側が0件のため管理システムを空にしない" : undefined });
          else plans.push({ userId, staffId, M, S, L, kind: M.size === 0 ? "skip" : "conflict", reason: M.size === 0 ? "管理システム側が0件のためスマレジを空にしない" : undefined });
        }

        const changed = plans.filter((p) => p.kind !== "none" && p.kind !== "skip");
        if (apply && changed.length > MAX_CHANGED_USERS && !force) {
          cs.aborted = `変更が${changed.length}人と多いため反映を見送りました（上限${MAX_CHANGED_USERS}人。確認後 force=true で実行）`;
          await log(c.contract_id, null, "error", { reason: cs.aborted });
          larkLines.push(`⚠️ ${label}: ${cs.aborted}`);
          summary.push(cs); continue;
        }

        const fixed = new Set<string>();   // この実行で反映に成功した人（ズレ一覧から外す）
        const nm = (ids: string[]) => ids.map((i) => storeName[i] ?? i).join("、") || "なし";
        for (const p of plans) {
          if (p.kind === "none") { cs.in_sync++; continue; }
          const who = uname[p.userId] ?? p.userId;
          if (p.kind === "skip") {
            cs.skipped++; await log(c.contract_id, p.userId, "skip", { reason: p.reason });
            larkLines.push(`⏸ ${label}: ${who}さんの所属が管理システムとスマレジで違いますが、${p.reason}ため何もしませんでした`);
            continue;
          }
          const toSm = p.kind === "push" || p.kind === "conflict";
          let ok = true;
          try {
            if (toSm) {
              // 管理システム → スマレジ
              const adds = minus(p.M, p.S), dels = minus(p.S, p.M);
              const putLog: any[] = [];
              if (apply) {
                // 追加には役割ID(roleId)が必須（AL=アルバイト／それ以外=社員。追加先の事業所ごとに引く）
                const roles = adds.length ? await fetchRoles(c.contract_id, token, adds.map((st) => reverse[st])) : [];
                const want = wantedRoleName(urole[p.userId]);
                for (const st of adds) {
                  const roleId = pickRoleId(roles, reverse[st], want);
                  if (!roleId) throw new Error(`スマレジの事業所${reverse[st]}に役割「${want}」が見つかりません`);
                  const r = await putStaffStore(c.contract_id, token, p.staffId, reverse[st], roleId);
                  putLog.push({ store: storeName[st], status: r.status, role: roleId, res: r.text.slice(0, 200) });
                  if (!r.ok) throw new Error(`スマレジへの所属追加に失敗(${r.status}): ${r.text}`);
                }
                for (const st of dels) {
                  const r = await tcApi(c.contract_id, token, `/staffs/${p.staffId}/staff_stores/${encodeURIComponent(reverse[st])}`, { method: "DELETE" });
                  if (!r.ok) throw new Error(`スマレジからの所属解除に失敗(${r.status}): ${(await r.text()).slice(0, 120)}`);
                }
              }
              cs.push++;
              await log(c.contract_id, p.userId, "push", { added: adds.map((i) => storeName[i]), removed: dels.map((i) => storeName[i]), reason: p.reason ?? null, applied: apply, puts: putLog });
              if (p.kind === "conflict" && p.L) {
                // スマレジ側で変えられていた内容（前回→今）を、上書きする前に残す
                const smAdded = minus(p.S, p.L), smRemoved = minus(p.L, p.S);
                cs.conflict_overwritten++;
                await log(c.contract_id, p.userId, "conflict_overwrite", { smaregi_side_added: smAdded.map((i) => storeName[i]), smaregi_side_removed: smRemoved.map((i) => storeName[i]), applied: apply });
                larkLines.push(`${apply ? "🔁" : "（試行）"} ${label}: ${who}さんの所属が管理システムとスマレジの両方で変更されていたため、管理システムの内容（${nm([...p.M])}）でスマレジを上書きしました。上書きされたスマレジ側の変更: 追加=${nm(smAdded)} ／ 解除=${nm(smRemoved)}`);
              } else if (adds.length || dels.length) {
                larkLines.push(`${apply ? "➡️" : "（試行）"} ${label}: ${who}さんの所属をスマレジへ反映: 追加=${nm(adds)} ／ 解除=${nm(dels)}`);
              }
            } else {
              // スマレジ → 管理システム
              const adds = minus(p.S, p.M), dels = minus(p.M, p.S);
              if (apply) {
                for (const st of adds) {
                  const { error } = await sb.from("user_stores").insert({ user_id: p.userId, store_id: st, is_primary: false });
                  if (error) throw new Error("管理システムへの所属追加に失敗: " + error.message);
                }
                for (const st of dels) {
                  const { error } = await sb.from("user_stores").delete().eq("user_id", p.userId).eq("store_id", st);
                  if (error) throw new Error("管理システムの所属解除に失敗: " + error.message);
                }
                // 主たる店舗が無くなったら、残りの中で並び順が先の店舗を主にする
                const { data: now } = await sb.from("user_stores").select("store_id,is_primary").eq("user_id", p.userId);
                if ((now ?? []).length && !(now ?? []).some((r: any) => r.is_primary)) {
                  const first = [...(now ?? [])].sort((a: any, b: any) => (storeSort[a.store_id] ?? 9999) - (storeSort[b.store_id] ?? 9999))[0];
                  await sb.from("user_stores").update({ is_primary: true }).eq("user_id", p.userId).eq("store_id", first.store_id);
                }
              }
              cs.import++;
              await log(c.contract_id, p.userId, "import", { added: adds.map((i) => storeName[i]), removed: dels.map((i) => storeName[i]), reason: p.reason ?? null, applied: apply });
              larkLines.push(`${apply ? "⬅️" : "（試行）"} ${label}: スマレジ側で${who}さんの所属が変更されたため管理システムに取り込みました: 追加=${nm(adds)} ／ 解除=${nm(dels)}`);
            }
          } catch (e) {
            ok = false; cs.errors++;
            await log(c.contract_id, p.userId, "error", { reason: String((e as Error).message ?? e).slice(0, 200) });
            larkLines.push(`❌ ${label}: ${who}さんの所属同期に失敗: ${String((e as Error).message ?? e).slice(0, 100)}`);
          }
          if (ok && apply) fixed.add(p.userId);
          // 台帳(前回同期時点)を「一致した状態」に更新
          if (ok && apply) {
            const finalSet = toSm ? p.M : p.S;
            await sb.from("staff_store_sync").delete().eq("user_id", p.userId).eq("contract_id", c.contract_id);
            if (finalSet.size) {
              await sb.from("staff_store_sync").insert([...finalSet].map((st) => ({
                user_id: p.userId, contract_id: c.contract_id, store_id: st, smaregi_staff_id: p.staffId, smaregi_store_id: reverse[st] ?? null, last_synced_at: new Date().toISOString(),
              })));
            }
          }
        }
        // 一致していた人も、台帳が無い／台帳がずれている場合は「今の一致状態」に更新する
        // （ずれたままだと、次回の3点比較で片側の変更を取り違えるため）
        if (apply) {
          for (const p of plans) {
            if (p.kind !== "none") continue;
            if (p.L !== null && eq(p.L, p.M)) continue;
            if (p.L === null && p.M.size === 0) continue;
            await sb.from("staff_store_sync").delete().eq("user_id", p.userId).eq("contract_id", c.contract_id);
            if (p.M.size) {
              await sb.from("staff_store_sync").insert([...p.M].map((st) => ({
                user_id: p.userId, contract_id: c.contract_id, store_id: st, smaregi_staff_id: p.staffId, smaregi_store_id: reverse[st] ?? null, last_synced_at: new Date().toISOString(),
              })));
            }
          }
        }

        // ---- 3.5) 「所属のズレ」の現在の一覧を作り直す（画面の未読バッジ用。試行モードでも更新）----
        {
          const nowIso = new Date().toISOString();
          const rows = plans.filter((p) => p.kind !== "none" && !fixed.has(p.userId)).map((p) => ({
            user_id: p.userId, contract_id: c.contract_id,
            only_portal: minus(p.M, p.S).map((i) => storeName[i] ?? i), only_smaregi: minus(p.S, p.M).map((i) => storeName[i] ?? i),
            reason: p.reason ?? null, updated_at: nowIso,
          }));
          const { data: old } = await sb.from("staff_store_mismatch").select("user_id,detected_at").eq("contract_id", c.contract_id);
          const since: Record<string, string> = {}; (old ?? []).forEach((r: any) => { since[r.user_id] = r.detected_at; });
          let del = sb.from("staff_store_mismatch").delete().eq("contract_id", c.contract_id);
          if (onlyUser) del = del.eq("user_id", onlyUser);
          await del;
          if (rows.length) await sb.from("staff_store_mismatch").insert(rows.map((r) => ({ ...r, detected_at: since[r.user_id] ?? nowIso })));
        }

        // ---- 4) スナップショットを最新化（次回の新規事業所検知・棚卸し用） ----
        {
          const fetchedAt = new Date().toISOString(); const rid = crypto.randomUUID();
          await sb.from("smaregi_stores_snapshot").delete().eq("contract_id", c.contract_id);
          await sb.from("smaregi_staff_stores_snapshot").delete().eq("contract_id", c.contract_id);
          if (smStoreList.length) await sb.from("smaregi_stores_snapshot").insert(smStoreList.map((s) => ({ contract_id: c.contract_id, store_id: s.id, store_name: s.name, run_id: rid, fetched_at: fetchedAt })));
          const rows: any[] = [];
          for (const [staffId, set] of staffStores) for (const sid of set) rows.push({ contract_id: c.contract_id, smaregi_staff_id: staffId, smaregi_store_id: sid, run_id: rid, fetched_at: fetchedAt });
          for (let i = 0; i < rows.length; i += 500) await sb.from("smaregi_staff_stores_snapshot").insert(rows.slice(i, i + 500));
        }

        // ---- 5) 管理システムに店舗が増えたのにスマレジに事業所が無い → 本部タスクを1回だけ発行 ----
        if (c.corporation_id) {
          const { data: corp } = await sb.from("corporations").select("name").eq("id", c.corporation_id).maybeSingle();
          const corpName = corp?.name as string | undefined;
          if (corpName && ["LiveGate", "SK", "N-Style", "トーホー"].includes(corpName)) {
            const { data: ops } = await sb.from("v_store_current_relations").select("store_id,store_name,operator_entity_type,operator_entity_id,store_is_active")
              .eq("operator_entity_type", "corporation").eq("operator_entity_id", c.corporation_id).eq("store_is_active", true);
            const mappedSet = new Set(Object.values(storeMap));
            // 将来日から始まる対応(effective_from > 今日)がある店舗は、これから対応する予定なのでタスクにしない
            const { data: futureMaps } = await sb.from("store_external_mappings").select("store_id").eq("source_system", "smaregi_timecard").eq("is_active", true).gt("effective_from", today);
            const future = new Set((futureMaps ?? []).map((r: any) => r.store_id));
            for (const o of ops ?? []) {
              if (mappedSet.has(o.store_id) || future.has(o.store_id)) continue;
              const { data: exist } = await sb.from("smaregi_store_task_links").select("task_id").eq("store_id", o.store_id).eq("contract_id", c.contract_id).maybeSingle();
              if (exist) continue;
              if (!apply) { cs.tasks_created++; larkLines.push(`（試行）${label}: 店舗「${o.store_name}」に対応するスマレジの事業所が無いため、本部タスクを作成する予定です`); continue; }
              const title = `スマレジ・タイムカードに事業所『${o.store_name}』を作成してください（契約: ${corpName}）`;
              const { data: t, error: terr } = await sb.from("hq_tasks").insert({
                title, corp: corpName, freq: "once", target_date: today, due_date: today, status: "todo", visibility: "all",
                description: "管理システムに店舗が追加されましたが、この契約のスマレジ・タイムカードに同名の事業所がありません。スマレジの画面で事業所を作成してください（管理システムからは作成できません）。作成後は毎日の同期が自動で検知して店舗と結びつけ、このタスクを完了にします。",
              }).select("id").single();
              if (terr || !t) { cs.errors++; await log(c.contract_id, null, "error", { reason: "本部タスク作成失敗: " + (terr?.message ?? "") }); continue; }
              await sb.from("smaregi_store_task_links").insert({ store_id: o.store_id, contract_id: c.contract_id, task_id: t.id });
              cs.tasks_created++; await log(c.contract_id, null, "task_created", { store: o.store_name, title });
              larkLines.push(`📝 ${label}: 店舗「${o.store_name}」に対応するスマレジの事業所が無いため、本部タスク「${title}」を作成しました`);
            }
          }
        }
      } catch (e) {
        cs.errors++; cs.aborted = String((e as Error).message ?? e).slice(0, 160);
        await log(c.contract_id, null, "error", { reason: cs.aborted });
        larkLines.push(`❌ ${c.label ?? c.contract_id.slice(-3)}: 所属同期でエラー: ${cs.aborted}`);
      }
      summary.push(cs);
    }

    const importantLines = larkLines;
    if (importantLines.length) {
      const head = `【スマレジ所属同期${apply ? "" : "（試行・書き込みなし）"}】${today}`;
      const text = head + "\n" + importantLines.slice(0, 40).join("\n") + (importantLines.length > 40 ? `\n…ほか${importantLines.length - 40}件（staff_store_sync_log参照）` : "");
      await larkPost(sb, text);
    }
    const errors = summary.reduce((a, s) => a + s.errors, 0);
    return json({ ok: errors === 0, mode, run_id: runId, contracts: summary, notices: larkLines.length });
  } catch (e) {
    return json({ ok: false, error: String((e as Error).message ?? e) }, 500);
  }
});
