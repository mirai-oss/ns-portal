-- =============================================================
-- 2026-11-08 Slack に紐づいた人は LINE 連携を外す（ユーザー指示「Slack の連携された方から LINE の連携を外して大丈夫。LINE 関係の表示も非表示に」）
--   方針: 入社前は LINE、入社後は Slack。Slack 紐づけ（user_slack に行が入る）と同時に users.line_user_id を外す。
--   元の LINE ID は user_slack.line_user_id_before に控える（戻すときは users.line_user_id に戻すだけ）。
--   ⚠️ LINE だけに送っている通知（給与照合・賃金申請・退職申請の本部向け、シフト締切・未提出リマインド、入社案内）は、
--      Slack 紐づけ済みの人には届かなくなる。Slack へ移すのは別途。
-- =============================================================
alter table public.user_slack add column if not exists line_user_id_before text;
alter table public.user_slack add column if not exists line_unlinked_at timestamptz;

create or replace function public.user_slack_unlink_line()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_line text;
begin
  select line_user_id into v_line from users where id = new.user_id;
  if v_line is not null then
    new.line_user_id_before := v_line;
    new.line_unlinked_at := now();
    update users set line_user_id = null, line_linked_at = null where id = new.user_id;
  end if;
  return new;
end $$;
drop trigger if exists user_slack_unlink_line_trg on public.user_slack;
create trigger user_slack_unlink_line_trg before insert on public.user_slack for each row execute function public.user_slack_unlink_line();

-- すでに紐づいている人（11/8 時点 5 名）も同じ扱いにする
update public.user_slack s
   set line_user_id_before = u.line_user_id, line_unlinked_at = now()
  from public.users u
 where u.id = s.user_id and u.line_user_id is not null and s.line_user_id_before is null;
update public.users u
   set line_user_id = null, line_linked_at = null
  from public.user_slack s
 where s.user_id = u.id and u.line_user_id is not null;
