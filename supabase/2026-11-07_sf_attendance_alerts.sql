-- =============================================================
-- 勤怠確認ボタン（Slack）: 店長が ○/× → ×は修正時刻を入力 → マスターの Slack に承認依頼 → 承認で管理システムに反映（2026-11-07）
-- 状態: ★ 未適用 ★（dry-run 済み・rollback 内で RPC の流れを検証済み。ユーザー承認後に apply_sql.py で適用）
-- 設計: docs/設計書_Slack通知基盤_Phase1_2026-10-29.md §10-5 を「店長=○× or 修正申請 → マスター=承認 → 反映」に変更（ユーザー決定 2026-11-07）
--
-- 流れ:
--   smaregi-attendance-anomaly-check（毎朝の取込後）が異常値（1h以内/13h超/24h超）を sf_attendance_alerts に積み、
--   勤怠確認チャンネル（slack_channels 'kintai.check'＝C0CFQLYUM1Q・店長が参加）へ送る。
--     [○ 合っている] → RPC sf_attendance_alert_confirm      → confirmed
--     [× 修正する]   → モーダル（出勤・退勤・理由）→ RPC sf_attendance_fix_request → fix_requested → マスターへ承認DM
--     [承認]/[却下]  → RPC sf_attendance_fix_decide（is_master のみ）→ approved: labor_cost_daily / attendance_records を更新（手修正ロック）
--   Slack から DB を直接更新しない: 権限・状態・反映はすべて RPC。slack-interact は受付と振り分けのみ。
--
-- 反映の範囲（事実）: スマレジ・タイムカードの打刻 API（timecard.attendances:write）は未申請のため、スマレジ側は直せない。
--   承認で直すのはハブの labor_cost_daily（人件費日次）と attendance_records。スマレジ側は従来どおり手で直す（給与はスマレジ側が正）。
--   翌日以降の同期（当月分の再取込）で元に戻らないよう、手修正した行は BEFORE UPDATE トリガで打刻の値を守る（manual_fixed_at）。
-- =============================================================

-- -------------------------------------------------------------
-- 0. 勤怠確認チャンネル（ユーザー指定 2026-11-07: C0CFQLYUM1Q）。Bot の招待はユーザー作業（/invite @nstyle-notify）
-- -------------------------------------------------------------
insert into slack_channels (channel_key, slack_channel_id, display_name, purpose, replaces)
values ('kintai.check', 'C0CFQLYUM1Q', '#勤怠確認', '勤怠の異常値（1h以内/13h超/24h超）の確認ボタン（○ 合っている / × 修正する）。店長が参加', 'LINE 勤怠異常値アラート（CEO/HQ 宛）と並行')
on conflict (channel_key) do update set slack_channel_id = excluded.slack_channel_id, updated_at = now();

-- -------------------------------------------------------------
-- 1. アラート表
-- -------------------------------------------------------------
create table if not exists sf_attendance_alerts (
  id                      uuid primary key default gen_random_uuid(),
  labor_cost_daily_id     uuid not null references labor_cost_daily(id) on delete cascade,
  user_id                 uuid not null references users(id),          -- 対象スタッフ
  store_id                uuid not null references stores(id),
  work_date               date not null,
  clock_in                timestamptz,                                  -- 検知時点の値
  clock_out               timestamptz,
  worked_minutes          numeric,
  kind                    text not null check (kind in ('short','long','extreme')),
  status                  text not null default 'open'
                          check (status in ('open','confirmed','fix_requested','approved','rejected','cancelled')),
  notification_ids        uuid[] not null default '{}',                 -- 店長向けメッセージ（複数可）
  approval_notification_ids uuid[] not null default '{}',               -- マスター向け承認メッセージ
  confirmed_by            uuid references users(id),
  confirmed_at            timestamptz,
  proposed_clock_in       timestamptz,
  proposed_clock_out      timestamptz,
  fix_reason              text,
  requested_by            uuid references users(id),
  requested_at            timestamptz,
  decided_by              uuid references users(id),
  decided_at              timestamptz,
  decision_note           text,
  applied_at              timestamptz,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  constraint sf_attendance_alerts_lcd_uq unique (labor_cost_daily_id)
);
create index if not exists sf_attendance_alerts_status_idx on sf_attendance_alerts (status, created_at desc);
create index if not exists sf_attendance_alerts_store_idx on sf_attendance_alerts (store_id, work_date);
comment on table sf_attendance_alerts is '勤怠の異常値アラート（Slack ○×ボタン → 修正申請 → マスター承認 → 反映）。状態遷移は RPC のみ';

alter table sf_attendance_alerts enable row level security;
drop policy if exists sf_attendance_alerts_read on sf_attendance_alerts;
create policy sf_attendance_alerts_read on sf_attendance_alerts for select using (
  auth.uid() is not null and (user_id = auth.uid() or sf_can_manage(store_id))
);
-- 書き込みポリシーは作らない（service_role＝Edge Function と RPC だけ）

-- -------------------------------------------------------------
-- 2. labor_cost_daily の手修正ロック（担当D管轄の表。列追加＋トリガのみ。既存列・同期ロジックは無変更）
-- -------------------------------------------------------------
alter table labor_cost_daily
  add column if not exists manual_fixed_at   timestamptz,
  add column if not exists manual_fixed_by   uuid references users(id),
  add column if not exists manual_fix_alert_id uuid,
  add column if not exists orig_clock_in     timestamptz,
  add column if not exists orig_clock_out    timestamptz,
  add column if not exists orig_worked_minutes numeric,
  add column if not exists orig_smaregi_estimate_cost numeric;
comment on column labor_cost_daily.manual_fixed_at is 'Slack 承認で手修正した時刻。非 NULL の行は同期の upsert で打刻の値が上書きされない（トリガ）。解除は manual_fixed_at を NULL にする update';

create or replace function public.labor_cost_daily_keep_manual_fix()
returns trigger language plpgsql as $$
begin
  -- 手修正済みの行に、manual_fixed_at を変えない更新（＝同期の upsert）が来たら打刻の値を守る
  if old.manual_fixed_at is not null and new.manual_fixed_at is not distinct from old.manual_fixed_at then
    new.clock_in := old.clock_in;
    new.clock_out := old.clock_out;
    new.worked_minutes := old.worked_minutes;
    new.smaregi_estimate_cost := old.smaregi_estimate_cost;
    new.tardy := old.tardy;
    new.early_leaving := old.early_leaving;
  end if;
  return new;
end $$;
drop trigger if exists labor_cost_daily_keep_manual_fix on labor_cost_daily;
create trigger labor_cost_daily_keep_manual_fix before update on labor_cost_daily
  for each row execute function public.labor_cost_daily_keep_manual_fix();

-- -------------------------------------------------------------
-- 3. 権限ヘルパー（sf_can_manage と同じ規則を、auth.uid() の代わりに p_actor で判定。service_role から呼ぶため）
-- -------------------------------------------------------------
create or replace function public.sf_can_manage_as(p_actor uuid, p_store_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((
    select case
      when u.is_master or u.role in ('CEO','HQ','TEAM') then true
      when u.role = 'TENCHO' then exists (select 1 from user_stores us where us.user_id = u.id and us.store_id = p_store_id)
      else false
    end
    from users u where u.id = p_actor and u.is_active
  ), false);
$$;
revoke all on function public.sf_can_manage_as(uuid, uuid) from public, anon, authenticated;
grant execute on function public.sf_can_manage_as(uuid, uuid) to service_role;

-- 表示用の要約（Slack 本文に使う。例: 11/6（金）　鳥一代 本店　中山 俊士　10:00−翌10:00（24時間0分））
create or replace function public.sf_attendance_alert_summary(p_alert sf_attendance_alerts)
returns text language sql stable set search_path = public as $$
  select format('%s（%s）　%s　%s　%s−%s（%s）',
    to_char(p_alert.work_date, 'FMMM/FMDD'),
    (array['日','月','火','水','木','金','土'])[extract(dow from p_alert.work_date)::int + 1],
    (select name from stores where id = p_alert.store_id),
    (select name from users where id = p_alert.user_id),
    to_char(p_alert.clock_in at time zone 'Asia/Tokyo', 'HH24:MI'),
    case when (p_alert.clock_out at time zone 'Asia/Tokyo')::date > p_alert.work_date then '翌' else '' end
      || to_char(p_alert.clock_out at time zone 'Asia/Tokyo', 'HH24:MI'),
    (floor(coalesce(p_alert.worked_minutes,0) / 60))::int || '時間' || (coalesce(p_alert.worked_minutes,0)::int % 60) || '分');
$$;

-- -------------------------------------------------------------
-- 4. RPC ① ○ 合っている
-- -------------------------------------------------------------
create or replace function public.sf_attendance_alert_confirm(p_alert_id uuid, p_actor uuid, p_via text default 'slack')
returns jsonb language plpgsql security definer set search_path = public as $$
declare a sf_attendance_alerts%rowtype; v_name text; v_prev text;
begin
  select name into v_name from users where id = p_actor and is_active;
  if v_name is null then return jsonb_build_object('ok', false, 'code', 'no_actor', 'message', '操作者が管理システムに見つかりません'); end if;
  select * into a from sf_attendance_alerts where id = p_alert_id for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'この勤怠確認は見つかりません'); end if;
  if a.status <> 'open' then
    select name into v_prev from users where id = coalesce(a.confirmed_by, a.requested_by, a.decided_by);
    return jsonb_build_object('ok', false, 'code', 'already', 'message',
      format('この勤怠確認はすでに処理されています（%s・%s）', a.status, coalesce(v_prev, '-')));
  end if;
  if not (sf_can_manage_as(p_actor, a.store_id) or a.user_id = p_actor) then
    return jsonb_build_object('ok', false, 'code', 'forbidden', 'message', 'この店舗の勤怠を確認する権限がありません');
  end if;
  update sf_attendance_alerts set status = 'confirmed', confirmed_by = p_actor, confirmed_at = now(), updated_at = now() where id = a.id;
  return jsonb_build_object('ok', true, 'alert_id', a.id, 'summary', sf_attendance_alert_summary(a), 'actor_name', v_name,
    'notification_ids', to_jsonb(a.notification_ids));
end $$;
revoke all on function public.sf_attendance_alert_confirm(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.sf_attendance_alert_confirm(uuid, uuid, text) to service_role;

-- -------------------------------------------------------------
-- 5. RPC ② × 修正する（修正申請。反映はしない）
-- -------------------------------------------------------------
create or replace function public.sf_attendance_fix_request(p_alert_id uuid, p_actor uuid, p_clock_in timestamptz, p_clock_out timestamptz, p_reason text, p_via text default 'slack')
returns jsonb language plpgsql security definer set search_path = public as $$
declare a sf_attendance_alerts%rowtype; v_name text; v_prev text; v_min numeric;
begin
  select name into v_name from users where id = p_actor and is_active;
  if v_name is null then return jsonb_build_object('ok', false, 'code', 'no_actor', 'message', '操作者が管理システムに見つかりません'); end if;
  select * into a from sf_attendance_alerts where id = p_alert_id for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'この勤怠確認は見つかりません'); end if;
  if a.status not in ('open', 'confirmed') then
    select name into v_prev from users where id = coalesce(a.requested_by, a.decided_by);
    return jsonb_build_object('ok', false, 'code', 'already', 'message', format('この勤怠確認はすでに処理されています（%s・%s）', a.status, coalesce(v_prev, '-')));
  end if;
  if not sf_can_manage_as(p_actor, a.store_id) then
    return jsonb_build_object('ok', false, 'code', 'forbidden', 'message', 'この店舗の勤怠を修正する権限がありません');
  end if;
  if p_clock_in is null or p_clock_out is null or p_clock_out <= p_clock_in then
    return jsonb_build_object('ok', false, 'code', 'invalid_time', 'message', '退勤は出勤より後の時刻にしてください');
  end if;
  v_min := extract(epoch from (p_clock_out - p_clock_in)) / 60;
  if v_min > 24 * 60 then return jsonb_build_object('ok', false, 'code', 'invalid_time', 'message', '勤務は 24 時間以内にしてください'); end if;
  if (p_clock_in at time zone 'Asia/Tokyo')::date not between a.work_date - 1 and a.work_date + 1 then
    return jsonb_build_object('ok', false, 'code', 'invalid_time', 'message', '出勤日が勤務日と離れすぎています');
  end if;
  if length(coalesce(trim(p_reason), '')) not between 1 and 300 then
    return jsonb_build_object('ok', false, 'code', 'invalid_reason', 'message', '修正理由を 300 字以内で入れてください');
  end if;
  update sf_attendance_alerts
     set status = 'fix_requested', proposed_clock_in = p_clock_in, proposed_clock_out = p_clock_out, fix_reason = trim(p_reason),
         requested_by = p_actor, requested_at = now(), updated_at = now()
   where id = a.id;
  return jsonb_build_object('ok', true, 'alert_id', a.id, 'summary', sf_attendance_alert_summary(a), 'actor_name', v_name,
    'proposed', format('%s−%s（%s時間%s分）',
      to_char(p_clock_in at time zone 'Asia/Tokyo', 'HH24:MI'),
      case when (p_clock_out at time zone 'Asia/Tokyo')::date > (p_clock_in at time zone 'Asia/Tokyo')::date then '翌' else '' end
        || to_char(p_clock_out at time zone 'Asia/Tokyo', 'HH24:MI'),
      floor(v_min / 60)::int, (v_min::int % 60)),
    'reason', trim(p_reason), 'notification_ids', to_jsonb(a.notification_ids));
end $$;
revoke all on function public.sf_attendance_fix_request(uuid, uuid, timestamptz, timestamptz, text, text) from public, anon, authenticated;
grant execute on function public.sf_attendance_fix_request(uuid, uuid, timestamptz, timestamptz, text, text) to service_role;

-- -------------------------------------------------------------
-- 6. RPC ③ 承認 / 却下（is_master のみ）。承認でハブの勤怠実績に反映（手修正ロック付き）
-- -------------------------------------------------------------
create or replace function public.sf_attendance_fix_decide(p_alert_id uuid, p_actor uuid, p_approve boolean, p_note text default null, p_via text default 'slack')
returns jsonb language plpgsql security definer set search_path = public as $$
declare a sf_attendance_alerts%rowtype; v_name text; v_master boolean; v_prev text; v_min numeric; l labor_cost_daily%rowtype; v_est numeric;
begin
  select name, coalesce(is_master, false) into v_name, v_master from users where id = p_actor and is_active;
  if v_name is null then return jsonb_build_object('ok', false, 'code', 'no_actor', 'message', '操作者が管理システムに見つかりません'); end if;
  if not v_master then return jsonb_build_object('ok', false, 'code', 'forbidden', 'message', '承認できるのはマスターだけです'); end if;
  select * into a from sf_attendance_alerts where id = p_alert_id for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'この修正申請は見つかりません'); end if;
  if a.status <> 'fix_requested' then
    select name into v_prev from users where id = a.decided_by;
    return jsonb_build_object('ok', false, 'code', 'already', 'message', format('この修正申請はすでに処理されています（%s・%s）', a.status, coalesce(v_prev, '-')));
  end if;

  if p_approve then
    select * into l from labor_cost_daily where id = a.labor_cost_daily_id for update;
    if not found then return jsonb_build_object('ok', false, 'code', 'no_record', 'message', '元の勤怠実績が見つかりません（同期で消えた可能性）'); end if;
    v_min := round(extract(epoch from (a.proposed_clock_out - a.proposed_clock_in)) / 60);
    -- 概算人件費は時間に比例して付け替える（スマレジ側の修正後は同期で正しい値に置き換わる）
    v_est := case when coalesce(l.worked_minutes, 0) > 0 and l.smaregi_estimate_cost is not null
                  then round(l.smaregi_estimate_cost * v_min / l.worked_minutes) else l.smaregi_estimate_cost end;
    update labor_cost_daily
       set orig_clock_in = coalesce(orig_clock_in, clock_in), orig_clock_out = coalesce(orig_clock_out, clock_out),
           orig_worked_minutes = coalesce(orig_worked_minutes, worked_minutes), orig_smaregi_estimate_cost = coalesce(orig_smaregi_estimate_cost, smaregi_estimate_cost),
           clock_in = a.proposed_clock_in, clock_out = a.proposed_clock_out, worked_minutes = v_min, smaregi_estimate_cost = v_est,
           manual_fixed_at = now(), manual_fixed_by = p_actor, manual_fix_alert_id = a.id, updated_at = now()
     where id = l.id;
    update attendance_records set clock_in = a.proposed_clock_in, clock_out = a.proposed_clock_out
     where user_id = a.user_id and work_date = a.work_date;
    update sf_attendance_alerts set status = 'approved', decided_by = p_actor, decided_at = now(), decision_note = nullif(trim(coalesce(p_note, '')), ''),
           applied_at = now(), updated_at = now() where id = a.id;
  else
    update sf_attendance_alerts set status = 'rejected', decided_by = p_actor, decided_at = now(), decision_note = nullif(trim(coalesce(p_note, '')), ''),
           updated_at = now() where id = a.id;
  end if;
  return jsonb_build_object('ok', true, 'alert_id', a.id, 'approved', p_approve, 'summary', sf_attendance_alert_summary(a), 'actor_name', v_name,
    'proposed', format('%s−%s',
      to_char(a.proposed_clock_in at time zone 'Asia/Tokyo', 'HH24:MI'),
      case when (a.proposed_clock_out at time zone 'Asia/Tokyo')::date > (a.proposed_clock_in at time zone 'Asia/Tokyo')::date then '翌' else '' end
        || to_char(a.proposed_clock_out at time zone 'Asia/Tokyo', 'HH24:MI')),
    'reason', a.fix_reason, 'note', nullif(trim(coalesce(p_note, '')), ''),
    'requested_by_name', (select name from users where id = a.requested_by),
    'notification_ids', to_jsonb(a.notification_ids), 'approval_notification_ids', to_jsonb(a.approval_notification_ids));
end $$;
revoke all on function public.sf_attendance_fix_decide(uuid, uuid, boolean, text, text) from public, anon, authenticated;
grant execute on function public.sf_attendance_fix_decide(uuid, uuid, boolean, text, text) to service_role;

-- 確認用:
-- select id, status, sf_attendance_alert_summary(a.*) from sf_attendance_alerts a order by created_at desc limit 20;
-- select id, work_date, clock_in, clock_out, worked_minutes, manual_fixed_at from labor_cost_daily where manual_fixed_at is not null;
