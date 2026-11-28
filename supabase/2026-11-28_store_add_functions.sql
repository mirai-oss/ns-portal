-- 店舗を 1 回の呼び出しで追加する関数（担当F／2026-11-28）
-- 社長の OK の後に適用する。実データ（委託先など）はこのファイルに書かず、呼び出すときに渡す。
--
-- できること
--   smv2_add_store(入力, false)      下見。何も残さず、何が登録されるかだけを返す（入力チェックも全部かかる）
--   smv2_add_store(入力, true)       登録。★営業前の状態（is_active=false・seisan_target=false）で入る★
--   smv2_set_store_start(店舗, true) 扱い始め。is_active=true、精算の対象フラグも形に合わせて入れる
--   smv2_set_store_start(店舗, false) 扱いを止める（データは消さない）
--   smv2_undo_add_store(店舗, false) 取り消しの下見（消せない理由があれば一覧で返す）
--   smv2_undo_add_store(店舗, true)  取り消し。この関数で追加し、まだ何のデータも付いていない店舗だけ
--
-- 書く表: stores（チャットルームは自動で作られる）・info.stores・store_aliases・store_external_mappings・
--         brands / store_brand_relations・vendors / vendor_roles（他社委託で新しい委託先のとき）・store_operation_relations
-- 書かない表（各担当）: settle_stores・settle_store_terms（担当C）／report_channel_stores・レジ売上の取り込み（担当B・D）／
--         家賃・PL（担当A）／銀行口座（担当C）
-- 扱い始めの値は既存店に合わせる: C は seisan_target と seisan_pl_categories_target が true、B は後者だけ true、A は両方 false。
-- 呼べる人: ログインした本部・社長・マスター、または SQL を直接実行する管理者。anon と service_role の API からは呼べない。
--
-- 【この変更の戻し方】
--   drop function public.smv2_add_store(jsonb, boolean), public.smv2_set_store_start(uuid, boolean),
--     public.smv2_undo_add_store(uuid, boolean), public.smv2_require_store_admin(), public.smv2_group_corp(text);
--   drop table public.store_add_logs;   -- 追加の記録が消えるので、記録が 0 件のときだけ

begin;

create table if not exists public.store_add_logs (
  id         uuid primary key default gen_random_uuid(),
  store_id   uuid not null,                 -- 取り消した店舗は残らないので、外部キーは付けない
  form       text not null check (form in ('A','B','C')),
  input      jsonb not null,
  created    jsonb not null default '{}'::jsonb,  -- この呼び出しで新しく作った委託先・業態
  created_by uuid,
  created_at timestamptz not null default now(),
  undone_at  timestamptz
);
alter table public.store_add_logs enable row level security;
revoke all on public.store_add_logs from public, anon, authenticated;

create or replace function public.smv2_require_store_admin() returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null then
    if not public.store_master_can_edit() then raise exception '権限がありません（本部/社長/マスターのみ）'; end if;
  elsif session_user not in ('postgres', 'supabase_admin') then
    raise exception '権限がありません（ログインしてください）';
  end if;
end $$;

-- グループ会社を名前（表示名・正式名・登録名）から 1 件に決める
create or replace function public.smv2_group_corp(p_name text) returns uuid
language plpgsql stable security definer set search_path = public as $$
declare v_ids uuid[];
begin
  select array_agg(id) into v_ids from public.corporations
   where is_group_company
     and public.smv2_norm(p_name) in (public.smv2_norm(name), public.smv2_norm(display_name), public.smv2_norm(legal_name));
  if coalesce(array_length(v_ids, 1), 0) <> 1 then raise exception 'グループ会社が 1 件に決まりません: %', p_name; end if;
  return v_ids[1];
end $$;

create or replace function public.smv2_add_store(p jsonb, p_apply boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c_keys constant text[] := array['form','name','display_name','opened_on','postal_code','address','phone','business_hours',
    'official_url','signs','dash_store_name','mf_department_name','settlement_name','aliases','brand','lease_corporation',
    'operator_corporation','operator_vendor','revenue_corporation','effective_from','term_months','auto_renew','note'];
  v_bad text; v_form text; v_name text; v_settle text; v_mf text; v_from date;
  v_names text[]; v_a text;
  v_lease uuid; v_rev uuid; v_op uuid; v_op_type text; v_rel_type text;
  v_vendor jsonb; v_vname text; v_brand jsonb; v_brand_id uuid; v_info_corp uuid; v_operator_name text;
  v_store uuid; v_no int; v_no_text text; v_sort int; v_created jsonb := '{}'::jsonb; v_result jsonb;
begin
  perform public.smv2_require_store_admin();
  perform pg_advisory_xact_lock(hashtext('smv2_add_store'));

  if p is null or jsonb_typeof(p) <> 'object' then raise exception '入力は JSON のオブジェクトで渡してください'; end if;
  select string_agg(k, ', ') into v_bad from jsonb_object_keys(p) k where not (k = any(c_keys));
  if v_bad is not null then raise exception '知らない項目があります（打ち間違いを確認）: %', v_bad; end if;

  v_form := upper(btrim(coalesce(p->>'form','')));
  if v_form not in ('A','B','C') then raise exception 'form は A（直営）・B（グループ委託）・C（他社委託）のどれかです'; end if;
  v_name := btrim(coalesce(p->>'name',''));
  if v_name = '' or length(v_name) > 40 then raise exception '店舗名（name）を 40 文字以内で入れてください'; end if;
  if coalesce(p->>'effective_from','') !~ '^\d{4}-\d{2}-\d{2}$' then raise exception '開始日（effective_from）を YYYY-MM-DD で入れてください'; end if;
  v_from := (p->>'effective_from')::date;
  v_settle := nullif(btrim(coalesce(p->>'settlement_name','')), '');
  v_mf := nullif(btrim(coalesce(p->>'mf_department_name','')), '');
  if v_form = 'A' and v_settle is not null then raise exception '直営（A）に精算名は入れません'; end if;
  -- B・C は精算の店舗名（stores.seisan_store_name＝settle_stores.name）が要る。指定が無ければ正式名
  if v_form <> 'A' and v_settle is null then v_settle := v_name; end if;

  -- 呼び名（正式名＋別名＋精算名）。まったく同じ文字はまとめる（空白違いは別々に残す）
  select array_agg(n order by ord) into v_names from (
    select distinct on (n) n, ord from (
      select v_name as n, 0 as ord
      union all select btrim(x), 1 from jsonb_array_elements_text(coalesce(p->'aliases','[]'::jsonb)) x
      union all select v_settle, 2
    ) s where coalesce(n,'') <> '' order by n, ord
  ) d;

  foreach v_a in array v_names || array_remove(array[nullif(btrim(coalesce(p->>'dash_store_name','')),'')], null) loop
    if exists (select 1 from public.stores s where public.smv2_norm(v_a) in (public.smv2_norm(s.name), public.smv2_norm(s.display_name), public.smv2_norm(s.dash_store_name)))
       or exists (select 1 from public.store_aliases a where public.smv2_norm(a.alias) = public.smv2_norm(v_a))
       or exists (select 1 from public.store_external_mappings m where m.is_active and public.smv2_norm(m.external_store_name) = public.smv2_norm(v_a)) then
      raise exception 'この呼び名は、すでに登録されている店舗で使われています: %', v_a;
    end if;
  end loop;

  -- 会社と運営の形
  v_lease := public.smv2_group_corp(coalesce(p->>'lease_corporation',''));
  v_rev := case when nullif(p->>'revenue_corporation','') is null then v_lease else public.smv2_group_corp(p->>'revenue_corporation') end;
  select legacy_info_id into v_info_corp from public.corporations where id = v_lease;
  if v_info_corp is null then raise exception '借主の会社が社内情報管理（info.corporations）とつながっていません'; end if;

  if v_form in ('A','B') then
    if p ? 'operator_vendor' then raise exception '% の形では operator_vendor を使いません', v_form; end if;
    v_op_type := 'corporation';
    if v_form = 'A' then
      v_op := case when nullif(p->>'operator_corporation','') is null then v_lease else public.smv2_group_corp(p->>'operator_corporation') end;
      if v_op <> v_lease then raise exception '直営（A）は借主と運営が同じ会社です。違う場合は B です'; end if;
      v_rel_type := 'direct';
    else
      v_op := public.smv2_group_corp(coalesce(p->>'operator_corporation',''));
      if v_op = v_lease then raise exception 'グループ委託（B）は借主と運営が別の会社です'; end if;
      v_rel_type := 'outsourcing';
    end if;
    select coalesce(legal_name, name) into v_operator_name from public.corporations where id = v_op;
  else
    if p ? 'operator_corporation' then raise exception '他社委託（C）では operator_corporation を使いません'; end if;
    v_vendor := p->'operator_vendor';
    if v_vendor is null or jsonb_typeof(v_vendor) <> 'object' then raise exception '他社委託（C）は operator_vendor が必要です'; end if;
    select string_agg(k, ', ') into v_bad from jsonb_object_keys(v_vendor) k where k not in ('id','name','corporation_number','contact_email','contact_phone');
    if v_bad is not null then raise exception 'operator_vendor に知らない項目があります: %', v_bad; end if;
    v_op_type := 'vendor'; v_rel_type := 'outsourcing';
    if nullif(v_vendor->>'id','') is not null then
      select id, name into v_op, v_operator_name from public.vendors where id = (v_vendor->>'id')::uuid and is_active;
      if v_op is null then raise exception '指定した委託先（取引先）が見つからないか、無効です'; end if;
    else
      v_vname := btrim(coalesce(v_vendor->>'name',''));
      if v_vname = '' then raise exception '委託先は id か name を入れてください'; end if;
      if exists (select 1 from public.vendors v where public.smv2_norm(v.name) = public.smv2_norm(v_vname)
                   or exists (select 1 from unnest(v.name_aliases) x where public.smv2_norm(x) = public.smv2_norm(v_vname)))
         or exists (select 1 from public.vendor_aliases a where a.is_active and public.smv2_norm(a.alias) = public.smv2_norm(v_vname)) then
        raise exception '同じ名前の取引先がすでにあります。新しく作らず id を指定してください: %', v_vname;
      end if;
      if nullif(v_vendor->>'corporation_number','') is not null and v_vendor->>'corporation_number' !~ '^\d{13}$' then
        raise exception '法人番号は 13 桁の数字です（インボイス番号の T は付けません）';
      end if;
    end if;
  end if;

  begin  -- ここから書き込み。下見（p_apply=false）はこの区切りごと取り消す
    if v_form = 'C' and v_op is null then
      insert into public.vendors (name, corporation_number, contact_email, contact_phone, created_by, updated_by)
      values (v_vname, nullif(v_vendor->>'corporation_number',''), nullif(v_vendor->>'contact_email',''),
              nullif(v_vendor->>'contact_phone',''), auth.uid(), auth.uid())
      returning id, name into v_op, v_operator_name;
      v_created := v_created || jsonb_build_object('vendor_id', v_op);
    end if;
    if v_form = 'C' and not exists (select 1 from public.vendor_roles where vendor_id = v_op and role_type = 'operator') then
      insert into public.vendor_roles (vendor_id, role_type, effective_from) values (v_op, 'operator', v_from);
      v_created := v_created || jsonb_build_object('operator_role_vendor_id', v_op);
    end if;

    select coalesce(max(n), 0) + 1 into v_no
      from (select case when store_no ~ '^\d+$' then store_no::int end as n from public.stores) x where n < 99;
    if v_no >= 99 then raise exception '店舗番号が上限（98）に達しました。番号の付け方を見直してください'; end if;
    v_no_text := lpad(v_no::text, 2, '0');
    select coalesce(max(sort_order), 0) + 1 into v_sort from public.stores where location_type = 'store';

    insert into public.stores (name, display_name, store_no, sort_order, is_active, corporation_id, location_type,
                               seisan_target, seisan_store_name, mf_department_name, dash_store_name, signs)
    values (v_name, nullif(btrim(coalesce(p->>'display_name','')),''), v_no_text, v_sort, false, v_lease, 'store',
            false, v_settle, v_mf, nullif(btrim(coalesce(p->>'dash_store_name','')),''),
            case when p ? 'signs' then array(select jsonb_array_elements_text(p->'signs')) end)
    returning id into v_store;

    insert into info.stores (corporation_id, store_code, name, hub_store_id, operator_name,
                             postal_code, address, phone, business_hours, official_url)
    values (v_info_corp, v_no_text, v_name, v_store, v_operator_name,
            nullif(p->>'postal_code',''), nullif(p->>'address',''), nullif(p->>'phone',''),
            nullif(p->>'business_hours',''), nullif(p->>'official_url',''));

    foreach v_a in array v_names loop
      insert into public.store_aliases (alias, store_id, source, kind)
      values (v_a, v_store, case when v_a = v_name then '正準' when v_a = v_settle then '精算' else '追加登録' end, 'name');
      insert into public.store_external_mappings (store_id, source_system, external_store_name, created_by, effective_from)
      values (v_store, 'legacy_alias', v_a, auth.uid(), null);
    end loop;
    if v_settle is not null then
      insert into public.store_external_mappings (store_id, source_system, external_store_name, vendor_id, created_by)
      values (v_store, 'settlement', v_settle, case when v_form = 'C' then v_op end, auth.uid());
    end if;
    if v_mf is not null then
      insert into public.store_external_mappings (store_id, source_system, external_store_name, created_by)
      values (v_store, 'payroll', v_mf, auth.uid());
    end if;

    v_brand := p->'brand';
    if v_brand is not null and jsonb_typeof(v_brand) = 'object' then
      if nullif(v_brand->>'id','') is not null then
        select id into v_brand_id from public.brands where id = (v_brand->>'id')::uuid;
        if v_brand_id is null then raise exception '指定した業態が見つかりません'; end if;
      else
        if btrim(coalesce(v_brand->>'name','')) = '' then raise exception '業態は id か name を入れてください'; end if;
        select id into v_brand_id from public.brands where public.smv2_norm(name) = public.smv2_norm(v_brand->>'name') limit 1;
        if v_brand_id is null then
          insert into public.brands (name, display_name) values (btrim(v_brand->>'name'), btrim(v_brand->>'name')) returning id into v_brand_id;
          v_created := v_created || jsonb_build_object('brand_id', v_brand_id);
        else
          update public.brands set is_active = true where id = v_brand_id and not is_active;
        end if;
      end if;
      insert into public.store_brand_relations (store_id, brand_id, is_primary, effective_from)
      values (v_store, v_brand_id, true, nullif(p->>'opened_on','')::date);
    end if;

    insert into public.store_operation_relations (store_id, relation_type, lease_entity_type, lease_entity_id,
      operator_entity_type, operator_entity_id, revenue_entity_type, revenue_entity_id, effective_from,
      contract_term_months, auto_renew, note, created_by)
    values (v_store, v_rel_type, 'corporation', v_lease, v_op_type, v_op, 'corporation', v_rev, v_from,
      nullif(p->>'term_months','')::int, coalesce((p->>'auto_renew')::boolean, false), nullif(p->>'note',''), auth.uid());

    insert into public.store_add_logs (store_id, form, input, created, created_by)
    values (v_store, v_form, p, v_created, auth.uid());

    v_result := jsonb_build_object(
      'applied', p_apply is true, 'store_id', case when p_apply then v_store end, 'store_no', v_no_text, 'name', v_name, 'form', v_form,
      'operator', v_operator_name, 'new_vendor', v_created ? 'vendor_id', 'new_brand', v_created ? 'brand_id',
      'aliases', to_jsonb(v_names), 'effective_from', v_from,
      'state', '営業前（is_active=false・seisan_target=false）。扱い始めに smv2_set_store_start を実行',
      'next', case v_form
        when 'C' then '["担当C: 精算の店舗と条件","社長: 委託先の振込先口座","担当D: 売上の取り込み（店舗名をそろえる）","担当A: 家賃・PL・MF部門","担当B: 売上の日報"]'::jsonb
        else '["担当D: 売上・勤怠・給与","担当A: 家賃・PL・MF部門","担当C: 入金の確認","担当B: 日報・口コミ・採用・シフト"]'::jsonb end);

    if p_apply is not true then raise exception using errcode = 'P0T01', message = 'preview'; end if;
  exception when sqlstate 'P0T01' then null;
  end;
  return v_result;
end $$;

create or replace function public.smv2_set_store_start(p_store_id uuid, p_start boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_form text;
begin
  perform public.smv2_require_store_admin();
  if p_start is null then raise exception 'true（扱い始め）か false（止める）を指定してください'; end if;
  select form into v_form from public.store_add_logs where store_id = p_store_id and undone_at is null;
  if v_form is null then raise exception 'この関数で追加した店舗だけが対象です'; end if;
  update public.stores set is_active = p_start, seisan_target = (p_start and v_form = 'C'),
    seisan_pl_categories_target = (p_start and v_form in ('B','C')) where id = p_store_id;
  return jsonb_build_object('store_id', p_store_id, 'is_active', p_start, 'seisan_target', p_start and v_form = 'C',
    'seisan_pl_categories_target', p_start and v_form in ('B','C'));
end $$;

create or replace function public.smv2_undo_add_store(p_store_id uuid, p_apply boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_log public.store_add_logs%rowtype; v_info uuid; r record; n bigint; v_blockers jsonb := '[]'::jsonb;
  v_vendor uuid; v_brand uuid; v_used boolean := false;
begin
  perform public.smv2_require_store_admin();
  perform pg_advisory_xact_lock(hashtext('smv2_add_store'));
  select * into v_log from public.store_add_logs where store_id = p_store_id and undone_at is null for update;
  if not found then raise exception 'この関数で追加した店舗（まだ取り消していないもの）だけが対象です'; end if;
  select id into v_info from info.stores where hub_store_id = p_store_id;

  -- ① 外部キーで店舗を指している表（追加のときに自分で書いた表は除く）
  for r in
    select k.conrelid::regclass::text as tbl, a.attname as col, k.confrelid
      from pg_constraint k join pg_attribute a on a.attrelid = k.conrelid and a.attnum = k.conkey[1]
     where k.contype = 'f' and k.confrelid in ('public.stores'::regclass, 'info.stores'::regclass)
       and not (k.confrelid = 'public.stores'::regclass and k.conrelid in ('public.chat_rooms'::regclass, 'info.stores'::regclass,
            'public.store_aliases'::regclass, 'public.store_external_mappings'::regclass,
            'public.store_brand_relations'::regclass, 'public.store_operation_relations'::regclass))
  loop
    execute format('select count(*) from %s where %I = $1', r.tbl, r.col) into n
      using case when r.confrelid = 'public.stores'::regclass then p_store_id else v_info end;
    if n > 0 then v_blockers := v_blockers || jsonb_build_object('table', r.tbl, 'column', r.col, 'rows', n); end if;
  end loop;
  -- ② 外部キーが無いのに店舗の ID を持つ列（精算の店舗など）
  for r in
    select format('%I.%I', c.table_schema, c.table_name) as tbl, c.column_name as col, c.udt_name
      from information_schema.columns c join information_schema.tables t using (table_schema, table_name)
     where t.table_type = 'BASE TABLE' and c.table_schema in ('public','info') and c.column_name ~ '(^|_)store_ids?$'
       and c.udt_name in ('uuid','_uuid') and c.table_name <> 'store_add_logs'
       and not exists (select 1 from pg_constraint k join pg_attribute a on a.attrelid = k.conrelid and a.attnum = any(k.conkey)
                        where k.contype = 'f' and k.conrelid = format('%I.%I', c.table_schema, c.table_name)::regclass and a.attname = c.column_name)
  loop
    execute format(case when r.udt_name = '_uuid' then 'select count(*) from %s where $1 = any(%I)' else 'select count(*) from %s where %I = $1' end,
                   r.tbl, r.col) into n using p_store_id;
    if n > 0 then v_blockers := v_blockers || jsonb_build_object('table', r.tbl, 'column', r.col, 'rows', n); end if;
  end loop;
  -- ③ 自動で作られたチャットルームに、参加者や投稿があるか
  for r in
    select k.conrelid::regclass::text as tbl, a.attname as col
      from pg_constraint k join pg_attribute a on a.attrelid = k.conrelid and a.attnum = k.conkey[1]
     where k.contype = 'f' and k.confrelid = 'public.chat_rooms'::regclass
  loop
    execute format('select count(*) from %s where %I in (select id from public.chat_rooms where store_id = $1)', r.tbl, r.col) into n using p_store_id;
    if n > 0 then v_blockers := v_blockers || jsonb_build_object('table', r.tbl, 'column', r.col, 'rows', n); end if;
  end loop;

  if jsonb_array_length(v_blockers) > 0 then
    return jsonb_build_object('ok', false, 'applied', false, 'blockers', v_blockers,
      'message', 'データが付いているため取り消せません。扱いを止めるだけなら smv2_set_store_start(店舗, false)');
  end if;
  if p_apply is not true then return jsonb_build_object('ok', true, 'applied', false, 'message', '取り消せます'); end if;

  delete from public.chat_rooms where store_id = p_store_id;
  delete from public.store_operation_relations where store_id = p_store_id;
  delete from public.store_brand_relations where store_id = p_store_id;
  delete from public.store_external_mappings where store_id = p_store_id;
  delete from public.store_aliases where store_id = p_store_id;
  delete from info.stores where hub_store_id = p_store_id;
  delete from public.stores where id = p_store_id;

  -- 新しく作った委託先・業態は消さずに無効にする（ほかで使われ始めていれば、そのまま）
  v_vendor := (v_log.created->>'operator_role_vendor_id')::uuid;
  if v_vendor is not null and not exists (select 1 from public.store_operation_relations where operator_entity_id = v_vendor) then
    delete from public.vendor_roles where vendor_id = v_vendor and role_type = 'operator';
  end if;
  v_vendor := (v_log.created->>'vendor_id')::uuid;
  if v_vendor is not null and not exists (select 1 from public.store_operation_relations where operator_entity_id = v_vendor) then
    -- 請求書・口座など、ほかの表で使われ始めていたら無効にしない
    for r in
      select k.conrelid::regclass::text as tbl, a.attname as col
        from pg_constraint k join pg_attribute a on a.attrelid = k.conrelid and a.attnum = k.conkey[1]
       where k.contype = 'f' and k.confrelid = 'public.vendors'::regclass and k.conrelid <> 'public.vendor_roles'::regclass
    loop
      execute format('select count(*) from %s where %I = $1', r.tbl, r.col) into n using v_vendor;
      if n > 0 then v_used := true; end if;
    end loop;
    if not v_used then update public.vendors set is_active = false, updated_at = now() where id = v_vendor; end if;
  end if;
  v_brand := (v_log.created->>'brand_id')::uuid;
  if v_brand is not null and not exists (select 1 from public.store_brand_relations where brand_id = v_brand) then
    update public.brands set is_active = false where id = v_brand;
  end if;

  update public.store_add_logs set undone_at = now() where id = v_log.id;
  return jsonb_build_object('ok', true, 'applied', true,
    'vendor_kept_active', v_used,
    'note', '新しく作った委託先・業態は消さずに無効にしています（委託先が請求書などで使われていれば有効のまま）');
end $$;

revoke all on function public.smv2_require_store_admin()            from public, anon, authenticated, service_role;
revoke all on function public.smv2_group_corp(text)                 from public, anon, authenticated, service_role;
revoke all on function public.smv2_add_store(jsonb, boolean)        from public, anon, service_role;
revoke all on function public.smv2_set_store_start(uuid, boolean)   from public, anon, service_role;
revoke all on function public.smv2_undo_add_store(uuid, boolean)    from public, anon, service_role;
grant execute on function public.smv2_add_store(jsonb, boolean)      to authenticated;
grant execute on function public.smv2_set_store_start(uuid, boolean) to authenticated;
grant execute on function public.smv2_undo_add_store(uuid, boolean)  to authenticated;

commit;
