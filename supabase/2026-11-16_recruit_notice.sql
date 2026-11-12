-- 採用管理の Slack 通知（2026-11-16 下書き）: 応募者 1 人につき親メッセージ 1 件＋スレッド
--   設計: scratchpad rc1/設計_採用管理のSlack通知.md（決定: 2026-11-12 ユーザー）
--   ★ 本番未適用（下書き。適用は別途承認）。戻し方: 2026-11-16_recruit_notice_rollback.sql
--   前提: 2026-11-12_notice_base.sql（notice_types・notice_cases・notice_mention_rules・notice_case_upsert）が入っていること
--
--   これを適用しただけでは、何も送られない（スイッチ app_settings.recruit_slack.enabled の既定は false。false のあいだ、下のトリガーは何もせずに戻る）。
--   足すもの: 宛先 1 行（hr.saiyo）・通知の種類 1 行（recruit）・メンション先の設定 3 行・設定の項目 1 つ・関数 12 本・トリガー 8 本・見回りの定期実行 1 つ。
--   変えないもの: 既存の表の列・既存の関数（apply_submit / indeed_intake / line_intake / merge_applicants / hire_applicant など）・既存のトリガー（trg_lark_notify）・
--                 表 notifications と lark_routes（＝いまの Chatwork への通知は、そのまま出続ける）。
--
--   出来事の拾い方: 表 notifications は見ない（受信者ごとに行が増える・状態の変更や面接の確定が入らない・本文に電話番号が入ることがあるため）。
--     applicants と applicant_messages に AFTER トリガーを足し、「この応募者に何かあった」とだけ Edge Function recruit-notify に知らせる（pg_net。氏名・本文は送らない）。
--     何を Slack に書くかは、Edge Function が「いまの状態」と控え（notice_cases）の差で決める。だから、同じ知らせが二度届いても、二度は書かない。

-- ============ 0. 前提の確認（足りなければ、何も変えずに止まる） ============
do $$
declare v_missing text;
begin
  if to_regclass('public.notice_cases') is null or to_regclass('public.notice_types') is null then
    raise exception '先に 2026-11-12_notice_base.sql を適用してください（notice_cases / notice_types がありません）';
  end if;
  select string_agg(c, ', ') into v_missing
    from unnest(array['name','source','job_type','status','store_id','assignee_id','user_id','applied_at','updated_at','interview_at','interview_mode','interview_place','interview_prefs',
                      'handled_at','hired_at','exit_stage','exit_reason','last_msg_dir','form_received_at','line_linked_at','answers']) c
   where not exists (select 1 from information_schema.columns k where k.table_schema = 'public' and k.table_name = 'applicants' and k.column_name = c);
  if v_missing is not null then raise exception 'applicants に、トリガーが見る列がありません: %', v_missing; end if;
end $$;

-- ============ 1. 宛先・通知の種類・メンション先・設定 ============
-- 採用管理チャンネル（ユーザー指定 2026-11-12）。Bot が参加するまでは送れない（送信は失敗として台帳に残るだけ）。送るかどうかは、下のスイッチで決める
insert into slack_channels (channel_key, slack_channel_id, display_name, purpose, replaces)
values ('hr.saiyo', 'C0CGY7PCFM4', '採用管理',
        '採用管理（応募者 1 人につき親メッセージ 1 件。応募受付・面接・結果・やり取りは、その親のスレッド）。送信は app_settings.recruit_slack.enabled が true のときだけ',
        'Chatwork「求人応募通知」「求人メッセージ通知」（lark_routes の applicant_new / applicant_message。Slack が正常に動くのを確認してから止める）')
on conflict (channel_key) do nothing;

insert into notice_types(type_key, label, emoji, channel_key, final_channel_key, date_rule, thread_fields, format_version, sort_order)
values ('recruit', '採用管理', '👤', 'hr.saiyo', null, 'event', '{store,source,job,applied_at,status,interview,assignee,history}', 2, 100)   -- 電話・メール・回答の中身は入れない
on conflict (type_key) do nothing;

-- メンション先（承認権限とは別）。担当者がいれば担当者／いなければ応募店舗の担当。相手が Slack と紐付いていなくても、ほかの人には広げない（共通の方針）
insert into notice_mention_rules(type_key, scene, targets, note) values
  ('recruit', 'assignee', '[{"kind":"task_assignee"}]', '応募者の担当者（applicants.assignee_id）がいるとき: その担当者'),
  ('recruit', 'open',     '[{"kind":"store_role","roles":["TENCHO"]},{"kind":"store_team_leader"}]', '担当者がいないとき: 応募店舗の店長＋その店舗の担当チーム長'),
  ('recruit', 'no_store', '[]', '担当者も応募店舗も決まっていないとき: 未決（決まるまで、だれにもメンションしない）')
on conflict (type_key, scene) do nothing;

-- スイッチ。enabled=false のあいだは何も起きない。since＝切り替えた時刻（これより前の応募者は、動きがあったときだけスレッドを作る＝過去分を流し込まない）
insert into app_settings(key, value)
select 'recruit_slack', jsonb_build_object('enabled', false, 'since', null, 'channel_key', 'hr.saiyo', 'body_chars', 200,
       'note', '採用管理の Slack 通知。切り替えは recruit_slack_set(true)（マスターのみ）。body_chars＝応募者のメッセージ本文を出す長さ（0 で本文を出さない）')
where not exists (select 1 from app_settings where key = 'recruit_slack');

-- スイッチの切り替え（マスターのみ）。初めて入れるときに、切り替えの時刻を控える
create or replace function recruit_slack_set(p_enabled boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  if not (onboarding_is_service() or coalesce((select is_master from users where id = auth.uid() and is_active), false)) then raise exception '権限がありません（マスターのみ）'; end if;
  select value into v from app_settings where key = 'recruit_slack';
  if v is null then raise exception '設定 recruit_slack がありません'; end if;
  v := v || jsonb_build_object('enabled', coalesce(p_enabled, false));
  if coalesce(p_enabled, false) and nullif(v ->> 'since', '') is null then v := v || jsonb_build_object('since', now()); end if;
  update app_settings set value = v where key = 'recruit_slack';
  return v - 'note';
end $$;

-- いま動かしてよいか（スイッチが入っていて、切り替えの時刻が控えてある）
create or replace function recruit_notice_on()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select (value ->> 'enabled') = 'true' and nullif(value ->> 'since', '') is not null from app_settings where key = 'recruit_slack'), false)
$$;

-- ============ 2. Edge Function を呼ぶ（pg_net。送るのは応募者の ID と目印だけ。氏名・電話・本文は送らない） ============
--   呼び方は pending_reminders_trigger() と同じ（合言葉は app_secrets.notify_slack_secret。apikey は公開用のキー）。
--   同じ取引の中で、同じ知らせは 1 回だけ。1 つの取引で 50 回まで（まとめて大量に更新したときに呼びすぎない。残りは見回り recruit_notice_sweep が拾う）。
create or replace function recruit_notice_fire(p_applicant uuid, p_kind text, p_ref text default null)
returns void language plpgsql security definer set search_path to 'public', 'net', 'extensions' as $$
declare
  c_fn   constant text := 'https://uuvsxzhpxtghojoubjcc.supabase.co/functions/v1/recruit-notify';
  c_anon constant text := 'sb_publishable_MrwPJAx_Ws_fdRutprKCiQ_dg3wCiTr';
  v_secret text; v_key text; v_seen text;
begin
  if p_applicant is null then return; end if;
  v_key := p_applicant::text || ':' || coalesce(p_kind, '') || ':' || coalesce(p_ref, '');
  v_seen := coalesce(current_setting('recruit_notice.fired', true), '');
  if position('|' || v_key || '|' in v_seen) > 0 then return; end if;
  if length(v_seen) - length(replace(v_seen, '|', '')) >= 100 then return; end if;   -- 区切りは 1 件につき 2 つ＝ 50 件まで
  perform set_config('recruit_notice.fired', v_seen || '|' || v_key || '|', true);
  select value into v_secret from app_secrets where key = 'notify_slack_secret';
  if v_secret is null or length(trim(v_secret)) = 0 then
    raise warning 'recruit_notice_fire: app_secrets.notify_slack_secret が未設定';
    return;
  end if;
  perform net.http_post(
    url := c_fn,
    headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', c_anon, 'Authorization', 'Bearer ' || c_anon, 'x-notify-secret', trim(v_secret)),
    body := jsonb_build_object('op', 'event', 'applicant_id', p_applicant, 'kind', p_kind, 'ref', p_ref),
    timeout_milliseconds := 60000);
end $$;

-- ============ 3. 出来事を拾うトリガー（既存のトリガー・関数は変えない。足すだけ） ============
--   どのトリガーも、スイッチが切れていれば何もしない。中で失敗しても、元の処理（応募の取り込み・管理画面の保存）は止めない（警告だけ）。
create or replace function trg_recruit_notice_applicant()
returns trigger language plpgsql security definer set search_path to 'public', 'net', 'extensions' as $$
begin
  begin
    if not recruit_notice_on() then return null; end if;
    if tg_op = 'INSERT' then
      -- CSV の取り込み（まとめて入る過去の応募者）では知らせない
      if new.source is distinct from 'csv' then perform recruit_notice_fire(new.id, 'created'); end if;
    elsif tg_op = 'UPDATE' then
      perform recruit_notice_fire(new.id, 'updated');
    elsif tg_op = 'DELETE' then
      -- 控えのある応募者が消えたとき（統合で消えた・管理画面で削除した）だけ知らせる。親は消さず「統合済み／削除済み」にする
      if exists (select 1 from notice_cases c where c.type_key = 'recruit' and c.ref_table = 'applicants' and c.ref_id = old.id::text) then
        perform recruit_notice_fire(old.id, 'deleted');
      end if;
    end if;
  exception when others then
    raise warning 'recruit_notice（applicants）: %', sqlerrm;
  end;
  return null;
end $$;

drop trigger if exists recruit_notice_ins on applicants;
create trigger recruit_notice_ins after insert on applicants for each row execute function trg_recruit_notice_applicant();
-- 更新は、Slack に出す内容に関わる列が変わったときだけ（既読・メモ・リマインドの記録などでは呼ばない）
drop trigger if exists recruit_notice_upd on applicants;
create trigger recruit_notice_upd after update on applicants for each row
  when (old.status is distinct from new.status or old.interview_at is distinct from new.interview_at or old.interview_mode is distinct from new.interview_mode
     or old.interview_place is distinct from new.interview_place or old.interview_prefs is distinct from new.interview_prefs
     or old.assignee_id is distinct from new.assignee_id or old.store_id is distinct from new.store_id or old.name is distinct from new.name
     or old.handled_at is distinct from new.handled_at or old.hired_at is distinct from new.hired_at or old.user_id is distinct from new.user_id
     or old.exit_reason is distinct from new.exit_reason or old.exit_stage is distinct from new.exit_stage or old.last_msg_dir is distinct from new.last_msg_dir
     or old.form_received_at is distinct from new.form_received_at or old.line_linked_at is distinct from new.line_linked_at
     or old.job_type is distinct from new.job_type or old.answers is distinct from new.answers)
  execute function trg_recruit_notice_applicant();
drop trigger if exists recruit_notice_del on applicants;
create trigger recruit_notice_del after delete on applicants for each row execute function trg_recruit_notice_applicant();

-- やり取り（applicant_messages）: 新しく入った 1 通ごとに知らせる。重複受信は、既存の一意制約（source_ref）で行が増えない＝トリガーも動かない。
--   別の応募者へ付け替わったとき（＝統合 merge_applicants がやり取りを移した）は、「統合かもしれない」と知らせる。本当に統合かどうか（元の応募者が消えたか）は Edge Function が確かめる
create or replace function trg_recruit_notice_message()
returns trigger language plpgsql security definer set search_path to 'public', 'net', 'extensions' as $$
begin
  begin
    if not recruit_notice_on() then return null; end if;
    if tg_op = 'INSERT' then
      perform recruit_notice_fire(new.applicant_id, 'message', new.id::text);
    elsif new.applicant_id is not null and old.applicant_id is not null and new.applicant_id <> old.applicant_id then
      perform recruit_notice_fire(new.applicant_id, 'merged', old.applicant_id::text);
    end if;
  exception when others then
    raise warning 'recruit_notice（applicant_messages）: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists recruit_notice_msg_ins on applicant_messages;
create trigger recruit_notice_msg_ins after insert on applicant_messages for each row execute function trg_recruit_notice_message();
drop trigger if exists recruit_notice_msg_move on applicant_messages;
create trigger recruit_notice_msg_move after update of applicant_id on applicant_messages for each row
  when (old.applicant_id is distinct from new.applicant_id) execute function trg_recruit_notice_message();

-- 統合の記録（applicant_merges）: 残る側（kept_id）に知らせる。消える側の ID を持つ列があれば、それも渡す。
--   ★ 列の名前は本番で未確認（リポジトリに定義が無い）。あり得る名前を順に見て、無ければ ref なしで知らせる（そのときは、上の「やり取りの付け替え」と、応募者の削除の知らせで拾う）
create or replace function trg_recruit_notice_merges()
returns trigger language plpgsql security definer set search_path to 'public', 'net', 'extensions' as $$
declare j jsonb; v_keep text; v_merged text;
begin
  begin
    if not recruit_notice_on() then return null; end if;
    j := to_jsonb(new);
    v_keep := j ->> 'kept_id';
    v_merged := coalesce(j ->> 'merged_id', j ->> 'merged_applicant_id', j ->> 'removed_id', j ->> 'from_id');
    if v_keep ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      perform recruit_notice_fire(v_keep::uuid, 'merged', case when v_merged ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then v_merged end);
    end if;
  exception when others then
    raise warning 'recruit_notice（applicant_merges）: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists recruit_notice_merged on applicant_merges;
create trigger recruit_notice_merged after insert on applicant_merges for each row execute function trg_recruit_notice_merges();

-- 入社登録（既存の流れ）: 入社ワークフローができた・Slack の親ができた・中止になった、を採用管理のスレッドに映す（「入社登録へ移行済み」とリンク）。入社登録の側は読むだけ
create or replace function trg_recruit_notice_onboarding()
returns trigger language plpgsql security definer set search_path to 'public', 'net', 'extensions' as $$
begin
  begin
    if new.applicant_id is not null and recruit_notice_on() then perform recruit_notice_fire(new.applicant_id, 'onboarding'); end if;
  exception when others then
    raise warning 'recruit_notice（onboarding_workflows）: %', sqlerrm;
  end;
  return null;
end $$;
do $$
begin
  if to_regclass('public.onboarding_workflows') is not null then
    drop trigger if exists recruit_notice_onb_ins on onboarding_workflows;
    create trigger recruit_notice_onb_ins after insert on onboarding_workflows for each row execute function trg_recruit_notice_onboarding();
    drop trigger if exists recruit_notice_onb_upd on onboarding_workflows;
    create trigger recruit_notice_onb_upd after update on onboarding_workflows for each row
      when (old.applicant_id is distinct from new.applicant_id or old.status is distinct from new.status or old.slack_parent_ts is distinct from new.slack_parent_ts)
      execute function trg_recruit_notice_onboarding();
  end if;
end $$;

-- ============ 4. 親を 1 件に保つための関数（Edge Function recruit-notify だけが呼ぶ） ============
-- 4-1. 親を作る権利を取る。true が返った実行だけが、親メッセージを投稿する。
--   ・初めて（控えがまだ無い／権利がまだ取られていない）→ true
--   ・すでにだれかが取っている → false（同時に呼ばれても、行のロックで 1 つだけが true になる）
--   ・親が出ないまま p_stale_seconds たった控え（投稿の途中で止まった）→ 取り直せる（true）。
--     取り直した実行は、同じ台帳の番号・同じ重複防止の鍵で送るので、前の実行が実は投稿できていた場合は notify-slack が「送信済み」と答え、親は増えない
create or replace function recruit_notice_claim(p_applicant uuid, p_stale_seconds integer default 300)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_n integer;
begin
  if not onboarding_is_service() then raise exception '権限がありません'; end if;
  if p_applicant is null then return false; end if;
  insert into notice_cases(type_key, ref_table, ref_id) values ('recruit', 'applicants', p_applicant::text)
  on conflict (type_key, ref_table, ref_id) do nothing;
  update notice_cases
     set slack_refs = slack_refs || jsonb_build_object('claim_at', now()), updated_at = now()
   where type_key = 'recruit' and ref_table = 'applicants' and ref_id = p_applicant::text
     and not (slack_refs ? 'ts')                                  -- 親の ts がまだ控えられていない
     and not (slack_refs ? 'merged_into')
     and (not (slack_refs ? 'claim_at') or (slack_refs ->> 'claim_at')::timestamptz < now() - make_interval(secs => greatest(coalesce(p_stale_seconds, 300), 30)));
  get diagnostics v_n = row_count;
  return v_n = 1;
end $$;

-- 4-2. 応募者ごとに、処理を 1 つずつにする（同じ応募者の出来事が続けて届いても、スレッドへの書き込みが重ならない・前後しない）。
--   取れた → true。取れない（別の実行が処理中）→ 「やり直しの印」を付けて false。処理中の実行は、終わるときに印を見て、もう一周する
create or replace function recruit_notice_lock(p_applicant uuid, p_token text, p_seconds integer default 120)
returns boolean language plpgsql security definer set search_path = public as $$
declare c notice_cases%rowtype;
begin
  if not onboarding_is_service() then raise exception '権限がありません'; end if;
  if p_applicant is null or coalesce(p_token, '') = '' then return false; end if;
  insert into notice_cases(type_key, ref_table, ref_id) values ('recruit', 'applicants', p_applicant::text)
  on conflict (type_key, ref_table, ref_id) do nothing;
  select * into c from notice_cases where type_key = 'recruit' and ref_table = 'applicants' and ref_id = p_applicant::text for update;
  if c.slack_refs ->> 'lock_token' is distinct from p_token and coalesce((c.slack_refs ->> 'lock_until')::timestamptz, '-infinity') > now() then
    update notice_cases set slack_refs = slack_refs || '{"dirty": true}'::jsonb where id = c.id;
    return false;
  end if;
  update notice_cases set slack_refs = slack_refs || jsonb_build_object('lock_token', p_token, 'lock_until', now() + make_interval(secs => greatest(coalesce(p_seconds, 120), 10)), 'dirty', false) where id = c.id;
  return true;
end $$;

-- 処理の終わり。true＝処理中に別の出来事が来ていた（権利を持ったまま、もう一周する）／false＝権利を手放した（または、時間切れで別の実行に移っていた）
create or replace function recruit_notice_unlock(p_applicant uuid, p_token text)
returns boolean language plpgsql security definer set search_path = public as $$
declare c notice_cases%rowtype;
begin
  if not onboarding_is_service() then raise exception '権限がありません'; end if;
  select * into c from notice_cases where type_key = 'recruit' and ref_table = 'applicants' and ref_id = p_applicant::text for update;
  if c.id is null or c.slack_refs ->> 'lock_token' is distinct from p_token then return false; end if;
  if coalesce((c.slack_refs ->> 'dirty')::boolean, false) then
    update notice_cases set slack_refs = slack_refs || jsonb_build_object('dirty', false, 'lock_until', now() + interval '120 seconds') where id = c.id;
    return true;
  end if;
  update notice_cases set slack_refs = slack_refs - 'lock_token' - 'lock_until' - 'dirty' where id = c.id;
  return false;
end $$;

-- 4-3. 統合（merge_applicants）のあと、控えを「残る側」の応募者に寄せる。Edge Function が「消える側の応募者の行が、もう無い」と確かめてから呼ぶ。
--   ・消える側に親が無い                    → 消える側の控え（あれば）を消すだけ。false
--   ・残る側に親が無い                      → 控えをそのまま残る側へ付け替える（同じ親・同じスレッドが、残る側のものになる。新しい親は作らない）。true
--   ・両方に親がある                        → 残る側を正にする。消える側は「統合済み」で閉じ、統合先を控える（Slack のメッセージは別のスレッドへ移せないので、古い親は消さずに閉じる）。true
--   2 回呼んでも同じ結果（2 回目は false）
create or replace function recruit_notice_merge(p_keep uuid, p_merged uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare m notice_cases%rowtype; k notice_cases%rowtype; v_entry jsonb;
begin
  if not onboarding_is_service() then raise exception '権限がありません'; end if;
  if p_keep is null or p_merged is null or p_keep = p_merged then return false; end if;
  if exists (select 1 from applicants where id = p_merged) then return false; end if;       -- 消える側がまだいる＝統合ではない（やり取りを 1 通だけ付け替えた、など）
  if not exists (select 1 from applicants where id = p_keep) then return false; end if;
  select * into m from notice_cases where type_key = 'recruit' and ref_table = 'applicants' and ref_id = p_merged::text for update;
  if m.id is null or m.slack_refs ? 'merged_into' then return false; end if;
  if not (m.slack_refs ? 'ts') then delete from notice_cases where id = m.id; return false; end if;
  select * into k from notice_cases where type_key = 'recruit' and ref_table = 'applicants' and ref_id = p_keep::text for update;
  if k.id is null or not (k.slack_refs ? 'ts') then
    if k.id is not null then delete from notice_cases where id = k.id; end if;               -- 残る側の、親の無い控え（権利の印だけ）は捨てる
    v_entry := jsonb_build_object('id', p_merged, 'mode', 'moved', 'at', now());
    update notice_cases
       set ref_id = p_keep::text, closed_at = null, updated_at = now(),
           slack_refs = (slack_refs - 'lock_token' - 'lock_until' - 'dirty' - 'tombstone')
                        || jsonb_build_object('merged_from', coalesce(slack_refs -> 'merged_from', '[]'::jsonb) || jsonb_build_array(v_entry))
     where id = m.id;
    return true;
  end if;
  v_entry := jsonb_build_object('id', p_merged, 'mode', 'closed', 'at', now());
  update notice_cases
     set status_code = 'done', status_label = '統合済み', closed_at = coalesce(closed_at, now()), updated_at = now(),
         slack_refs = (slack_refs - 'tombstone') || jsonb_build_object('merged_into', p_keep, 'merged_at', now())
   where id = m.id;
  update notice_cases
     set slack_refs = slack_refs || jsonb_build_object('merged_from', coalesce(slack_refs -> 'merged_from', '[]'::jsonb) || jsonb_build_array(v_entry)), updated_at = now()
   where id = k.id;
  return true;
end $$;

-- ============ 5. 見回り（取りこぼしの拾い直し。5 分ごと） ============
--   pg_net の呼び出しは、失敗しても自動ではやり直されない。ここで「Slack が DB の状態に追いついていない応募者」を見つけて、もう一度知らせる（1 回 30 人まで）。
--   (a) 切り替え後の応募なのに、5 分たっても親が無い（3 日より前のものは追わない）
--   (b) 控えより応募者の更新のほうが新しい（知らせの取りこぼし）／やり直しの印が残っている
--   (c) 面接日を 12 時間過ぎても選考中のまま（まだスレッドで知らせていない）
--   (d) 控えはあるのに、応募者の行がもう無い（統合・削除の知らせの取りこぼし）
--   スイッチが切れていれば何もしない。過去の応募者をまとめて流し込むことはしない
create or replace function recruit_notice_sweep()
returns integer language plpgsql security definer set search_path to 'public', 'net', 'extensions' as $$
declare v_since timestamptz; r record; n integer := 0;
begin
  if not recruit_notice_on() then return 0; end if;
  select (value ->> 'since')::timestamptz into v_since from app_settings where key = 'recruit_slack';
  for r in
    with cs as materialized (
      select c.ref_id, c.updated_at, c.slack_refs from notice_cases c
       where c.type_key = 'recruit' and c.ref_table = 'applicants' and c.ref_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    )
    select x.id, x.kind from (
      select a.id, 'sweep'::text as kind, 1 as pri, a.applied_at as ord_at
        from applicants a left join cs on cs.ref_id = a.id::text
       where a.applied_at >= v_since and a.applied_at > now() - interval '3 days' and a.applied_at < now() - interval '5 minutes'
         and a.source is distinct from 'csv' and (cs.ref_id is null or not (cs.slack_refs ? 'ts'))
      union all
      select a.id, 'sweep', 2, a.updated_at
        from cs join applicants a on a.id = cs.ref_id::uuid
       where cs.slack_refs ? 'ts' and not (cs.slack_refs ? 'merged_into') and not coalesce((cs.slack_refs ->> 'tombstone')::boolean, false)
         and coalesce((cs.slack_refs ->> 'lock_until')::timestamptz, '-infinity') < now()
         and ((a.updated_at > cs.updated_at and a.updated_at < now() - interval '3 minutes')
              or coalesce((cs.slack_refs ->> 'retry')::boolean, false) or coalesce((cs.slack_refs ->> 'dirty')::boolean, false)
              or (a.interview_at < now() - interval '12 hours' and a.status in ('new', 'contacted', 'interview_set', 'interviewed')
                  and coalesce(cs.slack_refs -> 'snap' ->> 'overdue', 'false') <> 'true'))
      union all
      select cs.ref_id::uuid, 'deleted', 3, cs.updated_at
        from cs
       where cs.slack_refs ? 'ts' and not coalesce((cs.slack_refs ->> 'tombstone')::boolean, false) and cs.updated_at < now() - interval '3 minutes'
         and not exists (select 1 from applicants a where a.id = cs.ref_id::uuid)
    ) x order by x.pri, x.ord_at limit 30
  loop
    perform recruit_notice_fire(r.id, r.kind);
    n := n + 1;
  end loop;
  return n;
end $$;

-- ============ 6. 権限（画面からは呼べない。Edge Function＝service_role と、トリガーの中からだけ） ============
revoke all on function recruit_slack_set(boolean), recruit_notice_on(), recruit_notice_fire(uuid, text, text),
  trg_recruit_notice_applicant(), trg_recruit_notice_message(), trg_recruit_notice_merges(), trg_recruit_notice_onboarding(),
  recruit_notice_claim(uuid, integer), recruit_notice_lock(uuid, text, integer), recruit_notice_unlock(uuid, text), recruit_notice_merge(uuid, uuid), recruit_notice_sweep()
  from public, anon, authenticated;
grant execute on function recruit_slack_set(boolean) to authenticated, service_role;   -- 中でマスターかどうかを確かめる
grant execute on function recruit_notice_claim(uuid, integer), recruit_notice_lock(uuid, text, integer), recruit_notice_unlock(uuid, text), recruit_notice_merge(uuid, uuid), recruit_notice_sweep() to service_role;

-- ============ 7. 見回りの定期実行（5 分ごと。スイッチが切れているあいだは、呼ばれてもすぐ戻る） ============
do $$
begin
  if exists (select 1 from cron.job where jobname = 'recruit-notice-sweep') then
    perform cron.unschedule('recruit-notice-sweep');
  end if;
  perform cron.schedule('recruit-notice-sweep', '*/5 * * * *', $cmd$select public.recruit_notice_sweep()$cmd$);
end $$;

-- ============ 確認用（読むだけ） ============
-- select channel_key, slack_channel_id, is_active from slack_channels where channel_key = 'hr.saiyo';
-- select value - 'note' from app_settings where key = 'recruit_slack';
-- select tgname, tgrelid::regclass from pg_trigger where tgname like 'recruit_notice_%' order by 1;
-- select jobname, schedule, active from cron.job where jobname = 'recruit-notice-sweep';
