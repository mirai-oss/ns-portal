-- レーンP: kd_pl_monthly_summaryへ業務委託精算書由来のPL反映データを取り込む（司令塔指示・2026-09-06）
--
-- 背景（設計書_業務委託精算書自動連携_2026-09-04.md §9-2の6状態モデル）:
-- ①「精算対象店舗」の経費は業務委託精算書（seisan-dashboard）へ登録され（invoice_pl_reflections.
--   reflection_route='seisan'）、GAS側の日次バッチsyncSeisanCategoriesToPlが「振込確定」済みの明細を
--   まとめてDB_PL（memo='自動｜精算書'）へ書き込む。②DB_PLはbqSyncPL経由でBigQuery stg_plへミラーされ、
--   ③kd_pl_monthly_summary（op=pl_monthly）はbqGetPL経由でstg_plを読む。
-- つまり「振込確定→syncSeisanCategoriesToPl実行済み」の分は**既にcost_manual/labor_manual等に
-- 含まれている**（stg_pl経由で自動的に）。二重計上を避けるため、この分を別途加算してはいけない。
--
-- 一方、まだsyncSeisanCategoriesToPlが実行されていない「振込確定待ち」「PL同期待ち」の分は
-- DB_PL/stg_plにまだ存在しないため、現状のkd_pl_monthly_summaryには一切反映されない
-- （旧システム側=GASのPL画面も同様に未反映のはずなので、ここだけなら新旧の差異ではない）。
--
-- 本マイグレーションでは、両方を可視化する列を追加する:
--   seisan_synced_breakdown: stg_pl側で実際にmemo='自動｜精算書'だったF/L/A/R/O別合計
--     （＝「業務委託精算書経由で本当にPLへ届いた金額」の裏付け・突合用。cost_total等には既に
--     含まれている数字の内訳表示なので、合計に加算してはいけない）
--   seisan_pending_total / seisan_pending_breakdown: invoice_pl_reflectionsのpl_statusが
--     まだDB_PL反映前（振込確定待ち／PL同期待ち）の金額。stg_plにはまだ無い＝cost_total等には
--     含まれていない「これから反映される見込み額」。全店舗共通の「部分反映＋出典表示」原則により、
--     画面側で「確定 X円＋精算書処理中 Y円」のように分けて出せるようにする（合算して表示しない）

alter table public.kd_pl_monthly_summary add column if not exists seisan_synced_breakdown jsonb not null default '{}'::jsonb;
alter table public.kd_pl_monthly_summary add column if not exists seisan_pending_total numeric;
alter table public.kd_pl_monthly_summary add column if not exists seisan_pending_breakdown jsonb not null default '{}'::jsonb;

comment on column public.kd_pl_monthly_summary.seisan_synced_breakdown is
  '既にDB_PL/stg_plに反映済み(memo=自動｜精算書)の業務委託精算書由来分。{"F":n,"L":n,"A":n,"R":n,"O":n}。cost_total等に既に含まれている内訳の裏付け表示用（加算禁止）';
comment on column public.kd_pl_monthly_summary.seisan_pending_total is
  'invoice_pl_reflections(reflection_route=seisan)でpl_statusがまだDB_PL反映前（振込確定待ち/PL同期待ち）の金額合計。cost_total等には未算入（部分反映の原則）';
comment on column public.kd_pl_monthly_summary.seisan_pending_breakdown is
  '↑のF/L/A/R/O別内訳。{"F":n,"L":n,"A":n,"R":n,"O":n}';
