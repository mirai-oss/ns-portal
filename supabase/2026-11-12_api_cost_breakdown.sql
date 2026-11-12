-- AI利用料の内訳（2026-11-12）。api_cost_daily は日次合計だけなので、
-- 「どのワークスペース・どのモデル・どの種類（入力/出力/キャッシュ等）で使ったか」を日次で保存する。
-- 取得元: Anthropic Cost Report API（group_by=workspace_id,description）。date は api_cost_daily と同じくUTC暦日。
-- 合計の正は api_cost_daily のまま（こちらは内訳の参考。両者の合計は概ね一致するが丸めで微差が出うる）。
create table if not exists api_cost_breakdown (
  date date not null,
  workspace_id text not null default '',   -- 空=デフォルトワークスペース
  workspace_name text,
  model text not null default '',
  cost_type text not null default '',      -- tokens / web_search / code_execution 等
  token_type text not null default '',     -- uncached_input_tokens / output_tokens / cache_read_input_tokens 等
  amount_cents numeric not null,
  updated_at timestamptz not null default now(),
  primary key (date, workspace_id, model, cost_type, token_type)
);
create index if not exists api_cost_breakdown_date_idx on api_cost_breakdown(date);
alter table api_cost_breakdown enable row level security;
-- 参照は HQ/CEO/マスターのみ（api_cost_daily と同じ考え方）。書き込みは service_role（Edge Function）だけ。
drop policy if exists api_cost_breakdown_read on api_cost_breakdown;
create policy api_cost_breakdown_read on api_cost_breakdown for select to authenticated
  using (exists (select 1 from users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO','HQ'))));
