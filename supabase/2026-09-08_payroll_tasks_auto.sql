-- 2026-09-08 担当B（nippo）
-- ユーザー要望「給与仕訳のところで給料確定ボタンを作り、押したら本部タスクに
-- 振込・現金手渡しのタスクが自動発行され、それぞれの完了も自動連携されるように
-- したい」に対応するための基盤（RPC）を新設。
--
-- 「給料確定」ボタン自体・振込を個別に完了させたときの呼び出しは、給与仕訳画面
-- （invoices.html・担当C管轄）側の実装が必要。ここではその画面から呼び出すための
-- RPCと、本部タスク（hq_tasks・担当E管轄のテーブル）への橋渡しを用意する
-- （前例: 2026-09-05 担当Cが同じ考え方でhq_create_transfer_taskを新設し、
-- hq_tasks/hq_task_steps/hq_step_checklist_itemsに直接書き込んでいる。今回もその
-- 「タスク1件＋工程1件＋工程内チェックリスト」パターンをそのまま踏襲する）。
--
-- ①jp_is_holiday/jp_prev_business_day: 日本の祝日（土日・固定日・ハッピーマンデー・
--  春分秋分の近似計算・日曜と重なった祝日の振替休日）を判定し、指定日が休みなら
--  さかのぼって直前の営業日を返す。「国民の休日」（祝日に挟まれた平日）は非対応
--  （現行の祝日体系では発生頻度が極めて低いため）。春分・秋分は公式発表ではなく
--  一般的な近似式（1980-2099年で使用実績のある式）による計算のため、将来的に
--  公式発表とズレる可能性が万一あれば都度この関数を調整する。
-- ②payroll_task_links: 「給料確定」で自動発行した本部タスクの年月・種別→
--  タスクID/工程IDの対応表（個々の完了チェックがどのタスクを指すか引くため）。
-- ③hq_create_payroll_tasks(year_month, corp): 給料確定ボタンから呼ぶ想定。
--  振込対象＝payroll_bank_accounts.payment_method<>'cash'の在籍者、
--  現金手渡し対象＝cash_handoff_targets()をそのまま再利用。
--  担当（assignee）は氏名の完全一致（全角/半角スペース差を吸収）で解決。
--  同じ年月・種別で既に発行済みなら重複作成しない（べき等）。
-- ④hq_check_payroll_task_item(year_month, kind, person_name): 振込 or 現金手渡しが
--  個人単位で完了した瞬間に呼ぶ。該当のチェック項目にチェックを入れ、工程内
--  全員分チェックが揃ったら本部タスクの工程を完了扱いにする（既存トリガー
--  hq_task_recalc_statusにより本部タスク本体も自動でstatus='done'になる）。
--  ここで初めて完了状態になった場合のみ、Larkへ完了報告を送る（notify_lark。
--  ai-cockpitのエラー通知等と同じ、共通のLark Webhook宛の汎用関数）。
--  現金手渡し側はcash_handoff_complete（本ファイル末尾で更新）から自動的に
--  呼ばれる。振込側は、給与仕訳画面で個々の振込を完了にする箇所から
--  invoices.html側で呼び出してもらう必要がある（WORKLOG参照）。

create or replace function public.jp_is_national_holiday(p_date date)
returns boolean
language plpgsql
immutable
as $function$
declare
  v_y int := extract(year from p_date)::int;
  v_m int := extract(month from p_date)::int;
  v_d int := extract(day from p_date)::int;
  v_dow int := extract(dow from p_date)::int; -- 0=日,1=月,...,6=土
  v_spring int; v_autumn int;
begin
  if (v_m,v_d) in ((1,1),(2,11),(2,23),(4,29),(5,3),(5,4),(5,5),(8,11),(11,3),(11,23)) then
    return true;
  end if;
  -- ハッピーマンデー: 成人の日(1月第2月)・海の日(7月第3月)・敬老の日(9月第3月)・スポーツの日(10月第2月)
  if v_dow = 1 then
    if (v_m=1 and ceil(v_d/7.0)=2) or (v_m=7 and ceil(v_d/7.0)=3)
       or (v_m=9 and ceil(v_d/7.0)=3) or (v_m=10 and ceil(v_d/7.0)=2) then
      return true;
    end if;
  end if;
  -- 春分の日・秋分の日（近似式）
  v_spring := floor(20.8431 + 0.242194*(v_y-1980)) - floor((v_y-1980)/4.0);
  v_autumn := floor(23.2488 + 0.242194*(v_y-1980)) - floor((v_y-1980)/4.0);
  if (v_m=3 and v_d=v_spring) or (v_m=9 and v_d=v_autumn) then
    return true;
  end if;
  return false;
end;
$function$;

create or replace function public.jp_is_holiday(p_date date)
returns boolean
language sql
immutable
as $function$
  select extract(dow from p_date)::int in (0,6)
    or jp_is_national_holiday(p_date)
    -- 振替休日: 祝日(固定/ハッピーマンデー/春分秋分)が日曜と重なった翌月曜
    or (extract(dow from p_date)::int = 1 and extract(dow from p_date - 1)::int = 0 and jp_is_national_holiday(p_date - 1));
$function$;

create or replace function public.jp_prev_business_day(p_date date)
returns date
language plpgsql
immutable
as $function$
declare v_d date := p_date;
begin
  while jp_is_holiday(v_d) loop
    v_d := v_d - 1;
  end loop;
  return v_d;
end;
$function$;

create table if not exists payroll_task_links (
  year_month text not null,
  kind text not null check (kind in ('transfer','cash')),
  task_id uuid not null references hq_tasks(id),
  step_id uuid not null references hq_task_steps(id),
  created_at timestamptz not null default now(),
  primary key (year_month, kind)
);
comment on table payroll_task_links is '給与仕訳の「給料確定」から自動発行した本部タスクの追跡（担当B・2026-09-08）。年月・種別(transfer/cash)→タスクID/工程IDの対応表';
alter table payroll_task_links enable row level security;
drop policy if exists payroll_task_links_read on payroll_task_links;
create policy payroll_task_links_read on payroll_task_links for select using (
  exists(select 1 from users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO','HQ','TENCHO','TEAM')))
);
-- 書き込みはhq_create_payroll_tasks経由のみ（SECURITY DEFINERがRLSをバイパスして行う）。

create or replace function public.hq_create_payroll_tasks(p_year_month text, p_corp text default 'N-Style')
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_caller users%rowtype;
  v_month_start date; v_mon int;
  v_transfer_due date; v_cash_due date;
  v_transfer_task uuid; v_transfer_step uuid;
  v_cash_task uuid; v_cash_step uuid;
  v_transfer_names text[]; v_cash_names text[];
  v_name text; v_sort int; v_assignees uuid[];
  v_existing payroll_task_links%rowtype;
begin
  select * into v_caller from users u0 where u0.id = auth.uid() and u0.is_active;
  if v_caller.id is null or not (v_caller.is_master or v_caller.role in ('CEO','HQ')) then
    raise exception '権限がありません（マスター・本部・社長のみ）';
  end if;
  if p_year_month !~ '^\d{4}-\d{2}$' then
    raise exception 'year_monthは YYYY-MM 形式で指定してください';
  end if;
  v_month_start := to_date(p_year_month || '-01', 'YYYY-MM-DD');
  v_mon := extract(month from v_month_start)::int;
  v_transfer_due := jp_prev_business_day(v_month_start + 14); -- 15日
  v_cash_due := jp_prev_business_day(v_month_start + 24);     -- 25日

  select array_agg(u.name order by u.name) into v_transfer_names
    from payroll_bank_accounts pba join users u on u.id = pba.user_id
    where pba.payment_method is distinct from 'cash' and u.is_active;
  select array_agg(t.name order by t.name) into v_cash_names
    from cash_handoff_targets(p_year_month) t where t.is_active;

  -- ① 給料振込タスク
  select * into v_existing from payroll_task_links where year_month = p_year_month and kind = 'transfer';
  if v_existing.task_id is not null then
    v_transfer_task := v_existing.task_id;
  elsif v_transfer_names is not null and array_length(v_transfer_names,1) > 0 then
    select coalesce(array_agg(id), array[]::uuid[]) into v_assignees
      from users where is_active and replace(replace(name,' ',''),chr(12288),'') = any(array['青山純','原美香','中山俊士']);
    insert into hq_tasks(title, corp, freq, target_date, due_date, notes, description, visibility, created_by)
    values (v_mon||'月分　給料振込　'||p_corp, p_corp, 'once', current_date, v_transfer_due, '',
      '給料確定ボタンにより自動発行（対象'||array_length(v_transfer_names,1)||'名）', 'all', auth.uid())
    returning id into v_transfer_task;
    insert into hq_task_steps(task_id, title, assignee_ids, due_date, sort_order, kind)
    values (v_transfer_task, '振込完了を確認', v_assignees, v_transfer_due, 10, 'step')
    returning id into v_transfer_step;
    v_sort := 10;
    foreach v_name in array v_transfer_names loop
      insert into hq_step_checklist_items(step_id, title, sort_order) values (v_transfer_step, v_name, v_sort);
      v_sort := v_sort + 10;
    end loop;
    insert into payroll_task_links(year_month, kind, task_id, step_id) values (p_year_month, 'transfer', v_transfer_task, v_transfer_step);
  end if;

  -- ② 現金手渡しタスク
  select * into v_existing from payroll_task_links where year_month = p_year_month and kind = 'cash';
  if v_existing.task_id is not null then
    v_cash_task := v_existing.task_id;
  elsif v_cash_names is not null and array_length(v_cash_names,1) > 0 then
    select coalesce(array_agg(id), array[]::uuid[]) into v_assignees
      from users where is_active and replace(replace(name,' ',''),chr(12288),'') = any(array['青山純','原美香','中山俊士','坂本龍太郎','佐藤俊一','鍋倉巧']);
    insert into hq_tasks(title, corp, freq, target_date, due_date, notes, description, visibility, created_by)
    values (v_mon||'月分　現金手渡し　'||p_corp, p_corp, 'once', current_date, v_cash_due, '',
      '給料確定ボタンにより自動発行（対象'||array_length(v_cash_names,1)||'名）', 'all', auth.uid())
    returning id into v_cash_task;
    insert into hq_task_steps(task_id, title, assignee_ids, due_date, sort_order, kind)
    values (v_cash_task, '手渡し完了を確認', v_assignees, v_cash_due, 10, 'step')
    returning id into v_cash_step;
    v_sort := 10;
    foreach v_name in array v_cash_names loop
      insert into hq_step_checklist_items(step_id, title, sort_order) values (v_cash_step, v_name, v_sort);
      v_sort := v_sort + 10;
    end loop;
    insert into payroll_task_links(year_month, kind, task_id, step_id) values (p_year_month, 'cash', v_cash_task, v_cash_step);
  end if;

  return jsonb_build_object(
    'transfer_task_id', v_transfer_task, 'transfer_due', v_transfer_due, 'transfer_count', coalesce(array_length(v_transfer_names,1),0),
    'cash_task_id', v_cash_task, 'cash_due', v_cash_due, 'cash_count', coalesce(array_length(v_cash_names,1),0)
  );
end;
$function$;
grant execute on function public.hq_create_payroll_tasks(text, text) to authenticated;

create or replace function public.hq_check_payroll_task_item(p_year_month text, p_kind text, p_person_name text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_caller users%rowtype;
  v_link payroll_task_links%rowtype;
  v_item hq_step_checklist_items%rowtype;
  v_total int; v_done int;
  v_task hq_tasks%rowtype;
  v_was_done boolean;
begin
  select * into v_caller from users u0 where u0.id = auth.uid() and u0.is_active;
  if v_caller.id is null or not (v_caller.is_master or v_caller.role in ('CEO','HQ','TENCHO','TEAM')) then
    raise exception '権限がありません';
  end if;
  if p_kind not in ('transfer','cash') then
    raise exception 'kindはtransferかcashを指定してください';
  end if;

  select * into v_link from payroll_task_links where year_month = p_year_month and kind = p_kind;
  if v_link.step_id is null then
    return jsonb_build_object('ok', false, 'reason', '対応する本部タスクが見つかりません（給料確定が未実行の可能性があります）');
  end if;

  select * into v_item from hq_step_checklist_items
   where step_id = v_link.step_id
     and replace(replace(title,' ',''),chr(12288),'') = replace(replace(p_person_name,' ',''),chr(12288),'');
  if v_item.id is null then
    return jsonb_build_object('ok', false, 'reason', p_person_name||' はこのタスクのチェック項目に見つかりません');
  end if;

  if v_item.checked_at is null then
    update hq_step_checklist_items set checked_at = now(), checked_by = auth.uid() where id = v_item.id;
  end if;

  select count(*), count(*) filter (where checked_at is not null) into v_total, v_done
    from hq_step_checklist_items where step_id = v_link.step_id;

  select * into v_task from hq_tasks where id = v_link.task_id;
  v_was_done := v_task.status = 'done';

  if v_total > 0 and v_total = v_done then
    update hq_task_steps set completed_at = coalesce(completed_at, now()), completed_by = coalesce(completed_by, auth.uid())
      where id = v_link.step_id;
    if not v_was_done then
      perform notify_lark('✅ '||v_task.title||' が完了しました（全'||v_total||'件チェック済み）');
    end if;
  end if;

  return jsonb_build_object('ok', true, 'checked', v_done, 'total', v_total);
end;
$function$;
grant execute on function public.hq_check_payroll_task_item(text, text, text) to authenticated;

-- cash_handoff_complete更新: ①既に完了済みの再実行でcompleted_atを上書きしない
-- （Lark二重通知防止のガードのため）②本部タスクのチェックリスト連携
-- ③その月の現金手渡し対象者が全員完了したらLarkへ完了報告
create or replace function public.cash_handoff_complete(p_user_id uuid, p_year_month text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_row sf_cash_handoff_signatures%rowtype;
  v_synced_rows integer := 0;
  v_already_done boolean;
  v_uname text;
  v_total int; v_done int;
begin
  if not exists(select 1 from users where id = auth.uid() and is_active and (
    is_master or role in ('CEO','HQ','TENCHO','TEAM')
  )) then
    raise exception '権限がありません';
  end if;
  select * into v_row from sf_cash_handoff_signatures where user_id = p_user_id and year_month = p_year_month;
  if v_row.id is null then
    raise exception '対象の記録が見つかりません';
  end if;
  if v_row.payer_checked_at is null or v_row.receiver_checked_at is null then
    raise exception '渡した側・受け取った側、両方の確認が必要です';
  end if;

  v_already_done := v_row.completed_at is not null;
  update sf_cash_handoff_signatures set completed_at = coalesce(completed_at, now()), updated_at = now()
   where id = v_row.id;

  begin
    update payroll_journal_records set paid_at = now(), paid_by = auth.uid()
     where user_id = p_user_id and year_month = p_year_month and paid_at is null;
    get diagnostics v_synced_rows = row_count;
  exception when undefined_table then v_synced_rows := 0;
  end;

  if not v_already_done then
    -- 2026-09-08追加: 本部タスク（現金手渡し）のチェックリストを自動で連携
    begin
      select name into v_uname from users where id = p_user_id;
      if v_uname is not null then
        perform hq_check_payroll_task_item(p_year_month, 'cash', v_uname);
      end if;
    exception when others then null; -- 本部タスク未発行等でも現金手渡し自体の完了は止めない
    end;

    -- その月の現金手渡し対象者が全員完了したらLarkへ報告
    begin
      select count(*) into v_total
        from payroll_bank_accounts pba join users u on u.id = pba.user_id
        where pba.payment_method = 'cash' and u.is_active;
      select count(*) into v_done
        from sf_cash_handoff_signatures s
        join payroll_bank_accounts pba on pba.user_id = s.user_id and pba.payment_method = 'cash'
        join users u on u.id = s.user_id and u.is_active
        where s.year_month = p_year_month and s.completed_at is not null;
      if v_total > 0 and v_total = v_done then
        perform notify_lark('💴 現金手渡し完了：'||p_year_month||'分の現金手渡し対象者 全'||v_total||'名の受け渡しが完了しました（nippo「現金手渡し・サイン」）');
      end if;
    exception when others then null;
    end;
  end if;

  return jsonb_build_object('ok', true, 'journal_marked_paid', v_synced_rows > 0);
end;
$function$;
grant execute on function public.cash_handoff_complete(uuid, text) to authenticated;
