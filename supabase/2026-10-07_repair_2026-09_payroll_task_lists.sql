-- 担当C: 2026-09分の給料タスク（既に発行済み）の対象者リストを是正する（1回限り）
-- 事前報告様式（DB変更・本番データの修正）:
-- 理由: 2026-10-07に「給料確定」で発行された9月分タスクの対象者が、給与仕訳の画面の人数と合っていない
--       （詳細は 2026-10-07_hq_create_payroll_tasks_headcount_fix.sql の冒頭）。同じ年月×種別のタスクは再生成されないため、
--       発行済みのチェックリストを直接直す。
-- 現状（2026-10-07 実データで確認）: 振込タスク81名（うち「鍋倉 由里子」は画面で非表示＝対象外の人）、現金手渡しタスク32名
--       （退職済みだが9月分の給与がある3名が漏れている）。チェック済み項目は0件（まだ誰も確認作業を始めていない）。
-- 変更:
--   ① 振込タスクから「鍋倉 由里子」の項目を削除（→80名）
--   ② 現金手渡しタスクへ「カウン カン」「プエイプエイモーウー」「セダイ デイパ」の3項目を追加（→35名）
--   ③ 両タスクの説明文の人数を実数に更新
-- 影響: 上記2タスクのチェックリストのみ。チェック済み項目があれば削除対象外（本ファイルは未チェックのものだけを削除）。
-- migration: 本ファイル（追加はnot existsで重複しない・削除は条件付き＝何度流しても壊れない）。
-- rollback: ①は項目を再追加、②は追加した3項目を削除、③は説明文の人数を元に戻す。

delete from hq_step_checklist_items
 where step_id = (select step_id from payroll_task_links where year_month = '2026-09' and kind = 'transfer')
   and replace(replace(title, ' ', ''), chr(12288), '') = '鍋倉由里子'
   and checked_at is null;

insert into hq_step_checklist_items (step_id, title, sort_order)
select l.step_id, n.name,
       (select coalesce(max(i.sort_order), 0) from hq_step_checklist_items i where i.step_id = l.step_id) + 10 * n.rn
  from payroll_task_links l
  cross join (values ('カウン　カン', 1), ('プエイプエイモーウー', 2), ('セダイ　デイパ', 3)) as n(name, rn)
 where l.year_month = '2026-09' and l.kind = 'cash'
   and not exists (select 1 from hq_step_checklist_items i where i.step_id = l.step_id and i.title = n.name);

update hq_tasks t
   set description = '給料確定ボタンにより自動発行（対象' || (select count(*) from hq_step_checklist_items i where i.step_id = l.step_id) || '名）'
  from payroll_task_links l
 where l.task_id = t.id and l.year_month = '2026-09' and l.kind in ('transfer', 'cash');
