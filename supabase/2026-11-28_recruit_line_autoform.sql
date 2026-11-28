-- 2026-11-28 採用: LINE連携が完了したら、応募フォーム（本人専用のリンク）の案内を自動で返す（担当D・社長依頼）
--   line_intake の返事を差し替えるだけ（line-webhook は変更・再デプロイなし）。止める: app_settings.recruit_line_autoform の enabled=false
--   戻し方: 2026-11-28_recruit_line_autoform_rollback.sql
begin;

CREATE OR REPLACE FUNCTION public.line_intake(p_secret text, p_line_user_id text, p_text text DEFAULT NULL::text, p_event_id text DEFAULT NULL::text, p_sent_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_aid uuid; v_name text; v_code text; v_linked boolean := false; v_store uuid;
  v_a applicants%rowtype; v_cfg jsonb; v_auto text;
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

  -- 2026-11-28 連携が成立した人で、応募フォームが未回答なら、本人専用のフォームのリンク入りの案内を返事にする（社長依頼）。
  --   文面とオン/オフは app_settings.recruit_line_autoform。失敗しても、連携と通常の返事は止めない。
  if v_linked then
    begin
      select value into v_cfg from app_settings where key = 'recruit_line_autoform';
      select * into v_a from applicants where id = v_aid;
      if coalesce((v_cfg ->> 'enabled')::boolean, false) and position('{url}' in coalesce(v_cfg ->> 'text', '')) > 0
         and v_a.form_received_at is null and v_a.user_id is null and v_a.hired_at is null and v_a.exited_at is null
         and v_a.status in ('new', 'contacted', 'interview_set') and v_a.form_key in ('al', 'shain') then
        v_auto := replace(replace(v_cfg ->> 'text', '{name}', coalesce(v_name, '')), '{url}',
                          'https://mirai-oss.github.io/nippo/?apply=' || v_a.form_key || '&p=' || applicant_form_token(v_aid));
        insert into applicant_messages (applicant_id, channel, direction, body, sent_at, source_ref, sender_key)
        values (v_aid, 'line', 'out', v_auto, now(), 'autoform:' || v_aid::text, 'system:autoform')
        on conflict (source_ref) do nothing;
        -- 返事をしていない応募者からのメッセージがあるときは、自動の案内で「対応済み」に見えないように戻す
        if v_a.last_msg_dir = 'in' then
          update applicants set last_msg_dir = v_a.last_msg_dir, last_msg_at = v_a.last_msg_at where id = v_aid;
        end if;
      end if;
    exception when others then
      raise warning 'line_intake の応募フォーム案内: %', sqlerrm;
      v_auto := null;
    end;
  end if;

  return jsonb_build_object('ok', true, 'linked', v_linked, 'name', v_name,
    'reply', case when v_linked and v_auto is not null then v_auto
      when v_linked
      then v_name || 'さん、連携が完了しました。こちらからご連絡いたしますので、そのままお待ちください。'
      else null end);
end $function$;

insert into app_settings (key, value) values ('recruit_line_autoform', jsonb_build_object('enabled', true,
  'note', 'LINE連携の直後に応募フォームの案内を自動で返す（line_intake）。{name}=氏名・{url}=本人専用のフォームのリンク。enabled=false で今までの返事に戻る',
  'text', $txt${name}さん、LINEの連携が完了しました。ご応募ありがとうございます。

面接の前に、下の応募フォームへのご回答をお願いいたします。
{url}

ご回答を確認しましたら、担当者よりご連絡いたします。$txt$))
on conflict (key) do nothing;
commit;
