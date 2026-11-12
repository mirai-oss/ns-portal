-- 2026-11-16_recruit_notice.sql を外す  ★実行は別途承認
--   ふだん「止める」ときは、これではなく  select recruit_slack_set(false);  （スイッチを切るだけ。何も消えない。入れ直しても、同じ応募者の親は増えない）
--   これは、足したトリガー・関数・定期実行・設定を取り除く。既存の表の列・既存の関数・既存のトリガー（trg_lark_notify など）には触れない。Chatwork への通知はそのまま。
--   応募者と Slack の親の対応（控え）が 1 件でもあるときは、控え・通知の種類・メンション先の設定は消さずに残す（消すと、入れ直したときに同じ応募者の親がもう 1 件できるため）。
--   Edge Function recruit-notify は、これでは消えない（呼ばれなくなるだけ）。消すときは別途。

-- 1) 見回りの定期実行を止める
do $$
begin
  if exists (select 1 from cron.job where jobname = 'recruit-notice-sweep') then perform cron.unschedule('recruit-notice-sweep'); end if;
end $$;

-- 2) 足したトリガーを外す（表は変えない）
drop trigger if exists recruit_notice_ins on applicants;
drop trigger if exists recruit_notice_upd on applicants;
drop trigger if exists recruit_notice_del on applicants;
drop trigger if exists recruit_notice_msg_ins on applicant_messages;
drop trigger if exists recruit_notice_msg_move on applicant_messages;
drop trigger if exists recruit_notice_merged on applicant_merges;
do $$
begin
  if to_regclass('public.onboarding_workflows') is not null then
    drop trigger if exists recruit_notice_onb_ins on onboarding_workflows;
    drop trigger if exists recruit_notice_onb_upd on onboarding_workflows;
  end if;
end $$;

-- 3) 足した関数を消す
drop function if exists trg_recruit_notice_applicant();
drop function if exists trg_recruit_notice_message();
drop function if exists trg_recruit_notice_merges();
drop function if exists trg_recruit_notice_onboarding();
drop function if exists recruit_notice_sweep();
drop function if exists recruit_notice_merge(uuid, uuid);
drop function if exists recruit_notice_unlock(uuid, text);
drop function if exists recruit_notice_lock(uuid, text, integer);
drop function if exists recruit_notice_claim(uuid, integer);
drop function if exists recruit_notice_fire(uuid, text, text);
drop function if exists recruit_notice_on();
drop function if exists recruit_slack_set(boolean);

-- 4) 設定・控え・種類・宛先
delete from app_settings where key = 'recruit_slack';
do $$
declare n integer;
begin
  select count(*) into n from notice_cases where type_key = 'recruit' and slack_refs ? 'ts';
  if n > 0 then
    raise notice '採用管理の控え（応募者と Slack の親の対応）が % 件あります。控え・通知の種類 recruit・メンション先の設定は残します', n;
    delete from notice_cases where type_key = 'recruit' and not (slack_refs ? 'ts');   -- 親の無い控え（権利の印だけ）は消す
  else
    delete from notice_cases where type_key = 'recruit';
    delete from notice_mention_rules where type_key = 'recruit';
    delete from notice_types where type_key = 'recruit';
  end if;
  -- 宛先: 一度も送っていなければ消す。送った記録（台帳）があれば、無効にするだけ
  if exists (select 1 from notification_deliveries where channel_key = 'hr.saiyo') then
    update slack_channels set is_active = false, updated_at = now() where channel_key = 'hr.saiyo';
  else
    delete from slack_channels where channel_key = 'hr.saiyo';
  end if;
end $$;

-- 確認用（読むだけ）: どれも 0 行になる
-- select tgname from pg_trigger where tgname like 'recruit_notice_%';
-- select proname from pg_proc where proname like 'recruit_notice_%' or proname like 'trg_recruit_notice_%' or proname = 'recruit_slack_set';
-- select jobname from cron.job where jobname = 'recruit-notice-sweep';
