-- 2026-11-11 担当A（TK-244 第1弾）: F/L/FL 評価基準（店舗×年月×指標の3境界値）＋履歴＋日報スナップショット＋RPC6本。★草案・本番未適用★
-- 権限: マスター（users.is_master＝ポータル統合アカウント）のみ。表は RLS 有効・ポリシー無し＝直接の読み書きは全面拒否。RPC は security definer で is_master を判定。
-- 値の単位: 境界値は「パーセント」（例 20.0 = 20.0%）。判定は 丸める前の比率×100 と ≤ 比較（境界値ちょうどは良い側）。
-- 影響: 新規の表3・関数のみ。既存の表・関数は変更しない。
-- 【rollback】drop function me_is_master(), fl_thresholds_list(text), fl_thresholds_upsert(jsonb), fl_thresholds_copy(text,text,uuid[],boolean), fl_thresholds_missing(text), fl_threshold_history(uuid,text), fl_rating_grade(numeric,numeric,numeric,numeric);
--   drop table daily_report_card_snapshots, fl_rating_threshold_history, fl_rating_thresholds;

create table if not exists public.fl_rating_thresholds (
  store_id uuid not null references public.stores (id),
  year_month text not null check (year_month ~ '^\d{4}-(0[1-9]|1[0-2])$'),
  metric text not null check (metric in ('labor', 'food', 'fl')),
  excellent_max numeric not null,
  normal_max numeric not null,
  warn_max numeric not null,
  updated_by uuid references public.users (id),
  updated_at timestamptz not null default now(),
  primary key (store_id, year_month, metric),
  check (excellent_max >= 0 and excellent_max <= normal_max and normal_max <= warn_max and warn_max <= 1000)
);
comment on table public.fl_rating_thresholds is 'F/L/FL評価の境界値（%）。目標値(dash_target_monthly)とは別データ。優秀≤excellent_max<普通≤normal_max<要改善≤warn_max<危険水準';

create table if not exists public.fl_rating_threshold_history (
  id bigint generated always as identity primary key,
  store_id uuid not null, year_month text not null, metric text not null,
  before jsonb, after jsonb,
  changed_by uuid, changed_at timestamptz not null default now()
);
create index if not exists fl_rating_threshold_history_idx on public.fl_rating_threshold_history (store_id, year_month, changed_at desc);

create table if not exists public.daily_report_card_snapshots (
  id bigint generated always as identity primary key,
  store_id uuid not null references public.stores (id),
  date date not null,
  vm jsonb not null,                      -- 配信時のVM（評価基準・評価結果込み）。過去日報を当時の基準で再現する
  delivery_no int not null default 1,     -- 同日2回目以降の配信は 2,3…（画像は別名保存）
  generated_at timestamptz not null default now()
);
create index if not exists daily_report_card_snapshots_idx on public.daily_report_card_snapshots (store_id, date, delivery_no);

alter table public.fl_rating_thresholds enable row level security;
alter table public.fl_rating_threshold_history enable row level security;
alter table public.daily_report_card_snapshots enable row level security;
revoke all on public.fl_rating_thresholds, public.fl_rating_threshold_history, public.daily_report_card_snapshots from public, anon, authenticated;
-- ポリシーは作らない（service_role＝日報VM/Edge と、security definer のRPCだけが読み書きできる）

-- 履歴トリガー（変更者は auth.uid()。service_role経由は null）
create or replace function public.fl_rating_thresholds_log() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  insert into public.fl_rating_threshold_history (store_id, year_month, metric, before, after, changed_by)
  values (coalesce(new.store_id, old.store_id), coalesce(new.year_month, old.year_month), coalesce(new.metric, old.metric),
          case when tg_op = 'INSERT' then null else to_jsonb(old) - 'updated_by' end,
          case when tg_op = 'DELETE' then null else to_jsonb(new) - 'updated_by' end, auth.uid());
  return coalesce(new, old);
end $$;
drop trigger if exists fl_rating_thresholds_log_t on public.fl_rating_thresholds;
create trigger fl_rating_thresholds_log_t after insert or update or delete on public.fl_rating_thresholds
  for each row execute function public.fl_rating_thresholds_log();

-- 評価の判定（比率は丸める前の値。境界値はパーセント）。未設定・値なしは 'unset'
create or replace function public.fl_rating_grade(p_ratio numeric, p_excellent numeric, p_normal numeric, p_warn numeric)
returns text language sql immutable as $$
  select case
    when p_ratio is null or p_excellent is null or p_normal is null or p_warn is null then 'unset'
    when p_ratio * 100 <= p_excellent then 'excellent'
    when p_ratio * 100 <= p_normal then 'normal'
    when p_ratio * 100 <= p_warn then 'warn'
    else 'danger' end
$$;
grant execute on function public.fl_rating_grade(numeric,numeric,numeric,numeric) to service_role;

-- 1) マスター判定
create or replace function public.me_is_master() returns boolean
language sql stable security definer set search_path to 'public' as $$
  select coalesce((select u.is_master from public.users u where u.id = auth.uid() and u.is_active), false)
$$;
revoke all on function public.me_is_master() from public, anon;
grant execute on function public.me_is_master() to authenticated;

create or replace function public._fl_require_master() returns void
language plpgsql stable security definer set search_path to 'public' as $$
begin if not public.me_is_master() then raise exception 'forbidden: マスターのみ操作できます' using errcode = '42501'; end if; end $$;
revoke all on function public._fl_require_master() from public, anon, authenticated;

-- 2) 一覧（店舗×指標。未設定は行なし）
create or replace function public.fl_thresholds_list(p_ym text) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
begin
  perform public._fl_require_master();
  return coalesce((select jsonb_agg(jsonb_build_object('store_id', t.store_id, 'store_name', s.name, 'year_month', t.year_month, 'metric', t.metric,
           'excellent_max', t.excellent_max, 'normal_max', t.normal_max, 'warn_max', t.warn_max, 'updated_at', t.updated_at) order by s.sort_order, s.name, t.metric)
         from public.fl_rating_thresholds t join public.stores s on s.id = t.store_id where t.year_month = p_ym), '[]'::jsonb);
end $$;

-- 3) 保存（行の配列。主キー重複は上書き＝二重登録にならない）。検証は表の check 制約＋ここで型・指標を確認
create or replace function public.fl_thresholds_upsert(p_rows jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare r jsonb; n int := 0;
begin
  perform public._fl_require_master();
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 or jsonb_array_length(p_rows) > 400 then raise exception '行は1〜400件の配列で渡してください'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    insert into public.fl_rating_thresholds (store_id, year_month, metric, excellent_max, normal_max, warn_max, updated_by, updated_at)
    values ((r->>'store_id')::uuid, r->>'year_month', r->>'metric', (r->>'excellent_max')::numeric, (r->>'normal_max')::numeric, (r->>'warn_max')::numeric, auth.uid(), now())
    on conflict (store_id, year_month, metric) do update
      set excellent_max = excluded.excellent_max, normal_max = excluded.normal_max, warn_max = excluded.warn_max, updated_by = auth.uid(), updated_at = now();
    n := n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'saved', n);
end $$;

-- 4) 前月コピー（複数店舗一括・dry_run で差分確認）。p_overwrite=false なら コピー先に既にある行は触らない
create or replace function public.fl_thresholds_copy(p_from text, p_to text, p_store_ids uuid[] default null, p_dry_run boolean default true, p_overwrite boolean default false) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_new int; v_over int; v_skip int; v_rows jsonb;
begin
  perform public._fl_require_master();
  if p_from !~ '^\d{4}-(0[1-9]|1[0-2])$' or p_to !~ '^\d{4}-(0[1-9]|1[0-2])$' or p_from = p_to then raise exception '年月が不正です'; end if;
  select jsonb_agg(jsonb_build_object('store_id', f.store_id, 'metric', f.metric, 'excellent_max', f.excellent_max, 'normal_max', f.normal_max, 'warn_max', f.warn_max,
           'action', case when t.store_id is null then 'new' when p_overwrite then 'overwrite' else 'skip' end)),
         count(*) filter (where t.store_id is null), count(*) filter (where t.store_id is not null and p_overwrite), count(*) filter (where t.store_id is not null and not p_overwrite)
    into v_rows, v_new, v_over, v_skip
  from public.fl_rating_thresholds f left join public.fl_rating_thresholds t on t.store_id = f.store_id and t.metric = f.metric and t.year_month = p_to
  where f.year_month = p_from and (p_store_ids is null or f.store_id = any (p_store_ids));
  if not p_dry_run then
    insert into public.fl_rating_thresholds (store_id, year_month, metric, excellent_max, normal_max, warn_max, updated_by, updated_at)
    select f.store_id, p_to, f.metric, f.excellent_max, f.normal_max, f.warn_max, auth.uid(), now()
    from public.fl_rating_thresholds f where f.year_month = p_from and (p_store_ids is null or f.store_id = any (p_store_ids))
    on conflict (store_id, year_month, metric) do update
      set excellent_max = excluded.excellent_max, normal_max = excluded.normal_max, warn_max = excluded.warn_max, updated_by = auth.uid(), updated_at = now()
      where p_overwrite;
  end if;
  return jsonb_build_object('dry_run', p_dry_run, 'new', coalesce(v_new,0), 'overwrite', coalesce(v_over,0), 'skip', coalesce(v_skip,0), 'rows', coalesce(v_rows, '[]'::jsonb));
end $$;

-- 5) 未設定店舗（有効な店舗で、3指標のどれかが無い）
create or replace function public.fl_thresholds_missing(p_ym text) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
begin
  perform public._fl_require_master();
  return coalesce((select jsonb_agg(jsonb_build_object('store_id', s.id, 'store_name', s.name,
           'missing', (select jsonb_agg(m.metric) from (values ('labor'),('food'),('fl')) m(metric)
                       where not exists (select 1 from public.fl_rating_thresholds t where t.store_id = s.id and t.year_month = p_ym and t.metric = m.metric))) order by s.sort_order, s.name)
         from public.stores s where s.is_active
           and (select count(*) from public.fl_rating_thresholds t where t.store_id = s.id and t.year_month = p_ym) < 3), '[]'::jsonb);
end $$;

-- 6) 変更履歴
create or replace function public.fl_threshold_history(p_store uuid, p_ym text) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
begin
  perform public._fl_require_master();
  return coalesce((select jsonb_agg(jsonb_build_object('metric', h.metric, 'before', h.before, 'after', h.after, 'changed_by', u.name, 'changed_at', h.changed_at) order by h.changed_at desc)
         from public.fl_rating_threshold_history h left join public.users u on u.id = h.changed_by
         where h.store_id = p_store and h.year_month = p_ym), '[]'::jsonb);
end $$;

revoke all on function public.fl_thresholds_list(text), public.fl_thresholds_upsert(jsonb), public.fl_thresholds_copy(text,text,uuid[],boolean,boolean),
  public.fl_thresholds_missing(text), public.fl_threshold_history(uuid,text) from public, anon;
grant execute on function public.fl_thresholds_list(text), public.fl_thresholds_upsert(jsonb), public.fl_thresholds_copy(text,text,uuid[],boolean,boolean),
  public.fl_thresholds_missing(text), public.fl_threshold_history(uuid,text) to authenticated;

-- 権限表（適用後に実行して司令塔が確認するSELECT。期待: 3表とも anon/authenticated の権限が0行・ポリシー0件）
--   select table_name, grantee, privilege_type from information_schema.role_table_grants
--    where table_name in ('fl_rating_thresholds','fl_rating_threshold_history','daily_report_card_snapshots') and grantee in ('anon','authenticated','PUBLIC');
--   select tablename, policyname from pg_policies where tablename in ('fl_rating_thresholds','fl_rating_threshold_history','daily_report_card_snapshots');
--   select proname, proacl from pg_proc where proname in ('me_is_master','fl_thresholds_list','fl_thresholds_upsert','fl_thresholds_copy','fl_thresholds_missing','fl_threshold_history');
