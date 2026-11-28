-- 2026-11-29 ユビレジの「レジ側の日ごとの売上」と、受け取った期間を保存する（現金の月次照合のレジ側。担当D・社長依頼）
--   書くのは EF ubiregi-sales-import（service_role）だけ。読むのは Mac mini の照合タスク（service_role）。画面・利用者からは読めない。
--   戻し方: 2026-11-29_ubiregi_register_rollback.sql
begin;
create table if not exists public.ubiregi_register_daily (
  store_name text not null, biz_date date not null, vals numeric[] not null check (array_length(vals, 1) = 16),
  uploaded_at timestamptz not null default now(), primary key (store_name, biz_date));
create table if not exists public.ubiregi_register_coverage (
  store_name text not null, ym text not null check (ym ~ '^\d{4}-(0[1-9]|1[0-2])$'), covered_from date not null, covered_to date not null,
  uploaded_at timestamptz not null default now(), primary key (store_name, ym), check (covered_from <= covered_to));
alter table public.ubiregi_register_daily enable row level security;
alter table public.ubiregi_register_coverage enable row level security;
revoke all on public.ubiregi_register_daily, public.ubiregi_register_coverage from public, anon, authenticated;
grant select, insert, update, delete on public.ubiregi_register_daily, public.ubiregi_register_coverage to service_role;

-- 受け取った期間（p_from〜p_to）の分を入れ替え、月ごとの受け取り済みの期間を記録する。前の期間とつながる・重なるときは広げ、離れているときは新しい方だけにする。
create or replace function public.ubiregi_register_save(p_store text, p_from date, p_to date, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public as $function$
declare m date; v_from date; v_to date; c ubiregi_register_coverage%rowtype; v_n int;
begin
  if p_store is null or p_from is null or p_to is null or p_from > p_to or p_to - p_from > 62 then raise exception '期間が正しくありません'; end if;
  if exists (select 1 from jsonb_array_elements(p_rows) r where r ->> 'store' = p_store and ((r ->> 'date')::date < p_from or (r ->> 'date')::date > p_to)) then
    raise exception '期間の外の日が含まれています'; end if;
  delete from ubiregi_register_daily where store_name = p_store and biz_date between p_from and p_to;
  insert into ubiregi_register_daily (store_name, biz_date, vals)
  select p_store, (r ->> 'date')::date, array(select x::numeric from jsonb_array_elements_text(r -> 'values') with ordinality t(x, n) order by n)
    from jsonb_array_elements(p_rows) r where r ->> 'store' = p_store;
  get diagnostics v_n = row_count;
  for m in select generate_series(date_trunc('month', p_from), date_trunc('month', p_to), interval '1 month')::date loop
    v_from := greatest(p_from, m); v_to := least(p_to, (m + interval '1 month' - interval '1 day')::date);
    select * into c from ubiregi_register_coverage where store_name = p_store and ym = to_char(m, 'YYYY-MM');
    if found and v_from <= c.covered_to + 1 and v_to >= c.covered_from - 1 then
      v_from := least(v_from, c.covered_from); v_to := greatest(v_to, c.covered_to);
    end if;
    insert into ubiregi_register_coverage (store_name, ym, covered_from, covered_to) values (p_store, to_char(m, 'YYYY-MM'), v_from, v_to)
    on conflict (store_name, ym) do update set covered_from = excluded.covered_from, covered_to = excluded.covered_to, uploaded_at = now();
  end loop;
  return jsonb_build_object('rows', v_n);
end $function$;
revoke all on function public.ubiregi_register_save(text, date, date, jsonb) from public, anon, authenticated;
grant execute on function public.ubiregi_register_save(text, date, date, jsonb) to service_role;
commit;
