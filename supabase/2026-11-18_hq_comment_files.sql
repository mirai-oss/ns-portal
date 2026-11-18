-- 本部タスクのコメントに、写真・PDF を添付できるようにする（2026-11-18）。新しい表を 1 つ足すだけ（既存の表・関数には触れない）。
-- 見える人＝そのタスクが見える人（コメントと同じ）。消せる人＝添付した本人。ファイルの置き場は、いまの写真と同じ（保存先の仕組みは変えない）。
-- 戻し方: drop table if exists public.hq_task_comment_files;
create table if not exists public.hq_task_comment_files (
  id uuid primary key default gen_random_uuid(),
  comment_id uuid not null references public.hq_task_comments(id) on delete cascade,
  task_id uuid not null references public.hq_tasks(id) on delete cascade,
  storage_path text not null,
  file_name text,
  created_by uuid references public.users(id),
  created_at timestamptz not null default now()
);
create index if not exists hq_task_comment_files_task_idx on public.hq_task_comment_files (task_id, created_at);
create index if not exists hq_task_comment_files_comment_idx on public.hq_task_comment_files (comment_id);
alter table public.hq_task_comment_files enable row level security;
drop policy if exists hqcomfile_read on public.hq_task_comment_files;
create policy hqcomfile_read on public.hq_task_comment_files for select using (hq_task_visible(task_id));
drop policy if exists hqcomfile_insert on public.hq_task_comment_files;
create policy hqcomfile_insert on public.hq_task_comment_files for insert with check (hq_task_visible(task_id) and created_by = auth.uid());
drop policy if exists hqcomfile_delete on public.hq_task_comment_files;
create policy hqcomfile_delete on public.hq_task_comment_files for delete using (created_by = auth.uid());
grant select, insert, delete on public.hq_task_comment_files to authenticated;
