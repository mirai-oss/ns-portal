-- 2026-09-14: 現金手渡し・サイン画面（nippo index.html cashHandoffView・DB関数
-- cash_handoff_targets）の「役職ごとにどこまでの店舗が見えるか」を、コード直書きから
-- テーブル設定へ切り替える。担当C（ns-portal・請求書/MF連携）が、ns-portalとnippoが
-- 共有する同一Supabaseプロジェクトに対して、ユーザーからの直接依頼により対応。
--
-- 【なぜ必要か】
-- ユーザー指示「手渡し給料の表示される役職毎の権限を選べるようにしたい。取り急ぎチーム長は
-- 全ての店舗の手渡し給料を見れるようにして欲しい」。現行のcash_handoff_targets関数は
-- 役職ごとの店舗閲覧範囲（全店舗/チーム店舗+自店舗/自店舗のみ）がplpgsql内にif分岐で
-- 直書きされており、変更のたびにコードデプロイ（関数の再作成）が必要だった。
--
-- 【現在の構造】
-- cash_handoff_targets(p_year_month)関数：呼び出し元の役職により
--   is_master/CEO/HQ → 全店舗（v_stores=null）
--   TEAM（チーム長）  → 所属チームの店舗 ∪ 本人の所属店舗（team_store_ids ∪ user_store_ids）
--   その他（TENCHO等）→ 本人の所属店舗のみ（user_store_ids）
-- という分岐がハードコードされている。呼び出し元はnippo（index.html cashHandoffView）の
-- 「💴現金手渡し・サイン」画面のみ（他に利用箇所なし・grep確認済み）。
--
-- 【今回の変更】
-- 1. 新設テーブルcash_handoff_role_scope（role→scope('all'|'team'|'own')の設定値）を作り、
--    今回の依頼どおりTEAMの初期値を'all'にして投入する（他の役職は現状の挙動を維持する値で
--    投入＝実質的な閲覧範囲の変化はTEAMのみ。CEO/HQはmasterと同じ全店舗のため'all'、
--    TENCHOは元々自店舗のみだったため'own'）。
-- 2. cash_handoff_targets関数を、if分岐の代わりにこのテーブルを参照する形に書き換える
--    （関数のシグネチャ・戻り値・呼び出し元への影響は無い＝nippo側のコード変更は不要）。
--    is_masterは安全のため引き続きテーブル設定に関わらず常に全店舗（テーブルに行が無い/
--    誤って行を消してしまった場合の保険）。テーブルに行が無い役職は最も安全側の'own'に
--    フォールバックする。
--
-- 【既存データへの影響】無し（新規テーブル1件・既存関数の書き換えのみ。既存テーブルの
-- 行・列に対する変更は無い）
-- 【migration】このファイル自体（CREATE TABLE + INSERT + CREATE OR REPLACE FUNCTION。
-- INSERTはon conflict do nothingで冪等）
-- 【rollback】関数を元のIF分岐版に戻す（本ファイルのコメントに元の定義を残してあるので、
-- それをそのままCREATE OR REPLACE FUNCTIONし直せば良い）。テーブルは
-- drop table if exists cash_handoff_role_scope; で削除可（他から参照されない）
-- 【既存機能への影響】TEAM（チーム長）ロールの閲覧範囲が「チーム店舗+自店舗」→「全店舗」に
-- 拡大する（今回のユーザー指示どおりの意図した変更）。CEO/HQ/TENCHO/master・現金手渡し
-- 機能自体の操作（サイン・引き出し確認等）のロジックには一切影響しない

create table if not exists cash_handoff_role_scope (
  role text primary key,
  scope text not null check (scope in ('all','team','own')),
  updated_at timestamptz not null default now(),
  note text
);
comment on table cash_handoff_role_scope is
  '現金手渡し・サイン画面（nippo）で、各役職がどこまでの店舗の対象者を閲覧できるかの設定。
   scope: all=全店舗／team=所属チームの店舗+自店舗／own=自店舗のみ。
   masterは常に全店舗（この設定に関わらず）。行が無い役職はownにフォールバックする。';

insert into cash_handoff_role_scope (role, scope, note) values
  ('CEO', 'all', '元々全店舗（is_masterと同じ扱い）'),
  ('HQ', 'all', '元々全店舗（is_masterと同じ扱い）'),
  ('TEAM', 'all', '2026-09-14ユーザー指示により、チーム店舗+自店舗→全店舗へ変更'),
  ('TENCHO', 'own', '元々自店舗のみ（変更なし）')
on conflict (role) do nothing;

-- 元の定義（rollback用に残す）:
-- create or replace function public.cash_handoff_targets(p_year_month text)
--  returns table(user_id uuid, name text, store_id uuid, amount numeric, is_active boolean)
--  language plpgsql security definer set search_path to 'public' as $function$
-- declare v_caller users%rowtype; v_stores uuid[];
-- begin
--   select * into v_caller from users u0 where u0.id = auth.uid() and u0.is_active;
--   if v_caller.id is null or not (v_caller.is_master or v_caller.role in ('CEO','HQ','TENCHO','TEAM')) then
--     raise exception '権限がありません';
--   end if;
--   if v_caller.is_master or v_caller.role in ('CEO','HQ') then
--     v_stores := null;
--   elsif v_caller.role = 'TEAM' then
--     v_stores := team_store_ids(v_caller.team_id) || user_store_ids(v_caller.id);
--   else
--     v_stores := user_store_ids(v_caller.id);
--   end if;
--   return query
--     select u.id, u.name,
--       (select us.store_id from user_stores us where us.user_id = u.id order by us.is_primary desc limit 1),
--       coalesce(s.net_pay, 0), u.is_active
--     from payroll_bank_accounts pba
--     join users u on u.id = pba.user_id
--     left join sf_payroll_sync s on s.user_id = u.id and s.year_month = p_year_month
--     where pba.payment_method = 'cash'
--       and (v_stores is null or (select us2.store_id from user_stores us2 where us2.user_id = u.id order by us2.is_primary desc limit 1) = any(v_stores));
-- end; $function$

create or replace function public.cash_handoff_targets(p_year_month text)
 returns table(user_id uuid, name text, store_id uuid, amount numeric, is_active boolean)
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_caller users%rowtype; v_stores uuid[]; v_scope text;
begin
  select * into v_caller from users u0 where u0.id = auth.uid() and u0.is_active;
  if v_caller.id is null or not (v_caller.is_master or v_caller.role in ('CEO','HQ','TENCHO','TEAM')) then
    raise exception '権限がありません';
  end if;

  if v_caller.is_master then
    v_stores := null; -- masterは設定テーブルに関わらず常に全店舗（安全側の固定）
  else
    select scope into v_scope from cash_handoff_role_scope where role = v_caller.role;
    v_scope := coalesce(v_scope, 'own'); -- 設定が無い役職は最も安全側（自店舗のみ）にフォールバック
    if v_scope = 'all' then
      v_stores := null;
    elsif v_scope = 'team' then
      v_stores := team_store_ids(v_caller.team_id) || user_store_ids(v_caller.id);
    else
      v_stores := user_store_ids(v_caller.id);
    end if;
  end if;

  return query
    select u.id, u.name,
      (select us.store_id from user_stores us where us.user_id = u.id order by us.is_primary desc limit 1),
      coalesce(s.net_pay, 0),
      u.is_active
    from payroll_bank_accounts pba
    join users u on u.id = pba.user_id
    left join sf_payroll_sync s on s.user_id = u.id and s.year_month = p_year_month
    where pba.payment_method = 'cash'
      and (v_stores is null or (select us2.store_id from user_stores us2 where us2.user_id = u.id order by us2.is_primary desc limit 1) = any(v_stores));
end;
$function$;
