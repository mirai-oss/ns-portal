-- ============================================================
-- 2026-11-11 担当B（設計の依頼・ユーザー承認待ち）— 2026-10 トーホーの給料確定を「取消さずに」やり直す（既存『10月分 【振込トーホー】給料』への工程追加だけ）
-- 【背景】10月の確定は題名の月ずれの不具合のため、振込タスクが既存タスクに紐づかなかった（現金手渡しは新規作成・紐づき済み）。給料確定ボタンは確定済みの月では押せない（v171）ので、
--   取消（U-27）を使わずに、確定の関数を同じ月・同じ会社でもう一度だけ呼ぶ。関数は冪等: 確定の印は on conflict do nothing・既にある links（現金）は何もしない・無い links（振込）だけ追加
-- 【やること】DOブロック内で「マスター本人として」関数を呼ぶ（SQL Editor は auth.uid() が無いため、このDOブロックの中だけ claims を設定。終われば消える）。1トランザクション
-- 【変わるもの】振込: 既存の『10月分 【振込トーホー】給料』(進行中・期限11/30) に工程『振込対象者の確認（給料確定リスト）』を1つ足し、対象者のチェック項目を載せ、links に transfer を1行追加
-- 【変わらないもの】現金手渡しタスク・サイン記録・payroll_finalized・給与仕訳の paid_at・C の振込CSV出力の記録（payroll_transfer_* ）には一切触れない。通知: #本部-経理監視 に確定結果が1通出る（⚠️が付けば理由が書いてある）
-- 【安全ガード】想定と違えば停止: 2026-10 トーホーが確定済み・transfer の links がまだ無い・cash の links が1件・既存『10月分 【振込トーホー】給料』(期限11/30)が1件で未完了
-- 【rollback】追加した工程の取り外し: 給料確定の取消(U-27)は現金手渡しタスクごと取り消すので使わず、必要なら担当Bが工程だけ外すSQLを出す
-- ============================================================
do $$
declare v_corp uuid; v_master uuid; v_n int; r jsonb;
begin
  select id into v_corp from corporations where name = 'トーホー';
  select id into v_master from users where is_master and is_active order by created_at limit 1;
  if v_corp is null or v_master is null then raise exception '停止: 法人またはマスターが見つかりません'; end if;
  if not exists (select 1 from payroll_finalized where year_month = '2026-10' and corporation_id = v_corp) then raise exception '停止: 2026-10 トーホーが未確定です'; end if;
  if exists (select 1 from payroll_task_links where year_month = '2026-10' and corporation_id = v_corp and kind = 'transfer') then raise exception '停止: 振込の紐づけが既にあります（やり直し不要）'; end if;
  select count(*) into v_n from payroll_task_links where year_month = '2026-10' and corporation_id = v_corp and kind = 'cash';
  if v_n <> 1 then raise exception '停止: 現金手渡しの紐づけが % 件です（1件のはず）', v_n; end if;
  select count(*) into v_n from hq_tasks t where t.corp = 'トーホー' and t.template_id is not null and t.deleted_at is null and t.status <> 'done'
     and t.title ~ '^10月分[[:space:]　]*【振込トーホー】給料$' and t.due_date >= date '2026-11-01' and t.due_date <= date '2026-12-15';
  if v_n <> 1 then raise exception '停止: 紐づけ先の既存タスクが % 件です（1件のはず）', v_n; end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_master::text, 'role', 'authenticated')::text, true);
  r := public.hq_create_payroll_tasks('2026-10', null, v_corp);
  perform set_config('request.jwt.claims', '', true);
  raise notice '結果: %', r;
  if coalesce((r->>'transfer_attached')::boolean, false) is not true then raise exception '停止: 振込タスクに紐づきませんでした（%）。全て元に戻します', r::text; end if;
end $$;

-- ===== 確認（無害・件数のみ）=====
select (select count(*) from payroll_task_links where year_month = '2026-10' and kind = 'transfer') as 振込の紐づけ,
       (select count(*) from payroll_task_links where year_month = '2026-10' and kind = 'cash') as 現金の紐づけ,
       (select count(*) from hq_task_steps s join payroll_task_links l on l.step_id = s.id where l.year_month = '2026-10' and l.kind = 'transfer') as 足した工程,
       (select count(*) from hq_step_checklist_items i join payroll_task_links l on l.step_id = i.step_id where l.year_month = '2026-10' and l.kind = 'transfer') as 振込のチェック項目,
       (select count(*) from hq_tasks where title like '10月分%現金手渡し%' and deleted_at is null) as 現金手渡しタスク;
