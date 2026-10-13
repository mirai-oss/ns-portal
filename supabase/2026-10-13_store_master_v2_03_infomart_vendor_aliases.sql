-- =====================================================================
-- 店舗・法人正本Phase1 同梱 — ③ インフォマート店舗コード対応・取引先の別名（vendor_aliases）・定期請求書10社seed
-- 担当F ／ 設計: docs/seed_定期請求書10社_2026-10-11.md（§2・§3・確定=2026-10-12 Sync11）
--        docs/実装指示書_請求書自動処理_担当CFE_2026-10-11.md「担当F（Phase1に同梱・小）」
-- 前提: 2026-10-07_store_master_v2_01 / _02 を適用済み（本番適用済み・2026-10-07）
--
-- 【事前報告様式（DB変更）】
-- 理由: 請求書自動処理（担当C Phase4）で ①請求書に書かれたインフォマート店舗コード(01〜08)から店舗を判定し、
--       ②請求元の表記ゆれ（㈲染谷商店／染谷商店 等）から取引先を判定できるようにするため。
-- 現構造（2026-10-13 本番を読み取り専用で確認）:
--   store_external_mappings: source_system の許可リストに 'infomart' が無い（check制約）／同一(source,コード)の重複防止が無い。
--   vendors 86件（10社のうち「株式会社プレコ」1件が名前の一部だけ似ているが別会社の疑い→統合しない）／vendor_aliases は未作成／vendors.email_domains は未作成。
-- 変更（追加のみ。既存の列・行・他システムの読み取りは不変）:
--   (1) store_external_mappings の source_system 許可リストに 'infomart' を追加（制約を作り直し）＋(source,コード)の一意索引
--   (2) register_store_mapping を再定義（許可リストに infomart を追加＋「外部コード」でも既存の登録を検出して別店舗への上書きを拒否）
--   (3) vendors に email_domains text[]（既知の送信元ドメイン。空のまま・既存行は影響なし）を追加
--   (4) vendor_aliases 新設（請求元の別名→取引先。unique(alias, source)）＋書き込みRPC register_vendor_alias（本部/社長/マスター、または請求書権限の人）
--   (5) インフォマート店舗コード対応 8行を store_external_mappings へ（source='infomart'・コード01〜08・請求書上の表記・ブランド付き）
--   (6) 定期請求書10社の取引先を vendors に登録（同じ法人番号・同名が既にあれば追加しない）＋別名をvendor_aliasesへ
-- 既存データへの影響: なし（stores/corporations/既存mappingsは触らない）。vendors は新規行の追加のみ（会計用の既定科目・口座は空）。
-- ★重要な照合結果: ハブ stores.store_no とインフォマートコードは 06 と 08 が逆（下記）。コードは source 別に持つので衝突しないが、
--   「store_no をインフォマートコードとして使う」実装は 黒霧屋 新横浜 と 鶏武者 新横浜 を取り違える。
-- 冪等: 何度流しても壊れない。 rollback: ファイル末尾のコメント参照。
-- =====================================================================

-- (1) source_system に 'infomart' を追加（制約名は環境で違い得るため定義から探して作り直す）
do $$
declare c text;
begin
  for c in select conname from pg_constraint
           where conrelid = 'public.store_external_mappings'::regclass and contype = 'c'
             and pg_get_constraintdef(oid) ilike '%source_system%' loop
    execute format('alter table public.store_external_mappings drop constraint %I', c);
  end loop;
  alter table public.store_external_mappings add constraint store_external_mappings_source_system_check
    check (source_system in ('smaregi','smaregi_timecard','invoice','tabelog','hotpepper','gurunavi','gbp','reservation','payroll',
                             'settlement','ad','delivery','dashboard','infomart','legacy_alias'));
end $$;

create unique index if not exists store_external_mappings_uq_code
  on public.store_external_mappings (source_system, external_store_code) where external_store_code is not null;

-- (2) register_store_mapping（許可リストに infomart を追加＋外部コードでも重複を検出）
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
       'reservation','payroll','settlement','ad','delivery','dashboard','infomart','legacy_alias') then
    raise exception 'source_system が不正です: %', p_source;
  end if;
  if not exists (select 1 from public.stores where id = p_store_id) then raise exception '店舗が存在しません'; end if;
  if coalesce(nullif(btrim(p_external_id),''), nullif(btrim(p_code),''), nullif(btrim(p_name),'')) is null then
    raise exception '外部ID・コード・名称のいずれかを入力してください';
  end if;

  select * into v_old from public.store_external_mappings m
    where m.source_system = p_source
      and ((nullif(btrim(p_external_id),'') is not null and m.external_store_id = btrim(p_external_id))
        or (nullif(btrim(p_code),'') is not null and m.external_store_code = btrim(p_code))
        or (nullif(btrim(p_name),'') is not null and m.external_store_name = btrim(p_name)))
    order by m.is_active desc limit 1;
  if found then
    if v_old.is_active and v_old.store_id <> p_store_id then
      raise exception 'この外部名/ID/コードは既に別の店舗に登録されています（先に無効化してください）';
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

-- (3) vendors.email_domains
alter table public.vendors add column if not exists email_domains text[] not null default '{}';
comment on column public.vendors.email_domains is '既知の送信元メールドメイン（請求書メール自動分類の「既知送信元ルール」用）。空=未設定';

-- (4) vendor_aliases
create table if not exists public.vendor_aliases (
  id uuid primary key default gen_random_uuid(),
  vendor_id uuid not null references public.vendors(id),
  alias text not null,
  source text not null default 'manual',
  created_by uuid references public.users(id),
  created_at timestamptz not null default now(),
  is_active boolean not null default true,
  unique (alias, source)
);
create index if not exists vendor_aliases_vendor_idx on public.vendor_aliases (vendor_id);
comment on table public.vendor_aliases is '請求元の表記ゆれ（㈲染谷商店／染谷商店 等）→取引先。請求書OCRの請求元名の判定に使う';
alter table public.vendor_aliases enable row level security;
drop policy if exists vendor_aliases_select_auth on public.vendor_aliases;
create policy vendor_aliases_select_auth on public.vendor_aliases for select to authenticated using (true);

-- 別名の登録口（「今後この内容で処理する」ボタン等）。本部/社長/マスター、または請求書・会計の権限を持つ人
create or replace function public.register_vendor_alias(p_vendor_id uuid, p_alias text, p_source text default 'manual')
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid; v_other uuid;
begin
  if not (store_master_can_edit() or invoice_can_access()) then raise exception '権限がありません'; end if;
  if nullif(btrim(p_alias),'') is null then raise exception '別名を入力してください'; end if;
  if not exists (select 1 from public.vendors where id = p_vendor_id) then raise exception '取引先が存在しません'; end if;
  select vendor_id into v_other from public.vendor_aliases
   where alias = btrim(p_alias) and is_active and vendor_id <> p_vendor_id limit 1;
  if v_other is not null then raise exception 'この別名は既に別の取引先に登録されています'; end if;
  insert into public.vendor_aliases (vendor_id, alias, source, created_by)
  values (p_vendor_id, btrim(p_alias), coalesce(nullif(btrim(p_source),''),'manual'), auth.uid())
  on conflict (alias, source) do update set vendor_id = excluded.vendor_id, is_active = true
  returning id into v_id;
  return v_id;
end $$;
revoke all on function public.register_vendor_alias(uuid,text,text) from public;
grant execute on function public.register_vendor_alias(uuid,text,text) to authenticated;

create or replace function public.set_vendor_alias_active(p_id uuid, p_active boolean)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not (store_master_can_edit() or invoice_can_access()) then raise exception '権限がありません'; end if;
  update public.vendor_aliases set is_active = coalesce(p_active, true) where id = p_id;
end $$;
revoke all on function public.set_vendor_alias_active(uuid,boolean) from public;
grant execute on function public.set_vendor_alias_active(uuid,boolean) to authenticated;

-- (5) インフォマート店舗コード対応（seed §2）。ブランド: 07/08は「匠味」（2枚看板）、他は店舗の主ブランド
--   ★照合: ハブ stores.store_no は 06=鶏武者 新横浜／08=黒霧屋 新横浜 だが、インフォマートは 06=黒霧屋 新横浜／08=鶏武者 新横浜（逆）。
--          MF部門（06新横浜黒霧屋／08新横浜・匠味/鶏武者）の番号と一致している。store_no は使わず、店舗は名前で結ぶ。
insert into public.store_external_mappings
  (store_id, brand_id, source_system, external_store_code, external_store_name, corporation_hint, note)
select s.id,
       coalesce((select b.id from public.brands b where b.name = m.brand_name),
                (select r.brand_id from public.store_brand_relations r where r.store_id = s.id and r.is_primary and r.effective_to is null limit 1)),
       'infomart', m.code, m.inv_name, 'toho',
       'seed 2026-10-11 §2（インフォマート自社コード'||m.code||'・MF部門 '||m.mf||'）'
from (values
  ('01','鳥一代 本店',   '鳥一代 本店',   null,   '01本店'),
  ('02','鳥一代 はなれ', '鳥一代 はなれ', null,   '02はなれ'),
  ('03','鳥一代 芝店',   '芝の鳥一代',   null,   '03芝'),
  ('04','鳥一代 恵比寿店','鳥一代 恵比寿', null,   '04恵比寿'),
  ('05','鳥一代 新橋店', '鳥一代 新橋',   null,   '05新橋'),
  ('06','黒霧屋 新横浜', '黒霧屋 新横浜', null,   '06新横浜黒霧屋'),
  ('07','匠味 川崎店',   '鶏武者 川崎店', '匠味', '07川崎・匠味/鶏武者'),
  ('08','匠味 新横浜店', '鶏武者 新横浜', '匠味', '08新横浜・匠味/鶏武者')
) as m(code, inv_name, store_name, brand_name, mf)
join public.stores s on s.name = m.store_name
where not exists (select 1 from public.store_external_mappings x
                  where x.source_system = 'infomart' and (x.external_store_code = m.code or x.external_store_name = m.inv_name));

-- (6) 定期請求書10社: 取引先（無ければ追加）＋別名。法人番号=登録番号からTを除いた13桁（10社とも法人）
create temp table _seed_vendors (name text, regno text, core text, aliases text[]) on commit drop;
insert into _seed_vendors values
  ('有限会社染谷商店','T9010702004685','染谷商店',               array['㈲染谷商店','染谷商店']),
  ('有限会社森和','T3010602031075','森和',                       array['㈲森和','森和']),
  ('コカ・コーラボトラーズジャパン株式会社','T9020001043244','コカ・コーラボトラーズジャパン', array['コカ・コーラボトラーズ','セントラル富士']),
  ('株式会社フレッシュエージェント','T4030003006946','フレッシュエージェント', array['野菜の丸平','フレッシュエージェント']),
  ('株式会社プレコフーズ','T5010801013582','プレコフーズ',       array['プレコエムユニット','㈱プレコフーズ']),
  ('株式会社西原商会','T3340001003270','西原商会',               array['㈱西原商会','西原商会関東 川崎支店']),
  ('株式会社タジマフーズ','T3010802016751','タジマフーズ',       array['㈱タジマフーズ','タジマ青果','成瀬商店']),
  ('株式会社シモヤマ','T7010601002833','シモヤマ',               array['㈱シモヤマ']),
  ('有限会社伊勢五本店','T8010002049713','伊勢五本店',           array['㈲伊勢五本店','伊勢五本店']),
  ('株式会社アールエスエス','T8011801005559','アールエスエス',   array['RSS','アールエスエス']);

insert into public.vendors (name, corporation_number, notes)
select s.name, substr(s.regno, 2),
       '定期請求書10社seed（2026-10-11）。インボイス登録番号 '||s.regno||'。既定の科目・口座は未設定（担当Cが投入）'
from _seed_vendors s
where not exists (
  select 1 from public.vendors x
  where x.corporation_number = substr(s.regno, 2)
     or replace(replace(replace(replace(replace(replace(normalize(x.name, NFKC),' ',''),'　',''),'株式会社',''),'有限会社',''),'(株)',''),'(有)','')
        like '%' || replace(normalize(s.core, NFKC),' ','') || '%'
);

insert into public.vendor_aliases (vendor_id, alias, source)
select v.id, a.alias, 'seed_infomart_2026-10-11'
from _seed_vendors s
join lateral (
  select x.id from public.vendors x
  where x.corporation_number = substr(s.regno, 2)
     or replace(replace(replace(replace(replace(replace(normalize(x.name, NFKC),' ',''),'　',''),'株式会社',''),'有限会社',''),'(株)',''),'(有)','')
        like '%' || replace(normalize(s.core, NFKC),' ','') || '%'
  order by (x.corporation_number = substr(s.regno, 2)) desc, x.created_at limit 1
) v on true
cross join lateral unnest(s.aliases) as a(alias)
on conflict (alias, source) do nothing;

-- ---------------------------------------------------------------------
-- rollback（新設物と本seedだけを戻す。既存データには触れない）:
--   delete from public.store_external_mappings where source_system='infomart';
--   delete from public.vendor_aliases where source='seed_infomart_2026-10-11';
--   delete from public.vendors where notes like '定期請求書10社seed（2026-10-11）%'
--     and id not in (select vendor_id from public.invoices where vendor_id is not null);
--   drop table if exists public.vendor_aliases;
--   drop function if exists public.register_vendor_alias(uuid,text,text), public.set_vendor_alias_active(uuid,boolean);
--   alter table public.vendors drop column if exists email_domains;
--   drop index if exists public.store_external_mappings_uq_code;
--   （source_system制約から 'infomart' を外すのは不要。残して問題なし）
-- ---------------------------------------------------------------------
