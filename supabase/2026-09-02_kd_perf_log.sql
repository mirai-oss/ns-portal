-- P-0a（実装指示書_脱GAS移行_Phase0-1_2026-09-02.md §1 P側）
-- 経営ダッシュボード(tori-dashboard)・精算ダッシュボード(seisan-dashboard)のAPI呼び出し計測ログ。
-- 所有者: レーンP（kd_接頭辞）。書き込みはkeiei-api-perflog Edge Function（service_role接続）のみ。
-- app.js側の送信元: tori-dashboard/app.js:1487 logApiPerf_()（navigator.sendBeacon・2026-09-02実装済み）。
-- ペイロード: { app, action, ms, ok, errType, t }（1件=1リクエスト。バッチ無し）
--
-- 保持期間14日（毎日 keiei-api-perflog の op:'cleanup' で削除。運用はGitHub Actions cronから。
-- .github/workflows/keiei-perflog-daily.yml参照）。
create table if not exists public.kd_perf_log (
  id bigint generated always as identity primary key,
  app text not null,               -- 送信元アプリ（'tori-dashboard' | 'seisan-dashboard' 等）
  action text not null,            -- GAS/APIのaction名（例: 'bqGetPL'）
  ms integer not null,             -- 所要時間(ミリ秒。0〜600000にクランプ)
  ok boolean not null,             -- 成否
  err_type text,                   -- 'timeout'|'network'|'http_5xx'|'api_error'等（失敗時のみ・成功時はnull）
  client_ts timestamptz,           -- クライアント側の送信時刻（payload.t epoch ms → timestamptz。不正値はnull）
  ip text,                         -- 送信元IP（レート制限の直近件数カウント用。個人情報ではない）
  created_at timestamptz not null default now()
);

create index if not exists kd_perf_log_created_at_idx on public.kd_perf_log (created_at);
create index if not exists kd_perf_log_app_action_created_idx on public.kd_perf_log (app, action, created_at);
create index if not exists kd_perf_log_ip_created_idx on public.kd_perf_log (ip, created_at); -- レート制限用

alter table public.kd_perf_log enable row level security;
-- ポリシーは意図的に無し＝service_role以外は読み書き不可（Edge Functionはservice_role鍵で接続するため
-- 影響なし。ブラウザから直接PostgRESTを叩かせない設計＝必ずkeiei-api-perflog経由にする）。
