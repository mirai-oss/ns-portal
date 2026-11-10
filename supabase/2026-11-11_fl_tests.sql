-- 2026-11-11 担当A: F/L/FL・評価判定のテスト（純粋関数のみ。データを読み書きしない＝適用後に本番で実行しても安全）。失敗すると例外で止まる
do $t$
declare r jsonb;
begin
  -- ① 設計書の検証例: 店内700万・デリバリー(税抜換算後)100万・人件費160万・原価200万 → FL計算用800万 / L20.0% / F25.0% / FL45.0%
  r := public.fl_metrics_calc(7000000, 1000000, 1600000, 2000000);
  assert (r->>'fl_sales')::numeric = 8000000 and (r->>'instore_sales')::numeric = 7000000, '売上KPI=店内700万・FL用800万';
  assert round((r->>'l_rate')::numeric * 100, 1) = 20.0 and round((r->>'f_rate')::numeric * 100, 1) = 25.0 and round((r->>'fl_ratio')::numeric * 100, 1) = 45.0, 'L20/F25/FL45';
  -- ② 税込→税抜の換算: 108万 → 100万
  assert public.fl_delivery_tax_divisor() = 1.08 and round(1080000 / public.fl_delivery_tax_divisor()) = 1000000, '÷1.08';
  -- ③ デリバリーなし: 分母=店内のみ（従来と同じ）
  r := public.fl_metrics_calc(5000000, 0, 1000000, 1500000);
  assert (r->>'fl_sales')::numeric = 5000000 and round((r->>'fl_ratio')::numeric * 100, 1) = 50.0, 'デリバリーなしは従来と同じ';
  -- ④ 分母0 → 率は null（0割り・0%にしない）
  r := public.fl_metrics_calc(0, 0, 100000, 50000);
  assert r->'l_rate' = 'null'::jsonb and r->'f_rate' = 'null'::jsonb and r->'fl_ratio' = 'null'::jsonb, '分母0はnull';
  -- ⑤ 店内0でもデリバリーがあれば分母=デリバリー
  r := public.fl_metrics_calc(0, 500000, 100000, 100000);
  assert round((r->>'l_rate')::numeric * 100, 1) = 20.0, '店内0＋デリバリーあり';
  -- ⑥ 取消（マイナス）を含む合計の符号: 合計が正なら通常計算
  r := public.fl_metrics_calc(1000000, -20000, 300000, 300000);
  assert (r->>'fl_sales')::numeric = 980000, '取消マイナスはそのまま合算';
  -- ⑦ 4段階評価の境界値（境界ちょうどは良い側）: 優秀≤18 / 普通≤20 / 要改善≤23 / それ超=危険水準
  assert public.fl_rating_grade(0.18, 18, 20, 23) = 'excellent', '18.0=優秀';
  assert public.fl_rating_grade(0.1801, 18, 20, 23) = 'normal', '18.01=普通';
  assert public.fl_rating_grade(0.20, 18, 20, 23) = 'normal', '20.0=普通';
  assert public.fl_rating_grade(0.2001, 18, 20, 23) = 'warn', '20.01=要改善';
  assert public.fl_rating_grade(0.23, 18, 20, 23) = 'warn', '23.0=要改善';
  assert public.fl_rating_grade(0.2301, 18, 20, 23) = 'danger', '23.01=危険水準';
  -- ⑧ 基準未設定・値なし → unset
  assert public.fl_rating_grade(0.2, null, null, null) = 'unset' and public.fl_rating_grade(null, 18, 20, 23) = 'unset', '未設定・値なしはunset';
  -- ⑨ 丸める前の値で判定（20.04% は表示で20.0%でも要改善側）
  assert public.fl_rating_grade(0.20004, 18, 20, 23) = 'warn', '丸め前で判定';
  -- ⑪ 月間の率は「期間合計」から算出（日次比率の単純平均は使わない）: 2日間 売上100円・原価50円(50%) と 売上900円・原価90円(10%)
  --    → 日次比率の平均=30% ≠ 期間合計比率=14%。共通定義（fl_metrics_range）は合計ベースなので 14% になる
  r := public.fl_metrics_calc(100 + 900, 0, 0, 50 + 90);
  assert round((r->>'f_rate')::numeric * 100, 1) = 14.0, '期間合計の原価率=14%';
  assert round((((50.0 / 100) + (90.0 / 900)) / 2) * 100, 1) = 30.0 and round((r->>'f_rate')::numeric * 100, 1) <> 30.0, '日次比率の平均(30%)と期間合計比率(14%)は別物';
  -- ⑩ ダイニー低評価のしきい値（③適用後に有効）: 100点満点中75点以下（ちょうどを含む）
  assert public.dinii_low_score_max() = 75, 'ダイニー低評価=75点以下';
  raise notice 'fl tests: 全て合格';
end
$t$;
