-- 2026-08-29 担当B（nippo）続き
-- sf_payroll_sync/sf_payroll_allocationsの読み取りRLSを、labor_cost_dailyと同じ
-- has_feature(auth.uid(),'labor_cost_view')方式に統一する。
-- 理由: 当初「CEO/HQ/マスターor本人」にしていたが、これだとTENCHO（店長）が②調整画面で
-- 自店舗の他の従業員ぶんの人件費を見られない（labor_cost_dailyと同じ権限モデルにすべきだった）。
-- has_feature()はuser_features→role_featuresの順に判定・CEOは常にtrue（既存関数・無変更）。
drop policy if exists sf_payroll_sync_read on sf_payroll_sync;
create policy sf_payroll_sync_read on sf_payroll_sync for select using (
  exists(select 1 from users u where u.id = auth.uid() and u.is_active and u.is_master)
  or has_feature(auth.uid(), 'labor_cost_view')
);

drop policy if exists sf_payroll_allocations_read on sf_payroll_allocations;
create policy sf_payroll_allocations_read on sf_payroll_allocations for select using (
  exists(select 1 from users u where u.id = auth.uid() and u.is_active and u.is_master)
  or has_feature(auth.uid(), 'labor_cost_view')
);
