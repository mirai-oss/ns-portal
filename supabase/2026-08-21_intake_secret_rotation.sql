-- =====================================================================
-- 内部連携シークレットのローテーション — データ基盤Day2 タスク4（前半）
-- =====================================================================
-- 背景: 同じ合言葉'4259598a7ce747d54e2bf84326131129f21eb77f54dfdcdd'が、
--   公開リポ(ns-portal)の2つのSQLファイルとline-webhook/index.tsに平文で
--   ハードコードされていた（データ基盤監査レポート2026-08-21 リスクR6）。
--   調査の結果、DB上には同じ合言葉を使う関数がさらに5つ存在し（line_intake／
--   line_log_out／mark_interview_reminded／recruit_daily_targets／
--   recruit_mark_reminded＝いずれも採用LINE連携）、しかもこの5つは**リポジトリの
--   どのSQLファイルにも保存されていなかった**（SQL Editorで直接作成されたと見られる）。
--   本ファイルでこの5つも合わせてバックアップ・修正する（pg_get_functiondef()で
--   本番の定義を直接取得し、合言葉チェック部分だけ差し替えた）。
--
-- 方針: 既存のマイグレーションSQLファイル(2026-08-12_checklist_deadline_alert.sql /
--   2026-08-20_shift_reminders_functions.sql)は編集しない。新しい本ファイルで
--   CREATE OR REPLACE により関数の中身だけ差し替える（ファイル自体は日付入りで追加）。
--
-- 移行方式: 新しい合言葉をapp_secretsに保存し、関数は「新しい値 または
--   旧い値」のどちらでも通す形にする（新旧両対応の移行期間）。
--   ・呼び出し元のうち line-webhook（LINE→従業員連携）は本コミットで新しい値に切替済み
--   ・「5分おきにGASから呼ばれる」とコメントにあるchecklist_overdue_checkの
--     呼び出し元GASは特定できていないため、旧い値も一定期間は許可し続ける
--     （呼び出し元が見つかり次第、新しい値に更新した上で旧い値をapp_secretsから削除する）
-- 実行場所: Supabase SQL Editor / Management API（何度実行しても壊れません）
-- =====================================================================

-- 新しい合言葉を保存（値はapp_secretsのみに置き、コード上には書かない）
insert into app_secrets (key, value, updated_at)
values ('checklist_intake_secret', '__NEW_SECRET__', now())
on conflict (key) do update set value = excluded.value, updated_at = now();

-- 旧い合言葉も一時的に保存（移行期間用。呼び出し元が判明し更新され次第、削除する）
insert into app_secrets (key, value, updated_at)
values ('checklist_intake_secret_prev', '__OLD_SECRET__', now())
on conflict (key) do update set value = excluded.value, updated_at = now();

-- 共通チェック関数: 新しい値・旧い値のどちらでも通す
create or replace function checklist_intake_secret_ok(p_secret text) returns boolean
language plpgsql security definer set search_path = public as $$
declare v_cur text; v_prev text;
begin
  select value into v_cur  from app_secrets where key = 'checklist_intake_secret';
  select value into v_prev from app_secrets where key = 'checklist_intake_secret_prev';
  return p_secret is not null and (p_secret = v_cur or (v_prev is not null and p_secret = v_prev));
end $$;

-- ---------------------------------------------------------------------
-- checklist_overdue_check: ハードコード判定 → 上記の共通関数を使うよう差し替え
-- （本体ロジックは2026-08-12_checklist_deadline_alert.sqlと完全に同じ）
-- ---------------------------------------------------------------------
create or replace function checklist_overdue_check(p_secret text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_alerted int := 0; r record; v_body text;
begin
  if not checklist_intake_secret_ok(p_secret) then
    raise exception '認証エラー';
  end if;

  for r in
    select i.id as item_id, i.label, i.due_time, s.id as store_id, s.name as store_name
      from checklist_items i
      join checklist_templates t on t.id = i.template_id and t.is_active
      join stores s on s.is_active and (t.store_id is null or t.store_id = s.id)
     where i.is_active
       and i.due_time is not null
       and (now() at time zone 'Asia/Tokyo')::time > i.due_time
       and not exists (
         select 1 from checklist_checks c
          where c.item_id = i.id and c.store_id = s.id and c.work_date = biz_date()
       )
       and not exists (
         select 1 from checklist_overdue_alerts a
          where a.item_id = i.id and a.store_id = s.id and a.work_date = biz_date()
       )
  loop
    insert into checklist_overdue_alerts (item_id, store_id, work_date)
    values (r.item_id, r.store_id, biz_date())
    on conflict (item_id, store_id, work_date) do nothing;

    v_body := '⏰ 期限切れ未完了: ' || r.store_name || '「' || r.label || '」（期限 '
      || to_char(r.due_time, 'HH24:MI') || '）がまだチェックされていません';

    insert into notifications (recipient_id, type, body_i18n, link)
    select distinct u.id, 'checklist_overdue',
           jsonb_build_object('ja', v_body),
           jsonb_build_object('item_id', r.item_id, 'store_id', r.store_id, 'work_date', biz_date()::text)
      from users u
     where u.is_active
       and (
         u.role in ('CEO','HQ')
         or (u.role = 'TEAM' and exists(select 1 from team_stores ts where ts.team_id = u.team_id and ts.store_id = r.store_id))
         or (u.role = 'TENCHO' and exists(select 1 from user_stores us where us.user_id = u.id and us.store_id = r.store_id))
       );
    v_alerted := v_alerted + 1;
  end loop;

  return jsonb_build_object('ok', true, 'alerted', v_alerted);
end $$;

-- ---------------------------------------------------------------------
-- line_intake_user: 同様に差し替え（本体ロジックは2026-08-20_shift_reminders_functions.sqlと完全に同じ）
-- ---------------------------------------------------------------------
create or replace function public.line_intake_user(p_secret text, p_line_user_id text, p_text text default null)
 returns jsonb
 language plpgsql security definer set search_path = public as $$
declare v_uid uuid; v_uname text; v_code text;
begin
  if not checklist_intake_secret_ok(p_secret) then
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

-- ---------------------------------------------------------------------
-- 以下5つは、リポジトリのどのSQLファイルにも存在しなかった関数（本番DBに
-- 直接作成されていた）。pg_get_functiondef()で取得した本番の定義そのままに、
-- 合言葉チェックだけ共通関数へ差し替えている。これで初めてgit管理下に入る。
-- ---------------------------------------------------------------------

create or replace function public.line_intake(p_secret text, p_line_user_id text, p_text text default null, p_event_id text default null, p_sent_at timestamptz default now())
 returns jsonb
 language plpgsql security definer set search_path to 'public' as $function$
declare v_aid uuid; v_name text; v_code text; v_linked boolean := false; v_store uuid;
begin
  if not checklist_intake_secret_ok(p_secret) then
    raise exception '認証エラー';
  end if;
  if p_line_user_id is null or length(btrim(p_line_user_id)) = 0 then
    return jsonb_build_object('ok', false);
  end if;

  select id, name, store_id into v_aid, v_name, v_store from applicants
   where line_user_id = p_line_user_id order by applied_at desc limit 1;

  if v_aid is null then
    v_code := (regexp_match(upper(coalesce(p_text,'')),
                            '[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{6}'))[1];
    if v_code is not null then
      select id, name, store_id into v_aid, v_name, v_store from applicants
       where line_code = v_code and line_user_id is null limit 1;
      if v_aid is not null then
        update applicants set line_user_id = p_line_user_id, line_linked_at = now(),
                              updated_at = now()
         where id = v_aid;
        v_linked := true;
        insert into notifications (recipient_id, type, body_i18n, link)
        select u.id, 'applicant_new',
               jsonb_build_object('ja', 'LINEが連携されました: ' || v_name || 'さん'),
               jsonb_build_object('applicant_id', v_aid)
          from users u where u.is_active and can_see_applicant(u.id, v_store);
      end if;
    end if;
  end if;

  if v_aid is null then
    return jsonb_build_object('ok', false,
      'reply', '恐れ入ります。担当者からお送りした6桁の合言葉（英数字）をそのまま送信してください。');
  end if;

  if not v_linked and length(btrim(coalesce(p_text,''))) > 0 then
    insert into applicant_messages (applicant_id, channel, direction, body, sent_at, source_ref, sender_key)
    values (v_aid, 'line', 'in', left(btrim(p_text), 8000), coalesce(p_sent_at, now()),
            'line:' || coalesce(p_event_id, gen_random_uuid()::text), 'line:' || p_line_user_id)
    on conflict (source_ref) do nothing;
    update applicants set msg_received_at = coalesce(p_sent_at, now()), msg_seen_at = null,
                          updated_at = now()
     where id = v_aid;
    insert into notifications (recipient_id, type, body_i18n, link)
    select u.id, 'applicant_message',
           jsonb_build_object('ja', 'LINEにメッセージが届きました: ' || v_name || 'さん'),
           jsonb_build_object('applicant_id', v_aid)
      from users u where u.is_active and can_see_applicant(u.id, v_store);
  end if;

  return jsonb_build_object('ok', true, 'linked', v_linked, 'name', v_name,
    'reply', case when v_linked
      then v_name || 'さん、連携が完了しました。こちらからご連絡いたしますので、そのままお待ちください。'
      else null end);
end $function$;

create or replace function public.line_log_out(p_secret text, p_applicant uuid, p_text text)
 returns uuid
 language plpgsql security definer set search_path to 'public' as $function$
declare v_id uuid := gen_random_uuid();
begin
  if not checklist_intake_secret_ok(p_secret) then
    raise exception '認証エラー';
  end if;
  insert into applicant_messages (id, applicant_id, channel, direction, body, sent_at, direction_fixed)
  values (v_id, p_applicant, 'line', 'out', left(btrim(p_text), 8000), now(), true);
  update applicants set updated_at = now() where id = p_applicant;
  return v_id;
end $function$;

create or replace function public.mark_interview_reminded(p_secret text, p_applicant uuid)
 returns void
 language plpgsql security definer set search_path to 'public' as $function$
begin
  if not checklist_intake_secret_ok(p_secret) then
    raise exception '認証エラー';
  end if;
  update applicants set interview_reminded_at = now() where id = p_applicant;
end $function$;

create or replace function public.recruit_mark_reminded(p_secret text, p_applicant uuid)
 returns void
 language plpgsql security definer set search_path to 'public' as $function$
begin
  if not checklist_intake_secret_ok(p_secret) then
    raise exception '認証エラー';
  end if;
  update applicants
     set invite_reminded_at  = now(),
         invite_remind_count = coalesce(invite_remind_count, 0) + 1,
         updated_at = now()
   where id = p_applicant;
end $function$;

create or replace function public.recruit_daily_targets(p_secret text)
 returns jsonb
 language plpgsql security definer set search_path to 'public' as $function$
declare v_total int := 0; v_n int; v_names text; v_rem jsonb; v_iv jsonb; r record;
begin
  if not checklist_intake_secret_ok(p_secret) then
    raise exception '認証エラー';
  end if;

  if not exists(select 1 from notifications
                 where type = 'applicant_new'
                   and body_i18n->>'ja' like '⚠️ 面接日を過ぎて%'
                   and created_at > now() - interval '20 hours') then
    for r in select u.id from users u where u.is_active and has_feature(u.id, 'recruit') loop
      select count(*), string_agg(a.name, '、' order by a.interview_at)
        into v_n, v_names
        from applicants a
       where a.interview_at is not null
         and a.interview_at < now() - interval '12 hours'
         and a.status in ('new','contacted','interview_set')
         and can_see_applicant(r.id, a.store_id);
      if v_n > 0 then
        insert into notifications (recipient_id, type, body_i18n, link)
        values (r.id, 'applicant_new',
                jsonb_build_object('ja', '⚠️ 面接日を過ぎて選考中のままの方が ' || v_n
                  || '名います（' || left(coalesce(v_names,''), 120) || '）ステータスの更新をお願いします'),
                jsonb_build_object('alert', 'interview_overdue'));
        v_total := greatest(v_total, v_n);
      end if;
    end loop;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', id, 'name', name, 'token', invite_token, 'kind', 'invite')), '[]'::jsonb)
    into v_rem
    from applicants
   where status = 'hired'
     and user_id is null
     and invite_token is not null
     and line_user_id is not null
     and invite_sent_at is not null
     and invite_sent_at < now() - interval '20 hours'
     and coalesce(invite_remind_count, 0) < 3
     and invite_remind_dismissed_at is null
     and (invite_reminded_at is null
          or invite_reminded_at < now() - interval '3 days');

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', a.id, 'name', a.name, 'kind', 'interview',
           'text', a.name || 'さん' || E'\n\n'
             || 'お世話になっております。明日の面接のご案内です。' || E'\n\n'
             || '【面接日時】'
             || to_char(a.interview_at at time zone 'Asia/Tokyo', 'MM月DD日 HH24:MI')
             || case when a.interview_url is not null and btrim(a.interview_url) <> ''
                     then E'\n【面接URL】' || a.interview_url
                       || E'\n\nお時間になりましたら、上のリンクからご参加ください。'
                     else '' end
             || E'\n\nご都合が悪くなった場合は、このままご返信ください。'
             || E'\nお会いできるのを楽しみにしております。')), '[]'::jsonb)
    into v_iv
    from applicants a
   where a.interview_at is not null
     and a.line_user_id is not null
     and a.interview_reminded_at is null
     and a.status in ('interview_set','contacted')
     and (a.interview_at at time zone 'Asia/Tokyo')::date
         = ((now() at time zone 'Asia/Tokyo')::date + 1);

  return jsonb_build_object('ok', true, 'alerts', v_total,
                            'reminders', (v_rem || v_iv));
end $function$;
