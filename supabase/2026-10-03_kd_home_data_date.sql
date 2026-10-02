-- レーンP: kd_home_kpi_snapshotに「数字が何日時点のものか」(data_date)を追加
--
-- 【事前報告様式（DB変更）】
-- 理由: ユーザー回答(2026-10-03)「売上は前日分が分かればよい。リアルタイムは不要」。売上の取込は朝(〜08:49 morning-refresh)に
--       前日分までが入る運用で、当日(JST)の行は一日中0/nullになる。現在のhome_kpiは「今日」の売上と「月初〜今日」の累計を
--       目標(月初〜今日の累計)と比べるため、①今日の売上は常に空 ②累計は前日まで・目標は今日までで達成率が約1日分低く出る。
-- 現構造: kd_home_kpi_snapshot(store_id, period_date=今日(JST), today_*, mtd_sales, budget_achievement_rate ...)。
-- 変更: data_date date列を追加。home_kpiは「売上のある最新営業日」をdata_dateとし、today_*・mtd・目標累計をdata_date基準で計算する。
--       period_date(=行のキー・今日)は変えない＝keiei-api-homeの検索条件・既存の読み手は無変更で動く。
-- 既存データへの影響: 列追加(null許容)のみ。既存行はdata_date=nullのまま次回リフレッシュで埋まる。
-- migration: 本ファイル(何度流しても壊れない)。 rollback: `alter table public.kd_home_kpi_snapshot drop column data_date;`(コード側はnull許容で動く)
alter table public.kd_home_kpi_snapshot add column if not exists data_date date;
comment on column public.kd_home_kpi_snapshot.data_date is
  'today_*/mtd_sales/budget_achievement_rateが何日時点の数字か（売上のある最新営業日。通常は前日）。画面は「本日」でなく「◯/◯（曜）までの実績」と表示する';
