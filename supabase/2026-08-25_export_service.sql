-- ============================================================
-- 担当G: 共通データ出力センター（Export Service）Phase 1
-- 実装指示書_担当G_データ出力センター_2026-08-25.md
-- 調査レポート_担当G_データ出力センター_2026-08-25.md（承認済み6点）に基づく設計。
--
-- 縄張り: export_ / tpl_ 接頭辞の新規テーブルのみ（既存テーブルは一切触らない）。
-- 冪等。何度実行しても壊れない。
-- ============================================================

-- ============================================================
-- 権限判定関数（法人単位RLSがハブ本体に前例が無いため新規整備。§8の推奨方針）
-- ============================================================

-- データ出力センターへのアクセス可否（管理者メニュー相当。CEO/HQ/TEAM/TENCHO＋マスター。
-- SHAIN/ALは対象外＝本部タスクボード等と同じ「管理者メニュー」の考え方を踏襲）
create or replace function export_can_access() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((
    select (u.is_master or u.role in ('CEO','HQ','TEAM','TENCHO'))
    from users u where u.id = auth.uid() and u.is_active
  ), false);
$$;

-- テンプレート管理（アップロード・差し替え）はより絞る＝マスター/CEO/HQのみ
create or replace function export_can_manage_templates() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((
    select (u.is_master or u.role in ('CEO','HQ'))
    from users u where u.id = auth.uid() and u.is_active
  ), false);
$$;

-- このユーザーが出力対象にできる店舗ID一覧。
--   is_master/CEO/HQ = 全有効店舗
--   TEAM             = 自分のteam_idが担当するteam_stores経由の店舗
--   TENCHO           = 自分がuser_storesで紐付く店舗
--   それ以外（SHAIN/AL等）= 空配列（export_can_access()側で先にブロックされる想定だが二重に安全側）
create or replace function export_allowed_store_ids(p_uid uuid default auth.uid())
returns uuid[]
language sql stable security definer set search_path = public as $$
  select case
    when exists(
      select 1 from users u where u.id = p_uid and u.is_active and (u.is_master or u.role in ('CEO','HQ'))
    ) then (select coalesce(array_agg(id), array[]::uuid[]) from stores where is_active)
    when exists(
      select 1 from users u where u.id = p_uid and u.is_active and u.role = 'TEAM'
    ) then (
      select coalesce(array_agg(distinct ts.store_id), array[]::uuid[])
      from team_stores ts
      join users u on u.team_id = ts.team_id and u.id = p_uid
    )
    when exists(
      select 1 from users u where u.id = p_uid and u.is_active and u.role = 'TENCHO'
    ) then (
      select coalesce(array_agg(distinct us.store_id), array[]::uuid[])
      from user_stores us where us.user_id = p_uid
    )
    else array[]::uuid[]
  end;
$$;

-- ============================================================
-- テンプレート管理（指示書§4）
-- ============================================================
create table if not exists tpl_templates (
  id uuid primary key default gen_random_uuid(),
  template_code text not null unique,      -- 'pl_monthly' 等。コード側のレンダラー対応表のキー
  template_name text not null,             -- '月次PL／年間推移PL'
  category text not null,                  -- '経営・売上' 等（指示書§3のカテゴリー）
  description text,
  file_path text,                          -- Storage export-templates バケット内のパス（null=コード生成のみ・テンプレ未登録）
  renderer_key text not null,              -- どのレンダラー関数を使うか（コード側で対応）
  layout jsonb not null default '{}'::jsonb, -- レンダラーへ渡す軽量設定（見出し行番号・データ開始行等。座標マッピングのみ・変換ロジックは持たせない）
  version int not null default 1,
  is_active boolean not null default true,
  created_by uuid references users(id),
  created_at timestamptz not null default now(),
  updated_by uuid references users(id),
  updated_at timestamptz not null default now()
);

-- 過去バージョン（差し替え履歴。file_path上書きはせず新規行を追加）
create table if not exists tpl_template_versions (
  id uuid primary key default gen_random_uuid(),
  template_id uuid not null references tpl_templates(id) on delete cascade,
  version int not null,
  file_path text,
  layout jsonb,
  note text,
  created_by uuid references users(id),
  created_at timestamptz not null default now(),
  unique (template_id, version)
);

alter table tpl_templates enable row level security;
alter table tpl_template_versions enable row level security;

drop policy if exists tpl_templates_read on tpl_templates;
create policy tpl_templates_read on tpl_templates for select using (export_can_access());
drop policy if exists tpl_templates_write on tpl_templates;
create policy tpl_templates_write on tpl_templates for all
  using (export_can_manage_templates()) with check (export_can_manage_templates());

drop policy if exists tpl_versions_read on tpl_template_versions;
create policy tpl_versions_read on tpl_template_versions for select using (export_can_access());
drop policy if exists tpl_versions_write on tpl_template_versions;
create policy tpl_versions_write on tpl_template_versions for all
  using (export_can_manage_templates()) with check (export_can_manage_templates());

-- ============================================================
-- 出力履歴（監査ログ。指示書§9）
-- actor_type は invoice_audit_logs の前例(human/ai)を踏襲＝将来のHermes連携(§13)への布石
-- ============================================================
create table if not exists export_history (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id),
  template_id uuid references tpl_templates(id),
  report_key text not null,
  export_type text not null check (export_type in ('excel','csv','sheets')),
  corporation_ids uuid[],
  store_ids uuid[],
  period_from text,   -- 'YYYY-MM'
  period_to text,     -- 'YYYY-MM'
  filters jsonb,
  file_path text,
  sheet_url text,
  status text not null default 'pending' check (status in ('pending','processing','completed','failed')),
  error_message text,
  row_count int,
  file_size_bytes bigint,
  duration_ms int,
  actor_type text not null default 'human' check (actor_type in ('human','ai')),
  created_at timestamptz not null default now(),
  completed_at timestamptz
);
create index if not exists export_history_user_idx on export_history (user_id, created_at desc);
create index if not exists export_history_report_idx on export_history (report_key, created_at desc);

alter table export_history enable row level security;
-- 閲覧: 本人の出力履歴、または管理者は全件（監査目的）
drop policy if exists export_history_read on export_history;
create policy export_history_read on export_history for select using (
  user_id = auth.uid() or export_can_manage_templates()
);
-- 書き込みはservice_role（Edge Function）のみ想定。RLSのinsert/update方針は設けない（誰も直接書けない）

-- ============================================================
-- Storage: 非公開バケット2種（invoice-filesと同じ方針＝report-photosの教訓＝必ず非公開＋署名URL）
-- ============================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('export-templates', 'export-templates', false, 10485760, null)
on conflict (id) do update set allowed_mime_types = null;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('export-outputs', 'export-outputs', false, 52428800, null)
on conflict (id) do update set allowed_mime_types = null;

drop policy if exists export_templates_read on storage.objects;
create policy export_templates_read on storage.objects for select
  using (bucket_id = 'export-templates' and export_can_access());
-- 書き込みはservice_role（Edge Function経由）のみ。直接policyは設けない。

drop policy if exists export_outputs_read on storage.objects;
create policy export_outputs_read on storage.objects for select
  using (bucket_id = 'export-outputs' and export_can_access());
-- 書き込みはservice_role（Edge Function経由）のみ。直接policyは設けない。

-- ============================================================
-- Phase 1 PoC: 月次PL／年間推移PLテンプレートを1件登録（file_pathは初回はnull。
-- テンプレートファイルはExport Serviceの初回実機テストでStorageへアップロード後にUPDATEする）
-- ============================================================
insert into tpl_templates (template_code, template_name, category, description, renderer_key, layout, is_active)
values (
  'pl_monthly',
  '月次PL／年間推移PL',
  '経営・売上',
  '対象期間・対象店舗（複数選択可）を指定し、店舗別PLと合算PLをExcel/CSVで出力する。データ源はBigQuery stg_pl（tori-dashboard GASブリッジ経由）。',
  'pl_monthly_v1',
  '{"header_row": 3, "data_start_row": 4, "label_col": 1, "value_start_col": 2}'::jsonb,
  true
)
on conflict (template_code) do update set
  template_name = excluded.template_name,
  category = excluded.category,
  description = excluded.description,
  renderer_key = excluded.renderer_key,
  layout = excluded.layout,
  updated_at = now();

-- 確認用（実行はしない・手動確認時のコメント）:
-- select * from tpl_templates;
-- select * from export_history order by created_at desc limit 20;
