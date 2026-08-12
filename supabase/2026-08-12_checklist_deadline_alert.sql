-- =====================================================================
-- 現場チェックシート: 期限（時間）・期限切れアラート・評価区分
-- 画面=日報システム（nippo・現場アプリ）／データ=ハブ
--
-- 【中山さんのご要望】
--  ① チェック項目に期限（時間）をつけられるようにする
--  ② 期限を過ぎても終わっていない項目があれば、担当チーム長に
--     アプリ内通知＋Lark/Chatworkへ即時アラート
--  ③ チーム長が「電話で確認した」ことをアプリ上に記録できる（対応済みにする）
--  ④ 評価区分:「期限内完了」「期限切れ完了（やったが遅れた）」
--    「期限切れ未完了（やっていない）」の3つを区別できるようにする
--
-- 実行場所: Supabase SQL Editor（何度実行しても壊れません）
-- 注意: 2026-08-12_checklist_history.sql を先に実行しておくこと
-- =====================================================================

-- ---------------------------------------------------------------------
-- ① 項目に期限（時刻・任意）を持たせる
-- ---------------------------------------------------------------------
alter table checklist_items add column if not exists due_time time;

-- ---------------------------------------------------------------------
-- ④ 完了が期限に間に合ったかどうかを、チェックした瞬間に記録する
--    （あとで期限を変えても、過去の評価が変わらないようにするため「その時点の期限」で判定して残す）
-- ---------------------------------------------------------------------
alter table checklist_checks add column if not exists late boolean;

create or replace function trg_checklist_check_late() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_due time;
begin
  select due_time into v_due from checklist_items where id = new.item_id;
  if v_due is not null then
    new.late := (new.checked_at at time zone 'Asia/Tokyo')::time > v_due;
  end if;
  return new;
end $$;

drop trigger if exists checklist_checks_late on checklist_checks;
create trigger checklist_checks_late before insert on checklist_checks
  for each row execute function trg_checklist_check_late();

-- ---------------------------------------------------------------------
-- ②③ 期限切れ未完了のアラート（1項目×1店舗×1日 につき1回だけ）
-- ---------------------------------------------------------------------
create table if not exists checklist_overdue_alerts (
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null references checklist_items(id) on delete cascade,
  store_id uuid not null references stores(id) on delete cascade,
  work_date date not null,
  alerted_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid references users(id),
  resolved_note text,
  unique (item_id, store_id, work_date)
);
alter table checklist_overdue_alerts enable row level security;
drop policy if exists ckoa_read on checklist_overdue_alerts;
create policy ckoa_read on checklist_overdue_alerts for select using (auth.uid() is not null);
-- 書き込みは resolve_checklist_alert()／checklist_overdue_check() 経由のみ（直接のinsert/update/deleteは許可しない）

-- チーム長が「対応済みにする」を押したときに呼ぶ
create or replace function resolve_checklist_alert(p_alert_id uuid, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists(
    select 1 from users u where u.id = auth.uid() and u.is_active
      and (u.role in ('CEO','HQ','TEAM','TENCHO') or u.is_master)
  ) then
    raise exception '権限がありません';
  end if;
  update checklist_overdue_alerts
     set resolved_at = now(), resolved_by = auth.uid(),
         resolved_note = nullif(btrim(coalesce(p_note,'')),'')
   where id = p_alert_id and resolved_at is null;
end $$;
grant execute on function resolve_checklist_alert(uuid, text) to authenticated;

-- 5分ごとにGASから呼ばれる点検本体。期限切れ・未完了・未アラートを見つけて、
-- アラート記録を作り、担当チーム長・店長・本部・社長に通知する
-- （Lark/Chatworkへの即時送信は、既存の notifications → trg_lark_notify の仕組みにそのまま乗る。
--   設定 →「🔔 通知を設定する」の画面で、イベント「チェックの期限切れ」を選んだ部屋に届く）
create or replace function checklist_overdue_check(p_secret text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_alerted int := 0; r record; v_body text;
begin
  if p_secret is distinct from '4259598a7ce747d54e2bf84326131129f21eb77f54dfdcdd' then
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
grant execute on function checklist_overdue_check(text) to anon, authenticated;

select 'checklist 期限・アラート 適用完了' as result;
