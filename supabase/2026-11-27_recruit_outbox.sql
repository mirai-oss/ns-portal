-- 採用管理: 応募者への送信の「送信箱」と、送信のスイッチ・試しモード（2026-11-27 下書き）
--   設計: docs/設計書_採用_面接確定とLINEのSlack操作_2026-11-13.md §2 ／ この段階のメモ: scratchpad ob18/stage2/メモ_第2弾.md
--   ★ 本番未適用（下書き。適用は別途承認）。戻し方: 2026-11-27_recruit_outbox_rollback.sql
--   前提: 2026-11-26_recruit_action_base.sql（applicant_ops・recruit_op_log）が入っていること
--
--   これを適用しただけでは、いまの動きは何も変わらない。応募者へは何も送られない。
--     ・この中に、LINE・Slack・カレンダーを呼ぶ処理は 1 つも無い（送るのは Edge Function recruit-action。ここは「送ってよいか」と「結果の記録」だけ）。
--     ・実在の応募者へ届く経路は、2 つの設定で二重に閉じてある:
--         ① 送信のスイッチ app_settings.recruit_actions.send_enabled（既定 false）… false のあいだ、テスト用の印（answers._test = true）の無い応募者は断る
--         ② 試しモード     app_settings.recruit_actions.line_mode   （既定 dry） … dry のあいだ、LINE を呼ばず「試しとして処理した」と残すだけ（applicant_messages には入れない）
--   足すもの: 設定の項目 1 つ・表 1 つ（applicant_outbox）・関数 5 本。 変えないもの: 既存の表の列・既存の関数・既存のトリガー・line-webhook。

-- ============ 0. 前提の確認 ============
do $$
begin
  if to_regclass('public.applicant_ops') is null or to_regprocedure('public.recruit_op_log(uuid,text,uuid,text,text,jsonb,jsonb,text,text,text,timestamptz)') is null then
    raise exception '先に 2026-11-26_recruit_action_base.sql を適用してください（applicant_ops / recruit_op_log がありません）';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'applicant_messages' and column_name = 'sent_by')
     or not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'applicants' and column_name = 'line_user_id') then
    raise exception 'applicant_messages.sent_by / applicants.line_user_id がありません';
  end if;
end $$;

-- ============ 1. 設定（既定は、どれも「外へ出ない」側） ============
insert into app_settings (key, value)
select 'recruit_actions',
       '{"send_enabled": false, "line_mode": "dry", "calendar_mode": "dry", "note": "採用の共通の操作（recruit-action）。send_enabled=false のあいだは、テスト用の応募者（answers._test=true）だけ受ける。line_mode / calendar_mode が dry のあいだは、LINE / カレンダーを呼ばず、試しとして記録するだけ。切り替えは recruit_actions_cfg_set（マスターのみ）"}'::jsonb
where not exists (select 1 from app_settings where key = 'recruit_actions');

-- いまの設定（はっきり true / live と書いてあるときだけ、開く。それ以外・設定が無い・読めない値は、閉じた側）
create or replace function public.recruit_actions_cfg()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'send_enabled', coalesce((select value -> 'send_enabled' = 'true'::jsonb from app_settings where key = 'recruit_actions'), false),
    'line_mode', case when (select value ->> 'line_mode' from app_settings where key = 'recruit_actions') = 'live' then 'live' else 'dry' end,
    'calendar_mode', case when (select value ->> 'calendar_mode' from app_settings where key = 'recruit_actions') = 'live' then 'live' else 'dry' end)
$$;

-- 設定の切り替え（マスターのみ）。渡した項目だけ変える（null は変えない）
create or replace function public.recruit_actions_cfg_set(p_send_enabled boolean default null, p_line_mode text default null, p_calendar_mode text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_value jsonb;
begin
  if not (onboarding_is_service() or coalesce((select is_master from users where id = auth.uid() and is_active), false)) then
    raise exception '権限がありません（マスターのみ）';
  end if;
  if p_line_mode is not null and p_line_mode not in ('dry', 'live') then raise exception 'line_mode は dry か live です'; end if;
  if p_calendar_mode is not null and p_calendar_mode not in ('dry', 'live') then raise exception 'calendar_mode は dry か live です'; end if;
  select value into v_value from app_settings where key = 'recruit_actions';
  if v_value is null then raise exception '設定 recruit_actions がありません'; end if;
  if p_send_enabled is not null then v_value := v_value || jsonb_build_object('send_enabled', p_send_enabled); end if;
  if p_line_mode is not null then v_value := v_value || jsonb_build_object('line_mode', p_line_mode); end if;
  if p_calendar_mode is not null then v_value := v_value || jsonb_build_object('calendar_mode', p_calendar_mode); end if;
  update app_settings set value = v_value where key = 'recruit_actions';
  return recruit_actions_cfg();
end $$;

-- ============ 2. 送信箱（応募者あての 1 通 1 行） ============
-- 状態: sending＝送信中（LINE を呼ぶ直前に付く）／sent＝送信成功／failed＝送信失敗（LINE が断った）／unknown＝結果不明（返事が来なかった。自動では再送しない）／dry_done＝試しとして処理した（何も送っていない）
-- request_key＝依頼の鍵（同じ依頼は 1 行）／dedupe_key＝内容の鍵（同じ内容の案内は 1 回だけ。返信のように内容で縛らないものは null）／retry_key＝LINE の再送の鍵（やり直すときも同じ鍵を使う）
-- 本文は、応募者とのやり取り（applicant_messages）と同じ扱い: 画面からは直接読めない（RLS・ポリシーなし）
create table if not exists public.applicant_outbox (
  id           uuid primary key default gen_random_uuid(),
  applicant_id uuid not null,
  channel      text not null default 'line' check (channel in ('line')),
  purpose      text not null check (purpose ~ '^[a-z][a-z_]{1,39}$'),        -- reply（返信）／interview_notice（面接の案内）など
  body         text not null check (length(body) between 1 and 4900),
  actor_id     uuid,
  via          text not null check (via in ('slack', 'web', 'app', 'auto')),
  request_key  text not null check (length(request_key) between 8 and 200),
  dedupe_key   text check (dedupe_key is null or length(dedupe_key) between 8 and 300),
  retry_key    uuid not null default gen_random_uuid(),
  mode         text not null check (mode in ('dry', 'live')),
  status       text not null check (status in ('sending', 'sent', 'failed', 'unknown', 'dry_done')),
  attempts     integer not null default 0,
  error        text,
  response     jsonb,
  message_id   uuid,                                                          -- 送信成功のときにできた applicant_messages の行
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  sent_at      timestamptz,
  constraint applicant_outbox_request_key_uq unique (request_key)
);
create index if not exists applicant_outbox_applicant_idx on public.applicant_outbox (applicant_id, created_at desc);
-- 同じ内容の鍵は、「送信中・送信成功・結果不明」のあいだ 1 行だけ（失敗と試しは、やり直しを妨げない）
create unique index if not exists applicant_outbox_dedupe_uq on public.applicant_outbox (dedupe_key)
  where dedupe_key is not null and status in ('sending', 'sent', 'unknown');
alter table public.applicant_outbox enable row level security;
revoke all on public.applicant_outbox from anon, authenticated;

-- ============ 3. 送ってよいかの確認（窓を開く前に使う。何も書かない） ============
-- 返す形: {"ok": true, "can_send": true|false, "code": "ok|denied|not_found|disabled|not_linked", "message", "applicant_name", "linked", "is_test", "send_enabled", "line_mode"}
create or replace function public.recruit_send_check(p_applicant uuid, p_actor uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_cfg jsonb := recruit_actions_cfg(); v_a record; v_linked boolean; v_test boolean; v_code text := 'ok'; v_msg text := null;
begin
  if not onboarding_is_service() then raise exception '権限がありません（サーバー側の処理だけ）'; end if;
  if p_actor is null then raise exception '操作する人（p_actor）が指定されていません'; end if;
  select a.id, a.name, a.store_id, a.line_user_id, a.answers into v_a from applicants a where a.id = p_applicant;
  if not found then return jsonb_build_object('ok', false, 'can_send', false, 'code', 'not_found', 'message', '応募者が見つかりません'); end if;
  if not (coalesce((select u.is_active from users u where u.id = p_actor), false) and has_feature(p_actor, 'recruit') and can_see_applicant(p_actor, v_a.store_id)) then
    return jsonb_build_object('ok', false, 'can_send', false, 'code', 'denied', 'message', '権限がありません');
  end if;
  v_linked := coalesce(btrim(coalesce(v_a.line_user_id, '')), '') <> '';
  v_test := coalesce(v_a.answers ->> '_test', '') = 'true';
  if not (v_cfg ->> 'send_enabled')::boolean and not v_test then
    v_code := 'disabled'; v_msg := '応募者への送信は、まだ使えません（送信のスイッチが OFF です）';
  elsif not v_linked then
    v_code := 'not_linked'; v_msg := 'この応募者は LINE と連携していないため、ここからは送れません';
  end if;
  return jsonb_build_object('ok', true, 'can_send', v_code = 'ok', 'code', v_code, 'message', v_msg, 'applicant_name', v_a.name,
    'linked', v_linked, 'is_test', v_test, 'send_enabled', (v_cfg ->> 'send_enabled')::boolean, 'line_mode', v_cfg ->> 'line_mode');
end $$;

-- ============ 4. 送信の始まり（権限・スイッチ・二重の確認をして、送信箱に 1 行入れる） ============
-- 返す形（code）:
--   send        … 送ってよい。Edge Function が LINE を呼び、終わったら recruit_send_finish を呼ぶ。"to"（LINE の宛先）と "retry_key" を返す（Edge Function の外へは出さないこと）
--   dry         … 試しモード。何も送らず、送信箱に「試しとして処理した」と残した
--   replayed    … 同じ依頼の鍵の 2 回目。前の行の状態を返すだけ（送らない）
--   denied / disabled / not_linked / duplicate / duplicate_recent / not_found / key_reused … 送らない（"message" に理由）
create or replace function public.recruit_send_begin(
  p_applicant uuid, p_body text, p_purpose text, p_request_key text, p_actor uuid, p_via text, p_dedupe_key text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_cfg jsonb := recruit_actions_cfg(); v_a record; v_row applicant_outbox%rowtype;
  v_key text := btrim(coalesce(p_request_key, '')); v_body text := btrim(coalesce(p_body, '')); v_dedupe text := nullif(btrim(coalesce(p_dedupe_key, '')), '');
  v_purpose text := coalesce(nullif(btrim(coalesce(p_purpose, '')), ''), 'reply'); v_mode text; v_test boolean; v_actor_name text; v_op uuid;
begin
  if not onboarding_is_service() then raise exception '権限がありません（サーバー側の処理だけ）'; end if;
  if p_actor is null then raise exception '操作する人（p_actor）が指定されていません'; end if;
  if p_via is null or p_via not in ('slack', 'web', 'app') then raise exception 'p_via が正しくありません'; end if;
  if length(v_key) < 8 or length(v_key) > 200 then raise exception '依頼の鍵（p_request_key）が正しくありません'; end if;
  if v_purpose !~ '^[a-z][a-z_]{1,39}$' then raise exception 'p_purpose が正しくありません'; end if;
  if length(v_body) < 1 then return jsonb_build_object('ok', false, 'code', 'empty', 'message', '本文が空です'); end if;
  if length(v_body) > 4900 then return jsonb_build_object('ok', false, 'code', 'too_long', 'message', '本文が長すぎます（4,900 文字まで）'); end if;

  -- 応募者の行を押さえる（同じ応募者への送信は、ここで 1 つずつになる）
  select a.id, a.name, a.store_id, a.line_user_id, a.answers into v_a from applicants a where a.id = p_applicant for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', '応募者が見つかりません'); end if;

  -- 「送信中」のまま 2 分を過ぎた行（送る処理が途中で止まった）は、「結果不明」にする（送れたか分からないので、自動では再送しない）
  update applicant_outbox set status = 'unknown', error = '結果の記録が無いまま、時間が過ぎました', updated_at = now()
   where applicant_id = p_applicant and status = 'sending' and updated_at < now() - interval '2 minutes';

  -- 同じ依頼の鍵の 2 回目: 送らない。前の行の状態を返すだけ
  select * into v_row from applicant_outbox where request_key = v_key;
  if found then
    if v_row.applicant_id <> p_applicant or v_row.actor_id is distinct from p_actor then
      return jsonb_build_object('ok', false, 'code', 'key_reused', 'message', '同じ依頼の鍵が、別の操作で使われています');
    end if;
    return jsonb_build_object('ok', v_row.status in ('sent', 'dry_done'), 'code', 'replayed', 'replayed', true, 'outbox_id', v_row.id, 'status', v_row.status, 'mode', v_row.mode,
      'message', case v_row.status when 'sent' then '送信済みです' when 'dry_done' then '試しとして処理済みです（LINE は送っていません）' when 'sending' then '送信の処理中です（もう一度は送りません）'
                                   when 'unknown' then '送れたか確認できていません（自動では再送しません）' else '送信に失敗しています' end);
  end if;

  -- 権限（サーバー側で確かめる）
  if not (coalesce((select u.is_active from users u where u.id = p_actor), false) and has_feature(p_actor, 'recruit') and can_see_applicant(p_actor, v_a.store_id)) then
    v_op := recruit_op_log(p_applicant, 'message_send', p_actor, p_via, 'send-denied:' || left(v_key, 100) || ':' || gen_random_uuid()::text, '{}'::jsonb, jsonb_build_object('purpose', v_purpose), 'denied', 'no_permission', null);
    return jsonb_build_object('ok', false, 'code', 'denied', 'message', '権限がありません');
  end if;

  -- 送信のスイッチ: OFF のあいだは、テスト用の印の付いた応募者だけ
  v_test := coalesce(v_a.answers ->> '_test', '') = 'true';
  if not (v_cfg ->> 'send_enabled')::boolean and not v_test then
    return jsonb_build_object('ok', false, 'code', 'disabled', 'message', '応募者への送信は、まだ使えません（送信のスイッチが OFF です）');
  end if;
  -- LINE と連携していない応募者には、送れない
  if coalesce(btrim(coalesce(v_a.line_user_id, '')), '') = '' then
    return jsonb_build_object('ok', false, 'code', 'not_linked', 'message', 'この応募者は LINE と連携していないため、ここからは送れません');
  end if;
  -- 同じ内容の鍵（面接の案内など）: 送信中・送信成功・結果不明の行があれば、送らない
  if v_dedupe is not null and exists (select 1 from applicant_outbox b where b.dedupe_key = v_dedupe and b.status in ('sending', 'sent', 'unknown')) then
    return jsonb_build_object('ok', false, 'code', 'duplicate', 'message', '同じ内容を、すでに送っています（または、送れたか確認できていません）');
  end if;
  -- 同じ文面を、直前（10 分以内）に送っている: 送らない（管理システムの画面からの送信＝古い経路との二重も、ここで受ける）
  if exists (select 1 from applicant_messages m
              where m.applicant_id = p_applicant and m.channel = 'line' and m.direction = 'out' and m.body = left(v_body, 8000) and m.sent_at > now() - interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'duplicate_recent', 'message', '同じ文面を、直前（10 分以内）に送っています');
  end if;

  v_mode := v_cfg ->> 'line_mode';
  select u.name into v_actor_name from users u where u.id = p_actor;
  insert into applicant_outbox (applicant_id, channel, purpose, body, actor_id, via, request_key, dedupe_key, mode, status, attempts)
  values (p_applicant, 'line', v_purpose, v_body, p_actor, p_via, v_key, v_dedupe, v_mode, case when v_mode = 'live' then 'sending' else 'dry_done' end, case when v_mode = 'live' then 1 else 0 end)
  returning * into v_row;

  if v_mode <> 'live' then
    v_op := recruit_op_log(p_applicant, 'message_send', p_actor, p_via, 'send:' || v_row.id::text || ':dry', '{}'::jsonb,
                           jsonb_build_object('outbox_id', v_row.id, 'purpose', v_purpose, 'mode', 'dry', 'chars', length(v_body)), 'noop', null, '試しモード（LINE は送っていない）');
    return jsonb_build_object('ok', true, 'code', 'dry', 'outbox_id', v_row.id, 'mode', 'dry', 'status', 'dry_done', 'applicant_name', v_a.name, 'actor_name', v_actor_name,
      'message', '試しモードのため、LINE は送っていません');
  end if;
  return jsonb_build_object('ok', true, 'code', 'send', 'outbox_id', v_row.id, 'mode', 'live', 'status', 'sending', 'retry_key', v_row.retry_key,
    'to', v_a.line_user_id, 'text', v_body, 'applicant_name', v_a.name, 'actor_name', v_actor_name);
end $$;

-- ============ 5. 送信の終わり（結果の記録。成功したときだけ、やり取りに「こちらから」を、送った人つきで 1 通入れる） ============
-- p_status: sent（送信成功）／failed（LINE が断った）／unknown（返事が来なかった。自動では再送しない）
-- やり取りに 1 通入ると、既存のトリガーが Slack のスレッドに「↩️ こちらから（LINE・送った人・日時）」を出す（ここからは Slack を呼ばない）
create or replace function public.recruit_send_finish(p_outbox uuid, p_status text, p_error text default null, p_response jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_row applicant_outbox%rowtype; v_msg uuid; v_op uuid;
begin
  if not onboarding_is_service() then raise exception '権限がありません（サーバー側の処理だけ）'; end if;
  if p_status is null or p_status not in ('sent', 'failed', 'unknown') then raise exception 'p_status が正しくありません'; end if;
  select * into v_row from applicant_outbox where id = p_outbox for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', '送信箱の行が見つかりません'); end if;
  if v_row.status <> 'sending' then
    -- すでに結果が入っている（二度目の呼び出し）: 何も変えない
    return jsonb_build_object('ok', v_row.status = p_status, 'code', 'already', 'status', v_row.status, 'outbox_id', v_row.id);
  end if;
  if p_status = 'sent' then
    insert into applicant_messages (applicant_id, channel, direction, body, sent_at, source_ref, direction_fixed, sent_by)
    values (v_row.applicant_id, 'line', 'out', left(v_row.body, 8000), now(), 'outbox:' || v_row.id::text, true, v_row.actor_id)
    on conflict (source_ref) do nothing
    returning id into v_msg;
    update applicants set updated_at = now(),
           last_actor_id = coalesce(v_row.actor_id, last_actor_id),
           last_actor_at = case when v_row.actor_id is not null then now() else last_actor_at end,
           interview_sent_at = case when v_row.purpose = 'interview_notice' then now() else interview_sent_at end   -- 面接の案内を送った印（画面の mark_interview_sent と同じ）
     where id = v_row.applicant_id;
    update applicant_outbox set status = 'sent', sent_at = now(), message_id = v_msg, response = p_response, error = null, updated_at = now() where id = p_outbox;
    v_op := recruit_op_log(v_row.applicant_id, 'message_send', v_row.actor_id, v_row.via, 'send:' || v_row.id::text || ':sent', '{}'::jsonb,
                           jsonb_build_object('outbox_id', v_row.id, 'purpose', v_row.purpose, 'mode', 'live', 'message_id', v_msg, 'chars', length(v_row.body)), 'done', null, null);
  else
    update applicant_outbox set status = p_status, error = left(coalesce(p_error, ''), 500), response = p_response, updated_at = now() where id = p_outbox;
    v_op := recruit_op_log(v_row.applicant_id, 'message_send', v_row.actor_id, v_row.via, 'send:' || v_row.id::text || ':' || p_status, '{}'::jsonb,
                           jsonb_build_object('outbox_id', v_row.id, 'purpose', v_row.purpose, 'mode', 'live', 'status', p_status), 'failed',
                           left(case when p_status = 'unknown' then '結果不明: ' else '' end || coalesce(p_error, ''), 500), null);
  end if;
  return jsonb_build_object('ok', true, 'code', p_status, 'status', p_status, 'outbox_id', v_row.id, 'message_id', v_msg);
end $$;

-- ============ 6. 権限（どれも、画面からは呼べない。Edge Function＝service_role だけ。設定の切り替えは、中でマスターかどうかを確かめる） ============
revoke all on function public.recruit_actions_cfg(), public.recruit_actions_cfg_set(boolean, text, text), public.recruit_send_check(uuid, uuid),
  public.recruit_send_begin(uuid, text, text, text, uuid, text, text), public.recruit_send_finish(uuid, text, text, jsonb)
  from public, anon, authenticated;
grant execute on function public.recruit_actions_cfg(), public.recruit_send_check(uuid, uuid),
  public.recruit_send_begin(uuid, text, text, text, uuid, text, text), public.recruit_send_finish(uuid, text, text, jsonb) to service_role;
grant execute on function public.recruit_actions_cfg_set(boolean, text, text) to authenticated, service_role;

-- ============ 確認用（読むだけ） ============
-- select recruit_actions_cfg();                                            -- {"send_enabled": false, "line_mode": "dry", "calendar_mode": "dry"}
-- select status, mode, purpose, count(*) from applicant_outbox group by 1, 2, 3 order by 1, 2, 3;
