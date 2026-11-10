-- 2026-11-12 担当A（TK-252）: daily_report_card_vm v6.3 草案（未連携デリバリーチャネル＝Uber Eats の扱い）。★未適用★ 前提: v6.2 適用済み＋2026-11-12_ubereats_unlinked_map_DRAFT.sql。
-- 変更: ①新関数 delivery_channel_linked(channel)（取込ジョブがあるチャネルだけ true。現在は rocketnow のみ＝連携したらここに足す）
--   ②delivery_store_map に「未連携チャネル」が active の店は、delivery.unlinked_channels／unlinked_note を返し、fl_reference_today/mtd=true・ratings=hold（参考値＋評価保留）。0円扱いにはしない。
--   既存キー不変・追加のみ。rocketnow の欠損判定（v6.1）はそのまま。
-- 【指紋ガード】本番VMが v6.2（breakdown を含み unlinked_channels をまだ含まない）でなければ中止。
-- 【rollback】v6.2 の関数定義で create or replace し直す。drop function delivery_channel_linked(text)。

do $guard$
declare v_src text;
begin
  select prosrc into v_src from pg_proc where proname = 'daily_report_card_vm' and pronamespace = 'public'::regnamespace;
  if v_src is null or v_src not like '%breakdown%' or v_src like '%unlinked_channels%' then
    raise exception 'daily_report_card_vm が v6.2 の状態ではありません（v6.2未適用 or 適用済み）。中止します';
  end if;
end
$guard$;

create or replace function public.delivery_channel_linked(p_channel text) returns boolean
language sql immutable as $$ select p_channel = 'rocketnow' $$;   -- 取込ジョブが存在するチャネル。Uber Eats を連携したら 'ubereats' を足す
revoke all on function public.delivery_channel_linked(text) from public, anon, authenticated;
grant execute on function public.delivery_channel_linked(text) to service_role;

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
  -- 取込ジョブが未定義（未連携）のデリバリーチャネルを持つ店（例: Uber Eats）。0円扱いにせず「未連携」として F/L/FL を参考値＋評価保留にする
  v_unlinked text[] := coalesce(array(select distinct m.channel from public.delivery_store_map m where m.store_id = p_store and m.active and not public.delivery_channel_linked(m.channel) order by 1), '{}'::text[]);
  v_has_unl boolean;
  v_dn int := (fd->>'delivery_rows')::int;
  v_med_n int; v_med_lunch numeric; v_med_total numeric; v_seisan boolean; v_bdpos numeric; v_bd_status text; v_bd_lunch numeric; v_bd_dinner numeric; v_dv_last date; v_dv_mtd_missing boolean; v_dv_day_missing boolean; v_dv_miss_days int; v_dv_day_status text;
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
  v_has_unl := coalesce(array_length(v_unlinked, 1), 0) > 0;
  v_dv_day_missing := v_dv_day_status = 'missing' or v_has_unl;
  -- 月間: 取扱開始日以降・休業でない各日について、行も取込成功記録も無い日の数。1日でもあれば参考値＋評価保留
  select count(*) into v_dv_miss_days
    from generate_series(greatest(date_trunc('month', p_date)::date, coalesce((select min(m.created_at)::date from public.delivery_store_map m where m.store_id = p_store and m.active), p_date + 1)), p_date, interval '1 day') g(d)
   where v_enabled and not public.delivery_closed(p_store, g.d::date)
     and not exists (select 1 from public.kd_delivery_daily x where x.store_id = p_store and x.biz_date = g.d::date)
     and not public.delivery_ingest_ok(g.d::date);
  v_dv_mtd_missing := v_enabled and (coalesce(v_dv_miss_days, 0) > 0 or v_has_unl);

  -- 売上内訳（営業区分別売上）の正本 = 経営ダッシュボードの「営業区分別売上」と同じ元データ（kd_media_daily＝分析_媒体別日次）。
  --   分類は app.js mediaClassOf の既定ルールと同じ: 媒体名が「ランチ|昼」→ランチ／デリバリー系(デリバリ|ロケットナウ|出前)→デリバリー(別系統・ここでは除外)／それ以外→ディナー。
  --   POS確定売上とは一致する（直近31日・媒体データのある247店日で差0）ので按分は不要。明細（kd_detail_hour_daily）では代用しない。媒体データが無い日・店は status='missing'（＝未取得）
  --   ※ DB_媒体分類シートによる個別の上書き設定はDBに無いため未反映（要: DBへの移行。ルール案書を参照）
  select count(*), coalesce(sum(case when coalesce(m.media_raw, m.media_name) ~ 'ランチ|昼' then m.net_sales else 0 end), 0), coalesce(sum(m.net_sales), 0)
    into v_med_n, v_med_lunch, v_med_total
    from public.kd_media_daily m
   where m.store_id = p_store and m.biz_date = p_date and not (coalesce(m.media_raw, m.media_name) ~ 'デリバリ|ロケットナウ|出前');

  --   【業務委託4店の特例】媒体データが無くても、POS確定売上が取れていれば ランチ0円／ディナー＝POS全額／合計＝POS とする。
  --     対象は既存の店舗マスタ属性 stores.seisan_target（業務委託精算書の対象店舗＝エース本厚木・じんべぇ川崎・じんべぇ新横浜・秋葉原肉寿司の4店）に限定（新テーブル・新列は作らない）。
  --     通常店で媒体データが無い日は status='missing'（未取得）のまま。POS をディナーへ無条件に振り替えない。
  --   【保証】ランチ＋ディナー＝POS確定売上（デリバリーは含めない）。媒体がある店は ディナー＝POS−ランチ媒体（媒体合計とPOSは直近31日で全店日一致）。media_total/media_diff は監査用
  v_bdpos := nullif((v5->>'sales_today'), '')::numeric;
  select coalesce(s.seisan_target, false) into v_seisan from public.stores s where s.id = p_store;
  if v_bdpos is not null and v_bdpos >= 0 and v_med_n > 0 then
    v_bd_status := 'ok'; v_bd_lunch := least(v_med_lunch, v_bdpos); v_bd_dinner := v_bdpos - v_bd_lunch;
  elsif v_bdpos is not null and v_bdpos >= 0 and coalesce(v_seisan, false) then
    v_bd_status := 'ok'; v_bd_lunch := 0; v_bd_dinner := v_bdpos;
  else
    v_bd_status := 'missing';
  end if;

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
      'unlinked_channels', to_jsonb(v_unlinked), 'unlinked_note', case when v_has_unl then 'デリバリー売上の一部（' || array_to_string(array(select case c when 'ubereats' then 'Uber Eats' else c end from unnest(v_unlinked) c), '・') || '）が未連携' end,
      'mtd_incomplete', coalesce(v_dv_mtd_missing, false), 'missing_days', coalesce(v_dv_miss_days, 0), 'last_date', v_dv_last,
      'status', v_dv_day_status,
      'budget_ratio', null),                                                -- デリバリー予算は無い（金額のみ表示）
    'is_holiday_eve', public.jp_holiday_name(p_date + 1) is not null,
    'days_to_holiday', v_days_to_holiday,
    'ratings', v_rat,
    'fl_reference_today', coalesce(v_dv_day_missing, false),   -- true=デリバリー未取得のため店内のみで計算した参考値
    'fl_reference_mtd', coalesce(v_dv_mtd_missing, false),
    'breakdown', jsonb_build_object('status', v_bd_status, 'source', case when v_med_n > 0 then 'kd_media_daily' when v_bd_status = 'ok' then 'pos_consigned' end,
      'lunch', case when v_bd_status = 'ok' then v_bd_lunch end, 'dinner', case when v_bd_status = 'ok' then v_bd_dinner end, 'total', case when v_bd_status = 'ok' then v_bdpos end,
      'has_lunch', coalesce(v_bd_lunch, 0) > 0, 'media_total', case when v_med_n > 0 then v_med_total end, 'media_diff', case when v_med_n > 0 and v_bdpos is not null then v_med_total - v_bdpos end,
      'consigned', coalesce(v_seisan, false)),
    'mtd_status', '暫定',
    'mtd_dinii_low_count', v_low
  );
end
$function$;

revoke all on function public.daily_report_card_vm(uuid, date) from public, anon, authenticated;
grant execute on function public.daily_report_card_vm(uuid, date) to service_role;
