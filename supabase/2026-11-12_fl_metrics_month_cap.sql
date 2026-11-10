-- 2026-11-12 担当A（TK-252）: fl_metrics_month の当月途中の過大対策（草案・未適用）。keiei-kd-refresh の月次サマリ修正と同じ考え方
--   月の集計範囲を「月末」ではなく「売上のある最終日（kd_daily_store_full で net_sales>0 の最大日付）」までに限定する。売上のある最終日が月末以降（確定月）なら従来と同じ値。
-- 影響: fl_metrics_month の当月途中の値のみ（日次・月初〜当日の fl_metrics_day/mtd は不変）。fl_consistency_check の当月比較が月次サマリ修正後の値と一致するようになる。
-- 【指紋ガード】本番の fl_metrics_month の md5 が草案作成時（d9ab7fde24171dce3e41ddd86bde8646）でなければ中止。
-- 【rollback】create or replace で旧定義（fl_metrics_range(店, 月初, 月末)）へ戻す。
do $guard$
begin
  if (select md5(prosrc) from pg_proc where proname = 'fl_metrics_month' and pronamespace = 'public'::regnamespace) is distinct from 'd9ab7fde24171dce3e41ddd86bde8646' then
    raise exception 'fl_metrics_month の本番定義が草案作成時と違います。中止します';
  end if;
end
$guard$;
create or replace function public.fl_metrics_month(p_store uuid, p_ym text) returns jsonb
language sql stable security definer set search_path to 'public' as $$
  with b as (select (p_ym || '-01')::date m0, ((p_ym || '-01')::date + interval '1 month - 1 day')::date m1)
  select public.fl_metrics_range(p_store, b.m0,
    least(b.m1, coalesce((select max(k.date) from public.kd_daily_store_full k where k.store_id = p_store and k.date between b.m0 and b.m1 and k.net_sales > 0), b.m1)))
  from b
$$;
