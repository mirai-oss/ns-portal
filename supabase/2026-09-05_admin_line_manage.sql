-- 2026-09-05 担当B（nippo）
-- ユーザー要望「入社してる方のLINE連携はどこでやるの？」→ アカウント管理の従業員詳細画面から
-- 本部/社長が本人に代わって合言葉を発行・解除できるようにする（既存の自己連携用RPCの管理者版）。
-- user_issue_line_code/user_unlink_lineはauth.uid()固定のため、対象ユーザーを指定できる管理者版を新設。

create or replace function public.admin_issue_line_code(p_user_id uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_code text; v_oa text;
begin
  if my_role() not in ('CEO','HQ') then
    raise exception '権限がありません（社長・本部のみ）';
  end if;
  if not exists(select 1 from users where id = p_user_id) then
    raise exception '対象のユーザーが見つかりません';
  end if;
  select line_code into v_code from users where id = p_user_id;
  if v_code is null then
    loop
      select string_agg(substr('23456789ABCDEFGHJKLMNPQRSTUVWXYZ',
                               (floor(random()*32)+1)::int, 1), '')
        into v_code from generate_series(1,6);
      exit when not exists(
        select 1 from users where line_code = v_code
        union all select 1 from applicants where line_code = v_code
      );
    end loop;
    update users set line_code = v_code, updated_at = now() where id = p_user_id;
  end if;
  select value into v_oa from app_secrets where key = 'line_oa_id';
  return jsonb_build_object('ok', true, 'code', v_code, 'oa', coalesce(v_oa, ''));
end $function$;

create or replace function public.admin_unlink_line(p_user_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  if my_role() not in ('CEO','HQ') then
    raise exception '権限がありません（社長・本部のみ）';
  end if;
  update users set line_user_id = null, line_linked_at = null, line_code = null, updated_at = now()
   where id = p_user_id;
end $function$;
