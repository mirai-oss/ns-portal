-- 2026-09-08 担当B（nippo）
-- ユーザー要望「現金手渡しの人のリストを店舗ごとに振り分けて、渡した人・受け取った人が
-- それぞれ電子サインできるようにしたい。給与仕訳や会計が見れない権限の人でも、店長以上なら
-- このタブと電子サインの場所を使えるようにしたい」に対応。
--
-- 設計方針: invoices.html（給与仕訳・会計。閲覧権限が絞られている）とは別に、nippo側に
-- 独立した画面を作る。対象者一覧はpayroll_bank_accounts（担当C所有・現状はmaster/HQのみ
-- 閲覧可）を直接読ませるのではなく、必要な3項目（対象者・店舗・金額）だけを返す
-- security definerのRPCを新設し、店長・チーム長でも安全に一覧を作れるようにする。
-- 完了時のpayroll_journal_records（担当C所有）への書き込みも同様にRPC経由に限定する
-- （他チームのテーブルへ直接updateはせず、狭い入口のRPCだけを用意する）。

-- ① 現金手渡しサインの記録テーブル
create table if not exists sf_cash_handoff_signatures (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id),
  year_month text not null,
  store_id uuid references stores(id),
  amount numeric not null default 0,
  amount_confirmed boolean not null default false,
  payer_id uuid references users(id),
  payer_checked_at timestamptz,
  payer_signature_path text,
  receiver_checked_at timestamptz,
  receiver_signature_path text,
  completed_at timestamptz,
  created_by uuid references users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, year_month)
);
comment on table sf_cash_handoff_signatures is '現金手渡し給与の受け渡し確認・電子サイン記録（担当B・nippo所有）';

alter table sf_cash_handoff_signatures enable row level security;
drop policy if exists cash_handoff_rw on sf_cash_handoff_signatures;
create policy cash_handoff_rw on sf_cash_handoff_signatures for all using (
  exists(select 1 from users u where u.id = auth.uid() and u.is_active and (
    u.is_master or u.role in ('CEO','HQ') or
    -- 店長・チーム長は自分の店舗ぶんだけ（team_store_ids/user_store_idsは既存の共通関数）
    ((u.role in ('TENCHO','TEAM')) and store_id = any(
      case when u.role = 'TEAM' then team_store_ids(u.team_id) else user_store_ids(u.id) end
    ))
  ))
) with check (
  exists(select 1 from users u where u.id = auth.uid() and u.is_active and (
    u.is_master or u.role in ('CEO','HQ') or
    ((u.role in ('TENCHO','TEAM')) and store_id = any(
      case when u.role = 'TEAM' then team_store_ids(u.team_id) else user_store_ids(u.id) end
    ))
  ))
);

-- ② 対象者一覧を作るRPC（payroll_bank_accountsを直接公開しない・3項目だけ返す）
-- 店舗はuser_stores（複数所属の場合は最初の1件）から決める。RLSで店長・チーム長は
-- 自店舗の人だけに絞られる設計のため、ここでは全件返し、絞り込みはRLS/呼び出し側に任せる
create or replace function public.cash_handoff_targets(p_year_month text)
returns table(user_id uuid, name text, store_id uuid, amount numeric, is_active boolean)
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if not exists(select 1 from users where id = auth.uid() and is_active and (
    is_master or role in ('CEO','HQ','TENCHO','TEAM')
  )) then
    raise exception '権限がありません';
  end if;
  return query
    select u.id, u.name,
      (select us.store_id from user_stores us where us.user_id = u.id order by us.is_primary desc limit 1),
      coalesce(s.net_pay, 0),
      u.is_active
    from payroll_bank_accounts pba
    join users u on u.id = pba.user_id
    left join sf_payroll_sync s on s.user_id = u.id and s.year_month = p_year_month
    where pba.payment_method = 'cash';
end;
$function$;
grant execute on function public.cash_handoff_targets(text) to authenticated;

-- ③ 完了処理（両者の確認・サイン後）: 完了時刻を記録し、給与仕訳の振込レコードが
-- 既にあれば「振込完了」にする（payroll_journal_records.paid_at。担当C側の会計ダッシュボード・
-- 給与仕訳一覧の状態表示はこの列を見ているため、ここをセットするだけで自動的に反映される）
create or replace function public.cash_handoff_complete(p_user_id uuid, p_year_month text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_row sf_cash_handoff_signatures%rowtype; v_synced_rows integer := 0;
begin
  if not exists(select 1 from users where id = auth.uid() and is_active and (
    is_master or role in ('CEO','HQ','TENCHO','TEAM')
  )) then
    raise exception '権限がありません';
  end if;
  select * into v_row from sf_cash_handoff_signatures where user_id = p_user_id and year_month = p_year_month;
  if v_row.id is null then
    raise exception '対象の記録が見つかりません';
  end if;
  if v_row.payer_checked_at is null or v_row.receiver_checked_at is null then
    raise exception '渡した側・受け取った側、両方の確認が必要です';
  end if;
  update sf_cash_handoff_signatures set completed_at = now(), updated_at = now()
   where id = v_row.id;
  begin
    update payroll_journal_records set paid_at = now(), paid_by = auth.uid()
     where user_id = p_user_id and year_month = p_year_month and paid_at is null;
    get diagnostics v_synced_rows = row_count;
  exception when undefined_table then v_synced_rows := 0;
  end;
  return jsonb_build_object('ok', true, 'journal_marked_paid', v_synced_rows > 0);
end;
$function$;
grant execute on function public.cash_handoff_complete(uuid, text) to authenticated;

-- ④ サイン画像の保管バケット（payroll-pdfsと同じ非公開バケット方針）
-- パス規約: {user_id}/{year_month}_payer.png・{user_id}/{year_month}_receiver.png
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('cash-signatures', 'cash-signatures', false, 2097152, array['image/png'])
on conflict (id) do update set allowed_mime_types = array['image/png'];

drop policy if exists cash_sig_rw on storage.objects;
create policy cash_sig_rw on storage.objects for all using (
  bucket_id = 'cash-signatures' and exists(select 1 from users u where u.id = auth.uid() and u.is_active and (
    u.is_master or u.role in ('CEO','HQ','TENCHO','TEAM')
  ))
) with check (
  bucket_id = 'cash-signatures' and exists(select 1 from users u where u.id = auth.uid() and u.is_active and (
    u.is_master or u.role in ('CEO','HQ','TENCHO','TEAM')
  ))
);
