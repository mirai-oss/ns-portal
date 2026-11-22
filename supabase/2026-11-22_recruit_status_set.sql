-- 2026-11-22 担当B（社長依頼）— 採用管理（Slack のカード）から、応募者の状態を選んで変えられるようにする
--  社長: 「採用応募のところでステータスの変更をできるように（今は採用だけできるようになっているのを、選べるように）」
--  やること（新しい関数 2 つだけ。テーブル・既存の関数は触らない）:
--   ① recruit_status_info … 窓を開くときの材料（氏名・いまの状態・離脱の記録）。権限（採用の権限＋この応募者の店舗を見られる）を確かめる
--   ② recruit_status_set  … 状態を変える。選べる状態: 新規／連絡済み／面接設定／面接済み／不採用／辞退／連絡なし（バックレ）。
--        ・「採用」と「退職」には、ここからは変えない（採用は［採用を決める］＝入社登録の流れ・退職は別の手続き）。採用・退職になっている応募者の状態も、ここからは変えない
--        ・窓を開いたときの状態と、いまの状態が違えば、何も変えずに「先に変更されています」（古い画面からの上書きを防ぐ）
--        ・同じ依頼の鍵の 2 回目は、前の結果を返すだけ（二重に変えない）
--        ・不採用／辞退／連絡なし にするとき、離脱の段階・理由が選ばれていれば、管理画面の「離脱の記録」と同じ列（exit_stage / exit_reason・exit_source='manual'）に残す。選ばれていなければ、残さない（管理画面で、あとから記録できる）
--        ・終了の状態から、選考中の状態に戻すときは、離脱の記録を消す（終了していないので）
--        ・Slack への反映は、既存のトリガー（recruit_notice_upd）が拾う。ここからは Slack を呼ばない
--  操作の記録は、既存の applicant_ops（op='status_set'）に残す。
-- 【戻し方】drop function public.recruit_status_set(uuid, text, text, text, text, text, uuid, text, text); drop function public.recruit_status_info(uuid, uuid);
begin;

create or replace function public.recruit_status_info(p_applicant uuid, p_actor uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_actor uuid; v_a record;
begin
  if auth.uid() is not null then v_actor := auth.uid();
  elsif onboarding_is_service() then v_actor := p_actor;
  else raise exception '認証が必要です';
  end if;
  if v_actor is null then raise exception '操作する人（p_actor）が指定されていません'; end if;
  select a.id, a.name, a.status, a.store_id, a.exit_stage, a.exit_reason into v_a from applicants a where a.id = p_applicant;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', '応募者が見つかりません'); end if;
  if not (coalesce((select u.is_active from users u where u.id = v_actor), false)
          and has_feature(v_actor, 'recruit') and can_see_applicant(v_actor, v_a.store_id)) then
    return jsonb_build_object('ok', false, 'code', 'denied', 'message', '権限がありません');
  end if;
  return jsonb_build_object('ok', true, 'applicant_id', v_a.id, 'applicant_name', v_a.name, 'status', v_a.status,
    'exit_stage', v_a.exit_stage, 'exit_reason', v_a.exit_reason, 'locked', v_a.status in ('hired', 'retired'));
end $$;

create or replace function public.recruit_status_set(
  p_applicant uuid, p_status text, p_expected_status text, p_exit_stage text, p_exit_reason text, p_request_key text,
  p_actor uuid default null, p_via text default 'web', p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid; v_via text; v_key text := btrim(coalesce(p_request_key, ''));
  v_reason text := nullif(left(btrim(coalesce(p_reason, '')), 300), '');
  v_a record; v_prev applicant_ops%rowtype; v_op uuid; v_before jsonb; v_after jsonb; v_exit boolean; v_now timestamptz := now();
  v_stage text := nullif(btrim(coalesce(p_exit_stage, '')), ''); v_why text := nullif(btrim(coalesce(p_exit_reason, '')), '');
begin
  if auth.uid() is not null then v_actor := auth.uid();
  elsif onboarding_is_service() then v_actor := p_actor;
  else raise exception '認証が必要です';
  end if;
  if v_actor is null then raise exception '操作する人（p_actor）が指定されていません'; end if;
  v_via := coalesce(nullif(btrim(coalesce(p_via, '')), ''), 'web');
  if v_via not in ('slack', 'web', 'app') then raise exception 'p_via が正しくありません'; end if;
  if length(v_key) < 8 or length(v_key) > 200 then raise exception '依頼の鍵（p_request_key）が正しくありません'; end if;
  if p_applicant is null then raise exception '応募者が指定されていません'; end if;

  select a.id, a.status, a.store_id, a.exit_stage, a.exit_reason into v_a from applicants a where a.id = p_applicant for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', '応募者が見つかりません'); end if;

  select * into v_prev from applicant_ops where request_key = v_key;
  if found then
    if v_prev.applicant_id <> p_applicant or v_prev.op <> 'status_set' or v_prev.actor_id is distinct from v_actor then
      return jsonb_build_object('ok', false, 'code', 'key_reused', 'message', '同じ依頼の鍵が、別の操作で使われています');
    end if;
    return jsonb_build_object('ok', v_prev.result in ('done', 'noop'), 'code', v_prev.result, 'replayed', true, 'op_id', v_prev.id,
      'message', case v_prev.result when 'done' then '状態を変更しました（処理済み）' when 'noop' then 'すでにその状態です'
                                   when 'conflict' then '先に変更されています' when 'denied' then '権限がありません' else '変更できませんでした' end);
  end if;

  v_before := jsonb_build_object('status', v_a.status, 'exit_stage', v_a.exit_stage, 'exit_reason', v_a.exit_reason);
  v_after  := jsonb_build_object('status', p_status, 'expected_status', p_expected_status, 'exit_stage', v_stage, 'exit_reason', v_why);

  if not (coalesce((select u.is_active from users u where u.id = v_actor), false)
          and has_feature(v_actor, 'recruit') and can_see_applicant(v_actor, v_a.store_id)) then
    v_op := recruit_op_log(p_applicant, 'status_set', v_actor, v_via, v_key, v_before, v_after, 'denied', 'no_permission', v_reason);
    return jsonb_build_object('ok', false, 'code', 'denied', 'op_id', v_op, 'message', '権限がありません');
  end if;

  -- 選べる状態だけ。採用・退職は、ここからは変えない（採用は［採用を決める］から）
  if p_status is null or p_status not in ('new', 'contacted', 'interview_set', 'interviewed', 'rejected', 'declined', 'noshow') then
    v_op := recruit_op_log(p_applicant, 'status_set', v_actor, v_via, v_key, v_before, v_after, 'failed', 'invalid_status', v_reason);
    return jsonb_build_object('ok', false, 'code', 'invalid_status', 'op_id', v_op, 'message', 'その状態には、ここからは変えられません（採用は［採用を決める］から行います）');
  end if;
  if v_a.status in ('hired', 'retired') then
    v_op := recruit_op_log(p_applicant, 'status_set', v_actor, v_via, v_key, v_before, v_after, 'failed', 'locked', v_reason);
    return jsonb_build_object('ok', false, 'code', 'locked', 'op_id', v_op, 'message', '採用・退職になっている応募者の状態は、ここからは変えられません（管理画面から行ってください）');
  end if;
  if (v_stage is not null and v_stage not in ('before_interview', 'interview', 'after_hire', 'during_registration', 'first_shift'))
     or (v_why is not null and v_why not in ('interview_noshow', 'declined_before_interview', 'no_contact_after_hire', 'dropped_during_registration', 'first_shift_noshow', 'declined_before_start', 'company_reason', 'other')) then
    v_op := recruit_op_log(p_applicant, 'status_set', v_actor, v_via, v_key, v_before, v_after, 'failed', 'invalid_exit', v_reason);
    return jsonb_build_object('ok', false, 'code', 'invalid_exit', 'op_id', v_op, 'message', '離脱の段階・理由が正しくありません');
  end if;

  if v_a.status = p_status and v_stage is null and v_why is null then
    v_op := recruit_op_log(p_applicant, 'status_set', v_actor, v_via, v_key, v_before, v_after, 'noop', null, v_reason);
    return jsonb_build_object('ok', true, 'code', 'noop', 'op_id', v_op, 'message', 'すでにその状態です');
  end if;

  -- 押した人が見ていた状態と、いまの状態が違う: 何も変えない
  if p_expected_status is not null and v_a.status is distinct from p_expected_status then
    v_op := recruit_op_log(p_applicant, 'status_set', v_actor, v_via, v_key, v_before, v_after, 'conflict', 'expected_mismatch', v_reason);
    return jsonb_build_object('ok', false, 'code', 'conflict', 'op_id', v_op, 'message', '先に変更されています', 'current_status', v_a.status);
  end if;

  v_exit := p_status in ('rejected', 'declined', 'noshow');
  if v_exit then
    update applicants set status = p_status, status_changed_at = case when v_a.status is distinct from p_status then v_now else status_changed_at end,
           exit_stage = coalesce(v_stage, exit_stage), exit_reason = coalesce(v_why, exit_reason),
           exit_source = case when v_stage is not null or v_why is not null then 'manual' else exit_source end,
           exited_at = case when v_stage is not null or v_why is not null then coalesce(exited_at, v_now) else exited_at end,
           last_actor_id = v_actor, last_actor_at = v_now, updated_at = v_now
     where id = p_applicant;
  else
    -- 選考中の状態に戻す: 終了していないので、離脱の記録は消す
    update applicants set status = p_status, status_changed_at = case when v_a.status is distinct from p_status then v_now else status_changed_at end,
           exit_stage = null, exit_reason = null, exit_note = null, exit_source = null, exited_at = null,
           last_actor_id = v_actor, last_actor_at = v_now, updated_at = v_now
     where id = p_applicant;
  end if;
  v_op := recruit_op_log(p_applicant, 'status_set', v_actor, v_via, v_key, v_before, v_after, 'done', null, v_reason);
  return jsonb_build_object('ok', true, 'code', 'done', 'op_id', v_op, 'message', '状態を変更しました', 'before_status', v_a.status, 'after_status', p_status);
end $$;

revoke all on function public.recruit_status_info(uuid, uuid), public.recruit_status_set(uuid, text, text, text, text, text, uuid, text, text) from public, anon, authenticated;
grant execute on function public.recruit_status_info(uuid, uuid), public.recruit_status_set(uuid, text, text, text, text, text, uuid, text, text) to service_role;

commit;
