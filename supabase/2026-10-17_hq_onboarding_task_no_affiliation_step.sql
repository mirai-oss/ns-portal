-- ============================================================
-- 2026-10-17 担当B（nippo）— 入社登録の本部タスクから、工程「所属事業所を入力」を外す
-- 【状態】事前報告（ユーザー確認待ち・未適用）。対象RPCは担当Eの hq_create_onboarding_task（最新定義＝2026-09-02_hq_onboarding_task_corp_and_due.sql）
--
-- 【理由】ユーザー指示（2026-10-17）: 管理システムの所属店舗がスマレジの所属事業所へ自動で同期される（担当Dの毎日の所属同期・従業員編集の
--   「スマレジに登録」ボタン・今すぐ同期）ため、手作業の工程「所属事業所を入力」は不要。今後は付けない。
-- 【現構造】入社登録タスクは4工程（①メールアドレスを登録 ②所属事業所を入力 ③給与・明細設定を入力 ④LINEで登録案内を送る）
-- 【変更】②を作らない（他の工程・チェックリスト・タスクの説明文の「所属事業所:」行は変更なし）。既に作成済みのタスクは変えない
-- 【影響】これから作られる入社登録タスクだけ（3工程になる）。既存のタスク・工程は触らない
-- 【前提・注意】新しい入社者の所属事業所は、毎日の所属同期（smaregi-affiliation-sync）が反映する。このジョブはリポジトリ変数
--   AFFILIATION_SYNC_MODE=apply のときだけ実際に反映する設定（それまでは試行のみ）。適用前に「apply」になっていることを担当D/司令塔に確認すること
-- 【migration】本ファイル（create or replace・冪等）
-- 【rollback】2026-09-02_hq_onboarding_task_corp_and_due.sql をもう一度実行（工程②が復活）
-- ============================================================
create or replace function hq_create_onboarding_task(
  p_name text,
  p_email text default null,
  p_corp text default 'トーホー',
  p_business text default null,
  p_target_date date default current_date
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_task_id uuid;
  v_assignee uuid;
  v_step3_id uuid;
  v_corp text;
  v_due date;
begin
  if auth.uid() is null or not exists(select 1 from users u where u.id = auth.uid() and u.is_active) then
    raise exception '認証が必要です';
  end if;
  if p_name is null or trim(p_name) = '' then
    raise exception '氏名が必要です';
  end if;

  v_due := p_target_date + 1;

  -- 所属事業所（店舗名）から実際の法人を自動判定（見つからなければp_corpへフォールバック）
  select c.name into v_corp
    from stores s join corporations c on c.id = s.corporation_id
    where s.name = p_business and s.is_active
    limit 1;
  if v_corp is null then
    v_corp := coalesce(p_corp, 'トーホー');
  end if;

  select id into v_assignee from users where name = '青山純' and is_active limit 1;
  if v_assignee is null then
    select id into v_assignee from users where name = '齋藤　隆治' and is_active limit 1;
  end if;

  insert into hq_tasks (title, corp, freq, target_date, due_date, notes, description, visibility, created_by)
  values (
    '入社登録（' || p_name || 'さん）', v_corp, 'once', p_target_date, v_due, '',
    '新入社員: ' || p_name || 'さん' || E'\n' ||
    'メールアドレス: ' || coalesce(p_email, '（未設定）') || E'\n' ||
    '所属事業所: ' || coalesce(p_business, '（未設定）'),
    'all', auth.uid()
  ) returning id into v_task_id;

  insert into hq_task_steps(task_id, title, assignee_id, sort_order, kind, due_date)
  values (v_task_id, 'メールアドレスを登録（' || coalesce(p_email, '未設定') || '）', v_assignee, 10, 'step', v_due);

  -- 2026-10-17: 工程「所属事業所を入力」は廃止（管理システムの所属店舗をスマレジへ自動同期するため。ユーザー指示）。sort_order=20は欠番のまま

  insert into hq_task_steps(task_id, title, assignee_id, sort_order, kind, due_date)
  values (v_task_id, '給与・明細設定を入力', v_assignee, 30, 'step', v_due)
  returning id into v_step3_id;
  insert into hq_step_checklist_items(step_id, title, sort_order) values
    (v_step3_id, '時給', 10),
    (v_step3_id, '交通費', 20),
    (v_step3_id, '源泉所得税の適用', 30),
    (v_step3_id, '個別Web給与明細表示設定', 40);

  insert into hq_task_steps(task_id, title, assignee_id, sort_order, kind, action_kind, action_payload, due_date)
  values (v_task_id, 'LINEで登録案内を送る', v_assignee, 40, 'step', 'onboarding_line_guide',
          jsonb_build_object('name', p_name, 'email', p_email), v_due);

  insert into hq_task_activity(task_id, actor_id, kind, detail)
  values (v_task_id, auth.uid(), 'create', '入社登録により自動作成（' || p_name || 'さん）');

  return v_task_id;
end;
$$;

grant execute on function hq_create_onboarding_task(text, text, text, text, date) to authenticated;
