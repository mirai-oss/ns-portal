-- 2026-09-10: チーム長（role=TEAM）の店舗スコープに「所属店舗（user_stores）」も含める
-- （担当C・ns-portal/nippo。ユーザー要望対応）
--
-- ユーザー要望（原文）:
-- 「基本的に店舗名が入っているものに関しては、全てマスターの店舗とマッピングさせて
-- 自動で連携されるようにしてほしい。所属チームが入ってなかったとしても、所属店舗に
-- 入ってればその店舗の現金手当が出るようにしてほしい」
--
-- 従来はrole=TEAM（チーム長）の店舗スコープをteam_store_ids(team_id)だけで決めていた
-- （team_storesテーブル。編集UIが無く、2026-09-10付の修正でユーザー編集画面の「所属店舗」
-- 保存時に作り直すようにしたばかり）。この要望は「所属チームが未設定でも、本人の
-- 所属店舗（user_stores）が入っていればそれも見てほしい」という、より緩やかな
-- フォールバックを求めるもの。team_store_idsとuser_store_idsの両方をOR（配列結合）で
-- 見るように変更し、どちらか一方だけ設定されていても正しく動くようにする。
--
-- 対象2関数（team_store_idsを参照している全関数。pg_proc.prosrc ilike '%team_store_ids%'
-- で確認済み）:
--   - cash_handoff_targets: 現金手渡し・サインの対象者一覧
--   - can_view: 日報等の閲覧権限判定（チーム長は担当店舗ぶん閲覧できる）

create or replace function public.cash_handoff_targets(p_year_month text)
 returns table(user_id uuid, name text, store_id uuid, amount numeric, is_active boolean)
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_caller users%rowtype; v_stores uuid[];
begin
  select * into v_caller from users u0 where u0.id = auth.uid() and u0.is_active;
  if v_caller.id is null or not (v_caller.is_master or v_caller.role in ('CEO','HQ','TENCHO','TEAM')) then
    raise exception '権限がありません';
  end if;
  if v_caller.is_master or v_caller.role in ('CEO','HQ') then
    v_stores := null; -- 全店舗
  elsif v_caller.role = 'TEAM' then
    -- 2026-09-10修正: 所属チーム（team_stores）が未設定・不完全でも、本人の所属店舗
    -- （user_stores）が入っていればその店舗ぶんは出るよう、両方をOR（配列結合）で見る
    v_stores := team_store_ids(v_caller.team_id) || user_store_ids(v_caller.id);
  else
    v_stores := user_store_ids(v_caller.id);
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

create or replace function public.can_view(p_viewer uuid, p_author uuid)
 returns boolean
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  v users%rowtype;
  a users%rowtype;
  po permission_overrides%rowtype;
  v_stores uuid[]; a_stores uuid[];
begin
  if p_viewer = p_author then return true; end if;
  select * into v from users where id = p_viewer;
  select * into a from users where id = p_author;
  if v.id is null or a.id is null then return false; end if;

  -- 社長は全員分
  if v.role = 'CEO' then return true; end if;

  -- v2.6.25 外販は自分のぶんだけ（他の人の日報は見えない）
  if v.role = 'GAIHAN' then return false; end if;
  -- 外販の日報は、社長・本部だけが見られる
  if a.role = 'GAIHAN' then return v.role = 'HQ'; end if;

  -- v2.6.28 本部・社長の日報は、社長だけが見られる（社長は上で true 済み）
  if a.role in ('HQ','CEO') then return false; end if;

  -- 社長による上書き設定
  select * into po from permission_overrides where role = v.role;
  if po.role is not null then
    if po.mode = 'all' then return true; end if;
    if po.mode = 'stores' and (user_store_ids(p_author) && po.store_ids) then return true; end if;
  end if;

  -- v2.6.28 部下は上長の日報を見られない（同格まではOK）
  if role_rank(a.role) > role_rank(v.role) then return false; end if;

  -- v2.6.28 同じ店舗なら全員分見られる（チーム長は担当店舗）
  -- 2026-09-10修正: チーム長は所属チーム（team_stores）だけでなく、本人の所属店舗
  -- （user_stores）も見る（所属チーム未設定・不完全でも動くように）
  if v.role = 'TEAM' then
    v_stores := team_store_ids(v.team_id) || user_store_ids(p_viewer);
  else
    v_stores := user_store_ids(p_viewer);
  end if;
  a_stores := user_store_ids(p_author);
  return v_stores && a_stores;
end $function$;
