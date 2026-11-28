// 入金まわりの既存の権限漏れの修正（2026-11-28_deposit_access_fix.sql）の検証。本番には接続しない（PGlite）。 node deposit_access_test.mjs
import { PGlite } from '@electric-sql/pglite';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
const here = dirname(fileURLToPath(import.meta.url));
const FIX = readFileSync(process.env.FIX_FILE || join(here, '../../supabase/2026-11-28_deposit_access_fix.sql'), 'utf8');
const FIX_RB = readFileSync(join(here, '../../supabase/2026-11-28_deposit_access_fix_ROLLBACK.sql'), 'utf8');
const U = (n) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const ID = { c1: U(1), c2: U(2), i1: U(901), i2: U(902), A1: U(11), B1: U(12), ceo: U(101), master: U(102), hqU: U(103), hqL: U(104), teamU: U(105), teamL: U(106), tencho: U(107), ovr: U(108), shain: U(109), al: U(110), r1: U(201), r2: U(202), r3: U(203) };
const P = Object.fromEntries(['ceo', 'master', 'hqU', 'hqL', 'teamU', 'teamL', 'tencho', 'ovr', 'shain', 'al'].map((k) => [k, { role: 'authenticated', id: ID[k] }]));
P.anon = { role: 'anon', id: '' }; P.service = { role: 'service_role', id: '' };
const BASE = `
create role anon nologin; create role authenticated nologin; create role service_role nologin bypassrls;
create schema auth;
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
create function auth.role() returns text language sql stable as $$ select nullif(current_setting('request.jwt.claim.role', true), '') $$;
grant usage on schema auth to anon, authenticated, service_role; grant usage on schema public to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
create schema info; grant usage on schema info to anon, authenticated, service_role;
create table info.profiles (id uuid primary key, role_id uuid, is_master boolean default false, is_active boolean default true);
create table info.user_corporations (user_id uuid, corporation_id uuid); create table info.role_corporations (role_id uuid, corporation_id uuid);
create table public.corporations (id uuid primary key, name text, legacy_info_id uuid);
create table public.stores (id uuid primary key, name text, corporation_id uuid);
create table public.users (id uuid primary key, name text, role text, is_master boolean not null default false, is_active boolean not null default true, team_id uuid);
create table public.user_stores (user_id uuid, store_id uuid);
create table public.portal_user_overrides (user_id uuid, system_key text, allowed boolean);
create function public.invoice_can_access() returns boolean language sql stable security definer set search_path to 'public' as $$
  select coalesce((select u.is_master or u.role in ('CEO','HQ') from users u where u.id = auth.uid() and u.is_active), false)
      or coalesce((select po.allowed from portal_user_overrides po where po.user_id = auth.uid() and po.system_key = 'invoices'), false); $$;
create table public.kd_deposit_daily (id serial primary key, store_id uuid, corporation_id uuid, deposit_date date, amount numeric);
create table public.kd_deposit_monthly_summary (id serial primary key, store_id uuid, corporation_id uuid, year_month text, deposit_total numeric);
create view public.kd_deposit_daily_v with (security_invoker = true) as select store_id, deposit_date, amount from public.kd_deposit_daily;
create view public.kd_deposit_carry_v with (security_invoker = true) as select store_id, deposit_date from public.kd_deposit_daily;
create table public.ar_receivables (id uuid primary key, corporation_id uuid, store_id uuid);
create table public.ar_deposits (id serial primary key, receivable_id uuid references public.ar_receivables(id), amount numeric);
create table public.ar_matching (id serial primary key, receivable_id uuid references public.ar_receivables(id), note text);
create table public.ar_receivable_attachments (id serial primary key, receivable_id uuid references public.ar_receivables(id), file_name text);
create table public.ar_recurring_master (id serial primary key, name text);
alter table public.kd_deposit_daily enable row level security; alter table public.kd_deposit_monthly_summary enable row level security;
alter table public.ar_receivables enable row level security; alter table public.ar_deposits enable row level security; alter table public.ar_matching enable row level security;
alter table public.ar_receivable_attachments enable row level security; alter table public.ar_recurring_master enable row level security;
create policy ai_reader_read on public.kd_deposit_daily for select using (true);
`;
const GATE = (t) => `(EXISTS ( SELECT 1 FROM users u WHERE ((u.id = auth.uid()) AND u.is_active AND (u.is_master OR (u.role = ANY (ARRAY['CEO'::text, 'HQ'::text, 'TEAM'::text])) OR ((u.role = 'TENCHO'::text) AND (EXISTS ( SELECT 1 FROM user_stores us WHERE ((us.user_id = u.id) AND (us.store_id = ${t}.store_id)))))))))`;
const ORIG = `
drop policy ai_reader_read on public.kd_deposit_daily;
create policy kd_deposit_daily_select on public.kd_deposit_daily for select to authenticated using ${GATE('kd_deposit_daily')};
create policy kd_deposit_monthly_summary_select on public.kd_deposit_monthly_summary for select to authenticated using ${GATE('kd_deposit_monthly_summary')};
create policy authenticated_full_access on public.ar_receivables for all to authenticated using (true) with check (true);
create policy authenticated_full_access on public.ar_deposits for all to authenticated using (true) with check (true);
create policy authenticated_full_access on public.ar_matching for all to authenticated using (true) with check (true);
create policy authenticated_full_access on public.ar_receivable_attachments for all to authenticated using (true) with check (true);
create policy authenticated_full_access on public.ar_recurring_master for all to authenticated using (true) with check (true);
revoke all on public.ar_receivables, public.ar_deposits, public.ar_matching, public.ar_receivable_attachments, public.ar_recurring_master from anon;
`;
const SEED = `
insert into public.corporations values ('${ID.c1}', '法人1', '${ID.i1}'), ('${ID.c2}', '法人2', '${ID.i2}');
insert into public.stores values ('${ID.A1}', 'A1', '${ID.c1}'), ('${ID.B1}', 'B1', '${ID.c2}');
insert into public.users (id, name, role, is_master, is_active) values ('${ID.ceo}','社長','CEO',true,true),('${ID.master}','マスター','SHAIN',true,true),('${ID.hqU}','本部U','HQ',false,true),('${ID.hqL}','本部L','HQ',false,true),
 ('${ID.teamU}','チームU','TEAM',false,true),('${ID.teamL}','チームL','TEAM',false,true),('${ID.tencho}','店長','TENCHO',false,true),('${ID.ovr}','許可つき社員','SHAIN',false,true),('${ID.shain}','社員','SHAIN',false,true),('${ID.al}','AL','AL',false,true);
insert into public.user_stores values ('${ID.tencho}', '${ID.A1}');
insert into public.portal_user_overrides values ('${ID.ovr}', 'invoices', true);
insert into info.profiles (id, is_master, is_active) values ('${ID.hqU}', false, true), ('${ID.hqL}', false, true), ('${ID.teamU}', false, true), ('${ID.teamL}', false, true);
insert into info.user_corporations values ('${ID.hqL}', '${ID.i1}'), ('${ID.teamL}', '${ID.i1}');
insert into public.kd_deposit_daily (store_id, corporation_id, deposit_date, amount) values ('${ID.A1}', '${ID.c1}', '2026-11-01', 100), ('${ID.B1}', '${ID.c2}', '2026-11-01', 200);
insert into public.kd_deposit_monthly_summary (store_id, corporation_id, year_month, deposit_total) values ('${ID.A1}', '${ID.c1}', '2026-11', 100), ('${ID.B1}', '${ID.c2}', '2026-11', 200);
insert into public.ar_receivables values ('${ID.r1}', '${ID.c1}', '${ID.A1}'), ('${ID.r2}', '${ID.c2}', '${ID.B1}'), ('${ID.r3}', null, null);
insert into public.ar_deposits (receivable_id, amount) values ('${ID.r1}', 1), ('${ID.r2}', 2), ('${ID.r3}', 3);
insert into public.ar_matching (receivable_id, note) values ('${ID.r1}', 'm1'), ('${ID.r2}', 'm2');
insert into public.ar_receivable_attachments (receivable_id, file_name) values ('${ID.r1}', 'f1'), ('${ID.r2}', 'f2');
insert into public.ar_recurring_master (name) values ('rm');
`;
let pass = 0, fail = 0; const failures = [];
const ok = (n, c, x = '') => { if (c) { pass++; console.log('  ✅ ' + n); } else { fail++; failures.push(n); console.log('  ❌ ' + n + (x ? ' → ' + x : '')); } };
async function as(db, who, sql) {
  const p = P[who];
  await db.exec(`set role ${p.role}; select set_config('request.jwt.claim.sub', '${p.id}', false), set_config('request.jwt.claim.role', '${p.role}', false);`);
  try { const r = await db.query(sql); return { ok: true, rows: r.rows, n: r.affectedRows ?? r.rows.length }; } catch (e) { return { ok: false, err: String(e.message) }; }
  finally { await db.exec(`reset role; select set_config('request.jwt.claim.sub', '', false), set_config('request.jwt.claim.role', '', false);`); }
}
const cnt = async (db, who, t) => { const r = await as(db, who, `select count(*)::int n from public.${t}`); return r.ok ? r.rows[0].n : 'DENIED'; };
const sup = async (db, sql) => (await db.query(sql)).rows;
const snap = async (db) => JSON.stringify([await sup(db, `select tablename, policyname, cmd, roles::text, qual, with_check from pg_policies where schemaname='public' order by 1,2`), await sup(db, `select table_name, grantee, privilege_type from information_schema.role_table_grants where table_schema='public' and table_name like any (array['kd\\_%','ar\\_%']) order by 1,2,3`)]);

const db = new PGlite(); await db.exec(BASE); await db.exec(ORIG); await db.exec(SEED);
console.log('■ 入金まわりの既存の権限漏れの修正');
// 適用前: 漏れの再現
ok('【適用前の漏れ】アルバイトでも ar_deposits を全件読め、登録・削除もできる', (await cnt(db, 'al', 'ar_deposits')) === 3 && (await as(db, 'al', `insert into public.ar_deposits (receivable_id, amount) values ('${ID.r1}', 9)`)).ok && (await as(db, 'al', `delete from public.ar_deposits where amount = 9`)).ok);
ok('【適用前の漏れ】法人限定の本部・チーム長が、他法人の kd_deposit_daily を読める', (await cnt(db, 'hqL', 'kd_deposit_daily')) === 2 && (await cnt(db, 'teamL', 'kd_deposit_daily')) === 2);
ok('【適用前の漏れ】ログインなし(anon)・ログイン済みに TRUNCATE などの不要な権限がある', (await sup(db, `select has_table_privilege('anon','public.kd_deposit_daily','TRUNCATE') a, has_table_privilege('authenticated','public.ar_deposits','TRUNCATE') b`))[0].a === true);
const before = await snap(db);
const ap = await db.exec(FIX).then(() => ({ ok: true }), (e) => ({ ok: false, err: String(e.message) })); ok('修正SQLが流れる', ap.ok, ap.err);
ok('2 回流しても同じ', await db.exec(FIX).then(() => true, () => false));
// ar_*
const ar = {}; for (const w of ['ceo', 'master', 'hqU', 'hqL', 'teamU', 'teamL', 'tencho', 'ovr', 'shain', 'al', 'anon']) ar[w] = await cnt(db, w, 'ar_deposits');
ok('ar_deposits: 社長・マスター・法人の限定が無い本部・許可つき社員は全件（3）、法人限定の本部は自法人の請求の分だけ（1）', ar.ceo === 3 && ar.master === 3 && ar.hqU === 3 && ar.ovr === 3 && ar.hqL === 1, JSON.stringify(ar));
ok('ar_deposits: チーム長・店長・社員（許可なし）・アルバイト・ログインなしは見えない／触れない', ['teamU', 'teamL', 'tencho', 'shain', 'al'].every((w) => ar[w] === 0) && ar.anon === 'DENIED', JSON.stringify(ar));
const others = {}; for (const t of ['ar_receivables', 'ar_matching', 'ar_receivable_attachments', 'ar_recurring_master']) others[t] = [await cnt(db, 'hqU', t), await cnt(db, 'hqL', t), await cnt(db, 'al', t), await cnt(db, 'ovr', t)];
ok('ar_receivables・ar_matching・添付は同じ規則（全件／自法人／0／全件）。繰り返し設定は請求書の利用者全員', JSON.stringify(others) === JSON.stringify({ ar_receivables: [3, 1, 0, 3], ar_matching: [2, 1, 0, 2], ar_receivable_attachments: [2, 1, 0, 2], ar_recurring_master: [1, 1, 0, 1] }), JSON.stringify(others));
ok('書き込み: 本部（限定なし）は実入金を登録・変更・削除できる（画面の操作は妨げない）', (await as(db, 'hqU', `insert into public.ar_deposits (receivable_id, amount) values ('${ID.r2}', 20)`)).ok && (await as(db, 'hqU', `update public.ar_deposits set amount = 21 where amount = 20`)).n === 1 && (await as(db, 'hqU', `delete from public.ar_deposits where amount = 21`)).n === 1);
ok('書き込み: 法人限定の本部は、他法人・法人未確定の請求への実入金の登録も、変更・削除もできない（自法人はできる）', !(await as(db, 'hqL', `insert into public.ar_deposits (receivable_id, amount) values ('${ID.r2}', 30)`)).ok && !(await as(db, 'hqL', `insert into public.ar_deposits (receivable_id, amount) values ('${ID.r3}', 30)`)).ok
  && (await as(db, 'hqL', `update public.ar_deposits set amount = 5 where receivable_id = '${ID.r2}'`)).n === 0 && (await as(db, 'hqL', `delete from public.ar_deposits where receivable_id = '${ID.r2}'`)).n === 0 && (await as(db, 'hqL', `insert into public.ar_deposits (receivable_id, amount) values ('${ID.r1}', 31)`)).ok);
ok('書き込み: アルバイト・店長・チーム長は、登録も変更も削除もできない', (await Promise.all(['al', 'tencho', 'teamU', 'shain'].map(async (w) => !(await as(db, w, `insert into public.ar_deposits (receivable_id, amount) values ('${ID.r1}', 40)`)).ok && (await as(db, w, `update public.ar_deposits set amount = 0`)).n === 0 && (await as(db, w, `delete from public.ar_deposits`)).n === 0))).every(Boolean));
// kd_*
const kd = {}; for (const w of ['ceo', 'master', 'hqU', 'hqL', 'teamU', 'teamL', 'tencho', 'shain', 'al', 'anon']) kd[w] = [await cnt(db, w, 'kd_deposit_daily'), await cnt(db, w, 'kd_deposit_monthly_summary')];
ok('kd_deposit_*: 社長・マスター・限定の無い本部・チーム長は全店（各 2）、法人限定の本部・チーム長は自法人（各 1）、店長は担当店（各 1）', ['ceo', 'master', 'hqU', 'teamU'].every((w) => kd[w][0] === 2 && kd[w][1] === 2) && ['hqL', 'teamL', 'tencho'].every((w) => kd[w][0] === 1 && kd[w][1] === 1), JSON.stringify(kd));
ok('kd_deposit_*: 社員・アルバイトは従来どおり見えない／ログインなしは拒否', kd.shain[0] === 0 && kd.al[0] === 0 && kd.anon[0] === 'DENIED');
const v = {}; for (const w of ['hqU', 'hqL', 'tencho']) v[w] = [await cnt(db, w, 'kd_deposit_daily_v'), await cnt(db, w, 'kd_deposit_carry_v')];
ok('ビュー kd_deposit_daily_v・kd_deposit_carry_v も、同じ規則で絞られる（ビュー経由の抜け道がない）', JSON.stringify(v) === JSON.stringify({ hqU: [2, 2], hqL: [1, 1], tencho: [1, 1] }), JSON.stringify(v));
ok('kd_deposit_*: 書き込みはできない（社長でも。集計の取込はサービスロールだけ）', !(await as(db, 'ceo', `insert into public.kd_deposit_daily (store_id, corporation_id, deposit_date, amount) values ('${ID.A1}','${ID.c1}','2026-11-02',1)`)).ok && !(await as(db, 'ceo', `delete from public.kd_deposit_daily`)).ok);
ok('サービスロール（取込・Edge Function）は、従来どおり全件の読み書きができる', (await cnt(db, 'service', 'kd_deposit_daily')) === 2 && (await cnt(db, 'service', 'ar_deposits')) === 4 && (await as(db, 'service', `insert into public.kd_deposit_daily (store_id, corporation_id, deposit_date, amount) values ('${ID.A1}','${ID.c1}','2026-11-03',1)`)).ok);
ok('不要な権限が外れている（anon は全て無し、authenticated は TRUNCATE・REFERENCES・TRIGGER 無し・kd_* は書き込み無し）', await (async () => { const r = (await sup(db, `select has_table_privilege('anon','public.kd_deposit_daily','SELECT') a1, has_table_privilege('anon','public.ar_deposits','SELECT') a2, has_table_privilege('authenticated','public.kd_deposit_daily','TRUNCATE') t1, has_table_privilege('authenticated','public.ar_deposits','TRUNCATE') t2, has_table_privilege('authenticated','public.kd_deposit_daily','INSERT') i1, has_table_privilege('authenticated','public.ar_deposits','INSERT') i2, has_table_privilege('authenticated','public.kd_deposit_daily','SELECT') s1`))[0]; return !r.a1 && !r.a2 && !r.t1 && !r.t2 && !r.i1 && r.i2 && r.s1; })());
// ロールバック
await db.exec(`delete from public.ar_deposits where amount in (31)`);
const rb = await db.exec(FIX_RB).then(() => ({ ok: true }), (e) => ({ ok: false, err: String(e.message) })); ok('ロールバックが通る', rb.ok, rb.err);
const afterRb = await snap(db);
ok('ロールバックで、ポリシーと権限が適用前と完全に同じ', JSON.stringify(JSON.parse(afterRb)[0]) === JSON.stringify(JSON.parse(before)[0]) && JSON.stringify(JSON.parse(afterRb)[1]) === JSON.stringify(JSON.parse(before)[1]));
ok('ロールバック後、もう一度適用できる', await db.exec(FIX).then(() => true, () => false));
console.log(`\n==== 結果: ${pass} 件 OK ／ ${fail} 件 NG ====`); if (fail) { console.log(failures.join('\n')); process.exit(1); }
