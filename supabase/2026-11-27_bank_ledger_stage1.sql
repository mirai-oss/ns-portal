-- 銀行入金明細の正本（Supabase）— 段階1: 新しい箱・権限・守りだけを作る
-- 作成: 2026-11-27（第2版 2026-11-27: レビュー7点を反映／第3版 2026-11-28: 原本の保存確認を DB の守りに追加・閲覧範囲の明文化）　状態: **下書き（未適用）**。本番への適用は、ユーザーが SQL の中身を確認して承認してから。
-- 設計: docs/手順書_銀行入金の正本化_段階1_2026-11-27.html ／ テスト: tools/bank-ledger-test/（PGlite で権限・守り・再実行を検証）
--
-- 【この SQL がやること】新しいテーブル 7 つ・関数・非公開バケット 1 つを「足す」だけ。
-- 【この SQL がやらないこと】既存テーブル・既存関数・既存ビュー・既存バケットの変更／削除、データの移行、画面の切り替え。
--   → 適用しても、入金管理画面・取込・分類・照合・消込は 1 ミリも変わらない（新しい箱が空のまま増えるだけ）。
-- 【既存への影響】無し。参照するだけ: users / user_stores / team_stores（team_store_ids / user_store_ids 関数）/ stores / corporations。
-- 【ロールバック】2026-11-27_bank_ledger_stage1_ROLLBACK.sql（データ・原本ファイルが 1 件でもあれば、何も消さずに止まる）。
-- 【再実行】何度流しても、すでに入っているデータ・設定を変えない（create ... if not exists / create or replace / 自分の持ち物のポリシーだけ作り直し。
--          バケットの既存の設定は上書きしない。将来の列の追加は、別の新しい SQL で行う＝この SQL は「新規に作る時」専用）。
--
-- 用語: 「正本」＝この表が唯一の正しい明細。「原本の事実」＝銀行の CSV に書かれていた値（日付・摘要・入出金額・残高）で、あとから変えない。
--       「管理上の訂正値」＝原本は直さず、集計に使う値だけを別の列（adj_*）で上書きしたもの（理由・修正者・日時が履歴に残る）。
--       「移行済み・照合待ち」＝旧シートから移した明細で、まだ銀行 CSV と突き合わせていないもの。

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
grant execute on function public.bank_ledger_admin() to authenticated, service_role;

-- A-2. その店舗の入金（集計）を見てよい人。
--   ・マスター・社長・本部＝全店（全法人）
--   ・チーム長（TEAM）＝担当チームの店舗（team_stores）＋本人の所属店舗（user_stores）だけ
--       ※経営ダッシュボードの入金管理画面（GAS のセッション）は、チーム長を「所属店舗だけ」にしている。
--         kd_deposit_daily の RLS は TEAM を全店にしているが、そちらは広すぎるので、ここでは合わせない（より狭い方に倒す）。
--   ・店長（TENCHO）＝本人の所属店舗（user_stores）だけ
--   ・一般社員（SHAIN）・アルバイト（AL）・無効なユーザー・未ログイン＝見えない
--   ・店舗が未確定（null）の明細・口座は、本部・社長・マスターだけ
--   ・サービスロール（取込ジョブ・Edge Function）は全店
--   法人をまたぐ範囲は、店舗の所属（stores.corporation_id）で自然に分かれる。他法人の店舗の担当でなければ見えない。
create or replace function public.bank_store_visible(p_store uuid)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select coalesce(auth.role(), '') = 'service_role'
      or public.bank_ledger_admin()
      or (p_store is not null and exists (
            select 1 from public.users u
             where u.id = auth.uid() and u.is_active
               and ((u.role = 'TEAM'   and p_store = any (coalesce(public.team_store_ids(u.team_id), '{}'::uuid[]) || coalesce(public.user_store_ids(u.id), '{}'::uuid[])))
                 or (u.role = 'TENCHO' and p_store = any (coalesce(public.user_store_ids(u.id), '{}'::uuid[]))))))
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

-- B-2. CSV 原本（ファイルの実体 1 つにつき 1 行）。同じ中身（同じ SHA-256）の CSV は、同じ口座の中では 1 行にまとまる。
--      置き場所は SHA-256 から決まる（{銀行}/{口座ID}/{SHA-256}.csv）＝同じ中身を何度取り直しても、同じ場所・上書きは起きない。
--      取得の実行ごとの記録は、下の bank_import_files（複数の取得履歴が、同じ原本を指せる）。
create table if not exists public.bank_csv_originals (
  id                uuid primary key default gen_random_uuid(),
  bank_account_id   uuid not null references public.bank_accounts (id),
  file_sha256       text not null check (file_sha256 ~ '^[0-9a-f]{64}$'),
  size_bytes        integer not null check (size_bytes >= 0),
  content_type      text,
  first_file_name   text,                              -- 最初に取得したときのファイル名（参考）
  storage_bucket    text not null default 'bank-csv-originals',
  storage_path      text not null,
  first_seen_at     timestamptz not null default now(),
  created_by        uuid,
  constraint bank_csv_originals_sha_per_account unique (bank_account_id, file_sha256),
  constraint bank_csv_originals_path_uniq unique (storage_bucket, storage_path)
);

-- B-3. 取得履歴（取得・取り込みを実行するたびに 1 行。同じ CSV を取り直しても、行は毎回増える）。
create table if not exists public.bank_import_files (
  id                  uuid primary key default gen_random_uuid(),
  bank_account_id     uuid not null references public.bank_accounts (id),
  source              text not null check (source in ('playwright', 'manual_csv')),
  fetched_at          timestamptz not null default now(),   -- 取得を始めた時刻
  as_of               timestamptz,                          -- 取得が完了し、明細を確定した時刻（新旧比較の「同じ時点」に使う）
  period_from         date,
  period_to           date,
  file_name           text,                                 -- この取得でのファイル名
  original_id         uuid references public.bank_csv_originals (id),   -- 原本の保存に失敗したら null のまま（status='failed'）
  original_reused     boolean not null default false,       -- すでにあった原本と同じ中身だった（取り直し）
  -- ▼原本の保存確認（段階 2 の取込関数が、保存のあと置き場から読み戻して確かめた結果を書く。確認が済むまで、解析・確定に進めない）
  --   original_id がある＝台帳に行がある、というだけでは「実ファイルが置き場にある」とは言えないため、別に確認の印を持つ。
  original_verified_at     timestamptz,                     -- 置き場から読み戻して確認を終えた時刻
  original_verified_sha256 text check (original_verified_sha256 is null or original_verified_sha256 ~ '^[0-9a-f]{64}$'),  -- 読み戻した中身から計算した SHA-256
  original_verified_size   integer,                         -- 読み戻した中身のバイト数
  status              text not null default 'registered'
                      check (status in ('registered', 'stored', 'parsed', 'committed', 'held', 'failed')),
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
  -- 「原本が置き場に無いのに取り込み確定」は作れない（保存に失敗したら確定の前に止まる）
  constraint bank_import_files_commit_needs_original check (status <> 'committed' or original_id is not null)
);
create index if not exists bank_import_files_acct_idx on public.bank_import_files (bank_account_id, fetched_at desc);
create index if not exists bank_import_files_original_idx on public.bank_import_files (original_id) where original_id is not null;
create index if not exists bank_import_files_status_idx on public.bank_import_files (status) where status in ('failed', 'held');

-- B-4. 明細の正本。
--   原本の事実の列（txn_date・txn_time・description・deposit_amount・withdrawal_amount・balance）は、いったん入ったら変えない
--   （空の txn_time・balance・口座・重複判定キーを、あとから CSV と結んだときに「埋める」ことだけ 1 回できる）。
--   直したいときは adj_*（管理上の訂正値）に入れる。集計は「訂正値があれば訂正値、無ければ原本の値」を使う。
create table if not exists public.bank_transactions (
  id                uuid primary key default gen_random_uuid(),
  bank_account_id   uuid references public.bank_accounts (id),    -- 旧シートの行は口座が分からないので null 可（CSV と結べたときに入る）
  corporation_id    uuid references public.corporations (id),
  store_id          uuid references public.stores (id),            -- 未確定は null
  -- ▼原本の事実
  txn_date          date not null,
  txn_time          time,                                          -- 取れるときだけ（PayPay=秒まで／GMO=無し）
  description       text not null default '',
  deposit_amount    bigint not null default 0 check (deposit_amount >= 0),
  withdrawal_amount bigint not null default 0 check (withdrawal_amount >= 0),
  balance           bigint,                                        -- この取引の直後の残高（取れるとき）
  -- ▼管理上の訂正値（null＝訂正なし）
  adj_txn_date           date,
  adj_description        text,
  adj_deposit_amount     bigint check (adj_deposit_amount is null or adj_deposit_amount >= 0),
  adj_withdrawal_amount  bigint check (adj_withdrawal_amount is null or adj_withdrawal_amount >= 0),
  is_adjusted       boolean generated always as (adj_txn_date is not null or adj_description is not null
                                                  or adj_deposit_amount is not null or adj_withdrawal_amount is not null) stored,
  source_kind       text not null check (source_kind in ('playwright', 'manual_csv', 'legacy_sheet', 'manual_entry')),
  import_file_id    uuid references public.bank_import_files (id),  -- どの取得履歴で入った（結ばれた）か。原本へは import_file_id → original_id でたどる
  -- 重複判定。dedupe_key が同じなら同じ取引。決め方は段階 2 の取込関数（PayPay=日付+取引順番号／GMO=日付+摘要+入出金+残高）。
  dedupe_key        text,
  identity_basis    text not null default 'none'
                    check (identity_basis in ('seq_no', 'balance_chain', 'time_amount', 'legacy_unverified', 'none')),
  -- 照合の状態。
  --   new            = 取込の途中（確定の前の一瞬だけ。取り込みを確定すると、1 件も残らない）
  --   legacy_pending = 移行済み・照合待ち（旧シートの行。いまの数字を保つため、集計に入る）
  --   verified       = 銀行 CSV と突き合わせ済み（集計に入る）
  --   held           = 確実に識別できず保留（集計に入らない。件数・金額を別に出す）
  match_status      text not null default 'new' check (match_status in ('new', 'legacy_pending', 'verified', 'held')),
  hold_reason       text,
  -- 分類（既存の「入金かどうか」の扱いをそのまま写すための印）
  tx_kind           text not null default 'unclassified'
                    check (tx_kind in ('atm_deposit', 'adjustment', 'interest', 'transfer_in', 'transfer_out', 'fee', 'card', 'other', 'unclassified')),
  counts_as_sales_deposit boolean not null default false,          -- 売上入金として集計に入れる種類か（旧シートの行は、いまの集計と同じになるよう true で移す）
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
  constraint bank_tx_confirm_has_time check (confirm_status <> 'confirmed' or confirmed_at is not null),
  -- 「照合済み」は、銀行 CSV と結ばれている（取得履歴がある）か、人が入れた明細だけ
  constraint bank_tx_verified_has_source check (match_status <> 'verified' or import_file_id is not null or source_kind = 'manual_entry')
);
create unique index if not exists bank_tx_dedupe_uniq on public.bank_transactions (bank_account_id, dedupe_key) where dedupe_key is not null;
create unique index if not exists bank_tx_legacy_uniq on public.bank_transactions (legacy_batch, legacy_seq) where legacy_batch is not null;
create index if not exists bank_tx_store_date_idx on public.bank_transactions (store_id, txn_date);
create index if not exists bank_tx_acct_date_idx  on public.bank_transactions (bank_account_id, txn_date);
create index if not exists bank_tx_file_idx       on public.bank_transactions (import_file_id) where import_file_id is not null;
create index if not exists bank_tx_pending_idx    on public.bank_transactions (match_status) where match_status in ('legacy_pending', 'held', 'new');

-- B-5. 訂正・状態変更の履歴（追記専用。修正前・修正後・修正者・日時）
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

-- B-6. 口座ごとの取得状態。「集計が未完了のとき、古い数字を最新として出さない」ための印。
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

-- B-7. 入金備考（いまはスプレッドシート DB_入金備考。日付×店舗で 1 件。編集は社長・本部だけ）
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
alter table public.bank_csv_originals      enable row level security;
alter table public.bank_import_files       enable row level security;
alter table public.bank_transactions       enable row level security;
alter table public.bank_transaction_events enable row level security;
alter table public.bank_account_sync_state enable row level security;
alter table public.bank_deposit_notes      enable row level security;

drop policy if exists bank_accounts_read on public.bank_accounts;
create policy bank_accounts_read on public.bank_accounts for select to authenticated using (public.bank_ledger_admin());
drop policy if exists bank_csv_originals_tbl_read on public.bank_csv_originals;
create policy bank_csv_originals_tbl_read on public.bank_csv_originals for select to authenticated using (public.bank_ledger_admin());
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

revoke all on public.bank_accounts, public.bank_csv_originals, public.bank_import_files, public.bank_transactions,
              public.bank_transaction_events, public.bank_account_sync_state, public.bank_deposit_notes from anon;
-- ログイン済みの人に与えるのは「読む」だけ（上の RLS でさらに絞られる）。Supabase の初期設定で付く他の権限（references・trigger なども）は全部外す。
-- 入金備考だけは、書くのも権限関数（本部・社長・マスター）で絞った上で、書き込みの権限を渡す。
revoke all on public.bank_accounts, public.bank_csv_originals, public.bank_import_files, public.bank_transactions,
              public.bank_transaction_events, public.bank_account_sync_state, public.bank_deposit_notes from authenticated;
grant select on public.bank_accounts, public.bank_csv_originals, public.bank_import_files, public.bank_transactions,
                public.bank_transaction_events, public.bank_account_sync_state to authenticated;
grant select, insert, update, delete on public.bank_deposit_notes to authenticated;

-- =====================================================================
-- D. 守り（トリガー）
-- =====================================================================
-- D-1. 明細
--   ・削除は誰もできない。
--   ・原本の事実（日付・摘要・入出金額）は、訂正の手続きを通しても変えられない（直すときは adj_* を使う）。
--   ・空だった原本項目（時刻・残高・口座・重複判定キー・取得履歴）は、CSV と結んだときに 1 回だけ埋められる。埋めたあとは変えられない。
--   ・確定済みの行は、訂正の手続き（bank_tx_correct）を通さないと、管理項目・訂正値・状態を変えられない。
--   ・変更があれば、必ず履歴に「修正前・修正後」を自動で残す（手続きを通らない経路でも漏れない）。
create or replace function public.bank_tx_guard()
returns trigger language plpgsql as $$
declare
  v_corr boolean := coalesce(current_setting('app.bank_correction', true), '') = 'on';
  v_before jsonb := '{}'::jsonb; v_after jsonb := '{}'::jsonb; v_kind text;
  v_tracked text[] := array['bank_account_id','corporation_id','store_id','txn_time','balance','dedupe_key','import_file_id','identity_basis',
                            'adj_txn_date','adj_description','adj_deposit_amount','adj_withdrawal_amount',
                            'tx_kind','counts_as_sales_deposit','confirm_status','match_status','hold_reason','source_kind'];
  v_confirmed_protected text[] := array['corporation_id','store_id','adj_txn_date','adj_description','adj_deposit_amount','adj_withdrawal_amount',
                                        'tx_kind','counts_as_sales_deposit','confirm_status','hold_reason'];
  v_fill_once text[] := array['bank_account_id','txn_time','balance','dedupe_key','import_file_id'];
  c text;
begin
  if tg_op = 'DELETE' then
    raise exception '銀行明細は削除できません（誤りは管理上の訂正値で直します）';
  end if;
  -- 原本の事実は変えられない
  if new.txn_date is distinct from old.txn_date or new.description is distinct from old.description
     or new.deposit_amount is distinct from old.deposit_amount or new.withdrawal_amount is distinct from old.withdrawal_amount then
    raise exception '銀行原本の取引情報（日付・摘要・入出金額）は変更できません。管理上の訂正値（adj_*）を使ってください';
  end if;
  if new.legacy_batch is distinct from old.legacy_batch or new.legacy_seq is distinct from old.legacy_seq
     or new.legacy_payload is distinct from old.legacy_payload then
    raise exception '旧シートの控えは変更できません';
  end if;
  -- 空だった原本項目は 1 回だけ埋められる。埋めたあとは変えられない
  foreach c in array v_fill_once loop
    if to_jsonb(old) -> c <> 'null'::jsonb and to_jsonb(new) -> c is distinct from to_jsonb(old) -> c then
      raise exception '原本に結び付いた項目は変更できません: %', c;
    end if;
  end loop;
  if old.source_kind is distinct from new.source_kind and not (old.source_kind = 'legacy_sheet' and new.source_kind in ('playwright', 'manual_csv')) then
    raise exception '取得元は変更できません';
  end if;
  if old.identity_basis is distinct from new.identity_basis and old.match_status not in ('legacy_pending', 'new') then
    raise exception '重複判定の根拠は、照合待ち・取込途中の明細だけ決められます';
  end if;
  -- 確定済みの行
  if old.confirm_status = 'confirmed' and not v_corr then
    foreach c in array v_confirmed_protected loop
      if to_jsonb(new) -> c is distinct from to_jsonb(old) -> c then
        raise exception '確定済みの明細は直接変更できません（訂正の手続きを使ってください）: %', c;
      end if;
    end loop;
    if new.match_status is distinct from old.match_status and not (old.match_status = 'legacy_pending' and new.match_status = 'verified') then
      raise exception '確定済みの明細の照合状態は直接変更できません（訂正の手続きを使ってください）';
    end if;
  end if;
  -- 履歴
  foreach c in array v_tracked loop
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

-- D-1b. トリガー用の関数は、誰からも直接は呼ばせない（トリガーとしての実行には、呼び出す人の実行権限はいらない）
revoke all on function public.bank_tx_guard() from public, anon, authenticated;
-- D-2. 履歴は追記専用（更新・削除できない）
create or replace function public.bank_append_only()
returns trigger language plpgsql as $$
begin
  raise exception '% は追記専用です（更新・削除はできません）', tg_table_name;
end $$;
revoke all on function public.bank_append_only() from public, anon, authenticated;
drop trigger if exists bank_tx_events_append_only on public.bank_transaction_events;
create trigger bank_tx_events_append_only before update or delete on public.bank_transaction_events
  for each row execute function public.bank_append_only();
-- 原本の台帳も、いったん入ったら更新・削除できない（同じ中身の取り直しは、取得履歴の行が増えるだけ）
drop trigger if exists bank_csv_originals_append_only on public.bank_csv_originals;
create trigger bank_csv_originals_append_only before update or delete on public.bank_csv_originals
  for each row execute function public.bank_append_only();

-- D-3. 取得履歴: 口座・取得元は変えられない。原本との結び付きは、保存が成功したときに null → 値 の 1 回だけ。削除もできない。
--      解析済み（parsed）・確定（committed）にできるのは、次の 3 つがすべて満たされたときだけ（original_id があるだけでは通らない）:
--        ① 置き場（storage.objects）に、その原本の実ファイルが実在し、保存されたサイズが台帳（size_bytes）と一致する
--        ② 保存のあと読み戻して計算した SHA-256 が記録されていて、台帳の file_sha256 と一致する（original_verified_*）
--        ③ 読み戻したサイズが台帳の size_bytes と一致する
--      確定にはさらに、取込の途中（match_status='new'）の明細が 1 件も残っていないこと。
--      ※ 読み戻して SHA-256 を計算する処理そのものは段階 2 の取込関数がやる（DB の中ではファイルの中身を読めない）。ここはその結果の記録と突き合わせを必須にする。
--      security definer にするのは、呼ぶ人の権限にかかわらず、置き場の実在を同じ条件で確かめるため。
create or replace function public.bank_import_files_guard()
returns trigger language plpgsql security definer set search_path to 'public', 'storage' as $$
declare
  v_orig public.bank_csv_originals%rowtype;
  v_size bigint;
begin
  if tg_op = 'DELETE' then
    raise exception '取得履歴は削除できません';
  end if;
  if tg_op = 'INSERT' then
    -- 最初から「解析済み・確定」で作ることはできない（保存確認を飛ばせてしまうため）。登録・保存済み・失敗から始める
    if new.status not in ('registered', 'stored', 'failed') then
      raise exception '取得履歴は registered / stored / failed から始めます（保存確認を経ずに解析済み・確定にはできません）';
    end if;
    if new.original_verified_at is not null or new.original_verified_sha256 is not null or new.original_verified_size is not null then
      raise exception '原本の保存確認の結果は、保存の後に記録します';
    end if;
    if new.original_id is not null and not exists (select 1 from public.bank_csv_originals o where o.id = new.original_id and o.bank_account_id = new.bank_account_id) then
      raise exception '原本が別の口座のものです';
    end if;
    return new;
  end if;
  if new.bank_account_id is distinct from old.bank_account_id or new.source is distinct from old.source then
    raise exception '取得履歴の口座・取得元は変更できません';
  end if;
  if old.original_id is not null and new.original_id is distinct from old.original_id then
    raise exception '保存済みの原本との結び付きは変更できません';
  end if;
  if new.original_id is not null and new.original_id is distinct from old.original_id then
    if not exists (select 1 from public.bank_csv_originals o where o.id = new.original_id and o.bank_account_id = new.bank_account_id) then
      raise exception '原本が別の口座のものです';
    end if;
  end if;
  if old.status = 'committed' and new.status <> 'committed' then
    raise exception '確定した取り込みの状態は戻せません';
  end if;
  if old.original_verified_at is not null and (new.original_verified_at is distinct from old.original_verified_at
     or new.original_verified_sha256 is distinct from old.original_verified_sha256 or new.original_verified_size is distinct from old.original_verified_size) then
    raise exception '原本の保存確認の結果は変更できません';
  end if;
  if new.status in ('parsed', 'committed') and old.status is distinct from new.status then
    if new.original_id is null then
      raise exception '原本が保存されていないため、解析・確定に進めません';
    end if;
    select * into v_orig from public.bank_csv_originals where id = new.original_id;
    select nullif(obj.metadata ->> 'size', '')::bigint into v_size
      from storage.objects obj where obj.bucket_id = v_orig.storage_bucket and obj.name = v_orig.storage_path;
    if not found then
      raise exception '原本ファイルが置き場に見つかりません（保存の成功を確認できないため、解析・確定に進めません）';
    end if;
    if v_size is distinct from v_orig.size_bytes::bigint then
      raise exception '置き場の原本ファイルのサイズが台帳と一致しません';
    end if;
    if new.original_verified_at is null or new.original_verified_sha256 is null or new.original_verified_size is null then
      raise exception '原本を置き場から読み戻した確認（ハッシュ・サイズ）が記録されていません';
    end if;
    if new.original_verified_sha256 <> v_orig.file_sha256 or new.original_verified_size <> v_orig.size_bytes then
      raise exception '読み戻した原本のハッシュ・サイズが台帳と一致しません';
    end if;
  end if;
  if new.status = 'committed' and old.status <> 'committed' then
    if exists (select 1 from public.bank_transactions t where t.import_file_id = new.id and t.match_status = 'new') then
      raise exception '取込の途中の明細が残っているため、確定できません';
    end if;
  end if;
  return new;
end $$;
revoke all on function public.bank_import_files_guard() from public, anon, authenticated;
drop trigger if exists bank_import_files_guard_trg on public.bank_import_files;
create trigger bank_import_files_guard_trg before insert or update or delete on public.bank_import_files
  for each row execute function public.bank_import_files_guard();

-- =====================================================================
-- E. 訂正の手続き（本部・社長・マスターだけ。理由が必須。確定済みの明細を直せる唯一の入り口）
--    直せるのは「管理項目」と「管理上の訂正値（adj_*）」だけ。原本の事実（日付・摘要・入出金額・残高）は、ここからも変えられない。
--    adj_* に JSON の null を渡すと、訂正を取り消して原本の値に戻る。
-- =====================================================================
create or replace function public.bank_tx_correct(p_id uuid, p_changes jsonb, p_reason text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_old public.bank_transactions%rowtype;
  v_allowed text[] := array['store_id','tx_kind','counts_as_sales_deposit','confirm_status',
                            'adj_txn_date','adj_description','adj_deposit_amount','adj_withdrawal_amount'];
  k text;
  v_name text;
  v_corp uuid;
begin
  if not public.bank_ledger_admin() then raise exception '権限がありません'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception '訂正の理由が必要です'; end if;
  if p_changes is null or jsonb_typeof(p_changes) <> 'object' or p_changes = '{}'::jsonb then raise exception '変更内容がありません'; end if;
  for k in select jsonb_object_keys(p_changes) loop
    if not (k = any (v_allowed)) then raise exception '変更できない項目です（原本の事実は変えられません）: %', k; end if;
  end loop;
  select * into v_old from public.bank_transactions where id = p_id for update;
  if not found then raise exception '明細が見つかりません'; end if;
  if p_changes ? 'store_id' then
    select s.corporation_id into v_corp from public.stores s where s.id = nullif(p_changes ->> 'store_id', '')::uuid;
  end if;
  select coalesce(u.name, u.id::text) into v_name from public.users u where u.id = auth.uid();
  perform set_config('app.bank_correction', 'on', true);
  perform set_config('app.bank_reason', btrim(p_reason), true);
  perform set_config('app.bank_actor', coalesce(v_name, 'user'), true);
  update public.bank_transactions t set
    store_id                = case when p_changes ? 'store_id' then nullif(p_changes ->> 'store_id', '')::uuid else t.store_id end,
    corporation_id          = case when p_changes ? 'store_id' then v_corp else t.corporation_id end,
    tx_kind                 = case when p_changes ? 'tx_kind' then p_changes ->> 'tx_kind' else t.tx_kind end,
    counts_as_sales_deposit = case when p_changes ? 'counts_as_sales_deposit' then (p_changes ->> 'counts_as_sales_deposit')::boolean else t.counts_as_sales_deposit end,
    adj_txn_date            = case when p_changes ? 'adj_txn_date' then nullif(p_changes ->> 'adj_txn_date', '')::date else t.adj_txn_date end,
    adj_description         = case when p_changes ? 'adj_description' then p_changes ->> 'adj_description' else t.adj_description end,
    adj_deposit_amount      = case when p_changes ? 'adj_deposit_amount' then nullif(p_changes ->> 'adj_deposit_amount', '')::bigint else t.adj_deposit_amount end,
    adj_withdrawal_amount   = case when p_changes ? 'adj_withdrawal_amount' then nullif(p_changes ->> 'adj_withdrawal_amount', '')::bigint else t.adj_withdrawal_amount end,
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
--    ビューではなく「関数」にする（owner 実行のビューは Supabase の安全性チェックで警告になるため）。関数の中で bank_store_visible により店舗ごとに絞る。
--    形は kd_deposit_daily（店舗×日・amount・deposit_count・entries[{a,m}]）と合わせてある。
--
--    ■ どの明細を集計（amount・deposit_count・entries）に入れるか（ここが「いまの数字を保つ」と「未確認の新規入金を入れない」の両立）
--        入れる : match_status が legacy_pending（移行済み・照合待ち）か verified（銀行 CSV と突き合わせ済み）で、
--                 counts_as_sales_deposit が true、店舗が決まっていて、入金額（訂正値があれば訂正値）が 0 より大きいもの
--        入れない: held（保留）・new（取込の途中）
--        → 旧シートから移した行は、いまの数字と同じになるよう、そのまま入る。
--          新しく取り込んだ行は、重複判定・残高の鎖の検証を通って verified になったものだけが入る。識別できない行は held で入らない。
--    ■ 入れなかった明細は、数字から消さずに別の列で見せる（held_count・held_amount・new_count）。画面は「保留 n 件（金額）」を必ず出す。
--    ■ 使う値: 日付・入金額・摘要は「管理上の訂正値（adj_*）があればそれ、無ければ原本の値」。
-- =====================================================================
create or replace function public.bank_deposit_daily(p_from date default null, p_to date default null)
returns table (store_id uuid, corporation_id uuid, deposit_date date, amount numeric, deposit_count integer,
               entries jsonb, legacy_pending_count integer, held_count integer, held_amount numeric, new_count integer,
               last_changed_at timestamptz)
language sql stable security definer set search_path to 'public' as $$
  with e as (
    select t.*,
           coalesce(t.adj_txn_date, t.txn_date)             as eff_date,
           coalesce(t.adj_deposit_amount, t.deposit_amount) as eff_dep,
           coalesce(t.adj_description, t.description)       as eff_desc
      from public.bank_transactions t
     where t.counts_as_sales_deposit and t.store_id is not null and public.bank_store_visible(t.store_id)
  )
  select e.store_id,
         e.corporation_id,
         e.eff_date,
         coalesce(sum(e.eff_dep) filter (where e.match_status in ('legacy_pending', 'verified')), 0)::numeric,
         (count(*) filter (where e.match_status in ('legacy_pending', 'verified')))::int,
         coalesce(jsonb_agg(jsonb_build_object('a', e.eff_dep, 'm', left(e.eff_desc, 80))
                            order by e.txn_time nulls last, e.created_at, e.id)
                  filter (where e.match_status in ('legacy_pending', 'verified')), '[]'::jsonb),
         (count(*) filter (where e.match_status = 'legacy_pending'))::int,
         (count(*) filter (where e.match_status = 'held'))::int,
         coalesce(sum(e.eff_dep) filter (where e.match_status = 'held'), 0)::numeric,
         (count(*) filter (where e.match_status = 'new'))::int,
         max(e.updated_at)
    from e
   where e.eff_dep > 0
     and (p_from is null or e.eff_date >= p_from) and (p_to is null or e.eff_date <= p_to)
   group by e.store_id, e.corporation_id, e.eff_date
$$;
comment on function public.bank_deposit_daily(date, date) is
  '店舗×日の入金（銀行明細の正本から作る）。amount には legacy_pending と verified だけが入る。held（保留）・new（取込途中）は held_*・new_count で別に出す';
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
--    置き場所の形: {銀行}/{口座ID}/{SHA-256}.csv（ファイル名に口座番号・店舗名・日時を入れない。同じ中身は同じ場所＝上書きは起きない）
--    読む＝本部・社長・マスターだけ／入れる＝同じ人（手動取込）とサービスロール（取込ジョブ）。上書き・削除の決まりは作らない＝誰もできない。
--    すでに同じ名前のバケットがあるときは、設定を変えない（公開になっていたら、気づけるよう止まる）。
-- =====================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('bank-csv-originals', 'bank-csv-originals', false, 10485760,
        array['text/csv', 'text/plain', 'application/vnd.ms-excel', 'application/octet-stream'])
on conflict (id) do nothing;

do $$
begin
  if exists (select 1 from storage.buckets where id = 'bank-csv-originals' and public) then
    raise exception 'バケット bank-csv-originals が公開になっています。中身を確認してから非公開にしてください（この SQL は既存の設定を変えません）';
  end if;
end $$;

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
