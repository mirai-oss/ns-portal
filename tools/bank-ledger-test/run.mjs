// 銀行入金の正本（段階1）の検証。本番には接続しない（メモリ上の PGlite）。使い方: npm install && npm test
import { PGlite } from '@electric-sql/pglite';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const STAGE1 = readFileSync(process.env.STAGE1_FILE || join(here, '../../supabase/2026-11-27_bank_ledger_stage1.sql'), 'utf8');   // STAGE1_FILE は「わざと壊した版でテストが落ちるか」の確認用
const STAGE2 = readFileSync(process.env.STAGE2_FILE || join(here, '../../supabase/2026-11-28_bank_ledger_stage2.sql'), 'utf8');
const STAGE3 = readFileSync(process.env.STAGE3_FILE || join(here, '../../supabase/2026-11-28_bank_ledger_stage3.sql'), 'utf8');
const STAGE4 = readFileSync(process.env.STAGE4_FILE || join(here, '../../supabase/2026-11-28_bank_ledger_stage4.sql'), 'utf8');
const STAGE4_ROLLBACK = readFileSync(join(here, '../../supabase/2026-11-28_bank_ledger_stage4_ROLLBACK.sql'), 'utf8');
const STAGE3_ROLLBACK = readFileSync(join(here, '../../supabase/2026-11-28_bank_ledger_stage3_ROLLBACK.sql'), 'utf8');
const STAGE2_ROLLBACK = readFileSync(join(here, '../../supabase/2026-11-28_bank_ledger_stage2_ROLLBACK.sql'), 'utf8');
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

  // ---------- 8. 段階2: 取込の関数（原本の保存確認・重複しない取込・保留・失敗の記録）----------
  section('8. 段階2の取込関数: サービスロールだけ／原本の実在・サイズ・ハッシュ照合が済むまで取り込めない／同じ明細を何回取っても増えない／保留・失敗の扱い');
  {
    const db = await fresh(); await db.exec(STAGE2);
    const svc = (sql) => as(db, 'service', sql);
    const one = async (sql) => { const r = await svc(sql); if (!r.ok) throw new Error(r.err); return Object.values(r.rows[0])[0]; };
    const j = (o) => `'${JSON.stringify(o).replace(/'/g, "''")}'::jsonb`;
    const HEX = (c) => c.repeat(64);
    // 口座
    const ppAcct = await one(`select public.bank_account_upsert('paypay','paypayA','T-PP-1','テストPP','${ID.storeA1}')`);
    const gmoAcct = await one(`select public.bank_account_upsert('gmo_aozora','gmo_corp','T-GMO-1','テストGMO',null)`);
    ok('口座を登録できる（店舗未定の GMO 口座は unassigned・店舗ID なし）', (await sup(db, `select store_status, store_id from public.bank_accounts where id='${gmoAcct}'`)).rows[0].store_status === 'unassigned' && (await sup(db, `select store_id from public.bank_accounts where id='${gmoAcct}'`)).rows[0].store_id === null);
    await svc(`select public.bank_account_upsert('paypay','paypayA','T-PP-1','テストPP2',null)`);
    ok('もう一度登録しても、店舗の割り当てを null で消さない・口座は増えない', (await sup(db, `select store_id from public.bank_accounts where id='${ppAcct}'`)).rows[0].store_id === ID.storeA1 && (await sup(db, `select count(*)::int n from public.bank_accounts`)).rows[0].n === 2);
    // サービスロール以外は呼べない
    const calls = [`bank_account_upsert('paypay','g','x',null,null)`, `bank_import_register('${ppAcct}','playwright')`, `bank_import_attach_original('${U(1)}', repeat('a',64), 1)`,
      `bank_import_record_verification('${U(1)}', repeat('a',64), 1)`, `bank_import_ingest('${U(1)}', '[]'::jsonb)`, `bank_import_commit('${U(1)}')`, `bank_import_fail('${U(1)}', 'x')`];
    for (const who of ['ceo', 'hq', 'master', 'team', 'tenchoA', 'shain', 'al', 'anon']) {
      const bad = []; for (const c of calls) { const r = await as(db, who, `select public.${c}`); if (r.ok) bad.push(c.split('(')[0]); }
      ok(`${who}: 取込の 7 つの関数をどれも呼べない`, bad.length === 0, bad.join(','));
    }
    // 取込の 1 回ぶんを進める道具
    const sha = HEX('a'), path = (a, b, sh) => `${b}/${a}/${sh}.csv`;
    const objAdd = (a, b, sh, size) => sup(db, `insert into storage.objects (bucket_id, name, metadata) values ('bank-csv-originals', '${path(a, b, sh)}', '{"size": ${size}}') on conflict do nothing`);
    const reg = (a) => one(`select public.bank_import_register('${a}','playwright','x.csv')`);
    const rowsPP = [
      { date: '2026-11-01', time: '10:00:00', desc: 'ATM セブン銀行', dep: 10000, wd: 0, bal: 110000, key: 'pp|2026-11-01|1', basis: 'seq_no' },
      { date: '2026-11-01', time: '12:00:00', desc: 'ATM セブン銀行', dep: 20000, wd: 0, bal: 130000, key: 'pp|2026-11-01|2', basis: 'seq_no' },
      { date: '2026-11-02', time: '09:00:00', desc: 'ATM利用手数料', dep: 0, wd: 110, bal: 129890, key: 'pp|2026-11-02|3', basis: 'seq_no' },
    ];
    // (a) 原本が置き場に無いと、取り込めない（台帳の行・ハッシュ記録があっても）
    let id1 = await reg(ppAcct);
    await svc(`select public.bank_import_attach_original('${id1}', '${sha}', 500)`);
    ok('2 つ目の取込は、同じ口座で実行中の間は始められない', !(await svc(`select public.bank_import_register('${ppAcct}','playwright')`)).ok);
    await svc(`select public.bank_import_record_verification('${id1}', '${sha}', 500)`);
    let r = await svc(`select public.bank_import_ingest('${id1}', ${j(rowsPP)}, true)`);
    ok('実ファイルが置き場に無いと、取り込めない（解析に進まない）', !r.ok && /置き場/.test(r.err), r.err);
    ok('取り込めなかったとき、明細は 1 行も入っていない', (await sup(db, `select count(*)::int n from public.bank_transactions`)).rows[0].n === 0);
    await svc(`select public.bank_import_fail('${id1}', '原本が置き場に無い')`);
    const st = (await sup(db, `select status, last_error from public.bank_account_sync_state where bank_account_id='${ppAcct}'`)).rows[0];
    ok('失敗を取得履歴と取得状態に残す（取込済みの数字は触らない）', st.status === 'error' && /置き場/.test(st.last_error) && (await sup(db, `select status from public.bank_import_files where id='${id1}'`)).rows[0].status === 'failed');
    // (b) サイズ・ハッシュの食い違い
    let id2 = await reg(ppAcct);
    await svc(`select public.bank_import_attach_original('${id2}', '${sha}', 500)`);
    const bad1 = await svc(`select public.bank_import_record_verification('${id2}', '${HEX('b')}', 500)`);
    ok('読み戻したハッシュが台帳と違うと、記録できない（取り込まない）', !bad1.ok && /一致しません/.test(bad1.err), bad1.err);
    const bad2 = await svc(`select public.bank_import_record_verification('${id2}', '${sha}', 499)`);
    ok('読み戻したサイズが台帳と違うと、記録できない', !bad2.ok);
    await svc(`select public.bank_import_record_verification('${id2}', '${sha}', 500)`);
    await objAdd(ppAcct, 'paypay', sha, 499);
    r = await svc(`select public.bank_import_ingest('${id2}', ${j(rowsPP)}, true)`);
    ok('置き場のサイズが台帳と違うと、取り込めない', !r.ok && /サイズ/.test(r.err), r.err);
    ok('  このとき明細は 1 行も入らず、状態は stored のまま（解析済みにならない）', (await sup(db, `select count(*)::int n from public.bank_transactions`)).rows[0].n === 0 && (await sup(db, `select status from public.bank_import_files where id='${id2}'`)).rows[0].status === 'stored');
    await svc(`select public.bank_import_fail('${id2}', 'サイズ不一致')`);
    // (c) 正常: 原本の実在・サイズ・ハッシュが揃う
    await sup(db, `update storage.objects set metadata = '{"size": 500}' where name = '${path(ppAcct, 'paypay', sha)}'`);
    let id3 = await reg(ppAcct);
    const att = await one(`select public.bank_import_attach_original('${id3}', '${sha}', 500)`);
    ok('同じ SHA-256 の原本は台帳で 1 行にまとまり、2 回目以降は取り直し（reused）', att.reused === true && (await sup(db, `select count(*)::int n from public.bank_csv_originals`)).rows[0].n === 1);
    ok('置き場所は {銀行}/{口座ID}/{SHA-256}.csv', att.storage_path === path(ppAcct, 'paypay', sha) && att.storage_bucket === 'bank-csv-originals', JSON.stringify(att));
    await svc(`select public.bank_import_record_verification('${id3}', '${sha}', 500)`);
    r = await svc(`select public.bank_import_ingest('${id3}', ${j(rowsPP)}, true)`);
    ok('保存確認が揃えば取り込める（3 行すべて新規）', r.ok && r.rows[0].bank_import_ingest.rows_new === 3 && r.rows[0].bank_import_ingest.rows_dup === 0, r.err || JSON.stringify(r.rows));
    const cm = await svc(`select public.bank_import_commit('${id3}')`);
    ok('確定でき、取得状態が ok・取得済みの最新日付が入る', cm.ok && (await sup(db, `select status, covers_through::text d from public.bank_account_sync_state where bank_account_id='${ppAcct}'`)).rows[0].status === 'ok');
    const cls = (await sup(db, `select tx_kind, counts_as_sales_deposit c, store_id, match_status, identity_basis from public.bank_transactions order by txn_date, txn_time`)).rows;
    ok('分類: ATM 入金は売上入金に数える／手数料の出金は数えない', cls[0].tx_kind === 'atm_deposit' && cls[0].c === true && cls[2].tx_kind === 'fee' && cls[2].c === false);
    ok('口座の店舗が明細に入り、照合済み（verified）で、判定の根拠が残る', cls.every((x) => x.store_id === ID.storeA1 && x.match_status === 'verified' && x.identity_basis === 'seq_no'));
    ok('確定済みの取り込みは、失敗にできない', !(await svc(`select public.bank_import_fail('${id3}', 'x')`)).ok);
    // (d) 同じ明細を何回取っても増えない／期間が重なる CSV でも増えない
    for (let k = 1; k <= 2; k++) {
      const id = await reg(ppAcct);
      await svc(`select public.bank_import_attach_original('${id}', '${sha}', 500)`); await svc(`select public.bank_import_record_verification('${id}', '${sha}', 500)`);
      const rr = await svc(`select public.bank_import_ingest('${id}', ${j(rowsPP)}, true)`); await svc(`select public.bank_import_commit('${id}')`);
      ok(`同じ CSV を ${k + 1} 回目に取り込んでも、行は増えない（rows_dup=3・rows_new=0）`, rr.ok && rr.rows[0].bank_import_ingest.rows_dup === 3 && rr.rows[0].bank_import_ingest.rows_new === 0 && (await sup(db, `select count(*)::int n from public.bank_transactions`)).rows[0].n === 3, rr.err);
    }
    const sha2 = HEX('c'); await objAdd(ppAcct, 'paypay', sha2, 700);
    const ov = [rowsPP[1], rowsPP[2], { date: '2026-11-03', time: '08:00:00', desc: 'ATM セブン銀行', dep: 5000, wd: 0, bal: 134890, key: 'pp|2026-11-03|4', basis: 'seq_no' }];
    let id4 = await reg(ppAcct);
    await svc(`select public.bank_import_attach_original('${id4}', '${sha2}', 700)`); await svc(`select public.bank_import_record_verification('${id4}', '${sha2}', 700)`);
    // 期間が重なる CSV（古い 1 行が欠ける）→ 既存の行（11/01 の 1 件目）が今回の CSV に無い＝食い違い。新しい行は保留で入る
    r = await svc(`select public.bank_import_ingest('${id4}', ${j(ov)}, true)`);
    ok('期間が重なる CSV に既存の行が欠けていると、新しい行は保留で入る（overlap_missing=1・rows_held=1・rows_dup=2）', r.ok && r.rows[0].bank_import_ingest.overlap_missing === 1 && r.rows[0].bank_import_ingest.rows_held === 1 && r.rows[0].bank_import_ingest.rows_dup === 2, r.err || JSON.stringify(r.rows));
    ok('  保留の行には理由が入り、集計（日次入金）に入らない', (await sup(db, `select hold_reason from public.bank_transactions where dedupe_key='pp|2026-11-03|4'`)).rows[0].hold_reason.length > 0
      && (await as(db, 'ceo', `select count(*)::int n from public.bank_deposit_daily() where deposit_date='2026-11-03'`)).rows[0].n === 1 && Number((await as(db, 'ceo', `select amount from public.bank_deposit_daily() where deposit_date='2026-11-03'`)).rows[0].amount) === 0);
    await svc(`select public.bank_import_commit('${id4}')`);
    // 識別できない行（ジョブが hold_reason を付けた行）・同じ目印が 1 回の取込に 2 行
    const sha3 = HEX('d'); await objAdd(gmoAcct, 'gmo_aozora', sha3, 300);
    const gmoRows = [
      { date: '2026-10-01', desc: 'ATM セブン銀行', dep: 148000, wd: 0, bal: 148000, key: 'gmo|2026-10-01|ATM セブン銀行|148000|0|148000', basis: 'balance_chain' },
      { date: '2026-10-02', desc: 'ATM セブン銀行', dep: 50000, wd: 0, bal: 198000, key: 'gmo|2026-10-02|a|50000|0|198000', basis: 'balance_chain' },
      { date: '2026-10-03', desc: 'ATM セブン銀行', dep: 1, wd: 0, bal: 5, key: 'gmo|2026-10-03|x#1', basis: 'none', hold_reason: '同じ内容の取引が複数行あり、識別できない' },
      { date: '2026-10-03', desc: 'ATM セブン銀行', dep: 1, wd: 0, bal: 5, key: 'gmo|2026-10-03|x#2', basis: 'none', hold_reason: '同じ内容の取引が複数行あり、識別できない' },
      { date: '2026-10-04', desc: 'ATM セブン銀行', dep: 7, wd: 0, bal: 9, key: null, basis: 'none' },
    ];
    let id5 = await one(`select public.bank_import_register('${gmoAcct}','manual_csv','g.csv')`);
    await svc(`select public.bank_import_attach_original('${id5}', '${sha3}', 300)`); await svc(`select public.bank_import_record_verification('${id5}', '${sha3}', 300)`);
    r = await svc(`select public.bank_import_ingest('${id5}', ${j(gmoRows)}, false)`);
    const g = r.ok && r.rows[0].bank_import_ingest;
    ok('GMO（店舗未定の口座）: 2 行が照合済み・3 行が保留（同じ内容 2 行＋目印なし 1 行）', g && g.rows_new === 2 && g.rows_held === 3, r.err || JSON.stringify(g));
    ok('  保留の 2 行は、別々の行として両方入る（勝手に統合・削除しない）', (await sup(db, `select count(*)::int n from public.bank_transactions where bank_account_id='${gmoAcct}' and match_status='held' and description='ATM セブン銀行' and deposit_amount=1`)).rows[0].n === 2);
    ok('  店舗未定の口座の明細は、店舗ID なしで保存され、日次入金の集計には出ない', (await sup(db, `select count(*)::int n from public.bank_transactions where bank_account_id='${gmoAcct}' and store_id is null`)).rows[0].n === 5 && (await as(db, 'ceo', `select count(*)::int n from public.bank_deposit_daily() where deposit_date between '2026-10-01' and '2026-10-04'`)).rows[0].n === 0);
    ok('  残高の鎖の検証結果（false）が取得履歴に残る', (await sup(db, `select balance_chain_ok from public.bank_import_files where id='${id5}'`)).rows[0].balance_chain_ok === false);
    await svc(`select public.bank_import_commit('${id5}')`);
    // 同じ GMO を取り直しても、保留の行も含めて増えない
    let id6 = await one(`select public.bank_import_register('${gmoAcct}','manual_csv','g2.csv')`);
    await svc(`select public.bank_import_attach_original('${id6}', '${sha3}', 300)`); await svc(`select public.bank_import_record_verification('${id6}', '${sha3}', 300)`);
    r = await svc(`select public.bank_import_ingest('${id6}', ${j(gmoRows.slice(0, 4))}, false)`);
    ok('GMO を取り直しても、保留の行を含めて増えない（4 行すべて rows_dup）', r.ok && r.rows[0].bank_import_ingest.rows_dup === 4 && r.rows[0].bank_import_ingest.rows_new === 0 && (await sup(db, `select count(*)::int n from public.bank_transactions where bank_account_id='${gmoAcct}'`)).rows[0].n === 5, r.err);
    await svc(`select public.bank_import_commit('${id6}')`);
    ok('同じ原本（SHA-256）を指す取得履歴が複数あり、原本の台帳は増えない', (await sup(db, `select count(*)::int n from public.bank_import_files where original_id = (select id from public.bank_csv_originals where file_sha256='${sha3}')`)).rows[0].n === 2);
    // 古い「実行中」の印は、30 分で期限切れ
    await svc(`select public.bank_import_register('${gmoAcct}','playwright')`);
    ok('実行中の印があると、同じ口座の次の取込は始められない', !(await svc(`select public.bank_import_register('${gmoAcct}','playwright')`)).ok);
    await sup(db, `update public.bank_account_sync_state set last_attempt_at = now() - interval '31 minutes' where bank_account_id='${gmoAcct}'`);
    ok('31 分前の実行中の印は期限切れとして、次の取込を始められる', (await svc(`select public.bank_import_register('${gmoAcct}','playwright')`)).ok);
    // 順序の守り
    const idx = await one(`select public.bank_import_register('${ppAcct}','playwright')`);
    ok('原本を結ぶ前に、確認・取込・確定はできない', !(await svc(`select public.bank_import_record_verification('${idx}', '${sha}', 500)`)).ok && !(await svc(`select public.bank_import_ingest('${idx}', '[]'::jsonb)`)).ok && !(await svc(`select public.bank_import_commit('${idx}')`)).ok);
    // 画面の権限: 取込で入った明細も、他の人には見えない
    ok('取込で入った明細は、店長・社員・チーム長・アルバイトが直接読めない', (await Promise.all(['tenchoA', 'shain', 'team', 'al'].map((w) => as(db, w, `select count(*)::int n from public.bank_transactions`)))).every((x) => x.ok && x.rows[0].n === 0));
    ok('店長は自店舗（A1）の日次入金だけ見える（保留・手数料は金額に入らない）', Number((await as(db, 'tenchoA', `select sum(amount) a from public.bank_deposit_daily()`)).rows[0].a) === 30000 + 0);
    // 再実行・ロールバック
    ok('段階2の SQL は、2 回流しても同じ（再実行できる）', (await script(db, STAGE2)).ok && (await script(db, STAGE2)).ok);
    const cntBefore = (await sup(db, `select count(*)::int n from public.bank_transactions`)).rows[0].n;
    ok('段階2のロールバックは関数だけを消し、データ・表・段階1の関数は残る', (await script(db, STAGE2_ROLLBACK)).ok && (await sup(db, `select count(*)::int n from pg_proc where proname in ('bank_import_register','bank_import_attach_original','bank_import_record_verification','bank_import_ingest','bank_import_commit','bank_import_fail','bank_account_upsert','bank_assert_service')`)).rows[0].n === 0
      && (await sup(db, `select count(*)::int n from public.bank_transactions`)).rows[0].n === cntBefore && (await sup(db, `select count(*)::int n from pg_proc where proname in ('bank_deposit_daily','bank_store_visible','bank_tx_correct')`)).rows[0].n === 3);
  }

  // ---------- 9. 段階3: 旧シートの移行（控え・取引単位の対応づけ・差異の一覧・承認・再実行・既存の明細が不変）----------
  section('9. 段階3の旧シート移行: 全行を控えに保存／取引単位で対応づけ（同日同額を統合しない）／差異の一覧／承認の記録／再実行で増えない／既存の銀行明細は不変');
  {
    const db = await fresh(); await db.exec(STAGE2); await db.exec(STAGE3);
    const svc = (sql) => as(db, 'service', sql);
    const one = async (sql) => { const r = await svc(sql); if (!r.ok) throw new Error(r.err + ' :: ' + sql.slice(0, 120)); return Object.values(r.rows[0])[0]; };
    const j = (o) => `'${JSON.stringify(o).replace(/'/g, "''")}'::jsonb`;
    const sha = (x) => createHash('sha256').update(JSON.stringify(x)).digest('hex');
    // 銀行CSV由来の既存の明細（段階2の取込で入れる）
    const acct = await one(`select public.bank_account_upsert('paypay','paypayA','T-S3-1','店A1','${ID.storeA1}')`);
    const hexA = 'a'.repeat(64);
    await sup(db, `insert into storage.objects (bucket_id, name, metadata) values ('bank-csv-originals', 'paypay/${acct}/${hexA}.csv', '{"size": 10}')`);
    const imp = await one(`select public.bank_import_register('${acct}','playwright','s3.csv')`);
    await svc(`select public.bank_import_attach_original('${imp}', '${hexA}', 10)`); await svc(`select public.bank_import_record_verification('${imp}', '${hexA}', 10)`);
    const csvRows = [
      { date: '2026-11-01', time: '10:00:00', desc: 'ATM セブン銀行', dep: 10000, wd: 0, bal: 1, key: 'pp|1', basis: 'seq_no' },
      { date: '2026-11-01', time: '12:00:00', desc: 'ATM セブン銀行', dep: 10000, wd: 0, bal: 2, key: 'pp|2', basis: 'seq_no' },
      { date: '2026-11-02', time: '09:00:00', desc: 'ATM セブン銀行', dep: 5000, wd: 0, bal: 3, key: 'pp|3', basis: 'none', hold_reason: '旧に無いと見えていた保留（テスト）' },   // 旧シートには有る（店舗名の別表記など）
      { date: '2026-11-03', time: '08:00:00', desc: 'ATM セブン銀行', dep: 7000, wd: 0, bal: 4, key: 'pp|4', basis: 'none', hold_reason: '旧入金DBに無い（テスト）' },
      { date: '2026-11-05', time: '10:00:00', desc: 'ATM セブン銀行', dep: 20000, wd: 0, bal: 5, key: 'pp|5', basis: 'seq_no' },
      { date: '2026-11-05', time: '11:00:00', desc: 'ATM セブン銀行', dep: 20000, wd: 0, bal: 6, key: 'pp|6', basis: 'seq_no' },
      { date: '2026-11-07', time: '15:00:00', desc: 'ATM セブン銀行', dep: 1500, wd: 0, bal: 7, key: 'pp|7', basis: 'seq_no' },   // 旧に無い・照合済み（時刻差など）
    ];
    const ing = await svc(`select public.bank_import_ingest('${imp}', ${j(csvRows)}, true) r`); await svc(`select public.bank_import_commit('${imp}')`);
    ok('準備: 銀行CSV由来の既存の明細 7 行（うち保留 2）が入った', ing.ok && ing.rows[0].r.rows_new === 5 && ing.rows[0].r.rows_held === 2, ing.err);
    const fp0 = (await svc(`select public.bank_csv_rows_fingerprint() r`)).rows[0].r;
    // 旧シートの行（6 列の一部。取引時刻・登録日時つき）
    const A1 = ID.storeA1, B1 = ID.storeB1;
    const row = (n, store_id, store, date, amount, desc, token, reg = '2026-11-10T05:00:00Z') => ({ row_no: n, store, store_id, date, amount, desc, token, registered_at: reg });
    const legacy1 = [
      row(1, A1, 'A1', '2026-11-01', 10000, 'ATM セブン銀行', '12:00:00'),     // 並びは時刻の逆（行番号では対応を決めない）
      row(2, A1, 'A1', '2026-11-01', 10000, 'ATM セブン銀行', '10:00:00'),
      row(3, A1, 'A1', '2026-11-02', 5000, 'ATM セブン銀行', '09:00:00'),
      row(4, A1, 'A1', '2026-11-05', 20000, 'ATM セブン銀行', '#1'),            // 時刻が無い同日同額（確認対象）
      row(5, A1, 'A1', '2026-11-05', 20000, 'ATM セブン銀行', '#2'),
      row(6, A1, 'A1', '2026-10-01', 8000, 'ATM セブン銀行', '09:00:00'),        // 銀行CSVの期間より前
      row(7, A1, 'A1', '2026-11-06', 9000, 'ATM セブン銀行', '10:00:00'),        // 期間内で銀行に無い
      row(8, A1, 'A1', '2026-11-02', 50000, '調整分', ''),
      row(9, A1, 'A1', '2026-11-02', -3000, 'sssへ入金', ''),                    // マイナスの手動調整
      row(10, null, '未知の店', '2026-11-02', 100, 'ATM', '10:00:00'),            // 店舗が決まらない
      row(11, B1, 'B1', '2026-11-01', 4000, 'ATM セブン銀行', '10:00:00'),        // 銀行口座が正本に無い店舗
      row(12, B1, 'B1', '2026-11-01', 4000, 'ATM セブン銀行', '10:00:00'),        // 全く同じ内容の行（統合しない）
    ];
    const notes1 = [{ store: 'A1', store_id: A1, date: '2026-11-01', note: 'メモ1', updated_by: '社長', updated_at: '2026-11-02T00:00:00Z' }, { store: 'A1', store_id: A1, date: '2026-11-02', note: 'メモ2', updated_by: '本部', updated_at: '2026-11-03T00:00:00Z' }, { store: '未知の店', store_id: null, date: '2026-11-02', note: '店舗不明メモ' }];
    const meta1 = { source: 'rehearsal', columns_present: ['店舗', '日付', '入金額', '摘要', '取引時刻', '登録日時'], payload_sha256: sha([legacy1, notes1]) };
    for (const who of ['ceo', 'hq', 'tenchoA', 'shain', 'al', 'anon']) {
      const r = await as(db, who, `select public.bank_legacy_load(${j(meta1)}, ${j(legacy1)}, ${j(notes1)})`);
      ok(`${who}: 旧シートの取り込み関数（bank_legacy_load）は呼べない`, !r.ok);
    }
    const b1 = await one(`select public.bank_legacy_load(${j(meta1)}, ${j(legacy1)}, ${j(notes1)})`);
    ok('旧シートの全行（12 行）と備考（3 件）が控えに保存される', (await sup(db, `select (select count(*)::int from public.bank_legacy_rows where batch_id='${b1}') r, (select count(*)::int from public.bank_legacy_notes where batch_id='${b1}') n`)).rows[0].r === 12
      && (await sup(db, `select count(*)::int n from public.bank_legacy_notes where batch_id='${b1}'`)).rows[0].n === 3);
    ok('同じ内容の取り出しを再度保存しても、バッチは増えない（同じバッチが返る）', (await one(`select public.bank_legacy_load(${j(meta1)}, ${j(legacy1)}, ${j(notes1)})`)) === b1 && (await sup(db, `select count(*)::int n from public.bank_legacy_batches`)).rows[0].n === 1);
    const ords = (await sup(db, `select ordinal from public.bank_legacy_rows where batch_id='${b1}' and row_no in (11,12) order by row_no`)).rows.map((x) => x.ordinal);
    ok('全く同じ内容の 2 行は、出現番号 1・2 で別々の行として残る（内容ハッシュだけで一意としない）', same(ords, [1, 2]) && (await sup(db, `select count(distinct content_hash)::int n from public.bank_legacy_rows where batch_id='${b1}' and row_no in (11,12)`)).rows[0].n === 1);
    ok('控えは更新・削除できない（追記専用）', denied(await sup(db, `update public.bank_legacy_rows set amount = 1`)) && denied(await sup(db, `delete from public.bank_legacy_rows`)) && denied(await sup(db, `delete from public.bank_legacy_batches`)));
    // 計画（対応づけ）
    const plan = (await svc(`select public.bank_legacy_plan('${b1}') r`)).rows[0].r;
    ok('対応づけ: 銀行CSV由来の明細と 1 対 1 が 5 組・旧のみ移行 4・手動調整 2・店舗未解決 1', plan.paired === 5 && plan.migrated === 4 && plan.adjustments === 2 && plan.unresolved === 1, JSON.stringify(plan));
    ok('  時刻が一致する同日同額の 2 行は、行の並びが逆でも、時刻で正しく対応づく（確認対象にならない）', (await sup(db, `select count(*)::int n from public.bank_legacy_links k where k.basis = 'time' and k.confidence = 'auto'`)).rows[0].n === 3);
    const tmap = (await sup(db, `select r.token, t.txn_time::text tt from public.bank_legacy_links k join public.bank_legacy_rows r on r.content_hash || '#' || r.ordinal = k.legacy_key join public.bank_transactions t on t.id = k.transaction_id where k.kind='paired' and r.txn_date='2026-11-01'`)).rows;
    ok('  （10:00 の旧 ↔ 10:00 の銀行、12:00 ↔ 12:00）', tmap.every((x) => x.token.slice(0, 5) === x.tt.slice(0, 5)) && tmap.length === 2, JSON.stringify(tmap));
    ok('  時刻で特定できない同日同額（#1・#2）だけが「確認対象（proposed）」になる（件数・金額は変わらない）', (await sup(db, `select count(*)::int n from public.bank_diff_items where kind='ambiguous_pair'`)).rows[0].n === 2 && (await sup(db, `select count(*)::int n from public.bank_legacy_links where confidence='proposed'`)).rows[0].n === 2);
    ok('  新しい行は作られず、既存の銀行明細の数は変わらない', (await sup(db, `select count(*)::int n from public.bank_transactions where source_kind <> 'legacy_sheet'`)).rows[0].n === 7 && (await sup(db, `select count(*)::int n from public.bank_transactions where source_kind = 'legacy_sheet'`)).rows[0].n === 0);
    const dif = (await sup(db, `select kind, status, count(*)::int c from public.bank_diff_items group by 1,2 order by 1,2`)).rows.map((x) => `${x.kind}/${x.status}/${x.c}`).join(',');
    ok('差異の一覧: 旧シートに無い銀行の入金（保留 1・未確認 1）／旧と対応済みなのに保留のまま 1／期間内の旧のみ 1／手動調整 2／曖昧な対応 2／店舗未解決 1', dif === 'ambiguous_pair/open/2,bank_only/held/1,bank_only/open/1,legacy_only_in_window/open/1,manual_adjustment/open/2,paired_held/held/1,unresolved_store/open/1', dif);
    { const again = (await svc(`select public.bank_legacy_plan('${b1}') r`)).rows[0].r; ok('  計画を 2 回流しても、対応も差異も増えない', Object.values(again).every((v) => v === 0), JSON.stringify(again)); }
    // 移行
    const mig = (await svc(`select public.bank_legacy_migrate('${b1}') r`)).rows[0].r;
    ok('移行: 旧のみ 4 行＋手動調整 2 行＝6 行が legacy_pending で入る（店舗未解決は入れない）', mig.migrated_rows === 6 && mig.still_unmigrated === 0, JSON.stringify(mig));
    ok('  同じ内容の 2 行（B1）は、2 行とも別々の明細として移行される', (await sup(db, `select count(*)::int n from public.bank_transactions where source_kind='legacy_sheet' and store_id='${B1}' and deposit_amount=4000`)).rows[0].n === 2);
    ok('  マイナスの手動調整は、出金側に絶対値で保存され、売上入金として数える', (await sup(db, `select withdrawal_amount::int w, deposit_amount::int d, tx_kind, counts_as_sales_deposit c from public.bank_transactions where description='sssへ入金'`)).rows.every((x) => x.w === 3000 && x.d === 0 && x.tx_kind === 'adjustment' && x.c === true));
    ok('  2 回目の移行は何も増やさない', (await svc(`select public.bank_legacy_migrate('${b1}') r`)).rows[0].r.migrated_rows === 0 && (await sup(db, `select count(*)::int n from public.bank_transactions where source_kind='legacy_sheet'`)).rows[0].n === 6);
    // 備考
    const nm0 = (await sup(db, `insert into public.bank_deposit_notes (store_id, note_date, note) values ('${A1}', '2026-11-02', '手で入れた別の文面') returning 1`)).ok;
    const nm = (await svc(`select public.bank_legacy_migrate_notes('${b1}') r`)).rows[0].r;
    ok('備考: 既存が無いものだけ入る（1 件）／別の文面が既にあれば上書きせず差異（1 件）／店舗が決まらない備考は差異（1 件）', nm0 && nm.inserted === 1 && nm.mismatch === 1 && nm.unresolved === 1, JSON.stringify(nm));
    ok('  既存の備考は上書きされていない', (await sup(db, `select note from public.bank_deposit_notes where store_id='${A1}' and note_date='2026-11-02'`)).rows[0].note === '手で入れた別の文面');
    ok('  備考の移行も 2 回流して増えない', (await svc(`select public.bank_legacy_migrate_notes('${b1}') r`)).rows[0].r.inserted === 0);
    // 検証レポート
    const rep = (await svc(`select public.bank_legacy_report('${b1}') r`)).rows[0].r;
    ok('保存則: 旧の全行が控えに保存され、すべて対応づけか移行か未解決のどれかに入る（リンクの無い行 0・未移行 0）', rep.legacy_rows === 12 && rep.legacy_rows_saved === 12 && rep.rows_without_link === 0 && rep.rows_unmigrated === 0
      && rep.links_by_kind.paired === 5 && rep.links_by_kind.migrated === 4 && rep.links_by_kind.adjustment === 2 && rep.links_by_kind.unresolved === 1, JSON.stringify(rep.links_by_kind));
    ok('店舗×日付の件数・金額の比較: 食い違いは 2 日だけ＝旧に無い銀行側の照合済み 1 件（11/07）と、旧と対応済みなのに保留のままの 1 件（11/02）。保留の 11/03 は集計に入らず一致', rep.store_dates_mismatch === 2 && rep.mismatch_sample.map((m) => m.date).join() === '2026-11-02,2026-11-07'
      && rep.mismatch_sample[1].ledger_count - rep.mismatch_sample[1].legacy_count === 1 && rep.mismatch_sample[0].legacy_count - rep.mismatch_sample[0].ledger_count === 1, JSON.stringify(rep.mismatch_sample));
    ok('備考の保存: 控え 3 件・うち正本と同じ 1 件', rep.notes_saved === 3 && rep.notes_in_ledger_same === 1);
    ok('既存の銀行CSV由来の明細は、計画・移行を通して 1 件も変わらない（指紋が同じ）', JSON.stringify(rep.csv_rows_fingerprint) === JSON.stringify(fp0), JSON.stringify([rep.csv_rows_fingerprint, fp0]));
    const dd = (await as(db, 'ceo', `select deposit_date::text d, amount::int a, deposit_count c from public.bank_deposit_daily() where store_id='${A1}' and deposit_date='2026-11-02'`)).rows[0];
    ok('日次集計: 11/02 の A1 は 調整 50,000−3,000 ＝ 47,000（件数 2。入金 5,000 は保留中なので入らない）。マイナスの調整も数える', dd && dd.a === 47000 && dd.c === 2, JSON.stringify(dd));
    // ---- 承認（一括・個別）----
    const items = (await sup(db, `select id, kind from public.bank_diff_items order by kind, created_at`)).rows;
    const adj = items.filter((x) => x.kind === 'manual_adjustment').map((x) => x.id);
    const dec = (who, ids, decision, reason, kind, ec, et) => as(db, who, `select public.bank_diff_decide('{${ids.join(',')}}'::uuid[], '${decision}', ${reason === null ? 'null' : `'${reason}'`}, ${kind ? `'${kind}'` : 'null'}, ${ec == null ? 'null' : ec}, ${et == null ? 'null' : et}) r`);
    for (const who of ['tenchoA', 'shain', 'al', 'anon']) ok(`${who}: 差異の承認はできない`, !(await dec(who, adj, 'approved', 'テスト')).ok);
    ok('理由が無い承認はできない', !(await dec('ceo', adj, 'approved', '')).ok);
    ok('種類を指定した一括承認は、別の種類が混じっていると拒否される（取り違え防止）', !(await dec('ceo', [adj[0], items.find((x) => x.kind === 'bank_only').id], 'approved', '一括テスト', 'manual_adjustment')).ok);
    const d1 = await dec('ceo', [adj[0]], 'approved', '個別承認テスト（調整）', 'manual_adjustment');
    ok('個別承認: 社長が理由つきで承認できる（single）', d1.ok && d1.rows[0].r.mode === 'single' && d1.rows[0].r.items === 1, d1.err);
    ok('高額・マイナスの調整（個別確認の対象）は、一括に混ぜられない', !(await dec('hq', adj, 'approved', '一括テスト', 'manual_adjustment', 2, 47000)).ok);
    const amb = items.filter((x) => x.kind === 'ambiguous_pair').map((x) => x.id);
    ok('一括承認は、確認した件数・合計が無いと拒否される', !(await dec('hq', amb, 'approved', '一括テスト', 'ambiguous_pair')).ok);
    ok('確認した合計が実際と違うと拒否される（見ていないものを承認しない）', !(await dec('hq', amb, 'approved', '一括テスト', 'ambiguous_pair', 2, 1)).ok && !(await dec('hq', amb, 'approved', '一括テスト', 'ambiguous_pair', 3, 40000)).ok);
    const d2 = await dec('hq', amb, 'approved', '一括承認テスト（曖昧な対応づけ）', 'ambiguous_pair', 2, 40000);
    ok('一括承認: 本部が、確認した件数（2）・合計（40,000）つきで一括承認できる（bulk）。曖昧な対応づけの確からしさが approved になる', d2.ok && d2.rows[0].r.mode === 'bulk' && d2.rows[0].r.items === 2 && d2.rows[0].r.total === 40000
      && (await sup(db, `select count(*)::int n from public.bank_legacy_links where confidence='approved'`)).rows[0].n === 2, d2.err);
    const rec = (await sup(db, `select mode, decision, reason, actor_label, item_count, array_length(item_ids,1) n, decided_at is not null has_time from public.bank_decision_batches order by decided_at`)).rows;
    ok('承認の記録に、対象の一覧（件数）・理由・操作者・日時が残る（2 回ぶん）', rec.length === 2 && rec.every((x) => x.reason.length > 0 && x.actor_label && x.has_time && x.n === x.item_count) && rec[0].mode === 'single' && rec[1].mode === 'bulk', JSON.stringify(rec));
    ok('決定の履歴（差異ごとの 状態の移り変わり）が残り、更新・削除できない', (await sup(db, `select count(*)::int n from public.bank_diff_decisions`)).rows[0].n === 3 && denied(await sup(db, `update public.bank_diff_decisions set to_status='open'`)) && denied(await sup(db, `delete from public.bank_decision_batches`)));
    const bo = items.filter((x) => x.kind === 'bank_only');
    const heldItem = (await sup(db, `select id from public.bank_diff_items where kind='bank_only' and status='held'`)).rows[0].id;
    const d3 = await dec('ceo', [heldItem], 'approved', '旧シートにも入れる前提で照合済みに', 'bank_only');
    ok('銀行側のみで保留中の行を承認すると、保留が解けて照合済みになり、履歴（release）が残る', d3.ok && (await sup(db, `select match_status from public.bank_transactions where dedupe_key='pp|4'`)).rows[0].match_status === 'verified'
      && (await sup(db, `select count(*)::int n from public.bank_transaction_events e join public.bank_transactions t on t.id=e.transaction_id where t.dedupe_key='pp|4' and e.event_kind='release'`)).rows[0].n === 1, d3.err);
    const ph = items.find((x) => x.kind === 'paired_held').id;
    const d3b = await dec('ceo', [ph], 'approved', '旧シートにある入金（店舗名の別表記）と確認したので保留を解く', 'paired_held');
    ok('旧と対応済みの保留を承認すると、保留が解けて照合済みになり、旧との数字のずれ（11/02）が消える', d3b.ok && (await sup(db, `select match_status from public.bank_transactions where dedupe_key='pp|3'`)).rows[0].match_status === 'verified'
      && (await svc(`select (public.bank_legacy_report('${b1}')->'mismatch_sample') r`)).rows[0].r.every((m) => m.date !== '2026-11-02'), d3b.err);
    const inwin = items.find((x) => x.kind === 'legacy_only_in_window').id;
    const d4 = await dec('ceo', [inwin], 'rejected', '銀行に無いので集計から外す');
    ok('却下: 旧のみの行を集計から外せる（行は残り、履歴に correct が残る）', d4.ok && (await sup(db, `select counts_as_sales_deposit c from public.bank_transactions where source_kind='legacy_sheet' and txn_date='2026-11-06'`)).rows[0].c === false
      && (await as(db, 'ceo', `select count(*)::int n from public.bank_deposit_daily() where store_id='${A1}' and deposit_date='2026-11-06'`)).rows[0].n === 0, d4.err);
    ok('訂正（corrected）は、先に訂正（bank_tx_correct）していないと記録できない', !(await dec('ceo', [items.find((x) => x.kind === 'ambiguous_pair').id], 'corrected', '訂正した')).ok);
    ok('決定した差異の内容（金額・日付など）は変えられない', denied(await sup(db, `update public.bank_diff_items set amount = 1`)) && denied(await sup(db, `delete from public.bank_diff_items`)));
    // ---- 取り出しどうしの変化（並べ替え・追加・削除・修正・同内容の個数変化）----
    const legacy2 = [legacy1[2], legacy1[0], legacy1[1], legacy1[3], legacy1[4],          // 並べ替え（行 3 を先頭へ）
      /* 行 6（10/01）は消えた */
      row(7, A1, 'A1', '2026-11-06', 9500, 'ATM セブン銀行', '10:00:00'),                   // 行 7 の金額を修正（同じ店舗・日付で内容だけ違う＝修正の候補）
      legacy1[7], legacy1[8], legacy1[9], legacy1[10], legacy1[11],
      row(13, B1, 'B1', '2026-11-01', 4000, 'ATM セブン銀行', '10:00:00'),                  // 全く同じ内容の 3 行目（個数が増えた）
      row(14, A1, 'A1', '2026-11-08', 2500, 'ATM セブン銀行', '10:00:00')].map((r, i) => ({ ...r, row_no: i + 1 }));
    const b2 = await one(`select public.bank_legacy_load(${j({ ...meta1, payload_sha256: sha(['b2']) })}, ${j(legacy2)}, ${j(notes1)})`);
    const chg = (await svc(`select public.bank_legacy_changes('${b2}', '${b1}') r`)).rows[0].r;
    ok('変化の検出: 追加 2（新しい行・同じ内容の 3 行目）／削除 1（10/01 の行）／修正の候補 1（11/06 の金額）／並べ替えられた行あり', chg.added === 2 && chg.removed === 1 && chg.modified_candidates === 1 && chg.reordered_rows >= 1, JSON.stringify(chg));
    ok('  同内容の個数が増えた追加は、そのことが差異に記録される（個数の増減を見分ける）', (await sup(db, `select count(*)::int n from public.bank_diff_items where kind='added_since_prev' and (detail->>'same_content_count_changed')::boolean`)).rows[0].n === 1);
    const plan2 = (await svc(`select public.bank_legacy_plan('${b2}') r`)).rows[0].r;
    const mig2 = (await svc(`select public.bank_legacy_migrate('${b2}') r`)).rows[0].r;
    ok('取り出し 2 回目: 並べ替えた行は同じ行として扱われ、新しい対応づけは増えない（追加された行と修正の候補だけが新しい）', plan2.paired === 0 && plan2.adjustments === 0, JSON.stringify(plan2));
    ok('  修正の候補の「新しい側」は、人が決めるまで移行されない（二重計上を防ぐ）。追加された通常の行は移行される', mig2.migrated_rows === 2 && mig2.still_unmigrated === 1, JSON.stringify(mig2));
    ok('  古い側（10/01 の削除された行・11/06 の元の行）の移行済みの明細は、削除も変更もされない', (await sup(db, `select count(*)::int n from public.bank_transactions where source_kind='legacy_sheet' and txn_date in ('2026-10-01','2026-11-06')`)).rows[0].n === 2);
    ok('  控えは 12 ＋ 13 行（バッチごとに全行が残る）', (await sup(db, `select count(*)::int n from public.bank_legacy_rows`)).rows[0].n === 25);
    const rep2 = (await svc(`select public.bank_legacy_report('${b1}') r`)).rows[0].r;
    ok('既存の銀行CSV由来の明細の指紋は、承認・却下・取り出し 2 回目のあとも同じ（照合済みにした 1 行を除き、原本の値は不変）', rep2.csv_rows_fingerprint.rows === 7);
    // ---- 既存の日次集計との互換 ----
    const dbc = await fresh(); await dbc.exec(SEED_LEDGER);
    const before = JSON.stringify((await as(dbc, 'ceo', `select * from public.bank_deposit_daily() order by store_id, deposit_date`)).rows);
    await dbc.exec(STAGE2); await dbc.exec(STAGE3);
    const after = JSON.stringify((await as(dbc, 'ceo', `select * from public.bank_deposit_daily() order by store_id, deposit_date`)).rows);
    ok('段階3を流しても、手動調整が無いデータの日次集計は、1 行も変わらない（段階1の定義と同じ結果）', before === after && before.length > 10);
    // ---- 権限 ----
    for (const who of ['tenchoA', 'shain', 'al', 'team']) {
      const bad = []; for (const t of ['bank_legacy_batches', 'bank_legacy_rows', 'bank_legacy_notes', 'bank_legacy_links', 'bank_diff_items', 'bank_decision_batches', 'bank_diff_decisions']) { const r = await as(db, who, `select count(*)::int n from public.${t}`); if (!r.ok || r.rows[0].n !== 0) bad.push(t); }
      ok(`${who}: 旧シートの控え・対応・差異・決定の記録は 0 件（読めない）`, bad.length === 0, bad.join(','));
    }
    ok('anon: 控え・差異は読めない', denied(await as(db, 'anon', `select 1 from public.bank_legacy_rows limit 1`)) && denied(await as(db, 'anon', `select 1 from public.bank_diff_items limit 1`)));
    for (const who of ['ceo', 'hq', 'master']) ok(`${who}: 控え・差異・決定の記録を読める`, (await as(db, who, `select (select count(*) from public.bank_legacy_rows) a, (select count(*) from public.bank_diff_items) b, (select count(*) from public.bank_decision_batches) c`)).rows[0].a > 0);
    ok('社員・店長は、差異の一覧の関数（レポート）も呼べない', !(await as(db, 'shain', `select public.bank_legacy_report('${b1}')`)).ok && !(await as(db, 'tenchoA', `select public.bank_legacy_report('${b1}')`)).ok);
    // ---- 再実行・ロールバック ----
    ok('段階3の SQL は、2 回流しても同じ（データがあっても壊れない）', (await script(db, STAGE3)).ok && (await script(db, STAGE3)).ok && (await sup(db, `select count(*)::int n from public.bank_legacy_rows`)).rows[0].n === 25);
    const rb = await script(db, STAGE3_ROLLBACK);
    ok('データが入った状態では、段階3のロールバックは何も消さずに止まる', !rb.ok && /取り消しを中止/.test(rb.err) && (await sup(db, `select count(*)::int n from public.bank_legacy_rows`)).rows[0].n === 25, rb.err);
    const dbe = await fresh(); await dbe.exec(STAGE2); await dbe.exec(STAGE3);
    const defBefore = (await sup(dbe, `select md5(pg_get_functiondef('public.bank_deposit_daily(date,date)'::regprocedure)) m`)).rows[0].m;
    const rbe = await script(dbe, STAGE3_ROLLBACK);
    const db1 = await fresh(); const def1 = (await sup(db1, `select md5(pg_get_functiondef('public.bank_deposit_daily(date,date)'::regprocedure)) m`)).rows[0].m;
    ok('空の状態なら段階3のロールバックが通り、日次集計は段階1の定義（同一）に戻る。新しい表・関数は全部消える', rbe.ok && (await sup(dbe, `select md5(pg_get_functiondef('public.bank_deposit_daily(date,date)'::regprocedure)) m`)).rows[0].m === def1 && def1 !== defBefore
      && (await sup(dbe, `select count(*)::int n from pg_class where relname like 'bank\\_legacy\\_%' or relname like 'bank\\_diff\\_%' or relname like 'bank\\_decision\\_%'`)).rows[0].n === 0, rbe.err);
  }

  // ---------- 9c. 手動調整: 個別確認（高額・マイナス）と一括承認／数字の維持と正当性の承認の区別／マイナスは銀行の出金ではない／保留解除の条件／時刻での再照合 ----------
  section('9c. 手動調整の承認（個別／一括・件数と合計の確認）／数字の維持と承認の区別／マイナス調整は銀行の実出金と別／保留解除は 1 対 1 のときだけ／時刻での再照合');
  {
    const db = await fresh(); await db.exec(STAGE2); await db.exec(STAGE3);
    const svc = (sql) => as(db, 'service', sql);
    const one = async (sql) => { const r = await svc(sql); if (!r.ok) throw new Error(r.err + ' :: ' + sql.slice(0, 120)); return Object.values(r.rows[0])[0]; };
    const j = (o) => `'${JSON.stringify(o).replace(/'/g, "''")}'::jsonb`;
    const sha = (x) => createHash('sha256').update(JSON.stringify(x)).digest('hex');
    const A1 = ID.storeA1;
    const row = (n, date, amount, desc, token = '') => ({ row_no: n, store: 'A1', store_id: A1, date, amount, desc, token, registered_at: '2026-11-10T05:00:00Z' });
    const rows = [row(1, '2026-10-01', 1000, '調整分'), row(2, '2026-10-02', 2000, '調整分'), row(3, '2026-10-02', 2000, '調整分'), row(4, '2026-10-03', 3000, '調整分'),     // 一括の対象（同じ内容の 2 行を含む）
      row(5, '2026-10-04', 5000000, 'sss入金分'), row(6, '2026-10-05', -3000, '調整'), row(7, '2026-10-06', -4000000, 'sssへ入金')];                                    // 個別確認: 高額・マイナス・高額かつマイナス（重複は 1 件）
    const meta = { source: 'rehearsal', columns_present: ['店舗', '日付', '入金額', '摘要', '取引時刻', '登録日時'], payload_sha256: sha(['9c', rows]) };
    const b = await one(`select public.bank_legacy_load(${j(meta)}, ${j(rows)}, '[]'::jsonb)`);
    await svc(`select public.bank_legacy_plan('${b}')`); await svc(`select public.bank_legacy_migrate('${b}')`);
    const pv = async (cls) => (await as(db, 'hq', `select public.bank_diff_preview('manual_adjustment', ${cls ? `'${cls}'` : 'null'}) r`)).rows[0].r;
    const all = await pv(null), blk = await pv('bulk'), ind = await pv('individual');
    ok('一覧と合計: 全 7 行／一括の対象 4 行（合計 8,000）／個別確認の対象 3 行（高額 2・マイナス 2・両方 1 → 重複を除いて 3）', all.count === 7 && blk.count === 4 && blk.total === 8000 && ind.count === 3 && ind.high === 2 && ind.negative === 2 && ind.high_and_negative === 1 && ind.individual_distinct === 3 && ind.total === 5000000 - 3000 - 4000000, JSON.stringify([all.count, blk.count, blk.total, ind]));
    ok('  同じ内容の調整行（10/02 の 2000 円×2）は、統合されず 2 件として数えられる', blk.items.filter((x) => x.date === '2026-10-02').length === 2);
    for (const who of ['tenchoA', 'shain', 'al', 'anon']) ok(`${who}: 一覧・合計（プレビュー）を見られない`, !(await as(db, who, `select public.bank_diff_preview('manual_adjustment') r`)).ok);
    const daily = async () => Number((await as(db, 'ceo', `select sum(amount) a from public.bank_deposit_daily()`)).rows[0].a);
    const before = await daily();
    ok('移行だけで数字は維持される（承認の前）: 調整の符号つき合計 ＝ 8,000 ＋ 997,000 ＝ 1,005,000', before === 1005000, String(before));
    const rp0 = (await svc(`select public.bank_legacy_report('${b}') r`)).rows[0].r.adjustments;
    ok('レポート: 数字が維持された行 7／正当性の承認は 0 件（未承認 7）— 「維持」と「承認」は別の数字', rp0.rows === 7 && rp0.numbers_preserved_rows === 7 && rp0.legitimacy_approved === 0 && rp0.legitimacy_pending === 7 && rp0.individual_distinct === 3 && rp0.bulk_pending === 4, JSON.stringify(rp0));
    const dec = (who, ids, decision, reason, ec, et) => as(db, who, `select public.bank_diff_decide('{${ids.join(',')}}'::uuid[], '${decision}', '${reason}', 'manual_adjustment', ${ec == null ? 'null' : ec}, ${et == null ? 'null' : et}) r`);
    ok('個別確認の行を含む一括は、件数・合計が合っていても拒否される', !(await dec('hq', all.ids, 'approved', '全部まとめて', 7, 1005000)).ok);
    ok('個別確認の行 2 件の一括も拒否される（1 件ずつ）', !(await dec('hq', ind.ids.slice(0, 2), 'approved', 'まとめて', 2, 0)).ok);
    ok('一括承認は、件数・合計の確認が無い／違うと拒否される', !(await dec('hq', blk.ids, 'approved', '一括')).ok && !(await dec('hq', blk.ids, 'approved', '一括', 4, 7999)).ok && !(await dec('hq', blk.ids, 'approved', '一括', 3, 8000)).ok);
    const bulk = await dec('hq', blk.ids, 'approved', '本部が一覧・合計を確認して一括承認', blk.count, blk.total);
    ok('一括承認: 本部が、一覧で確認した件数（4）・合計（8,000）つきで承認できる', bulk.ok && bulk.rows[0].r.items === 4 && bulk.rows[0].r.total === 8000, bulk.err);
    const rec = (await sup(db, `select mode, total_amount::int t, expected_count, expected_total::int et, array_length(item_ids,1) n from public.bank_decision_batches`)).rows;
    ok('  決定の記録に、対象の一覧（4 件）・合計・確認した件数と合計が残る', rec.length === 1 && rec[0].mode === 'bulk' && rec[0].t === 8000 && rec[0].expected_count === 4 && rec[0].et === 8000 && rec[0].n === 4, JSON.stringify(rec));
    ok('  承認しても、数字は 1 円も変わらない（正当性の確認であって、数字の維持とは別）', (await daily()) === before);
    for (const id of ind.ids) { const r = await dec('ceo', [id], 'approved', '内容を確認（個別）'); if (!r.ok) throw new Error(r.err); }
    const rp1 = (await svc(`select public.bank_legacy_report('${b}') r`)).rows[0].r.adjustments;
    ok('個別確認の 3 件は 1 件ずつ承認でき、全 7 件の正当性の承認が済む（数字は同じ）', rp1.legitimacy_approved === 7 && rp1.legitimacy_pending === 0 && (await daily()) === before, JSON.stringify(rp1));
    const neg = ind.items.find((x) => x.amount === -3000).id;
    const rj = await dec('ceo', [neg], 'rejected', 'この調整は誤りなので集計から外す');
    ok('却下は「数字が変わる」決定: マイナス調整を外すと合計が 3,000 増え、行は残り、履歴（correct）が残る', rj.ok && (await daily()) === before + 3000
      && (await sup(db, `select count(*)::int n from public.bank_transactions where tx_kind='adjustment' and counts_as_sales_deposit=false`)).rows[0].n === 1, rj.err);
    // マイナス調整は、銀行の実際の出金ではない
    const realW = (await sup(db, `select count(*)::int n from public.bank_transactions where bank_account_id is not null and withdrawal_amount > 0`)).rows[0].n;
    const adjW = (await sup(db, `select count(*)::int n from public.bank_transactions where tx_kind = 'adjustment' and withdrawal_amount > 0 and bank_account_id is null and source_kind = 'legacy_sheet'`)).rows[0].n;
    ok('マイナス調整（2 行）は、銀行口座に結び付かない調整の行として入り、「銀行の実際の出金」には入らない', realW === 0 && adjW === 2, JSON.stringify([realW, adjW]));
    const acct = await one(`select public.bank_account_upsert('paypay','paypayA','T-9C-1','店A1','${A1}')`);
    ok('銀行口座に結び付いた行を「調整」にはできない（実際の銀行明細と調整を取り違えない）', denied(await sup(db, `insert into public.bank_transactions (bank_account_id, txn_date, source_kind, tx_kind, withdrawal_amount, match_status, import_file_id) values ('${acct}','2026-11-01','playwright','adjustment',5,'new',null)`)));
    // ---- 保留解除は 1 対 1 のときだけ／時刻での再照合 ----
    const hexA = 'b'.repeat(64);
    await sup(db, `insert into storage.objects (bucket_id, name, metadata) values ('bank-csv-originals', 'paypay/${acct}/${hexA}.csv', '{"size": 10}')`);
    const imp = await one(`select public.bank_import_register('${acct}','playwright','9c.csv')`);
    await svc(`select public.bank_import_attach_original('${imp}', '${hexA}', 10)`); await svc(`select public.bank_import_record_verification('${imp}', '${hexA}', 10)`);
    const csv = [
      { date: '2026-11-10', time: '10:00:00', desc: 'ATM セブン銀行', dep: 7000, wd: 0, bal: 1, key: 'q|1', basis: 'none', hold_reason: '保留（テスト）' },   // 10:00 の 7,000（保留）
      { date: '2026-11-10', time: '11:00:00', desc: 'ATM セブン銀行', dep: 7000, wd: 0, bal: 2, key: 'q|2', basis: 'seq_no' },
      { date: '2026-11-12', time: '09:00:00', desc: 'ATM セブン銀行', dep: 3000, wd: 0, bal: 3, key: 'q|3', basis: 'seq_no' },
      { date: '2026-11-12', time: '09:30:00', desc: 'ATM セブン銀行', dep: 3000, wd: 0, bal: 4, key: 'q|4', basis: 'seq_no' }];
    await svc(`select public.bank_import_ingest('${imp}', ${j(csv)}, true)`); await svc(`select public.bank_import_commit('${imp}')`);
    const lrows = [row(1, '2026-11-10', 7000, 'ATM セブン銀行', '#1'), row(2, '2026-11-10', 7000, 'ATM セブン銀行', '#2'),                       // 時刻なし: 順番で対応（確認対象）
      row(3, '2026-11-12', 3000, 'ATM セブン銀行', '09:00:00'), row(4, '2026-11-12', 3000, 'ATM セブン銀行', '#2')];                           // 片方は時刻が一致、残りだけ順番（確認対象は残りだけ）
    const meta2 = { ...meta, payload_sha256: sha(['9c2', lrows]) };
    const b2 = await one(`select public.bank_legacy_load(${j(meta2)}, ${j(lrows)}, '[]'::jsonb)`);
    // 別バッチに含まれる同じ旧行（調整 7 行）は、すでに対応づけ済みなので、ここでは新しい 4 行だけが対象
    const pl = (await svc(`select public.bank_legacy_plan('${b2}') r`)).rows[0].r;
    ok('時刻での再照合: 時刻が一致する 1 組（09:00）は自動、時刻で特定できない 3 組だけが確認対象（proposed）', pl.paired === 4 && (await sup(db, `select count(*)::int n from public.bank_legacy_links where kind='paired' and basis='time' and confidence='auto'`)).rows[0].n === 1
      && (await sup(db, `select count(*)::int n from public.bank_legacy_links where kind='paired' and confidence='proposed'`)).rows[0].n === 3, JSON.stringify(pl));
    const phs = (await sup(db, `select id from public.bank_diff_items where kind='paired_held'`)).rows.map((x) => x.id);
    ok('旧と対応済みなのに保留のままの行が 1 件（10:00 の保留）', phs.length === 1);
    const relBad = await as(db, 'ceo', `select public.bank_diff_decide('{${phs[0]}}'::uuid[], 'approved', '保留を解く', 'paired_held') r`);
    ok('1 対 1 が確かめられない（対応が順番だけの確認対象のまま）と、保留は解けない', !relBad.ok && /1 対 1/.test(relBad.err), relBad.err);
    const ambs = (await sup(db, `select id, amount from public.bank_diff_items where kind='ambiguous_pair' order by id`)).rows;
    const tot = ambs.reduce((a, x) => a + Number(x.amount), 0);
    const apr = await as(db, 'ceo', `select public.bank_diff_decide('{${ambs.map((x) => x.id).join(',')}}'::uuid[], 'approved', '時刻と順番を確認して対応を確定', 'ambiguous_pair', ${ambs.length}, ${tot}) r`);
    ok('対応づけの確認対象を承認すると（確認した件数・合計つき）、確からしさが approved になる', apr.ok, apr.err);
    const relOk = await as(db, 'ceo', `select public.bank_diff_decide('{${phs[0]}}'::uuid[], 'approved', '旧シートの同じ入金と 1 対 1 を確認したので保留を解く', 'paired_held') r`);
    ok('1 対 1（同じ店舗ID・日付・金額・確認済みの対応）が確かめられたあとなら、保留を解ける（照合済みに）', relOk.ok && (await sup(db, `select match_status from public.bank_transactions where dedupe_key='q|1'`)).rows[0].match_status === 'verified', relOk.err);
  }

  // ---------- 10. 段階4: 14 日間の並行稼働の毎日の照合（不一致の自動記録・原因・自動解消・二重計上の防止）----------
  section('10. 段階4の毎日の照合: 不一致を自動で記録（原因つき）／タイミング差は合格判定から外す／後の取り出しで自動解消／旧行が先に来ても二重計上しない／14日の経過');
  {
    const db = await fresh(); await db.exec(STAGE2); await db.exec(STAGE3); await db.exec(STAGE4);
    const svc = (sql) => as(db, 'service', sql);
    const one = async (sql) => { const r = await svc(sql); if (!r.ok) throw new Error(r.err + ' :: ' + sql.slice(0, 160)); return Object.values(r.rows[0])[0]; };
    const j = (o) => `'${JSON.stringify(o).replace(/'/g, "''")}'::jsonb`;
    const sha = (x) => createHash('sha256').update(JSON.stringify(x)).digest('hex');
    const jst = new Date(Date.now() + 9 * 3600e3);
    const d = (n, base = jst) => new Date(base.getTime() - n * 86400e3).toISOString().slice(0, 10);   // n 日前（日本時間）
    const A1 = ID.storeA1;
    const acct = await one(`select public.bank_account_upsert('paypay','paypayA','T-S4-1','店A1','${A1}')`);
    let n = 0;
    const csv = async (rows) => {   // 銀行CSVの取込（段階2の関数）
      const hex = ('e' + (++n).toString(16)).padEnd(64, '0');
      await sup(db, `insert into storage.objects (bucket_id, name, metadata) values ('bank-csv-originals', 'paypay/${acct}/${hex}.csv', '{"size": 10}')`);
      const imp = await one(`select public.bank_import_register('${acct}','playwright','s4.csv')`);
      await svc(`select public.bank_import_attach_original('${imp}', '${hex}', 10)`); await svc(`select public.bank_import_record_verification('${imp}', '${hex}', 10)`);
      const r = await svc(`select public.bank_import_ingest('${imp}', ${j(rows)}, true)`); if (!r.ok) throw new Error(r.err); await svc(`select public.bank_import_commit('${imp}')`);
    };
    const b = (key, time, date, dep) => ({ date, time, desc: 'ATM セブン銀行', dep, wd: 0, bal: 1, key, basis: 'seq_no' });
    const lrow = (no, date, amount, desc, token) => ({ row_no: no, store: 'A1', store_id: A1, date, amount, desc, token, registered_at: '2026-11-10T05:00:00Z' });
    const load = async (rows, tag) => one(`select public.bank_legacy_load(${j({ source: 'rehearsal', columns_present: ['店舗', '日付', '入金額', '摘要', '取引時刻', '登録日時'], payload_sha256: sha([tag, rows]) })}, ${j(rows)}, '[]'::jsonb)`);
    let day = 0; let prev = null;
    const recon = async (rows, tag) => { const bid = await load(rows.map((r, i) => ({ ...r, row_no: i + 3 })), tag); const r = await svc(`select public.bank_reconcile_run('${bid}', ${prev ? `'${prev}'` : 'null'}, '${d(-(day++))}') r`); prev = bid; if (!r.ok) throw new Error(r.err); return r.rows[0].r; };
    const daily = async (date) => (await as(db, 'ceo', `select amount::int a, deposit_count c from public.bank_deposit_daily() where store_id='${A1}' and deposit_date='${date}'`)).rows[0];
    // ----- 1 日目: 銀行CSV 2 件（古い日付）・旧シートは同じ 2 件＋期間より前 1 件＋手動調整 1 件 → 不一致 0
    await csv([b('s|1', '10:00:00', d(10), 10000), b('s|2', '09:00:00', d(9), 5000)]);
    const base = [lrow(0, d(10), 10000, 'ATM セブン銀行', '10:00:00'), lrow(0, d(9), 5000, 'ATM セブン銀行', '09:00:00'), lrow(0, d(60), 8000, 'ATM セブン銀行', '09:00:00'), lrow(0, d(8), 2000, '調整分', '')];
    let r1 = await recon(base, 'day1');
    ok('1 日目: 旧シートと正本が一致（不一致 0・状態 ok）。銀行2件は旧行と1対1・旧のみ（期間より前）と調整は移行', r1.status === 'ok' && r1.mismatches_open === 0 && r1.paired_total === 2 && r1.migrate.migrated_rows === 2, JSON.stringify(r1));
    ok('  同じ取り出しを 2 回照合しようとすると断られる', !(await svc(`select public.bank_reconcile_run('${prev}', null, '${d(0)}')`)).ok);
    // ----- 2 日目: 銀行CSVの当日分が先に入る（旧シートにはまだ無い）→ 不一致 1（タイミング差）。合格判定には影響しない
    await csv([b('s|3', '12:00:00', d(0), 7000)]);
    let r2 = await recon(base, 'day2');
    ok('2 日目: 銀行の当日分が先に入ると、不一致 1 件（取込のタイミング差）として記録される。状態は ok（タイミング差は判定から外す）', r2.mismatches_open === 1 && r2.timing === 1 && r2.unexplained === 0 && r2.status === 'ok' && r2.new === 1, JSON.stringify(r2));
    const mm = (await sup(db, `select cause, is_timing, status, ledger_count, legacy_count from public.bank_reconcile_mismatches`)).rows;
    ok('  不一致の記録: 原因 bank_only・タイミング差・未解消（open）・件数の食い違い（正本 1／旧 0）', mm.length === 1 && mm[0].cause === 'bank_only' && mm[0].is_timing && mm[0].status === 'open' && mm[0].ledger_count === 1 && mm[0].legacy_count === 0, JSON.stringify(mm));
    // ----- 3 日目: 旧シートにも当日分が入る → 自動で対応づけ・解消。二重計上しない
    const day3 = [...base, lrow(0, d(0), 7000, 'ATM セブン銀行', '12:00:00')];
    let r3 = await recon(day3, 'day3');
    const dd0 = await daily(d(0));
    ok('3 日目: 旧シートにも入ると、取引単位で 1 対 1 に対応し、不一致は自動で解消される（二重計上なし: 当日は 7,000・1 件）', r3.mismatches_open === 0 && r3.resolved === 1 && r3.status === 'ok' && dd0.a === 7000 && dd0.c === 1, JSON.stringify([r3, dd0]));
    ok('  不一致の記録は「自動で解消済み」になり、差異の一覧も resolved（記録は残る）', (await sup(db, `select status from public.bank_reconcile_mismatches`)).rows[0].status === 'auto_resolved' && (await sup(db, `select count(*)::int n from public.bank_diff_items where kind='bank_only' and status='resolved'`)).rows[0].n === 1);
    // ----- 4 日目: 旧シートが先（銀行側の取込が遅れた）。期間内の旧のみは「移行せず」差異に出す
    const day4 = [...day3, lrow(0, d(1), 3000, 'ATM セブン銀行', '09:00:00')];
    let r4 = await recon(day4, 'day4');
    ok('4 日目: 旧シートが先に入った分（銀行側の取込が遅れた）は、移行せず差異に出す。不一致 1（タイミング差）・状態 ok', r4.mismatches_open === 1 && r4.timing === 1 && r4.migrate.migrated_rows === 0 && r4.unpaired_legacy === 1, JSON.stringify(r4));
    ok('  この旧行は、正本に移行されていない（あとで銀行の明細が入っても、二重に数えないため）', (await sup(db, `select count(*)::int n from public.bank_transactions where source_kind='legacy_sheet' and txn_date='${d(1)}'`)).rows[0].n === 0);
    // ----- 5 日目: 遅れていた銀行CSVが入る → 対応づけ・解消。二重計上しない
    await csv([b('s|4', '09:00:00', d(1), 3000)]);
    let r5 = await recon(day4, 'day5');
    const dd1 = await daily(d(1));
    ok('5 日目: 遅れていた銀行の明細が入ると、旧行と自動で対応し、不一致は解消。二重計上なし（前日は 3,000・1 件）', r5.mismatches_open === 0 && r5.resolved === 1 && dd1.a === 3000 && dd1.c === 1, JSON.stringify([r5, dd1]));
    ok('  差異（旧のみ・期間内）も自動で resolved になる', (await sup(db, `select count(*)::int n from public.bank_diff_items where kind='legacy_only_in_window' and status='resolved'`)).rows[0].n === 1);
    // ----- 6 日目: 銀行側にだけ有る古い入金（タイミング差ではない）→ 不一致が続き、状態は mismatch
    await csv([b('s|5', '08:00:00', d(5), 8000)]);
    let r6 = await recon(day4, 'day6');
    ok('6 日目: 古い日付で銀行側にだけ有る入金は、不一致（原因 bank_only・タイミング差ではない）。状態 mismatch', r6.mismatches_open === 1 && r6.timing === 0 && r6.status === 'mismatch', JSON.stringify(r6));
    // ----- 7 日目: 旧シートの行の修正（金額 2,000 → 2,500）を検出
    const day7 = day4.map((r) => (r.desc === '調整分' ? { ...r, amount: 2500 } : r));
    let r7 = await recon(day7, 'day7');
    ok('7 日目: 旧シートの行の修正（調整の金額）を「修正の候補」として検出し、自動確定しない。不一致が続く', r7.changes.modified_candidates === 1 && r7.status === 'mismatch', JSON.stringify(r7.changes));
    const open7 = (await sup(db, `select cause, days_open from public.bank_reconcile_mismatches where status='open' order by txn_date`)).rows;
    ok('  続いている不一致は、原因つきで日数が数えられる', open7.length === 2 && open7.some((x) => /bank_only/.test(x.cause)) && open7.some((x) => /modified_candidate/.test(x.cause)), JSON.stringify(open7));
    // ----- 経過報告・権限
    const rep = (await as(db, 'ceo', `select public.bank_reconcile_report(14) r`)).rows[0].r;
    ok('14 日の経過報告: 実行 7 回・連続 ok は 0（直近が mismatch）・基準（14 日連続）は未達・いま続く不一致 2 件・自動解消の累計 2 件', rep.criterion_met === false && rep.consecutive_ok_days === 0 && rep.open_mismatches.length === 2 && rep.auto_resolved_total === 2 && rep.runs.length === 7, JSON.stringify([rep.days_observed, rep.consecutive_ok_days, rep.open_mismatches.length, rep.auto_resolved_total, rep.runs.length]));
    for (const who of ['tenchoA', 'shain', 'al', 'anon']) ok(`${who}: 照合の経過報告・記録は見られない`, !(await as(db, who, `select public.bank_reconcile_report(14)`)).ok && (!(await as(db, who, `select count(*)::int n from public.bank_reconcile_mismatches`)).ok || (await as(db, who, `select count(*)::int n from public.bank_reconcile_mismatches`)).rows[0].n === 0));
    for (const who of ['ceo', 'hq', 'tenchoA']) ok(`${who}: 照合の実行（bank_reconcile_run）は呼べない（取込ジョブだけ）`, !(await as(db, who, `select public.bank_reconcile_run('${prev}')`)).ok);
    ok('不一致・実行の記録は削除できない／実行の記録は更新できない', denied(await sup(db, `delete from public.bank_reconcile_mismatches`)) && denied(await sup(db, `update public.bank_reconcile_runs set status='ok'`)) && denied(await sup(db, `update public.bank_reconcile_mismatches set txn_date = '2020-01-01'`)));
    // 連続 ok の数え方: 全部の不一致が消えれば、ok が続く（別の db で簡易確認）
    const rb = await script(db, STAGE4_ROLLBACK);
    ok('データが入った状態では、段階4のロールバックは何も消さずに止まる', !rb.ok && /取り消しを中止/.test(rb.err), rb.err);
    const dbe = await fresh(); await dbe.exec(STAGE2); await dbe.exec(STAGE3);
    const planBefore = (await sup(dbe, `select md5(pg_get_functiondef('public.bank_legacy_plan(uuid)'::regprocedure)) m`)).rows[0].m;
    await dbe.exec(STAGE4); const planAfter = (await sup(dbe, `select md5(pg_get_functiondef('public.bank_legacy_plan(uuid)'::regprocedure)) m`)).rows[0].m;
    const rbe = await script(dbe, STAGE4_ROLLBACK);
    ok('空の状態なら段階4のロールバックが通り、bank_legacy_plan は段階3の定義に戻る（新しい表・関数は消える）', rbe.ok && planBefore !== planAfter && (await sup(dbe, `select md5(pg_get_functiondef('public.bank_legacy_plan(uuid)'::regprocedure)) m`)).rows[0].m === planBefore
      && (await sup(dbe, `select count(*)::int n from pg_class where relname like 'bank\\_reconcile\\_%'`)).rows[0].n === 0, rbe.err);
    ok('段階4の SQL は、2 回流しても同じ（データがあっても壊れない）', (await script(db, STAGE4)).ok && (await script(db, STAGE4)).ok && (await sup(db, `select count(*)::int n from public.bank_reconcile_runs`)).rows[0].n === 7);
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
