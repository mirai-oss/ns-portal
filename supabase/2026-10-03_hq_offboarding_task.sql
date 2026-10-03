-- ============================================================
-- 退職手続きの本部タスク自動発行（担当E）  作成: 2026-10-03
-- 実装指示書_退職手続きタスクと書類配布_担当BE_2026-10-03.md §2 に対応
--
-- 【DB変更の事前報告】（ユーザー確認後に適用。未適用の間はこのファイルは設計案）
-- ■なぜ必要か
--   退職承認（担当B・hr_approve_retirement）の直後に、本部が行う退職手続き（健康保険証回収・
--   資格喪失届・住民税・源泉徴収票）を漏れなく追えるよう、入社登録タスクと同じ作法で
--   本部タスクを自動発行したい。
-- ■現在の構造
--   hq_tasks: related_user_id列なし（従業員に紐づけられない＝同じ人の二重発行を防げない）。
--   hq_task_steps.action_kind/action_payload: 既存（入社のLINE案内ボタン用・列追加は不要）。
--   hq_create_offboarding_task: 未作成。
-- ■変更内容
--   1) hq_tasks に列 related_user_id uuid（users.id・on delete set null）＋部分index を追加
--   2) RPC hq_create_offboarding_task を新設（タスク＋工程。社員=5工程／アルバイト=源泉徴収票のみ）
--   ※Storageバケット hr-documents・hr_documents表・hr_register_document は担当B
--     （supabase/2026-10-03_hr_documents.sql）が作成する。本ファイルは作らない（二重管理回避）
-- ■既存データ・既存機能への影響
--   列追加は NULL 許容のみ（既存行は無変更）。新RPCは新設のため既存機能に影響なし。
--   入社登録タスク（hq_create_onboarding_task）・LINE案内ボタンには一切触れない。
-- ■rollback
--   drop function if exists hq_create_offboarding_task(uuid,text,text,boolean,date,date,date);
--   drop index if exists idx_hq_tasks_related_user;
--   alter table hq_tasks drop column if exists related_user_id;
--   （発行済みの退職タスクは hq_tasks の task_category='offboarding' で特定して削除可能）
-- ============================================================

alter table hq_tasks add column if not exists related_user_id uuid references users(id) on delete set null;
create index if not exists idx_hq_tasks_related_user on hq_tasks(related_user_id) where related_user_id is not null;

-- ============================================================
-- hq_create_offboarding_task
--   p_user_id         … 退職する従業員（users.id）。related_user_idに保存し二重発行判定に使う
--   p_name            … 氏名（タスク名・説明に使う）
--   p_corp            … 法人（'LiveGate'|'SK'|'N-Style'|'トーホー'。それ以外は'トーホー'へ）
--   p_is_employee     … true=社員扱い（SHAIN/TENCHO/TEAM/HQ）／false=アルバイト（AL）
--   p_retirement_date … 退職日
--   p_approved_on     … 承認日（工程1の期限＝承認日+3日）
--   p_final_pay_date  … 最終給与の支払日（任意）。省略時は「退職月の翌月25日」と仮定（★要確認）。
--                       工程5の期限＝この日+3日
--
-- 期限（§1の表）: 1=承認日+3日／2=退職日／3=退職日+5日／4=退職日の翌月10日／5=最終給与支払日+3日
-- 担当: 入社登録と同じ固定担当（青山純→見つからなければ齋藤　隆治→無ければ担当未定で作成）
-- 返り値: タスクid。同じ従業員の退職タスクが未完了で既にあれば、新規作成せずそのidを返す（べき等）
-- 権限: 本部担当者（マスター・社長・本部）または auth.uid()が無いサーバー側ジョブ
-- ============================================================
create or replace function hq_create_offboarding_task(
  p_user_id uuid,
  p_name text,
  p_corp text,
  p_is_employee boolean,
  p_retirement_date date,
  p_approved_on date default current_date,
  p_final_pay_date date default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_task_id uuid;
  v_existing uuid;
  v_assignee uuid;
  v_corp text;
  v_pay date;
  v_year int;
  v_title text;
  v_desc text;
  v_retire_txt text;
begin
  if auth.uid() is not null and not hq_can_manage() then
    raise exception '権限がありません（本部担当者のみ）';
  end if;
  if p_user_id is null then
    raise exception '対象の従業員（user_id）が必要です';
  end if;
  if p_name is null or trim(p_name) = '' then
    raise exception '氏名が必要です';
  end if;
  if p_retirement_date is null then
    raise exception '退職日が必要です';
  end if;

  select id into v_existing from hq_tasks
    where related_user_id = p_user_id and task_category = 'offboarding'
      and deleted_at is null and status <> 'done'
    limit 1;
  if v_existing is not null then
    return v_existing;
  end if;

  v_corp := case when p_corp in ('LiveGate','SK','N-Style','トーホー') then p_corp else 'トーホー' end;
  v_pay := coalesce(p_final_pay_date,
                    (date_trunc('month', p_retirement_date) + interval '1 month' + interval '24 days')::date);
  v_year := extract(year from p_retirement_date)::int;
  v_retire_txt := to_char(p_retirement_date, 'YYYY/MM/DD');
  v_title := '退職手続き（' || p_name || 'さん・退職日 ' || v_retire_txt || '）';
  v_desc := '退職者: ' || p_name || 'さん（' || case when p_is_employee then '社員' else 'アルバイト' end || '）' || E'\n' ||
            '退職日: ' || v_retire_txt || E'\n' ||
            '承認日: ' || to_char(coalesce(p_approved_on, current_date), 'YYYY/MM/DD') || E'\n' ||
            '退職承認により自動発行';

  select id into v_assignee from users where name = '青山純' and is_active limit 1;
  if v_assignee is null then
    select id into v_assignee from users where name = '齋藤　隆治' and is_active limit 1;
  end if;

  insert into hq_tasks (title, corp, freq, target_date, due_date, notes, description, visibility,
                        created_by, task_category, related_user_id)
  values (v_title, v_corp, 'once', coalesce(p_approved_on, current_date),
          case when p_is_employee
               then greatest((date_trunc('month', p_retirement_date) + interval '1 month' + interval '9 days')::date, v_pay + 3)
               else v_pay + 3 end,
          '', v_desc, 'all', auth.uid(), 'offboarding', p_user_id)
  returning id into v_task_id;

  if p_is_employee then
    insert into hq_task_steps(task_id, title, assignee_id, sort_order, kind, due_date) values
      (v_task_id, '「退職願」／「退職届」を受け取る', v_assignee, 10, 'step', coalesce(p_approved_on, current_date) + 3),
      (v_task_id, '健康保険証を回収する', v_assignee, 20, 'step', p_retirement_date),
      (v_task_id, '「健康保険・厚生年金保険被保険者資格喪失届」を提出する', v_assignee, 30, 'step', p_retirement_date + 5),
      (v_task_id, '住民税の手続き（異動届・徴収方法の切替）', v_assignee, 40, 'step',
         (date_trunc('month', p_retirement_date) + interval '1 month' + interval '9 days')::date);
  end if;

  insert into hq_task_steps(task_id, title, assignee_id, sort_order, kind, due_date, action_kind, action_payload)
  values (v_task_id, '源泉徴収票をスマレジから出力してアップロードする', v_assignee,
          50, 'step', v_pay + 3, 'offboarding_tax_slip',
          jsonb_build_object('user_id', p_user_id, 'name', p_name, 'year', v_year));

  insert into hq_task_activity(task_id, actor_id, kind, detail)
  values (v_task_id, auth.uid(), 'create', '退職承認により自動作成（' || p_name || 'さん・退職日 ' || v_retire_txt || '）');

  return v_task_id;
end;
$$;

grant execute on function hq_create_offboarding_task(uuid, text, text, boolean, date, date, date) to authenticated;
