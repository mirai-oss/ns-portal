-- 銀行入金明細の正本（Supabase）— 段階5: 店舗未確定の管理・運営法人の履歴・口座の法人確認
-- 作成: 2026-11-28　状態: **下書き（未適用）**。本番への適用は、SQL の中身と検証結果を報告して、承認を受けてから。
-- 前提: 段階1〜4 が適用済み。段階1〜4のファイルは編集しない（変更はこの新しいファイルで）。
--
-- 【この SQL がやること】
--   ① 店舗未確定（store_id が空）の口座・明細の管理: 一覧・口座への店舗の後付け紐付け・取引単位の紐付け・履歴・取り消し。
--   ② 店舗の運営法人の履歴表（適用開始日・終了日）。店舗マスタの法人を変えても、過去の銀行入金の帰属法人は変わらない。
--   ③ 口座の「利用形態」（single＝1 店舗専用／multi＝複数店舗で共有）。※口座の名義・法人の確認の記録には、既存の corporation_bank_accounts（振込先口座・法人あたり現在1つ）を流用しない（別設計を提案中）。
-- 【法人別の可視性】新しい関数 bank_global_admin / bank_corp_ok（既存のポリシーには使わない＝既存の閲覧権限は変わらない）を足し、この段階の関数は最初から法人別に動く:
--   全法人の管理者（社長・マスター・法人の限定が無い本部）は全件／法人を限定された本部（info.user_corporations・info.role_corporations）は許可された法人の分だけ／法人未確定の明細・口座は全法人の管理者だけ。
--   既存の表・ストレージ・既存の関数の法人別制御は、段階6（別途承認）。
-- 【この SQL がやらないこと】既存の明細・口座の書き換え、店舗・法人の自動紐付け（根拠のない紐付けはしない。紐付けは人の操作だけ）、画面・GAS・BigQuery・旧シートの変更、
--   権限（RLS）の変更（法人別の権限は段階6）。
-- 【既存への影響】表・関数を足し、bank_accounts に列を 2 つ足す（既定値あり・既存の動作は変わらない）。店舗の運営法人の履歴表に、現在の店舗マスタから初期データを入れる（新しい表への書き込みのみ）。
-- 【ロールバック】2026-11-28_bank_ledger_stage5_ROLLBACK.sql（新しい表が空のとき（履歴表の初期データは除く）だけ）。
--
-- 守ること（社長指示 2026-11-28）:
--   ・店舗未確定の明細は、店舗別の入金実績（bank_deposit_daily）に計上しない（store_id が空の行は集計から除外される＝段階1のとおり）。
--   ・口座の紐付けの変更だけで、すでに店舗が付いた明細・確定済み（confirmed）・訂正済み（adj_*）の明細を書き換えない（店舗未確定で、未確定（open）・未訂正の明細だけが対象）。
--   ・複数店舗で共有する口座（multi）は、口座単位で全件を 1 店舗へ自動計上しない。取引単位で帰属を決める。
--   ・紐付けの変更者・変更日時・変更前後・理由を、追記専用の履歴に残す。誤った紐付けは、履歴を指定して取り消せる。

-- =====================================================================
-- ① 口座の利用形態・名義確認との結び付け
-- =====================================================================
alter table public.bank_accounts add column if not exists usage_mode text not null default 'single';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'bank_accounts_usage_mode_check' and conrelid = 'public.bank_accounts'::regclass) then
    alter table public.bank_accounts add constraint bank_accounts_usage_mode_check check (usage_mode in ('single', 'multi'));
  end if;
  -- 複数店舗で共有する口座は、口座に店舗を持たせない（取引単位で決める）
  if not exists (select 1 from pg_constraint where conname = 'bank_accounts_multi_no_store' and conrelid = 'public.bank_accounts'::regclass) then
    alter table public.bank_accounts add constraint bank_accounts_multi_no_store check (usage_mode = 'single' or store_id is null);
  end if;
end $$;

-- =====================================================================
-- ①b 法人別の可視性（新しい表・関数だけ。既存のポリシー・関数は変えない）。<b>原則は「許可が無ければ拒否」</b>
--   ・全法人を見られる管理者 ＝ 社長（CEO）・マスター・「全法人の閲覧権限」を明示的に付与された本部（下の bank_ledger_global_users）。
--   ・それ以外の本部 ＝ 既存の法人の許可（info.user_corporations。無ければ役職の許可 info.role_corporations）に載っている法人だけ。
--     <b>どちらも無い本部は、何も見えない</b>（新しい法人・新しい本部担当者を足しても、権限を設定するまで全法人が見えることはない）。
--     ※既存の info.can_access_corp は「許可が無ければ全法人」の作りのため、そのままは使わず、同じ表（user_corporations・role_corporations・corporations.legacy_info_id）を読んで「許可が無ければ拒否」で判定する。
-- =====================================================================
-- 全法人の閲覧権限の付与（本部向け。社長・マスターは付与なしで全法人）。取り消しても行は消さない（revoked_at）。
create table if not exists public.bank_ledger_global_users (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.users (id),
  granted_at timestamptz not null default now(),
  granted_by uuid,
  note       text,
  revoked_at timestamptz,
  revoked_by uuid
);
create unique index if not exists bank_ledger_global_users_active on public.bank_ledger_global_users (user_id) where revoked_at is null;
create or replace function public.bank_ledger_global_guard() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception '全法人の閲覧権限の付与の記録は削除できません（取り消しは revoked_at）'; end if;
  if new.user_id is distinct from old.user_id or new.granted_at is distinct from old.granted_at or new.granted_by is distinct from old.granted_by then raise exception '付与の記録の本人・日時・付与者は変更できません'; end if;
  if old.revoked_at is not null and new.revoked_at is distinct from old.revoked_at then raise exception '取り消し済みです'; end if;
  return new;
end $$;
revoke all on function public.bank_ledger_global_guard() from public, anon, authenticated;
drop trigger if exists bank_ledger_global_guard_trg on public.bank_ledger_global_users;
create trigger bank_ledger_global_guard_trg before update or delete on public.bank_ledger_global_users for each row execute function public.bank_ledger_global_guard();
alter table public.bank_ledger_global_users enable row level security;
revoke all on public.bank_ledger_global_users from anon, authenticated;
grant select on public.bank_ledger_global_users to authenticated;

-- 全法人の管理者か（社長・マスター・付与された本部）。法人未確定のデータは、この人だけが見られる
create or replace function public.bank_global_admin()
returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.users u
                  where u.id = auth.uid() and u.is_active
                    and (coalesce(u.is_master, false) or u.role = 'CEO'
                         or (u.role = 'HQ' and exists (select 1 from public.bank_ledger_global_users g where g.user_id = u.id and g.revoked_at is null))))
$$;
revoke all on function public.bank_global_admin() from public, anon;
grant execute on function public.bank_global_admin() to authenticated, service_role;
drop policy if exists bank_ledger_global_read on public.bank_ledger_global_users;
create policy bank_ledger_global_read on public.bank_ledger_global_users for select to authenticated using (public.bank_global_admin());
-- 見てよい法人の ID の一覧（サービスロール・全法人の管理者＝全法人／法人を限定された本部＝許可に載った法人だけ／許可が無い・本部以外＝空）。
--   行ポリシーや集計で「行ごとに関数を呼ぶ」と遅いので、1 回だけ計算して（(select ...)）使う: (select bank_global_admin()) or 法人列 = any (coalesce((select bank_allowed_corp_ids()), '{}'))
create or replace function public.bank_allowed_corp_ids()
returns uuid[] language sql stable security definer set search_path to 'public' as $$
  select case
    when coalesce(auth.role(), '') = 'service_role' or public.bank_global_admin() then (select coalesce(array_agg(c.id), '{}'::uuid[]) from public.corporations c)
    when public.bank_ledger_admin() then (
      select coalesce(array_agg(c.id), '{}'::uuid[]) from public.corporations c
       where c.legacy_info_id is not null and c.legacy_info_id in (
         select uc.corporation_id from info.user_corporations uc where uc.user_id = auth.uid()
         union
         select rc.corporation_id from info.profiles p join info.role_corporations rc on rc.role_id = p.role_id
          where p.id = auth.uid() and p.is_active and not exists (select 1 from info.user_corporations x where x.user_id = auth.uid())))
    else '{}'::uuid[] end
$$;
revoke all on function public.bank_allowed_corp_ids() from public, anon;
grant execute on function public.bank_allowed_corp_ids() to authenticated, service_role;
-- その法人のデータを見てよい管理者か。法人が空（未確定）なら、全法人の管理者だけ。サービスロール（取込）は常に可
create or replace function public.bank_corp_ok(p_corp uuid)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select coalesce(auth.role(), '') = 'service_role'
      or public.bank_global_admin()
      or (public.bank_ledger_admin() and p_corp is not null and p_corp = any (public.bank_allowed_corp_ids()))
$$;
revoke all on function public.bank_corp_ok(uuid) from public, anon;
grant execute on function public.bank_corp_ok(uuid) to authenticated, service_role;
-- 付与・取り消し（全法人の管理者だけ。理由が必須。本人への付与は、本部の役職の人だけ）
create or replace function public.bank_ledger_global_set(p_user uuid, p_on boolean, p_reason text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.bank_global_admin() then raise exception '権限がありません（全法人の閲覧権限の付与は、全法人の管理者だけ）'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception '理由が必要です'; end if;
  if p_on then
    if not exists (select 1 from public.users u where u.id = p_user and u.is_active and u.role = 'HQ') then raise exception '付与できるのは、有効な本部（HQ）の人だけです（社長・マスターは付与なしで全法人）'; end if;
    insert into public.bank_ledger_global_users (user_id, granted_by, note) values (p_user, auth.uid(), btrim(p_reason)) on conflict do nothing;
  else
    update public.bank_ledger_global_users set revoked_at = now(), revoked_by = auth.uid(), note = coalesce(note, '') || ' / 取り消し: ' || btrim(p_reason) where user_id = p_user and revoked_at is null;
  end if;
  return jsonb_build_object('ok', true, 'user_id', p_user, 'on', p_on);
end $$;
revoke all on function public.bank_ledger_global_set(uuid, boolean, text) from public, anon;
grant execute on function public.bank_ledger_global_set(uuid, boolean, text) to authenticated, service_role;
-- ※本部への全法人の閲覧権限の付与は、自動では行わない。業務上必要な人だけ、全法人の管理者が bank_ledger_global_set() で個別に付与する（理由つき・追記専用の記録）。
--   適用直後、付与が無い本部は何も見えない（銀行台帳を使う画面は、まだ無い）。

-- =====================================================================
-- ② 店舗の運営法人の履歴（適用開始日・終了日）
-- =====================================================================
create table if not exists public.store_corporation_periods (
  id             uuid primary key default gen_random_uuid(),
  store_id       uuid not null references public.stores (id),
  corporation_id uuid not null references public.corporations (id),
  valid_from     date not null,
  valid_to       date,                                   -- null＝現在も有効
  note           text,
  created_at     timestamptz not null default now(),
  created_by     uuid,
  constraint store_corp_periods_range check (valid_to is null or valid_to >= valid_from),
  constraint store_corp_periods_uniq unique (store_id, valid_from)
);
create index if not exists store_corp_periods_idx on public.store_corporation_periods (store_id, valid_from desc);
create or replace function public.store_corp_periods_guard() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception '運営法人の履歴は削除できません（終了日を入れて、新しい期間を足します）'; end if;
  if tg_op = 'UPDATE' and (new.store_id is distinct from old.store_id or new.corporation_id is distinct from old.corporation_id or new.valid_from is distinct from old.valid_from) then
    raise exception '運営法人の履歴の店舗・法人・開始日は変更できません（終了日だけ入れられます）';
  end if;
  if exists (select 1 from public.store_corporation_periods p where p.store_id = new.store_id and p.id <> new.id
              and p.valid_from <= coalesce(new.valid_to, date '9999-12-31') and coalesce(p.valid_to, date '9999-12-31') >= new.valid_from) then
    raise exception '同じ店舗の運営法人の期間が重なります';
  end if;
  return new;
end $$;
revoke all on function public.store_corp_periods_guard() from public, anon, authenticated;
drop trigger if exists store_corp_periods_guard_trg on public.store_corporation_periods;
create trigger store_corp_periods_guard_trg before insert or update or delete on public.store_corporation_periods for each row execute function public.store_corp_periods_guard();
-- 初期データ: 現在の店舗マスタの運営法人（開始日は十分古い日付）。すでにある店舗は触らない
insert into public.store_corporation_periods (store_id, corporation_id, valid_from, note)
  select s.id, s.corporation_id, date '2000-01-01', '初期データ（段階5。現在の店舗マスタの運営法人）' from public.stores s
   where s.corporation_id is not null and not exists (select 1 from public.store_corporation_periods p where p.store_id = s.id)
  on conflict do nothing;
alter table public.store_corporation_periods enable row level security;
drop policy if exists store_corp_periods_read on public.store_corporation_periods;
create policy store_corp_periods_read on public.store_corporation_periods for select to authenticated using (public.bank_ledger_admin() and public.bank_corp_ok(corporation_id));
revoke all on public.store_corporation_periods from anon, authenticated;
grant select on public.store_corporation_periods to authenticated;

-- 入金日に有効な運営法人（履歴が無い店舗は、現在の店舗マスタの法人）。取込・紐付けのとき、明細の帰属法人を決めるのに使う（決めた値は明細に保存され、あとで店舗マスタを変えても動かない）
create or replace function public.store_corporation_on(p_store uuid, p_date date)
returns uuid language sql stable security definer set search_path to 'public' as $$
  select coalesce(
    (select p.corporation_id from public.store_corporation_periods p where p.store_id = p_store and p.valid_from <= p_date and (p.valid_to is null or p.valid_to >= p_date) order by p.valid_from desc limit 1),
    (select s.corporation_id from public.stores s where s.id = p_store))
$$;
revoke all on function public.store_corporation_on(uuid, date) from public, anon;
grant execute on function public.store_corporation_on(uuid, date) to authenticated, service_role;

-- 運営法人の変更（M&A など）: 現在の期間に終了日を入れ、新しい期間を足す。<b>過去の銀行明細の帰属法人は動かさない</b>（店舗マスタ stores.corporation_id の更新は、別の手続き）
create or replace function public.store_corporation_change(p_store uuid, p_corp uuid, p_from date, p_reason text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_cur public.store_corporation_periods%rowtype;
begin
  if not public.bank_global_admin() then raise exception '権限がありません（運営法人の変更は、全法人の管理者だけ）'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception '理由が必要です'; end if;
  select * into v_cur from public.store_corporation_periods where store_id = p_store and valid_to is null order by valid_from desc limit 1;
  if found then
    if p_from <= v_cur.valid_from then raise exception '新しい開始日は、いまの期間の開始日（%）より後にしてください', v_cur.valid_from; end if;
    update public.store_corporation_periods set valid_to = p_from - 1 where id = v_cur.id;
  end if;
  insert into public.store_corporation_periods (store_id, corporation_id, valid_from, note, created_by) values (p_store, p_corp, p_from, btrim(p_reason), auth.uid());
  return jsonb_build_object('ok', true, 'store_id', p_store, 'corporation_id', p_corp, 'valid_from', p_from, 'past_bank_rows_changed', 0);
end $$;
revoke all on function public.store_corporation_change(uuid, uuid, date, text) from public, anon;
grant execute on function public.store_corporation_change(uuid, uuid, date, text) to authenticated, service_role;

-- =====================================================================
-- ③ 紐付けの履歴（追記専用）
-- =====================================================================
create table if not exists public.bank_assignment_history (
  id             uuid primary key default gen_random_uuid(),
  kind           text not null check (kind in ('account', 'transaction')),
  action         text not null check (action in ('assign', 'reassign', 'revert')),
  account_id     uuid references public.bank_accounts (id),
  transaction_id uuid references public.bank_transactions (id),
  parent_id      uuid references public.bank_assignment_history (id),     -- 口座の紐付けに伴う明細の履歴は、口座の履歴を指す
  before_values  jsonb not null,                                          -- {store_id, corporation_id, (口座は usage_mode, store_status)}
  after_values   jsonb not null,
  reverts_id     uuid references public.bank_assignment_history (id),
  reason         text not null check (btrim(reason) <> ''),
  actor_id       uuid,
  actor_label    text,
  created_at     timestamptz not null default now(),
  constraint bank_assign_hist_target check ((kind = 'account' and account_id is not null) or (kind = 'transaction' and transaction_id is not null))
);
create index if not exists bank_assign_hist_tx_idx on public.bank_assignment_history (transaction_id, created_at desc);
create index if not exists bank_assign_hist_acct_idx on public.bank_assignment_history (account_id, created_at desc);
create index if not exists bank_assign_hist_parent_idx on public.bank_assignment_history (parent_id);
alter table public.bank_assignment_history enable row level security;
drop policy if exists bank_assign_hist_read on public.bank_assignment_history;
create policy bank_assign_hist_read on public.bank_assignment_history for select to authenticated using (
  public.bank_ledger_admin() and (
    (kind = 'account' and public.bank_corp_ok((select a.corporation_id from public.bank_accounts a where a.id = account_id)))
    or (kind = 'transaction' and public.bank_corp_ok((select t.corporation_id from public.bank_transactions t where t.id = transaction_id)))));
revoke all on public.bank_assignment_history from anon, authenticated;
grant select on public.bank_assignment_history to authenticated;
drop trigger if exists bank_assign_hist_append_only on public.bank_assignment_history;
create trigger bank_assign_hist_append_only before update or delete on public.bank_assignment_history for each row execute function public.bank_append_only();

-- =====================================================================
-- ④ 関数（本部・社長・マスターだけ。理由が必須）
-- =====================================================================
-- 店舗未確定・法人未確定の一覧（口座ごと）。口座番号は出さない（末尾 4 桁だけ）。
create or replace function public.bank_unassigned_summary()
returns table (account_id uuid, bank_code text, account_last4 text, display_name text, usage_mode text, account_store_id uuid, account_corporation_id uuid,
               unassigned_count bigint, unassigned_sales_count bigint, unassigned_sales_amount numeric, no_corporation_count bigint, first_date date, last_date date)
language sql stable security definer set search_path to 'public' as $$
  select a.id, a.bank_code, a.account_last4, a.display_name, a.usage_mode, a.store_id, a.corporation_id,
         count(t.id) filter (where t.store_id is null),
         count(t.id) filter (where t.store_id is null and t.counts_as_sales_deposit and t.deposit_amount > 0),
         coalesce(sum(t.deposit_amount) filter (where t.store_id is null and t.counts_as_sales_deposit), 0)::numeric,
         count(t.id) filter (where t.corporation_id is null),
         min(t.txn_date) filter (where t.store_id is null), max(t.txn_date) filter (where t.store_id is null)
    from public.bank_accounts a left join public.bank_transactions t on t.bank_account_id = a.id and ((select public.bank_global_admin()) or t.corporation_id = any (coalesce((select public.bank_allowed_corp_ids()), '{}'::uuid[])))
   where public.bank_ledger_admin() and public.bank_corp_ok(a.corporation_id)
   group by a.id
  having a.store_id is null or a.corporation_id is null or count(t.id) filter (where t.store_id is null or t.corporation_id is null) > 0
$$;
revoke all on function public.bank_unassigned_summary() from public, anon;
grant execute on function public.bank_unassigned_summary() to authenticated, service_role;

-- 店舗未確定の明細（口座を指定）。残高・口座番号は出さない。
create or replace function public.bank_unassigned_list(p_account uuid, p_limit integer default 500)
returns table (transaction_id uuid, txn_date date, description text, deposit_amount bigint, withdrawal_amount bigint, tx_kind text, counts_as_sales_deposit boolean, confirm_status text, is_adjusted boolean)
language sql stable security definer set search_path to 'public' as $$
  select t.id, t.txn_date, t.description, t.deposit_amount, t.withdrawal_amount, t.tx_kind, t.counts_as_sales_deposit, t.confirm_status, t.is_adjusted
    from public.bank_transactions t where public.bank_ledger_admin() and ((select public.bank_global_admin()) or t.corporation_id = any (coalesce((select public.bank_allowed_corp_ids()), '{}'::uuid[]))) and t.bank_account_id = p_account and t.store_id is null
   order by t.txn_date, t.created_at limit greatest(p_limit, 1)
$$;
revoke all on function public.bank_unassigned_list(uuid, integer) from public, anon;
grant execute on function public.bank_unassigned_list(uuid, integer) to authenticated, service_role;

-- 口座への店舗の後付け紐付け（single の口座だけ）。その口座の「店舗未確定・未確定（open）・未訂正」の明細だけを再判定して店舗・帰属法人を入れる。
--   すでに店舗が付いた明細・確定済み・訂正済みの明細は書き換えない（件数を返す）。帰属法人は明細の日付に有効な運営法人（店舗の履歴）。
create or replace function public.bank_account_assign_store(p_account uuid, p_store uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_acct public.bank_accounts%rowtype; v_name text; v_hist uuid; v_n int := 0; v_skipped int := 0; v_corp uuid;
begin
  if not public.bank_ledger_admin() then raise exception '権限がありません'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception '理由が必要です'; end if;
  select * into v_acct from public.bank_accounts where id = p_account for update;
  if not found then raise exception '口座が見つかりません'; end if;
  if not public.bank_corp_ok(v_acct.corporation_id) then raise exception '権限がありません（この口座の法人を見る権限がありません）'; end if;
  if v_acct.usage_mode = 'multi' then raise exception '複数店舗で共有する口座は、口座単位では店舗を決められません。取引単位で紐付けてください'; end if;
  if not exists (select 1 from public.stores where id = p_store) then raise exception '店舗が見つかりません'; end if;
  if v_acct.store_id is not null and v_acct.store_id <> p_store then raise exception 'すでに別の店舗（%）が紐付いています。付け替えは、履歴の取り消しから行ってください', v_acct.store_id; end if;
  select coalesce(u.name, u.id::text) into v_name from public.users u where u.id = auth.uid();
  v_corp := public.store_corporation_on(p_store, current_date);
  if not public.bank_corp_ok(v_corp) then raise exception '権限がありません（紐付け先の店舗の運営法人を見る権限がありません）'; end if;
  insert into public.bank_assignment_history (kind, action, account_id, before_values, after_values, reason, actor_id, actor_label)
    values ('account', 'assign', p_account, jsonb_build_object('store_id', v_acct.store_id, 'corporation_id', v_acct.corporation_id, 'store_status', v_acct.store_status),
            jsonb_build_object('store_id', p_store, 'corporation_id', v_corp, 'store_status', 'assigned'), btrim(p_reason), auth.uid(), coalesce(v_name, 'user')) returning id into v_hist;
  update public.bank_accounts set store_id = p_store, corporation_id = coalesce(v_corp, corporation_id), store_status = 'assigned', updated_at = now() where id = p_account;
  perform set_config('app.bank_reason', btrim(p_reason), true); perform set_config('app.bank_actor', coalesce(v_name, 'user'), true);
  with tgt as (select t.id, t.corporation_id old_corp, public.store_corporation_on(p_store, t.txn_date) new_corp from public.bank_transactions t
                where t.bank_account_id = p_account and t.store_id is null and t.confirm_status = 'open' and not t.is_adjusted and ((select public.bank_global_admin()) or t.corporation_id = any (coalesce((select public.bank_allowed_corp_ids()), '{}'::uuid[])))),
       hist as (insert into public.bank_assignment_history (kind, action, account_id, transaction_id, parent_id, before_values, after_values, reason, actor_id, actor_label)
                select 'transaction', 'assign', p_account, tgt.id, v_hist, jsonb_build_object('store_id', null, 'corporation_id', tgt.old_corp),
                       jsonb_build_object('store_id', p_store, 'corporation_id', coalesce(tgt.new_corp, tgt.old_corp)), btrim(p_reason), auth.uid(), coalesce(v_name, 'user') from tgt returning transaction_id),
       upd as (update public.bank_transactions t set store_id = p_store, corporation_id = coalesce(tgt.new_corp, t.corporation_id) from tgt where t.id = tgt.id returning t.id)
  select count(*) into v_n from upd;
  select count(*) into v_skipped from public.bank_transactions t where t.bank_account_id = p_account and t.store_id is null;
  perform set_config('app.bank_reason', '', true); perform set_config('app.bank_actor', '', true);
  return jsonb_build_object('ok', true, 'history_id', v_hist, 'updated_transactions', v_n, 'skipped_unassigned_confirmed_or_adjusted', v_skipped);
end $$;
revoke all on function public.bank_account_assign_store(uuid, uuid, text) from public, anon;
grant execute on function public.bank_account_assign_store(uuid, uuid, text) to authenticated, service_role;

-- 取引単位の紐付け（店舗未確定の明細。p_allow_change=true のときだけ、すでに店舗が付いた未確定・未訂正の明細の付け替えも可）。確定済み・訂正済みは対象外（件数を返す）。
create or replace function public.bank_tx_assign_store(p_tx_ids uuid[], p_store uuid, p_reason text, p_allow_change boolean default false)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_name text; v_n int := 0; v_skip int := 0;
begin
  if not public.bank_ledger_admin() then raise exception '権限がありません'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception '理由が必要です'; end if;
  if coalesce(array_length(p_tx_ids, 1), 0) = 0 then raise exception '対象が空です'; end if;
  if not exists (select 1 from public.stores where id = p_store) then raise exception '店舗が見つかりません'; end if;
  select coalesce(u.name, u.id::text) into v_name from public.users u where u.id = auth.uid();
  perform set_config('app.bank_reason', btrim(p_reason), true); perform set_config('app.bank_actor', coalesce(v_name, 'user'), true);
  with tgt as (select t.id, t.bank_account_id, t.store_id old_store, t.corporation_id old_corp, public.store_corporation_on(p_store, t.txn_date) new_corp
                 from public.bank_transactions t where t.id = any (p_tx_ids) and t.confirm_status = 'open' and not t.is_adjusted
                  and (t.store_id is null or (p_allow_change and t.store_id <> p_store))
                  and ((select public.bank_global_admin()) or t.corporation_id = any (coalesce((select public.bank_allowed_corp_ids()), '{}'::uuid[]))) and public.bank_corp_ok(public.store_corporation_on(p_store, t.txn_date))),
       hist as (insert into public.bank_assignment_history (kind, action, account_id, transaction_id, before_values, after_values, reason, actor_id, actor_label)
                select 'transaction', case when tgt.old_store is null then 'assign' else 'reassign' end, tgt.bank_account_id, tgt.id,
                       jsonb_build_object('store_id', tgt.old_store, 'corporation_id', tgt.old_corp), jsonb_build_object('store_id', p_store, 'corporation_id', coalesce(tgt.new_corp, tgt.old_corp)),
                       btrim(p_reason), auth.uid(), coalesce(v_name, 'user') from tgt returning transaction_id),
       upd as (update public.bank_transactions t set store_id = p_store, corporation_id = coalesce(tgt.new_corp, t.corporation_id) from tgt where t.id = tgt.id returning t.id)
  select count(*) into v_n from upd;
  v_skip := coalesce(array_length(p_tx_ids, 1), 0) - v_n;
  perform set_config('app.bank_reason', '', true); perform set_config('app.bank_actor', '', true);
  return jsonb_build_object('ok', true, 'updated_transactions', v_n, 'skipped', v_skip);
end $$;
revoke all on function public.bank_tx_assign_store(uuid[], uuid, text, boolean) from public, anon;
grant execute on function public.bank_tx_assign_store(uuid[], uuid, text, boolean) to authenticated, service_role;

-- 誤った紐付けの取り消し（履歴の 1 件を指定）。取り消せるのは、その履歴のあとに値が変わっていないものだけ。
--   取引の履歴 → その明細を変更前の状態に戻す。口座の履歴 → 口座を変更前に戻し、その履歴に伴う明細も、値が変わっていないものだけ元に戻す（残りは件数で返す）。
create or replace function public.bank_assignment_revert(p_history_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare h public.bank_assignment_history%rowtype; v_name text; v_new uuid; c public.bank_assignment_history%rowtype; v_ok int := 0; v_changed int := 0; t public.bank_transactions%rowtype; a public.bank_accounts%rowtype;
begin
  if not public.bank_ledger_admin() then raise exception '権限がありません'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception '理由が必要です'; end if;
  select * into h from public.bank_assignment_history where id = p_history_id;
  if not found then raise exception '履歴が見つかりません'; end if;
  if h.action = 'revert' then raise exception '取り消しの履歴は取り消せません（もう一度紐付けてください）'; end if;
  if exists (select 1 from public.bank_assignment_history where reverts_id = p_history_id) then raise exception 'この履歴は、すでに取り消されています'; end if;
  select coalesce(u.name, u.id::text) into v_name from public.users u where u.id = auth.uid();
  perform set_config('app.bank_reason', btrim(p_reason), true); perform set_config('app.bank_actor', coalesce(v_name, 'user'), true);
  if h.kind = 'transaction' then
    select * into t from public.bank_transactions where id = h.transaction_id for update;
    if not public.bank_corp_ok(t.corporation_id) or not public.bank_corp_ok(nullif(h.before_values ->> 'corporation_id', '')::uuid) then raise exception '権限がありません（この明細の法人を見る権限がありません）'; end if;
    if t.confirm_status <> 'open' or t.is_adjusted then raise exception '確定済み・訂正済みの明細は、ここでは戻せません（訂正の手続きを使ってください）'; end if;
    if t.store_id is distinct from nullif(h.after_values ->> 'store_id', '')::uuid then raise exception 'この紐付けのあとに、明細の店舗が変わっているため、戻せません'; end if;
    update public.bank_transactions set store_id = nullif(h.before_values ->> 'store_id', '')::uuid, corporation_id = nullif(h.before_values ->> 'corporation_id', '')::uuid where id = t.id;
    insert into public.bank_assignment_history (kind, action, account_id, transaction_id, before_values, after_values, reverts_id, reason, actor_id, actor_label)
      values ('transaction', 'revert', h.account_id, h.transaction_id, h.after_values, h.before_values, h.id, btrim(p_reason), auth.uid(), coalesce(v_name, 'user'));
    v_ok := 1;
  else
    select * into a from public.bank_accounts where id = h.account_id for update;
    if not public.bank_corp_ok(a.corporation_id) or not public.bank_corp_ok(nullif(h.before_values ->> 'corporation_id', '')::uuid) then raise exception '権限がありません（この口座の法人を見る権限がありません）'; end if;
    if a.store_id is distinct from nullif(h.after_values ->> 'store_id', '')::uuid then raise exception 'この紐付けのあとに、口座の店舗が変わっているため、戻せません'; end if;
    insert into public.bank_assignment_history (kind, action, account_id, before_values, after_values, reverts_id, reason, actor_id, actor_label)
      values ('account', 'revert', h.account_id, h.after_values, h.before_values, h.id, btrim(p_reason), auth.uid(), coalesce(v_name, 'user')) returning id into v_new;
    update public.bank_accounts set store_id = nullif(h.before_values ->> 'store_id', '')::uuid, corporation_id = nullif(h.before_values ->> 'corporation_id', '')::uuid,
           store_status = coalesce(h.before_values ->> 'store_status', 'unassigned'), updated_at = now() where id = h.account_id;
    for c in select * from public.bank_assignment_history where parent_id = h.id and action <> 'revert' loop
      select * into t from public.bank_transactions where id = c.transaction_id for update;
      if t.confirm_status = 'open' and not t.is_adjusted and t.store_id is not distinct from nullif(c.after_values ->> 'store_id', '')::uuid then
        update public.bank_transactions set store_id = nullif(c.before_values ->> 'store_id', '')::uuid, corporation_id = nullif(c.before_values ->> 'corporation_id', '')::uuid where id = t.id;
        insert into public.bank_assignment_history (kind, action, account_id, transaction_id, parent_id, before_values, after_values, reverts_id, reason, actor_id, actor_label)
          values ('transaction', 'revert', c.account_id, c.transaction_id, v_new, c.after_values, c.before_values, c.id, btrim(p_reason), auth.uid(), coalesce(v_name, 'user'));
        v_ok := v_ok + 1;
      else v_changed := v_changed + 1; end if;
    end loop;
  end if;
  perform set_config('app.bank_reason', '', true); perform set_config('app.bank_actor', '', true);
  return jsonb_build_object('ok', true, 'reverted', v_ok, 'not_reverted_because_changed_later', v_changed);
end $$;
revoke all on function public.bank_assignment_revert(uuid, text) from public, anon;
grant execute on function public.bank_assignment_revert(uuid, text) to authenticated, service_role;
