-- =====================================================================
-- 現場チェックシート: 実施履歴（誰が・いつ、チェック／取消したか）
-- 画面=日報システム（nippo・現場アプリ）／データ=ハブ
--
-- 【背景】
--  checklist_checks は「項目×店舗×日付」で1行だけ持つ設計（unique制約）。
--  チェックを外す（取消）と行ごと削除されるため、「誰が最初にチェックしたか」
--  「誰がいつ取り消したか」の記録が残らなかった。
--  → checklist_checks はこれまで通り「今の状態」を持ち、
--    新設の checklist_check_log に「何が起きたか」を全部残す（追記のみ・削除しない）。
--
-- 実行場所: Supabase SQL Editor（何度実行しても壊れません）
-- =====================================================================

create table if not exists checklist_check_log (
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null references checklist_items(id) on delete cascade,
  store_id uuid not null references stores(id) on delete cascade,
  work_date date not null,
  action text not null check (action in ('checked','unchecked')),
  actor_id uuid references users(id) on delete set null,
  acted_at timestamptz not null default now(),
  photo_url text
);
create index if not exists checklist_check_log_idx on checklist_check_log (item_id, store_id, work_date);

alter table checklist_check_log enable row level security;
drop policy if exists cklog_read on checklist_check_log;
create policy cklog_read on checklist_check_log for select using (auth.uid() is not null);
-- 書き込みはトリガーだけが行う（security definer）。直接のinsert/update/deleteはユーザーに許可しない
drop policy if exists cklog_no_direct_write on checklist_check_log;

-- checklist_checks の増減をそのまま履歴に写す
create or replace function trg_checklist_check_log() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into checklist_check_log (item_id, store_id, work_date, action, actor_id, acted_at, photo_url)
    values (new.item_id, new.store_id, new.work_date, 'checked', new.checked_by, new.checked_at, new.photo_url);
    return new;
  elsif tg_op = 'DELETE' then
    insert into checklist_check_log (item_id, store_id, work_date, action, actor_id, acted_at, photo_url)
    values (old.item_id, old.store_id, old.work_date, 'unchecked', auth.uid(), now(), null);
    return old;
  end if;
  return null;
end $$;

drop trigger if exists checklist_checks_log on checklist_checks;
create trigger checklist_checks_log after insert or delete on checklist_checks
  for each row execute function trg_checklist_check_log();

select 'checklist_check_log 適用完了（チェック・取消の履歴を残すようになりました）' as result;
