-- 【事前報告様式（DB変更）】
-- 目的: F3「PL販管費入力のSupabase正本化」の土台（担当A設計・2026-10-06）。DB_PLシート→stg_pl→kd の経路が人の編集（年月列の空欄化）で
--       全部崩れた事故を受け、入力の正本をSupabaseに置く。年月・店舗・科目・区分・金額はDBが入力時に検証して不正行は入れない。
-- 追加（新規のみ・既存テーブル/RLS/列の変更なし）:
--   pl_entries          … PL販管費の正本（1行=1明細。ソフト削除=deleted_at）
--   pl_entries_history  … 変更履歴（トリガで自動記録。誰が・いつ・前後の値）
--   RPC: pl_entries_bulk_upsert（検証つき一括登録。dry_runで事前検証だけも可）/ pl_entries_delete / pl_entries_export /
--        pl_entries_import_from_kd（移行時に1回だけ。kd_pl_entriesからの取り込み）
-- 書込権限: master/CEO/HQ=全店・全社共通・自動行すべて、TENCHO=自店舗の手入力行のみ（現行GASの scopeAllows_ と同じ）、他は不可。service_role=GAS等の自動連携（p_actorで実行者名を記録）。
-- 直接のINSERT/UPDATE/DELETEはRLSで不可（必ずRPC経由）。読取は master/CEO/HQ/TEAM=全件、TENCHO=自店舗＋全社共通行（現行bqGetPLと同じ）。
-- ロールバック: drop function pl_entries_*; drop table pl_entries_history, pl_entries;
-- 実行: supabase db query --linked -f supabase/2026-10-06_pl_entries_master.sql

create table if not exists public.pl_entries (
  id uuid primary key default gen_random_uuid(),
  year_month text not null check (year_month ~ '^\d{4}-(0[1-9]|1[0-2])$'),
  store_id uuid references public.stores (id),            -- null=全社共通
  item text not null check (length(btrim(item)) > 0),      -- 勘定科目
  category text not null check (category in ('S','F','L','A','R','O','X')),
  amount numeric not null,
  memo text not null default '',
  sub_item text not null default '',
  source text not null default '手入力',                   -- '手入力' | '自動｜精算書' | '自動｜スポット人件費' …
  source_key text,                                         -- 自動連携の冪等キー（任意。あれば同じキーは1行に保つ）
  deleted_at timestamptz,
  created_by text, updated_by text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists pl_entries_source_key_uq on public.pl_entries (source_key) where source_key is not null and deleted_at is null;
create index if not exists pl_entries_ym_store_idx on public.pl_entries (year_month, store_id) where deleted_at is null;
create index if not exists pl_entries_source_idx on public.pl_entries (source, year_month) where deleted_at is null;

create table if not exists public.pl_entries_history (
  id bigint generated always as identity primary key,
  entry_id uuid not null,
  op text not null,                 -- insert | update | delete(=ソフト削除)
  old_row jsonb, new_row jsonb,
  changed_by text, changed_at timestamptz not null default now()
);
create index if not exists pl_entries_history_entry_idx on public.pl_entries_history (entry_id, changed_at desc);

create or replace function public.trg_pl_entries_history() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_actor text := coalesce(nullif(current_setting('app.actor', true), ''), 'unknown'); v_op text;
begin
  if tg_op = 'INSERT' then
    insert into public.pl_entries_history (entry_id, op, new_row, changed_by) values (new.id, 'insert', to_jsonb(new), v_actor);
  elsif tg_op = 'UPDATE' then
    v_op := case when old.deleted_at is null and new.deleted_at is not null then 'delete' else 'update' end;
    insert into public.pl_entries_history (entry_id, op, old_row, new_row, changed_by) values (new.id, v_op, to_jsonb(old), to_jsonb(new), v_actor);
  elsif tg_op = 'DELETE' then
    insert into public.pl_entries_history (entry_id, op, old_row, changed_by) values (old.id, 'delete', to_jsonb(old), v_actor);
  end if;
  return null;
end $$;
drop trigger if exists pl_entries_history_trg on public.pl_entries;
create trigger pl_entries_history_trg after insert or update or delete on public.pl_entries for each row execute function public.trg_pl_entries_history();

-- RLS
alter table public.pl_entries enable row level security;
alter table public.pl_entries_history enable row level security;
drop policy if exists pl_entries_select on public.pl_entries;
create policy pl_entries_select on public.pl_entries for select to authenticated using (
  exists (select 1 from public.users u where u.id = auth.uid() and u.is_active and (
    u.is_master or u.role in ('CEO','HQ','TEAM')
    or (u.role = 'TENCHO' and (pl_entries.store_id is null
         or exists (select 1 from public.user_stores us where us.user_id = u.id and us.store_id = pl_entries.store_id)))
  ))
);
drop policy if exists pl_entries_history_select on public.pl_entries_history;
create policy pl_entries_history_select on public.pl_entries_history for select to authenticated using (
  exists (select 1 from public.users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO','HQ')))
);
revoke insert, update, delete on public.pl_entries from anon, authenticated;
revoke insert, update, delete on public.pl_entries_history from anon, authenticated;

-- 実行者の権限判定。kind: service(GAS等=service_role) / admin(master,CEO,HQ) / tencho(自店舗の手入力のみ) / none
create or replace function public._pl_scope(p_actor text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_claims jsonb; v_role text; u record; v_stores uuid[];
begin
  begin v_claims := nullif(current_setting('request.jwt.claims', true), '')::jsonb; exception when others then v_claims := null; end;
  v_role := coalesce(v_claims->>'role', '');
  if v_role = 'service_role' then
    return jsonb_build_object('kind', 'service', 'actor', coalesce(nullif(btrim(p_actor), ''), 'service'));
  end if;
  select id, name, role, is_master, is_active into u from public.users where id = auth.uid();
  if not found or not u.is_active then return jsonb_build_object('kind', 'none', 'actor', ''); end if;
  if u.is_master or u.role in ('CEO','HQ') then
    return jsonb_build_object('kind', 'admin', 'actor', u.id::text || ':' || coalesce(u.name, ''));
  end if;
  if u.role = 'TENCHO' then
    select coalesce(array_agg(store_id), '{}') into v_stores from public.user_stores where user_id = u.id;
    return jsonb_build_object('kind', 'tencho', 'actor', u.id::text || ':' || coalesce(u.name, ''), 'stores', to_jsonb(v_stores));
  end if;
  return jsonb_build_object('kind', 'none', 'actor', '');
end $$;
revoke all on function public._pl_scope(text) from public, anon;
grant execute on function public._pl_scope(text) to authenticated, service_role;

-- 店舗名→store_id（stores.name / dash_store_name / store_aliases kind=name・全角半角括弧とスペースの揺れを吸収）。見つからなければnull
create or replace function public._pl_resolve_store(p_name text) returns uuid
language sql stable security definer set search_path = public as $$
  with n as (select btrim(p_name) as raw, btrim(regexp_replace(regexp_replace(p_name, '[（(）)]', ' ', 'g'), '[\s　]+', ' ', 'g')) as norm)
  select coalesce(
    (select s.id from public.stores s, n where btrim(s.name) in (n.raw, n.norm) or btrim(coalesce(s.dash_store_name,'')) in (n.raw, n.norm) order by s.sort_order limit 1),
    (select a.store_id from public.store_aliases a, n where a.kind = 'name' and btrim(a.alias) in (n.raw, n.norm) limit 1)
  )
$$;
revoke all on function public._pl_resolve_store(text) from public, anon;
grant execute on function public._pl_resolve_store(text) to authenticated, service_role;

-- 一括登録（全か無か: 検証エラーが1行でもあれば何も書かずerrorsを理由つきで返す。p_dry_run=trueなら検証だけ）
-- 行: {id?, year_month, store_id? | store_name?（どちらも空=全社共通）, item, category(S/F/L/A/R/O/X), amount, memo?, sub_item?, source?(既定'手入力'), source_key?}
-- mode:
--   'upsert'              … idがあればその行を更新、なければ（source_keyがあれば同キーを更新、なければ）追加
--   'replace_month_store' … 行に含まれる（年月×店舗）の「手入力」行を、今回の行の集合に揃える（idありは更新・なしは追加・載っていない既存手入力行は削除）。出力→編集→取込用
--   'replace_source'      … 自動連携用。行に含まれる（source×年月）の既存行（全店）を削除して今回の行に差し替え。p_scope=[{source,year_month}]で「行が0でも空にしたい範囲」を追加指定可
create or replace function public.pl_entries_bulk_upsert(p_rows jsonb, p_mode text default 'upsert', p_dry_run boolean default false, p_actor text default null, p_scope jsonb default '[]'::jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  sc jsonb := public._pl_scope(p_actor); kind text := sc->>'kind'; actor text := sc->>'actor';
  my_stores uuid[];
  errs jsonb := '[]'::jsonb; e_count int := 0;
  r jsonb; ord int;
  v_id uuid; v_ym text; v_store uuid; v_sname text; v_item text; v_cat text; v_amt numeric; v_src text; v_key text; v_memo text; v_sub text;
  ex record; ins int := 0; upd int := 0; del int := 0; cnt int; sp record;
  max_ym text := to_char((now() at time zone 'Asia/Tokyo') + interval '10 years', 'YYYY-MM');
begin
  if kind = 'none' then return jsonb_build_object('ok', false, 'error', '権限がありません（ログインが必要、または書込権限がありません）'); end if;
  if p_mode not in ('upsert','replace_month_store','replace_source') then return jsonb_build_object('ok', false, 'error', 'modeは upsert|replace_month_store|replace_source のいずれか'); end if;
  if jsonb_typeof(p_rows) is distinct from 'array' then return jsonb_build_object('ok', false, 'error', 'rowsは配列で渡してください'); end if;
  if jsonb_array_length(p_rows) > 5000 then return jsonb_build_object('ok', false, 'error', '1回の上限は5000行です'); end if;
  if p_mode = 'replace_source' and kind = 'tencho' then return jsonb_build_object('ok', false, 'error', 'replace_sourceは本部/自動連携のみ'); end if;
  if kind = 'tencho' then select coalesce(array_agg(x::uuid), '{}') into my_stores from jsonb_array_elements_text(sc->'stores') x; end if;

  create temp table if not exists _pl_stage (idx int, id uuid, ym text, store_id uuid, item text, cat text, amt numeric, memo text, sub_item text, source text, source_key text) on commit drop;
  truncate _pl_stage;

  for r, ord in select value, ordinality from jsonb_array_elements(p_rows) with ordinality loop
    begin
      v_id := nullif(btrim(coalesce(r->>'id','')), '')::uuid;
      v_ym := btrim(coalesce(r->>'year_month',''));
      v_ym := regexp_replace(v_ym, '^(\d{4})[/.](\d{1,2})$', '\1-\2');
      if v_ym ~ '^\d{4}-\d$' then v_ym := substr(v_ym,1,5) || '0' || substr(v_ym,6); end if;
      if v_ym !~ '^\d{4}-(0[1-9]|1[0-2])$' then raise exception '年月が不正です（YYYY-MM）: %', coalesce(r->>'year_month','(空)'); end if;
      if v_ym < '2015-01' or v_ym > max_ym then raise exception '年月が範囲外です: %', v_ym; end if;
      v_store := null; v_sname := btrim(coalesce(r->>'store_name',''));
      if nullif(btrim(coalesce(r->>'store_id','')), '') is not null then
        v_store := (r->>'store_id')::uuid;
        if not exists (select 1 from public.stores where id = v_store) then raise exception '店舗IDが存在しません: %', r->>'store_id'; end if;
      elsif v_sname <> '' then
        v_store := public._pl_resolve_store(v_sname);
        if v_store is null then raise exception '店舗名を特定できません: %', v_sname; end if;
      end if;
      v_item := btrim(coalesce(r->>'item',''));
      if v_item = '' then raise exception '勘定科目が空です'; end if;
      v_cat := upper(btrim(coalesce(r->>'category','')));
      if v_cat not in ('S','F','L','A','R','O','X') then raise exception '区分が不正です（S/F/L/A/R/O/X）: %', coalesce(r->>'category','(空)'); end if;
      begin v_amt := nullif(btrim(replace(replace(coalesce(r->>'amount',''), ',', ''), '¥', '')), '')::numeric;
      exception when others then raise exception '金額が数値ではありません: %', r->>'amount'; end;
      if v_amt is null then raise exception '金額が空です'; end if;
      v_src := coalesce(nullif(btrim(coalesce(r->>'source','')), ''), '手入力');
      v_key := nullif(btrim(coalesce(r->>'source_key','')), '');
      v_memo := coalesce(r->>'memo',''); v_sub := coalesce(r->>'sub_item','');
      if p_mode = 'replace_month_store' and v_src <> '手入力' then raise exception 'replace_month_storeは手入力行のみ（自動行はreplace_source）'; end if;
      if p_mode = 'replace_source' and v_src = '手入力' then raise exception 'replace_sourceは自動連携行のみ（sourceに手入力以外を指定）'; end if;
      -- 権限
      if kind = 'tencho' then
        if v_store is null or not (v_store = any(my_stores)) then raise exception 'この店舗の経費を編集する権限がありません'; end if;
        if v_src <> '手入力' then raise exception '自動連携行は編集できません'; end if;
      end if;
      -- 既存行の確認（id指定の更新）
      if v_id is not null and p_mode <> 'replace_source' then
        select * into ex from public.pl_entries where id = v_id;
        if not found or ex.deleted_at is not null then raise exception '更新対象の行が見つかりません（削除済みの可能性）: %', v_id; end if;
        if kind = 'tencho' and (ex.store_id is null or not (ex.store_id = any(my_stores)) or ex.source <> '手入力') then raise exception 'この行を編集する権限がありません'; end if;
      end if;
      insert into _pl_stage values (ord, v_id, v_ym, v_store, v_item, v_cat, v_amt, v_memo, v_sub, v_src, v_key);
    exception when others then
      e_count := e_count + 1;
      if e_count <= 200 then errs := errs || jsonb_build_object('index', ord - 1, 'reason', sqlerrm); end if;
    end;
  end loop;

  if e_count > 0 then
    return jsonb_build_object('ok', false, 'dry_run', p_dry_run, 'error_count', e_count, 'errors', errs);
  end if;
  if p_dry_run then
    return jsonb_build_object('ok', true, 'dry_run', true, 'rows', (select count(*) from _pl_stage));
  end if;

  perform set_config('app.actor', actor, true);

  if p_mode = 'replace_month_store' then
    update public.pl_entries e set deleted_at = now(), updated_at = now(), updated_by = actor
      where e.deleted_at is null and e.source = '手入力'
        and exists (select 1 from _pl_stage s where s.ym = e.year_month and s.store_id is not distinct from e.store_id)
        and e.id not in (select id from _pl_stage where id is not null);
    get diagnostics cnt = row_count; del := del + cnt;
  elsif p_mode = 'replace_source' then
    for sp in
      select distinct source, ym from _pl_stage
      union select distinct x->>'source', x->>'year_month' from jsonb_array_elements(coalesce(p_scope, '[]'::jsonb)) x where coalesce(x->>'source','') <> '' and coalesce(x->>'source','') <> '手入力'
    loop
      update public.pl_entries set deleted_at = now(), updated_at = now(), updated_by = actor
        where deleted_at is null and source = sp.source and year_month = sp.ym;
      get diagnostics cnt = row_count; del := del + cnt;
    end loop;
  end if;

  for sp in select * from _pl_stage order by idx loop
    if sp.id is not null and p_mode <> 'replace_source' then
      update public.pl_entries set year_month = sp.ym, store_id = sp.store_id, item = sp.item, category = sp.cat, amount = sp.amt,
        memo = sp.memo, sub_item = sp.sub_item, source = sp.source, source_key = sp.source_key, updated_at = now(), updated_by = actor
        where id = sp.id and deleted_at is null;
      upd := upd + 1;
    elsif sp.source_key is not null and exists (select 1 from public.pl_entries where source_key = sp.source_key and deleted_at is null) then
      update public.pl_entries set year_month = sp.ym, store_id = sp.store_id, item = sp.item, category = sp.cat, amount = sp.amt,
        memo = sp.memo, sub_item = sp.sub_item, source = sp.source, updated_at = now(), updated_by = actor
        where source_key = sp.source_key and deleted_at is null;
      upd := upd + 1;
    else
      insert into public.pl_entries (year_month, store_id, item, category, amount, memo, sub_item, source, source_key, created_by, updated_by)
        values (sp.ym, sp.store_id, sp.item, sp.cat, sp.amt, sp.memo, sp.sub_item, sp.source, sp.source_key, actor, actor);
      ins := ins + 1;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'dry_run', false, 'inserted', ins, 'updated', upd, 'deleted', del);
end $$;
revoke all on function public.pl_entries_bulk_upsert(jsonb, text, boolean, text, jsonb) from public, anon;
grant execute on function public.pl_entries_bulk_upsert(jsonb, text, boolean, text, jsonb) to authenticated, service_role;

-- 削除（ソフト削除。履歴に残る）
create or replace function public.pl_entries_delete(p_ids uuid[], p_actor text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare sc jsonb := public._pl_scope(p_actor); kind text := sc->>'kind'; actor text := sc->>'actor'; my_stores uuid[]; cnt int := 0; bad int := 0; e record;
begin
  if kind = 'none' then return jsonb_build_object('ok', false, 'error', '権限がありません'); end if;
  if kind = 'tencho' then select coalesce(array_agg(x::uuid), '{}') into my_stores from jsonb_array_elements_text(sc->'stores') x; end if;
  perform set_config('app.actor', actor, true);
  for e in select * from public.pl_entries where id = any(p_ids) and deleted_at is null loop
    if kind = 'tencho' and (e.store_id is null or not (e.store_id = any(my_stores)) or e.source <> '手入力') then bad := bad + 1; continue; end if;
    update public.pl_entries set deleted_at = now(), updated_at = now(), updated_by = actor where id = e.id;
    cnt := cnt + 1;
  end loop;
  return jsonb_build_object('ok', bad = 0, 'deleted', cnt, 'denied', bad);
end $$;
revoke all on function public.pl_entries_delete(uuid[], text) from public, anon;
grant execute on function public.pl_entries_delete(uuid[], text) to authenticated, service_role;

-- 出力（編集用）。単一のjsonbで返す＝PostgRESTの1000行打切りを受けない。呼び出し元の権限（RLS）で見える行だけ返す
create or replace function public.pl_entries_export(p_from text default null, p_to text default null, p_store uuid default null, p_include_deleted boolean default false)
returns jsonb
language sql stable security invoker set search_path = public as $$
  select jsonb_build_object('ok', true, 'rows', coalesce(jsonb_agg(jsonb_build_object(
    'id', e.id, 'year_month', e.year_month, 'store_id', e.store_id, 'store_name', coalesce(s.name, ''),
    'item', e.item, 'category', e.category, 'amount', e.amount, 'memo', e.memo, 'sub_item', e.sub_item,
    'source', e.source, 'source_key', e.source_key, 'deleted_at', e.deleted_at, 'updated_at', e.updated_at, 'updated_by', e.updated_by
  ) order by e.year_month, s.sort_order nulls first, e.item, e.created_at, e.id), '[]'::jsonb))
  from public.pl_entries e left join public.stores s on s.id = e.store_id
  where (p_from is null or e.year_month >= p_from) and (p_to is null or e.year_month <= p_to)
    and (p_store is null or e.store_id = p_store)
    and (p_include_deleted or e.deleted_at is null)
$$;
revoke all on function public.pl_entries_export(text, text, uuid, boolean) from public, anon;
grant execute on function public.pl_entries_export(text, text, uuid, boolean) to authenticated, service_role;

-- 移行用（1回だけ・service_roleのみ）: kd_pl_entries（=DB_PL/stg_plの最新ミラー）から正本へ取り込む。
-- 空の正本にだけ実行可（p_force=trueで追加取込）。区分が空/不明の行は科目名から推定（家賃→R等・不明はO）し、normalizedで一覧を返す。
-- 年月が不正/店舗名が解決不能の行は取り込まず rejected に理由を返す（行は黙って捨てない）。memoが「自動｜…」で始まる行は sourceをその値に。
-- 自動連携行の判定（担当A定義）。keiei-kd-refreshのplAutoSourceOf()と同じ規則。手入力ならnull
create or replace function public.pl_auto_source(p_memo text) returns text language sql immutable as $$
  select case
    when btrim(coalesce(p_memo,'')) like '自動｜%' then btrim(p_memo)
    when btrim(coalesce(p_memo,'')) like '%（自動計上）' then btrim(p_memo)
    when btrim(coalesce(p_memo,'')) like '店舗間移動:%' or btrim(coalesce(p_memo,'')) like '店舗間移動：%' then '店舗間移動'
    else null end
$$;
drop function if exists public.pl_entries_import_from_kd(text, boolean);
create or replace function public.pl_entries_import_from_kd(p_actor text default 'import', p_force boolean default false, p_reset boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_claims jsonb; v_cnt int; ins int := 0; fixed_cat int := 0; rej jsonb := '[]'::jsonb; norm jsonb := '[]'::jsonb; k record; v_cat text; v_src text;
begin
  begin v_claims := nullif(current_setting('request.jwt.claims', true), '')::jsonb; exception when others then v_claims := null; end;
  if coalesce(v_claims->>'role','') <> 'service_role' then return jsonb_build_object('ok', false, 'error', 'service_roleのみ'); end if;
  if p_reset then delete from public.pl_entries where true; end if;   -- 切替時の「空にして再取込」（削除行は履歴に残る）
  select count(*) into v_cnt from public.pl_entries;
  if v_cnt > 0 and not p_force then return jsonb_build_object('ok', false, 'error', format('pl_entriesに既に%s行あります（追加取込はp_force=true）', v_cnt)); end if;
  perform set_config('app.actor', coalesce(p_actor, 'import'), true);
  for k in select * from public.kd_pl_entries order by id loop
    if k.year_month !~ '^\d{4}-(0[1-9]|1[0-2])$' then
      rej := rej || jsonb_build_object('kd_id', k.id, 'reason', '年月が不正: ' || k.year_month); continue;
    end if;
    if k.store_name <> '' and k.store_id is null then
      rej := rej || jsonb_build_object('kd_id', k.id, 'reason', '店舗名を特定できません: ' || k.store_name); continue;
    end if;
    v_cat := upper(btrim(k.category));
    if v_cat not in ('S','F','L','A','R','O','X') then
      -- 区分が空/「？」等の行は、区分セルの文字→無ければ科目名から推定（家賃→R・広告/販促→A・仕入→F・人件/給料/福利→L・他はO）。推定した行は normalized に返す
      v_cat := case when v_cat ~ '^F|仕入|原価' then 'F' when v_cat ~ '^L|人件' then 'L' when v_cat ~ '^A|広告' then 'A' when v_cat ~ '^R|家賃|賃料' then 'R'
        when k.item ~ '仕入' then 'F' when k.item ~ '給料|雑給|人件費|法定福利|通勤|役員報酬|賞与' then 'L' when k.item ~ '広告|販促|販売促進' then 'A' when k.item ~ '家賃|賃料|地代|リース' then 'R'
        else 'O' end;
      fixed_cat := fixed_cat + 1;
      norm := norm || jsonb_build_object('kd_id', k.id, 'ym', k.year_month, 'store', k.store_name, 'item', k.item, 'amount', k.amount, 'category', v_cat);
    end if;
    v_src := coalesce(public.pl_auto_source(k.memo), '手入力');
    insert into public.pl_entries (year_month, store_id, item, category, amount, memo, sub_item, source, created_by, updated_by)
      values (k.year_month, k.store_id, coalesce(nullif(btrim(k.item), ''), '(未分類)'), v_cat, k.amount, k.memo, k.sub_item, v_src, coalesce(p_actor,'import'), coalesce(p_actor,'import'));
    ins := ins + 1;
  end loop;
  return jsonb_build_object('ok', true, 'inserted', ins, 'category_normalized', fixed_cat, 'normalized', norm, 'rejected', rej);
end $$;
revoke all on function public.pl_entries_import_from_kd(text, boolean, boolean) from public, anon, authenticated;
grant execute on function public.pl_entries_import_from_kd(text, boolean, boolean) to service_role;
revoke all on function public.pl_auto_source(text) from public, anon;
grant execute on function public.pl_auto_source(text) to authenticated, service_role;

comment on table public.pl_entries is 'PL販管費の正本（F3）。書込はRPC(pl_entries_bulk_upsert/delete)のみ。kd_pl_*はここから作る（切替後）';
comment on table public.pl_entries_history is 'pl_entriesの変更履歴（トリガ自動記録・master/CEO/HQのみ閲覧）';
