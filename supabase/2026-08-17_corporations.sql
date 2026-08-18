-- ============================================================
-- 法人マスタの一本化（要件定義書v3.2 §16.5／実装指示書_第3期実装フェーズ §B）
-- 目的: hq_corps と info.corporations の二重化を解消し、正本 public.corporations を作る。
-- 既存テーブルはALTER・削除しない（追加のみ）。hq_corps・info.corporations は
-- 削除せず残す（互換維持）が、以後の新規書き込みは corporations 側に寄せる。
-- 冪等。
-- ============================================================

-- ---- 正本テーブル ----
-- id は hq_corps.id をそのまま引き継ぐ（既存のhq_タスク画面・データとの整合を保つため。
-- なお hq_tasks.corp / hq_task_templates.corp は元々「法人名の文字列」を持つ設計で
-- hq_corps.idへのFKではないため、このid引き継ぎ自体はhq_タスク側のデータ移行を必要としない）。
-- name は既存UIでバッジ表示に使っている短い表示名（hq_corps由来）をそのまま正とする。
-- corp_code・法人の正式名称の出どころは info.corporations（社内情報管理システムの法人マスタ、
-- 4社・codeあり）。legacy_info_id で info.corporations.id と対応付ける。
-- idにはdefault gen_random_uuid()を付けておく（今回の初期投入ではhq_corps.idを明示指定して
-- 上書きするが、今後「法人管理」画面から新規法人を追加するときはこの既定値でid採番される）
-- name unique: hq_corpsのname text not null uniqueと同じ制約を引き継ぐ（法人管理画面の
-- 「追加できませんでした（同名の法人がある可能性があります）」という既存の案内文と挙動を合わせるため）
create table if not exists corporations (
  id uuid primary key default gen_random_uuid(),
  corp_code text unique,
  name text not null unique,
  sort_order int not null default 100,
  is_active boolean not null default true,
  legacy_info_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table corporations alter column id set default gen_random_uuid();
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'corporations_name_key') then
    alter table corporations add constraint corporations_name_key unique (name);
  end if;
end $$;

-- hq_corpsの4法人を投入。corp_code・legacy_info_idはinfo.corporationsとの名称突き合わせで補う
-- （名称の対応は2026-08-17時点で実データを目視確認済み: LiveGate=livegate／SK=sk／
--  N-Style=nstyle／トーホー=toho）。突き合わせが見つからない法人が将来増えた場合は
-- corp_code・legacy_info_idがnullのまま入るだけで、エラーにはならない（追加のみの移行方針）。
insert into corporations (id, corp_code, name, sort_order, is_active, legacy_info_id, updated_at)
select
  h.id,
  cm.code,
  h.name,
  h.sort_order,
  h.is_active,
  cm.info_id,
  now()
from hq_corps h
left join (
  select ic.id as info_id, ic.code,
    case ic.code
      when 'livegate' then 'LiveGate'
      when 'sk' then 'SK'
      when 'nstyle' then 'N-Style'
      when 'toho' then 'トーホー'
      else null
    end as hq_name
  from info.corporations ic
) cm on cm.hq_name = h.name
on conflict (id) do update set
  corp_code = excluded.corp_code,
  name = excluded.name,
  sort_order = excluded.sort_order,
  is_active = excluded.is_active,
  legacy_info_id = excluded.legacy_info_id,
  updated_at = now();

alter table corporations enable row level security;
drop policy if exists corp_read on corporations;
create policy corp_read on corporations for select using (auth.uid() is not null);
drop policy if exists corp_write on corporations;
create policy corp_write on corporations for all using (portal_can_post()) with check (portal_can_post());

-- ---- 店舗マスタとの関連 ----
-- 既存列は一切触らず、corporation_id列だけ追加する。
alter table stores add column if not exists corporation_id uuid references corporations(id);

-- info.stores（店番01〜05・鳥一代グループのみ収録）との店舗名一致で埋められる分だけ埋める。
-- 06〜12（2枚看板店・委託店）はinfo.stores未収録のため対応が取れず、nullのまま残す
-- （法人が不明な店舗を推測で確定しない。ユーザーに一覧を提示して確定してもらう）。
update stores s set corporation_id = c.id
from info.stores ist
join corporations c on c.legacy_info_id = ist.corporation_id
where ist.name = s.name and s.corporation_id is null and s.corporation_id is distinct from c.id;
