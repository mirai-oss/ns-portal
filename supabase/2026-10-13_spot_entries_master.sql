-- 【事前報告様式（DB変更）】
-- 目的: スポット人件費(タイミー等)の入力の正本をSupabaseに置く（担当A・2026-10-13・ユーザー指示「GASなしで」）。
--       旧: DB_スポット人件費シート(GAS saveSpotEntry/deleteSpotEntry)→stg_spot→kd。GASの削除が効かない不具合(2026-10-05の編集で行削除が欠落)を契機に脱GAS。
-- 追加（新規のみ）: spot_entries(正本・ソフト削除) / spot_entries_history(履歴) / RPC spot_entry_save, spot_entry_delete
--   内部関数 _spot_pl_rebuild（月次PLの『自動｜スポット人件費』行(L区分)を正本から再計算）、
--   トリガ trg_spot_entries_to_kd（kd_spot_entriesを即時に追従させる＝GASもEdge更新も待たない）。
-- 書込権限: master/CEO/HQ のみ(_pl_scopeと同じ)。service_role可。直接のINSERT/UPDATE/DELETEは不可(RPCのみ)。読取: master/CEO/HQ/TEAM=全件、TENCHO=自店舗。
-- 切替: app_secrets.spot_source='entries'(別途セット)でEdge keiei-kd-refreshがstg_spotではなくspot_entriesから読む。
-- ロールバック: delete from app_secrets where key='spot_source'; drop trigger/function/table（kd_spot_entriesは次回Edge更新でstg_spotから復元）
-- 実行: supabase db query --linked -f supabase/2026-10-13_spot_entries_master.sql

create table if not exists public.spot_entries (
  id text primary key default gen_random_uuid()::text,
  work_date date not null,
  store_id uuid not null references public.stores (id),
  kind text not null default 'タイミー',
  amount numeric not null check (amount > 0),
  headcount numeric,
  memo text not null default '',
  requester text not null default '',
  entered_by text not null default '',
  entered_at timestamptz not null default now(),
  deleted_at timestamptz,
  updated_by text,
  updated_at timestamptz not null default now()
);
create index if not exists spot_entries_date_idx on public.spot_entries (work_date desc) where deleted_at is null;
create index if not exists spot_entries_store_idx on public.spot_entries (store_id, work_date) where deleted_at is null;

create table if not exists public.spot_entries_history (
  id bigint generated always as identity primary key,
  entry_id text not null, op text not null, old_row jsonb, new_row jsonb,
  changed_by text, changed_at timestamptz not null default now()
);
create index if not exists spot_entries_history_entry_idx on public.spot_entries_history (entry_id, changed_at desc);

create or replace function public.trg_spot_entries_history() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_actor text := coalesce(nullif(current_setting('app.actor', true), ''), 'unknown'); v_op text;
begin
  if tg_op = 'INSERT' then
    insert into public.spot_entries_history (entry_id, op, new_row, changed_by) values (new.id, 'insert', to_jsonb(new), v_actor);
  elsif tg_op = 'UPDATE' then
    v_op := case when old.deleted_at is null and new.deleted_at is not null then 'delete' else 'update' end;
    insert into public.spot_entries_history (entry_id, op, old_row, new_row, changed_by) values (new.id, v_op, to_jsonb(old), to_jsonb(new), v_actor);
  end if;
  return null;
end $$;
drop trigger if exists spot_entries_history_trg on public.spot_entries;
create trigger spot_entries_history_trg after insert or update on public.spot_entries for each row execute function public.trg_spot_entries_history();

-- kd_spot_entries(経営ダッシュボードが読む行ミラー)を即時に追従させる
create or replace function public.trg_spot_entries_to_kd() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op in ('UPDATE', 'DELETE') then delete from public.kd_spot_entries where spot_id = old.id; end if;
  if tg_op in ('INSERT', 'UPDATE') and new.deleted_at is null then
    insert into public.kd_spot_entries (spot_id, work_date, store_id, store_name, kind, amount, headcount, memo, entered_by, entered_at)
    select new.id, new.work_date, new.store_id, coalesce(nullif(btrim(s.dash_store_name), ''), s.name), new.kind, new.amount, new.headcount, new.memo,
           new.entered_by, to_char(new.entered_at at time zone 'Asia/Tokyo', 'YYYY-MM-DD HH24:MI')
    from public.stores s where s.id = new.store_id;
  end if;
  return null;
end $$;
drop trigger if exists spot_entries_to_kd_trg on public.spot_entries;
create trigger spot_entries_to_kd_trg after insert or update or delete on public.spot_entries for each row execute function public.trg_spot_entries_to_kd();

alter table public.spot_entries enable row level security;
alter table public.spot_entries_history enable row level security;
drop policy if exists spot_entries_select on public.spot_entries;
create policy spot_entries_select on public.spot_entries for select to authenticated using (
  exists (select 1 from public.users u where u.id = auth.uid() and u.is_active and (
    u.is_master or u.role in ('CEO','HQ','TEAM')
    or (u.role = 'TENCHO' and exists (select 1 from public.user_stores us where us.user_id = u.id and us.store_id = spot_entries.store_id))))
);
drop policy if exists spot_entries_history_select on public.spot_entries_history;
create policy spot_entries_history_select on public.spot_entries_history for select to authenticated using (
  exists (select 1 from public.users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO','HQ')))
);
revoke insert, update, delete on public.spot_entries from anon, authenticated;
revoke insert, update, delete on public.spot_entries_history from anon, authenticated;

-- 月次PLの『自動｜スポット人件費』(L区分)を正本から再計算（店舗×年月）。GAS時代の同名の自動行(source_keyなし)は置き換える
create or replace function public._spot_pl_rebuild(p_ym text, p_store uuid, p_actor text) returns void
language plpgsql security definer set search_path = public as $$
declare v_sum numeric; v_key text := 'spot:' || p_ym || ':' || p_store::text; v_actor text := coalesce(nullif(btrim(p_actor), ''), 'spot');
begin
  perform set_config('app.actor', v_actor, true);
  select coalesce(sum(amount), 0) into v_sum from public.spot_entries
    where deleted_at is null and store_id = p_store and to_char(work_date, 'YYYY-MM') = p_ym;
  update public.pl_entries set deleted_at = now(), updated_at = now(), updated_by = v_actor
    where deleted_at is null and source = '自動｜スポット人件費' and year_month = p_ym and store_id = p_store and source_key is null;
  if v_sum > 0 then
    update public.pl_entries set amount = v_sum, updated_at = now(), updated_by = v_actor where source_key = v_key and deleted_at is null;
    if not found then
      insert into public.pl_entries (year_month, store_id, item, category, amount, memo, sub_item, source, source_key, created_by, updated_by)
        values (p_ym, p_store, 'スポット人件費', 'L', v_sum, '自動｜スポット人件費', '', '自動｜スポット人件費', v_key, v_actor, v_actor);
    end if;
  else
    update public.pl_entries set deleted_at = now(), updated_at = now(), updated_by = v_actor where source_key = v_key and deleted_at is null;
  end if;
end $$;
revoke all on function public._spot_pl_rebuild(text, uuid, text) from public, anon, authenticated;
grant execute on function public._spot_pl_rebuild(text, uuid, text) to service_role;

-- 保存（追加・修正）。p_idが空=追加。店舗は名前で渡す（表記ゆれは_pl_resolve_storeが吸収）
create or replace function public.spot_entry_save(p_id text, p_store_name text, p_date date, p_kind text, p_amount numeric,
  p_headcount numeric default null, p_memo text default '', p_requester text default '', p_actor text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare sc jsonb := public._pl_scope(p_actor); v_actor text := sc->>'actor'; v_store uuid; v_id text := nullif(btrim(coalesce(p_id, '')), ''); ex record;
  v_kind text := coalesce(nullif(left(btrim(coalesce(p_kind, '')), 20), ''), 'タイミー');
begin
  if sc->>'kind' = 'none' then return jsonb_build_object('ok', false, 'error', '権限がありません（社長・本部のみ）'); end if;
  if p_date is null then return jsonb_build_object('ok', false, 'error', '日付が不正です'); end if;
  if p_amount is null or p_amount <= 0 then return jsonb_build_object('ok', false, 'error', '金額を入力してください'); end if;
  if p_date < date '2015-01-01' or p_date > (now() at time zone 'Asia/Tokyo')::date + 366 then return jsonb_build_object('ok', false, 'error', '日付が範囲外です'); end if;
  v_store := public._pl_resolve_store(p_store_name);
  if v_store is null then return jsonb_build_object('ok', false, 'error', '店舗を特定できません: ' || coalesce(p_store_name, '(空)')); end if;
  perform set_config('app.actor', v_actor, true);
  if v_id is not null then
    select * into ex from public.spot_entries where id = v_id and deleted_at is null;
    if not found then return jsonb_build_object('ok', false, 'error', '該当データが見つかりません（削除済みの可能性）'); end if;
    update public.spot_entries set work_date = p_date, store_id = v_store, kind = v_kind, amount = p_amount, headcount = p_headcount,
      memo = left(coalesce(p_memo, ''), 200), requester = coalesce(p_requester, requester), updated_at = now(), updated_by = v_actor where id = v_id;
    if to_char(ex.work_date, 'YYYY-MM') <> to_char(p_date, 'YYYY-MM') or ex.store_id <> v_store then
      perform public._spot_pl_rebuild(to_char(ex.work_date, 'YYYY-MM'), ex.store_id, v_actor);
    end if;
  else
    insert into public.spot_entries (work_date, store_id, kind, amount, headcount, memo, requester, entered_by, updated_by)
      values (p_date, v_store, v_kind, p_amount, p_headcount, left(coalesce(p_memo, ''), 200), coalesce(p_requester, ''), v_actor, v_actor) returning id into v_id;
  end if;
  perform public._spot_pl_rebuild(to_char(p_date, 'YYYY-MM'), v_store, v_actor);
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;
revoke all on function public.spot_entry_save(text, text, date, text, numeric, numeric, text, text, text) from public, anon;
grant execute on function public.spot_entry_save(text, text, date, text, numeric, numeric, text, text, text) to authenticated, service_role;

-- 削除（ソフト削除。履歴に残る）
create or replace function public.spot_entry_delete(p_id text, p_actor text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare sc jsonb := public._pl_scope(p_actor); v_actor text := sc->>'actor'; ex record;
begin
  if sc->>'kind' = 'none' then return jsonb_build_object('ok', false, 'error', '権限がありません（社長・本部のみ）'); end if;
  select * into ex from public.spot_entries where id = nullif(btrim(coalesce(p_id, '')), '') and deleted_at is null;
  if not found then return jsonb_build_object('ok', false, 'error', '該当データが見つかりません'); end if;
  perform set_config('app.actor', v_actor, true);
  update public.spot_entries set deleted_at = now(), updated_at = now(), updated_by = v_actor where id = ex.id;
  perform public._spot_pl_rebuild(to_char(ex.work_date, 'YYYY-MM'), ex.store_id, v_actor);
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.spot_entry_delete(text, text) from public, anon;
grant execute on function public.spot_entry_delete(text, text) to authenticated, service_role;

comment on table public.spot_entries is 'スポット人件費の正本（2026-10-13）。書込はRPC(spot_entry_save/delete)のみ。kd_spot_entries/PL自動行はここから作る';
