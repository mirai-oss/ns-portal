-- シフト未提出者へのLINEリマインド（機能④の追加）
-- 従業員のLINE連携用に、応募者(applicants)とは別の列をusersに追加する

alter table public.users add column if not exists line_code text;
alter table public.users add column if not exists line_linked_at timestamptz;
create unique index if not exists users_line_code_uidx on public.users(line_code) where line_code is not null;
