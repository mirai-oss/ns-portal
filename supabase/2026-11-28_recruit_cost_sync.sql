-- 2026-11-28 求人費用の自動反映（社長依頼）: 広告費の内訳シート → recruit_costs（毎月 10〜20 日 9:00 JST・前の月）
--   呼び先: EF recruit-cost-sync。ファイルの ID と固定費は、このリポジトリに書かない（app_secrets / app_settings に別途登録）。
--   戻し方: 2026-11-28_recruit_cost_sync_rollback.sql
begin;

create or replace function public.recruit_cost_replace(p_month date, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public as $function$
declare v_n int; v_manual int;
begin
  if p_month is null or extract(day from p_month) <> 1 or jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception '内容が足りません';
  end if;
  if exists (select 1 from jsonb_array_elements(p_rows) r
              where coalesce(r ->> 'area', '') = '' or coalesce(r ->> 'form_key', '') not in ('al', 'shain') or coalesce((r ->> 'amount')::int, -1) < 0) then
    raise exception '行の内容が正しくありません';
  end if;
  delete from recruit_costs where month = p_month and note = 'auto:indeed-sheet';
  insert into recruit_costs (month, area, form_key, amount, note, updated_by, updated_at)
  select p_month, r ->> 'area', r ->> 'form_key', (r ->> 'amount')::int, 'auto:indeed-sheet', null, now()
    from jsonb_array_elements(p_rows) r
  on conflict (month, area, form_key) do update set amount = excluded.amount, note = excluded.note, updated_by = null, updated_at = now();
  get diagnostics v_n = row_count;
  select count(*) into v_manual from recruit_costs where month = p_month and note is distinct from 'auto:indeed-sheet';
  return jsonb_build_object('rows', v_n, 'manual', v_manual);
end $function$;
revoke all on function public.recruit_cost_replace(date, jsonb) from public, anon, authenticated;
grant execute on function public.recruit_cost_replace(date, jsonb) to service_role;

create or replace function public.recruit_cost_sync_trigger() returns void
language plpgsql security definer set search_path to 'public', 'net', 'extensions' as $function$
declare
  c_fn   constant text := 'https://uuvsxzhpxtghojoubjcc.supabase.co/functions/v1/recruit-cost-sync';
  c_anon constant text := 'sb_publishable_MrwPJAx_Ws_fdRutprKCiQ_dg3wCiTr';
  v_secret text;
begin
  select value into v_secret from app_secrets where key = 'notify_slack_secret';
  if v_secret is null or length(trim(v_secret)) = 0 then raise warning 'recruit_cost_sync_trigger: app_secrets.notify_slack_secret が未設定'; return; end if;
  perform net.http_post(url := c_fn,
    headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', c_anon, 'Authorization', 'Bearer ' || c_anon, 'x-notify-secret', trim(v_secret)),
    body := jsonb_build_object('trigger', 'pg_cron'), timeout_milliseconds := 120000);
end $function$;
revoke all on function public.recruit_cost_sync_trigger() from public, anon, authenticated;

select cron.schedule('recruit-cost-sync', '0 0 10-20 * *', 'select public.recruit_cost_sync_trigger()');
commit;
