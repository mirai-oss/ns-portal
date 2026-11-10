-- 2026-11-11 担当A（TK-252）: daily_report_card_vm v6.1（デリバリー欠損判定の精緻化）。★草案・本番未適用★ 前提: v6 適用済み。
-- 変更点: ①0円と未取得の区別（ok／zero／closed／missing）②取込成功の判定=import_runs（job='rocketnow-sales'・success・detail のファイル名の日付）
--   ③月間は「行も取込成功記録も無い営業日」が1日でもあれば参考値＋評価保留 ④休業は delivery_closed() 1か所（休業表が無い間は false）
--   VM の既存キーは変えず、delivery に missing_days を追加。status の意味だけ精緻化（zero=¥0・注文なし）。
-- 【指紋ガード】本番の daily_report_card_vm の md5 が v6 適用時の値でなければ中止。
-- 【rollback】create or replace で v6 の定義（2026-11-11_daily_report_card_vm_v6.sql の関数部分）を戻す。drop function delivery_ingest_ok(date), delivery_closed(uuid,date);

do $guard$
begin
  if (select md5(prosrc) from pg_proc where proname = 'daily_report_card_vm' and pronamespace = 'public'::regnamespace) is distinct from '02d453b9d506ef260a2f167338a95f9e' then
    raise exception 'daily_report_card_vm の本番定義が v6 適用時と違います。中止します（md5=%）',
      (select md5(prosrc) from pg_proc where proname = 'daily_report_card_vm' and pronamespace = 'public'::regnamespace);
  end if;
end
$guard$;

-- 取込成功の判定: その日がロケットナウ日次取込（ファイル名 sales-report(Multi)_開始_終了）の成功記録に含まれるか。detail が想定外の文言なら false（安全側＝未取得扱い）
create or replace function public.delivery_ingest_ok(p_date date) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (
    select 1 from public.import_runs r
    cross join lateral regexp_matches(coalesce(r.detail, ''), 'sales-report\(Multi\)_(\d{8})_(\d{8})', 'g') m
    where r.job = 'rocketnow-sales' and r.status = 'success'
      and to_date(m[1], 'YYYYMMDD') <= p_date and p_date <= to_date(m[2], 'YYYYMMDD'))
$$;
-- 休業・定休日の判定（1か所）。休業表（store_closed_days）が新設されるまでは常に false＝休業なし。新設後はここだけ差し替える
create or replace function public.delivery_closed(p_store uuid, p_date date) returns boolean
language sql stable security definer set search_path to 'public' as $$ select false $$;
revoke all on function public.delivery_ingest_ok(date), public.delivery_closed(uuid, date) from public, anon, authenticated;
grant execute on function public.delivery_ingest_ok(date), public.delivery_closed(uuid, date) to service_role;

create or replace function public.daily_report_card_vm(p_store uuid, p_date date)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v5 jsonb := public.daily_report_card_vm_v5(p_store, p_date);
  fd jsonb := public.fl_metrics_day(p_store, p_date);
  fm jsonb := public.fl_metrics_mtd(p_store, p_date);
  ym text := to_char(p_date, 'YYYY-MM');
  v_enabled boolean := exists (select 1 from public.delivery_store_map m where m.store_id = p_store and m.active);
  v_dn int := (fd->>'delivery_rows')::int;
  v_dv_last date; v_dv_mtd_missing boolean; v_dv_day_missing boolean; v_dv_miss_days int; v_dv_day_status text;
  v_n int; v_pos int;
  v_days_to_holiday int;
  v_rat jsonb := '{}'::jsonb;
  mt text; th record; g text; val numeric;
  v_low int;
begin
  -- 祝日までの日数（直近14日以内・翌日以降）。祝前日＝翌日が祝日
  select min(n) into v_days_to_holiday from generate_series(1, 14) n where public.jp_holiday_name(p_date + n) is not null;

  -- デリバリー欠損の判定 v6.1（取扱店のみ・0円と未取得を区別）。状態: ok / zero(¥0・注文なし＝取込成功の日で行なし or 0円) / closed(休業・対象外) / missing(未取得＝取込成功記録なし)
  --   取込成功の判定は import_runs（job='rocketnow-sales'・success・detail のファイル名の日付）。日付が特定できない・失敗は missing 側（安全側）
  --   休業日は delivery_closed() 1か所で判定（休業表が無い間は常に false＝休業なし）
  select max(biz_date) into v_dv_last from public.kd_delivery_daily where store_id = p_store and biz_date between date_trunc('month', p_date)::date and p_date;
  v_dv_day_status := case
    when not v_enabled then null
    when v_dn > 0 and (fd->>'delivery_sales_gross')::numeric > 0 then 'ok'
    when v_dn > 0 then 'zero'
    when public.delivery_closed(p_store, p_date) then 'closed'
    when public.delivery_ingest_ok(p_date) then 'zero'
    else 'missing' end;
  v_dv_day_missing := v_dv_day_status = 'missing';
  -- 月間: 取扱開始日以降・休業でない各日について、行も取込成功記録も無い日の数。1日でもあれば参考値＋評価保留
  select count(*) into v_dv_miss_days
    from generate_series(greatest(date_trunc('month', p_date)::date, coalesce((select min(m.created_at)::date from public.delivery_store_map m where m.store_id = p_store and m.active), p_date + 1)), p_date, interval '1 day') g(d)
   where v_enabled and not public.delivery_closed(p_store, g.d::date)
     and not exists (select 1 from public.kd_delivery_daily x where x.store_id = p_store and x.biz_date = g.d::date)
     and not public.delivery_ingest_ok(g.d::date);
  v_dv_mtd_missing := v_enabled and coalesce(v_dv_miss_days, 0) > 0;

  -- 月間の4段階評価（月間累計の丸め前の比率で判定）。基準が3境界値そろっていなければ unset
  foreach mt in array array['labor', 'food', 'fl'] loop
    select * into th from public.fl_rating_thresholds t where t.store_id = p_store and t.year_month = ym and t.metric = mt;
    val := case mt when 'labor' then (fm->>'l_rate')::numeric when 'food' then (fm->>'f_rate')::numeric else (fm->>'fl_ratio')::numeric end;
    g := case when v_dv_mtd_missing then 'hold' else public.fl_rating_grade(val, th.excellent_max, th.normal_max, th.warn_max) end;   -- hold=デリバリー欠けのため評価保留
    v_rat := v_rat || jsonb_build_object(mt, jsonb_build_object('grade', g, 'value', val,
              'thresholds', case when th.store_id is null then null else jsonb_build_object('excellent_max', th.excellent_max, 'normal_max', th.normal_max, 'warn_max', th.warn_max) end));
  end loop;

  -- ダイニー低評価（月初〜当日の来店分）。kd_dinii_responses.score は 0〜100（5点刻み）。しきい値は dinii_low_score_max()（100点満点中75点以下・ちょうどを含む）。0点（回答日時あり）も含む
  select count(*) into v_low from public.kd_dinii_responses r
   where r.store_id = p_store and r.score is not null and r.score <= public.dinii_low_score_max()
     and (r.visited_at at time zone 'Asia/Tokyo')::date between date_trunc('month', p_date)::date and p_date;

  return v5 || jsonb_build_object(
    -- FL共通定義で置き換える4キー（分母=FL計算用売上）
    'labor_ratio_today', fd->'l_rate',
    'food_cost_ratio_today', fd->'f_rate',
    'mtd_labor_ratio', fm->'l_rate',
    'mtd_food_cost_ratio', fm->'f_rate',
    -- 追加キー
    'fl_sales_today', fd->'fl_sales', 'fl_sales_mtd', fm->'fl_sales',
    'fl_ratio_today', fd->'fl_ratio', 'mtd_fl_ratio', fm->'fl_ratio',
    'delivery', jsonb_build_object(
      'enabled', v_enabled,
      'sales', case when v_enabled then fd->'delivery_sales' end,           -- 税抜換算後（FL計算用）
      'sales_gross', case when v_enabled then fd->'delivery_sales_gross' end, -- 換算前（プラットフォーム上の売上）
      'orders', case when v_enabled then fd->'delivery_orders' end,
      'mtd_sales', case when v_enabled then fm->'delivery_sales' end,
      'mtd_incomplete', coalesce(v_dv_mtd_missing, false), 'missing_days', coalesce(v_dv_miss_days, 0), 'last_date', v_dv_last,
      'status', v_dv_day_status,
      'budget_ratio', null),                                                -- デリバリー予算は無い（金額のみ表示）
    'is_holiday_eve', public.jp_holiday_name(p_date + 1) is not null,
    'days_to_holiday', v_days_to_holiday,
    'ratings', v_rat,
    'fl_reference_today', coalesce(v_dv_day_missing, false),   -- true=デリバリー未取得のため店内のみで計算した参考値
    'fl_reference_mtd', coalesce(v_dv_mtd_missing, false),
    'mtd_status', '暫定',
    'mtd_dinii_low_count', v_low
  );
end
$function$;

revoke all on function public.daily_report_card_vm(uuid, date) from public, anon, authenticated;
grant execute on function public.daily_report_card_vm(uuid, date) to service_role;

-- 確認用SELECT（適用後・service_roleで）: delivery_ingest_ok の直近日が true になること／はなれ等の status・missing_days
--   select d::date, public.delivery_ingest_ok(d::date) from generate_series(current_date - 6, current_date, interval '1 day') d;
