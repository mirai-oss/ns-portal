-- 2026-09-02（担当E）ユーザー実機フィードバック対応:
-- ①入社登録タスクの法人が常に既定値「N-Style」になってしまう（nippo側hqNotifyOnboarding()は
--   p_corpを渡していないため、hq_create_onboarding_task()の既定値'N-Style'がそのまま使われていた）
--   → p_business（所属事業所＝店舗名）からstores.corporation_id経由でcorporationsを引き、
--     実際の法人を自動判定するように変更（既定値へのフォールバックは'トーホー'に変更。
--     店舗名が一致しない/未設定の場合のみ使われる保険）
-- ②工程ごとの期限が入っておらず「期限が近いタスク」として表示されない
--   （E-5でボードの並び替え・バッジは「いま止まっている工程」のdue_dateを見る設計にしたため、
--   工程側にdue_dateが無いと全体期限が入っていても近い順に出てこなかった）
--   → 4つの工程すべてにタスクの全体期限と同じ日付（p_target_date + 1）を設定
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

  insert into hq_task_steps(task_id, title, assignee_id, sort_order, kind, due_date)
  values (v_task_id, '所属事業所を入力（' || coalesce(p_business, '未設定') || '）', v_assignee, 20, 'step', v_due);

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
