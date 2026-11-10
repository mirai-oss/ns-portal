-- 2026-11-11 担当A（TK-244 第1弾）: daily_report_card_vm v6。★草案・本番未適用★ 前提: 2026-11-11_fl_metrics_common.sql と 2026-11-11_fl_rating_thresholds.sql を先に適用。
-- 方式: 本番の v5 をそのまま daily_report_card_vm_v5 へ改名して残し、新しい daily_report_card_vm が v5 の結果に「追加キー」と「FL共通定義で置き換える4キー」を足して返す。
--   → v5 のロジックには一切手を入れない（差分が小さい・ロールバックは改名を戻すだけ）。既存キーは全て維持。
-- 値が変わる既存キー（設計書 §6.1・承認対象）: labor_ratio_today / food_cost_ratio_today / mtd_labor_ratio / mtd_food_cost_ratio（分母=FL計算用売上）。
--   デリバリーが無い店舗・日は分母＝店内売上のままなので値は v5 と同じ。売上系キー（sales_today・mtd_sales・budget_*・yoy_*・lunch/dinner 等）は変えない。
-- 追加キー: fl_sales_today / fl_sales_mtd / fl_ratio_today / mtd_fl_ratio / delivery{} / is_holiday_eve / days_to_holiday / ratings{} / mtd_status / mtd_dinii_low_count
-- 【指紋ガード】適用時に本番の daily_report_card_vm の md5(prosrc) が下の値と違えば中止（他セッションの変更の上書き防止）。
-- 【rollback】drop function daily_report_card_vm(uuid,date); alter function daily_report_card_vm_v5(uuid,date) rename to daily_report_card_vm;

do $guard$
begin
  if (select md5(prosrc) from pg_proc where proname = 'daily_report_card_vm' and pronamespace = 'public'::regnamespace) is distinct from 'd285584cab88ee431997c99e3eafcf2d' then
    raise exception 'daily_report_card_vm の本番定義が草案作成時(2026-11-10 v5)と違います。中止します（md5=%）',
      (select md5(prosrc) from pg_proc where proname = 'daily_report_card_vm' and pronamespace = 'public'::regnamespace);
  end if;
  if not exists (select 1 from pg_proc where proname = 'fl_metrics_range') or not exists (select 1 from pg_proc where proname = 'fl_rating_grade') then
    raise exception '先に fl_metrics_common / fl_rating_thresholds を適用してください';
  end if;
end
$guard$;

-- ダイニー低評価のしきい値（1か所の定数）: 100点満点中 この点数「以下」（ちょうどを含む）を低評価とする。当社独自の管理基準（ダイニーの5段階とは別物）。
-- VM・集計API・画面のどこにもハードコードしない。変更する時はこの関数だけ直す（ユーザー確定 2026-11-11: 75）。
create or replace function public.dinii_low_score_max() returns numeric
language sql immutable as $$ select 75::numeric $$;
revoke all on function public.dinii_low_score_max() from public, anon, authenticated;
grant execute on function public.dinii_low_score_max() to service_role;

alter function public.daily_report_card_vm(uuid, date) rename to daily_report_card_vm_v5;

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
  v_dv_last date; v_dv_mtd_missing boolean; v_dv_day_missing boolean;
  v_n int; v_pos int;
  v_days_to_holiday int;
  v_rat jsonb := '{}'::jsonb;
  mt text; th record; g text; val numeric;
  v_low int;
begin
  -- 祝日までの日数（直近14日以内・翌日以降）。祝前日＝翌日が祝日
  select min(n) into v_days_to_holiday from generate_series(1, 14) n where public.jp_holiday_name(p_date + n) is not null;

  -- デリバリー欠損の判定（取扱店のみ）。日次: 当日の行が無い＝未取得。月間: 月初〜当日に行が1件も無い、または最終行の日付が当日の3日以上前＝欠け（一部日欠け含む）
  --   欠けがあれば F/L/FL は「店内のみで計算した参考値」とし、4段階評価は「保留(hold)」にする
  select max(biz_date) into v_dv_last from public.kd_delivery_daily where store_id = p_store and biz_date between date_trunc('month', p_date)::date and p_date;
  v_dv_day_missing := v_enabled and v_dn = 0;
  v_dv_mtd_missing := v_enabled and (v_dv_last is null or p_date - v_dv_last >= 3);

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
      'mtd_incomplete', coalesce(v_dv_mtd_missing, false), 'last_date', v_dv_last,
      'status', case when not v_enabled then null when v_dn = 0 then 'missing' when (fd->>'delivery_sales_gross')::numeric = 0 then 'zero' else 'ok' end,
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
revoke all on function public.daily_report_card_vm_v5(uuid, date) from public, anon, authenticated;
grant execute on function public.daily_report_card_vm_v5(uuid, date) to service_role;

-- ①②で作った純粋関数・トリガー関数が PUBLIC/anon 実行可のままだったため、方針（PUBLIC不可）に合わせて閉じる（司令塔レビューの指摘）。service_role は維持
revoke all on function public.fl_delivery_tax_divisor() from public, anon, authenticated;
revoke all on function public.fl_metrics_calc(numeric, numeric, numeric, numeric) from public, anon, authenticated;
revoke all on function public.fl_rating_grade(numeric, numeric, numeric, numeric) from public, anon, authenticated;
revoke all on function public.fl_rating_thresholds_log() from public, anon, authenticated;
grant execute on function public.fl_delivery_tax_divisor(), public.fl_metrics_calc(numeric, numeric, numeric, numeric), public.fl_rating_grade(numeric, numeric, numeric, numeric) to service_role;

-- 確認用SELECT（適用後）: 非デリバリー店で v5 と置換4キーが一致すること／キー数が増えていること
--   select (public.daily_report_card_vm(s.id, current_date - 1) ->> 'mtd_labor_ratio') = (public.daily_report_card_vm_v5(s.id, current_date - 1) ->> 'mtd_labor_ratio') from stores s where s.is_active limit 5;
