-- 2026-11-28_recruit_line_autoform.sql の戻し
begin;

CREATE OR REPLACE FUNCTION public.line_intake(p_secret text, p_line_user_id text, p_text text DEFAULT NULL::text, p_event_id text DEFAULT NULL::text, p_sent_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

delete from app_settings where key = 'recruit_line_autoform';
commit;
