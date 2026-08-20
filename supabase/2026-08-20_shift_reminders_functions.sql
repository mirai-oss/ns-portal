-- ============================================================
-- シフト未提出者へのLINEリマインド（機能④の追加分）
-- ・従業員のLINE連携（応募者向けapply_line_code等とは完全に独立）
-- ・締切当日にまだ未提出の人をリストアップするRPC（送信はクライアント/Edge Functionが行う）
-- ・既存の line_intake（応募者向け）は一切変更しない。新規関数のみ追加。
-- 冪等。実行前に 2026-08-20_shift_reminders.sql（usersへのALTER）が適用済みであること。
-- ============================================================

-- ---- 従業員のLINE連携 ----

-- 自分用の6桁合言葉を発行（未発行なら新規作成、発行済みならそれを返す）
create or replace function public.user_issue_line_code() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_code text; v_oa text;
begin
  if auth.uid() is null then raise exception 'ログインが必要です'; end if;
  select line_code into v_code from users where id = auth.uid();
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
    update users set line_code = v_code, updated_at = now() where id = auth.uid();
  end if;
  select value into v_oa from app_secrets where key = 'line_oa_id';
  return jsonb_build_object('ok', true, 'code', v_code, 'oa', coalesce(v_oa, ''));
end $$;

-- 自分のLINE連携を解除
create or replace function public.user_unlink_line() returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'ログインが必要です'; end if;
  update users set line_user_id = null, line_linked_at = null, line_code = null, updated_at = now()
   where id = auth.uid();
end $$;

-- Webhookから呼ばれる: 従業員のLINE連携処理（応募者のline_intakeとは完全に独立した関数）
create or replace function public.line_intake_user(p_secret text, p_line_user_id text, p_text text default null)
 returns jsonb
 language plpgsql security definer set search_path = public as $$
declare v_uid uuid; v_uname text; v_code text;
begin
  if p_secret is distinct from '4259598a7ce747d54e2bf84326131129f21eb77f54dfdcdd' then
    raise exception '認証エラー';
  end if;
  if p_line_user_id is null or length(btrim(p_line_user_id)) = 0 then
    return jsonb_build_object('ok', false);
  end if;

  -- 既に従業員として連携済みなら何もしない（応募者側の処理に任せる）
  select id into v_uid from users where line_user_id = p_line_user_id and is_active limit 1;
  if v_uid is not null then
    return jsonb_build_object('ok', true, 'already', true);
  end if;

  v_code := (regexp_match(upper(coalesce(p_text,'')), '[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{6}'))[1];
  if v_code is null then
    return jsonb_build_object('ok', false);
  end if;

  select id, name into v_uid, v_uname from users
   where line_code = v_code and line_user_id is null and is_active limit 1;
  if v_uid is null then
    return jsonb_build_object('ok', false);
  end if;

  update users set line_user_id = p_line_user_id, line_linked_at = now(), updated_at = now()
   where id = v_uid;

  return jsonb_build_object('ok', true, 'linked', true, 'name', v_uname,
    'reply', v_uname || 'さん、LINE連携が完了しました。シフト提出の締切が近いときにこちらへお知らせします。');
end $$;

-- ---- 未提出リマインド ----

-- リマインド送信ログ（1日1人1回まで）
create table if not exists sf_reminder_log (
  id uuid primary key default gen_random_uuid(),
  work_date date not null,
  period_key text not null,
  user_id uuid not null references users(id) on delete cascade,
  sent_at timestamptz not null default now(),
  unique(work_date, period_key, user_id)
);
alter table sf_reminder_log enable row level security;
drop policy if exists sfrl_all on sf_reminder_log;
create policy sfrl_all on sf_reminder_log for all
  using (sf_can_manage(null) or exists(select 1 from users u where u.id=auth.uid() and (u.is_master or u.role in ('CEO','HQ','TEAM'))))
  with check (sf_can_manage(null) or exists(select 1 from users u where u.id=auth.uid() and (u.is_master or u.role in ('CEO','HQ','TEAM'))));

-- 今日が締切日の期間について、まだ未提出（下書きのまま）の人を一覧で返す（送信はしない・副作用なし）
create or replace function public.sf_reminder_targets() returns table(user_id uuid, name text, line_user_id text, period_key text, deadline date)
language plpgsql stable security definer set search_path = public as $$
declare
  v_today date := current_date;
  v_day int := extract(day from v_today)::int;
  v_period_key text; v_deadline date;
  v_allowed boolean;
begin
  select coalesce((select u.is_master or u.role in ('CEO','HQ','TEAM','TENCHO') from users u where u.id = auth.uid() and u.is_active), false)
    into v_allowed;
  if not v_allowed then raise exception '権限がありません'; end if;

  if v_day <= 5 then
    v_period_key := to_char(v_today,'YYYY-MM') || '-B';
    v_deadline := date_trunc('month', v_today)::date + 4;
  elsif v_day <= 20 then
    v_period_key := to_char(v_today + interval '1 month','YYYY-MM') || '-A';
    v_deadline := date_trunc('month', v_today)::date + 19;
  else
    v_period_key := to_char(v_today + interval '1 month','YYYY-MM') || '-B';
    v_deadline := (date_trunc('month', v_today) + interval '1 month')::date + 4;
  end if;

  if v_deadline <> v_today then
    return; -- 締切当日以外は何も返さない（V1はシンプルに1回だけ）
  end if;

  return query
    select u.id, u.name, u.line_user_id, v_period_key, v_deadline
    from users u
    where u.is_active
      and u.role in ('AL','SHAIN','TENCHO','TEAM','HQ','CEO')
      and exists(select 1 from user_stores us where us.user_id = u.id) -- シフト対象＝どこかの店舗に所属
      and not exists(
        select 1 from sf_shifts s
        where s.user_id = u.id and s.period_key = v_period_key and s.status <> 'draft'
      )
      and not exists(
        select 1 from sf_reminder_log l
        where l.work_date = v_today and l.period_key = v_period_key and l.user_id = u.id
      );
end $$;

-- 送信済みとして記録（実際の送信はクライアント/Edge Functionが行った後に呼ぶ）
create or replace function public.sf_mark_reminded(p_user_id uuid, p_period_key text) returns void
language plpgsql security definer set search_path = public as $$
declare v_allowed boolean;
begin
  select coalesce((select u.is_master or u.role in ('CEO','HQ','TEAM','TENCHO') from users u where u.id = auth.uid() and u.is_active), false)
    into v_allowed;
  if not v_allowed then raise exception '権限がありません'; end if;

  insert into sf_reminder_log(work_date, period_key, user_id)
  values (current_date, p_period_key, p_user_id)
  on conflict do nothing;
end $$;
