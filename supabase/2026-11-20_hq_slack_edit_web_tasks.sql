-- 2026-11-20 担当B（社長の依頼）— 管理システムの画面で作った本部タスクも、Slack から［💬 コメント］［✏️ 編集］［🧩 工程を編集］できるようにする
-- 【困りごと】Slack から付けたタスクにしか、Slack の操作ができなかった（記録表 hq_slack_task_log に行があるタスクだけを許す作りだったため）。
-- 【直し方】4 つの DB 関数（hq_slack_task_get / hq_slack_task_update / hq_slack_step_update / hq_slack_steps_get）の「記録表に行が無ければ断る」所だけを、
--   「タスクが存在すれば OK」に変える。作った人の判定は、記録表に無いときは hq_tasks.created_by を使う。
--   ・直せる人は今までと同じ（作った人・マスター・CEO・HQ）。コメントは画面と同じ見える範囲の人
--   ・記録表への行追加はしない（行があるかどうかで「完了通知」「工程の順番」の扱いが変わる仕組みのため、画面で作ったタスクの動きは変えない）
-- 【安全】今の本番の関数の定義を取り出して、決まった文字列だけを置き換える。想定と違えば（見つからない／2 回以上ある／関数が 4 本でない）何も変えずに止まる。
-- 【戻し方】2026-12-17_hq_slack_task_edit.sql と 2026-12-18_hq_slack_step_edit.sql の関数の定義を、もう一度実行する。
do $$
declare r record; v_new text; v_n integer; v_cnt integer := 0; v_expect integer;
  c_fn text[] := array['hq_slack_task_get', 'hq_slack_task_update', 'hq_slack_step_update', 'hq_slack_steps_get'];
begin
  select count(*) into v_cnt from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = any(c_fn);
  if v_cnt <> 4 then raise exception '対象の関数が 4 本ではありません（% 本）。何も変えずに止めました', v_cnt; end if;

  for r in select p.oid, p.proname from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = any(c_fn) loop
    v_new := pg_get_functiondef(r.oid);

    if r.proname = 'hq_slack_steps_get' then
      v_n := (length(v_new) - length(replace(v_new, 'if not exists (select 1 from hq_slack_task_log where task_id = p_task) then', ''))) / length('if not exists (select 1 from hq_slack_task_log where task_id = p_task) then');
      if v_n <> 1 then raise exception '% : 置き換え対象(1)が % 個でした。何も変えずに止めました', r.proname, v_n; end if;
      v_new := replace(v_new, 'if not exists (select 1 from hq_slack_task_log where task_id = p_task) then', 'if not exists (select 1 from hq_tasks where id = p_task and deleted_at is null) then');
    else
      -- ① 記録表に行が無くても止めない
      v_n := (length(v_new) - length(replace(v_new, 'if v_l.id is null or v_t.id is null then', ''))) / length('if v_l.id is null or v_t.id is null then');
      if v_n <> 1 then raise exception '% : 置き換え対象(①)が % 個でした。何も変えずに止めました', r.proname, v_n; end if;
      v_new := replace(v_new, 'if v_l.id is null or v_t.id is null then', 'if v_t.id is null then');
      -- ② 作った人（記録表に無ければ hq_tasks.created_by）
      v_n := (length(v_new) - length(replace(v_new, '''creator_id'', v_l.created_by', ''))) / length('''creator_id'', v_l.created_by');
      if v_n <> 1 then raise exception '% : 置き換え対象(②)が % 個でした。何も変えずに止めました', r.proname, v_n; end if;
      v_new := replace(v_new, '''creator_id'', v_l.created_by', '''creator_id'', coalesce(v_l.created_by, v_t.created_by)');
      -- ③ 直せる人の判定（update 系のみ）
      if r.proname in ('hq_slack_task_update', 'hq_slack_step_update') then
        v_n := (length(v_new) - length(replace(v_new, 'v_u.id = v_l.created_by', ''))) / length('v_u.id = v_l.created_by');
        if v_n <> 1 then raise exception '% : 置き換え対象(③)が % 個でした。何も変えずに止めました', r.proname, v_n; end if;
        v_new := replace(v_new, 'v_u.id = v_l.created_by', 'v_u.id = coalesce(v_l.created_by, v_t.created_by)');
      end if;
    end if;
    execute v_new;
  end loop;
end $$;

-- 確認: 4 本とも新しい形になっていれば 4 と出る
select count(*) as 新しい形の関数の本数
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace
   and p.proname in ('hq_slack_task_get', 'hq_slack_task_update', 'hq_slack_step_update', 'hq_slack_steps_get')
   and pg_get_functiondef(p.oid) not like '%v_l.id is null or v_t.id is null%'
   and pg_get_functiondef(p.oid) not like '%from hq_slack_task_log where task_id = p_task) then%';
