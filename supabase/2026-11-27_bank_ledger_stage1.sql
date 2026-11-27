-- 銀行入金明細の正本（Supabase）— 段階1: 新しい箱・権限・守りだけを作る
-- 作成: 2026-11-27　状態: **下書き（未適用）**。本番への適用は、ユーザーが SQL の中身を確認して承認してから。
-- 設計: docs/手順書_銀行入金の正本化_段階1_2026-11-27.md（§1〜§4）
--
-- 【この SQL がやること】新しいテーブル 6 つ・関数・非公開バケット 1 つを「足す」だけ。
-- 【この SQL がやらないこと】既存テーブル・既存関数・既存ビュー・既存バケットの変更／削除、データの移行、画面の切り替え。
--   → 適用しても、入金管理画面・取込・分類・照合・消込は 1 ミリも変わらない（新しい箱が空のまま増えるだけ）。
-- 【既存への影響】無し。参照するだけ: users / user_stores / stores / corporations。
-- 【ロールバック】2026-11-27_bank_ledger_stage1_ROLLBACK.sql（データが入る前なら、これで完全に元通り）。
-- 【冪等】何度流しても同じ（create ... if not exists / create or replace / drop policy if exists）。
--
-- 用語: 「正本」＝この表が唯一の正しい明細。「移行済み・照合待ち」＝旧シートから移した明細で、まだ銀行 CSV と突き合わせていないもの。

-- =====================================================================
-- A. 権限の関数（読むだけ。値は変えない）
-- =====================================================================
-- A-1. 本部・社長・マスターだけ（原本 CSV・口座・残高つきの明細・訂正履歴を読める人）
create or replace function public.bank_ledger_admin()
returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.users u where u.id = auth.uid() and u.is_active
                  and (coalesce(u.is_master, false) or u.role in ('CEO', 'HQ')))
$$;
revoke all on function public.bank_ledger_admin() from public, anon;
grant execute on function public.bank_ledger_admin() to authenticated;

-- A-2. その店舗の入金を見てよい人（いまの kd_deposit_daily の見え方と同じ: マスター・社長・本部・チーム長は全店／店長は担当店舗だけ）
--      サービスロール（取込ジョブ・Edge Function）は全店。店舗が未確定（null）の明細は、本部・社長・マスターだけ。
create or replace function public.bank_store_visible(p_store uuid)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select coalesce(auth.role(), '') = 'service_role'
      or public.bank_ledger_admin()
      or (p_store is not null and exists (
            select 1 from public.users u
             where u.id = auth.uid() and u.is_active
               and (u.role = 'TEAM'
                    or (u.role = 'TENCHO' and exists (select 1 from public.user_stores us where us.user_id = u.id and us.store_id = p_store)))))
$$;
revoke all on function public.bank_store_visible(uuid) from public, anon;
grant execute on function public.bank_store_visible(uuid) to authenticated, service_role;

-- =====================================================================
-- B. テーブル
-- =====================================================================
-- B-1. 銀行口座（PayPay 銀行・GMO あおぞらの、入金を受ける口座）。店舗が未確定の口座も持てる。
--      口座番号そのものはこの表にだけ置く（本部・社長・マスターだけが読める）。値の登録は段階 2 で、リポジトリには書かない。
create table if not exists public.bank_accounts (
  id               uuid primary key default gen_random_uuid(),
  bank_code        text not null check (bank_code in ('paypay', 'gmo_aozora')),
  login_group      text not null,                       -- 取得ジョブのログイン系統（例: paypayA / paypayB / gmo_corp）
  account_no       text not null,
  account_last4    text generated always as (right(account_no, 4)) stored,
  display_name     text,
  corporation_id   uuid references public.corporations (id),
  store_id         uuid references public.stores (id),  -- 未確定は null
  store_status     text not null default 'unassigned' check (store_status in ('assigned', 'unassigned')),
  is_active        boolean not null default true,
  note             text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint bank_accounts_unique unique (bank_code, account_no),
  constraint bank_accounts_store_consistent check ((store_status = 'assigned') = (store_id is not null))
);

-- B-2. 取得履歴・CSV 原本の台帳。同じ CSV を取り直しても「履歴の行」は毎回残る（原本ファイルは同じ SHA-256 なら 1 つにまとめる）。
create table if not exists public.bank_import_files (
  id                  uuid primary key default gen_random_uuid(),
  bank_account_id     uuid not null references public.bank_accounts (id),
  source              text not null check (source in ('playwright', 'manual_csv')),
  fetched_at          timestamptz not null default now(),   -- 取得を始めた時刻
  as_of               timestamptz,                          -- 取得が完了し、明細を確定した時刻（新旧比較の「同じ時点」に使う）
  period_from         date,
  period_to           date,
  file_name           text,
  file_sha256         text check (file_sha256 is null or file_sha256 ~ '^[0-9a-f]{64}$'),
  size_bytes          integer check (size_bytes is null or size_bytes >= 0),
  content_type        text,
  storage_bucket      text not null default 'bank-csv-originals',
  storage_path        text,                                 -- 保存に失敗したら null のまま（status='failed'）
  status              text not null default 'registered'
                      check (status in ('registered', 'stored', 'parsed', 'committed', 'held', 'failed')),
  duplicate_of_file_id uuid references public.bank_import_files (id),  -- 同じ SHA-256 の先行ファイル
  balance_chain_ok    boolean,                              -- 残高の鎖が全行つながったか（GMO・PayPay の検証結果）
  rows_total          integer not null default 0,
  rows_new            integer not null default 0,
  rows_dup            integer not null default 0,           -- すでに入っていた行
  rows_adopted        integer not null default 0,           -- 旧シートの行と結んだ数
  rows_held           integer not null default 0,           -- 照合保留にした行
  error               text,
  error_at            timestamptz,
  run_id              uuid,                                 -- import_runs.id（外部キーは張らない）
  created_by          uuid,
  created_at          timestamptz not null default now(),
  committed_at        timestamptz,
  -- 「原本が置き場に無いのに取り込み確定」は作れない（保存失敗は確定前に止まる）
  constraint bank_import_files_commit_needs_original check
    (status <> 'committed' or (storage_path is not null and file_sha256 is not null and size_bytes is not null))
);
create unique index if not exists bank_import_files_path_uniq on public.bank_import_files (storage_bucket, storage_path) where storage_path is not null;
create index if not exists bank_import_files_acct_idx on public.bank_import_files (bank_account_id, fetched_at desc);
create index if not exists bank_import_files_sha_idx on public.bank_import_files (file_sha256) where file_sha256 is not null;
create index if not exists bank_import_files_status_idx on public.bank_import_files (status) where status in ('failed', 'held');

-- B-3. 明細の正本。
create table if not exists public.bank_transactions (
  id                uuid primary key default gen_random_uuid(),
  bank_account_id   uuid references public.bank_accounts (id),    -- 旧シートの行は口座が分からないので null 可（CSV と結べたときに入る）
  corporation_id    uuid references public.corporations (id),
  store_id          uuid references public.stores (id),            -- 未確定は null
  txn_date          date not null,
  txn_time          time,                                          -- 取れるときだけ（PayPay=秒まで／GMO=無し）
  description       text not null default '',
  deposit_amount    bigint not null default 0 check (deposit_amount >= 0),
  withdrawal_amount bigint not null default 0 check (withdrawal_amount >= 0),
  balance           bigint,                                        -- この取引の直後の残高（取れるとき）
  source_kind       text not null check (source_kind in ('playwright', 'manual_csv', 'legacy_sheet', 'manual_entry')),
  import_file_id    uuid references public.bank_import_files (id),
  -- 重複判定。dedupe_key が同じなら同じ取引。決め方は段階 2 の取込関数（PayPay=日付+取引順番号／GMO=日付+摘要+入出金+残高）。
  dedupe_key        text,
  identity_basis    text not null default 'none'
                    check (identity_basis in ('seq_no', 'balance_chain', 'time_amount', 'legacy_unverified', 'none')),
  -- 照合の状態。new=今回の取込で入った／legacy_pending=移行済み・照合待ち／verified=銀行 CSV と突き合わせ済み／held=確実に識別できず保留
  match_status      text not null default 'new' check (match_status in ('new', 'legacy_pending', 'verified', 'held')),
  hold_reason       text,
  -- 分類（既存の「入金かどうか」の扱いをそのまま写すための印）
  tx_kind           text not null default 'unclassified'
                    check (tx_kind in ('atm_deposit', 'adjustment', 'interest', 'transfer_in', 'transfer_out', 'fee', 'card', 'other', 'unclassified')),
  counts_as_sales_deposit boolean not null default false,          -- 売上入金として集計に入れるか（旧シートの行は、いまの集計と同じになるよう true で移す）
  -- 確定。確定した行は、訂正の手続き（bank_tx_correct）を通さないと変えられない
  confirm_status    text not null default 'open' check (confirm_status in ('open', 'confirmed')),
  confirmed_at      timestamptz,
  confirmed_by      uuid,
  -- 旧シート由来の控え（原本の行を丸ごと残す。勝手に統合・削除しない）
  legacy_batch      text,
  legacy_seq        integer,
  legacy_payload    jsonb,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint bank_tx_account_required check (bank_account_id is not null or source_kind in ('legacy_sheet', 'manual_entry')),
  constraint bank_tx_legacy_has_batch check (source_kind <> 'legacy_sheet' or (legacy_batch is not null and legacy_seq is not null)),
  constraint bank_tx_hold_has_reason check (match_status <> 'held' or coalesce(hold_reason, '') <> ''),
  constraint bank_tx_confirm_has_time check (confirm_status <> 'confirmed' or confirmed_at is not null)
);
create unique index if not exists bank_tx_dedupe_uniq on public.bank_transactions (bank_account_id, dedupe_key) where dedupe_key is not null;
create unique index if not exists bank_tx_legacy_uniq on public.bank_transactions (legacy_batch, legacy_seq) where legacy_batch is not null;
create index if not exists bank_tx_store_date_idx on public.bank_transactions (store_id, txn_date);
create index if not exists bank_tx_acct_date_idx  on public.bank_transactions (bank_account_id, txn_date);
create index if not exists bank_tx_file_idx       on public.bank_transactions (import_file_id) where import_file_id is not null;
create index if not exists bank_tx_pending_idx    on public.bank_transactions (match_status) where match_status in ('legacy_pending', 'held');

-- B-4. 訂正・状態変更の履歴（追記専用。修正前・修正後・修正者・日時）
create table if not exists public.bank_transaction_events (
  id             uuid primary key default gen_random_uuid(),
  transaction_id uuid not null references public.bank_transactions (id) on delete restrict,
  event_kind     text not null check (event_kind in ('update', 'correct', 'adopt_legacy', 'hold', 'release', 'confirm', 'unconfirm', 'assign_store')),
  before_values  jsonb,
  after_values   jsonb,
  reason         text,
  actor_id       uuid,
  actor_label    text,
  created_at     timestamptz not null default now()
);
create index if not exists bank_tx_events_tx_idx on public.bank_transaction_events (transaction_id, created_at desc);

-- B-5. 口座ごとの取得状態。「集計が未完了のとき、古い数字を最新として出さない」ための印。
create table if not exists public.bank_account_sync_state (
  bank_account_id      uuid primary key references public.bank_accounts (id),
  status               text not null default 'never' check (status in ('never', 'ok', 'error', 'running')),
  last_attempt_at      timestamptz,
  last_success_at      timestamptz,
  last_success_file_id uuid references public.bank_import_files (id),
  covers_through       date,          -- 最後に成功した取得が含む最新の日付
  last_error           text,
  last_error_at        timestamptz,
  updated_at           timestamptz not null default now()
);

-- B-6. 入金備考（いまはスプレッドシート DB_入金備考。日付×店舗で 1 件。編集は社長・本部だけ）
create table if not exists public.bank_deposit_notes (
  store_id   uuid not null references public.stores (id),
  note_date  date not null,
  note       text not null,
  updated_by uuid,
  updated_by_label text,
  updated_at timestamptz not null default now(),
  primary key (store_id, note_date)
);

-- =====================================================================
-- C. 行レベルの権限（RLS）。anon は一切読めない。書き込みはサービスロール（取込ジョブ）か、下の関数だけ。
-- =====================================================================
alter table public.bank_accounts           enable row level security;
alter table public.bank_import_files       enable row level security;
alter table public.bank_transactions       enable row level security;
alter table public.bank_transaction_events enable row level security;
alter table public.bank_account_sync_state enable row level security;
alter table public.bank_deposit_notes      enable row level security;

drop policy if exists bank_accounts_read on public.bank_accounts;
create policy bank_accounts_read on public.bank_accounts for select to authenticated using (public.bank_ledger_admin());
drop policy if exists bank_import_files_read on public.bank_import_files;
create policy bank_import_files_read on public.bank_import_files for select to authenticated using (public.bank_ledger_admin());
drop policy if exists bank_transactions_read on public.bank_transactions;
create policy bank_transactions_read on public.bank_transactions for select to authenticated using (public.bank_ledger_admin());
drop policy if exists bank_tx_events_read on public.bank_transaction_events;
create policy bank_tx_events_read on public.bank_transaction_events for select to authenticated using (public.bank_ledger_admin());
drop policy if exists bank_sync_state_read on public.bank_account_sync_state;
create policy bank_sync_state_read on public.bank_account_sync_state for select to authenticated using (public.bank_ledger_admin());
drop policy if exists bank_deposit_notes_read on public.bank_deposit_notes;
create policy bank_deposit_notes_read on public.bank_deposit_notes for select to authenticated using (public.bank_store_visible(store_id));
drop policy if exists bank_deposit_notes_write on public.bank_deposit_notes;
create policy bank_deposit_notes_write on public.bank_deposit_notes for all to authenticated
  using (public.bank_ledger_admin()) with check (public.bank_ledger_admin());

revoke all on public.bank_accounts, public.bank_import_files, public.bank_transactions, public.bank_transaction_events,
              public.bank_account_sync_state, public.bank_deposit_notes from anon;
-- ログイン済みの人は読むだけ（上の RLS で絞られる）。入金備考だけ、書くのも権限関数で絞る
revoke insert, update, delete, truncate on public.bank_accounts, public.bank_import_files, public.bank_transactions,
              public.bank_transaction_events, public.bank_account_sync_state from authenticated;

-- =====================================================================
-- D. 守り（トリガー）
-- =====================================================================
-- D-1. 明細: 削除は誰もできない。確定済みの行は、訂正の手続き（bank_tx_correct）を通さないと変えられない。
--      変更があれば、必ず履歴（bank_transaction_events）に「修正前・修正後」を残す（手続きを通らない経路でも漏れない）。
create or replace function public.bank_tx_guard()
returns trigger language plpgsql as $$
declare
  v_corr boolean := coalesce(current_setting('app.bank_correction', true), '') = 'on';
  v_before jsonb; v_after jsonb; v_kind text;
  v_cols text[] := array['bank_account_id','corporation_id','store_id','txn_date','txn_time','description','deposit_amount','withdrawal_amount',
                         'balance','dedupe_key','tx_kind','counts_as_sales_deposit','confirm_status','match_status','hold_reason'];
  c text;
begin
  if tg_op = 'DELETE' then
    raise exception '銀行明細は削除できません（誤りは訂正で直します）';
  end if;
  -- 取得の根拠（どの CSV のどの行か）は、あとから書き換えられない（旧シートの行を CSV と結ぶ「いま空の所に入れる」ときだけ可）
  if old.import_file_id is not null and new.import_file_id is distinct from old.import_file_id then
    raise exception '取得履歴との結び付きは変更できません';
  end if;
  if old.source_kind is distinct from new.source_kind and not (old.source_kind = 'legacy_sheet' and new.source_kind in ('playwright', 'manual_csv')) then
    raise exception '取得元は変更できません';
  end if;
  if old.confirm_status = 'confirmed' and not v_corr then
    foreach c in array v_cols loop
      if to_jsonb(new) -> c is distinct from to_jsonb(old) -> c then
        raise exception '確定済みの明細は直接変更できません（訂正の手続きを使ってください）: %', c;
      end if;
    end loop;
  end if;
  -- 履歴
  v_before := '{}'::jsonb; v_after := '{}'::jsonb;
  foreach c in array v_cols loop
    if to_jsonb(new) -> c is distinct from to_jsonb(old) -> c then
      v_before := v_before || jsonb_build_object(c, to_jsonb(old) -> c);
      v_after  := v_after  || jsonb_build_object(c, to_jsonb(new) -> c);
    end if;
  end loop;
  new.updated_at := now();
  if v_after <> '{}'::jsonb then
    v_kind := case
      when v_corr then 'correct'
      when old.confirm_status = 'open' and new.confirm_status = 'confirmed' then 'confirm'
      when old.confirm_status = 'confirmed' and new.confirm_status = 'open' then 'unconfirm'
      when old.match_status = 'legacy_pending' and new.match_status = 'verified' then 'adopt_legacy'
      when new.match_status = 'held' and old.match_status <> 'held' then 'hold'
      when old.match_status = 'held' and new.match_status <> 'held' then 'release'
      when v_after ? 'store_id' then 'assign_store'
      else 'update' end;
    insert into public.bank_transaction_events (transaction_id, event_kind, before_values, after_values, reason, actor_id, actor_label)
    values (old.id, v_kind, v_before, v_after, nullif(current_setting('app.bank_reason', true), ''), auth.uid(),
            coalesce(nullif(current_setting('app.bank_actor', true), ''), case when auth.uid() is null then 'system:' || coalesce(auth.role(), 'db') else 'user' end));
  end if;
  return new;
end $$;
drop trigger if exists bank_tx_guard_trg on public.bank_transactions;
create trigger bank_tx_guard_trg before update or delete on public.bank_transactions
  for each row execute function public.bank_tx_guard();

-- D-2. 履歴は追記専用（更新・削除できない）
create or replace function public.bank_append_only()
returns trigger language plpgsql as $$
begin
  raise exception '% は追記専用です（更新・削除はできません）', tg_table_name;
end $$;
drop trigger if exists bank_tx_events_append_only on public.bank_transaction_events;
create trigger bank_tx_events_append_only before update or delete on public.bank_transaction_events
  for each row execute function public.bank_append_only();

-- D-3. 取得履歴: 原本の指紋・置き場所・口座は、いったん入ったら変えられない。削除もできない。
--      （状態・件数・エラーの更新だけ可。storage_path は保存が成功した時に null → 値 の 1 回だけ入れられる）
create or replace function public.bank_import_files_guard()
returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    raise exception '取得履歴は削除できません';
  end if;
  if new.bank_account_id is distinct from old.bank_account_id or new.source is distinct from old.source
     or new.storage_bucket is distinct from old.storage_bucket then
    raise exception '取得履歴の口座・取得元・置き場は変更できません';
  end if;
  if old.storage_path is not null and (new.storage_path is distinct from old.storage_path
       or new.file_sha256 is distinct from old.file_sha256 or new.size_bytes is distinct from old.size_bytes) then
    raise exception '保存済みの原本の情報は変更できません';
  end if;
  if old.status = 'committed' and new.status <> 'committed' then
    raise exception '確定した取り込みの状態は戻せません';
  end if;
  return new;
end $$;
drop trigger if exists bank_import_files_guard_trg on public.bank_import_files;
create trigger bank_import_files_guard_trg before update or delete on public.bank_import_files
  for each row execute function public.bank_import_files_guard();

-- =====================================================================
-- E. 訂正の手続き（本部・社長・マスターだけ。理由が必須。確定済みの明細を直せる唯一の入り口）
-- =====================================================================
create or replace function public.bank_tx_correct(p_id uuid, p_changes jsonb, p_reason text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_old public.bank_transactions%rowtype;
  v_allowed text[] := array['store_id','tx_kind','counts_as_sales_deposit','description','deposit_amount','withdrawal_amount','txn_date','confirm_status'];
  k text;
  v_name text;
begin
  if not public.bank_ledger_admin() then raise exception '権限がありません'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception '訂正の理由が必要です'; end if;
  if p_changes is null or jsonb_typeof(p_changes) <> 'object' or p_changes = '{}'::jsonb then raise exception '変更内容がありません'; end if;
  for k in select jsonb_object_keys(p_changes) loop
    if not (k = any (v_allowed)) then raise exception '変更できない項目です: %', k; end if;
  end loop;
  select * into v_old from public.bank_transactions where id = p_id for update;
  if not found then raise exception '明細が見つかりません'; end if;
  select coalesce(u.name, u.id::text) into v_name from public.users u where u.id = auth.uid();
  perform set_config('app.bank_correction', 'on', true);
  perform set_config('app.bank_reason', btrim(p_reason), true);
  perform set_config('app.bank_actor', coalesce(v_name, 'user'), true);
  update public.bank_transactions t set
    store_id                = case when p_changes ? 'store_id' then nullif(p_changes ->> 'store_id', '')::uuid else t.store_id end,
    tx_kind                 = case when p_changes ? 'tx_kind' then p_changes ->> 'tx_kind' else t.tx_kind end,
    counts_as_sales_deposit = case when p_changes ? 'counts_as_sales_deposit' then (p_changes ->> 'counts_as_sales_deposit')::boolean else t.counts_as_sales_deposit end,
    description             = case when p_changes ? 'description' then p_changes ->> 'description' else t.description end,
    deposit_amount          = case when p_changes ? 'deposit_amount' then (p_changes ->> 'deposit_amount')::bigint else t.deposit_amount end,
    withdrawal_amount       = case when p_changes ? 'withdrawal_amount' then (p_changes ->> 'withdrawal_amount')::bigint else t.withdrawal_amount end,
    txn_date                = case when p_changes ? 'txn_date' then (p_changes ->> 'txn_date')::date else t.txn_date end,
    confirm_status          = case when p_changes ? 'confirm_status' then p_changes ->> 'confirm_status' else t.confirm_status end,
    confirmed_at            = case when p_changes ? 'confirm_status' then (case when p_changes ->> 'confirm_status' = 'confirmed' then now() else null end) else t.confirmed_at end,
    confirmed_by            = case when p_changes ? 'confirm_status' then (case when p_changes ->> 'confirm_status' = 'confirmed' then auth.uid() else null end) else t.confirmed_by end
  where t.id = p_id;
  -- このトランザクションの外へ設定を漏らさない
  perform set_config('app.bank_correction', '', true);
  perform set_config('app.bank_reason', '', true);
  perform set_config('app.bank_actor', '', true);
  return jsonb_build_object('ok', true, 'id', p_id);
end $$;
revoke all on function public.bank_tx_correct(uuid, jsonb, text) from public, anon;
grant execute on function public.bank_tx_correct(uuid, jsonb, text) to authenticated;

-- =====================================================================
-- F. 日次集計（明細から作る唯一の集計。画面ごとに違う数字にならないための元）
--    ビューではなく「関数」にする（owner 実行のビューは Supabase の安全性チェックで警告になるため。
--    2026-11-26 の公開設定の件と同じ種類の警告を、新しく増やさない）。関数の中で bank_store_visible により店舗ごとに絞る。
--    形は kd_deposit_daily（店舗×日・amount・deposit_count・entries[{a,m}]）と合わせてある＝段階 6 の切り替えで画面側の変更が小さい。
-- =====================================================================
create or replace function public.bank_deposit_daily(p_from date default null, p_to date default null)
returns table (store_id uuid, corporation_id uuid, deposit_date date, amount numeric, deposit_count integer,
               entries jsonb, held_count integer, legacy_pending_count integer, last_changed_at timestamptz)
language sql stable security definer set search_path to 'public' as $$
  select t.store_id,
         t.corporation_id,
         t.txn_date,
         sum(t.deposit_amount)::numeric,
         count(*)::int,
         jsonb_agg(jsonb_build_object('a', t.deposit_amount, 'm', left(t.description, 80))
                   order by t.txn_time nulls last, t.created_at, t.id),
         (count(*) filter (where t.match_status = 'held'))::int,
         (count(*) filter (where t.match_status = 'legacy_pending'))::int,
         max(t.updated_at)
    from public.bank_transactions t
   where t.counts_as_sales_deposit and t.deposit_amount > 0 and t.store_id is not null
     and (p_from is null or t.txn_date >= p_from) and (p_to is null or t.txn_date <= p_to)
     and public.bank_store_visible(t.store_id)
   group by t.store_id, t.corporation_id, t.txn_date
$$;
comment on function public.bank_deposit_daily(date, date) is '店舗×日の入金（銀行明細の正本から作る）。held_count>0 の日は「保留あり」を画面に出すこと';
revoke all on function public.bank_deposit_daily(date, date) from public, anon;
grant execute on function public.bank_deposit_daily(date, date) to authenticated, service_role;

-- 取得状態（店舗ごと・口座番号は出さない）。古い数字を「最新」と見せないための印
-- （status が ok 以外／covers_through が古い／held_count>0 のときは、画面に注意を出す）
create or replace function public.bank_sync_status()
returns table (store_id uuid, bank_code text, status text, last_success_at timestamptz, last_attempt_at timestamptz,
               covers_through date, held_count integer)
language sql stable security definer set search_path to 'public' as $$
  select a.store_id, a.bank_code, coalesce(s.status, 'never'), s.last_success_at, s.last_attempt_at, s.covers_through,
         (select count(*) from public.bank_transactions t where t.bank_account_id = a.id and t.match_status = 'held')::int
    from public.bank_accounts a
    left join public.bank_account_sync_state s on s.bank_account_id = a.id
   where a.is_active and public.bank_store_visible(a.store_id)
$$;
revoke all on function public.bank_sync_status() from public, anon;
grant execute on function public.bank_sync_status() to authenticated, service_role;

-- =====================================================================
-- G. 原本 CSV の置き場（Storage の非公開バケット。給与振込の payroll-transfer-evidence と同じ作り）
--    置き場所の形: {銀行}/{口座ID}/{年}/{取得日時}_{SHA-256 の先頭 12 文字}.csv（ファイル名に口座番号・店舗名を入れない）
--    読む＝本部・社長・マスターだけ／入れる＝同じ人（手動取込）とサービスロール（取込ジョブ）。上書き・削除の決まりは作らない＝誰もできない。
-- =====================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('bank-csv-originals', 'bank-csv-originals', false, 10485760,
        array['text/csv', 'text/plain', 'application/vnd.ms-excel', 'application/octet-stream'])
on conflict (id) do update set public = false, file_size_limit = 10485760,
        allowed_mime_types = array['text/csv', 'text/plain', 'application/vnd.ms-excel', 'application/octet-stream'];

drop policy if exists bank_csv_originals_read on storage.objects;
create policy bank_csv_originals_read on storage.objects for select
  using (bucket_id = 'bank-csv-originals' and public.bank_ledger_admin());
drop policy if exists bank_csv_originals_insert on storage.objects;
create policy bank_csv_originals_insert on storage.objects for insert
  with check (bucket_id = 'bank-csv-originals' and public.bank_ledger_admin());
-- update・delete の決まりは作らない（ログインした人は、上書きも削除もできない）

-- =====================================================================
-- 確認用（適用後に 1 回だけ流す。どれも 0 件／ true のはず）
-- =====================================================================
-- select count(*) from public.bank_transactions;                       -- 0（空の箱）
-- select relname, relrowsecurity from pg_class where relname like 'bank\_%' and relkind = 'r';   -- 全部 true
-- select has_table_privilege('anon', 'public.bank_transactions', 'select');                      -- false
-- select id, public from storage.buckets where id = 'bank-csv-originals';                         -- public=false
