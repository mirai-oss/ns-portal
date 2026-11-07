-- =============================================================
-- 勤怠確認ボタン④: アラート条件の追加（2026-11-07・ユーザー決定「全店舗共通」）
-- 状態: ★ 未適用 ★（dry-run 済み）
-- 条件（smaregi-attendance-anomaly-check が判定）:
--   short        1 時間以内の勤務
--   long         勤務 12 時間以上（休憩除く）
--   extreme      24 時間超え（旧条件・維持）
--   late_leave   翌朝 6 時以降の退勤
--   no_clock_out 退勤打刻なし（勤務日の翌朝になっても退勤が無い）
--   break_long   休憩が長すぎる（合計 120 分超）／休憩の終了打刻なし
-- =============================================================
alter table sf_attendance_alerts drop constraint if exists sf_attendance_alerts_kind_check;
alter table sf_attendance_alerts add constraint sf_attendance_alerts_kind_check
  check (kind in ('short','long','extreme','late_leave','no_clock_out','break_long'));
alter table sf_attendance_alerts add column if not exists reasons text[];   -- 該当した条件の説明（複数可・表示用）

-- 退勤なし・休憩終了なしでも読める要約
create or replace function public.sf_attendance_break_text(b1s timestamptz, b1e timestamptz, b2s timestamptz, b2e timestamptz)
returns text language sql immutable as $$
  select case when b1s is null and b2s is null then '休憩なし'
    else '休憩 ' || concat_ws('・',
      case when b1s is not null then to_char(b1s at time zone 'Asia/Tokyo', 'HH24:MI') || '−' || coalesce(to_char(b1e at time zone 'Asia/Tokyo', 'HH24:MI'), '終了なし') end,
      case when b2s is not null then to_char(b2s at time zone 'Asia/Tokyo', 'HH24:MI') || '−' || coalesce(to_char(b2e at time zone 'Asia/Tokyo', 'HH24:MI'), '終了なし') end) end
$$;

create or replace function public.sf_attendance_alert_summary(p_alert sf_attendance_alerts)
returns text language sql stable set search_path = public as $$
  select format('%s（%s）　%s　%s　%s−%s（%s・%s）',
    to_char(p_alert.work_date, 'FMMM/FMDD'),
    (array['日','月','火','水','木','金','土'])[extract(dow from p_alert.work_date)::int + 1],
    (select name from stores where id = p_alert.store_id),
    (select name from users where id = p_alert.user_id),
    coalesce(to_char(p_alert.clock_in at time zone 'Asia/Tokyo', 'HH24:MI'), '-'),
    case when p_alert.clock_out is null then '退勤なし' else
      case when (p_alert.clock_out at time zone 'Asia/Tokyo')::date > p_alert.work_date then '翌' else '' end
      || to_char(p_alert.clock_out at time zone 'Asia/Tokyo', 'HH24:MI') end,
    case when p_alert.worked_minutes is null then '-' else
      (floor(p_alert.worked_minutes / 60))::int || '時間' || (p_alert.worked_minutes::int % 60) || '分' end,
    sf_attendance_break_text(p_alert.break_start_1, p_alert.break_end_1, p_alert.break_start_2, p_alert.break_end_2));
$$;

-- -------------------------------------------------------------
-- スマレジ・タイムカード側で直接修正されたときの検知（ユーザー指示 2026-11-07「直接修正されたら困るので同じくアラート」）
-- 毎朝の同期（smaregi-attendance-sync）が、前回取込済みの行と今回の値（出勤・退勤・休憩）を比べ、違えばここに積んで勤怠確認チャンネルへ通知。
-- 手修正ロック中の行（承認反映の直後・書き戻し失敗中）と、退勤がまだ無かった行（勤務の終了は修正ではない）は対象外。
-- -------------------------------------------------------------
create table if not exists sf_attendance_smaregi_changes (
  id                  uuid primary key default gen_random_uuid(),
  labor_cost_daily_id uuid not null references labor_cost_daily(id) on delete cascade,
  user_id             uuid not null references users(id),
  store_id            uuid not null references stores(id),
  work_date           date not null,
  before              jsonb not null,            -- {clock_in, clock_out, break_start_1, …}
  after               jsonb not null,
  diff_text           text not null,             -- 表示用（出勤 10:00 → 10:30／…）
  status              text not null default 'open' check (status in ('open','acknowledged')),
  acknowledged_by     uuid references users(id),
  acknowledged_at     timestamptz,
  notification_ids    uuid[] not null default '{}',
  detected_at         timestamptz not null default now(),
  created_at          timestamptz not null default now()
);
create index if not exists sf_attendance_smaregi_changes_status_idx on sf_attendance_smaregi_changes (status, detected_at desc);
create index if not exists sf_attendance_smaregi_changes_lcd_idx on sf_attendance_smaregi_changes (labor_cost_daily_id);
alter table sf_attendance_smaregi_changes enable row level security;
drop policy if exists sf_attendance_smaregi_changes_read on sf_attendance_smaregi_changes;
create policy sf_attendance_smaregi_changes_read on sf_attendance_smaregi_changes for select using (
  auth.uid() is not null and (user_id = auth.uid() or sf_can_manage(store_id))
);

create or replace function public.sf_attendance_change_ack(p_change_id uuid, p_actor uuid, p_via text default 'slack')
returns jsonb language plpgsql security definer set search_path = public as $$
declare c sf_attendance_smaregi_changes%rowtype; v_name text; v_prev text;
begin
  select name into v_name from users where id = p_actor and is_active;
  if v_name is null then return jsonb_build_object('ok', false, 'code', 'no_actor', 'message', '操作者が管理システムに見つかりません'); end if;
  select * into c from sf_attendance_smaregi_changes where id = p_change_id for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'この変更通知は見つかりません'); end if;
  if c.status <> 'open' then
    select name into v_prev from users where id = c.acknowledged_by;
    return jsonb_build_object('ok', false, 'code', 'already', 'message', format('%s さんが先に確認しています', coalesce(v_prev, '別の人')));
  end if;
  if not sf_can_manage_as(p_actor, c.store_id) then
    return jsonb_build_object('ok', false, 'code', 'forbidden', 'message', 'この店舗の勤怠を確認する権限がありません');
  end if;
  update sf_attendance_smaregi_changes set status = 'acknowledged', acknowledged_by = p_actor, acknowledged_at = now() where id = c.id;
  return jsonb_build_object('ok', true, 'change_id', c.id, 'actor_name', v_name, 'diff_text', c.diff_text,
    'summary', format('%s（%s）　%s　%s', to_char(c.work_date, 'FMMM/FMDD'), (array['日','月','火','水','木','金','土'])[extract(dow from c.work_date)::int + 1],
      (select name from stores where id = c.store_id), (select name from users where id = c.user_id)),
    'notification_ids', to_jsonb(c.notification_ids));
end $$;
revoke all on function public.sf_attendance_change_ack(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.sf_attendance_change_ack(uuid, uuid, text) to service_role;
