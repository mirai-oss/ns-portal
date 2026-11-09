-- 2026-11-09 担当C（U-23①②・2026-11-09 ユーザー承認のうえ適用済み。テンプレ3本=is_active:false／11月分【振込SK】給料(1a0bc84a・未着手)=論理削除）
-- 目的: 給料確定の前に本部タスクが自動で付くのをやめる。月次テンプレ『【振込トーホー】給料』『【振込Live】給料』『【振込SK】給料』を停止し、
--       給料確定（hq_create_payroll_tasks）に一本化する。『給料計算』テンプレ（毎月11日・確定前の作業）は残す。

-- ■事前確認（読み取りのみ。対象3本のIDと現在の is_active）
select id, title, corp, freq, monthly_dom, due_offset_days, is_active
  from public.hq_task_templates
 where id::text like any (array['87e15434%','e2b144a5%','9a16cf44%'])
 order by title;

-- ■停止（3本だけ。タイトルでも二重に絞る）
-- update public.hq_task_templates set is_active = false, updated_at = now()
--  where id::text like any (array['87e15434%','e2b144a5%','9a16cf44%'])
--    and title in ('【振込トーホー】給料','【振込Live】給料','【振込SK】給料');

-- ■戻し方（停止を取り消して、また毎月1日に自動で作る状態へ）
-- update public.hq_task_templates set is_active = true, updated_at = now()
--  where id::text like any (array['87e15434%','e2b144a5%','9a16cf44%'])
--    and title in ('【振込トーホー】給料','【振込Live】給料','【振込SK】給料');

-- ■停止後の確認（is_active が3本とも false、『給料計算』が true のまま）
-- select title, is_active from public.hq_task_templates where title like '%給料%' order by title;

-- ■適用結果（2026-11-09）: テンプレ3本 is_active=false（『給料計算』2292b88c は true のまま）。11月分 【振込SK】給料 1a0bc84a を論理削除(deleted_at)。【振込トーホー】1c87cccd・【振込Live】42f148dd は進行中のまま未変更。
-- ■戻し方（SKタスク）: update public.hq_tasks set deleted_at = null where id::text like '1a0bc84a%';
