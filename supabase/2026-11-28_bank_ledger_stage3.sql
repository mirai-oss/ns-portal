-- 銀行入金明細の正本（Supabase）— 段階3: 旧シート（入金DB・DB_入金備考）の移行の箱と関数
-- 作成: 2026-11-28　状態: **下書き（未適用）**。本番への適用・旧データの本番移行は、別途承認。
-- 前提: 段階1・2 が適用済み。段階1・2のファイルは編集しない（変更はこの新しいファイルで）。
-- 設計: docs/計画書_銀行入金の正本化_段階3_2026-11-28.html ／ テスト: tools/bank-ledger-test/（PGlite と、実データの「流して必ず巻き戻す」リハーサル）
--
-- 【この SQL がやること】新しい表 7 つ・関数 10 つを足し、日次集計の関数 bank_deposit_daily を「手動調整（マイナスを含む）も数える」形に 1 つ置き換える。
--   旧シートの全行を追記専用の控えに保存 → 銀行CSV由来の既存の明細と「取引単位」で対応づけ → 対応が無い旧行だけを移行 → 差異を一覧にして、保留・承認・訂正・却下を区別して記録する。
-- 【この SQL がやらないこと】データの移行そのもの（関数を作るだけ。実行は別途承認）、既存の明細（銀行CSV由来の行）の変更、画面・GAS・BigQuery・旧シートの変更。
-- 【既存への影響】bank_deposit_daily の置き換えだけ。手動調整の行が 1 件も無い現状では、戻り値は置き換え前と完全に同じ（テストで確認）。
-- 【ロールバック】2026-11-28_bank_ledger_stage3_ROLLBACK.sql（新しい表が空のときだけ。bank_deposit_daily は元の定義に戻す）。
-- 【再実行】何度流しても同じ（create ... if not exists / create or replace）。
--
-- 旧行の同一性（内容のハッシュだけで取引を決めない）:
--   旧行の同一性は「内容ハッシュ ＋ 出現番号」。同じ内容の行が複数あれば、出現番号 1・2・3… で別々の行として扱う（統合しない）。
--   並べ替え … 内容と個数が同じなら、行番号が変わっても同じ行（出現番号で対応）。
--   追加 … 前回より個数が増えた分。修正 … 内容が変わった行は、「消えた行」と「増えた行」の組として、同じ店舗・日付などの手がかりがあれば「修正の候補」にする。
--   曖昧な変更（修正の候補・同内容の個数の増減）は、自動では確定せず、差異の一覧に出す。移行済みの行は、人が決めるまで変えない・消さない。

-- =====================================================================
-- A. テーブル
-- =====================================================================
-- A-1. 取り出し 1 回ぶん（旧シートのその時点の全行・全備考を 1 バッチとする）
create table if not exists public.bank_legacy_batches (
  id              uuid primary key default gen_random_uuid(),
  source          text not null check (source in ('gas_export', 'rehearsal', 'manual_csv')),
  extracted_at    timestamptz not null default now(),
  row_count       integer not null check (row_count >= 0),
  notes_count     integer not null default 0 check (notes_count >= 0),
  columns_present text[] not null,                     -- 取り出せた列（6 列そろえば 店舗・日付・入金額・摘要・取引時刻・登録日時）
  payload_sha256  text not null check (payload_sha256 ~ '^[0-9a-f]{64}$'),   -- 取り出した内容全体のハッシュ（同じ内容の取り出しは 1 バッチにまとまる）
  note            text,
  created_at      timestamptz not null default now(),
  constraint bank_legacy_batches_sha_uniq unique (payload_sha256)
);

-- A-2. 旧シートの全行の控え（追記専用）
create table if not exists public.bank_legacy_rows (
  id            uuid primary key default gen_random_uuid(),
  batch_id      uuid not null references public.bank_legacy_batches (id),
  row_no        integer not null check (row_no >= 1),       -- シート上の並び（並べ替えで変わりうるので、同一性には使わない）
  store_raw     text not null,                              -- シートに書かれていた店舗名のまま
  store_id      uuid references public.stores (id),         -- 店舗マスタ（別名つき）で解決。解決できなければ null
  txn_date      date not null,
  amount        bigint not null,                            -- 入金額（調整はマイナスもあり得る）
  description   text not null default '',
  token         text,                                       -- 取引時刻（PayPay は 時:分:秒／手動 CSV は #通し番号）
  registered_at timestamptz,                                -- 登録日時
  kind          text not null check (kind in ('atm', 'adjustment')),
  content_hash  text not null,                              -- 内容（店舗・日付・金額・摘要・取引時刻・登録日時）のハッシュ。同一性は content_hash ＋ ordinal
  ordinal       integer not null check (ordinal >= 1),      -- 同じ内容の行の出現番号（バッチの中で行番号の順）
  constraint bank_legacy_rows_rowno_uniq unique (batch_id, row_no),
  constraint bank_legacy_rows_ident_uniq unique (batch_id, content_hash, ordinal)
);
create index if not exists bank_legacy_rows_store_date_idx on public.bank_legacy_rows (batch_id, store_id, txn_date);

-- A-3. 旧シートの備考の控え（追記専用）
create table if not exists public.bank_legacy_notes (
  id               uuid primary key default gen_random_uuid(),
  batch_id         uuid not null references public.bank_legacy_batches (id),
  store_raw        text not null,
  store_id         uuid references public.stores (id),
  note_date        date not null,
  note             text not null,
  updated_by_label text,
  updated_at_src   timestamptz,
  constraint bank_legacy_notes_uniq unique (batch_id, store_raw, note_date)
);

-- A-4. 旧行と正本の明細の対応（旧行の同一性は legacy_key ＝ 内容ハッシュ#出現番号。バッチをまたいで同じ）
--   paired   … 銀行CSV由来の明細と 1 対 1（新しい行は作らない）
--   migrated … 銀行に対応が無い旧のみの行（正本に legacy_pending の行を作る）
--   adjustment … 手動の調整行（同じく移行。承認の対象）
--   unresolved … 店舗が決まらない（移行しない。差異の一覧へ）
create table if not exists public.bank_legacy_links (
  id             uuid primary key default gen_random_uuid(),
  legacy_key     text not null,
  first_batch_id uuid not null references public.bank_legacy_batches (id),
  kind           text not null check (kind in ('paired', 'migrated', 'adjustment', 'unresolved')),
  transaction_id uuid references public.bank_transactions (id),
  basis          text,                                      -- time（時:分が一致）／single（その日その金額が 1 対 1）／order（順番）／before_csv_window／no_bank_account／in_window_unmatched
  confidence     text not null default 'auto' check (confidence in ('auto', 'proposed', 'approved')),
  created_at     timestamptz not null default now(),
  constraint bank_legacy_links_key_uniq unique (legacy_key),
  constraint bank_legacy_links_paired_tx check (kind <> 'paired' or transaction_id is not null)
);
create unique index if not exists bank_legacy_links_paired_tx_uniq on public.bank_legacy_links (transaction_id) where kind = 'paired';

-- A-5. 差異の一覧。状態: open（未確認）／held（保留）／approved（承認）／corrected（訂正）／rejected（却下）
create table if not exists public.bank_diff_items (
  id              uuid primary key default gen_random_uuid(),
  batch_id        uuid not null references public.bank_legacy_batches (id),
  sig             text not null,                            -- 同じ差異を 2 回作らないための目印
  kind            text not null check (kind in ('bank_only', 'paired_held', 'legacy_only_in_window', 'ambiguous_pair', 'manual_adjustment', 'unresolved_store',
                                                'note_mismatch', 'added_since_prev', 'removed_since_prev', 'modified_candidate')),
  store_id        uuid references public.stores (id),
  txn_date        date,
  amount          bigint,
  description     text,
  legacy_keys     text[] not null default '{}',
  transaction_ids uuid[] not null default '{}',
  detail          jsonb not null default '{}'::jsonb,
  status          text not null default 'open' check (status in ('open', 'held', 'approved', 'corrected', 'rejected')),
  decided_at      timestamptz,
  decided_by      uuid,
  decided_reason  text,
  created_at      timestamptz not null default now(),
  constraint bank_diff_items_sig_uniq unique (sig)
);
create index if not exists bank_diff_items_status_idx on public.bank_diff_items (status, kind);

-- A-6. 承認などの操作の記録（追記専用）。1 回の操作＝対象の一覧・理由・操作者・日時。
create table if not exists public.bank_decision_batches (
  id          uuid primary key default gen_random_uuid(),
  mode        text not null check (mode in ('single', 'bulk')),
  decision    text not null check (decision in ('approved', 'held', 'rejected', 'corrected')),
  reason      text not null check (btrim(reason) <> ''),
  actor_id    uuid,
  actor_label text,
  item_ids    uuid[] not null,
  item_count  integer not null check (item_count >= 1),
  total_amount numeric,                                   -- 対象の金額の合計（符号つき）。一括の承認では、操作者が確認した件数・合計と一致したことの証拠になる
  expected_count integer, expected_total numeric,         -- 操作者が「確認した」と申告した件数・合計（一括は必須）
  decided_at  timestamptz not null default now()
);
create table if not exists public.bank_diff_decisions (
  id          uuid primary key default gen_random_uuid(),
  batch_id    uuid not null references public.bank_decision_batches (id),
  item_id     uuid not null references public.bank_diff_items (id),
  from_status text not null,
  to_status   text not null,
  decided_at  timestamptz not null default now()
);
create index if not exists bank_diff_decisions_item_idx on public.bank_diff_decisions (item_id, decided_at desc);

-- A-7. 手動調整（マイナスを含む）は、銀行の実際の入出金とは別物。銀行口座に結び付いた行（＝実際の銀行明細）は、調整にできない。
--      → マイナスの調整は「出金側に絶対値で」入るが、銀行の出金としては数えない（bank_account_id が空・旧シート由来か手入力の行だけが調整）。
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'bank_tx_adjustment_not_bank_row' and conrelid = 'public.bank_transactions'::regclass) then
    alter table public.bank_transactions add constraint bank_tx_adjustment_not_bank_row
      check (tx_kind <> 'adjustment' or (bank_account_id is null and source_kind in ('legacy_sheet', 'manual_entry')));
  end if;
end $$;

-- =====================================================================
-- B. 権限（段階1と同じ: 本部・社長・マスターだけが読める。画面からは書けない）と、守り
-- =====================================================================
alter table public.bank_legacy_batches   enable row level security;
alter table public.bank_legacy_rows      enable row level security;
alter table public.bank_legacy_notes     enable row level security;
alter table public.bank_legacy_links     enable row level security;
alter table public.bank_diff_items       enable row level security;
alter table public.bank_decision_batches enable row level security;
alter table public.bank_diff_decisions   enable row level security;
drop policy if exists bank_legacy_batches_read on public.bank_legacy_batches;
create policy bank_legacy_batches_read on public.bank_legacy_batches for select to authenticated using (public.bank_ledger_admin());
drop policy if exists bank_legacy_rows_read on public.bank_legacy_rows;
create policy bank_legacy_rows_read on public.bank_legacy_rows for select to authenticated using (public.bank_ledger_admin());
drop policy if exists bank_legacy_notes_read on public.bank_legacy_notes;
create policy bank_legacy_notes_read on public.bank_legacy_notes for select to authenticated using (public.bank_ledger_admin());
drop policy if exists bank_legacy_links_read on public.bank_legacy_links;
create policy bank_legacy_links_read on public.bank_legacy_links for select to authenticated using (public.bank_ledger_admin());
drop policy if exists bank_diff_items_read on public.bank_diff_items;
create policy bank_diff_items_read on public.bank_diff_items for select to authenticated using (public.bank_ledger_admin());
drop policy if exists bank_decision_batches_read on public.bank_decision_batches;
create policy bank_decision_batches_read on public.bank_decision_batches for select to authenticated using (public.bank_ledger_admin());
drop policy if exists bank_diff_decisions_read on public.bank_diff_decisions;
create policy bank_diff_decisions_read on public.bank_diff_decisions for select to authenticated using (public.bank_ledger_admin());
revoke all on public.bank_legacy_batches, public.bank_legacy_rows, public.bank_legacy_notes, public.bank_legacy_links, public.bank_diff_items,
              public.bank_decision_batches, public.bank_diff_decisions from anon, authenticated;
grant select on public.bank_legacy_batches, public.bank_legacy_rows, public.bank_legacy_notes, public.bank_legacy_links, public.bank_diff_items,
                public.bank_decision_batches, public.bank_diff_decisions to authenticated;

-- 追記専用（更新・削除できない）: 取り出しの控え・備考の控え・操作の記録
drop trigger if exists bank_legacy_batches_append_only on public.bank_legacy_batches;
create trigger bank_legacy_batches_append_only before update or delete on public.bank_legacy_batches for each row execute function public.bank_append_only();
drop trigger if exists bank_legacy_rows_append_only on public.bank_legacy_rows;
create trigger bank_legacy_rows_append_only before update or delete on public.bank_legacy_rows for each row execute function public.bank_append_only();
drop trigger if exists bank_legacy_notes_append_only on public.bank_legacy_notes;
create trigger bank_legacy_notes_append_only before update or delete on public.bank_legacy_notes for each row execute function public.bank_append_only();
drop trigger if exists bank_decision_batches_append_only on public.bank_decision_batches;
create trigger bank_decision_batches_append_only before update or delete on public.bank_decision_batches for each row execute function public.bank_append_only();
drop trigger if exists bank_diff_decisions_append_only on public.bank_diff_decisions;
create trigger bank_diff_decisions_append_only before update or delete on public.bank_diff_decisions for each row execute function public.bank_append_only();

-- 対応・差異は、削除できない。変えられるのは「あとから決まる欄」だけ（対応の明細・確からしさ／差異の状態・決定）
create or replace function public.bank_legacy_guard()
returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception '% は削除できません', tg_table_name; end if;
  if tg_table_name = 'bank_legacy_links' then
    if new.legacy_key is distinct from old.legacy_key or new.kind is distinct from old.kind or new.first_batch_id is distinct from old.first_batch_id then
      raise exception '旧行の対応の種類・識別は変更できません';
    end if;
    if old.transaction_id is not null and new.transaction_id is distinct from old.transaction_id then
      raise exception '結んだ明細は変更できません';
    end if;
  else
    if new.sig is distinct from old.sig or new.kind is distinct from old.kind or new.batch_id is distinct from old.batch_id
       or new.legacy_keys is distinct from old.legacy_keys or new.transaction_ids is distinct from old.transaction_ids
       or new.store_id is distinct from old.store_id or new.txn_date is distinct from old.txn_date or new.amount is distinct from old.amount then
      raise exception '差異の内容は変更できません（状態と決定だけ変えられます）';
    end if;
  end if;
  return new;
end $$;
revoke all on function public.bank_legacy_guard() from public, anon, authenticated;
drop trigger if exists bank_legacy_links_guard_trg on public.bank_legacy_links;
create trigger bank_legacy_links_guard_trg before update or delete on public.bank_legacy_links for each row execute function public.bank_legacy_guard();
drop trigger if exists bank_diff_items_guard_trg on public.bank_diff_items;
create trigger bank_diff_items_guard_trg before update or delete on public.bank_diff_items for each row execute function public.bank_legacy_guard();

-- =====================================================================
-- C. 日次集計の置き換え: 手動調整（マイナスを含む）も数える。それ以外の動きは段階1と同じ。
--    調整の行は、入金額 − 出金額（＝符号つきの金額）で数える。調整でない行は、入金額 > 0 だけ（従来どおり）。
-- =====================================================================
create or replace function public.bank_deposit_daily(p_from date default null, p_to date default null)
returns table (store_id uuid, corporation_id uuid, deposit_date date, amount numeric, deposit_count integer,
               entries jsonb, legacy_pending_count integer, held_count integer, held_amount numeric, new_count integer,
               last_changed_at timestamptz)
language sql stable security definer set search_path to 'public' as $$
  with e as (
    select t.*,
           coalesce(t.adj_txn_date, t.txn_date) as eff_date,
           coalesce(t.adj_deposit_amount, t.deposit_amount)
             - (case when t.tx_kind = 'adjustment' then coalesce(t.adj_withdrawal_amount, t.withdrawal_amount) else 0 end) as eff_dep,
           coalesce(t.adj_description, t.description) as eff_desc
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
   where (e.eff_dep > 0 or e.tx_kind = 'adjustment')
     and (p_from is null or e.eff_date >= p_from) and (p_to is null or e.eff_date <= p_to)
   group by e.store_id, e.corporation_id, e.eff_date
$$;
revoke all on function public.bank_deposit_daily(date, date) from public, anon;
grant execute on function public.bank_deposit_daily(date, date) to authenticated, service_role;

-- =====================================================================
-- D. 関数（取込・計画・移行はサービスロールだけ／承認は本部・社長・マスターだけ）
-- =====================================================================
-- D-1. 取り出した内容の保存（旧シートの全行・全備考）。同じ内容（ハッシュが同じ）の取り出しは、新しいバッチを作らず、既存のバッチを返す。
--   p_meta: {source, columns_present:[…], payload_sha256, note}
--   p_rows: [{row_no, store, store_id, date, amount, desc, token, registered_at}]  p_notes: [{store, store_id, date, note, updated_by, updated_at}]
create or replace function public.bank_legacy_load(p_meta jsonb, p_rows jsonb, p_notes jsonb default '[]'::jsonb)
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid; v_sha text := p_meta ->> 'payload_sha256'; v_n int;
begin
  perform public.bank_assert_service();
  select id into v_id from public.bank_legacy_batches where payload_sha256 = v_sha;
  if found then return v_id; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_typeof(p_notes) <> 'array' then raise exception 'rows・notes は配列で渡してください'; end if;
  insert into public.bank_legacy_batches (source, row_count, notes_count, columns_present, payload_sha256, note)
  values (p_meta ->> 'source', jsonb_array_length(p_rows), jsonb_array_length(p_notes),
          array(select jsonb_array_elements_text(p_meta -> 'columns_present')), v_sha, p_meta ->> 'note') returning id into v_id;
  insert into public.bank_legacy_rows (batch_id, row_no, store_raw, store_id, txn_date, amount, description, token, registered_at, kind, content_hash, ordinal)
  select v_id, x.row_no, x.store, x.store_id, x.dt, x.amount, x.descr, x.token, x.reg,
         case when x.amount <= 0 or x.descr ~ '^(調整|sss)' then 'adjustment' else 'atm' end,
         x.h, row_number() over (partition by x.h order by x.row_no)
    from (select (r ->> 'row_no')::int row_no, r ->> 'store' store, nullif(r ->> 'store_id', '')::uuid store_id, (r ->> 'date')::date dt,
                 (r ->> 'amount')::bigint amount, coalesce(r ->> 'desc', '') descr, nullif(r ->> 'token', '') token, nullif(r ->> 'registered_at', '')::timestamptz reg,
                 md5(concat_ws('|', r ->> 'store', r ->> 'date', r ->> 'amount', coalesce(r ->> 'desc', ''), coalesce(r ->> 'token', ''), coalesce(r ->> 'registered_at', ''))) h
            from jsonb_array_elements(p_rows) r) x;
  insert into public.bank_legacy_notes (batch_id, store_raw, store_id, note_date, note, updated_by_label, updated_at_src)
  select v_id, n ->> 'store', nullif(n ->> 'store_id', '')::uuid, (n ->> 'date')::date, n ->> 'note', n ->> 'updated_by', nullif(n ->> 'updated_at', '')::timestamptz
    from jsonb_array_elements(p_notes) n;
  select count(*) into v_n from public.bank_legacy_rows where batch_id = v_id;
  if v_n <> jsonb_array_length(p_rows) then raise exception '保存した行数が一致しません（% / %）', v_n, jsonb_array_length(p_rows); end if;
  return v_id;
end $$;

-- D-2. 取引単位の突き合わせと、差異の一覧づくり（書くのは「対応」と「差異」だけ。既存の明細には触れない）。何度流しても同じ。
create or replace function public.bank_legacy_plan(p_batch uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_paired int := 0; v_mig int := 0; v_adj int := 0; v_unres int := 0; v_inwin int := 0; v_bank_only int := 0; v_amb int := 0; v_ph int := 0; n int;
begin
  perform public.bank_assert_service();
  if not exists (select 1 from public.bank_legacy_batches where id = p_batch) then raise exception 'バッチが見つかりません'; end if;
  -- 対象の旧行（まだ対応づけていない行だけ。同一性は 内容ハッシュ#出現番号）
  drop table if exists _bl_l; drop table if exists _bl_t; drop table if exists _bl_p;
  create temporary table _bl_l on commit drop as
    select r.id, r.content_hash || '#' || r.ordinal as lkey, r.kind, r.store_id, r.txn_date, r.amount, r.row_no, r.description,
           case when r.token ~ '^\d{1,2}:\d{2}' then lpad(split_part(r.token, ':', 1), 2, '0') || ':' || left(split_part(r.token, ':', 2), 2) end as hhmm
      from public.bank_legacy_rows r
     where r.batch_id = p_batch and not exists (select 1 from public.bank_legacy_links k where k.legacy_key = r.content_hash || '#' || r.ordinal);
  -- A. 店舗が決まらない行・手動の調整行
  insert into public.bank_legacy_links (legacy_key, first_batch_id, kind, basis)
    select lkey, p_batch, 'unresolved', 'no_store' from _bl_l where store_id is null on conflict (legacy_key) do nothing;
  get diagnostics v_unres = row_count;
  insert into public.bank_diff_items (batch_id, sig, kind, store_id, txn_date, amount, description, legacy_keys, detail)
    select p_batch, 'unresolved|' || lkey, 'unresolved_store', null, txn_date, amount, description, array[lkey], jsonb_build_object('row_no', row_no)
      from _bl_l where store_id is null on conflict (sig) do nothing;
  insert into public.bank_legacy_links (legacy_key, first_batch_id, kind, basis)
    select lkey, p_batch, 'adjustment', 'manual_adjustment' from _bl_l where store_id is not null and kind = 'adjustment' on conflict (legacy_key) do nothing;
  get diagnostics v_adj = row_count;
  insert into public.bank_diff_items (batch_id, sig, kind, store_id, txn_date, amount, description, legacy_keys, detail)
    select p_batch, 'adjustment|' || lkey, 'manual_adjustment', store_id, txn_date, amount, description, array[lkey],
           -- 個別確認の対象: 高額（300 万円以上）・マイナス・ゼロ（金額が 0 以下）。複数に当てはまる行も 1 件として数える（review_class は 1 つ）。
           -- numbers_preserved: 移行で数字は維持される（自動）。この差異の「承認」は、調整内容が正当かどうかの確認で、数字の維持とは別。
           jsonb_build_object('row_no', row_no, 'high', abs(amount) >= 3000000, 'negative', amount < 0, 'zero', amount = 0,
                              'review_class', case when amount <= 0 or abs(amount) >= 3000000 then 'individual' else 'bulk' end, 'numbers_preserved', true)
      from _bl_l where store_id is not null and kind = 'adjustment' on conflict (sig) do nothing;
  -- B. 銀行CSV由来の明細（まだ旧行と結んでいないもの）
  create temporary table _bl_t on commit drop as
    select t.id, t.store_id, t.txn_date, t.deposit_amount as amount, t.txn_time, t.dedupe_key, t.match_status,
           to_char(t.txn_time, 'HH24:MI') as hhmm
      from public.bank_transactions t
     where t.source_kind in ('playwright', 'manual_csv') and t.counts_as_sales_deposit and t.deposit_amount > 0 and t.store_id is not null
       and t.match_status in ('verified', 'held')
       and not exists (select 1 from public.bank_legacy_links k where k.kind = 'paired' and k.transaction_id = t.id);
  -- C. 対応づけ: ①時:分が一致するもの同士 ②残りを、その日その金額の中で順番に
  create temporary table _bl_p (lid uuid, lkey text, tid uuid, basis text, confidence text) on commit drop;
  insert into _bl_p
    select l.id, l.lkey, t.id, 'time', 'auto'
      from (select *, row_number() over (partition by store_id, txn_date, amount, hhmm order by row_no) rn from _bl_l where kind = 'atm' and store_id is not null and hhmm is not null) l
      join (select *, row_number() over (partition by store_id, txn_date, amount, hhmm order by txn_time, dedupe_key) rn from _bl_t where hhmm is not null) t
        on l.store_id = t.store_id and l.txn_date = t.txn_date and l.amount = t.amount and l.hhmm = t.hhmm and l.rn = t.rn;
  insert into _bl_p
    select l.id, l.lkey, t.id, case when g.nl = 1 and g.nt = 1 then 'single' else 'order' end, case when g.nl = 1 and g.nt = 1 then 'auto' else 'proposed' end
      from (select *, row_number() over (partition by store_id, txn_date, amount order by row_no) rn from _bl_l l0
             where kind = 'atm' and store_id is not null and not exists (select 1 from _bl_p p where p.lid = l0.id)) l
      join (select *, row_number() over (partition by store_id, txn_date, amount order by txn_time nulls last, dedupe_key) rn from _bl_t t0
             where not exists (select 1 from _bl_p p where p.tid = t0.id)) t
        on l.store_id = t.store_id and l.txn_date = t.txn_date and l.amount = t.amount and l.rn = t.rn
      join (select store_id, txn_date, amount, count(*) filter (where src = 'l') nl, count(*) filter (where src = 't') nt
              from (select store_id, txn_date, amount, 'l' src from _bl_l where kind = 'atm' and store_id is not null
                    union all select store_id, txn_date, amount, 't' from _bl_t) u group by 1, 2, 3) g
        on g.store_id = l.store_id and g.txn_date = l.txn_date and g.amount = l.amount;
  insert into public.bank_legacy_links (legacy_key, first_batch_id, kind, transaction_id, basis, confidence)
    select lkey, p_batch, 'paired', tid, basis, confidence from _bl_p on conflict (legacy_key) do nothing;
  get diagnostics v_paired = row_count;
  insert into public.bank_diff_items (batch_id, sig, kind, store_id, txn_date, amount, description, legacy_keys, transaction_ids, detail)
    select p_batch, 'ambiguous|' || p.lkey, 'ambiguous_pair', l.store_id, l.txn_date, l.amount, l.description, array[p.lkey], array[p.tid], jsonb_build_object('basis', p.basis)
      from _bl_p p join _bl_l l on l.id = p.lid where p.confidence = 'proposed' on conflict (sig) do nothing;
  get diagnostics v_amb = row_count;
  -- 旧シートに対応があるのに、銀行側の明細が保留のままのもの（例: 店舗名の別表記で「旧に無い」と見えていた入金）。保留の行は集計に入らないので、旧と数字がずれる → 人が解くまで差異として残す
  insert into public.bank_diff_items (batch_id, sig, kind, store_id, txn_date, amount, description, legacy_keys, transaction_ids, status, detail)
    select p_batch, 'pairedheld|' || p.tid, 'paired_held', l.store_id, l.txn_date, l.amount, l.description, array[p.lkey], array[p.tid], 'held',
           jsonb_build_object('hold_reason', tx.hold_reason, 'basis', p.basis)
      from _bl_p p join _bl_l l on l.id = p.lid join public.bank_transactions tx on tx.id = p.tid where tx.match_status = 'held' on conflict (sig) do nothing;
  get diagnostics v_ph = row_count;
  -- D. 対応が無い旧行 → 移行（旧のみ）。銀行CSVの期間の中なら「旧のみ（要確認）」の差異にする
  insert into public.bank_legacy_links (legacy_key, first_batch_id, kind, basis)
    select l.lkey, p_batch, 'migrated',
           case when cov.d0 is null then 'no_bank_account' when l.txn_date < cov.d0 then 'before_csv_window' else 'in_window_unmatched' end
      from _bl_l l left join (select store_id, min(txn_date) d0 from public.bank_transactions where source_kind in ('playwright', 'manual_csv') and store_id is not null group by 1) cov on cov.store_id = l.store_id
     where l.kind = 'atm' and l.store_id is not null and not exists (select 1 from _bl_p p where p.lid = l.id)
    on conflict (legacy_key) do nothing;
  get diagnostics v_mig = row_count;
  insert into public.bank_diff_items (batch_id, sig, kind, store_id, txn_date, amount, description, legacy_keys, detail)
    select p_batch, 'inwin|' || l.lkey, 'legacy_only_in_window', l.store_id, l.txn_date, l.amount, l.description, array[l.lkey], jsonb_build_object('row_no', l.row_no)
      from _bl_l l join public.bank_legacy_links k on k.legacy_key = l.lkey and k.basis = 'in_window_unmatched' on conflict (sig) do nothing;
  get diagnostics v_inwin = row_count;
  -- E. 旧に対応が無い銀行の明細 → 差異（保留中の行は held、それ以外は open。当日分は時刻差の可能性を detail に残す）
  insert into public.bank_diff_items (batch_id, sig, kind, store_id, txn_date, amount, description, transaction_ids, status, detail)
    select p_batch, 'bankonly|' || t.id, 'bank_only', t.store_id, t.txn_date, t.amount, tx.description, array[t.id],
           case when t.match_status = 'held' then 'held' else 'open' end,
           jsonb_build_object('match_status', t.match_status, 'hold_reason', tx.hold_reason, 'timing', t.txn_date >= (now() at time zone 'Asia/Tokyo')::date)
      from _bl_t t join public.bank_transactions tx on tx.id = t.id
     where not exists (select 1 from _bl_p p where p.tid = t.id) on conflict (sig) do nothing;
  get diagnostics v_bank_only = row_count;
  return jsonb_build_object('paired', v_paired, 'migrated', v_mig, 'adjustments', v_adj, 'unresolved', v_unres,
                            'ambiguous_pairs', v_amb, 'paired_held', v_ph, 'legacy_only_in_window', v_inwin, 'bank_only', v_bank_only);
end $$;

-- D-3. 取り出しどうしの変化（並べ替え・追加・削除・修正）を見分けて、曖昧なものを差異の一覧に出す。自動では確定しない。
--   同じ内容の行は 出現番号 で数える: 個数が増えた分＝追加、減った分＝削除。内容が変わった行は「削除」と「追加」の組になり、
--   同じ店舗・日付（または同じ登録日時）が手がかりなら「修正の候補」にする（追加された側の移行を、人が決めるまで止める）。
create or replace function public.bank_legacy_changes(p_new uuid, p_prev uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_added int := 0; v_removed int := 0; v_mod int := 0; v_reordered int := 0;
begin
  perform public.bank_assert_service();
  if p_new = p_prev then raise exception '同じバッチどうしは比べられません'; end if;
  drop table if exists _bl_add; drop table if exists _bl_rem;
  create temporary table _bl_add on commit drop as
    select n.* from public.bank_legacy_rows n where n.batch_id = p_new
       and not exists (select 1 from public.bank_legacy_rows o where o.batch_id = p_prev and o.content_hash = n.content_hash and o.ordinal = n.ordinal);
  create temporary table _bl_rem on commit drop as
    select o.* from public.bank_legacy_rows o where o.batch_id = p_prev
       and not exists (select 1 from public.bank_legacy_rows n where n.batch_id = p_new and n.content_hash = o.content_hash and n.ordinal = o.ordinal);
  select count(*) into v_reordered from public.bank_legacy_rows n join public.bank_legacy_rows o
    on o.batch_id = p_prev and o.content_hash = n.content_hash and o.ordinal = n.ordinal where n.batch_id = p_new and n.row_no <> o.row_no;
  -- 修正の候補: 消えた行と増えた行が、同じ店舗・日付で、内容（金額か摘要）だけ違う（1 対 1 に決まるものだけ。決まらないものは追加・削除のまま）
  create temporary table _bl_m on commit drop as
    select a.id aid, r.id rid from (select *, row_number() over (partition by store_raw, txn_date order by row_no) rn, count(*) over (partition by store_raw, txn_date) c from _bl_add) a
      join (select *, row_number() over (partition by store_raw, txn_date order by row_no) rn, count(*) over (partition by store_raw, txn_date) c from _bl_rem) r
        on a.store_raw = r.store_raw and a.txn_date = r.txn_date and a.rn = r.rn and a.c = 1 and r.c = 1;
  insert into public.bank_diff_items (batch_id, sig, kind, store_id, txn_date, amount, description, legacy_keys, detail)
    select p_new, 'mod|' || r.content_hash || '#' || r.ordinal || '>' || a.content_hash || '#' || a.ordinal, 'modified_candidate', a.store_id, a.txn_date, a.amount, a.description,
           array[r.content_hash || '#' || r.ordinal, a.content_hash || '#' || a.ordinal],
           jsonb_build_object('before', jsonb_build_object('amount', r.amount, 'description', r.description, 'token', r.token),
                              'after', jsonb_build_object('amount', a.amount, 'description', a.description, 'token', a.token), 'hold_migrate', true)
      from _bl_m m join _bl_add a on a.id = m.aid join _bl_rem r on r.id = m.rid on conflict (sig) do nothing;
  get diagnostics v_mod = row_count;
  insert into public.bank_diff_items (batch_id, sig, kind, store_id, txn_date, amount, description, legacy_keys, detail)
    select p_new, 'added|' || a.content_hash || '#' || a.ordinal, 'added_since_prev', a.store_id, a.txn_date, a.amount, a.description, array[a.content_hash || '#' || a.ordinal],
           jsonb_build_object('same_content_count_changed', exists (select 1 from public.bank_legacy_rows o where o.batch_id = p_prev and o.content_hash = a.content_hash))
      from _bl_add a where a.id not in (select aid from _bl_m) on conflict (sig) do nothing;
  get diagnostics v_added = row_count;
  insert into public.bank_diff_items (batch_id, sig, kind, store_id, txn_date, amount, description, legacy_keys, detail)
    select p_new, 'removed|' || r.content_hash || '#' || r.ordinal, 'removed_since_prev', r.store_id, r.txn_date, r.amount, r.description, array[r.content_hash || '#' || r.ordinal],
           jsonb_build_object('same_content_count_changed', exists (select 1 from public.bank_legacy_rows n where n.batch_id = p_new and n.content_hash = r.content_hash))
      from _bl_rem r where r.id not in (select rid from _bl_m) on conflict (sig) do nothing;
  get diagnostics v_removed = row_count;
  return jsonb_build_object('added', v_added, 'removed', v_removed, 'modified_candidates', v_mod, 'reordered_rows', v_reordered);
end $$;

-- D-4. 旧のみの行・調整行を、正本の明細として移行（legacy_pending）。既存の明細（銀行CSV由来）には触れない。何度流しても同じ。
--   人が決めるまで移行を止める行: 修正の候補の「増えた側」（detail.hold_migrate が true で、まだ open / held のもの）。
create or replace function public.bank_legacy_migrate(p_batch uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_n int := 0; v_skipped int := 0;
begin
  perform public.bank_assert_service();
  with todo as (
    select k.id link_id, r.*, k.kind lkind
      from public.bank_legacy_links k
      join public.bank_legacy_rows r on r.batch_id = p_batch and r.content_hash || '#' || r.ordinal = k.legacy_key
     where k.kind in ('migrated', 'adjustment') and k.transaction_id is null and r.store_id is not null
       and not exists (select 1 from public.bank_diff_items d where d.kind = 'modified_candidate' and d.status in ('open', 'held')
                         and (d.detail ->> 'hold_migrate')::boolean and d.legacy_keys[2] = k.legacy_key)),
  ins as (
    insert into public.bank_transactions (corporation_id, store_id, txn_date, description, deposit_amount, withdrawal_amount, source_kind, match_status,
                                          tx_kind, counts_as_sales_deposit, legacy_batch, legacy_seq, legacy_payload)
    select s.corporation_id, t.store_id, t.txn_date, t.description, greatest(t.amount, 0), greatest(-t.amount, 0), 'legacy_sheet', 'legacy_pending',
           case when t.lkind = 'adjustment' then 'adjustment' else 'atm_deposit' end, true, t.content_hash, t.ordinal,
           jsonb_build_object('store', t.store_raw, 'date', t.txn_date, 'amount', t.amount, 'desc', t.description, 'token', t.token, 'registered_at', t.registered_at)
      from todo t join public.stores s on s.id = t.store_id
    on conflict (legacy_batch, legacy_seq) where legacy_batch is not null do nothing
    returning id, legacy_batch, legacy_seq)
  update public.bank_legacy_links k set transaction_id = i.id from ins i where k.legacy_key = i.legacy_batch || '#' || i.legacy_seq;
  get diagnostics v_n = row_count;
  -- 途中で止まったあとの再実行: すでに移行済みの明細があるのに対応が空の行を結び直す（行は増やさない）
  update public.bank_legacy_links k set transaction_id = t.id from public.bank_transactions t
   where k.transaction_id is null and k.kind in ('migrated', 'adjustment') and t.source_kind = 'legacy_sheet' and t.legacy_batch || '#' || t.legacy_seq = k.legacy_key;
  select count(*) into v_skipped from public.bank_legacy_links where kind in ('migrated', 'adjustment') and transaction_id is null;
  return jsonb_build_object('migrated_rows', v_n, 'still_unmigrated', v_skipped);
end $$;

-- D-5. 備考の移行: 既存の備考が無い（店舗×日付）だけ入れる。違う文面が既にあれば上書きせず、差異の一覧へ。店舗が決まらない備考も差異へ。
create or replace function public.bank_legacy_migrate_notes(p_batch uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_ins int := 0; v_same int := 0; v_diff int := 0; v_unres int := 0;
begin
  perform public.bank_assert_service();
  insert into public.bank_deposit_notes (store_id, note_date, note, updated_by_label, updated_at)
    select n.store_id, n.note_date, n.note, coalesce(n.updated_by_label, '旧シートから移行'), coalesce(n.updated_at_src, now())
      from public.bank_legacy_notes n where n.batch_id = p_batch and n.store_id is not null
    on conflict (store_id, note_date) do nothing;
  get diagnostics v_ins = row_count;
  select count(*) into v_same from public.bank_legacy_notes n join public.bank_deposit_notes d on d.store_id = n.store_id and d.note_date = n.note_date and d.note = n.note where n.batch_id = p_batch;
  insert into public.bank_diff_items (batch_id, sig, kind, store_id, txn_date, description, detail)
    select p_batch, 'note|' || n.store_id || '|' || n.note_date, 'note_mismatch', n.store_id, n.note_date, left(n.note, 80), jsonb_build_object('legacy_note', n.note, 'ledger_note', d.note)
      from public.bank_legacy_notes n join public.bank_deposit_notes d on d.store_id = n.store_id and d.note_date = n.note_date and d.note <> n.note
     where n.batch_id = p_batch on conflict (sig) do nothing;
  get diagnostics v_diff = row_count;
  insert into public.bank_diff_items (batch_id, sig, kind, txn_date, description, detail)
    select p_batch, 'noteunres|' || n.store_raw || '|' || n.note_date, 'unresolved_store', n.note_date, left(n.note, 80), jsonb_build_object('store_raw', n.store_raw, 'is_note', true)
      from public.bank_legacy_notes n where n.batch_id = p_batch and n.store_id is null on conflict (sig) do nothing;
  get diagnostics v_unres = row_count;
  return jsonb_build_object('inserted', v_ins, 'same', v_same, 'mismatch', v_diff, 'unresolved', v_unres);
end $$;

-- D-6. 差異の決定（個別・一括）。本部・社長・マスターだけ。理由が必須。対象の一覧・理由・操作者・日時（と件数・合計）を、決定の記録（追記専用）に残す。
--   approved  … このままでよい（旧のみ・調整行・曖昧な対応づけ）。銀行側の保留中の行は、保留を解いて照合済みにする（履歴に release が残る）
--   held      … 保留のまま（理由を残すだけ）
--   rejected  … 集計に入れない（対象の明細の「売上入金として数える」を外す。行は残る。履歴に correct が残る）。これは数字が変わる決定
--   corrected … 訂正した（先に bank_tx_correct で訂正してあることを確かめる）
--   【数字の維持と、調整の正当性の承認は別】手動調整の行は、移行した時点で数字は維持される（自動）。ここでの「承認」は、その調整が正当かどうかを人が確認した記録で、数字は変えない。
--   【個別確認の対象】高額（300 万円以上）・マイナス・ゼロの調整（review_class=individual）は、1 件ずつしか承認・却下できない（一括に混ぜられない）。
--   【一括の確認】2 件以上を approved / rejected にするときは、操作者が一覧で確認した「件数」と「合計（符号つき）」を渡す。実際の対象と一致しなければ拒否する（見ていないものを承認しない）。
--   【保留の解除（paired_held）の条件】旧の行と銀行の明細が、同じ店舗ID・同じ日付・同じ金額で、1 対 1（確からしさが auto か approved）と確かめられた場合だけ解ける。
--   p_kind を渡すと、対象がすべてその種類であることを確かめる（一括承認の取り違え防止）。
create or replace function public.bank_diff_decide(p_item_ids uuid[], p_decision text, p_reason text, p_kind text default null,
                                                   p_expect_count integer default null, p_expect_total numeric default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_batch uuid; v_it public.bank_diff_items%rowtype; v_name text; v_n int := 0; v_tx uuid; v_ids uuid[]; v_cnt int; v_total numeric; v_mode text;
begin
  if not public.bank_ledger_admin() then raise exception '権限がありません'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception '理由が必要です'; end if;
  if p_decision not in ('approved', 'held', 'rejected', 'corrected') then raise exception '決定は approved / held / rejected / corrected のどれかです'; end if;
  select array_agg(distinct x) into v_ids from unnest(coalesce(p_item_ids, '{}')) x;
  if v_ids is null or array_length(v_ids, 1) < 1 then raise exception '対象が空です'; end if;
  v_cnt := array_length(v_ids, 1); v_mode := case when v_cnt = 1 then 'single' else 'bulk' end;
  if (select count(*) from public.bank_diff_items where id = any (v_ids)) <> v_cnt then raise exception '存在しない差異が含まれています'; end if;
  if p_kind is not null and exists (select 1 from public.bank_diff_items where id = any (v_ids) and kind <> p_kind) then raise exception '指定した種類（%）以外の差異が含まれています', p_kind; end if;
  select coalesce(sum(coalesce(amount, 0)), 0) into v_total from public.bank_diff_items where id = any (v_ids);
  -- 個別確認の対象（高額・マイナス・ゼロ）は、一括にできない
  if v_mode = 'bulk' and p_decision in ('approved', 'rejected')
     and exists (select 1 from public.bank_diff_items where id = any (v_ids) and detail ->> 'review_class' = 'individual') then
    raise exception '個別確認が必要な行（高額・マイナス・ゼロの調整）が含まれています。1 件ずつ承認・却下してください';
  end if;
  -- 一括の承認・却下は、確認した件数と合計が実際と一致していること
  if v_mode = 'bulk' and p_decision in ('approved', 'rejected') then
    if p_expect_count is null or p_expect_total is null then raise exception '一括の承認・却下には、確認した件数と合計（符号つき）が必要です'; end if;
    if p_expect_count <> v_cnt or p_expect_total <> v_total then raise exception '確認した件数・合計（% 件・%）が、実際の対象（% 件・%）と一致しません', p_expect_count, p_expect_total, v_cnt, v_total; end if;
  elsif p_expect_count is not null and p_expect_count <> v_cnt or p_expect_total is not null and p_expect_total <> v_total then
    raise exception '確認した件数・合計が、実際の対象と一致しません';
  end if;
  select coalesce(u.name, u.id::text) into v_name from public.users u where u.id = auth.uid();
  insert into public.bank_decision_batches (mode, decision, reason, actor_id, actor_label, item_ids, item_count, total_amount, expected_count, expected_total)
    values (v_mode, p_decision, btrim(p_reason), auth.uid(), coalesce(v_name, 'user'), v_ids, v_cnt, v_total, p_expect_count, p_expect_total) returning id into v_batch;
  for v_it in select * from public.bank_diff_items where id = any (v_ids) order by id for update loop
    if p_decision = 'corrected' then
      foreach v_tx in array v_it.transaction_ids loop
        if not exists (select 1 from public.bank_transactions t where t.id = v_tx and (t.is_adjusted or exists (select 1 from public.bank_transaction_events e where e.transaction_id = v_tx and e.event_kind = 'correct'))) then
          raise exception '訂正の記録がありません（先に bank_tx_correct で訂正してください）';
        end if;
      end loop;
    end if;
    if p_decision = 'approved' and v_it.kind = 'paired_held' then      -- 保留の解除は、1 対 1 の対応が確かめられたときだけ
      foreach v_tx in array v_it.transaction_ids loop
        if not exists (
          select 1 from public.bank_transactions t
            join public.bank_legacy_links k on k.transaction_id = t.id and k.kind = 'paired' and k.confidence in ('auto', 'approved')
            join public.bank_legacy_rows r on r.content_hash || '#' || r.ordinal = k.legacy_key
           where t.id = v_tx and r.store_id = t.store_id and r.txn_date = t.txn_date and r.amount = t.deposit_amount
             and (select count(*) from public.bank_legacy_links k2 where k2.transaction_id = t.id) = 1
             and (select count(*) from public.bank_legacy_links k3 where k3.legacy_key = k.legacy_key) = 1)
        then raise exception '旧の行との 1 対 1 の対応（同じ店舗ID・日付・金額）が確かめられないため、保留を解けません';
        end if;
      end loop;
    end if;
    if p_decision = 'approved' and v_it.kind in ('bank_only', 'paired_held') then      -- 銀行側の保留（旧に無い／旧と対応済み）→ 照合済みへ
      perform set_config('app.bank_reason', btrim(p_reason), true); perform set_config('app.bank_actor', coalesce(v_name, 'user'), true);
      update public.bank_transactions set match_status = 'verified', hold_reason = null
       where id = any (v_it.transaction_ids) and match_status = 'held';
      perform set_config('app.bank_reason', '', true); perform set_config('app.bank_actor', '', true);
    elsif p_decision = 'approved' and v_it.kind = 'ambiguous_pair' then
      update public.bank_legacy_links set confidence = 'approved' where legacy_key = any (v_it.legacy_keys);
    elsif p_decision = 'rejected' then
      foreach v_tx in array v_it.transaction_ids loop
        perform public.bank_tx_correct(v_tx, '{"counts_as_sales_deposit": false}'::jsonb, p_reason);
      end loop;
      -- 旧のみ・調整の行（移行済み）も同様に集計から外す（数字が変わる決定）
      for v_tx in select k.transaction_id from public.bank_legacy_links k where k.legacy_key = any (v_it.legacy_keys) and k.transaction_id is not null and k.kind in ('migrated', 'adjustment') loop
        perform public.bank_tx_correct(v_tx, '{"counts_as_sales_deposit": false}'::jsonb, p_reason);
      end loop;
    end if;
    insert into public.bank_diff_decisions (batch_id, item_id, from_status, to_status) values (v_batch, v_it.id, v_it.status, p_decision);
    update public.bank_diff_items set status = p_decision, decided_at = now(), decided_by = auth.uid(), decided_reason = btrim(p_reason) where id = v_it.id;
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('decision_batch', v_batch, 'mode', v_mode, 'items', v_n, 'total', v_total);
end $$;

-- D-6b. 一括承認の前に見る「一覧と合計」（読むだけ。本部・社長・マスターだけ）。件数・合計（符号つき）・内訳・個別確認の対象の数（高額・マイナスの重複は 1 件）を返す。
--   この件数・合計を、そのまま bank_diff_decide の p_expect_count / p_expect_total に渡して一括承認する。
create or replace function public.bank_diff_preview(p_kind text, p_review_class text default null, p_status text default 'open')
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v jsonb;
begin
  if not (public.bank_ledger_admin() or coalesce(auth.role(), '') = 'service_role') then raise exception '権限がありません'; end if;
  select jsonb_build_object(
    'kind', p_kind, 'review_class', p_review_class, 'status', p_status,
    'count', count(*), 'total', coalesce(sum(coalesce(d.amount, 0)), 0),
    'positive_total', coalesce(sum(d.amount) filter (where d.amount > 0), 0), 'negative_total', coalesce(sum(d.amount) filter (where d.amount < 0), 0),
    'high', count(*) filter (where (d.detail ->> 'high')::boolean), 'negative', count(*) filter (where (d.detail ->> 'negative')::boolean), 'zero', count(*) filter (where (d.detail ->> 'zero')::boolean),
    'high_and_negative', count(*) filter (where (d.detail ->> 'high')::boolean and (d.detail ->> 'negative')::boolean),
    'individual_distinct', count(*) filter (where d.detail ->> 'review_class' = 'individual'),
    'ids', coalesce(jsonb_agg(d.id order by s.name, d.txn_date, d.id), '[]'::jsonb),
    'items', coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'store', s.name, 'date', d.txn_date, 'desc', d.description, 'amount', d.amount, 'review_class', d.detail ->> 'review_class') order by s.name, d.txn_date, d.id), '[]'::jsonb))
    into v
    from public.bank_diff_items d left join public.stores s on s.id = d.store_id
   where d.kind = p_kind and d.status = p_status and (p_review_class is null or d.detail ->> 'review_class' = p_review_class);
  return v;
end $$;

-- D-7. 既存の銀行CSV由来の明細の指紋（移行の前後で変わらないことの確認用。読むだけ）
create or replace function public.bank_csv_rows_fingerprint()
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object('rows', count(*), 'md5', coalesce(md5(string_agg(concat_ws('|', t.id, t.bank_account_id, t.store_id, t.corporation_id, t.txn_date, t.txn_time, t.description, t.deposit_amount,
         t.withdrawal_amount, t.balance, t.dedupe_key, t.match_status, t.hold_reason, t.tx_kind, t.counts_as_sales_deposit, t.import_file_id, t.confirm_status, t.adj_deposit_amount, t.adj_description, t.adj_txn_date), ',' order by t.id)), ''))
    from public.bank_transactions t where t.source_kind in ('playwright', 'manual_csv')
$$;

-- D-8. 検証レポート（読むだけ）: 保存則・店舗×日付の件数と金額の比較・備考の比較・差異の内訳・既存の銀行CSV由来の行の指紋
create or replace function public.bank_legacy_report(p_batch uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v jsonb; v_rows int; v_notes int;
begin
  if not (public.bank_ledger_admin() or coalesce(auth.role(), '') = 'service_role') then raise exception '権限がありません'; end if;
  select row_count, notes_count into v_rows, v_notes from public.bank_legacy_batches where id = p_batch;
  with L as (select store_id, txn_date, count(*) c, sum(amount) a from public.bank_legacy_rows where batch_id = p_batch and store_id is not null group by 1, 2),
       D as (select store_id, deposit_date txn_date, deposit_count c, amount a, held_count hc from public.bank_deposit_daily()),
       C as (select coalesce(L.store_id, D.store_id) store_id, coalesce(L.txn_date, D.txn_date) txn_date,
                    coalesce(L.c, 0) lc, coalesce(L.a, 0) la, coalesce(D.c, 0) dc, coalesce(D.a, 0) da, coalesce(D.hc, 0) hc
               from L full join D on L.store_id = D.store_id and L.txn_date = D.txn_date)
  select jsonb_build_object(
    'legacy_rows', v_rows,
    'legacy_rows_saved', (select count(*) from public.bank_legacy_rows where batch_id = p_batch),
    'links_by_kind', coalesce((select jsonb_object_agg(kind, c) from (select k.kind, count(*) c from public.bank_legacy_rows r join public.bank_legacy_links k on k.legacy_key = r.content_hash || '#' || r.ordinal where r.batch_id = p_batch group by 1) q), '{}'::jsonb),
    'rows_without_link', (select count(*) from public.bank_legacy_rows r where r.batch_id = p_batch and not exists (select 1 from public.bank_legacy_links k where k.legacy_key = r.content_hash || '#' || r.ordinal)),
    'rows_unmigrated', (select count(*) from public.bank_legacy_rows r join public.bank_legacy_links k on k.legacy_key = r.content_hash || '#' || r.ordinal where r.batch_id = p_batch and k.kind in ('migrated', 'adjustment') and k.transaction_id is null),
    'store_dates_compared', (select count(*) from C),
    'store_dates_mismatch', (select count(*) from C where lc <> dc or la <> da),
    'mismatch_sample', coalesce((select jsonb_agg(jsonb_build_object('store_id', store_id, 'date', txn_date, 'legacy_count', lc, 'ledger_count', dc, 'legacy_amount', la, 'ledger_amount', da, 'held_in_ledger', hc) order by txn_date) from (select * from C where lc <> dc or la <> da order by txn_date limit 50) m), '[]'::jsonb),
    'legacy_total', (select coalesce(sum(la), 0) from C), 'ledger_total', (select coalesce(sum(da), 0) from C),
    'notes_legacy', v_notes,
    'notes_saved', (select count(*) from public.bank_legacy_notes where batch_id = p_batch),
    'notes_in_ledger_same', (select count(*) from public.bank_legacy_notes n join public.bank_deposit_notes d on d.store_id = n.store_id and d.note_date = n.note_date and d.note = n.note where n.batch_id = p_batch),
    'adjustments', (select jsonb_build_object(
        'rows', count(*),
        'numbers_preserved_rows', count(*) filter (where k.transaction_id is not null),          -- 移行で数字が維持された行（承認とは別）
        'legitimacy_pending', count(*) filter (where d.status in ('open', 'held')), 'legitimacy_approved', count(*) filter (where d.status = 'approved'), 'rejected', count(*) filter (where d.status = 'rejected'),
        'individual_distinct', count(*) filter (where d.detail ->> 'review_class' = 'individual'), 'high', count(*) filter (where (d.detail ->> 'high')::boolean),
        'negative', count(*) filter (where (d.detail ->> 'negative')::boolean), 'zero', count(*) filter (where (d.detail ->> 'zero')::boolean), 'high_and_negative', count(*) filter (where (d.detail ->> 'high')::boolean and (d.detail ->> 'negative')::boolean),
        'individual_pending', count(*) filter (where d.detail ->> 'review_class' = 'individual' and d.status in ('open', 'held')),
        'bulk_pending', count(*) filter (where d.detail ->> 'review_class' = 'bulk' and d.status in ('open', 'held')),
        'bulk_pending_total', coalesce(sum(d.amount) filter (where d.detail ->> 'review_class' = 'bulk' and d.status in ('open', 'held')), 0),
        'signed_total', coalesce(sum(d.amount), 0),
        'negative_rows_not_bank_withdrawals', (select count(*) from public.bank_transactions t where t.tx_kind = 'adjustment' and t.withdrawal_amount > 0 and t.bank_account_id is null))
       from public.bank_diff_items d left join public.bank_legacy_links k on k.legacy_key = d.legacy_keys[1] where d.batch_id = p_batch and d.kind = 'manual_adjustment'),
    'diff_items_by_kind_status', coalesce((select jsonb_object_agg(kind || '/' || status, c) from (select kind, status, count(*) c from public.bank_diff_items where batch_id = p_batch group by 1, 2) q), '{}'::jsonb),
    'csv_rows_fingerprint', public.bank_csv_rows_fingerprint()
  ) into v;
  return v;
end $$;

-- 実行権限
revoke all on function public.bank_legacy_load(jsonb, jsonb, jsonb) from public, anon, authenticated;
revoke all on function public.bank_legacy_plan(uuid) from public, anon, authenticated;
revoke all on function public.bank_legacy_changes(uuid, uuid) from public, anon, authenticated;
revoke all on function public.bank_legacy_migrate(uuid) from public, anon, authenticated;
revoke all on function public.bank_legacy_migrate_notes(uuid) from public, anon, authenticated;
revoke all on function public.bank_csv_rows_fingerprint() from public, anon, authenticated;
revoke all on function public.bank_legacy_report(uuid) from public, anon, authenticated;
revoke all on function public.bank_diff_decide(uuid[], text, text, text, integer, numeric) from public, anon;
revoke all on function public.bank_diff_preview(text, text, text) from public, anon;
grant execute on function public.bank_legacy_load(jsonb, jsonb, jsonb) to service_role;
grant execute on function public.bank_legacy_plan(uuid) to service_role;
grant execute on function public.bank_legacy_changes(uuid, uuid) to service_role;
grant execute on function public.bank_legacy_migrate(uuid) to service_role;
grant execute on function public.bank_legacy_migrate_notes(uuid) to service_role;
grant execute on function public.bank_csv_rows_fingerprint() to service_role;
grant execute on function public.bank_legacy_report(uuid) to service_role, authenticated;
grant execute on function public.bank_diff_decide(uuid[], text, text, text, integer, numeric) to authenticated, service_role;
grant execute on function public.bank_diff_preview(text, text, text) to authenticated, service_role;
