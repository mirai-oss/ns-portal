-- ============================================================
-- 2026-10-17 担当B（nippo）— 賃金設定（時給・月給）を管理システムで持ち、スマレジ・タイムカードへ自動反映する土台
-- 【状態】事前報告（ユーザー確認待ち・未適用）。前提: 担当D Phase1（smaregi_contracts／employee_smaregi_links）適用済み
--
-- 【理由】ユーザー要望（2026-10-17）: 時給・社員の月給を管理システムの中で入れて、スマレジ・タイムカードへ同期したい。
--   事業所ごとに時給が違う人がいる（ヘルプ先は高め）。スマレジのAPI（従業員賃金設定 POST/PUT /staffs/{id}/wage_apply）で書ける。
--   ※メール・交通費・源泉所得税・個別Web給与明細表示はスマレジAPIに書き込み口が無く、手作業のまま（読み取りのみ可能）。
-- 【現構造】賃金を持つ表は管理システムに無い（時給・月給はスマレジで手入力）。
-- 【変更】
--   ① 新規テーブル employee_wage_settings: 人×契約×区分(0=時給/2=月給)×店舗(空=全事業所共通)×適用開始日 の1行。
--      金額・休日賃金・スマレジ側の賃金設定ID・反映状況(pending/synced/error)を持つ
--   ② RLS: 本部・社長・マスターだけが読める（賃金は機微情報）。書き込みはRPC経由のみ
--   ③ 新RPC hr_save_wage（保存＝反映待ち）／hr_delete_wage（反映前のものだけ削除）
-- 【影響】新規テーブル1・RPC2のみ。既存の表・関数・画面は変えない。スマレジへの実際の反映は画面から smaregi-sync(wage_push) を呼んだときだけ
-- 【migration】本ファイル（冪等）
-- 【rollback】drop function if exists public.hr_save_wage(uuid,text,int,uuid,int,int,date); drop function if exists public.hr_delete_wage(uuid);
--   drop table if exists employee_wage_settings;
-- ============================================================

create table if not exists employee_wage_settings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  contract_id text not null references smaregi_contracts(contract_id),
  division int not null check (division in (0, 2)),         -- 0=時給 / 2=月給
  store_id uuid references stores(id),                       -- 空=全事業所共通。店舗を指定した行はその事業所だけの時給（ヘルプ先など）
  wage int not null check (wage >= 0),
  holiday_wage int check (holiday_wage is null or holiday_wage >= 0), -- 休日賃金（時給のみ）
  effective_date date not null,                              -- 適用開始日（月給は月初日のみ）
  smaregi_wage_apply_id text,                                -- スマレジ側の賃金設定ID（反映後に入る）
  sync_status text not null default 'pending' check (sync_status in ('pending', 'synced', 'error')),
  sync_error text,
  synced_at timestamptz,
  created_by uuid references users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (division = 0 or (store_id is null and holiday_wage is null)) -- 月給に店舗・休日賃金は無い
);
create unique index if not exists employee_wage_settings_key
  on employee_wage_settings (user_id, contract_id, division, coalesce(store_id, '00000000-0000-0000-0000-000000000000'::uuid), effective_date);
create index if not exists employee_wage_settings_user_idx on employee_wage_settings (user_id);
comment on table employee_wage_settings is '賃金設定（時給・月給）。管理システムが正本→スマレジ・タイムカードへwage_applyで反映（担当B・2026-10-17新設）。本部・社長・マスターのみ閲覧。書き込みはRPC/サービスロールのみ';

alter table employee_wage_settings enable row level security;
revoke all on employee_wage_settings from anon;
drop policy if exists employee_wage_settings_read on employee_wage_settings;
create policy employee_wage_settings_read on employee_wage_settings for select to authenticated using (
  exists (select 1 from users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO','HQ'))));
-- insert/update/deleteのポリシーは作らない＝直接の書き込みは全面拒否（下のRPCとEdge Function(service_role)のみ）

-- 保存（同じ 人×契約×区分×店舗×適用開始日 は上書き＝反映待ちに戻す）。本部・社長・マスターのみ
create or replace function public.hr_save_wage(p_user uuid, p_contract text, p_division int, p_store uuid, p_wage int, p_holiday int, p_date date)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_id uuid;
begin
  if not exists(select 1 from users where id = auth.uid() and is_active and (is_master or role in ('CEO','HQ'))) then
    raise exception '権限がありません（本部・社長・マスターのみ）';
  end if;
  if p_division not in (0, 2) then raise exception '給与形態は時給(0)か月給(2)を指定してください'; end if;
  if not exists(select 1 from users where id = p_user) then raise exception '対象の従業員が見つかりません'; end if;
  if not exists(select 1 from smaregi_contracts where contract_id = p_contract and is_active) then raise exception 'スマレジの契約が見つかりません'; end if;
  if p_wage is null or p_wage < 0 or p_wage > 100000000 then raise exception '金額が不正です'; end if;
  if p_date is null or p_date < date '2000-01-01' then raise exception '適用開始日を指定してください'; end if;
  if p_division = 2 then
    if p_store is not null then raise exception '月給は店舗を指定できません'; end if;
    if extract(day from p_date) <> 1 then raise exception '月給の適用開始日は月初日（1日）にしてください'; end if;
    p_holiday := null;
  end if;
  if p_division = 0 and p_wage > 100000 then raise exception '時給が大きすぎます（%円）。月給は「月給」で入力してください', p_wage; end if;
  if p_store is not null and not exists(select 1 from stores where id = p_store) then raise exception '店舗が見つかりません'; end if;
  insert into employee_wage_settings(user_id, contract_id, division, store_id, wage, holiday_wage, effective_date, created_by)
  values (p_user, p_contract, p_division, p_store, p_wage, p_holiday, p_date, auth.uid())
  on conflict (user_id, contract_id, division, coalesce(store_id, '00000000-0000-0000-0000-000000000000'::uuid), effective_date)
  do update set wage = excluded.wage, holiday_wage = excluded.holiday_wage, sync_status = 'pending', sync_error = null, updated_at = now()
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$function$;
revoke all on function public.hr_save_wage(uuid, text, int, uuid, int, int, date) from public, anon;
grant execute on function public.hr_save_wage(uuid, text, int, uuid, int, int, date) to authenticated;

-- 削除（スマレジへ反映済みのものは消せない＝スマレジ側の設定が残ってしまうため）
create or replace function public.hr_delete_wage(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare r employee_wage_settings%rowtype;
begin
  if not exists(select 1 from users where id = auth.uid() and is_active and (is_master or role in ('CEO','HQ'))) then
    raise exception '権限がありません（本部・社長・マスターのみ）';
  end if;
  select * into r from employee_wage_settings where id = p_id for update;
  if r.id is null then raise exception '賃金設定が見つかりません'; end if;
  if r.smaregi_wage_apply_id is not null then raise exception 'スマレジへ反映済みの設定は削除できません（スマレジ側にも残るため）。金額を直して反映してください'; end if;
  delete from employee_wage_settings where id = p_id;
  return jsonb_build_object('ok', true);
end;
$function$;
revoke all on function public.hr_delete_wage(uuid) from public, anon;
grant execute on function public.hr_delete_wage(uuid) to authenticated;
