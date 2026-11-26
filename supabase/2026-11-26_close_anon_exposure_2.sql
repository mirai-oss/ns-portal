-- 2026-11-26 追加: ar_matching（売掛の消込結果）を閉じる。ポータルはログイン済みで使うので影響なし。
alter table public.ar_matching enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='ar_matching') then
    create policy authenticated_full_access on public.ar_matching for all to authenticated using (true) with check (true);
  end if;
end $$;
revoke all on public.ar_matching from anon;

-- 確認: まだRLSが無効のテーブル（「No rows returned / 0 rows」なら全部閉じています）
select c.relname as table_name from pg_class c join pg_namespace s on s.oid=c.relnamespace
where s.nspname='public' and c.relkind in ('r','p') and not c.relrowsecurity order by 1;
