-- ============================================================
-- E-6: 入社登録完了→本部タスク自動作成の受け皿
-- 作成: 2026-09-01 ／ 担当E（本部タスクボード）
-- 実装指示書_ラウンド5_2026-08-31.md §6.1「E-6＋B-18（項目4）」に対応
--
-- 分担: 本ファイル（E-6）＝hq側の受け皿（自動生成RPC・工程/チェックリストのひな形・
-- 工程4のLINE案内ボタンが呼ぶaction_kind/action_payloadの受け皿列）。
-- nippo側（B-18）＝入社登録完了時にこのRPC(hq_create_onboarding_task)を呼ぶフック＋
-- 下記「LINE案内送信の契約」で決めたEdge Functionの実装。連携はWORKLOG参照。
--
-- 新規列のみ追加（既存ルールどおり）:
--   hq_task_steps.action_kind    … 工程パネルに特別なアクションボタンを出すための種別
--                                   （今回は'onboarding_line_guide'のみ。将来の他アクションにも使える汎用列）
--   hq_task_steps.action_payload … そのアクションが必要とするデータ（jsonb。今回は{name,email}）
-- ============================================================

alter table hq_task_steps add column if not exists action_kind text;
alter table hq_task_steps add column if not exists action_payload jsonb;

-- ============================================================
-- hq_create_onboarding_task: 入社登録完了時にnippo側（B-18）から呼ばれる想定のRPC。
-- タスク・工程4件・工程3のチェックリスト4件をまとめて自動作成する。
--
-- 引数:
--   p_name     … 新入社員の氏名（必須。タスク名「入社登録（○○さん）」・各工程title・
--                LINE案内のaction_payloadに使う）
--   p_email    … メールアドレス（工程1のタイトルに自動反映）
--   p_corp     … 法人（'LiveGate'|'SK'|'N-Style'|'トーホー'のいずれか。hq_tasks.corpの
--                CHECK制約に合わせて呼び出し側で正しい値を渡すこと）
--   p_business … 所属事業所（自由記述。工程2のタイトルに自動反映。任意）
--   p_target_date … 対象日（省略時は今日。期限＝対象日の翌日で自動設定）
--
-- 担当: 固定＝「青山純」。見つからない場合は代理「齋藤　隆治」（2026-09-01ユーザー回答）。
-- どちらも見つからなければ担当未定のまま作成する（タスク自体は必ず作られる）。
--
-- 権限: hq_can_manage()（マスター・社長・本部）までは絞らず、認証済みの有効ユーザーであれば
-- 呼べるようにしている（nippo側の入社登録フローがどの役職まで許可するかはB-18側の判断のため。
-- 必要であれば後から絞り込み可能）。
-- ============================================================
create or replace function hq_create_onboarding_task(
  p_name text,
  p_email text default null,
  p_corp text default 'N-Style',
  p_business text default null,
  p_target_date date default current_date
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_task_id uuid;
  v_assignee uuid;
  v_step3_id uuid;
begin
  if auth.uid() is null or not exists(select 1 from users u where u.id = auth.uid() and u.is_active) then
    raise exception '認証が必要です';
  end if;
  if p_name is null or trim(p_name) = '' then
    raise exception '氏名が必要です';
  end if;

  select id into v_assignee from users where name = '青山純' and is_active limit 1;
  if v_assignee is null then
    select id into v_assignee from users where name = '齋藤　隆治' and is_active limit 1;
  end if;

  insert into hq_tasks (title, corp, freq, target_date, due_date, notes, description, visibility, created_by)
  values (
    '入社登録（' || p_name || 'さん）', p_corp, 'once', p_target_date, p_target_date + 1, '',
    '新入社員: ' || p_name || 'さん' || E'\n' ||
    'メールアドレス: ' || coalesce(p_email, '（未設定）') || E'\n' ||
    '所属事業所: ' || coalesce(p_business, '（未設定）'),
    'all', auth.uid()
  ) returning id into v_task_id;

  insert into hq_task_steps(task_id, title, assignee_id, sort_order, kind)
  values (v_task_id, 'メールアドレスを登録（' || coalesce(p_email, '未設定') || '）', v_assignee, 10, 'step');

  insert into hq_task_steps(task_id, title, assignee_id, sort_order, kind)
  values (v_task_id, '所属事業所を入力（' || coalesce(p_business, '未設定') || '）', v_assignee, 20, 'step');

  insert into hq_task_steps(task_id, title, assignee_id, sort_order, kind)
  values (v_task_id, '給与・明細設定を入力', v_assignee, 30, 'step')
  returning id into v_step3_id;
  insert into hq_step_checklist_items(step_id, title, sort_order) values
    (v_step3_id, '時給', 10),
    (v_step3_id, '交通費', 20),
    (v_step3_id, '源泉所得税の適用', 30),
    (v_step3_id, '個別Web給与明細表示設定', 40);

  insert into hq_task_steps(task_id, title, assignee_id, sort_order, kind, action_kind, action_payload)
  values (v_task_id, 'LINEで登録案内を送る', v_assignee, 40, 'step', 'onboarding_line_guide',
          jsonb_build_object('name', p_name, 'email', p_email));

  insert into hq_task_activity(task_id, actor_id, kind, detail)
  values (v_task_id, auth.uid(), 'create', '入社登録により自動作成（' || p_name || 'さん）');

  return v_task_id;
end;
$$;

-- RPCはSECURITY DEFINERだが、呼び出し自体はREST経由でPOSTするため実行権限が必要
grant execute on function hq_create_onboarding_task(text, text, text, text, date) to authenticated;
