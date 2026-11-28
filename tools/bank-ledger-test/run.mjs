// 銀行入金の正本（段階1）の検証。本番には接続しない（メモリ上の PGlite）。使い方: npm install && npm test
import { PGlite } from '@electric-sql/pglite';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const STAGE1 = readFileSync(process.env.STAGE1_FILE || join(here, '../../supabase/2026-11-27_bank_ledger_stage1.sql'), 'utf8');   // STAGE1_FILE は「わざと壊した版でテストが落ちるか」の確認用
const ROLLBACK = readFileSync(process.env.ROLLBACK_FILE || join(here, '../../supabase/2026-11-27_bank_ledger_stage1_ROLLBACK.sql'), 'utf8');

// ---------- 土台（Supabase 相当）。既存の表は、本番と同じ列・同じ関数の形だけ ----------
const BASE = `
create role anon nologin; create role authenticated nologin; create role service_role nologin bypassrls;
create schema auth;
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
create function auth.role() returns text language sql stable as $$ select nullif(current_setting('request.jwt.claim.role', true), '') $$;
grant usage on schema auth to anon, authenticated, service_role;
create schema storage;
create table storage.buckets (id text primary key, name text not null, public boolean default false, file_size_limit bigint, allowed_mime_types text[]);
create table storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text references storage.buckets(id), name text, owner uuid, metadata jsonb, created_at timestamptz default now());
alter table storage.objects enable row level security;
-- 本物の Supabase は、storage の表への直接の delete を禁止している（実環境の事前検証で判明）。同じ守りを再現する
create function storage.protect_delete() returns trigger language plpgsql as $f$ begin
  if coalesce(current_setting('storage.allow_delete_query', true), '') <> 'true' then raise exception 'Direct deletion from storage tables is not allowed. Use the Storage API instead.'; end if;
  return old; end $f$;
create trigger protect_buckets_delete before delete on storage.buckets for each row execute function storage.protect_delete();
create trigger protect_objects_delete before delete on storage.objects for each row execute function storage.protect_delete();
grant usage on schema storage to anon, authenticated, service_role;
grant select, insert, update, delete on storage.objects to anon, authenticated, service_role;
grant select on storage.buckets to anon, authenticated, service_role;
grant usage on schema public to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
create table public.corporations (id uuid primary key default gen_random_uuid(), name text);
create table public.stores (id uuid primary key default gen_random_uuid(), name text, corporation_id uuid references public.corporations(id));
create table public.users (id uuid primary key, name text, role text, is_master boolean not null default false, is_active boolean not null default true, team_id uuid);
create table public.user_stores (user_id uuid, store_id uuid, is_primary boolean default false);
create table public.team_stores (team_id uuid, store_id uuid);
create function public.team_store_ids(p_team uuid) returns uuid[] language sql stable security definer set search_path to 'public' as $$ select coalesce(array_agg(store_id), '{}') from team_stores where team_id = p_team $$;
create function public.user_store_ids(p_user uuid) returns uuid[] language sql stable security definer set search_path to 'public' as $$ select coalesce(array_agg(store_id), '{}') from user_stores where user_id = p_user $$;
-- 既存の別バケットと、その既存ポリシー（段階1が触らないことの確認用）
insert into storage.buckets (id, name, public, file_size_limit) values ('payroll-transfer-evidence', 'payroll-transfer-evidence', false, 20971520);
create policy payroll_evidence_read on storage.objects for select using (bucket_id = 'payroll-transfer-evidence');
`;

const U = (n) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const ID = { corp1: U(1), corp2: U(2), storeA1: U(11), storeA2: U(12), storeB1: U(13),
  ceo: U(101), hq: U(102), master: U(103), team: U(104), tenchoA: U(105), tenchoB: U(106), shain: U(107), al: U(108), hqOff: U(109),
  team1: U(201), acctA1: U(301), acctB1: U(302), acctNone: U(303) };
const P = {  // 人物: Postgres のロール＋ログイン中のユーザー
  anon: { role: 'anon', id: '' }, service: { role: 'service_role', id: '' },
  ceo: { role: 'authenticated', id: ID.ceo }, hq: { role: 'authenticated', id: ID.hq }, master: { role: 'authenticated', id: ID.master },
  team: { role: 'authenticated', id: ID.team }, tenchoA: { role: 'authenticated', id: ID.tenchoA }, tenchoB: { role: 'authenticated', id: ID.tenchoB },
  shain: { role: 'authenticated', id: ID.shain }, al: { role: 'authenticated', id: ID.al }, hqOff: { role: 'authenticated', id: ID.hqOff },
};
const ADMINS = ['ceo', 'hq', 'master'];
const NON_ADMIN_LOGGED_IN = ['team', 'tenchoA', 'tenchoB', 'shain', 'al', 'hqOff'];

const SEED_USERS = `
insert into public.corporations (id, name) values ('${ID.corp1}', '法人1'), ('${ID.corp2}', '法人2');
insert into public.stores (id, name, corporation_id) values ('${ID.storeA1}', 'A1店', '${ID.corp1}'), ('${ID.storeA2}', 'A2店', '${ID.corp1}'), ('${ID.storeB1}', 'B1店', '${ID.corp2}');
insert into public.users (id, name, role, is_master, is_active, team_id) values
 ('${ID.ceo}', '社長', 'CEO', false, true, null), ('${ID.hq}', '本部', 'HQ', false, true, null),
 ('${ID.master}', 'マスター', 'SHAIN', true, true, null), ('${ID.team}', 'チーム長', 'TEAM', false, true, '${ID.team1}'),
 ('${ID.tenchoA}', '店長A', 'TENCHO', false, true, null), ('${ID.tenchoB}', '店長B', 'TENCHO', false, true, null),
 ('${ID.shain}', '社員', 'SHAIN', false, true, null), ('${ID.al}', 'アルバイト', 'AL', false, true, null), ('${ID.hqOff}', '退職した本部', 'HQ', false, false, null);
-- チーム長: チームの店舗 A1 ＋ 本人の所属店舗 A2（B1 は担当外）
insert into public.team_stores values ('${ID.team1}', '${ID.storeA1}');
insert into public.user_stores values ('${ID.team}', '${ID.storeA2}', true), ('${ID.tenchoA}', '${ID.storeA1}', true), ('${ID.tenchoB}', '${ID.storeB1}', true), ('${ID.shain}', '${ID.storeA1}', true), ('${ID.al}', '${ID.storeA1}', true), ('${ID.hqOff}', '${ID.storeA1}', true);
`;

const SEED_LEDGER = `
insert into public.bank_accounts (id, bank_code, login_group, account_no, corporation_id, store_id, store_status) values
 ('${ID.acctA1}', 'paypay', 'paypayA', 'TESTACCT-A1', '${ID.corp1}', '${ID.storeA1}', 'assigned'),
 ('${ID.acctB1}', 'gmo_aozora', 'gmo_corp', 'TESTACCT-B1', '${ID.corp2}', '${ID.storeB1}', 'assigned'),
 ('${ID.acctNone}', 'gmo_aozora', 'gmo_corp', 'TESTACCT-NONE', '${ID.corp2}', null, 'unassigned');
insert into public.bank_csv_originals (id, bank_account_id, file_sha256, size_bytes, storage_path) values
 ('${U(401)}', '${ID.acctA1}', repeat('a', 64), 100, 'paypay/${ID.acctA1}/' || repeat('a', 64) || '.csv');
insert into public.bank_import_files (id, bank_account_id, source, original_id, status) values
 ('${U(501)}', '${ID.acctA1}', 'playwright', '${U(401)}', 'stored'),
 ('${U(502)}', '${ID.acctA1}', 'playwright', '${U(401)}', 'stored');   -- 同じ原本を 2 つの取得履歴が指す
insert into public.bank_account_sync_state (bank_account_id, status) values ('${ID.acctA1}', 'ok');
-- 明細（11/01 は A1 店: 照合待ち10000＋照合済み20000＋保留5000＋取込途中3000／分類対象外999／訂正つき）
insert into public.bank_transactions (id, bank_account_id, corporation_id, store_id, txn_date, description, deposit_amount, source_kind, import_file_id, dedupe_key, match_status, hold_reason, tx_kind, counts_as_sales_deposit, legacy_batch, legacy_seq) values
 ('${U(601)}', null, '${ID.corp1}', '${ID.storeA1}', '2026-11-01', 'ローソンATM入金', 10000, 'legacy_sheet', null, null, 'legacy_pending', null, 'atm_deposit', true, 'L1', 1),
 ('${U(602)}', '${ID.acctA1}', '${ID.corp1}', '${ID.storeA1}', '2026-11-01', 'セブンATM入金', 20000, 'playwright', '${U(501)}', 'k602', 'verified', null, 'atm_deposit', true, null, null),
 ('${U(603)}', '${ID.acctA1}', '${ID.corp1}', '${ID.storeA1}', '2026-11-01', '識別できない', 5000, 'playwright', '${U(501)}', 'k603', 'held', '同じキーが2行', 'atm_deposit', true, null, null),
 ('${U(604)}', '${ID.acctA1}', '${ID.corp1}', '${ID.storeA1}', '2026-11-01', '取込途中', 3000, 'playwright', '${U(502)}', 'k604', 'new', null, 'atm_deposit', true, null, null),
 ('${U(605)}', '${ID.acctA1}', '${ID.corp1}', '${ID.storeA1}', '2026-11-01', '利息', 999, 'playwright', '${U(501)}', 'k605', 'verified', null, 'interest', false, null, null),
 ('${U(606)}', '${ID.acctA1}', '${ID.corp1}', '${ID.storeA1}', '2026-11-02', '保留だけの日', 7000, 'playwright', '${U(501)}', 'k606', 'held', '残高が合わない', 'atm_deposit', true, null, null),
 ('${U(607)}', null, '${ID.corp1}', '${ID.storeA2}', '2026-11-01', 'A2 旧', 40000, 'legacy_sheet', null, null, 'legacy_pending', null, 'atm_deposit', true, 'L1', 2),
 ('${U(608)}', null, '${ID.corp2}', '${ID.storeB1}', '2026-11-01', 'B1 旧', 50000, 'legacy_sheet', null, null, 'legacy_pending', null, 'atm_deposit', true, 'L1', 3),
 ('${U(609)}', null, null, null, '2026-11-01', '店舗未確定', 60000, 'legacy_sheet', null, null, 'legacy_pending', null, 'atm_deposit', true, 'L1', 4);
insert into public.bank_deposit_notes (store_id, note_date, note) values ('${ID.storeA1}', '2026-11-01', 'A1メモ'), ('${ID.storeB1}', '2026-11-01', 'B1メモ');
insert into storage.objects (bucket_id, name) values ('bank-csv-originals', 'paypay/x/original.csv');
-- 原本 401 の実ファイル（Storage が付けるサイズつき）
insert into storage.objects (bucket_id, name, metadata) values ('bank-csv-originals', 'paypay/${ID.acctA1}/' || repeat('a', 64) || '.csv', '{"size": 100}');
`;

// ---------- 小さなテスト枠 ----------
let pass = 0, fail = 0; const failures = [];
function ok(name, cond, extra = '') { if (cond) { pass++; console.log('  ✅ ' + name); } else { fail++; failures.push(name); console.log('  ❌ ' + name + (extra ? '  → ' + extra : '')); } }
const section = (t) => console.log('\n■ ' + t);
async function fresh({ stage1 = true, seedUsers = true } = {}) {
  const db = new PGlite();
  await db.exec(BASE);
  if (seedUsers) await db.exec(SEED_USERS);
  if (stage1) await db.exec(STAGE1);
  return db;
}
async function as(db, who, sql, params) {
  const p = typeof who === 'string' ? P[who] : who;
  await db.exec(`set role ${p.role}; select set_config('request.jwt.claim.sub', '${p.id}', false), set_config('request.jwt.claim.role', '${p.role}', false);`);
  try { const r = await db.query(sql, params); return { ok: true, rows: r.rows, n: r.affectedRows ?? r.rows.length }; }
  catch (e) { return { ok: false, err: String(e.message) }; }
  finally { await db.exec(`reset role; select set_config('request.jwt.claim.sub', '', false), set_config('request.jwt.claim.role', '', false);`); }
}
const sup = async (db, sql, params) => { try { const r = await db.query(sql, params); return { ok: true, rows: r.rows }; } catch (e) { return { ok: false, err: String(e.message) }; } };
const script = async (db, sql) => { try { await db.exec(sql); return { ok: true }; } catch (e) { return { ok: false, err: String(e.message) }; } };
const denied = (r) => !r.ok;
const names = (rows) => rows.map((x) => x.name ?? x.store_id).sort().join(',');
async function snapshot(db) {   // 既存の物（bank_ 以外）と全体の指紋
  const q = async (s) => (await db.query(s)).rows;
  const tables = await q(`select table_name from information_schema.tables where table_schema='public' and table_type='BASE TABLE' order by 1`);
  const rowsum = {};
  for (const t of tables) rowsum[t.table_name] = (await q(`select md5(coalesce(string_agg(x::text, '|' order by x::text), '')) h, count(*) n from public.${t.table_name} x`))[0];
  return {
    rowsum,
    cols: await q(`select table_name, column_name, data_type, is_nullable, column_default from information_schema.columns where table_schema='public' order by 1,2`),
    policies: await q(`select schemaname, tablename, policyname, cmd, roles::text, qual, with_check from pg_policies order by 1,2,3`),
    funcs: await q(`select p.proname, pg_get_functiondef(p.oid) def, p.prosecdef, p.proconfig::text cfg, p.proacl::text acl from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','auth') order by 1, pg_get_function_identity_arguments(p.oid)`),
    triggers: await q(`select tgrelid::regclass::text t, tgname, pg_get_triggerdef(oid) d from pg_trigger where not tgisinternal order by 1,2`),
    indexes: await q(`select tablename, indexname, indexdef from pg_indexes where schemaname='public' order by 1,2`),
    grants: await q(`select table_schema, table_name, grantee, privilege_type from information_schema.role_table_grants where table_schema in ('public','storage') order by 1,2,3,4`),
    buckets: await q(`select * from storage.buckets order by id`),
    constraints: await q(`select conrelid::regclass::text t, conname, pg_get_constraintdef(oid) d from pg_constraint where connamespace='public'::regnamespace order by 1,2`),
  };
}
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

// =====================================================================
async function main() {
  // ---------- 1. 適用前後で既存の物が変わらない ----------
  section('1. 段階1を適用しても、既存の表・関数・ポリシー・バケットが変わらない');
  {
    const db = await fresh({ stage1: false });
    const before = await snapshot(db);
    const r = await script(db, STAGE1); ok('SQL が最後まで流れる', r.ok, r.err);
    const after = await snapshot(db);
    const isBank = (x) => /bank_/.test(JSON.stringify(x));
    const old = (arr) => arr.filter((x) => !isBank(x));
    ok('既存の列定義が同じ', same(old(before.cols), old(after.cols)));
    ok('既存のポリシーが同じ', same(old(before.policies), old(after.policies)));
    ok('既存の関数が同じ（auth・team_store_ids 等）', same(old(before.funcs), old(after.funcs)));
    ok('既存のトリガー・索引・制約が同じ', same(old(before.triggers), old(after.triggers)) && same(old(before.indexes), old(after.indexes)) && same(old(before.constraints), old(after.constraints)));
    ok('既存の表のデータが同じ', same(before.rowsum, Object.fromEntries(Object.entries(after.rowsum).filter(([k]) => !k.startsWith('bank_')))));
    ok('既存のバケット payroll-transfer-evidence が同じ', same(before.buckets, after.buckets.filter((b) => b.id !== 'bank-csv-originals')));
    const nb = after.buckets.find((b) => b.id === 'bank-csv-originals');
    ok('新しいバケットは非公開・10MB', nb && nb.public === false && Number(nb.file_size_limit) === 10485760);
    const newTables = (await db.query(`select table_name from information_schema.tables where table_schema='public' and table_name like 'bank\\_%' order by 1`)).rows.map((x) => x.table_name);
    ok('新しい表は 7 つ', newTables.length === 7, newTables.join(','));
    const empty = (await db.query(`select (select count(*) from bank_transactions)+(select count(*) from bank_import_files)+(select count(*) from bank_csv_originals)+(select count(*) from bank_accounts) n`)).rows[0].n;
    ok('新しい表は空', Number(empty) === 0);
    const rls = (await db.query(`select relname, relrowsecurity from pg_class where relname like 'bank\\_%' and relkind='r'`)).rows;
    ok('新しい表は全部 RLS あり', rls.length === 7 && rls.every((x) => x.relrowsecurity));
    const sd = (await db.query(`select proname, prosecdef, proconfig::text cfg from pg_proc where proname in ('bank_ledger_admin','bank_store_visible','bank_tx_correct','bank_deposit_daily','bank_sync_status')`)).rows;
    ok('security definer 関数は 5 つとも search_path 固定', sd.length === 5 && sd.every((x) => x.prosecdef && /search_path=public/.test(x.cfg)), JSON.stringify(sd));
  }

  // ---------- 2. 権限（人物ごと） ----------
  section('2. 権限: 社長・本部・マスター・チーム長・店長・一般社員・アルバイト・他法人の店長・無効ユーザー・未ログイン・サービスロール');
  {
    const db = await fresh(); await db.exec(SEED_LEDGER);
    const T = ['bank_accounts', 'bank_csv_originals', 'bank_import_files', 'bank_transactions', 'bank_account_sync_state'];
    for (const who of ADMINS) {
      const bad = [];
      for (const t of T) { const r = await as(db, who, `select count(*)::int n from public.${t}`); if (!r.ok || r.rows[0].n === 0) bad.push(t); }
      ok(`${who}: 口座・原本・取得履歴・明細・取得状態をすべて読める`, bad.length === 0, bad.join(','));
      const ev = await as(db, who, `select count(*)::int n from public.bank_transaction_events`); ok(`${who}: 訂正履歴を読める（空でもエラーなし）`, ev.ok);
      const d = await as(db, who, `select store_id from public.bank_deposit_daily()`);
      ok(`${who}: 日次集計は全店・全法人（A1・A2・B1）`, d.ok && new Set(d.rows.map((x) => x.store_id)).size === 3, JSON.stringify(d.rows));
    }
    for (const who of NON_ADMIN_LOGGED_IN) {
      const bad = [];
      for (const t of [...T, 'bank_transaction_events']) { const r = await as(db, who, `select count(*)::int n from public.${t}`); if (!r.ok || r.rows[0].n !== 0) bad.push(t); }
      ok(`${who}: 口座・原本・取得履歴・明細・履歴・取得状態は 0 件（読めない）`, bad.length === 0, bad.join(','));
    }
    const expectStores = { team: [ID.storeA1, ID.storeA2], tenchoA: [ID.storeA1], tenchoB: [ID.storeB1], shain: [ID.storeA1], al: [], hqOff: [] };
    for (const [who, exp] of Object.entries(expectStores)) {
      const d = await as(db, who, `select distinct store_id from public.bank_deposit_daily()`);
      const got = d.ok ? d.rows.map((x) => x.store_id).sort() : ['ERR ' + d.err];
      ok(`${who}: 日次集計に見える店舗 = [${exp.map((s) => s.slice(-2)).join(',')}]`, same(got, [...exp].sort()), JSON.stringify(got));
      const s = await as(db, who, `select count(*)::int n from public.bank_sync_status()`);
      ok(`${who}: 取得状態は見える店舗の口座だけ（件数 ${exp.length === 0 ? 0 : '≦' + exp.length}）`, s.ok && (exp.length === 0 ? s.rows[0].n === 0 : s.rows[0].n <= exp.length), JSON.stringify(s));
    }
    const noB = await as(db, 'team', `select count(*)::int n from public.bank_deposit_daily() where store_id = '${ID.storeB1}'`);
    ok('チーム長: 他法人（B1）の入金は見えない', noB.ok && noB.rows[0].n === 0);
    const noUnassigned = await as(db, 'tenchoB', `select count(*)::int n from public.bank_sync_status() where store_id is null`);
    ok('店長B: 店舗未確定の口座は見えない', noUnassigned.ok && noUnassigned.rows[0].n === 0);
    const svc = await as(db, 'service', `select count(distinct store_id)::int n from public.bank_deposit_daily()`);
    ok('サービスロール: 日次集計は全店', svc.ok && svc.rows[0].n === 3);
    const svcAll = await as(db, 'service', `select count(*)::int n from public.bank_transactions`);
    ok('サービスロール: 明細を全件読める', svcAll.ok && svcAll.rows[0].n === 9);
    // 未ログイン
    for (const t of [...T, 'bank_transaction_events', 'bank_deposit_notes']) { const r = await as(db, 'anon', `select 1 from public.${t} limit 1`); ok(`未ログイン: ${t} は読めない（権限エラー）`, denied(r)); }
    for (const f of ['bank_deposit_daily()', 'bank_sync_status()', 'bank_ledger_admin()', `bank_store_visible('${ID.storeA1}')`]) { const r = await as(db, 'anon', `select * from public.${f}`); ok(`未ログイン: ${f} は呼べない`, denied(r)); }
    const rc = await as(db, 'anon', `select public.bank_tx_correct('${U(601)}', '{"tx_kind":"other"}', 'x')`); ok('未ログイン: bank_tx_correct は呼べない', denied(rc));
    // 書き込み（誰も直接はできない）
    for (const who of ['ceo', 'hq', 'master', 'tenchoA', 'service']) {
      if (who === 'service') continue;
      const i = await as(db, who, `insert into public.bank_transactions (txn_date, source_kind) values ('2026-01-01', 'manual_entry')`);
      const u = await as(db, who, `update public.bank_transactions set store_id = null`);
      const d = await as(db, who, `delete from public.bank_transactions`);
      ok(`${who}: 明細を直接 追加・更新・削除できない`, denied(i) && denied(u) && denied(d));
      const ai = await as(db, who, `insert into public.bank_accounts (bank_code, login_group, account_no) values ('paypay','x','x')`);
      ok(`${who}: 口座を直接 追加できない`, denied(ai));
    }
    // 訂正の手続き
    for (const who of ADMINS) { const r = await as(db, who, `select public.bank_tx_correct('${U(601)}', '{"adj_description":"訂正"}', 'テスト')`); ok(`${who}: 訂正の手続きを使える`, r.ok, r.err); }
    for (const who of NON_ADMIN_LOGGED_IN) { const r = await as(db, who, `select public.bank_tx_correct('${U(602)}', '{"adj_description":"x"}', 'テスト')`); ok(`${who}: 訂正の手続きは使えない`, !r.ok && /権限がありません/.test(r.err), r.err); }
    // 入金備考
    const nA = await as(db, 'tenchoA', `select note from public.bank_deposit_notes`); ok('店長A: 入金備考は A1 のものだけ見える', nA.ok && same(nA.rows.map((x) => x.note), ['A1メモ']), JSON.stringify(nA.rows));
    const nT = await as(db, 'team', `select note from public.bank_deposit_notes`); ok('チーム長: A1・A2 の備考だけ（B1 は見えない）', nT.ok && nT.rows.every((x) => x.note !== 'B1メモ'));
    const nC = await as(db, 'ceo', `select count(*)::int n from public.bank_deposit_notes`); ok('社長: 入金備考は全部見える', nC.ok && nC.rows[0].n === 2);
    const nw = await as(db, 'tenchoA', `insert into public.bank_deposit_notes (store_id, note_date, note) values ('${ID.storeA1}', '2026-11-05', 'x')`); ok('店長A: 入金備考は書けない', denied(nw));
    const nw2 = await as(db, 'hq', `insert into public.bank_deposit_notes (store_id, note_date, note) values ('${ID.storeA1}', '2026-11-05', '本部メモ')`); ok('本部: 入金備考を書ける', nw2.ok, nw2.err);
    // Storage
    const so = async (who) => (await as(db, who, `select name from storage.objects where bucket_id = 'bank-csv-originals'`));
    for (const who of ADMINS) { const r = await so(who); ok(`${who}: 原本ファイルを読める`, r.ok && r.rows.length === 2); }
    for (const who of [...NON_ADMIN_LOGGED_IN, 'anon']) { const r = await so(who); ok(`${who}: 原本ファイルは読めない（0 件または拒否）`, !r.ok || r.rows.length === 0); }
    for (const who of ADMINS) { const r = await as(db, who, `insert into storage.objects (bucket_id, name) values ('bank-csv-originals', 'paypay/x/new-${who}.csv')`); ok(`${who}: 原本ファイルを追加できる`, r.ok, r.err); }
    for (const who of [...NON_ADMIN_LOGGED_IN, 'anon']) { const r = await as(db, who, `insert into storage.objects (bucket_id, name) values ('bank-csv-originals', 'paypay/x/evil-${who}.csv')`); ok(`${who}: 原本ファイルを追加できない`, denied(r)); }
    for (const who of [...ADMINS, 'tenchoA']) {
      const u = await as(db, who, `update storage.objects set name = 'hacked' where bucket_id = 'bank-csv-originals'`);
      const d = await as(db, who, `delete from storage.objects where bucket_id = 'bank-csv-originals'`);
      const left = (await sup(db, `select count(*)::int n from storage.objects where bucket_id='bank-csv-originals' and name='hacked'`)).rows[0].n;
      ok(`${who}: 原本ファイルを 上書き・削除できない`, (!u.ok || u.n === 0) && (!d.ok || d.n === 0) && left === 0);
    }
    const sv = await as(db, 'service', `insert into storage.objects (bucket_id, name) values ('bank-csv-originals', 'paypay/x/job.csv')`); ok('サービスロール: 原本ファイルを追加できる（取込ジョブ）', sv.ok, sv.err);
    const tf = await as(db, 'tenchoA', `select public.bank_tx_guard()`); ok('トリガー関数は直接呼べない', denied(tf));
  }

  // ---------- 2b. 法人をまたぐ閲覧は、明示的に割り当てられた店舗だけ ----------
  section('2b. 法人をまたぐ閲覧: 担当チームの店舗・本人の所属店舗として明示的に割り当てられた店舗だけ（法人の所属では広がらない）');
  {
    const db = await fresh(); await db.exec(SEED_LEDGER);
    const vis = async (who, store) => { const r = await as(db, who, `select (select count(*)::int from public.bank_deposit_daily() where store_id='${store}') d, (select count(*)::int from public.bank_deposit_notes where store_id='${store}') n, (select count(*)::int from public.bank_sync_status() where store_id='${store}') s, public.bank_store_visible('${store}') v`); return r.ok ? r.rows[0] : null; };
    let r = await vis('team', ID.storeB1);
    ok('初期: チーム長は他法人 B1 の入金・備考・取得状態・可視判定のどれも見えない', r && r.d === 0 && r.n === 0 && r.s === 0 && r.v === false, JSON.stringify(r));
    // 担当チームに B1（他法人）を明示的に入れる → 見える
    await sup(db, `insert into public.team_stores values ('${ID.team1}', '${ID.storeB1}')`);
    r = await vis('team', ID.storeB1);
    ok('担当チームに他法人の店 B1 を入れると、チーム長に B1 だけ見える', r && r.d === 1 && r.n === 1 && r.s === 1 && r.v === true, JSON.stringify(r));
    ok('同じ他法人でも、店長 A（担当外）には見えない', (await vis('tenchoA', ID.storeB1)).v === false);
    await sup(db, `delete from public.team_stores where team_id='${ID.team1}' and store_id='${ID.storeB1}'`);
    ok('割り当てを外すと、すぐ見えなくなる', (await vis('team', ID.storeB1)).v === false);
    // 本人の所属店舗として他法人の店を割り当て → 見える（店長 A に B1 を所属させる）
    await sup(db, `insert into public.user_stores values ('${ID.tenchoA}', '${ID.storeB1}', false)`);
    ok('店長に他法人の店を所属として割り当てると、その店だけ見える', (await vis('tenchoA', ID.storeB1)).v === true && (await vis('tenchoA', ID.storeA2)).v === false);
    // 法人の所属では広がらない: A1 の法人を B と同じ法人にしても、担当外の店は見えない
    await sup(db, `update public.stores set corporation_id='${ID.corp2}' where id='${ID.storeA2}'`);
    ok('店の法人を変えても、担当でない人には見えない（法人では広がらない）', (await vis('tenchoB', ID.storeA2)).v === false && (await vis('shain', ID.storeA2)).v === false);
    ok('逆に、店の法人を変えても、明示的に割り当てた人からは消えない', (await vis('team', ID.storeA2)).v === true);
    // 店舗未確定は、社長・本部・マスターだけ
    for (const who of ['team', 'tenchoA', 'tenchoB']) ok(`${who}: 店舗未確定（null）の明細・口座は見えない`, (await as(db, who, `select public.bank_store_visible(null) v`)).rows[0].v === false);
  }

  // ---------- 2c. 社員・店長の閲覧（所属店舗だけ・閲覧のみ・機密は出ない・所属の変更が反映される）----------
  section('2c. 社員（SHAIN）・店長（TENCHO）: 所属店舗の入金だけ閲覧／口座番号・残高・原本・取得履歴は見えない／所属の追加・解除が反映／アルバイトは不可');
  {
    const db = await fresh(); await db.exec(SEED_LEDGER);
    const stores = async (who) => { const r = await as(db, who, `select distinct store_id from public.bank_deposit_daily() order by 1`); return r.ok ? r.rows.map((x) => x.store_id).sort() : ['ERR ' + r.err]; };
    // --- 閲覧できる内容（日次入金額・件数・入金日・照合状況・備考）---
    const d = await as(db, 'shain', `select * from public.bank_deposit_daily() where store_id = '${ID.storeA1}' and deposit_date = '2026-11-01'`);
    const row = d.ok && d.rows[0];
    ok('社員: 自店舗の日次入金（日付・金額・件数）が見える', row && Number(row.amount) === 30000 && row.deposit_count === 2, JSON.stringify(row));
    ok('社員: 照合状況（照合待ち・保留・取込途中の件数と保留金額）が見える', row && row.legacy_pending_count === 1 && row.held_count === 1 && Number(row.held_amount) === 5000 && row.new_count === 1, JSON.stringify(row));
    const nt = await as(db, 'shain', `select note from public.bank_deposit_notes`);
    ok('社員: 自店舗の備考が見える（他店の備考は見えない）', nt.ok && same(nt.rows.map((x) => x.note), ['A1メモ']), JSON.stringify(nt.rows));
    const ss = await as(db, 'shain', `select * from public.bank_sync_status()`);
    ok('社員: 自店舗の取得状態が見える', ss.ok && ss.rows.length === 1 && ss.rows[0].store_id === ID.storeA1, JSON.stringify(ss));
    // --- 機密は出ない: 関数の戻り値の列に口座番号・残高・原本・取得履歴が無い ---
    const cols = (await sup(db, `select string_agg(column_name, ',') c from (select unnest(proargnames) column_name from pg_proc where proname in ('bank_deposit_daily','bank_sync_status') and pronamespace = 'public'::regnamespace) q`)).rows[0].c;
    ok('関数の戻り値に、口座番号・残高・原本・取得履歴の機密の列が無い', !/account_no|account_last4|balance|original|sha256|storage_path|file_name|error|import_file|dedupe/.test(cols), cols);
    const ent = JSON.stringify(row && row.entries);
    ok('日次入金の中身（entries）に、口座番号・残高が含まれない', row && !/TESTACCT|balance|残高/.test(ent), ent);
    // --- 正本テーブル・原本は直接読めない ---
    for (const who of ['shain', 'tenchoA']) {
      const bad = [];
      for (const t of ['bank_accounts', 'bank_csv_originals', 'bank_import_files', 'bank_transactions', 'bank_transaction_events', 'bank_account_sync_state']) { const r = await as(db, who, `select count(*)::int n from public.${t}`); if (!r.ok || r.rows[0].n !== 0) bad.push(t); }
      ok(`${who}: 正本テーブル・口座・原本の台帳・取得履歴・訂正履歴を直接読めない（0 件）`, bad.length === 0, bad.join(','));
      const so = await as(db, who, `select name from storage.objects where bucket_id = 'bank-csv-originals'`);
      ok(`${who}: Storage の原本ファイルを読めない`, !so.ok || so.rows.length === 0);
      const w = await as(db, who, `insert into public.bank_deposit_notes (store_id, note_date, note) values ('${ID.storeA1}', '2026-11-09', 'x')`);
      ok(`${who}: 備考を書けない（閲覧のみ）`, denied(w));
      const c = await as(db, who, `select public.bank_tx_correct('${U(602)}', '{"adj_description":"x"}', 'テスト')`);
      ok(`${who}: 訂正・確定の手続きは使えない`, !c.ok && /権限/.test(c.err));
    }
    // --- アルバイトは、所属店舗があっても不可 ---
    ok('アルバイト: 所属店舗があっても、入金・備考・取得状態は何も見えない', (await stores('al')).length === 0 && (await as(db, 'al', `select (select count(*) from public.bank_deposit_notes)::int n, (select count(*) from public.bank_sync_status())::int s, public.bank_store_visible('${ID.storeA1}') v`)).rows[0].n === 0);
    // --- 複数店舗・所属の変更が反映される（社員）---
    ok('社員（A1 のみ所属）: 見える店舗は A1 だけ', same(await stores('shain'), [ID.storeA1]));
    await sup(db, `insert into public.user_stores values ('${ID.shain}', '${ID.storeA2}', false)`);
    ok('所属を A2 にも追加すると、社員に A1・A2 が見える（B1 は見えない）', same(await stores('shain'), [ID.storeA1, ID.storeA2].sort()));
    ok('  備考・取得状態・可視判定にも同じに反映される', (await as(db, 'shain', `select public.bank_store_visible('${ID.storeA2}') a2, public.bank_store_visible('${ID.storeB1}') b1`)).rows[0].a2 === true && (await as(db, 'shain', `select public.bank_store_visible('${ID.storeB1}') b1`)).rows[0].b1 === false);
    await sup(db, `delete from public.user_stores where user_id = '${ID.shain}' and store_id = '${ID.storeA1}'`);
    ok('A1 の所属を解除すると、A1 は見えなくなり A2 だけ残る', same(await stores('shain'), [ID.storeA2]) && (await as(db, 'shain', `select count(*)::int n from public.bank_deposit_notes where store_id = '${ID.storeA1}'`)).rows[0].n === 0);
    await sup(db, `delete from public.user_stores where user_id = '${ID.shain}'`);
    ok('所属を全部解除すると、何も見えない', (await stores('shain')).length === 0);
    // --- 所属変更の反映（店長・チーム長・無効化・役割変更）---
    await sup(db, `insert into public.user_stores values ('${ID.tenchoA}', '${ID.storeB1}', false)`);
    ok('店長に他法人の店 B1 を所属として割り当てると、B1 も見える（明示的な割り当てだけ）', same(await stores('tenchoA'), [ID.storeA1, ID.storeB1].sort()));
    await sup(db, `delete from public.user_stores where user_id = '${ID.tenchoA}' and store_id = '${ID.storeB1}'`);
    ok('割り当てを外すと、また A1 だけ', same(await stores('tenchoA'), [ID.storeA1]));
    await sup(db, `update public.users set is_active = false where id = '${ID.tenchoA}'`);
    ok('店長を無効にすると、何も見えない', (await stores('tenchoA')).length === 0);
    await sup(db, `update public.users set is_active = true, role = 'AL' where id = '${ID.tenchoA}'`);
    ok('役割がアルバイトに変わると、何も見えない', (await stores('tenchoA')).length === 0);
    await sup(db, `update public.users set role = 'SHAIN' where id = '${ID.tenchoA}'`);
    ok('役割が社員に変わると、所属店舗（A1）が見える', same(await stores('tenchoA'), [ID.storeA1]));
    await sup(db, `delete from public.team_stores where team_id = '${ID.team1}'`);
    ok('チームの担当店舗を外すと、チーム長は本人の所属店舗（A2）だけになる', same(await stores('team'), [ID.storeA2]));
  }

  // ---------- 3. 集計に入れる明細の条件 ----------
  section('3. 日次集計: いまの数字を保つ（照合待ちは入る）／未確認の新規は入れない（保留・取込途中は別枠）');
  {
    const db = await fresh(); await db.exec(SEED_LEDGER);
    const d = (await as(db, 'service', `select * from public.bank_deposit_daily('2026-11-01','2026-11-01') where store_id = '${ID.storeA1}'`)).rows[0];
    ok('A1 11/01: amount = 照合待ち10000 ＋ 照合済み20000 = 30000', d && Number(d.amount) === 30000, JSON.stringify(d));
    ok('A1 11/01: deposit_count = 2、legacy_pending_count = 1', d && d.deposit_count === 2 && d.legacy_pending_count === 1);
    ok('A1 11/01: 保留は 1 件・5000（amount に入らない）、取込途中は 1 件（入らない）', d && d.held_count === 1 && Number(d.held_amount) === 5000 && d.new_count === 1);
    ok('A1 11/01: entries は集計に入った 2 件だけ', d && d.entries.length === 2);
    ok('A1 11/01: 売上入金でない分類（利息 999）は出てこない', d && !JSON.stringify(d.entries).includes('利息') && Number(d.amount) === 30000);
    const only = (await as(db, 'service', `select * from public.bank_deposit_daily('2026-11-02','2026-11-02')`)).rows[0];
    ok('保留だけの日: 行は出て amount=0・held 1 件・7000', only && Number(only.amount) === 0 && only.held_count === 1 && Number(only.held_amount) === 7000 && only.entries.length === 0, JSON.stringify(only));
    const nul = (await as(db, 'service', `select count(*)::int n from public.bank_deposit_daily() where store_id is null`)).rows[0].n;
    ok('店舗未確定の行は集計に出ない', nul === 0);
    // 訂正値は集計に反映・原本は不変
    await sup(db, `set app.bank_correction = ''`);
    const c = await as(db, 'ceo', `select public.bank_tx_correct('${U(602)}', '{"adj_deposit_amount": 25000}', '金額訂正')`);
    ok('訂正（adj_deposit_amount=25000）を入れられる', c.ok, c.err);
    const d2 = (await as(db, 'service', `select amount from public.bank_deposit_daily('2026-11-01','2026-11-01') where store_id = '${ID.storeA1}'`)).rows[0];
    const raw = (await sup(db, `select deposit_amount, adj_deposit_amount, is_adjusted from public.bank_transactions where id='${U(602)}'`)).rows[0];
    ok('集計は訂正値（25000）を使い 35000 になる', Number(d2.amount) === 35000, JSON.stringify(d2));
    ok('原本の入金額は 20000 のまま・is_adjusted=true', Number(raw.deposit_amount) === 20000 && Number(raw.adj_deposit_amount) === 25000 && raw.is_adjusted === true);
    const c2 = await as(db, 'ceo', `select public.bank_tx_correct('${U(602)}', '{"adj_deposit_amount": null}', '訂正の取り消し')`);
    const d3 = (await as(db, 'service', `select amount from public.bank_deposit_daily('2026-11-01','2026-11-01') where store_id = '${ID.storeA1}'`)).rows[0];
    ok('訂正を取り消す（null）と、原本の値に戻る（30000）', c2.ok && Number(d3.amount) === 30000, c2.err);
    // 保留を解除（verified）すれば入る
    await sup(db, `update bank_transactions set match_status='verified', hold_reason=null where id='${U(603)}'`);
    const d4 = (await as(db, 'service', `select amount, held_count from public.bank_deposit_daily('2026-11-01','2026-11-01') where store_id = '${ID.storeA1}'`)).rows[0];
    ok('保留を解除（照合済み）すると集計に入る（35000・保留 0）', Number(d4.amount) === 35000 && d4.held_count === 0, JSON.stringify(d4));
  }

  // ---------- 4. 守り（原本の事実・訂正・確定・追記専用） ----------
  section('4. 守り: 原本の事実は変えられない／訂正値で直し履歴が残る／確定済みの保護／追記専用');
  {
    const db = await fresh(); await db.exec(SEED_LEDGER);
    const upd = async (set, id = U(602)) => sup(db, `update public.bank_transactions set ${set} where id = '${id}'`);
    ok('原本の日付は変えられない', denied(await upd(`txn_date = '2026-12-31'`)));
    ok('原本の摘要は変えられない', denied(await upd(`description = 'x'`)));
    ok('原本の入金額は変えられない', denied(await upd(`deposit_amount = 1`)));
    ok('原本の出金額は変えられない', denied(await upd(`withdrawal_amount = 1`)));
    const viaRpc = await as(db, 'ceo', `select public.bank_tx_correct('${U(602)}', '{"deposit_amount": 1}', '原本を直したい')`);
    ok('訂正の手続きでも、原本の入金額は変えられない（変更できない項目）', !viaRpc.ok && /変更できない項目/.test(viaRpc.err), viaRpc.err);
    ok('訂正の手続きでも、原本の残高・摘要・日付は変えられない', denied(await as(db, 'ceo', `select public.bank_tx_correct('${U(602)}', '{"balance": 1}', 'x')`)) && denied(await as(db, 'ceo', `select public.bank_tx_correct('${U(602)}', '{"description": "x"}', 'x')`)) && denied(await as(db, 'ceo', `select public.bank_tx_correct('${U(602)}', '{"txn_date": "2026-12-01"}', 'x')`)));
    ok('旧シートの控え（legacy_*）は変えられない', denied(await upd(`legacy_payload = '{}'::jsonb`, U(601))));
    ok('明細は削除できない', denied(await sup(db, `delete from public.bank_transactions where id='${U(602)}'`)));
    // 理由・権限
    ok('理由が空の訂正は拒否される', denied(await as(db, 'ceo', `select public.bank_tx_correct('${U(602)}', '{"adj_description":"x"}', '  ')`)));
    ok('空の変更は拒否される', denied(await as(db, 'ceo', `select public.bank_tx_correct('${U(602)}', '{}', 'x')`)));
    // 確定
    const cf = await as(db, 'hq', `select public.bank_tx_correct('${U(602)}', '{"confirm_status":"confirmed"}', '確認済み')`);
    ok('確定にできる（訂正の手続き）', cf.ok, cf.err);
    ok('確定済みの店舗は直接変えられない', denied(await upd(`store_id = '${ID.storeA2}'`)));
    ok('確定済みの訂正値は直接変えられない', denied(await upd(`adj_deposit_amount = 1`)));
    ok('確定済みの確定状態は直接戻せない', denied(await upd(`confirm_status = 'open', confirmed_at = null`)));
    ok('確定済みの照合状態を直接 held にできない', denied(await upd(`match_status = 'held', hold_reason = 'x'`)));
    const ca = await as(db, 'hq', `select public.bank_tx_correct('${U(602)}', '{"adj_description":"金額は正しいが摘要を整理","adj_deposit_amount":21000}', '摘要の整理と金額の補正')`);
    ok('確定済みでも、訂正の手続きなら訂正値を入れられる', ca.ok, ca.err);
    const ev = (await sup(db, `select event_kind, before_values, after_values, reason, actor_label from public.bank_transaction_events where transaction_id='${U(602)}' order by created_at, id`)).rows;
    ok('履歴が残る（確定・訂正の 2 件以上）', ev.length >= 2, String(ev.length));
    const last = ev[ev.length - 1];
    ok('履歴に 修正前・修正後・理由・修正者名 が入る', last.event_kind === 'correct' && last.after_values.adj_deposit_amount === 21000 && last.before_values.adj_deposit_amount === null && last.reason === '摘要の整理と金額の補正' && last.actor_label === '本部', JSON.stringify(last));
    ok('履歴の更新・削除はできない', denied(await sup(db, `update public.bank_transaction_events set reason='x'`)) && denied(await sup(db, `delete from public.bank_transaction_events`)));
    // 手続きを通らない変更も履歴に残る
    await upd(`store_id = '${ID.storeA2}', corporation_id = '${ID.corp1}'`, U(603));
    const ev2 = (await sup(db, `select event_kind, after_values from public.bank_transaction_events where transaction_id='${U(603)}'`)).rows;
    ok('手続きを通らない（未確定の）変更も、履歴に残る（assign_store）', ev2.length === 1 && ev2[0].event_kind === 'assign_store', JSON.stringify(ev2));
    // 店舗の訂正で法人も付く
    const st = await as(db, 'ceo', `select public.bank_tx_correct('${U(609)}', '{"store_id":"${ID.storeB1}"}', '店舗を確定')`);
    const t9 = (await sup(db, `select store_id, corporation_id from public.bank_transactions where id='${U(609)}'`)).rows[0];
    ok('店舗未確定の明細に店舗を付けると、法人も付く', st.ok && t9.store_id === ID.storeB1 && t9.corporation_id === ID.corp2, st.err + JSON.stringify(t9));
    // 旧行を CSV と結ぶ（空欄を 1 回だけ埋める）
    ok('旧行の時刻は 1 回だけ埋められる', (await upd(`txn_time = '10:00:00'`, U(601))).ok);
    ok('埋めたあとの時刻は変えられない', denied(await upd(`txn_time = '11:00:00'`, U(601))));
    ok('旧行を取得履歴と結ばずに「照合済み」にはできない', denied(await upd(`match_status = 'verified'`, U(607))));
    const adopt = await upd(`bank_account_id = '${ID.acctA1}', import_file_id = '${U(501)}', dedupe_key = 'k-adopt', balance = 1234, match_status = 'verified', source_kind = 'playwright', identity_basis = 'seq_no'`, U(607));
    ok('旧行を CSV と結んで「照合済み」にできる（口座・取得履歴・重複キー・残高を埋める）', adopt.ok, adopt.err);
    const ev3 = (await sup(db, `select event_kind from public.bank_transaction_events where transaction_id='${U(607)}'`)).rows;
    ok('結んだ履歴は adopt_legacy', ev3.some((x) => x.event_kind === 'adopt_legacy'), JSON.stringify(ev3));
    ok('結んだあと、取得履歴は付け替えられない', denied(await upd(`import_file_id = '${U(502)}'`, U(607))));
    ok('結んだ旧行の金額・日付は旧シートのまま', (await sup(db, `select deposit_amount::int a, txn_date::text d from public.bank_transactions where id='${U(607)}'`)).rows[0].a === 40000);
    // 重複キー
    ok('同じ口座で同じ重複判定キーは 2 行入らない', denied(await sup(db, `insert into public.bank_transactions (bank_account_id, txn_date, source_kind, dedupe_key, match_status, import_file_id) values ('${ID.acctA1}','2026-11-03','playwright','k602','verified','${U(501)}')`)));
    const other = await sup(db, `insert into public.bank_transactions (bank_account_id, txn_date, source_kind, dedupe_key, match_status) values ('${ID.acctB1}','2026-11-03','playwright','k602','new')`);
    ok('別の口座なら同じキーも入る', other.ok, other.err);
    ok('旧シートの同じ行番号は 2 回入らない（再移行しても二重にならない）', denied(await sup(db, `insert into public.bank_transactions (txn_date, source_kind, legacy_batch, legacy_seq, match_status) values ('2026-11-01','legacy_sheet','L1',1,'legacy_pending')`)));
    ok('旧シートの同日・同額の別行は、別の行番号なら両方入る', (await sup(db, `insert into public.bank_transactions (txn_date, description, deposit_amount, source_kind, legacy_batch, legacy_seq, match_status, tx_kind, counts_as_sales_deposit) values ('2026-11-01','ローソンATM入金',10000,'legacy_sheet','L1',5,'legacy_pending','atm_deposit',true)`)).ok);
    ok('保留には理由が要る', denied(await sup(db, `insert into public.bank_transactions (txn_date, source_kind, match_status) values ('2026-11-01','manual_entry','held')`)));
  }

  // ---------- 5. 原本と取得履歴 ----------
  section('5. 原本（bank_csv_originals）と取得履歴（bank_import_files）: 同じ原本を複数の取得履歴が指せる');
  {
    const db = await fresh(); await db.exec(SEED_LEDGER);
    const n = (await sup(db, `select count(*)::int n from public.bank_import_files where original_id = '${U(401)}'`)).rows[0].n;
    ok('1 つの原本を、2 つの取得履歴が指している', n === 2);
    ok('同じ口座・同じ SHA-256 の原本は 2 行にならない', denied(await sup(db, `insert into public.bank_csv_originals (bank_account_id, file_sha256, size_bytes, storage_path) values ('${ID.acctA1}', repeat('a',64), 1, 'p2')`)));
    ok('同じ置き場所は 2 行にならない', denied(await sup(db, `insert into public.bank_csv_originals (bank_account_id, file_sha256, size_bytes, storage_path) values ('${ID.acctB1}', repeat('b',64), 1, 'paypay/${ID.acctA1}/' || repeat('a', 64) || '.csv')`)));
    ok('別の口座なら、同じ SHA-256 の原本も別に持てる', (await sup(db, `insert into public.bank_csv_originals (bank_account_id, file_sha256, size_bytes, storage_path) values ('${ID.acctB1}', repeat('a',64), 1, 'gmo/b/' || repeat('a',64) || '.csv')`)).ok);
    ok('取り直し（3 回目の取得履歴）も同じ原本を指せる', (await sup(db, `insert into public.bank_import_files (bank_account_id, source, original_id, original_reused, status) values ('${ID.acctA1}','playwright','${U(401)}', true, 'stored')`)).ok);
    ok('原本の台帳は更新・削除できない', denied(await sup(db, `update public.bank_csv_originals set size_bytes = 1`)) && denied(await sup(db, `delete from public.bank_csv_originals`)));
    ok('取得履歴は削除できない', denied(await sup(db, `delete from public.bank_import_files`)));
    // 保存に失敗した取得履歴
    const f = await sup(db, `insert into public.bank_import_files (id, bank_account_id, source, status, error, error_at) values ('${U(510)}','${ID.acctA1}','playwright','failed','保存に失敗', now()) returning id`);
    ok('原本の保存に失敗した取得は「失敗」として履歴に残せる', f.ok, f.err);
    ok('原本が無い取得は「確定」にできない', denied(await sup(db, `update public.bank_import_files set status='committed' where id='${U(510)}'`)));
    ok('原本が無いまま確定の状態で作ることもできない', denied(await sup(db, `insert into public.bank_import_files (bank_account_id, source, status) values ('${ID.acctA1}','playwright','committed')`)));
    // 原本の付け替え
    ok('別の口座の原本は結べない', denied(await sup(db, `insert into public.bank_import_files (id, bank_account_id, source, status) values ('${U(511)}','${ID.acctB1}','playwright','registered')`).then(async () => sup(db, `update public.bank_import_files set original_id='${U(401)}' where id='${U(511)}'`))));
    ok('保存済みの原本との結び付きは変えられない', denied(await sup(db, `update public.bank_import_files set original_id = null where id='${U(501)}'`)));
    ok('取得履歴の口座は変えられない', denied(await sup(db, `update public.bank_import_files set bank_account_id='${ID.acctB1}' where id='${U(501)}'`)));
    // 確定の条件: 取込途中の行が残っていると確定できない
    ok('取込途中（new）の明細が残っていると確定できない', denied(await sup(db, `update public.bank_import_files set status='committed' where id='${U(502)}'`)));
    await sup(db, `update public.bank_transactions set match_status='verified' where id='${U(604)}'`);
    // 取込途中が無くなっても、保存確認（実ファイル・サイズ・読み戻したハッシュ）が無ければ確定できない
    ok('取込途中が無くなっても、保存確認が無ければ確定できない', denied(await sup(db, `update public.bank_import_files set status='committed' where id='${U(502)}'`)));
    await sup(db, `update public.bank_import_files set original_verified_at=now(), original_verified_sha256=repeat('a',64), original_verified_size=100 where id='${U(502)}'`);
    const c = await sup(db, `update public.bank_import_files set status='committed', committed_at=now() where id='${U(502)}'`);
    ok('取込途中が無く、保存確認も済んでいれば確定できる', c.ok, c.err);
    ok('確定した取り込みは元に戻せない', denied(await sup(db, `update public.bank_import_files set status='stored' where id='${U(502)}'`)));
  }

  // ---------- 5b. 原本の保存確認（実在・サイズ・ハッシュの照合）が段階 2 の必須条件 ----------
  section('5b. 原本の保存成功・実在・ハッシュ照合: original_id があるだけでは、解析・確定に進めない');
  {
    const db = await fresh(); await db.exec(SEED_LEDGER);
    const mk = async (id, orig = U(401)) => sup(db, `insert into public.bank_import_files (id, bank_account_id, source, original_id, status) values ('${id}','${ID.acctA1}','playwright', ${orig ? `'${orig}'` : 'null'}, 'stored')`);
    const upd = (id, set) => sup(db, `update public.bank_import_files set ${set} where id='${id}'`);
    const VER = `original_verified_at=now(), original_verified_sha256=repeat('a',64), original_verified_size=100`;
    // 作り方の入口
    ok('最初から「解析済み」で作れない', denied(await sup(db, `insert into public.bank_import_files (bank_account_id, source, original_id, status) values ('${ID.acctA1}','playwright','${U(401)}','parsed')`)));
    ok('最初から「確定」で作れない', denied(await sup(db, `insert into public.bank_import_files (bank_account_id, source, original_id, status) values ('${ID.acctA1}','playwright','${U(401)}','committed')`)));
    ok('保存確認の結果を、作成と同時に書き込めない', denied(await sup(db, `insert into public.bank_import_files (bank_account_id, source, original_id, status, original_verified_at, original_verified_sha256, original_verified_size) values ('${ID.acctA1}','playwright','${U(401)}','stored', now(), repeat('a',64), 100)`)));
    { const r = await sup(db, `insert into public.bank_import_files (bank_account_id, source, original_id, status) values ('${ID.acctB1}','gmo_aozora','${U(401)}','stored')`); ok('別の口座の原本を指したまま作れない', denied(r) && /別の口座/.test(r.err || ''), r.err); }
    // 解析済みへの条件
    await mk(U(520));
    ok('保存確認の記録が無いと、解析済みにできない', denied(await upd(U(520), `status='parsed'`)));
    ok('ハッシュだけ・サイズだけの記録では、解析済みにできない', denied(await upd(U(520), `status='parsed', original_verified_at=now(), original_verified_sha256=repeat('a',64)`)));
    ok('読み戻したハッシュが台帳と違うと、解析済みにできない', denied(await upd(U(520), `status='parsed', original_verified_at=now(), original_verified_sha256=repeat('b',64), original_verified_size=100`)));
    ok('読み戻したサイズが台帳と違うと、解析済みにできない', denied(await upd(U(520), `status='parsed', original_verified_at=now(), original_verified_sha256=repeat('a',64), original_verified_size=99`)));
    // 実ファイルの実在
    await sup(db, `insert into public.bank_csv_originals (id, bank_account_id, file_sha256, size_bytes, storage_path) values ('${U(402)}','${ID.acctA1}', repeat('d',64), 50, 'paypay/${ID.acctA1}/' || repeat('d',64) || '.csv')`);
    await mk(U(521), U(402));
    ok('台帳の行があっても、置き場に実ファイルが無ければ、解析済みにできない（ハッシュ記録が正しくても）', denied(await upd(U(521), `status='parsed', original_verified_at=now(), original_verified_sha256=repeat('d',64), original_verified_size=50`)));
    await sup(db, `insert into storage.objects (bucket_id, name, metadata) values ('bank-csv-originals', 'paypay/${ID.acctA1}/' || repeat('d',64) || '.csv', '{"size": 49}')`);
    ok('置き場のファイルのサイズが台帳と違うと、解析済みにできない', denied(await upd(U(521), `status='parsed', original_verified_at=now(), original_verified_sha256=repeat('d',64), original_verified_size=50`)));
    await sup(db, `update storage.objects set metadata = '{}' where name like '%' || repeat('d',64) || '.csv'`);
    ok('置き場のファイルにサイズの情報が無いと、解析済みにできない', denied(await upd(U(521), `status='parsed', original_verified_at=now(), original_verified_sha256=repeat('d',64), original_verified_size=50`)));
    await sup(db, `update storage.objects set metadata = '{"size": 50}' where name like '%' || repeat('d',64) || '.csv'`);
    const okp = await upd(U(521), `status='parsed', original_verified_at=now(), original_verified_sha256=repeat('d',64), original_verified_size=50`);
    ok('実ファイルが実在し、サイズ・読み戻したハッシュが台帳と一致すれば、解析済みにできる', okp.ok, okp.err);
    // 別バケット・別の名前のファイルは実在にならない
    await mk(U(522), U(402));
    await sup(db, `update storage.objects set bucket_id='payroll-transfer-evidence' where name like '%' || repeat('d',64) || '.csv'`);
    ok('別のバケットに同じ名前のファイルがあっても、実在とは認められない', denied(await upd(U(522), `status='parsed', original_verified_at=now(), original_verified_sha256=repeat('d',64), original_verified_size=50`)));
    await sup(db, `update storage.objects set bucket_id='bank-csv-originals' where name like '%' || repeat('d',64) || '.csv'`);
    // 記録後の改ざん
    ok('保存確認の結果は、あとから変えられない', denied(await upd(U(521), `original_verified_sha256=repeat('a',64)`)) && denied(await upd(U(521), `original_verified_at=null`)));
    // 一般ユーザーは取得履歴を変えられない（RLS・権限）
    for (const who of ['ceo', 'hq', 'master', 'team', 'tenchoA', 'shain', 'al', 'anon']) {
      const r = await as(db, who, `update public.bank_import_files set status='committed' where id='${U(521)}'`);
      ok(`${who}: 取得履歴を直接書き換えられない（サービスロールの取込ジョブだけ）`, denied(r));
    }
    await sup(db, `insert into public.bank_import_files (id, bank_account_id, source, status, error, error_at) values ('${U(510)}','${ID.acctA1}','playwright','failed','保存に失敗', now())`);
    ok('原本が無い（失敗の）取得履歴は、保存確認をつけても解析済みにできない', denied(await upd(U(510), `status='parsed', ${VER}`)));
  }

  // ---------- 6. 再実行（べき等） ----------
  section('6. SQL を 2 回・3 回流しても、データ・設定・既存の物を変えない');
  {
    const db = await fresh(); await db.exec(SEED_LEDGER);
    // 手で変えた設定（バケット）と、データを入れた状態で再実行
    await sup(db, `update storage.buckets set file_size_limit = 123, allowed_mime_types = array['text/csv'] where id='bank-csv-originals'`);
    await as(db, 'ceo', `select public.bank_tx_correct('${U(601)}', '{"adj_description":"訂正"}', 'テスト')`);
    const before = await snapshot(db);
    const evBefore = (await sup(db, `select md5(string_agg(x::text,'|' order by id)) h from public.bank_transaction_events x`)).rows[0].h;
    for (let i = 1; i <= 2; i++) { const r = await script(db, STAGE1); ok(`${i} 回目の再実行がエラーなく流れる`, r.ok, r.err); }
    const after = await snapshot(db);
    const evAfter = (await sup(db, `select md5(string_agg(x::text,'|' order by id)) h from public.bank_transaction_events x`)).rows[0].h;
    ok('全ての表のデータが同じ（行数・中身）', same(before.rowsum, after.rowsum));
    ok('履歴が増えていない', evBefore === evAfter);
    ok('列・制約・索引・トリガーが同じ', same(before.cols, after.cols) && same(before.constraints, after.constraints) && same(before.indexes, after.indexes) && same(before.triggers, after.triggers));
    ok('ポリシーが同じ', same(before.policies, after.policies));
    ok('関数の定義・権限が同じ', same(before.funcs, after.funcs));
    ok('表の権限（GRANT）が同じ', same(before.grants, after.grants));
    ok('手で変えたバケット設定（10MB→123 など）を上書きしない', same(before.buckets, after.buckets) && Number(after.buckets.find((b) => b.id === 'bank-csv-originals').file_size_limit) === 123);
    // バケットが公開になっていたら、黙って直さず止まる
    await sup(db, `update storage.buckets set public = true where id='bank-csv-originals'`);
    const pub = await script(db, STAGE1);
    ok('バケットが公開になっていたら、設定を変えずに止まる', !pub.ok && /公開/.test(pub.err) && (await sup(db, `select public from storage.buckets where id='bank-csv-originals'`)).rows[0].public === true, pub.err);
    // 空の状態からも 2 回
    const db2 = await fresh(); const r2 = await script(db2, STAGE1); ok('空の状態からの 2 回目も OK', r2.ok, r2.err);
  }

  // ---------- 7. ロールバック ----------
  section('7. ロールバック: データ・同期状態・原本ファイルがあれば、何も消さずに止まる');
  {
    const countObjs = async (db) => Number((await sup(db, `select (select count(*) from pg_class where relname like 'bank\\_%' and relkind='r') t, (select count(*) from pg_proc where proname like 'bank\\_%') f`)).rows[0].t);
    // (a) 空 → 完全に消える／既存は無傷
    {
      const db = await fresh({ stage1: false }); const base = await snapshot(db); await db.exec(STAGE1);
      const r = await script(db, ROLLBACK); ok('(a) 空の状態なら、ロールバックが通る', r.ok, r.err);
      const after = await snapshot(db);
      ok('(a) 表・関数・ポリシーが消え、既存は適用前と完全に同じ', same(base.cols, after.cols) && same(base.policies, after.policies) && same(base.funcs, after.funcs) && same(base.grants, after.grants));
      ok('(a) バケット bank-csv-originals は空・非公開のまま残り（Supabase は直接の削除を禁止）、他のバケットは無傷', same(base.buckets, after.buckets.filter((b) => b.id !== 'bank-csv-originals')) && after.buckets.find((b) => b.id === 'bank-csv-originals')?.public === false);
      ok('(a) ロールバックを 2 回流しても平気', (await script(db, ROLLBACK)).ok);
      ok('(a) 戻したあと、もう一度適用できる', (await script(db, STAGE1)).ok);
    }
    // (b) 各表に 1 行でもあれば止まる（同期状態・口座・入金備考・原本の台帳を含む）
    const cases = {
      '明細': (db) => db.exec(`insert into public.bank_transactions (txn_date, source_kind, legacy_batch, legacy_seq, match_status) values ('2026-11-01','legacy_sheet','L',1,'legacy_pending')`),
      '口座': (db) => db.exec(`insert into public.bank_accounts (bank_code, login_group, account_no) values ('paypay','g','n')`),
      '同期状態': async (db) => { await db.exec(`insert into public.bank_accounts (id, bank_code, login_group, account_no) values ('${ID.acctA1}','paypay','g','n')`); await db.exec(`insert into public.bank_account_sync_state (bank_account_id) values ('${ID.acctA1}')`); },
      '入金備考': (db) => db.exec(`insert into public.bank_deposit_notes (store_id, note_date, note) values ('${ID.storeA1}', '2026-11-01', 'x')`),
      '取得履歴': async (db) => { await db.exec(`insert into public.bank_accounts (id, bank_code, login_group, account_no) values ('${ID.acctA1}','paypay','g','n')`); await db.exec(`insert into public.bank_import_files (bank_account_id, source) values ('${ID.acctA1}','playwright')`); },
      '原本の台帳': async (db) => { await db.exec(`insert into public.bank_accounts (id, bank_code, login_group, account_no) values ('${ID.acctA1}','paypay','g','n')`); await db.exec(`insert into public.bank_csv_originals (bank_account_id, file_sha256, size_bytes, storage_path) values ('${ID.acctA1}', repeat('c',64), 1, 'p')`); },
    };
    for (const [name, seed] of Object.entries(cases)) {
      const db = await fresh(); await seed(db);
      const t0 = await countObjs(db); const r = await script(db, ROLLBACK);
      ok(`(b) ${name}に 1 行あると、止まる`, !r.ok && /取り消しを中止/.test(r.err), r.err);
      ok(`(b) ${name}: 止まったあと、表も関数も 1 つも消えていない`, (await countObjs(db)) === t0 && t0 === 7 && (await sup(db, `select 1 from pg_proc where proname='bank_tx_correct'`)).rows.length === 1);
    }
    // (c) Storage に原本ファイルがあるだけでも止まる
    {
      const db = await fresh(); await db.exec(`insert into storage.objects (bucket_id, name) values ('bank-csv-originals', 'paypay/x/a.csv')`);
      const r = await script(db, ROLLBACK);
      ok('(c) 原本ファイルが 1 つでもあれば止まり、バケット・表・ポリシーは残る', !r.ok && /原本は消しません/.test(r.err) && (await countObjs(db)) === 7 && (await sup(db, `select 1 from storage.buckets where id='bank-csv-originals'`)).rows.length === 1 && (await sup(db, `select 1 from pg_policies where policyname='bank_csv_originals_read'`)).rows.length === 1, r.err);
    }
    // (d) 他のバケットのファイルは、止める理由にならない
    {
      const db = await fresh(); await db.exec(`insert into storage.objects (bucket_id, name) values ('payroll-transfer-evidence', 'x.csv')`);
      const r = await script(db, ROLLBACK); ok('(d) 他のバケットにファイルがあっても、ロールバックは通り、そのファイルは残る', r.ok && (await sup(db, `select 1 from storage.objects where bucket_id='payroll-transfer-evidence'`)).rows.length === 1, r.err);
    }
  }

  console.log(`\n==== 結果: ${pass} 件 OK ／ ${fail} 件 NG ====`);
  if (fail) { console.log('NG:\n - ' + failures.join('\n - ')); process.exit(1); }
}
main().catch((e) => { console.error('テストの実行に失敗:', e); process.exit(2); });
