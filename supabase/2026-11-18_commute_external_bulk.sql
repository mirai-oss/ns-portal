-- 2026-11-18 案3の続き: 初期の一括取り込み。管理システムに交通費の記録がほとんど無い（記録のある人は 1 人だけ）ため、
--   スマレジの設定を「最初の基準」として一括で取り込む。社長・マスターだけ・理由が必須・スマレジへは何も送らない。
--   p_user を指定すると、その人の分だけ。実行は、社長の明示の指示があってから。
--   rollback: 2026-11-18_commute_external_bulk_rollback.sql（関数を消すだけ。取り込み済みの行は、控えの resolve_note で見分けられる）
create or replace function public.hr_commute_external_import_all(p_reason text, p_user uuid default null, p_actor uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare c record; n int := 0;
begin
  for c in select id from commute_external_changes where status = 'open' and (p_user is null or user_id = p_user) order by user_id, effective_date loop
    perform public.hr_commute_external_import(c.id, p_reason, p_actor);
    n := n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'imported', n);
end $$;
revoke all on function public.hr_commute_external_import_all(text, uuid, uuid) from public, anon;
grant execute on function public.hr_commute_external_import_all(text, uuid, uuid) to authenticated, service_role;
