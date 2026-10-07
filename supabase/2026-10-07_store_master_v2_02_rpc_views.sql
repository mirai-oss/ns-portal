-- =====================================================================
-- 店舗・法人・運営関係の正本 Phase1（土台）— ② 名寄せRPC・登録RPC・ビュー・管理画面用RPC
-- 担当F ／ 前提: 2026-10-07_store_master_v2_01_tables.sql を適用済み
--
-- 【事前報告様式（DB変更）】
-- 理由: 各システムがJSで別々に持つ店舗名照合を、DBの1本のRPC resolve_store() に寄せる土台（最終形=唯一のゲートウェイ）。
--       Phase1では「作る」だけで、どのシステムの読み取り先も切り替えない。
-- 現構造: store_aliases(alias主キー)・stores.name・各システムのJS照合。未解決は kd_unresolved_names へ隔離する既存の仕組み。
-- 変更（追加のみ）:
--   resolve_store()               … 解決順固定（①外部ID→②コード→③外部名→④stores.name→⑤store_aliases→⑥部分一致(low)→⑦未解決は隔離）
--   register_store_mapping()      … 人が確定したときの登録口（本部/社長/マスターのみ）。同名の未解決を解決済みにする
--   v_store_current_relations     … 今日時点の店舗×名義・運営・入金先・契約満了予定（精算関係もここから導出）
--   smv2_*（管理画面用RPC）       … 法人/店舗/ブランド/運営関係/別名/マッピングの編集口。stores.name等の既存列には一切触れない
-- 既存データへの影響: なし。 rollback: ファイル末尾のコメント参照。 冪等（create or replace）。
-- =====================================================================

-- ---------------------------------------------------------------------
-- 名称の正規化（照合専用。保存値は変えない）
--   NFKC（全角/半角・㈲→(有)等）→ 小文字 → 空白/記号除去 → 小書き仮名を大書き（じんべぇ=じんべえ）→ 末尾の「店」除去
-- ---------------------------------------------------------------------
create or replace function public.smv2_norm(p text)
returns text language sql immutable
set search_path to 'public' as $$
  select regexp_replace(
           translate(
             regexp_replace(lower(normalize(coalesce(p,''), NFKC)),
                            '[[:space:]　()（）\[\]【】「」『』・･_\-－ー―]', '', 'g'),
             'ぁぃぅぇぉっゃゅょゎァィゥェォッャュョヮ', 'あいうえおつやゆよわアイウエオツヤユヨワ'),
           '店$', '');
$$;

-- 法人ヒント（corp_code／名称／正式名／表示名／別名）→ corporations.id
create or replace function public.smv2_corp_id_from_hint(p_hint text)
returns uuid language sql stable
set search_path to 'public' as $$
  select x.id from (
    select c.id, 1 as pri from public.corporations c
      where p_hint is not null and btrim(p_hint) <> ''
        and (lower(c.corp_code) = lower(btrim(p_hint)) or smv2_norm(c.name) = smv2_norm(p_hint)
             or smv2_norm(c.legal_name) = smv2_norm(p_hint) or smv2_norm(c.display_name) = smv2_norm(p_hint))
    union all
    select a.corporation_id, 2 from public.corporation_aliases a
      where p_hint is not null and btrim(p_hint) <> '' and a.is_active and smv2_norm(a.alias) = smv2_norm(p_hint)
  ) x order by x.pri limit 1;
$$;

-- ---------------------------------------------------------------------
-- resolve_store: 店舗判定の唯一の共通ゲートウェイ（読み取り＋未解決の隔離記録のみ）
--   戻り値: store_id / brand_id / corporation_id / confidence / matched_by
--   confidence: exact(①〜③) / high(④⑤) / low(⑥) 。未解決は1行も返さず（0行）、kd_unresolved_namesへ記録。
--   corporation_id: stores.corporation_id。空の拠点（「本部」）は一致したマッピングの corporation_hint から補う
--   brand_id: 一致したマッピングの brand_id。無ければその店舗の現在の主ブランド
--   p_log=false で未解決の記録を止められる（新旧比較レポート用）。
-- ---------------------------------------------------------------------
create or replace function public.resolve_store(
  p_source text,
  p_external_id text default null,
  p_code text default null,
  p_name text default null,
  p_corp_hint text default null,
  p_log boolean default true
) returns table (store_id uuid, brand_id uuid, corporation_id uuid, confidence text, matched_by text)
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_today date := (now() at time zone 'Asia/Tokyo')::date;
  v_hint_corp uuid := smv2_corp_id_from_hint(p_corp_hint);
  v_n text := smv2_norm(p_name);
  v_store uuid; v_brand uuid; v_map public.store_external_mappings%rowtype;
  v_conf text; v_by text; v_cnt int;
  v_ids uuid[];
begin
  -- ①〜③ 外部マッピング（有効・期間内）。同名の別法人店舗は corporation_hint で絞る
  if p_external_id is not null and btrim(p_external_id) <> '' then
    select m.* into v_map from public.store_external_mappings m
      where m.source_system = p_source and m.external_store_id = btrim(p_external_id) and m.is_active
        and (m.effective_from is null or m.effective_from <= v_today) and (m.effective_to is null or m.effective_to >= v_today)
      limit 1;
    if found then v_store := v_map.store_id; v_brand := v_map.brand_id; v_conf := 'exact'; v_by := 'mapping:external_id'; end if;
  end if;
  if v_store is null and p_code is not null and btrim(p_code) <> '' then
    select m.* into v_map from public.store_external_mappings m
      where m.source_system = p_source and m.external_store_code = btrim(p_code) and m.is_active
        and (m.effective_from is null or m.effective_from <= v_today) and (m.effective_to is null or m.effective_to >= v_today)
      order by (v_hint_corp is not null and smv2_corp_id_from_hint(m.corporation_hint) = v_hint_corp) desc
      limit 1;
    if found then v_store := v_map.store_id; v_brand := v_map.brand_id; v_conf := 'exact'; v_by := 'mapping:code'; end if;
  end if;
  if v_store is null and p_name is not null and btrim(p_name) <> '' then
    select m.* into v_map from public.store_external_mappings m
      where m.source_system = p_source and m.external_store_name = btrim(p_name) and m.is_active
        and (m.effective_from is null or m.effective_from <= v_today) and (m.effective_to is null or m.effective_to >= v_today)
      limit 1;
    if found then v_store := v_map.store_id; v_brand := v_map.brand_id; v_conf := 'exact'; v_by := 'mapping:name'; end if;
  end if;

  -- ④ stores.name（正規化一致。同名が複数なら法人ヒントで絞る。絞れなければ未確定）
  if v_store is null and v_n <> '' then
    select array_agg(s.id) into v_ids from public.stores s where smv2_norm(s.name) = v_n or smv2_norm(s.display_name) = v_n;
    v_cnt := coalesce(array_length(v_ids,1),0);
    if v_cnt > 1 and v_hint_corp is not null then
      select array_agg(s.id) into v_ids from public.stores s
        where s.id = any(v_ids) and (s.corporation_id = v_hint_corp);
      v_cnt := coalesce(array_length(v_ids,1),0);
    end if;
    if v_cnt = 1 then v_store := v_ids[1]; v_conf := 'high'; v_by := 'store_name'; end if;
  end if;

  -- ⑤ store_aliases（正規化一致）
  if v_store is null and v_n <> '' then
    select array_agg(distinct a.store_id) into v_ids from public.store_aliases a where smv2_norm(a.alias) = v_n;
    v_cnt := coalesce(array_length(v_ids,1),0);
    if v_cnt > 1 and v_hint_corp is not null then
      select array_agg(s.id) into v_ids from public.stores s where s.id = any(v_ids) and s.corporation_id = v_hint_corp;
      v_cnt := coalesce(array_length(v_ids,1),0);
    end if;
    if v_cnt = 1 then v_store := v_ids[1]; v_conf := 'high'; v_by := 'store_alias'; end if;
  end if;

  -- ⑥ 正規化後の部分一致（2文字以上・候補がちょうど1店舗のときだけ。confidence='low'）
  if v_store is null and length(v_n) >= 2 then
    select array_agg(distinct c.sid) into v_ids from (
      select s.id as sid, smv2_norm(s.name) as nm from public.stores s
      union all select s.id, smv2_norm(s.display_name) from public.stores s where s.display_name is not null
      union all select a.store_id, smv2_norm(a.alias) from public.store_aliases a
    ) c where c.nm <> '' and (position(v_n in c.nm) > 0 or position(c.nm in v_n) > 0)
      and length(c.nm) >= 2;
    v_cnt := coalesce(array_length(v_ids,1),0);
    if v_cnt > 1 and v_hint_corp is not null then
      select array_agg(s.id) into v_ids from public.stores s where s.id = any(v_ids) and s.corporation_id = v_hint_corp;
      v_cnt := coalesce(array_length(v_ids,1),0);
    end if;
    if v_cnt = 1 then v_store := v_ids[1]; v_conf := 'low'; v_by := 'partial'; end if;
  end if;

  -- ⑦ 未解決: 0行を返し kd_unresolved_names へ1行記録（既存の隔離の仕組み・Lark通知は既存の kd-unresolved-check に乗る）
  if v_store is null then
    if p_log and coalesce(nullif(btrim(p_name),''), nullif(btrim(p_code),''), nullif(btrim(p_external_id),'')) is not null then
      perform public.kd_report_unresolved_name(
        'resolve_store:' || coalesce(p_source,'?'), 'store',
        coalesce(nullif(btrim(p_name),''), nullif(btrim(p_code),''), btrim(p_external_id)),
        jsonb_build_object('external_id', p_external_id, 'code', p_code, 'corp_hint', p_corp_hint));
    end if;
    return;
  end if;

  select s.corporation_id into corporation_id from public.stores s where s.id = v_store;
  if corporation_id is null and v_map.corporation_hint is not null then
    corporation_id := smv2_corp_id_from_hint(v_map.corporation_hint);
  end if;
  if v_brand is null then
    select r.brand_id into v_brand from public.store_brand_relations r
      where r.store_id = v_store and r.is_primary and (r.effective_to is null or r.effective_to >= v_today) limit 1;
  end if;
  store_id := v_store; brand_id := v_brand; confidence := v_conf; matched_by := v_by;
  return next;
end $$;
revoke all on function public.resolve_store(text,text,text,text,text,boolean) from public;
grant execute on function public.resolve_store(text,text,text,text,text,boolean) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- register_store_mapping: 人（またはMirai）が確定したときの登録口。本部/社長/マスターのみ
--   同じ(source, id)または(source, name)が既に別店舗へ有効登録されていれば拒否（黙って上書きしない）。
--   登録後、同じ名前の kd_unresolved_names（全source_table）を解決済みにする
-- ---------------------------------------------------------------------
create or replace function public.register_store_mapping(
  p_source text, p_external_id text, p_code text, p_name text, p_store_id uuid, p_brand_id uuid default null
) returns uuid
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_id uuid; v_old public.store_external_mappings%rowtype; v_raw text;
begin
  if not store_master_can_edit() then raise exception '権限がありません（本部/社長/マスターのみ）'; end if;
  if p_source is null or p_source not in ('smaregi','smaregi_timecard','invoice','tabelog','hotpepper','gurunavi','gbp',
       'reservation','payroll','settlement','ad','delivery','dashboard','legacy_alias') then
    raise exception 'source_system が不正です: %', p_source;
  end if;
  if not exists (select 1 from public.stores where id = p_store_id) then raise exception '店舗が存在しません'; end if;
  if coalesce(nullif(btrim(p_external_id),''), nullif(btrim(p_code),''), nullif(btrim(p_name),'')) is null then
    raise exception '外部ID・コード・名称のいずれかを入力してください';
  end if;

  select * into v_old from public.store_external_mappings m
    where m.source_system = p_source
      and ((nullif(btrim(p_external_id),'') is not null and m.external_store_id = btrim(p_external_id))
        or (nullif(btrim(p_name),'') is not null and m.external_store_name = btrim(p_name)))
    order by m.is_active desc limit 1;
  if found then
    if v_old.is_active and v_old.store_id <> p_store_id then
      raise exception 'この外部名/IDは既に別の店舗に登録されています（先に無効化してください）';
    end if;
    update public.store_external_mappings
       set store_id = p_store_id, brand_id = p_brand_id, is_active = true,
           external_store_code = coalesce(nullif(btrim(p_code),''), external_store_code),
           external_store_id = coalesce(nullif(btrim(p_external_id),''), external_store_id),
           external_store_name = coalesce(nullif(btrim(p_name),''), external_store_name)
     where id = v_old.id returning id into v_id;
  else
    insert into public.store_external_mappings
      (store_id, brand_id, source_system, external_store_id, external_store_code, external_store_name, created_by)
    values (p_store_id, p_brand_id, p_source, nullif(btrim(p_external_id),''), nullif(btrim(p_code),''),
            nullif(btrim(p_name),''), auth.uid())
    returning id into v_id;
  end if;

  for v_raw in select unnest(array[nullif(btrim(p_name),''), nullif(btrim(p_code),''), nullif(btrim(p_external_id),'')]) loop
    continue when v_raw is null;
    update public.kd_unresolved_names
       set status = 'resolved', resolved_at = now(), resolved_by = auth.uid()
     where kind = 'store' and status = 'open' and smv2_norm(raw_name) = smv2_norm(v_raw);
  end loop;
  return v_id;
end $$;
revoke all on function public.register_store_mapping(text,text,text,text,uuid,uuid) from public;
grant execute on function public.register_store_mapping(text,text,text,text,uuid,uuid) to authenticated;

-- ---------------------------------------------------------------------
-- ビュー: 今日時点の運営関係（精算関係=「入金先→運営主体」もここから導出。専用表はPhase4で判断）
-- ---------------------------------------------------------------------
create or replace view public.v_store_current_relations with (security_invoker = true) as
with ent as (
  select 'corporation'::text as t, c.id, coalesce(c.display_name, c.name) as nm from public.corporations c
  union all
  select 'vendor', v.id, v.name from public.vendors v
), cur as (
  select r.*, (now() at time zone 'Asia/Tokyo')::date as today
  from public.store_operation_relations r
  where r.effective_from <= (now() at time zone 'Asia/Tokyo')::date
    and (r.effective_to is null or r.effective_to >= (now() at time zone 'Asia/Tokyo')::date)
)
select
  s.id as store_id, s.name as store_name, coalesce(s.display_name, s.name) as store_display_name,
  s.location_type, s.is_active as store_is_active,
  cur.id as relation_id, cur.relation_type,
  cur.lease_entity_type,    cur.lease_entity_id,    le.nm as lease_name,
  cur.operator_entity_type, cur.operator_entity_id, oe.nm as operator_name,
  cur.revenue_entity_type,  cur.revenue_entity_id,  re.nm as revenue_name,
  cur.effective_from, cur.contract_term_months, cur.auto_renew,
  case when cur.contract_term_months is null then null
       else ((cur.effective_from
             + make_interval(months => cur.contract_term_months *
                 case when cur.auto_renew
                      then ((extract(year from age(cur.today, cur.effective_from))*12
                             + extract(month from age(cur.today, cur.effective_from)))::int / cur.contract_term_months) + 1
                      else 1 end))::date
             - 1) end as current_term_end,
  -- 精算関係（導出）: 運営を他者に任せている店舗は「入金先→運営主体」へ精算する
  case when cur.relation_type <> 'direct' and (cur.revenue_entity_id <> cur.operator_entity_id) then re.nm end as settlement_from_name,
  case when cur.relation_type <> 'direct' and (cur.revenue_entity_id <> cur.operator_entity_id) then oe.nm end as settlement_to_name
from public.stores s
left join cur on cur.store_id = s.id
left join ent le on le.t = cur.lease_entity_type    and le.id = cur.lease_entity_id
left join ent oe on oe.t = cur.operator_entity_type and oe.id = cur.operator_entity_id
left join ent re on re.t = cur.revenue_entity_type  and re.id = cur.revenue_entity_id;
grant select on public.v_store_current_relations to authenticated, service_role;

-- =====================================================================
-- 管理画面用RPC（ポータル masters.html）。すべて本部/社長/マスターのみ・既存列(name等)には触れない
-- =====================================================================
create or replace function public.smv2_update_corporation(
  p_id uuid, p_legal_name text, p_display_name text, p_is_group_company boolean
) returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not store_master_can_edit() then raise exception '権限がありません（本部/社長/マスターのみ）'; end if;
  update public.corporations
     set legal_name = nullif(btrim(p_legal_name),''), display_name = nullif(btrim(p_display_name),''),
         is_group_company = coalesce(p_is_group_company, is_group_company), updated_at = now()
   where id = p_id;
end $$;

create or replace function public.smv2_add_corporation_alias(p_corporation_id uuid, p_alias text, p_source text default 'manual')
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid;
begin
  if not store_master_can_edit() then raise exception '権限がありません（本部/社長/マスターのみ）'; end if;
  if nullif(btrim(p_alias),'') is null then raise exception '別名を入力してください'; end if;
  insert into public.corporation_aliases (corporation_id, alias, source, created_by)
  values (p_corporation_id, btrim(p_alias), coalesce(nullif(btrim(p_source),''),'manual'), auth.uid())
  on conflict (alias, source) do update set corporation_id = excluded.corporation_id, is_active = true
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.smv2_set_corporation_alias_active(p_id uuid, p_active boolean)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not store_master_can_edit() then raise exception '権限がありません（本部/社長/マスターのみ）'; end if;
  update public.corporation_aliases set is_active = coalesce(p_active, true) where id = p_id;
end $$;

-- 店舗: 表示名・拠点種類のみ（name/is_active/corporation_idは変更しない）
create or replace function public.smv2_update_store(p_id uuid, p_display_name text, p_location_type text)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not store_master_can_edit() then raise exception '権限がありません（本部/社長/マスターのみ）'; end if;
  if p_location_type not in ('store','hq','central_kitchen','office','warehouse') then raise exception '拠点種類が不正です'; end if;
  update public.stores set display_name = nullif(btrim(p_display_name),''), location_type = p_location_type where id = p_id;
end $$;

create or replace function public.smv2_add_brand(p_name text, p_display_name text default null)
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid;
begin
  if not store_master_can_edit() then raise exception '権限がありません（本部/社長/マスターのみ）'; end if;
  if nullif(btrim(p_name),'') is null then raise exception 'ブランド名を入力してください'; end if;
  insert into public.brands (name, display_name) values (btrim(p_name), coalesce(nullif(btrim(p_display_name),''), btrim(p_name)))
  on conflict (name) do update set is_active = true returning id into v_id;
  return v_id;
end $$;

-- 店舗のブランド一式を置き換え（配列の先頭=主ブランド）。外れたものは削除せず終了日を入れる
create or replace function public.smv2_set_store_brands(p_store_id uuid, p_brand_ids uuid[])
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_today date := (now() at time zone 'Asia/Tokyo')::date; v_b uuid; v_i int := 0;
begin
  if not store_master_can_edit() then raise exception '権限がありません（本部/社長/マスターのみ）'; end if;
  update public.store_brand_relations set effective_to = v_today - 1
   where store_id = p_store_id and effective_to is null and not (brand_id = any(coalesce(p_brand_ids,'{}')));
  foreach v_b in array coalesce(p_brand_ids,'{}') loop
    v_i := v_i + 1;
    if exists (select 1 from public.store_brand_relations where store_id=p_store_id and brand_id=v_b and effective_to is null) then
      update public.store_brand_relations set is_primary = (v_i = 1)
       where store_id=p_store_id and brand_id=v_b and effective_to is null;
    else
      insert into public.store_brand_relations (store_id, brand_id, is_primary, effective_from)
      values (p_store_id, v_b, (v_i = 1), v_today);
    end if;
  end loop;
end $$;

-- 運営関係: 上書きではなく「いまの関係に終了日を入れて、新しい関係を追加」
create or replace function public.smv2_add_operation_relation(
  p_store_id uuid, p_relation_type text,
  p_lease_type text, p_lease_id uuid, p_operator_type text, p_operator_id uuid, p_revenue_type text, p_revenue_id uuid,
  p_effective_from date, p_term_months int default null, p_auto_renew boolean default false, p_note text default null
) returns uuid language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid; v_open public.store_operation_relations%rowtype;
begin
  if not store_master_can_edit() then raise exception '権限がありません（本部/社長/マスターのみ）'; end if;
  if p_effective_from is null then raise exception '開始日を入力してください'; end if;
  select * into v_open from public.store_operation_relations
   where store_id = p_store_id and effective_to is null order by effective_from desc limit 1;
  if found then
    if v_open.effective_from >= p_effective_from then
      raise exception '開始日は、いまの関係の開始日（%）より後にしてください', v_open.effective_from;
    end if;
    update public.store_operation_relations set effective_to = p_effective_from - 1 where id = v_open.id;
  end if;
  insert into public.store_operation_relations
    (store_id, relation_type, lease_entity_type, lease_entity_id, operator_entity_type, operator_entity_id,
     revenue_entity_type, revenue_entity_id, effective_from, contract_term_months, auto_renew, note, created_by)
  values (p_store_id, p_relation_type, p_lease_type, p_lease_id, p_operator_type, p_operator_id, p_revenue_type, p_revenue_id,
          p_effective_from, p_term_months, coalesce(p_auto_renew,false), p_note, auth.uid())
  returning id into v_id;
  return v_id;
end $$;

-- 運営関係を終了だけする（閉店・契約終了。新しい関係は追加しない）
create or replace function public.smv2_end_operation_relation(p_id uuid, p_effective_to date)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not store_master_can_edit() then raise exception '権限がありません（本部/社長/マスターのみ）'; end if;
  update public.store_operation_relations set effective_to = p_effective_to
   where id = p_id and effective_to is null and effective_from <= p_effective_to;
  if not found then raise exception '終了できる関係が見つかりません（終了済み・または開始日より前です）'; end if;
end $$;

create or replace function public.smv2_set_mapping_active(p_id uuid, p_active boolean)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not store_master_can_edit() then raise exception '権限がありません（本部/社長/マスターのみ）'; end if;
  update public.store_external_mappings set is_active = coalesce(p_active, true) where id = p_id;
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'smv2_update_corporation(uuid,text,text,boolean)','smv2_add_corporation_alias(uuid,text,text)',
    'smv2_set_corporation_alias_active(uuid,boolean)','smv2_update_store(uuid,text,text)',
    'smv2_add_brand(text,text)','smv2_set_store_brands(uuid,uuid[])',
    'smv2_add_operation_relation(uuid,text,text,uuid,text,uuid,text,uuid,date,int,boolean,text)',
    'smv2_end_operation_relation(uuid,date)','smv2_set_mapping_active(uuid,boolean)']
  loop
    execute format('revoke all on function public.%s from public', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- rollback:
--   drop view if exists public.v_store_current_relations;
--   drop function if exists public.resolve_store(text,text,text,text,text,boolean), public.register_store_mapping(text,text,text,text,uuid,uuid),
--     public.smv2_norm(text), public.smv2_corp_id_from_hint(text), public.smv2_update_corporation(uuid,text,text,boolean),
--     public.smv2_add_corporation_alias(uuid,text,text), public.smv2_set_corporation_alias_active(uuid,boolean),
--     public.smv2_update_store(uuid,text,text), public.smv2_add_brand(text,text), public.smv2_set_store_brands(uuid,uuid[]),
--     public.smv2_add_operation_relation(uuid,text,text,uuid,text,uuid,text,uuid,date,int,boolean,text),
--     public.smv2_end_operation_relation(uuid,date), public.smv2_set_mapping_active(uuid,boolean);
-- ---------------------------------------------------------------------
