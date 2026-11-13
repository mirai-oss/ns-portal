-- =============================================================
-- 給与の支払方法を「給与の対象月ごと」に持つ（2026-11-13 ユーザー承認: 実装とテスト。★本番未適用。適用・既存分の移し替えは、報告のあとの別の承認）
--   いま: 支払方法は従業員 1 人に 1 つの現在値（payroll_bank_accounts.payment_method）だけ。過去の月の現金手渡しの対象・完了数・毎朝のお知らせ・給料確定の名簿が
--         現在値で決まるため、現在値を変えると、振込で支払い済みの過去の月まで「現金手渡し・未完了」になっていた。
--   これから:
--     ・表 payroll_month_payments に、従業員×給与の対象月ごとの支払方法を持つ（status: planned＝確定前／fixed＝確定）。
--         9 月: 振込／10 月: 現金／11 月: 振込／12 月: 現金 のように、月ごとに独立して保持する。
--     ・現在値（payroll_bank_accounts.payment_method）は「これからの月の初期値」。月の行が無い月だけ、初期値を使う。
--     ・給料確定（hq_create_payroll_tasks）のとき、その月の全員ぶんを「確定」として書く（振込の人は、そのときの振込先の控えも）。確定後は、ふつうの変更では変わらない。
--     ・確定前の変更（payroll_payment_change）と、確定後の訂正（payroll_month_payment_correct。本部・社長・マスターだけ・理由が必須）は別の処理。
--     ・初期値を変えるとき、それより前の月（給与データがあって、月の行が無い月）は、変える前の支払方法で固定する（過去の月が一緒に変わらないように）。
--     ・現金手渡しの対象（cash_handoff_targets_raw）・完了数（cash_handoff_complete）・毎朝のお知らせ（cash_handoff_incomplete_alert）・給料確定の名簿（hq_create_payroll_tasks）・
--       振込の保留（pay_transfer_pending_holds）は、その月の支払方法（payroll_month_method）で判定する。5 つとも、本番の定義の該当の行だけを置き換えたもの。
--     ・変更の履歴 payroll_month_payment_history（だれが・いつ・どの月・前・後・理由）。同じ内容のくり返しでは、履歴も行も増えない。
--   既存の給与データ・手渡しサインの記録・振込完了の印・本部タスクは書き換えない（訂正の操作のときだけ、名簿のチェック欄を合わせる。済みの印が付いた欄とサインの記録は消さない）。
--   既存の確定済みの月（8〜10 月分）の移し替えは、この SQL では行わない（関数 payroll_month_payments_backfill を用意するだけ。実行は別の承認）。
--     移し替える前は、月の行が無い＝今までどおり初期値で判定される（この SQL を適用しただけでは、いまの表示は変わらない）。
--   先に 2026-11-23a_payroll_bank_keep_account.sql（口座を消さない守り）を適用しておくこと。
--   戻し方: 2026-11-23b_payroll_month_payments_rollback.sql
-- =============================================================

create table if not exists public.payroll_month_payments (
  user_id     uuid not null references public.users(id) on delete cascade,
  year_month  text not null check (year_month ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'),            -- 給与の対象月（スマレジの給与データ sf_payroll_sync.year_month と同じ。支払月ではない）
  method      text not null check (method in ('bank_transfer', 'cash')),
  status      text not null default 'planned' check (status in ('planned', 'fixed')),      -- planned=確定前／fixed=確定（訂正の操作でしか変えられない）
  account     jsonb,                                                                       -- 確定のときの振込先の控え（振込のときだけ。画面からは直接読めない）
  source      text not null default 'manual' check (source in ('manual', 'default_freeze', 'finalize', 'backfill', 'correction')),
  decided_by  uuid,
  decided_at  timestamptz not null default now(),
  fixed_at    timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  primary key (user_id, year_month)
);
create index if not exists payroll_month_payments_ym_idx on public.payroll_month_payments(year_month, method);
comment on table public.payroll_month_payments is '給与の支払方法（従業員×給与の対象月）。確定した月は、現在値（payroll_bank_accounts.payment_method）を変えても変わらない';

create table if not exists public.payroll_month_payment_history (
  id          bigserial primary key,
  user_id     uuid not null,
  year_month  text,                         -- 対象の月（初期値だけの変更のときは、「この月から」の月）
  kind        text not null check (kind in ('month_set', 'default_change', 'default_freeze', 'correction', 'backfill')),
  before      jsonb,                        -- {method, status}
  after       jsonb,
  reason      text,
  changed_by  uuid,
  changed_at  timestamptz not null default now()
);
create index if not exists payroll_month_payment_history_user_idx on public.payroll_month_payment_history(user_id, changed_at);

-- 画面（ログインしている人）からは、表を直接読めない・書けない（口座の控えが入るため）。読むのも書くのも、下の関数だけ
alter table public.payroll_month_payments        enable row level security;
alter table public.payroll_month_payment_history enable row level security;
revoke all on public.payroll_month_payments        from public, anon, authenticated;
revoke all on public.payroll_month_payment_history from public, anon, authenticated;

-- 確定した月の行は、訂正の操作（下の関数）からしか変えられない・消せない
create or replace function public.payroll_month_payments_guard()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if coalesce(current_setting('payroll.month_fix_ok', true), '') = '1' then return coalesce(new, old); end if;
  if tg_op = 'DELETE' then
    if old.status = 'fixed' and pg_trigger_depth() <= 1 then raise exception '確定した月の支払方法は消せません'; end if;
    return old;
  end if;
  if old.status = 'fixed' and (new.method is distinct from old.method or new.status is distinct from old.status or new.account is distinct from old.account) then
    raise exception '確定した月の支払方法は、訂正の操作でしか変えられません';
  end if;
  return new;
end $$;
revoke all on function public.payroll_month_payments_guard() from public, anon, authenticated;
drop trigger if exists payroll_month_payments_guard on public.payroll_month_payments;
create trigger payroll_month_payments_guard before update or delete on public.payroll_month_payments
  for each row execute function public.payroll_month_payments_guard();

-- その月の支払方法（月の行があればそれ。無ければ、いまの初期値）
create or replace function public.payroll_month_method(p_user uuid, p_year_month text)
returns text language sql stable security definer set search_path to 'public' as $$
  select coalesce((select m.method from payroll_month_payments m where m.user_id = p_user and m.year_month = p_year_month),
                  (select b.payment_method from payroll_bank_accounts b where b.user_id = p_user))
$$;
revoke all on function public.payroll_month_method(uuid, text) from public, anon;
grant execute on function public.payroll_month_method(uuid, text) to authenticated, service_role;

-- その人のその月が、給料確定の済んだ月か（その人の給与データがある契約の法人で、確定の印があるか）
create or replace function public.payroll_month_is_finalized(p_user uuid, p_year_month text)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from payroll_finalized f
                  join smaregi_contracts sc on sc.corporation_id = f.corporation_id
                  join sf_payroll_sync sp on sp.contract_id = sc.contract_id and sp.user_id = p_user and sp.year_month = f.year_month
                 where f.year_month = p_year_month)
$$;
revoke all on function public.payroll_month_is_finalized(uuid, text) from public, anon, authenticated;

-- 操作できる人（本部・社長・マスター）
create or replace function public.payroll_pay_can()
returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from users u where u.id = auth.uid() and u.is_active and (coalesce(u.is_master, false) or u.role in ('CEO', 'HQ')))
$$;
revoke all on function public.payroll_pay_can() from public, anon;
grant execute on function public.payroll_pay_can() to authenticated;

-- 口座の控え（振込のときだけ。口座が無ければ null）
create or replace function public.payroll_account_snapshot(p_user uuid)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select case when b.account_number is null then null else
    jsonb_build_object('bank_code', b.bank_code, 'bank_name', b.bank_name, 'branch_code', b.branch_code, 'branch_name', b.branch_name,
                       'account_type', b.account_type, 'account_number', b.account_number, 'account_holder_kana', b.account_holder_kana) end
    from payroll_bank_accounts b where b.user_id = p_user
$$;
revoke all on function public.payroll_account_snapshot(uuid) from public, anon, authenticated;

-- 給料確定のとき: その月の支払方法を「確定」として書く（確定前に決めてあった月の行はその内容で確定・無い人はいまの初期値）。すでに確定の行は触らない＝くり返しても同じ
create or replace function public.payroll_month_payments_fix(p_year_month text, p_contracts text[])
returns integer language plpgsql security definer set search_path to 'public' as $$
declare n integer := 0; r record;
begin
  for r in
    select distinct sp.user_id, public.payroll_month_method(sp.user_id, p_year_month) as method
      from sf_payroll_sync sp
     where sp.year_month = p_year_month and (p_contracts is null or sp.contract_id = any(p_contracts))
  loop
    if r.method is null then continue; end if;   -- 口座の行も月の行も無い人（支払方法が未登録）: 今までどおり、どちらの名簿にも入らない
    insert into payroll_month_payments(user_id, year_month, method, status, account, source, decided_by, fixed_at)
    values (r.user_id, p_year_month, r.method, 'fixed', case when r.method = 'bank_transfer' then public.payroll_account_snapshot(r.user_id) end, 'finalize', auth.uid(), now())
    on conflict (user_id, year_month) do update
       set status = 'fixed', fixed_at = now(), updated_at = now(),
           account = case when payroll_month_payments.method = 'bank_transfer' then public.payroll_account_snapshot(payroll_month_payments.user_id) end
     where payroll_month_payments.status <> 'fixed';
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.payroll_month_payments_fix(text, text[]) from public, anon, authenticated;

-- 確定前の変更: 「◯月分から」を指定して支払方法を変える。p_set_default=true なら、これからの月の初期値も変える（口座の情報は変えない・消さない）。
--   その月が確定済みなら、ここでは変えられない（訂正の操作を使う）。初期値を変えるとき、それより前の月は、変える前の支払方法で固定する
create or replace function public.payroll_payment_change(p_user uuid, p_year_month text, p_method text, p_set_default boolean default true, p_reason text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare b payroll_bank_accounts%rowtype; m payroll_month_payments%rowtype; v_old text; v_frozen text[] := '{}'; r record; v_default_changed boolean := false; v_month_changed boolean := false; v_fin boolean;
begin
  if not public.payroll_pay_can() then raise exception '権限がありません（本部・社長・マスターのみ）'; end if;
  if p_method not in ('bank_transfer', 'cash') then raise exception '支払方法は、銀行振込か現金手渡しを指定してください'; end if;
  if p_year_month is null or p_year_month !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then raise exception '対象の月を YYYY-MM で指定してください'; end if;
  if not exists (select 1 from users u where u.id = p_user) then raise exception '従業員が見つかりません'; end if;
  select * into b from payroll_bank_accounts where user_id = p_user for update;
  select * into m from payroll_month_payments where user_id = p_user and year_month = p_year_month for update;
  if m.status = 'fixed' or (m.user_id is null and public.payroll_month_is_finalized(p_user, p_year_month)) then
    raise exception '%分は給料が確定済みです。確定済みの月は、訂正の操作（理由が必要）で直してください', p_year_month;
  end if;
  v_old := coalesce(m.method, b.payment_method);

  -- 初期値を変えるとき: それより前の月（給与データがあって月の行が無い月）を、変える前の支払方法で固定する
  if coalesce(p_set_default, true) and b.user_id is not null and b.payment_method is not null and b.payment_method <> p_method then
    for r in select distinct sp.year_month from sf_payroll_sync sp
              where sp.user_id = p_user and sp.year_month < p_year_month
                and not exists (select 1 from payroll_month_payments x where x.user_id = p_user and x.year_month = sp.year_month)
              order by sp.year_month loop
      v_fin := public.payroll_month_is_finalized(p_user, r.year_month);
      insert into payroll_month_payments(user_id, year_month, method, status, account, source, decided_by, fixed_at)
      values (p_user, r.year_month, b.payment_method, case when v_fin then 'fixed' else 'planned' end,
              case when b.payment_method = 'bank_transfer' and v_fin then public.payroll_account_snapshot(p_user) end, 'default_freeze', auth.uid(), case when v_fin then now() end);
      insert into payroll_month_payment_history(user_id, year_month, kind, before, after, reason, changed_by)
      values (p_user, r.year_month, 'default_freeze', null, jsonb_build_object('method', b.payment_method, 'status', case when v_fin then 'fixed' else 'planned' end),
              '初期値を変える前の支払方法で固定（' || p_year_month || '分からの変更にともなう）', auth.uid());
      v_frozen := array_append(v_frozen, r.year_month);
    end loop;
  end if;

  -- その月の行
  if m.user_id is null then
    insert into payroll_month_payments(user_id, year_month, method, status, source, decided_by) values (p_user, p_year_month, p_method, 'planned', 'manual', auth.uid());
    v_month_changed := v_old is distinct from p_method or true;
  elsif m.method <> p_method then
    update payroll_month_payments set method = p_method, source = 'manual', decided_by = auth.uid(), decided_at = now(), updated_at = now() where user_id = p_user and year_month = p_year_month;
    v_month_changed := true;
  end if;
  if v_month_changed and (m.user_id is null or m.method <> p_method) and v_old is distinct from p_method then
    insert into payroll_month_payment_history(user_id, year_month, kind, before, after, reason, changed_by)
    values (p_user, p_year_month, 'month_set', jsonb_build_object('method', v_old), jsonb_build_object('method', p_method, 'status', 'planned'), nullif(left(btrim(coalesce(p_reason, '')), 500), ''), auth.uid());
  end if;

  -- これからの月の初期値（口座の列は触らない）。口座の「申請 → 承認」の関所（bank_approval_required）が有効なときは、関所がこの書き込みを止める＝承認のルールを迂回しない
  --   （そのときは p_set_default=false で「その月だけ」を変えるか、申請 → 承認の流れを使う）
  if coalesce(p_set_default, true) then
    if b.user_id is null then
      insert into payroll_bank_accounts(user_id, payment_method, account_type, updated_by, updated_at) values (p_user, p_method, '1', auth.uid(), now());
      v_default_changed := true;
    elsif b.payment_method is distinct from p_method then
      update payroll_bank_accounts set payment_method = p_method, updated_by = auth.uid(), updated_at = now() where user_id = p_user;
      v_default_changed := true;
    end if;
    if v_default_changed then
      insert into payroll_month_payment_history(user_id, year_month, kind, before, after, reason, changed_by)
      values (p_user, p_year_month, 'default_change', jsonb_build_object('method', b.payment_method), jsonb_build_object('method', p_method), nullif(left(btrim(coalesce(p_reason, '')), 500), ''), auth.uid());
    end if;
  end if;
  return jsonb_build_object('ok', true, 'year_month', p_year_month, 'method', p_method, 'default_changed', v_default_changed, 'frozen_months', to_jsonb(v_frozen),
                            'unchanged', not v_default_changed and not (m.user_id is null or m.method <> p_method));
end $$;
revoke all on function public.payroll_payment_change(uuid, text, text, boolean, text) from public, anon;
grant execute on function public.payroll_payment_change(uuid, text, text, boolean, text) to authenticated;

-- 確定後の訂正: 権限のある人が、理由を入れて、確定済みの月の支払方法を直す。このときだけ、その月の名簿（本部タスクのチェック欄）を合わせる。
--   済みの印が付いたチェック欄・手渡しサインの記録・振込完了の記録は消さない
create or replace function public.payroll_month_payment_correct(p_user uuid, p_year_month text, p_method text, p_reason text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare m payroll_month_payments%rowtype; v_old text; v_name text; v_corp uuid; v_new_kind text; v_old_kind text; v_link payroll_task_links%rowtype; v_added boolean := false; v_removed integer := 0; v_sort integer;
begin
  if not public.payroll_pay_can() then raise exception '権限がありません（本部・社長・マスターのみ）'; end if;
  if p_method not in ('bank_transfer', 'cash') then raise exception '支払方法は、銀行振込か現金手渡しを指定してください'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception '訂正の理由を入れてください'; end if;
  select * into m from payroll_month_payments where user_id = p_user and year_month = p_year_month for update;
  if not (m.status = 'fixed' or (m.user_id is null and public.payroll_month_is_finalized(p_user, p_year_month))) then
    raise exception '%分はまだ確定していません。確定前の月は、ふつうの変更で直してください', p_year_month;
  end if;
  v_old := public.payroll_month_method(p_user, p_year_month);
  if m.status = 'fixed' and m.method = p_method then return jsonb_build_object('ok', true, 'unchanged', true); end if;

  perform set_config('payroll.month_fix_ok', '1', true);
  insert into payroll_month_payments(user_id, year_month, method, status, account, source, decided_by, fixed_at)
  values (p_user, p_year_month, p_method, 'fixed', case when p_method = 'bank_transfer' then public.payroll_account_snapshot(p_user) end, 'correction', auth.uid(), now())
  on conflict (user_id, year_month) do update
     set method = excluded.method, status = 'fixed', account = excluded.account, source = 'correction', decided_by = auth.uid(), decided_at = now(), fixed_at = coalesce(payroll_month_payments.fixed_at, now()), updated_at = now();
  perform set_config('payroll.month_fix_ok', '', true);
  insert into payroll_month_payment_history(user_id, year_month, kind, before, after, reason, changed_by)
  values (p_user, p_year_month, 'correction', jsonb_build_object('method', v_old, 'status', coalesce(m.status, 'default')), jsonb_build_object('method', p_method, 'status', 'fixed'), left(btrim(p_reason), 500), auth.uid());

  -- 名簿（本部タスクのチェック欄）を合わせる: 新しい側に名前が無ければ足す／古い側の「まだ済みでない」欄だけ外す
  if v_old is distinct from p_method then
    select u.name into v_name from users u where u.id = p_user;
    select sc.corporation_id into v_corp from sf_payroll_sync sp join smaregi_contracts sc on sc.contract_id = sp.contract_id
     where sp.user_id = p_user and sp.year_month = p_year_month order by sp.net_pay desc nulls last limit 1;
    v_new_kind := case when p_method = 'cash' then 'cash' else 'transfer' end; v_old_kind := case when p_method = 'cash' then 'transfer' else 'cash' end;
    select * into v_link from payroll_task_links where year_month = p_year_month and kind = v_new_kind and corporation_id = v_corp;
    if v_link.step_id is not null and v_name is not null
       and not exists (select 1 from hq_step_checklist_items c where c.step_id = v_link.step_id and replace(replace(c.title, ' ', ''), chr(12288), '') = replace(replace(v_name, ' ', ''), chr(12288), '')) then
      select coalesce(max(c.sort_order), 0) + 10 into v_sort from hq_step_checklist_items c where c.step_id = v_link.step_id;
      insert into hq_step_checklist_items(step_id, title, sort_order) values (v_link.step_id, v_name, v_sort);
      v_added := true;
    end if;
    select * into v_link from payroll_task_links where year_month = p_year_month and kind = v_old_kind and corporation_id = v_corp;
    if v_link.step_id is not null and v_name is not null then
      delete from hq_step_checklist_items c where c.step_id = v_link.step_id and c.checked_at is null
         and replace(replace(c.title, ' ', ''), chr(12288), '') = replace(replace(v_name, ' ', ''), chr(12288), '');
      get diagnostics v_removed = row_count;
    end if;
  end if;
  return jsonb_build_object('ok', true, 'year_month', p_year_month, 'before', v_old, 'method', p_method, 'task_item_added', v_added, 'task_items_removed', v_removed);
end $$;
revoke all on function public.payroll_month_payment_correct(uuid, text, text, text) from public, anon;
grant execute on function public.payroll_month_payment_correct(uuid, text, text, text) to authenticated;

-- 画面用: その人の、月ごとの支払方法と履歴（口座番号・金額は返さない）
create or replace function public.payroll_month_payment_status(p_user uuid, p_months integer default 8)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_can boolean; b payroll_bank_accounts%rowtype; v_months jsonb; v_hist jsonb;
begin
  v_can := public.payroll_pay_can();
  if not v_can then raise exception '権限がありません（本部・社長・マスターのみ）'; end if;
  select * into b from payroll_bank_accounts where user_id = p_user;
  select coalesce(jsonb_agg(x.j order by x.ym desc), '[]'::jsonb) into v_months from (
    select ms.ym, jsonb_build_object(
        'year_month', ms.ym,
        'method', public.payroll_month_method(p_user, ms.ym),
        'status', case when mp.status is not null then mp.status when public.payroll_month_is_finalized(p_user, ms.ym) then 'fixed' else 'default' end,
        'recorded', mp.user_id is not null, 'source', mp.source,
        'has_payroll', exists (select 1 from sf_payroll_sync sp where sp.user_id = p_user and sp.year_month = ms.ym),
        'finalized', public.payroll_month_is_finalized(p_user, ms.ym),
        'cash_sign', (select jsonb_build_object('exists', true, 'completed', bool_or(g.completed_at is not null)) from sf_cash_handoff_signatures g where g.user_id = p_user and g.year_month = ms.ym having count(*) > 0)) as j
      from (select to_char(d, 'YYYY-MM') as ym from generate_series(date_trunc('month', current_date) - make_interval(months => greatest(coalesce(p_months, 8), 1) - 2), date_trunc('month', current_date) + interval '1 month', interval '1 month') d) ms
      left join payroll_month_payments mp on mp.user_id = p_user and mp.year_month = ms.ym) x;
  select coalesce(jsonb_agg(jsonb_build_object('at', h.changed_at, 'by_name', (select u.name from users u where u.id = h.changed_by), 'year_month', h.year_month, 'kind', h.kind,
           'before', h.before ->> 'method', 'after', h.after ->> 'method', 'reason', h.reason) order by h.changed_at desc, h.id desc), '[]'::jsonb) into v_hist
    from (select * from payroll_month_payment_history hh where hh.user_id = p_user order by hh.changed_at desc, hh.id desc limit 20) h;
  return jsonb_build_object('ok', true, 'default_method', b.payment_method, 'has_account', b.account_number is not null,
    'account_inactive', b.account_number is not null and b.payment_method = 'cash', 'can_edit', v_can, 'can_correct', v_can, 'months', v_months, 'history', v_hist);
end $$;
revoke all on function public.payroll_month_payment_status(uuid, integer) from public, anon;
grant execute on function public.payroll_month_payment_status(uuid, integer) to authenticated;

-- 画面用（給与の仕訳・振込の画面）: その月の全員ぶんの支払方法（月の行がある人だけ。無い人は、画面が今までどおり初期値を使う）
create or replace function public.payroll_month_methods(p_year_month text)
returns table(user_id uuid, method text, status text) language sql stable security definer set search_path to 'public' as $$
  select m.user_id, m.method, m.status from payroll_month_payments m
   where m.year_month = p_year_month and (public.payroll_pay_can() or public.onboarding_is_service())
$$;
revoke all on function public.payroll_month_methods(text) from public, anon;
grant execute on function public.payroll_month_methods(text) to authenticated, service_role;

-- 既存の確定済みの月の移し替え（★ここでは呼ばない。p_apply=false は案を返すだけ。true で、食い違いの無い分だけ「確定」の行を足す。既存のデータは書き換えない）
--   証拠: 振込の名簿（本部タスクのチェック欄）と「振込完了」の印／現金手渡しの名簿・手渡しサインの記録。
--   両方に証拠がある・証拠が無い・証拠がまだ途中で今の初期値と食い違う、は自動で決めない（確認待ちの一覧に出す）
create or replace function public.payroll_month_payments_backfill(p_apply boolean default false)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare r record; v_t boolean; v_tc boolean; v_c boolean; v_sign boolean; v_done boolean; v_method text; v_def text; n_t int := 0; n_c int := 0; n_skip int := 0; v_hold jsonb := '[]'::jsonb; nm text;
begin
  if not (public.onboarding_is_service() or public.payroll_pay_can()) then raise exception '権限がありません'; end if;
  for r in
    select distinct f.year_month, f.corporation_id, sp.user_id
      from payroll_finalized f join smaregi_contracts sc on sc.corporation_id = f.corporation_id
      join sf_payroll_sync sp on sp.contract_id = sc.contract_id and sp.year_month = f.year_month and coalesce(sp.net_pay, 0) > 0
     where not exists (select 1 from payroll_month_payments m where m.user_id = sp.user_id and m.year_month = f.year_month)
     order by f.year_month, sp.user_id
  loop
    select replace(replace(u.name, ' ', ''), chr(12288), '') into nm from users u where u.id = r.user_id;
    select count(*) > 0, coalesce(bool_or(c.checked_at is not null), false) into v_t, v_tc from payroll_task_links l join hq_step_checklist_items c on c.step_id = l.step_id
     where l.year_month = r.year_month and l.kind = 'transfer' and l.corporation_id = r.corporation_id and replace(replace(c.title, ' ', ''), chr(12288), '') = nm;
    select count(*) > 0 into v_c from payroll_task_links l join hq_step_checklist_items c on c.step_id = l.step_id
     where l.year_month = r.year_month and l.kind = 'cash' and l.corporation_id = r.corporation_id and replace(replace(c.title, ' ', ''), chr(12288), '') = nm;
    select count(*) > 0, coalesce(bool_or(g.completed_at is not null), false) into v_sign, v_done from sf_cash_handoff_signatures g where g.user_id = r.user_id and g.year_month = r.year_month;
    select b.payment_method into v_def from payroll_bank_accounts b where b.user_id = r.user_id;
    v_method := case when v_t and not (v_c or v_sign) then 'bank_transfer' when (v_c or v_sign) and not v_t then 'cash' else null end;
    if v_method is null
       or (v_method = 'bank_transfer' and not v_tc and v_def is distinct from 'bank_transfer')
       or (v_method = 'cash' and not v_done and v_def is distinct from 'cash') then
      v_hold := v_hold || jsonb_build_array(jsonb_build_object('user_id', r.user_id, 'year_month', r.year_month, 'in_transfer_list', v_t, 'transfer_checked', v_tc,
                  'in_cash_list', v_c, 'cash_sign', v_sign, 'cash_sign_completed', v_done, 'default_now', v_def,
                  'why', case when v_t and (v_c or v_sign) then '振込の名簿と現金手渡しの両方に記録がある' when not v_t and not v_c and not v_sign then '名簿にもサインにも記録が無い' else '支払いがまだ済んでおらず、いまの初期値と食い違う' end));
      n_skip := n_skip + 1; continue;
    end if;
    if v_method = 'cash' then n_c := n_c + 1; else n_t := n_t + 1; end if;
    if coalesce(p_apply, false) then
      insert into payroll_month_payments(user_id, year_month, method, status, account, source, decided_by, fixed_at)
      values (r.user_id, r.year_month, v_method, 'fixed', case when v_method = 'bank_transfer' then public.payroll_account_snapshot(r.user_id) end, 'backfill', auth.uid(), now())
      on conflict (user_id, year_month) do nothing;
      insert into payroll_month_payment_history(user_id, year_month, kind, before, after, reason, changed_by)
      values (r.user_id, r.year_month, 'backfill', null, jsonb_build_object('method', v_method, 'status', 'fixed'), '既存の確定済みの月を、名簿とサインの記録から移し替え', auth.uid());
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'applied', coalesce(p_apply, false), 'bank_transfer', n_t, 'cash', n_c, 'needs_confirmation', n_skip, 'hold', v_hold);
end $$;
revoke all on function public.payroll_month_payments_backfill(boolean) from public, anon, authenticated;
grant execute on function public.payroll_month_payments_backfill(boolean) to service_role;

-- ---- ここから下は、本番の定義の「現在値で判定している行」だけを、その月の支払方法（payroll_month_method）に置き換えたもの ----
CREATE OR REPLACE FUNCTION public.cash_handoff_targets_raw(p_year_month text)
 RETURNS TABLE(user_id uuid, name text, store_id uuid, amount numeric, is_active boolean, contract_id text, corp_name text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_caller users%rowtype; v_stores uuid[]; v_scope text; v_def text;
begin
  select * into v_caller from users u0 where u0.id = auth.uid() and u0.is_active;
  if v_caller.id is null or not (v_caller.is_master or v_caller.role in ('CEO','HQ','TENCHO','TEAM')) then
    raise exception '権限がありません';
  end if;
  if v_caller.is_master then
    v_stores := null;
  else
    select scope into v_scope from cash_handoff_role_scope where role = v_caller.role;
    v_scope := coalesce(v_scope, 'own');
    if v_scope = 'all' then v_stores := null;
    elsif v_scope = 'team' then v_stores := team_store_ids(v_caller.team_id) || user_store_ids(v_caller.id);
    else v_stores := user_store_ids(v_caller.id);
    end if;
  end if;
  select sc.contract_id into v_def from smaregi_contracts sc where sc.is_default limit 1;
  return query
    select u.id, u.name,
      (select us.store_id from user_stores us where us.user_id = u.id order by us.is_primary desc limit 1),
      coalesce(s.amt, 0), u.is_active, coalesce(s.contract_id, v_def),
      (select c.name from smaregi_contracts sc2 join corporations c on c.id = sc2.corporation_id where sc2.contract_id = coalesce(s.contract_id, v_def))
    from payroll_bank_accounts pba
    join users u on u.id = pba.user_id
    left join (select sp.user_id, sp.contract_id, sum(sp.net_pay) as amt
                 from sf_payroll_sync sp where sp.year_month = p_year_month group by sp.user_id, sp.contract_id) s on s.user_id = u.id
    where public.payroll_month_method(pba.user_id, p_year_month) = 'cash'   -- 2026-11-23: その月の支払方法で判定（現在値では決めない）
      and (v_stores is null or (select us2.store_id from user_stores us2 where us2.user_id = u.id order by us2.is_primary desc limit 1) = any(v_stores));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.cash_handoff_complete(p_user_id uuid, p_year_month text, p_contract_id text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_row sf_cash_handoff_signatures%rowtype; v_synced_rows integer := 0; v_contract text; v_tenant text;
  v_already_done boolean; v_uname text; v_total int; v_done int; v_corp uuid; v_corp_name text; v_def text; v_chk jsonb;
begin
  if not exists(select 1 from users where id = auth.uid() and is_active and (is_master or role in ('CEO','HQ','TENCHO','TEAM'))) then
    raise exception '権限がありません';
  end if;
  select sc.contract_id into v_def from smaregi_contracts sc where sc.is_default limit 1;
  v_contract := coalesce(p_contract_id, v_def);
  select * into v_row from sf_cash_handoff_signatures where user_id = p_user_id and year_month = p_year_month and contract_id = v_contract;
  if v_row.id is null then raise exception '対象の記録が見つかりません'; end if;
  if v_row.payer_checked_at is null or v_row.receiver_checked_at is null then
    raise exception '渡した側・受け取った側、両方の確認が必要です';
  end if;

  v_already_done := v_row.completed_at is not null;                                    -- (a) 復元
  update sf_cash_handoff_signatures set completed_at = coalesce(completed_at, now()), updated_at = now() where id = v_row.id;

  select case sc.corporation_hint when 'toho' then 'default' else sc.corporation_hint end, sc.corporation_id, c.name
    into v_tenant, v_corp, v_corp_name
    from smaregi_contracts sc left join corporations c on c.id = sc.corporation_id where sc.contract_id = v_contract;
  begin
    update payroll_journal_records set paid_at = now(), paid_by = auth.uid()
     where user_id = p_user_id and year_month = p_year_month and paid_at is null
       and (v_tenant is null or tenant_id = v_tenant);
    get diagnostics v_synced_rows = row_count;
  exception when undefined_table then v_synced_rows := 0;
  end;

  if not v_already_done then
    begin                                                                              -- (b) 復元: 本部タスクのチェックリスト連携（法人別）
      select name into v_uname from users where id = p_user_id;
      if v_uname is not null then
        v_chk := hq_check_payroll_task_item(p_year_month, 'cash', v_uname, v_corp);
        -- 自動連携が効かなかったときは黙らず通知（本部タスクの手動チェックが必要）
        if not coalesce((v_chk->>'ok')::boolean, false) then
          perform notify_lark('⚠️ 現金手渡し: 本部タスクのチェックを自動で付けられませんでした（'||p_year_month||'・'||coalesce(v_corp_name,'')||'・'||v_uname||'さん）。理由: '||coalesce(v_chk->>'reason','不明')||'。本部タスクを手動で確認してください');
        end if;
      end if;
    exception when others then
      begin perform notify_lark('⚠️ 現金手渡し: 本部タスクの自動チェックでエラーが出ました（'||p_year_month||'・'||coalesce(v_corp_name,'')||'）。本部タスクを手動で確認してください'); exception when others then null; end;
    end;
    begin                                                                              -- (c) 復元: この月×この契約の対象者が全員完了したら通知
      select count(distinct pba.user_id) into v_total
        from payroll_bank_accounts pba join users u on u.id = pba.user_id and u.is_active
       where public.payroll_month_method(pba.user_id, p_year_month) = 'cash'
         and (exists (select 1 from sf_payroll_sync sp where sp.user_id = pba.user_id and sp.year_month = p_year_month and sp.contract_id = v_contract)
              or (v_contract = v_def and not exists (select 1 from sf_payroll_sync sp where sp.user_id = pba.user_id and sp.year_month = p_year_month)));
      select count(distinct s.user_id) into v_done
        from sf_cash_handoff_signatures s
        join payroll_bank_accounts pba on pba.user_id = s.user_id and public.payroll_month_method(s.user_id, p_year_month) = 'cash'
        join users u on u.id = s.user_id and u.is_active
       where s.year_month = p_year_month and s.contract_id = v_contract and s.completed_at is not null;
      if v_total > 0 and v_total = v_done then
        perform notify_lark('💴 現金手渡し完了：'||p_year_month||'分（'||coalesce(v_corp_name,'')||'）の現金手渡し対象者 全'||v_total||'名の受け渡しが完了しました（nippo「現金手渡し・サイン」）');
      end if;
    exception when others then null;
    end;
  end if;
  return jsonb_build_object('ok', true, 'journal_marked_paid', v_synced_rows > 0);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.cash_handoff_incomplete_alert(p_notify boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_today date := (now() at time zone 'Asia/Tokyo')::date;
  v_from text := to_char((now() at time zone 'Asia/Tokyo') - interval '2 months', 'YYYY-MM');
  r record; v_total int; v_done int; v_lines text; v_und int; v_all text := ''; v_items jsonb := '[]'::jsonb;
begin
  for r in select f.year_month, f.corporation_id, c.name as corp_name
             from payroll_finalized f join corporations c on c.id = f.corporation_id
            where f.year_month >= v_from
              and v_today >= ((to_date(f.year_month || '-01', 'YYYY-MM-DD') + interval '1 month')::date + 24)   -- 翌月25日以降
            order by f.year_month, c.name loop
    with tg as (
      select u.name,
             (select st.name from user_stores us join stores st on st.id = us.store_id where us.user_id = u.id order by us.is_primary desc limit 1) as store_name,
             rec.payer_checked_at, rec.receiver_checked_at, rec.completed_at, rec.withdrawn_at
        from payroll_bank_accounts pba
        join users u on u.id = pba.user_id
        join (select sp.user_id, sp.contract_id, sum(sp.net_pay) as amt from sf_payroll_sync sp where sp.year_month = r.year_month group by sp.user_id, sp.contract_id) s on s.user_id = u.id
        join smaregi_contracts sc on sc.contract_id = s.contract_id and sc.corporation_id = r.corporation_id
        left join sf_cash_handoff_signatures rec on rec.user_id = u.id and rec.year_month = r.year_month and rec.contract_id = s.contract_id
       where public.payroll_month_method(pba.user_id, r.year_month) = 'cash' and coalesce(s.amt, 0) > 0
         and not exists (select 1 from sf_payroll_hidden h where h.user_id = u.id and h.year_month = r.year_month)
    ), und as (
      select '・' || name || coalesce('（' || store_name || '）', '') || '：'
             || case when payer_checked_at is not null and receiver_checked_at is not null then '両者サイン済み・完了処理待ち'
                     when payer_checked_at is not null then '渡した側のみサイン済み（受け取りサイン待ち）'
                     when receiver_checked_at is not null then '受け取った側のみサイン済み（渡した側サイン待ち）'
                     else 'サイン未' end
             || case when withdrawn_at is not null then '／引き出し済み' else '／未引き出し' end as line
        from tg where completed_at is null order by store_name, name limit 30
    )
    select (select count(*) from tg), (select count(*) from tg where completed_at is not null), (select string_agg(line, E'\n') from und)
      into v_total, v_done, v_lines;
    v_und := v_total - v_done;
    if v_total > 0 and v_und > 0 then
      v_all := v_all || E'\n\n■ ' || ltrim(substr(r.year_month, 6), '0') || '月分（' || r.corp_name || '）： 対象' || v_total || '名中 完了' || v_done || '名・未完了' || v_und || '名'
               || E'\n' || coalesce(v_lines, '') || case when v_und > 30 then E'\n…ほか' || (v_und - 30) || '名' else '' end;
      v_items := v_items || jsonb_build_object('year_month', r.year_month, 'corporation', r.corp_name, 'targets', v_total, 'done', v_done, 'undone', v_und);
    end if;
  end loop;
  if v_all <> '' and p_notify then
    perform notify_lark('⚠️ 現金手渡し: 期限（給与月の翌月25日）を過ぎて、サインが完了していない方がいます（完了するまで毎朝お知らせします）' || v_all);
  end if;
  return jsonb_build_object('items', v_items, 'message', nullif(v_all, ''));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.hq_create_payroll_tasks(p_year_month text, p_corp text DEFAULT NULL::text, p_corp_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_caller users%rowtype;
  v_month_start date; v_due_month_start date; v_mon int;
  v_transfer_due date; v_cash_due date;
  v_transfer_task uuid; v_transfer_step uuid; v_cash_task uuid; v_cash_step uuid;
  v_transfer_names text[]; v_cash_names text[];
  v_name text; v_sort int; v_assignees uuid[];
  v_existing payroll_task_links%rowtype;
  v_contracts text[]; v_corp_id uuid;
  v_tpl uuid[]; v_ttask hq_tasks%rowtype; v_attached boolean := false; v_warn text := '';
begin
  select * into v_caller from users u0 where u0.id = auth.uid() and u0.is_active;
  if v_caller.id is null or not (v_caller.is_master or v_caller.role in ('CEO','HQ')) then
    raise exception '権限がありません（マスター・本部・社長のみ）';
  end if;
  if p_year_month !~ '^\d{4}-\d{2}$' then raise exception 'year_monthは YYYY-MM 形式で指定してください'; end if;
  v_month_start := to_date(p_year_month || '-01', 'YYYY-MM-DD');
  v_mon := extract(month from v_month_start)::int;
  v_due_month_start := v_month_start + interval '1 month';
  v_transfer_due := jp_prev_business_day((v_due_month_start + 14)::date);
  v_cash_due := jp_prev_business_day((v_due_month_start + 24)::date);

  -- 法人の決め方（担当C確認: ボタンが渡す名前は corporations.name と完全一致）:
  --   ① p_corp_id（法人ID）があればそれを優先（実在しなければエラー） ② 無ければ p_corp（名前）→ID。名前が無い呼び出し（引数なし）だけ従来の既定 'N-Style'
  --   ID も名前も解決できないときは既定へ落とさずエラーで止める（別法人の確定をトーホー等として記録する事故を防ぐ）
  if p_corp_id is not null then
    select c.id, c.name into v_corp_id, p_corp from corporations c where c.id = p_corp_id;
    if v_corp_id is null then raise exception '法人IDが見つかりません'; end if;
  else
    p_corp := coalesce(p_corp, 'N-Style');
    select c.id into v_corp_id from corporations c where c.name = p_corp limit 1;
    if v_corp_id is null then raise exception '法人名「%」が見つかりません（corporations.name と一致する名前、または法人IDを指定してください）', p_corp; end if;
  end if;
  select array_agg(sc.contract_id) into v_contracts from smaregi_contracts sc where sc.corporation_id = v_corp_id and sc.is_active;
  if v_contracts is not null and array_length(v_contracts, 1) = 0 then v_contracts := null; end if;

  -- 確定の印（月×法人）。以降、現金手渡し画面にこの法人の対象者が出る
  insert into payroll_finalized(year_month, corporation_id, finalized_by) values (p_year_month, v_corp_id, auth.uid())
  on conflict (year_month, corporation_id) do nothing;

  -- 2026-11-23: この月の支払方法を、ここで「確定」として月ごとの表に書く（確定前に月を指定して決めた分はそのまま・無い人はいまの既定）。以降、この月は既定を変えても変わらない
  perform public.payroll_month_payments_fix(p_year_month, v_contracts);

  select array_agg(u.name order by u.name) into v_transfer_names
    from payroll_bank_accounts pba join users u on u.id = pba.user_id
    where public.payroll_month_method(pba.user_id, p_year_month) = 'bank_transfer'
      and exists (select 1 from sf_payroll_sync s where s.user_id = u.id and s.year_month = p_year_month and coalesce(s.net_pay, 0) > 0
                    and (v_contracts is null or s.contract_id = any(v_contracts)))
      and not exists (select 1 from sf_payroll_hidden h where h.user_id = u.id and h.year_month = p_year_month);
  select array_agg(t.name order by t.name) into v_cash_names
    from cash_handoff_targets_raw(p_year_month) t where coalesce(t.amount, 0) > 0
      and (v_contracts is null or t.contract_id = any(v_contracts))
      and not exists (select 1 from sf_payroll_hidden h where h.user_id = t.user_id and h.year_month = p_year_month);

  select * into v_existing from payroll_task_links where year_month = p_year_month and kind = 'transfer' and corporation_id = v_corp_id;
  if v_existing.task_id is not null then
    v_transfer_task := v_existing.task_id;
  elsif v_transfer_names is not null and array_length(v_transfer_names,1) > 0 then
    select coalesce(array_agg(id), array[]::uuid[]) into v_assignees
      from users where is_active and replace(replace(name,' ',''),chr(12288),'') = any(array['青山純','原美香','中山俊士']);
    -- 月次テンプレ由来の既存「【振込◯◯】給料」タスク（題名の月＝給与月・期限は給与月の翌月以降・同じ法人・未削除。※過去分の誤った題名『支払月』は先に給与月へ直してから使う）があれば新規に作らず、そこに確認工程を足して紐づける（二重防止・U-25①）
    select array_agg(t.id) into v_tpl from hq_tasks t
     where t.corp = p_corp and t.template_id is not null and t.deleted_at is null
       and t.title ~ ('^'||v_mon||'月分[[:space:]　]*【振込[^】]*】給料$') and t.title not like '%口振%'
       and t.due_date >= v_due_month_start and t.due_date <= (v_due_month_start + 45);
    if v_tpl is not null and array_length(v_tpl,1) > 1 then
      v_warn := v_warn || '既存の振込タスクが'||array_length(v_tpl,1)||'件見つかったため、自動では紐づけず新規作成もしていません。本部で整理してください。';
    elsif v_tpl is not null then
      select * into v_ttask from hq_tasks where id = v_tpl[1];
      if v_ttask.status = 'done' then
        v_warn := v_warn || '既存の振込タスクが完了済みのため、紐づけも新規作成もしていません。';
      else
        v_transfer_task := v_ttask.id;
        insert into hq_task_steps(task_id, title, assignee_ids, due_date, sort_order, kind)
        values (v_transfer_task, '振込対象者の確認（給料確定リスト）', v_assignees, v_ttask.due_date,
                (select coalesce(max(sort_order),0) + 10 from hq_task_steps where task_id = v_transfer_task), 'step')
        returning id into v_transfer_step;
        v_sort := 10;
        foreach v_name in array v_transfer_names loop
          insert into hq_step_checklist_items(step_id, title, sort_order) values (v_transfer_step, v_name, v_sort);
          v_sort := v_sort + 10;
        end loop;
        insert into payroll_task_links(year_month, kind, task_id, step_id, corporation_id) values (p_year_month, 'transfer', v_transfer_task, v_transfer_step, v_corp_id);
        v_attached := true;
      end if;
    else
      insert into hq_tasks(title, corp, freq, target_date, due_date, notes, description, visibility, created_by)
      values (v_mon||'月分　給料振込　'||p_corp, p_corp, 'once', current_date, v_transfer_due, '',
        '給料確定ボタンにより自動発行（対象'||array_length(v_transfer_names,1)||'名）', 'all', auth.uid())
      returning id into v_transfer_task;
      insert into hq_task_steps(task_id, title, assignee_ids, due_date, sort_order, kind)
      values (v_transfer_task, '振込完了を確認', v_assignees, v_transfer_due, 10, 'step') returning id into v_transfer_step;
      v_sort := 10;
      foreach v_name in array v_transfer_names loop
        insert into hq_step_checklist_items(step_id, title, sort_order) values (v_transfer_step, v_name, v_sort);
        v_sort := v_sort + 10;
      end loop;
      insert into payroll_task_links(year_month, kind, task_id, step_id, corporation_id) values (p_year_month, 'transfer', v_transfer_task, v_transfer_step, v_corp_id);
    end if;
  end if;

  select * into v_existing from payroll_task_links where year_month = p_year_month and kind = 'cash' and corporation_id = v_corp_id;
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
    values (v_cash_task, '手渡し完了を確認', v_assignees, v_cash_due, 10, 'step') returning id into v_cash_step;
    v_sort := 10;
    foreach v_name in array v_cash_names loop
      insert into hq_step_checklist_items(step_id, title, sort_order) values (v_cash_step, v_name, v_sort);
      v_sort := v_sort + 10;
    end loop;
    insert into payroll_task_links(year_month, kind, task_id, step_id, corporation_id) values (p_year_month, 'cash', v_cash_task, v_cash_step, v_corp_id);
  end if;

  -- 確定の結果を通知。0名・紐づけ失敗などは ⚠️ を付けて知らせる（黙って終わらせない）
  if coalesce(array_length(v_transfer_names,1),0) = 0 and coalesce(array_length(v_cash_names,1),0) = 0 then
    v_warn := v_warn || '振込・現金とも対象者が0名でした。給与データの取り込み漏れがないか確認してください。';
  end if;
  begin
    perform notify_lark('💰 給料確定: '||p_year_month||'（'||p_corp||'） 振込'||coalesce(array_length(v_transfer_names,1),0)||'名・現金'||coalesce(array_length(v_cash_names,1),0)||'名'
      ||case when v_attached then '（既存の振込タスクに確認工程を追加）' else '' end
      ||case when v_warn <> '' then E'\n⚠️ '||v_warn else '' end);
  exception when others then null;
  end;

  return jsonb_build_object(
    'corporation_id', v_corp_id, 'transfer_attached', v_attached, 'warning', nullif(v_warn, ''),
    'transfer_task_id', v_transfer_task, 'transfer_due', v_transfer_due, 'transfer_count', coalesce(array_length(v_transfer_names,1),0),
    'cash_task_id', v_cash_task, 'cash_due', v_cash_due, 'cash_count', coalesce(array_length(v_cash_names,1),0)
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.pay_transfer_pending_holds(p_year_month text)
 RETURNS TABLE(user_id uuid, request_id uuid)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select q.user_id, q.id from profile_change_requests q
   where q.field = 'bank_account' and q.status = 'pending' and (q.effective_year_month is null or q.effective_year_month <= p_year_month)
     -- いま銀行振込の口座が登録されている人だけ（口座が未登録・現金手渡しの人は、もともと振込データに入らない＝従来どおりの扱い）
     and exists (select 1 from payroll_bank_accounts b where b.user_id = q.user_id and coalesce(public.payroll_month_method(b.user_id, p_year_month), 'bank_transfer') <> 'cash')
     and not exists (select 1 from payroll_transfer_schedule t where t.year_month = p_year_month
                      and t.created_at < coalesce((select (value ->> 'transfer_guard_since')::timestamptz from app_settings where key = 'employee_change'), '-infinity'::timestamptz))
     and not exists (select 1 from payroll_transfer_account_snapshots s where s.year_month = p_year_month and s.user_id = q.user_id)
  union all
  -- 2026-11-12 開発 2: 未承認の賃金変更がある人（関所が有効のときだけ。口座変更で既に外す人は重ねない）
  select w.user_id, null::uuid from payroll_wage_holds(p_year_month) w
   where exists (select 1 from payroll_bank_accounts b where b.user_id = w.user_id and coalesce(public.payroll_month_method(b.user_id, p_year_month), 'bank_transfer') <> 'cash')
     and not exists (select 1 from payroll_transfer_schedule t where t.year_month = p_year_month
                      and t.created_at < coalesce((select (value ->> 'transfer_guard_since')::timestamptz from app_settings where key = 'employee_change'), '-infinity'::timestamptz))
     and not exists (select 1 from payroll_transfer_account_snapshots s where s.year_month = p_year_month and s.user_id = w.user_id)
     and not exists (select 1 from profile_change_requests q2 where q2.user_id = w.user_id and q2.field = 'bank_account' and q2.status = 'pending' and (q2.effective_year_month is null or q2.effective_year_month <= p_year_month))
$function$
;
