-- 2026-11-14 担当A（TK-255）: 全12店舗日報（Slack自動配信）用データ。★読み取り専用の新関数1つ★
-- 方針（ユーザー承認 11/11）: 全店舗専用の別計算を作らない。店舗別日報と同じ daily_report_card_vm（v6.5）を12店分そのまま呼び、
--   日次＝対象日のVMそのもの。月次累計＝月初〜対象日の日別VMから「ランチ/ディナー（breakdown）」「前年比の分母（ly_sales）」を合算するだけ。
--   売上・客数・予算・比率・評価・口コミ・原価（店舗間移動込み）は VM の mtd_* / ratings をそのまま使う。
-- 対象店舗: 店舗別Slack配信の8店（report_channel_stores の slack_store_*）＋業務委託（stores.seisan_target）。並びは 直営→業務委託、店舗番号順。
-- 配信実績: notification_deliveries（event=report_daily_card・channel_key=store.*・当日・sent/updated）の店舗名を返す（親投稿の「直営N/8」用）。
-- 影響: 関数追加のみ（service_role 限定）。既存の関数・表は変更しない。
-- 【rollback】drop function public.all_stores_report_vm(date);

create or replace function public.all_stores_report_vm(p_date date) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare
  m0 date := date_trunc('month', p_date)::date;
  r record;
  d date;
  v jsonb; vd jsonb;
  out_stores jsonb := '[]'::jsonb;
  v_lunch numeric; v_dinner numeric; v_bd_bad int; v_bd_days int;
  v_ly numeric; v_ly_sales numeric; v_ly_days int;
  v_media_vm numeric; v_media_db numeric;
  v_delivered jsonb;
  v_direct int := 0;
begin
  for r in
    select s.id, s.name, coalesce(s.seisan_target, false) as consigned
      from public.stores s
     where coalesce(s.seisan_target, false)
        or s.id in (select rs.store_id from public.report_channel_stores rs join public.report_channels rc on rc.id = rs.channel_id where rc.name like 'slack_store_%')
  loop
    vd := public.daily_report_card_vm(r.id, p_date);
    v_lunch := 0; v_dinner := 0; v_bd_bad := 0; v_bd_days := 0; v_ly := 0; v_ly_sales := 0; v_ly_days := 0; v_media_vm := 0;
    for d in select (m0 + g)::date from generate_series(0, p_date - m0) g loop
      v := case when d = p_date then vd else public.daily_report_card_vm(r.id, d) end;
      if coalesce((v->>'has_data')::boolean, false) and coalesce((v->>'sales_today')::numeric, 0) > 0 then
        v_bd_days := v_bd_days + 1;
        if v->'breakdown'->>'status' = 'ok' then
          v_lunch := v_lunch + coalesce((v->'breakdown'->>'lunch')::numeric, 0);
          v_dinner := v_dinner + coalesce((v->'breakdown'->>'dinner')::numeric, 0);
          v_media_vm := v_media_vm + coalesce((v->'breakdown'->>'media_total')::numeric, 0);
        else v_bd_bad := v_bd_bad + 1; end if;
        if coalesce((v->>'ly_found')::boolean, false) and (v->>'ly_sales') is not null then
          v_ly := v_ly + (v->>'ly_sales')::numeric; v_ly_sales := v_ly_sales + (v->>'sales_today')::numeric; v_ly_days := v_ly_days + 1;
        end if;
      end if;
    end loop;
    select coalesce(sum(k.net_sales), 0) into v_media_db from public.kd_media_daily k
      where k.store_id = r.id and k.biz_date between m0 and p_date
        and exists (select 1 from public.kd_daily_store_full f where f.store_id = r.id and f.date = k.biz_date and f.net_sales > 0);
    if not r.consigned then v_direct := v_direct + 1; end if;
    out_stores := out_stores || jsonb_build_object(
      'store_id', r.id, 'store_name', r.name, 'consigned', r.consigned, 'store_no', vd->>'store_no', 'vm', vd,
      'mtd', jsonb_build_object('lunch', v_lunch, 'dinner', v_dinner, 'bd_days', v_bd_days, 'bd_bad_days', v_bd_bad,
                                'ly_sales', v_ly, 'sales_on_ly_days', v_ly_sales, 'ly_days', v_ly_days,
                                'media_total_vm', v_media_vm, 'media_total_db', v_media_db));
  end loop;
  select coalesce(jsonb_agg(distinct x.store), '[]'::jsonb) into v_delivered from (
    select split_part(dedupe_key, ':', 4) as store from public.notification_deliveries
     where event = 'report_daily_card' and channel_key like 'store.%' and delivery_status in ('sent', 'updated')
       and dedupe_key like 'report_daily_card:' || p_date::text || ':%') x;
  return jsonb_build_object('date', p_date, 'month_from', m0,
    'stores', (select coalesce(jsonb_agg(e order by (e->>'consigned')::boolean, e->>'store_no', e->>'store_name'), '[]'::jsonb) from jsonb_array_elements(out_stores) e),
    'direct_total', v_direct, 'delivered_direct', v_delivered);
end
$$;
revoke all on function public.all_stores_report_vm(date) from public, anon, authenticated;
grant execute on function public.all_stores_report_vm(date) to service_role;
