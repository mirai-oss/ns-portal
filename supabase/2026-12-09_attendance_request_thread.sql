-- =============================================================
-- 勤怠修正申請の改善・第 1 弾: スレッド化 ＋ 比較表示 の土台（2026-11-15 下書き・★ 本番未適用 ★）
--   設計: ob22/設計_勤怠修正申請_改善.md（§2 第 1 弾・§4・§7）
--   戻し方: 2026-12-09_attendance_request_thread_rollback.sql
--
--   この SQL は「足すだけ」。今ある関数（sf_attendance_request_submit / _decide ほか）・今ある列・制約は 1 つも変えない。
--   適用しただけでは、通知も承認の流れも変わらない（スイッチ app_settings.attendance_request_flow.thread が false のあいだ、
--   Edge Function は今までの処理をそのまま通る）。
--
--   足すもの:
--     1. スイッチ app_settings.attendance_request_flow（全部 false）
--     2. 通知の種類 notice_types 'attendance_request'（親とスレッドの場所は、今ある notice_cases に控える。新しい表は作らない）
--     3. sf_attendance_requests の列: before_meta（申請時点の元の行の情報）・source_changed_at・source_change
--        ＋ 追加の前のトリガー（新しい申請にだけ before_meta を入れる。今ある行は変えない）
--     4. 履歴の表 sf_attendance_request_events（足すだけ・書き換えと削除は不可）
--        ＋ 申請の行の追加・更新のあとのトリガー（申請・承認・却下・スマレジの結果を 1 行ずつ残す。失敗しても元の処理は止めない）
--     5. 元データの変化の検出 sf_attendance_request_source_check（読むだけ）
--     6. カード・画面用の読み取り sf_attendance_request_view（読むだけ・service_role だけ）
-- =============================================================

-- ============ 1. スイッチ（既定は全部 OFF＝今までどおり） ============
--   thread       … true で、フォームの勤怠申請を「親 1 行＋スレッド」で出す（第 1 弾）
--   two_stage    … true で、店舗別の 2 段階承認（第 2 弾の SQL と Edge Function が入ってから。thread が true のときだけ働く）
--   president_dm … 社長（承認者）へ、スレッドへのリンクだけの DM を送るか（ボタンは付けない）
insert into app_settings(key, value)
values ('attendance_request_flow', '{"thread": false, "two_stage": false, "president_dm": true}'::jsonb)
on conflict (key) do nothing;

-- ============ 2. 通知の種類（親とスレッドの場所の控え notice_cases の type_key に使う） ============
insert into notice_types(type_key, label, emoji, channel_key, final_channel_key, date_rule, thread_fields, sort_order)
values ('attendance_request', '勤怠修正', '📝', 'kintai.check', null, 'work_date', '{work_date,store,before,after,reason,status,history}', 12)
on conflict (type_key) do nothing;

-- ============ 3. 申請時点の修正前データ（元の行の情報）と、元データの変化の記録 ============
alter table sf_attendance_requests
  add column if not exists before_meta       jsonb,         -- {exists, labor_cost_daily_id, smaregi_shift_result_id, source, row_updated_at, manual_fixed, taken_at}
  add column if not exists source_changed_at timestamptz,   -- 元データが申請時点から変わったのを見つけた時刻（見つけていなければ null）
  add column if not exists source_change     jsonb;         -- そのときの中身 {state, current}
comment on column sf_attendance_requests.before_meta is '申請時点の元の勤怠の行の情報（修正）。追加の申請は exists=false（＝申請時点では打刻が無かった）';
comment on column sf_attendance_requests.before is '修正の申請: 申請時点の修正前の値（出勤・退勤・休憩・勤務時間）。承認待ちのあいだに元データが変わったかは sf_attendance_request_source_check で比べる';

create or replace function public.sf_attendance_requests_snapshot() returns trigger
language plpgsql security definer set search_path = public as $$
declare l labor_cost_daily%rowtype;
begin
  begin
    if new.before_meta is null then
      if new.kind = 'fix' and new.labor_cost_daily_id is not null then
        select * into l from labor_cost_daily where id = new.labor_cost_daily_id;
        if found then
          new.before_meta := jsonb_build_object('exists', true, 'labor_cost_daily_id', l.id, 'smaregi_shift_result_id', l.smaregi_shift_result_id,
            'source', l.source, 'row_updated_at', l.updated_at, 'manual_fixed', l.manual_fixed_at is not null, 'taken_at', now());
          if new.before is null then
            new.before := jsonb_build_object('clock_in', l.clock_in, 'clock_out', l.clock_out, 'worked_minutes', l.worked_minutes,
              'break_start_1', l.break_start_1, 'break_end_1', l.break_end_1, 'break_start_2', l.break_start_2, 'break_end_2', l.break_end_2, 'break_minutes', l.break_minutes);
          end if;
        else
          new.before_meta := jsonb_build_object('exists', false, 'taken_at', now());
        end if;
      else
        new.before_meta := jsonb_build_object('exists', false, 'taken_at', now());
      end if;
    end if;
  exception when others then
    raise warning 'sf_attendance_requests_snapshot: %', sqlerrm;   -- 控えに失敗しても、申請そのものは止めない
  end;
  return new;
end $$;
drop trigger if exists sf_attendance_requests_a_snapshot_bi on sf_attendance_requests;
create trigger sf_attendance_requests_a_snapshot_bi before insert on sf_attendance_requests
  for each row execute function public.sf_attendance_requests_snapshot();

-- ============ 4. 履歴の表（だれが・いつ・何を・理由）。足すだけ ============
create table if not exists sf_attendance_request_events (
  id         uuid primary key default gen_random_uuid(),
  request_id uuid not null references sf_attendance_requests(id) on delete cascade,
  at         timestamptz not null default clock_timestamp(),   -- 同じ取引の中でも、書いた順に並ぶように（now() は取引の開始時刻）
  actor      uuid references users(id),          -- 操作した人（システムの処理は null）
  action     text not null,                      -- submitted / approved / rejected / cancelled / sync_pending / sync_synced / sync_failed / sync_skipped
                                                 -- 第 2 弾: routed / first_approved / asked / returned / resubmitted / source_changed / final_approved / sync_retry / question / answer
  via        text,                               -- form / slack / portal / system
  note       text,                               -- 理由・質問・回答・エラーの文
  data       jsonb not null default '{}'::jsonb, -- 修正前後の値など
  slack_notification_id uuid                     -- この行をスレッドに出したときの台帳 id（出していなければ null）
);
create index if not exists sf_attendance_request_events_req_idx on sf_attendance_request_events (request_id, at);
comment on table sf_attendance_request_events is '勤怠の追加・修正申請の操作の履歴。足すだけ（書き換え・削除は不可。申請の行ごと消すときだけ一緒に消える）';

alter table sf_attendance_request_events enable row level security;
drop policy if exists sf_attendance_request_events_read on sf_attendance_request_events;
create policy sf_attendance_request_events_read on sf_attendance_request_events for select using (
  auth.uid() is not null and exists (
    select 1 from sf_attendance_requests r
     where r.id = sf_attendance_request_events.request_id
       and (r.requested_by = auth.uid() or r.user_id = auth.uid() or sf_can_manage(r.store_id)))
);
revoke insert, update, delete, truncate on sf_attendance_request_events from anon, authenticated;

create or replace function public.sf_attendance_request_events_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    -- 申請の行ごと消すとき（外部キーの連鎖＝トリガーの入れ子が 2 段目）だけ通す。履歴だけを直接消すことはできない
    if pg_trigger_depth() < 2 then raise exception '勤怠申請の履歴は消せません'; end if;
    return old;
  end if;
  if new.request_id is distinct from old.request_id or new.at is distinct from old.at or new.actor is distinct from old.actor
     or new.action is distinct from old.action or new.via is distinct from old.via or new.note is distinct from old.note
     or new.data is distinct from old.data then
    raise exception '勤怠申請の履歴は書き換えられません';   -- slack_notification_id（スレッドに出した印）だけは後から入れられる
  end if;
  return new;
end $$;
drop trigger if exists sf_attendance_request_events_guard_bud on sf_attendance_request_events;
create trigger sf_attendance_request_events_guard_bud before update or delete on sf_attendance_request_events
  for each row execute function public.sf_attendance_request_events_guard();

-- 申請の行の追加・更新のあと: 状態とスマレジの結果の変化を履歴に残す（今ある関数は変えずに、どの経路の操作も残る）
create or replace function public.sf_attendance_requests_event_log() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  begin
    if tg_op = 'INSERT' then
      insert into sf_attendance_request_events(request_id, actor, action, via, note, data)
      values (new.id, new.requested_by, 'submitted', new.requested_via, new.reason,
        jsonb_build_object('kind', new.kind, 'before', new.before,
          'after', jsonb_build_object('clock_in', new.clock_in, 'clock_out', new.clock_out, 'break_start_1', new.break_start_1, 'break_end_1', new.break_end_1,
                                      'break_start_2', new.break_start_2, 'break_end_2', new.break_end_2, 'break_minutes', new.break_minutes)));
    else
      if new.status is distinct from old.status then
        insert into sf_attendance_request_events(request_id, actor, action, via, note, data)
        values (new.id, new.decided_by, new.status, null, new.decision_note, jsonb_build_object('from', old.status, 'to', new.status));
      end if;
      if new.smaregi_sync_status is distinct from old.smaregi_sync_status and new.smaregi_sync_status is not null then
        insert into sf_attendance_request_events(request_id, actor, action, via, note, data)
        values (new.id, null, 'sync_' || new.smaregi_sync_status, 'system',
          case when new.smaregi_sync_status = 'failed' then left(coalesce(new.smaregi_error, ''), 300) end,
          jsonb_build_object('from', old.smaregi_sync_status));
      end if;
    end if;
  exception when others then
    raise warning 'sf_attendance_requests_event_log: %', sqlerrm;   -- 履歴に失敗しても、申請・承認そのものは止めない
  end;
  return null;
end $$;
drop trigger if exists sf_attendance_requests_event_aiu on sf_attendance_requests;
create trigger sf_attendance_requests_event_aiu after insert or update on sf_attendance_requests
  for each row execute function public.sf_attendance_requests_event_log();

-- ============ 5. 元データの変化の検出（読むだけ） ============
--   state: same＝申請時点と同じ／changed＝値が変わった／gone＝元の行が無くなった／appeared＝（追加の申請で）その日の打刻が出来ていた
--          na＝承認待ちではない（比べない）／not_found
--   比べるのは 出勤・退勤・休憩 1・休憩 2（分の単位）
create or replace function public.sf_attendance_request_source_check(p_request_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  c_cols constant text[] := array['clock_in', 'clock_out', 'break_start_1', 'break_end_1', 'break_start_2', 'break_end_2'];
  r sf_attendance_requests%rowtype; l labor_cost_daily%rowtype; v_cur jsonb; v_col text; v_same boolean := true;
begin
  select * into r from sf_attendance_requests where id = p_request_id;
  if not found then return jsonb_build_object('state', 'not_found'); end if;
  if r.status <> 'pending' then return jsonb_build_object('state', 'na'); end if;
  if r.kind = 'add' then
    select * into l from labor_cost_daily where user_id = r.user_id and work_date = r.work_date and store_id = r.store_id order by clock_in limit 1;
    if not found then return jsonb_build_object('state', 'same'); end if;
  else
    select * into l from labor_cost_daily where id = r.labor_cost_daily_id;
    if not found then return jsonb_build_object('state', 'gone'); end if;
  end if;
  v_cur := jsonb_build_object('clock_in', l.clock_in, 'clock_out', l.clock_out, 'break_start_1', l.break_start_1, 'break_end_1', l.break_end_1,
                              'break_start_2', l.break_start_2, 'break_end_2', l.break_end_2, 'break_minutes', l.break_minutes);
  if r.kind = 'add' then return jsonb_build_object('state', 'appeared', 'current', v_cur); end if;
  foreach v_col in array c_cols loop
    if date_trunc('minute', nullif(r.before ->> v_col, '')::timestamptz) is distinct from date_trunc('minute', nullif(v_cur ->> v_col, '')::timestamptz) then
      v_same := false;
    end if;
  end loop;
  if v_same then return jsonb_build_object('state', 'same'); end if;
  return jsonb_build_object('state', 'changed', 'current', v_cur);
end $$;
revoke all on function public.sf_attendance_request_source_check(uuid) from public, anon, authenticated;
grant execute on function public.sf_attendance_request_source_check(uuid) to service_role;

-- ============ 6. カード・画面用の読み取り（読むだけ・service_role だけ） ============
--   request は行そのもの（to_jsonb）。第 2 弾で列が増えても、この関数は作り直さなくてよい（flow・stage・first_approver_id などがそのまま入る）
--   names: 出てくる人の id → 氏名／slack: id → Slack のユーザー ID（在職の人だけ）
--   masters: 今の 1 段階の承認者（マスター）／presidents: 社長（役割 CEO）。どちらも在職の人だけ・{user_id, slack_user_id}
create or replace function public.sf_attendance_request_view(p_request_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r sf_attendance_requests%rowtype; j jsonb; v_ids text[];
begin
  select * into r from sf_attendance_requests where id = p_request_id;
  if not found then return null; end if;
  j := to_jsonb(r) - 'smaregi_response';
  v_ids := array_remove(array[r.user_id::text, r.requested_by::text, r.decided_by::text,
                              j ->> 'first_approver_id', j ->> 'first_decided_by', j ->> 'returned_by'], null);
  return jsonb_build_object(
    'request', j,
    'store_name', (select s.name from stores s where s.id = r.store_id),
    'names', (select coalesce(jsonb_object_agg(u.id::text, u.name), '{}'::jsonb) from users u where u.id::text = any(v_ids)),
    'slack', (select coalesce(jsonb_object_agg(k.user_id::text, k.slack_user_id), '{}'::jsonb)
                from user_slack k join users u on u.id = k.user_id
               where u.is_active and u.deactivated_at is null and k.user_id::text = any(v_ids)),
    'masters', (select coalesce(jsonb_agg(jsonb_build_object('user_id', u.id, 'slack_user_id', k.slack_user_id) order by u.id), '[]'::jsonb)
                  from users u left join user_slack k on k.user_id = u.id where u.is_active and coalesce(u.is_master, false)),
    'presidents', (select coalesce(jsonb_agg(jsonb_build_object('user_id', u.id, 'slack_user_id', k.slack_user_id) order by u.id), '[]'::jsonb)
                     from users u left join user_slack k on k.user_id = u.id where u.is_active and u.role = 'CEO'),
    'source', sf_attendance_request_source_check(r.id));
end $$;
revoke all on function public.sf_attendance_request_view(uuid) from public, anon, authenticated;
grant execute on function public.sf_attendance_request_view(uuid) to service_role;

-- トリガー用の関数は、画面から直接は呼べないようにしておく（念のため）
revoke all on function public.sf_attendance_requests_snapshot() from public, anon, authenticated;
revoke all on function public.sf_attendance_requests_event_log() from public, anon, authenticated;
revoke all on function public.sf_attendance_request_events_guard() from public, anon, authenticated;
