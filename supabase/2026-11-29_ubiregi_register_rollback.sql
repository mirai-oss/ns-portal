begin;
drop function if exists public.ubiregi_register_save(text, date, date, jsonb);
drop table if exists public.ubiregi_register_coverage;
drop table if exists public.ubiregi_register_daily;
commit;
