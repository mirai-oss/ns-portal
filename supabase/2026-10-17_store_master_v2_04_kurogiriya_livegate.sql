-- =====================================================================
-- 黒霧屋 新横浜の運営変更（トーホー→LiveGate・2026-11-01）準備（担当F）
-- 指示書: ns-portal/docs/指示書_黒霧屋運営変更_2026-11-01_準備_2026-10-17.md §2
-- 前提: 店舗正本 2026-10-07_store_master_v2_01/_02 ＋ 2026-10-13_..._03 を適用済み
--
-- 【事前報告様式（DB変更）】
-- 理由: ①2026-11-01から黒霧屋 新横浜の運営会社がトーホー→LiveGateに変わる（名義=N-Style・入金先=N-Style・グループ内運営・運営委託費なし）。
--       運営関係は期間で持つ表のため、上書きせず「旧行に終了日＋新行を追加」する。
--       ②LiveGateのスマレジ契約はスマレジの店舗IDを契約ごとに採番する（同じ番号が別の店舗を指しうる）ため、
--       店舗IDの一意の判定に「契約（＝法人ヒント）」を含め、取り違えを防ぐ（担当Dの複数契約対応の前提・店舗マッピングが先）。
-- 現構造（2026-10-17 本番を読み取り専用で確認）:
--   store_operation_relations: 黒霧屋 新横浜は 1行（2026-03-01〜・outsourcing・名義N-Style・運営トーホー・入金N-Style・12か月自動更新）。
--   store_external_mappings: smaregi/smaregi_timecard のID行（01〜 全店）は corporation_hint が空（=契約が不明）。一意索引は (source, ID) のみで
--       LiveGate契約の店舗IDが既存のトーホー側の番号と同じだと登録できない（衝突）。
-- 変更:
--   A. 黒霧屋 新横浜: トーホー運営の行に effective_to=2026-10-31 を入れ、LiveGate運営の行を effective_from=2026-11-01 で追加（上書きなし）
--   B. 契約対応（追加・既存の解決結果は変わらない）:
--      B1 スマレジ系ID行（smaregi / smaregi_timecard）の corporation_hint を 'toho'（現在の契約）に補完（hint空の行のみ）
--      B2 一意索引をスマレジ系だけ「(source, 契約, ID/コード/名前)」に作り直す（他のsourceは従来どおり）
--      B3 resolve_store の①〜③を契約対応に（呼び出し方・戻り値は同じ。スマレジ系で法人ヒントを渡すとその契約の店舗だけに当たる。
--         ヒント無しで複数店舗に当たる場合は誤って当てず未解決扱い）＋基準日 p_as_of を追加（省略=今日。旧6引数版を7引数版に置換・≤6引数の呼び出しはそのまま動く）
--   C. LiveGate契約sdm155v1の黒霧屋 新横浜=スマレジ事業所ID 4（smaregi / smaregi_timecard の2行・hint=livegate・2026-11-01開始）を追加し、
--      トーホー契約側（ID 8）の2行は effective_to=2026-10-31。LiveGateのID 4 はトーホー契約のID 4（鳥一代 恵比寿）と同番号＝Bがないと登録できない
-- 既存データへの影響: 店舗・法人・既存の運営関係の値は変更しない（黒霧屋の旧行は終了日が入るだけ）。resolve_store の現在の解決結果は変わらない
--   （全てのスマレジ行がトーホー契約の1本だけのため）。
-- ※ 黒霧屋の resolve_store(...).corporation_id は 店舗の既存列 stores.corporation_id（=トーホー）のまま。運営法人は v_store_current_relations.operator_* を使うこと。
-- 冪等。 rollback: ファイル末尾のコメント参照。
-- =====================================================================

-- ---------------------------------------------------------------------
-- A. 黒霧屋 新横浜の運営関係の切替（上書き禁止＝終了日＋新しい行）
-- ---------------------------------------------------------------------
update public.store_operation_relations r
   set effective_to = date '2026-10-31',
       note = concat_ws(' / ', r.note, '2026-11-01から運営がトーホー→LiveGateに変更（この行は2026-10-31で終了）')
  from public.stores s, public.corporations c
 where r.store_id = s.id and s.name = '黒霧屋 新横浜'
   and r.operator_entity_type = 'corporation' and r.operator_entity_id = c.id and c.corp_code = 'toho'
   and r.effective_to is null and r.effective_from < date '2026-11-01';

insert into public.store_operation_relations
  (store_id, relation_type, lease_entity_type, lease_entity_id, operator_entity_type, operator_entity_id,
   revenue_entity_type, revenue_entity_id, effective_from, contract_term_months, auto_renew, note)
select s.id, 'outsourcing', 'corporation', n.id, 'corporation', l.id, 'corporation', n.id,
       date '2026-11-01', null, false,
       '2026-11-01 運営がトーホー→LiveGate（グループ内運営・運営委託費なし・名義/入金先はN-Style）。契約期間は未登録'
  from public.stores s
  join public.corporations n on n.corp_code = 'nstyle'
  join public.corporations l on l.corp_code = 'livegate'
 where s.name = '黒霧屋 新横浜'
   and not exists (select 1 from public.store_operation_relations x
                    where x.store_id = s.id and x.effective_from = date '2026-11-01');

-- ---------------------------------------------------------------------
-- B. スマレジの契約ごとの店舗ID（同じ番号が契約違いで別店舗を指しても取り違えない）
-- ---------------------------------------------------------------------
-- B1 既存のスマレジ系ID行は全てトーホー契約
update public.store_external_mappings
   set corporation_hint = 'toho'
 where source_system in ('smaregi','smaregi_timecard') and external_store_id is not null and corporation_hint is null;

-- B2 一意索引: スマレジ系は契約（corporation_hint）を含める／他のsourceは従来どおり
drop index if exists public.store_external_mappings_uq_id;
drop index if exists public.store_external_mappings_uq_name;
drop index if exists public.store_external_mappings_uq_code;
create unique index if not exists store_external_mappings_uq_id
  on public.store_external_mappings (source_system, external_store_id)
  where external_store_id is not null and source_system not in ('smaregi','smaregi_timecard');
create unique index if not exists store_external_mappings_uq_name
  on public.store_external_mappings (source_system, external_store_name)
  where external_store_name is not null and source_system not in ('smaregi','smaregi_timecard');
create unique index if not exists store_external_mappings_uq_code
  on public.store_external_mappings (source_system, external_store_code)
  where external_store_code is not null and source_system not in ('smaregi','smaregi_timecard');
create unique index if not exists store_external_mappings_uq_id_contract
  on public.store_external_mappings (source_system, coalesce(corporation_hint, ''), external_store_id)
  where external_store_id is not null and source_system in ('smaregi','smaregi_timecard');
create unique index if not exists store_external_mappings_uq_name_contract
  on public.store_external_mappings (source_system, coalesce(corporation_hint, ''), external_store_name)
  where external_store_name is not null and source_system in ('smaregi','smaregi_timecard');
create unique index if not exists store_external_mappings_uq_code_contract
  on public.store_external_mappings (source_system, coalesce(corporation_hint, ''), external_store_code)
  where external_store_code is not null and source_system in ('smaregi','smaregi_timecard');

-- B3 外部マッピングの候補選び（resolve_store の①〜③から呼ぶ）
--   p_field: 'id'／'code'／'name'。スマレジ系は契約（corporation_hint）で絞り、複数店舗に当たるなら0行（誤って当てない）。
--   その他のsourceは従来どおり（法人ヒント一致を優先して1件）
create or replace function public.smv2_pick_mapping(
  p_source text, p_field text, p_value text, p_hint_corp uuid, p_today date
) returns setof public.store_external_mappings
language sql stable security definer
set search_path to 'public'
as $$
  with cand as (
    select m.* from public.store_external_mappings m
     where m.source_system = p_source and m.is_active
       and (m.effective_from is null or m.effective_from <= p_today) and (m.effective_to is null or m.effective_to >= p_today)
       and case p_field when 'id' then m.external_store_id = p_value
                        when 'code' then m.external_store_code = p_value
                        else m.external_store_name = p_value end
  ), filt as (
    -- スマレジ系で契約（法人）が指定されたら、その契約の行（hint空の行は契約不明＝ワイルドカード）だけに絞る
    select c.* from cand c
     where not (p_source in ('smaregi','smaregi_timecard') and p_hint_corp is not null
                and c.corporation_hint is not null
                and smv2_corp_id_from_hint(c.corporation_hint) is distinct from p_hint_corp)
  ), n as (select count(distinct store_id) as cnt from filt)
  select f.* from filt f, n
   -- スマレジ系で契約を特定できず複数店舗に当たるときは誤って当てない（0行）
   where not (p_source in ('smaregi','smaregi_timecard') and n.cnt > 1)
   order by (p_hint_corp is not null and smv2_corp_id_from_hint(f.corporation_hint) = p_hint_corp) desc, f.created_at
   limit 1;
$$;
revoke all on function public.smv2_pick_mapping(text,text,text,uuid,date) from public;
grant execute on function public.smv2_pick_mapping(text,text,text,uuid,date) to authenticated, service_role;

-- resolve_store（①〜③のみ契約対応に。④以降・戻り値・引数は変更なし）
drop function if exists public.resolve_store(text,text,text,text,text,boolean);
create or replace function public.resolve_store(
  p_source text,
  p_external_id text default null,
  p_code text default null,
  p_name text default null,
  p_corp_hint text default null,
  p_log boolean default true,
  p_as_of date default null          -- 基準日（省略=今日）。過去の勤怠・給与を後から取り込む時に、その日時点の対応で引く
) returns table (store_id uuid, brand_id uuid, corporation_id uuid, confidence text, matched_by text)
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_today date := coalesce(p_as_of, (now() at time zone 'Asia/Tokyo')::date);
  v_hint_corp uuid := smv2_corp_id_from_hint(p_corp_hint);
  v_n text := smv2_norm(p_name);
  v_store uuid; v_brand uuid; v_map public.store_external_mappings%rowtype;
  v_conf text; v_by text; v_cnt int;
  v_ids uuid[];
begin
  -- ①〜③ 外部マッピング（有効・期間内）。スマレジ系（契約ごとに店舗IDを採番）は契約＝法人ヒントで絞り、
  --   絞れず複数店舗に当たる場合は誤って当てずに次の段へ（smv2_pick_mapping）
  if p_external_id is not null and btrim(p_external_id) <> '' then
    select m.* into v_map from public.smv2_pick_mapping(p_source, 'id', btrim(p_external_id), v_hint_corp, v_today) m;
    if found then v_store := v_map.store_id; v_brand := v_map.brand_id; v_conf := 'exact'; v_by := 'mapping:external_id'; end if;
  end if;
  if v_store is null and p_code is not null and btrim(p_code) <> '' then
    select m.* into v_map from public.smv2_pick_mapping(p_source, 'code', btrim(p_code), v_hint_corp, v_today) m;
    if found then v_store := v_map.store_id; v_brand := v_map.brand_id; v_conf := 'exact'; v_by := 'mapping:code'; end if;
  end if;
  if v_store is null and p_name is not null and btrim(p_name) <> '' then
    select m.* into v_map from public.smv2_pick_mapping(p_source, 'name', btrim(p_name), v_hint_corp, v_today) m;
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
revoke all on function public.resolve_store(text,text,text,text,text,boolean,date) from public;
grant execute on function public.resolve_store(text,text,text,text,text,boolean,date) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- C. LiveGateのスマレジ契約（sdm155v1）の「黒霧屋 新横浜」: スマレジの事業所ID=4（担当Dが /stores を読んで確認・2026-10-17）
--    トーホー契約（sez093z1）側の黒霧屋はID 8 → 2026-10-31で終了。smaregi / smaregi_timecard の2行ずつ。
--    ※LiveGate契約のID 2（【不動産】グットレジデンス横浜店）・3（本社）は店舗マスタに無いためマッピングしない（未対応のまま隔離）
--    ※LiveGateのID 4 は、トーホー契約のID 4（鳥一代 恵比寿）と同じ番号＝B2の契約別の一意索引がないと登録できない
-- ---------------------------------------------------------------------
update public.store_external_mappings m
   set effective_to = date '2026-10-31',
       note = concat_ws(' / ', m.note, '2026-11-01から運営がLiveGateへ変更（トーホー契約側のこの行は2026-10-31で終了）')
  from public.stores s
 where m.store_id = s.id and s.name = '黒霧屋 新横浜'
   and m.source_system in ('smaregi','smaregi_timecard') and m.external_store_id = '8'
   and m.corporation_hint = 'toho' and m.effective_to is null;

insert into public.store_external_mappings
  (store_id, source_system, external_store_id, corporation_hint, effective_from, note)
select s.id, src.sys, '4', 'livegate', date '2026-11-01',
       'LiveGate契約sdm155v1の店舗「黒霧屋 新横浜」のスマレジ事業所ID=4（担当Dが/storesで確認 2026-10-17）'
  from public.stores s
 cross join (values ('smaregi'), ('smaregi_timecard')) as src(sys)
 where s.name = '黒霧屋 新横浜'
   and not exists (select 1 from public.store_external_mappings x
                    where x.source_system = src.sys and x.corporation_hint = 'livegate' and x.external_store_id = '4');

-- ---------------------------------------------------------------------
-- rollback:
--   -- A（運営関係を元に戻す）: 
--   delete from public.store_operation_relations r using public.stores s where r.store_id=s.id and s.name='黒霧屋 新横浜' and r.effective_from=date '2026-11-01';
--   update public.store_operation_relations r set effective_to=null from public.stores s where r.store_id=s.id and s.name='黒霧屋 新横浜' and r.effective_to=date '2026-10-31';
--   -- B（契約対応を戻す）: 索引を (source, ID) に戻し、resolve_store は 02 の定義へ（02のファイルを再実行）
--   drop index if exists public.store_external_mappings_uq_id_contract, public.store_external_mappings_uq_name_contract, public.store_external_mappings_uq_code_contract;
--   drop function if exists public.smv2_pick_mapping(text,text,text,uuid,date);
--   -- C: delete from public.store_external_mappings where corporation_hint='livegate' and external_store_id='4' and source_system in ('smaregi','smaregi_timecard');
--   --    update public.store_external_mappings set effective_to=null where corporation_hint='toho' and external_store_id='8' and effective_to=date '2026-10-31' and source_system in ('smaregi','smaregi_timecard');
--   -- resolve_store を6引数版へ戻す: drop function public.resolve_store(text,text,text,text,text,boolean,date); のあと 02 のファイルを再実行
-- ---------------------------------------------------------------------
