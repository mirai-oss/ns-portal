-- =============================================================
-- 給与振込の自動照合（下書き・2026-11-13 作成。★本番未適用。適用は別の承認のあと）
--   第 1 段階: マネーフォワードの仕訳（摘要「WEB総振」・貸方が預金）と、振込バッチの合計を比べる → 「マネーフォワード総額照合済み」
--              ここでは、従業員ごとの行は 1 つも完了にしない。
--   第 2 段階: PayPay 銀行の総合振込（1 件＋明細 N 件）を取り込み、振込バッチの予定者と 1 対 1 で結ぶ → 「PayPay 銀行明細照合済み」
--              銀行の結果が全件成功で、1 対 1 に合ったときだけ「振込完了」。
--              自動で「振込完了」にするのは、スイッチ app_settings.payroll_transfer_recon の auto_complete が true のときだけ（既定 false）。
--   振込バッチは、同じ月 × 法人に複数持てる（batch_kind: regular＝通常／additional＝追加／retry＝再振込／adjustment＝差額。batch_seq＝月 × 法人の中の連番）。
--     通常のバッチは月 × 法人に 1 つまで（取り下げたものは行ごと消えるので数えない）。追加・再振込・差額は、いくつでも。
--     通常のバッチだけ、給与データから対象者と金額を自動で決める。追加・再振込・差額は、対象者と金額を呼ぶ側が渡す。
--     1 対 1 の照合・「同じ銀行取引は 1 つのバッチだけ」・MF の出金の一意は、バッチ単位。
--   この SQL が足すもの: 新しい表 8 つ・新しい関数・スイッチの行 1 つ（app_settings に key を 1 つ足すだけ）。
--   この SQL が変えないもの: 既存の表の定義・既存の関数・既存の行（給与データ・口座・月ごとの支払方法・支払記録 paid_at には触れない）。
--   使う既存のもの（読むだけ）: sf_payroll_sync.net_pay／smaregi_contracts／payroll_month_payments（method・status・account）／payroll_month_method()／
--                               sf_payroll_hidden／pay_transfer_pending_holds()／payroll_transfer_schedule.scheduled_date／payroll_pay_can()／corporations／users
--   権限: 表は RLS を有効にし、画面（ログインしている人）からは直接読めない・書けない。読むのも書くのも、下の関数だけ。
--         画面用の関数（payroll_transfer_recon_status）と Slack 用の関数（payroll_transfer_recon_slack_summary）は、口座番号・名義カナを返さない。
--         Slack 用の関数は、金額も氏名も返さない。
--   証憑: 表と関数だけ。Storage のバケットは、この SQL では作らない（別に相談）。
--   戻し方: 2026-11-24_payroll_transfer_recon_rollback.sql
-- =============================================================

-- ===== 0. スイッチ（全部 OFF で始める） =====
--   mf_total_enabled: 第 1 段階を定期で動かす／bank_read_enabled: PayPay 銀行の読み取りを動かす／auto_complete: 自動で「振込完了」にする／slack_enabled: Slack に状況を出す
--   corps: 法人ごとの設定 { "<corporation_id>": { "source_account_keys": ["…"], "mf_deposit_accounts": ["普通預金/…"] } }
--          source_account_keys＝その法人の給与の出金口座を見分ける印（口座番号そのものは入れない）。未登録のあいだは、銀行の取引を自動では結ばない。
insert into public.app_settings(key, value)
values ('payroll_transfer_recon',
        jsonb_build_object('mf_total_enabled', false, 'bank_read_enabled', false, 'auto_complete', false,
                           'slack_enabled', false, 'slack_channel_key', null, 'recheck_business_days', 10, 'corps', '{}'::jsonb))
on conflict (key) do nothing;

-- ===== 1. 表 =====

-- 1-1. 給与の振込バッチ（給与の対象月 × 法人 × 連番。種類: regular＝通常／additional＝追加／retry＝再振込／adjustment＝差額）
create table if not exists public.payroll_transfer_batches (
  id               uuid primary key default gen_random_uuid(),
  year_month       text not null check (year_month ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'),   -- 給与の対象月（支払月ではない）
  corporation_id   uuid not null,
  batch_seq        integer not null default 1 check (batch_seq >= 1),                 -- 月 × 法人の中の連番
  batch_kind       text not null default 'regular'
                   check (batch_kind in ('regular', 'additional', 'retry', 'adjustment')),
  kind_reason      text,                                                               -- 追加・再振込・差額の理由（通常以外は必須）
  scheduled_date   date not null,                                                      -- 振込指定日
  expected_count   integer not null check (expected_count > 0),
  expected_total   numeric not null check (expected_total > 0),
  lines_hash       text not null,                                                      -- 固めた予定者の行の指紋（SHA-256）
  status           text not null default 'planned'
                   check (status in ('planned', 'mf_total_matched', 'bank_matched', 'completed', 'pending_check', 'failed')),
  status_reason    text,
  mf_matched_at    timestamptz,                                                        -- 第 1 段階が合った日時（状態が変わっても残す）
  bank_matched_at  timestamptz,                                                        -- 銀行の自動照合で全員 1 対 1・全件成功になった日時（手動確認では入らない）
  completed_at     timestamptz,
  completed_kind   text check (completed_kind in ('auto', 'human', 'manual')),         -- auto=スイッチによる自動／human=照合済みを人が完了に／manual=手動確認を含む
  completed_by     uuid,
  failed_at        timestamptz,
  frozen_by        uuid,
  frozen_at        timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (year_month, corporation_id, batch_seq),
  check (batch_kind = 'regular' or (kind_reason is not null and btrim(kind_reason) <> ''))
);
create unique index if not exists payroll_transfer_batches_regular_key on public.payroll_transfer_batches(year_month, corporation_id) where batch_kind = 'regular';   -- 通常のバッチは、月 × 法人に 1 つまで
comment on table public.payroll_transfer_batches is '給与の振込バッチ（対象月×法人×連番。通常・追加・再振込・差額）。固めたあと、対象月・法人・種類・人数・合計・指紋は変えられない';

-- 1-2. 銀行の総合振込 1 件（取り込み）。結び先のバッチは batch_id の 1 列だけ＝同じ銀行取引を 2 つのバッチに結べない
create table if not exists public.bank_bulk_transfers (
  id                  uuid primary key default gen_random_uuid(),
  bank                text not null default 'paypay',
  source_account_key  text not null,                                                   -- 出金口座を見分ける印（口座番号そのものではない）
  bank_ref            text not null,                                                   -- 銀行の受付番号など
  designated_date     date not null,
  total_count         integer not null check (total_count > 0),
  total_amount        numeric not null check (total_amount > 0),
  fee_total           numeric,
  bank_status_raw     text,                                                            -- 画面の言葉そのまま
  bank_status         text not null default 'unknown'
                      check (bank_status in ('accepted', 'processing', 'done', 'partial', 'failed', 'unknown')),
  login_profile       text,
  batch_id            uuid references public.payroll_transfer_batches(id),
  linked_at           timestamptz,
  first_seen_at       timestamptz not null default now(),
  last_seen_at        timestamptz not null default now(),
  unique (bank, source_account_key, bank_ref)
);
create unique index if not exists bank_bulk_transfers_batch_key on public.bank_bulk_transfers(batch_id) where batch_id is not null;   -- 1 つのバッチに結べる銀行取引も 1 件だけ
create index if not exists bank_bulk_transfers_date_idx on public.bank_bulk_transfers(designated_date);
comment on table public.bank_bulk_transfers is '銀行の総合振込 1 件（読み取った内容）。同じ受付番号の再投入では行は増えない';

-- 1-3. 銀行の明細（1 件ずつ）★口座番号・名義が入る
create table if not exists public.bank_bulk_transfer_details (
  id              uuid primary key default gen_random_uuid(),
  transfer_id     uuid not null references public.bank_bulk_transfers(id),
  line_no         integer not null,
  bank_code       text,
  branch_code     text,
  account_type    text,
  account_number  text,
  holder_kana     text,
  acct_key        text,                                                                -- そろえた「金融機関-支店-種別-口座番号」。読めない（伏せ字など）ときは null＝自動では結ばない
  kana_norm       text not null default '',
  amount          numeric not null check (amount > 0),
  result_raw      text,
  result          text not null default 'unknown'
                  check (result in ('success', 'failed', 'returned', 'accepted', 'processing', 'unknown')),
  first_seen_at   timestamptz not null default now(),
  last_seen_at    timestamptz not null default now(),
  unique (transfer_id, line_no)
);
create index if not exists bank_bulk_transfer_details_match_idx on public.bank_bulk_transfer_details(transfer_id, acct_key);

-- 1-4. バッチの予定者の行 ★その時点の金額と振込先の控え（あとで給与データや口座が変わっても変わらない）
create table if not exists public.payroll_transfer_batch_lines (
  id                      uuid primary key default gen_random_uuid(),
  batch_id                uuid not null references public.payroll_transfer_batches(id),
  year_month              text not null,
  corporation_id          uuid not null,
  user_id                 uuid not null,
  amount                  numeric not null check (amount > 0),
  account                 jsonb not null,                                              -- 固めた時点の振込先の控え（payroll_month_payments.account の写し）
  acct_key                text not null,
  kana_norm               text not null,
  line_status             text not null default 'planned'
                          check (line_status in ('planned', 'bank_matched', 'completed', 'pending_check', 'failed', 'returned', 'manual_confirmed')),
  status_reason           text,
  bank_detail_id          uuid references public.bank_bulk_transfer_details(id),
  manual_confirmation_id  bigint,
  completed_at            timestamptz,
  retry_of_line_id        uuid references public.payroll_transfer_batch_lines(id),     -- 再振込のとき、元の行（失敗・組戻しになった行）。元の行は消さない・変えない
  account_source          text not null default 'month' check (account_source in ('month', 'current')),   -- 振込先の出どころ: month＝給料確定のときの控え／current＝固めた時点の登録口座
  line_note               text,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  unique (batch_id, user_id)                                                           -- 同じバッチの中に、同じ人は 1 行（別のバッチ＝再振込・差額には入れる）
);
create unique index if not exists payroll_transfer_batch_lines_retry_key on public.payroll_transfer_batch_lines(retry_of_line_id) where retry_of_line_id is not null;   -- 1 つの元の行に、再振込の行は 1 つだけ
create index if not exists payroll_transfer_batch_lines_user_idx on public.payroll_transfer_batch_lines(year_month, corporation_id, user_id);
create unique index if not exists payroll_transfer_batch_lines_detail_key on public.payroll_transfer_batch_lines(bank_detail_id) where bank_detail_id is not null;   -- 明細 1 件は 1 人にだけ
create index if not exists payroll_transfer_batch_lines_batch_idx on public.payroll_transfer_batch_lines(batch_id, acct_key);

-- 1-5. 第 1 段階（マネーフォワード総額）の結果
create table if not exists public.payroll_mf_total_matches (
  id                uuid primary key default gen_random_uuid(),
  batch_id          uuid not null references public.payroll_transfer_batches(id),
  tenant_id         text not null,
  mf_journal_id     text not null,
  branch_no         integer not null default 0,
  transaction_date  date not null,
  deposit_account   text,                                                              -- 預金の「科目名/補助科目名」
  amount            numeric not null,
  remark            text,
  result            text not null check (result in ('matched', 'remark_mismatch', 'date_mismatch', 'deposit_account_not_configured', 'deposit_account_mismatch', 'amount_mismatch')),
  checked_at        timestamptz not null default now(),
  checked_by        uuid,
  unique (batch_id, tenant_id, mf_journal_id, branch_no)
);
create unique index if not exists payroll_mf_total_matches_used_key on public.payroll_mf_total_matches(tenant_id, mf_journal_id, branch_no) where result = 'matched';   -- 同じ MF の出金を、別のバッチの「一致」に使えない

-- 1-6. 手動確認（人が確認した、という記録。銀行の自動照合とは別に残す。追記だけ）
create table if not exists public.payroll_transfer_manual_confirmations (
  id            bigserial primary key,
  batch_id      uuid not null,
  line_id       uuid not null,
  user_id       uuid not null,                                                         -- 確認された従業員
  action        text not null check (action in ('confirm', 'revoke')),
  ref_id        bigint,                                                                -- revoke のとき、取り消す confirm の id
  basis         text,                                                                  -- 何を見て確かめたか
  reason        text not null check (btrim(reason) <> ''),
  evidence_id   uuid,
  confirmed_by  uuid not null,                                                         -- 確認者（必須）
  confirmed_at  timestamptz not null default now(),
  check (action <> 'confirm' or (basis is not null and btrim(basis) <> ''))
);
create index if not exists payroll_transfer_manual_confirmations_batch_idx on public.payroll_transfer_manual_confirmations(batch_id);

-- 1-7. 証憑（給与の対象月 × 法人 × 種類。原本の保存先・SHA-256・取得日時・取得元。取れなかったときは理由の行。追記だけ・上書きと削除は不可）
create table if not exists public.payroll_transfer_evidence (
  id                    uuid primary key default gen_random_uuid(),
  year_month            text not null check (year_month ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'),
  corporation_id        uuid not null,
  batch_id              uuid,
  bank_transfer_id      uuid,
  kind                  text not null check (kind in ('detail_pdf', 'result_pdf', 'detail_csv', 'result_csv', 'manual_upload', 'unavailable')),
  wanted_kind           text,                                                          -- unavailable のとき、取ろうとした種類
  storage_bucket        text,
  storage_path          text,
  sha256                text,
  size_bytes            bigint,
  mime                  text,
  fetched_at            timestamptz not null,                                          -- 取得日時
  source                text not null check (btrim(source) <> ''),                     -- 取得元（例: PayPay 銀行 BA-PLUS・WEB総振・結果）
  fetched_by            text not null check (btrim(fetched_by) <> ''),                 -- robot:paypayA など、または人の ID
  bank_status_at_fetch  text,
  unavailable_reason    text,
  created_at            timestamptz not null default now(),
  check ((kind = 'unavailable' and unavailable_reason is not null and btrim(unavailable_reason) <> '' and storage_path is null and sha256 is null)
      or (kind <> 'unavailable' and storage_bucket is not null and storage_path is not null and sha256 ~ '^[0-9a-f]{64}$' and unavailable_reason is null))
);
create unique index if not exists payroll_transfer_evidence_hash_key on public.payroll_transfer_evidence(year_month, corporation_id, kind, sha256) where kind <> 'unavailable';   -- 同じ中身を二重に保存しない
create unique index if not exists payroll_transfer_evidence_path_key on public.payroll_transfer_evidence(storage_bucket, storage_path) where storage_path is not null;          -- 同じ保存先を使い回さない（上書きしない）
create index if not exists payroll_transfer_evidence_ym_idx on public.payroll_transfer_evidence(year_month, corporation_id);

-- 1-8. 履歴（追記だけ）
create table if not exists public.payroll_transfer_recon_events (
  id           bigserial primary key,
  batch_id     uuid,
  line_id      uuid,
  event        text not null,
  from_status  text,
  to_status    text,
  actor_kind   text not null check (actor_kind in ('auto_mf', 'auto_bank', 'human', 'system')),
  actor_id     uuid,
  reason       text,
  detail       jsonb not null default '{}'::jsonb,                                     -- 口座番号・名義・金額は入れない
  created_at   timestamptz not null default now()
);
create index if not exists payroll_transfer_recon_events_batch_idx on public.payroll_transfer_recon_events(batch_id, id);

-- ===== 2. 権限（表は、画面から直接読めない・書けない） =====
alter table public.payroll_transfer_batches              enable row level security;
alter table public.payroll_transfer_batch_lines          enable row level security;
alter table public.bank_bulk_transfers                   enable row level security;
alter table public.bank_bulk_transfer_details            enable row level security;
alter table public.payroll_mf_total_matches              enable row level security;
alter table public.payroll_transfer_manual_confirmations enable row level security;
alter table public.payroll_transfer_evidence             enable row level security;
alter table public.payroll_transfer_recon_events         enable row level security;
revoke all on public.payroll_transfer_batches              from public, anon, authenticated;
revoke all on public.payroll_transfer_batch_lines          from public, anon, authenticated;
revoke all on public.bank_bulk_transfers                   from public, anon, authenticated;
revoke all on public.bank_bulk_transfer_details            from public, anon, authenticated;
revoke all on public.payroll_mf_total_matches              from public, anon, authenticated;
revoke all on public.payroll_transfer_manual_confirmations from public, anon, authenticated;
revoke all on public.payroll_transfer_evidence             from public, anon, authenticated;
revoke all on public.payroll_transfer_recon_events         from public, anon, authenticated;
revoke all on sequence public.payroll_transfer_manual_confirmations_id_seq from public, anon, authenticated;
revoke all on sequence public.payroll_transfer_recon_events_id_seq         from public, anon, authenticated;

-- ===== 3. 守りの引き金（下の関数の中からしか書けない。サービス用の鍵で直接書こうとしても止まる） =====
create or replace function public.payroll_recon_guard()
returns trigger language plpgsql as $$
begin
  if coalesce(current_setting('payroll.recon_ok', true), '') <> '1' then
    raise exception 'この表（%）は、振込照合の関数からしか変えられません', tg_table_name;
  end if;
  if tg_table_name = 'payroll_transfer_batches' and tg_op = 'UPDATE' then
    if new.id is distinct from old.id or new.year_month is distinct from old.year_month or new.corporation_id is distinct from old.corporation_id
       or new.batch_seq is distinct from old.batch_seq or new.batch_kind is distinct from old.batch_kind or new.kind_reason is distinct from old.kind_reason
       or new.expected_count is distinct from old.expected_count or new.expected_total is distinct from old.expected_total
       or new.lines_hash is distinct from old.lines_hash or new.frozen_at is distinct from old.frozen_at or new.frozen_by is distinct from old.frozen_by then
      raise exception '固めた振込バッチの内容（対象月・法人・種類・人数・合計）は変えられません';
    end if;
  end if;
  if tg_table_name = 'payroll_transfer_batch_lines' and tg_op = 'UPDATE' then
    if new.id is distinct from old.id or new.batch_id is distinct from old.batch_id or new.year_month is distinct from old.year_month
       or new.corporation_id is distinct from old.corporation_id or new.user_id is distinct from old.user_id or new.amount is distinct from old.amount
       or new.account is distinct from old.account or new.acct_key is distinct from old.acct_key or new.kana_norm is distinct from old.kana_norm
       or new.retry_of_line_id is distinct from old.retry_of_line_id or new.account_source is distinct from old.account_source then
      raise exception '固めた予定者の行（金額・振込先の控え・再振込の元の行）は変えられません';
    end if;
    if old.bank_detail_id is not null and new.bank_detail_id is distinct from old.bank_detail_id then
      raise exception '銀行の明細と結んだ行は、別の明細へ付け替えられません';
    end if;
  end if;
  if tg_table_name = 'bank_bulk_transfers' and tg_op = 'UPDATE' then
    if old.batch_id is not null and new.batch_id is distinct from old.batch_id then
      raise exception 'バッチと結んだ銀行取引は、別のバッチへ付け替えられません';
    end if;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
revoke all on function public.payroll_recon_guard() from public, anon, authenticated;

create or replace function public.payroll_recon_append_only()
returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    if coalesce(current_setting('payroll.recon_ok', true), '') <> '1' then
      raise exception 'この表（%）は、振込照合の関数からしか足せません', tg_table_name;
    end if;
    return new;
  end if;
  raise exception 'この表（%）の行は、書きかえ・削除できません（記録を残すため）', tg_table_name;
end $$;
revoke all on function public.payroll_recon_append_only() from public, anon, authenticated;

drop trigger if exists payroll_recon_guard on public.payroll_transfer_batches;
create trigger payroll_recon_guard before insert or update or delete on public.payroll_transfer_batches for each row execute function public.payroll_recon_guard();
drop trigger if exists payroll_recon_guard on public.payroll_transfer_batch_lines;
create trigger payroll_recon_guard before insert or update or delete on public.payroll_transfer_batch_lines for each row execute function public.payroll_recon_guard();
drop trigger if exists payroll_recon_guard on public.bank_bulk_transfers;
create trigger payroll_recon_guard before insert or update or delete on public.bank_bulk_transfers for each row execute function public.payroll_recon_guard();
drop trigger if exists payroll_recon_guard on public.bank_bulk_transfer_details;
create trigger payroll_recon_guard before insert or update or delete on public.bank_bulk_transfer_details for each row execute function public.payroll_recon_guard();
drop trigger if exists payroll_recon_guard on public.payroll_mf_total_matches;
create trigger payroll_recon_guard before insert or update or delete on public.payroll_mf_total_matches for each row execute function public.payroll_recon_guard();
drop trigger if exists payroll_recon_append_only on public.payroll_transfer_manual_confirmations;
create trigger payroll_recon_append_only before insert or update or delete on public.payroll_transfer_manual_confirmations for each row execute function public.payroll_recon_append_only();
drop trigger if exists payroll_recon_append_only on public.payroll_transfer_evidence;
create trigger payroll_recon_append_only before insert or update or delete on public.payroll_transfer_evidence for each row execute function public.payroll_recon_append_only();
drop trigger if exists payroll_recon_append_only on public.payroll_transfer_recon_events;
create trigger payroll_recon_append_only before insert or update or delete on public.payroll_transfer_recon_events for each row execute function public.payroll_recon_append_only();

-- ===== 4. 小さな部品 =====

-- サービス用の鍵（Edge Function・Mac mini の取り込み）からの呼び出しか
create or replace function public.payroll_recon_is_service()
returns boolean language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '') = 'service_role'
$$;
revoke all on function public.payroll_recon_is_service() from public, anon, authenticated;

-- 照合を動かせる人（本部・社長・マスター）か、サービス用の鍵
create or replace function public.payroll_recon_can()
returns boolean language sql stable security definer set search_path to 'public' as $$
  select public.payroll_pay_can() or public.payroll_recon_is_service()
$$;
revoke all on function public.payroll_recon_can() from public, anon, authenticated;

-- スイッチ（設定の行。無ければ空）
create or replace function public.payroll_recon_setting()
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select coalesce((select s.value from app_settings s where s.key = 'payroll_transfer_recon'), '{}'::jsonb)
$$;
revoke all on function public.payroll_recon_setting() from public, anon, authenticated;

create or replace function public.payroll_recon_flag(p_name text)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select coalesce((public.payroll_recon_setting() ->> p_name)::boolean, false)
$$;
revoke all on function public.payroll_recon_flag(text) from public, anon, authenticated;

-- 名義カナをそろえる（全角・半角、小さいカナ、伸ばし棒、中黒、空白の違いを無くす）。画面の CSV 出力（paypayCleanKana）と同じ考え方
create or replace function public.payroll_recon_kana_norm(p_text text)
returns text language sql immutable as $$
  select regexp_replace(
           regexp_replace(
             translate(regexp_replace(upper(normalize(coalesce(p_text, ''), NFKC)), '\s', '', 'g'), 'ァィゥェォッャュョヮ', 'アイウエオツヤユヨワ'),
             '[ー‐‑‒–—―−]', '-', 'g'),
           '・', '.', 'g')
$$;
revoke all on function public.payroll_recon_kana_norm(text) from public, anon, authenticated;

-- 口座をそろえた鍵「金融機関 4 桁-支店 3 桁-種別-口座番号 7 桁」。数字として読めないもの（伏せ字など）は null＝自動では結ばない
create or replace function public.payroll_recon_acct_key(p_bank text, p_branch text, p_type text, p_number text)
returns text language plpgsql immutable as $$
declare
  v_bank text := btrim(normalize(coalesce(p_bank, ''), NFKC));
  v_branch text := btrim(normalize(coalesce(p_branch, ''), NFKC));
  v_type text := btrim(normalize(coalesce(p_type, ''), NFKC));
  v_number text := btrim(normalize(coalesce(p_number, ''), NFKC));
begin
  if v_bank !~ '^[0-9]{1,4}$' or v_branch !~ '^[0-9]{1,3}$' or v_number !~ '^[0-9]{1,7}$' then return null; end if;
  v_type := case when v_type in ('1', '普通', '普通預金') then '1'
                 when v_type in ('2', '当座', '当座預金') then '2'
                 when v_type in ('4', '貯蓄', '貯蓄預金') then '4'
                 else null end;
  if v_type is null then return null; end if;
  return lpad(v_bank, 4, '0') || '-' || lpad(v_branch, 3, '0') || '-' || v_type || '-' || lpad(v_number, 7, '0');
end $$;
revoke all on function public.payroll_recon_acct_key(text, text, text, text) from public, anon, authenticated;

-- 状態の表示名（6 つ。手動確認を含む完了は分けて表示する）
create or replace function public.payroll_transfer_status_label(p_status text, p_completed_kind text default null)
returns text language sql immutable as $$
  select case p_status
           when 'planned' then '振込予定'
           when 'mf_total_matched' then 'マネーフォワード総額照合済み'
           when 'bank_matched' then 'PayPay 銀行明細照合済み'
           when 'completed' then case when p_completed_kind = 'manual' then '振込完了（手動確認）' else '振込完了' end
           when 'pending_check' then '確認待ち'
           when 'failed' then '振込失敗'
           else p_status end
$$;
revoke all on function public.payroll_transfer_status_label(text, text) from public, anon;
grant execute on function public.payroll_transfer_status_label(text, text) to authenticated, service_role;

-- バッチの種類の表示名
create or replace function public.payroll_transfer_kind_label(p_kind text)
returns text language sql immutable as $$
  select case p_kind when 'regular' then '通常' when 'additional' then '追加' when 'retry' then '再振込' when 'adjustment' then '差額' else p_kind end
$$;
revoke all on function public.payroll_transfer_kind_label(text) from public, anon;
grant execute on function public.payroll_transfer_kind_label(text) to authenticated, service_role;

-- バッチの予定者の行が、銀行取引の明細とぴったり合うか（人数が同じ・全員に、口座＋カナ＋金額の一致する明細がちょうど 1 件・同じ口座の人がいない）。
--   同じ日・同じ件数・同じ合計のバッチが複数あるとき、どのバッチの取引かを見分けるのに使う（内部用）
create or replace function public.payroll_recon_lines_match(p_batch_id uuid, p_transfer_id uuid)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select (select count(*) from payroll_transfer_batch_lines l where l.batch_id = p_batch_id)
       = (select count(*) from bank_bulk_transfer_details d where d.transfer_id = p_transfer_id)
     and exists (select 1 from payroll_transfer_batch_lines l where l.batch_id = p_batch_id)
     and not exists (select 1 from payroll_transfer_batch_lines l
                      where l.batch_id = p_batch_id
                        and (select count(*) from bank_bulk_transfer_details d
                              where d.transfer_id = p_transfer_id and d.acct_key = l.acct_key and d.kana_norm = l.kana_norm and d.amount = l.amount) <> 1)
     and not exists (select 1 from payroll_transfer_batch_lines l where l.batch_id = p_batch_id group by l.acct_key having count(*) > 1)
$$;
revoke all on function public.payroll_recon_lines_match(uuid, uuid) from public, anon, authenticated;

-- 履歴に 1 行足す（内部用）
create or replace function public.payroll_recon_log(p_batch_id uuid, p_line_id uuid, p_event text, p_from text, p_to text, p_actor_kind text, p_reason text, p_detail jsonb)
returns void language sql security definer set search_path to 'public' as $$
  insert into payroll_transfer_recon_events(batch_id, line_id, event, from_status, to_status, actor_kind, actor_id, reason, detail)
  values (p_batch_id, p_line_id, p_event, p_from, p_to, p_actor_kind, auth.uid(), p_reason, coalesce(p_detail, '{}'::jsonb))
$$;
revoke all on function public.payroll_recon_log(uuid, uuid, text, text, text, text, text, jsonb) from public, anon, authenticated;

-- バッチの状態を変える（内部用。変わったときだけ履歴に残す）
create or replace function public.payroll_recon_set_batch(p_batch_id uuid, p_status text, p_reason text, p_actor_kind text, p_detail jsonb default null)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_old text; v_old_reason text;
begin
  select b.status, b.status_reason into v_old, v_old_reason from payroll_transfer_batches b where b.id = p_batch_id;
  if v_old is not distinct from p_status and v_old_reason is not distinct from p_reason then return; end if;
  update payroll_transfer_batches b
     set status = p_status, status_reason = p_reason, updated_at = now(),
         failed_at = case when p_status = 'failed' and b.failed_at is null then now() else b.failed_at end
   where b.id = p_batch_id;
  perform public.payroll_recon_log(p_batch_id, null, 'batch_status', v_old, p_status, p_actor_kind, p_reason, p_detail);
end $$;
revoke all on function public.payroll_recon_set_batch(uuid, text, text, text, jsonb) from public, anon, authenticated;

-- 予定者の行の状態を変える（内部用。変わったときだけ履歴に残す）
create or replace function public.payroll_recon_set_line(p_line_id uuid, p_status text, p_reason text, p_actor_kind text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_old text; v_old_reason text; v_batch uuid;
begin
  select l.line_status, l.status_reason, l.batch_id into v_old, v_old_reason, v_batch from payroll_transfer_batch_lines l where l.id = p_line_id;
  if v_old is not distinct from p_status and v_old_reason is not distinct from p_reason then return; end if;
  update payroll_transfer_batch_lines l set line_status = p_status, status_reason = p_reason, updated_at = now() where l.id = p_line_id;
  perform public.payroll_recon_log(v_batch, p_line_id, 'line_status', v_old, p_status, p_actor_kind, p_reason, null);
end $$;
revoke all on function public.payroll_recon_set_line(uuid, text, text, text) from public, anon, authenticated;

-- バッチを「振込完了」にする（内部用）。p_kind: auto＝スイッチによる自動／human＝人が完了に／manual＝手動確認を含む
create or replace function public.payroll_recon_complete(p_batch_id uuid, p_kind text, p_actor_kind text, p_note text default null)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_old text; v_old_kind text;
begin
  select b.status, b.completed_kind into v_old, v_old_kind from payroll_transfer_batches b where b.id = p_batch_id;
  if v_old = 'completed' and v_old_kind is not distinct from p_kind then return; end if;
  update payroll_transfer_batch_lines l set line_status = 'completed', status_reason = null, completed_at = coalesce(l.completed_at, now()), updated_at = now()
   where l.batch_id = p_batch_id and l.bank_detail_id is not null and l.line_status = 'bank_matched';
  update payroll_transfer_batches b
     set status = 'completed', status_reason = null, completed_at = coalesce(b.completed_at, now()), completed_kind = p_kind,
         completed_by = auth.uid(), updated_at = now()
   where b.id = p_batch_id;
  perform public.payroll_recon_log(p_batch_id, null, 'batch_status', v_old, 'completed', p_actor_kind, p_note, jsonb_build_object('completed_kind', p_kind));
end $$;
revoke all on function public.payroll_recon_complete(uuid, text, text, text) from public, anon, authenticated;

-- ===== 5. 振込バッチを固める =====
--   5-1. 通常のバッチ（月 × 法人に 1 つ。対象者と金額は、給与データから自動で決める）
--   予定者＝その法人の契約の給与データ（差引支給額の合計が 1 円以上）のうち、その月の支払方法が振込で、対象外・保留でない人。
--          すでにその月 × 法人のどれかのバッチ（追加など）に入っている人は入れない（二重に振り込まないため）。
--   振込先＝給料確定のときの控え（payroll_month_payments の fixed・bank_transfer の account）。控えが無い人・口座が読めない人がいるときは、固めずに知らせる
--   （p_skip_unready = true で、その人を外して固める。外した人は、あとで「追加」のバッチに入れられる）。
--   同じ月 × 法人で 2 回呼んでも、通常のバッチの 2 つ目は作らない（最初のバッチを返す）。
create or replace function public.payroll_transfer_batch_freeze(p_year_month text, p_corp_id uuid, p_scheduled_date date default null, p_skip_unready boolean default false)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_date date; v_seq integer; v_batch uuid; v_existing uuid; v_cand jsonb; v_ready jsonb;
  v_count integer := 0; v_total numeric := 0; v_hash text; v_unready integer := 0;
begin
  if not public.payroll_pay_can() then raise exception '権限がありません'; end if;
  if p_year_month is null or p_year_month !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then raise exception '月（YYYY-MM）が不正です'; end if;
  if p_corp_id is null then raise exception '法人が指定されていません'; end if;
  perform pg_advisory_xact_lock(hashtext('payroll_transfer_batch:' || p_year_month || ':' || p_corp_id::text));   -- 同時に押されても 1 つだけ

  select b.id into v_existing from payroll_transfer_batches b
   where b.year_month = p_year_month and b.corporation_id = p_corp_id and b.batch_kind = 'regular';
  if v_existing is not null then
    return jsonb_build_object('ok', true, 'already', true, 'batch_id', v_existing);
  end if;

  v_date := coalesce(p_scheduled_date, (select t.scheduled_date from payroll_transfer_schedule t where t.year_month = p_year_month));
  if v_date is null then raise exception '振込指定日が決まっていません'; end if;

  -- 予定者の候補（まだどのバッチにも入っていない人）
  select coalesce(jsonb_agg(jsonb_build_object('user_id', c.user_id, 'amount', c.amt, 'account', c.account) order by c.user_id), '[]'::jsonb)
    into v_cand
    from (
      select sp.user_id, round(sum(sp.net_pay)) as amt,
             (select m.account from payroll_month_payments m
               where m.user_id = sp.user_id and m.year_month = p_year_month and m.status = 'fixed' and m.method = 'bank_transfer') as account
        from sf_payroll_sync sp
        join smaregi_contracts sc on sc.contract_id = sp.contract_id
       where sp.year_month = p_year_month and sc.corporation_id = p_corp_id
         and public.payroll_month_method(sp.user_id, p_year_month) = 'bank_transfer'
         and not exists (select 1 from sf_payroll_hidden h where h.user_id = sp.user_id and h.year_month = p_year_month)
         and not exists (select 1 from public.pay_transfer_pending_holds(p_year_month) ph where ph.user_id = sp.user_id)
         and not exists (select 1 from payroll_transfer_batch_lines l0
                          where l0.year_month = p_year_month and l0.corporation_id = p_corp_id and l0.user_id = sp.user_id)
       group by sp.user_id
      having round(sum(sp.net_pay)) > 0
    ) c;

  -- 振込先の控えが使える人だけを残す
  select coalesce(jsonb_agg(e.value order by e.value ->> 'user_id'), '[]'::jsonb) into v_ready
    from jsonb_array_elements(v_cand) e
   where jsonb_typeof(e.value -> 'account') = 'object'
     and public.payroll_recon_acct_key(e.value -> 'account' ->> 'bank_code', e.value -> 'account' ->> 'branch_code',
                                       e.value -> 'account' ->> 'account_type', e.value -> 'account' ->> 'account_number') is not null
     and public.payroll_recon_kana_norm(e.value -> 'account' ->> 'account_holder_kana') <> '';
  v_unready := jsonb_array_length(v_cand) - jsonb_array_length(v_ready);
  if v_unready > 0 and not coalesce(p_skip_unready, false) then
    return jsonb_build_object('ok', false, 'reason', 'unready', 'unready_count', v_unready,
                              'message', '振込先の控え（給料確定のときの口座）が無い人がいます。給料確定・口座を確かめてから、もう一度固めてください');
  end if;

  select count(*), coalesce(sum((e.value ->> 'amount')::numeric), 0),
         encode(sha256(convert_to(coalesce(string_agg(concat_ws('|', e.value ->> 'user_id', e.value ->> 'amount',
                  public.payroll_recon_acct_key(e.value -> 'account' ->> 'bank_code', e.value -> 'account' ->> 'branch_code',
                                                e.value -> 'account' ->> 'account_type', e.value -> 'account' ->> 'account_number'),
                  public.payroll_recon_kana_norm(e.value -> 'account' ->> 'account_holder_kana')), E'\n' order by e.value ->> 'user_id'), ''), 'UTF8')), 'hex')
    into v_count, v_total, v_hash
    from jsonb_array_elements(v_ready) e;
  if v_count = 0 then
    return jsonb_build_object('ok', false, 'reason', 'no_targets', 'unready_count', v_unready, 'message', '固める対象の人がいません');
  end if;

  select coalesce(max(b.batch_seq), 0) + 1 into v_seq from payroll_transfer_batches b where b.year_month = p_year_month and b.corporation_id = p_corp_id;

  perform set_config('payroll.recon_ok', '1', true);
  insert into payroll_transfer_batches(year_month, corporation_id, batch_seq, batch_kind, scheduled_date, expected_count, expected_total, lines_hash, frozen_by)
  values (p_year_month, p_corp_id, v_seq, 'regular', v_date, v_count, v_total, v_hash, auth.uid())
  returning id into v_batch;
  insert into payroll_transfer_batch_lines(batch_id, year_month, corporation_id, user_id, amount, account, acct_key, kana_norm, account_source)
  select v_batch, p_year_month, p_corp_id, (e.value ->> 'user_id')::uuid, (e.value ->> 'amount')::numeric, e.value -> 'account',
         public.payroll_recon_acct_key(e.value -> 'account' ->> 'bank_code', e.value -> 'account' ->> 'branch_code',
                                       e.value -> 'account' ->> 'account_type', e.value -> 'account' ->> 'account_number'),
         public.payroll_recon_kana_norm(e.value -> 'account' ->> 'account_holder_kana'), 'month'
    from jsonb_array_elements(v_ready) e;
  perform public.payroll_recon_log(v_batch, null, 'frozen', null, 'planned', 'human', null,
                                   jsonb_build_object('batch_seq', v_seq, 'batch_kind', 'regular', 'count', v_count, 'scheduled_date', v_date, 'skipped_unready', v_unready));
  perform public.payroll_recon_eval(v_batch, 'auto_bank');   -- 銀行のデータが先に取り込まれていた場合に備えて、すぐ照合する（無ければ何も変わらない）
  perform set_config('payroll.recon_ok', '', true);

  return jsonb_build_object('ok', true, 'already', false, 'batch_id', v_batch, 'batch_seq', v_seq, 'batch_kind', 'regular', 'count', v_count, 'skipped_unready', v_unready);
end $$;
revoke all on function public.payroll_transfer_batch_freeze(text, uuid, date, boolean) from public, anon;
grant execute on function public.payroll_transfer_batch_freeze(text, uuid, date, boolean) to authenticated;

--   5-2. 追加・再振込・差額のバッチ（対象者と金額を、呼ぶ側が渡して固める。月 × 法人に、いくつでも作れる）
--   p_kind : additional＝追加（その月 × 法人のどのバッチにも、まだ入っていない人だけ）
--            retry＝再振込（前のバッチで失敗・組戻しになった行にだけ。元の行の id を持つ。1 つの元の行に 1 つだけ）
--            adjustment＝差額（すでに別のバッチに入っている人でもよい）
--   p_lines: [ { "user_id": "…", "amount": 12345, "retry_of_line_id": "…"（再振込のときだけ必須）, "note": "…"（任意） }, … ]
--            同じバッチの中に、同じ人は 1 行。金額は 1 円以上の整数。
--   p_account_source: month＝給料確定のときの控え（追加・差額の既定）／current＝いまの登録口座（再振込の既定。口座を直してから再振込する場合のため）
--   振込先が用意できない人が 1 人でもいれば、固めずに知らせる。理由（p_reason）は必須。固めたあと、金額・口座は変えられない（通常のバッチと同じ）。
--   元の行（失敗・組戻し）とその履歴は、消さない・変えない（「再振込を作った」という履歴を足すだけ）。
create or replace function public.payroll_transfer_batch_freeze_custom(p_year_month text, p_corp_id uuid, p_kind text, p_scheduled_date date, p_lines jsonb, p_reason text,
                                                                       p_account_source text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_uid uuid := auth.uid(); v_src text; v_seq integer; v_batch uuid; v_cand jsonb; v_ready jsonb;
  v_n integer := 0; v_distinct integer := 0; v_bad integer := 0; v_count integer := 0; v_total numeric := 0; v_hash text; v_unready integer := 0; v_rl record;
begin
  if v_uid is null or not public.payroll_pay_can() then raise exception '権限がありません'; end if;
  if p_year_month is null or p_year_month !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then raise exception '月（YYYY-MM）が不正です'; end if;
  if p_corp_id is null then raise exception '法人が指定されていません'; end if;
  if p_kind is null or p_kind not in ('additional', 'retry', 'adjustment') then
    raise exception '種類が不正です（additional＝追加／retry＝再振込／adjustment＝差額。通常のバッチは payroll_transfer_batch_freeze で作ります）';
  end if;
  if p_scheduled_date is null then raise exception '振込指定日が必要です'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception '理由を入力してください'; end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception '対象者と金額がありません'; end if;
  v_src := coalesce(nullif(btrim(p_account_source), ''), case when p_kind = 'retry' then 'current' else 'month' end);
  if v_src not in ('month', 'current') then raise exception '振込先の出どころが不正です（month＝給料確定のときの控え／current＝いまの登録口座）'; end if;
  perform pg_advisory_xact_lock(hashtext('payroll_transfer_batch:' || p_year_month || ':' || p_corp_id::text));

  -- 形の確かめ: 人の ID があること・同じ人が 2 回いないこと・金額が 1 円以上の整数であること
  select count(*), count(distinct e.value ->> 'user_id'),
         count(*) filter (where (e.value ->> 'user_id') is null
                             or not (case when (e.value ->> 'amount') ~ '^[0-9]+$' then (e.value ->> 'amount')::numeric > 0 else false end))
    into v_n, v_distinct, v_bad
    from jsonb_array_elements(p_lines) e;
  if v_bad > 0 then raise exception '対象者の ID が無い行、または金額が 1 円以上の整数でない行があります'; end if;
  if v_distinct <> v_n then raise exception '同じ人が 2 回入っています（同じバッチの中に、同じ人は 1 行です）'; end if;

  if p_kind in ('additional', 'adjustment') then
    if exists (select 1 from jsonb_array_elements(p_lines) e
                where not exists (select 1 from sf_payroll_sync sp join smaregi_contracts sc on sc.contract_id = sp.contract_id
                                   where sp.user_id = (e.value ->> 'user_id')::uuid and sp.year_month = p_year_month and sc.corporation_id = p_corp_id)) then
      raise exception 'その月・その法人の給与データが無い人が入っています';
    end if;
  end if;
  if p_kind = 'additional' then
    if exists (select 1 from jsonb_array_elements(p_lines) e
                where exists (select 1 from payroll_transfer_batch_lines l0
                               where l0.year_month = p_year_month and l0.corporation_id = p_corp_id and l0.user_id = (e.value ->> 'user_id')::uuid)) then
      raise exception 'すでにこの月の振込バッチに入っている人がいます（追加ではなく、差額・再振込を使ってください）';
    end if;
  end if;
  if p_kind = 'retry' then
    if exists (select 1 from jsonb_array_elements(p_lines) e
                where (e.value ->> 'retry_of_line_id') is null
                   or not exists (select 1 from payroll_transfer_batch_lines o
                                   where o.id = (e.value ->> 'retry_of_line_id')::uuid and o.user_id = (e.value ->> 'user_id')::uuid
                                     and o.year_month = p_year_month and o.corporation_id = p_corp_id and o.line_status in ('failed', 'returned'))) then
      raise exception '再振込は、同じ月・同じ法人・同じ人の「失敗・組戻しになった行」にだけ作れます（元の行の id が必要です）';
    end if;
    if exists (select 1 from jsonb_array_elements(p_lines) e
                where exists (select 1 from payroll_transfer_batch_lines r where r.retry_of_line_id = (e.value ->> 'retry_of_line_id')::uuid)) then
      raise exception 'その行には、すでに再振込のバッチがあります（1 つの元の行に、再振込は 1 つだけ。再振込も失敗したときは、その再振込の行を元にします）';
    end if;
  end if;

  -- 振込先の控え（呼ぶ側からは口座を渡さない。DB にある控え・登録口座だけを使う）
  select coalesce(jsonb_agg(jsonb_build_object(
           'user_id', e.value ->> 'user_id', 'amount', (e.value ->> 'amount')::numeric,
           'retry_of_line_id', case when p_kind = 'retry' then e.value ->> 'retry_of_line_id' end, 'note', e.value ->> 'note',
           'account', case when v_src = 'month'
                           then (select m.account from payroll_month_payments m
                                  where m.user_id = (e.value ->> 'user_id')::uuid and m.year_month = p_year_month and m.status = 'fixed' and m.method = 'bank_transfer')
                           else public.payroll_account_snapshot((e.value ->> 'user_id')::uuid) end)
           order by e.value ->> 'user_id'), '[]'::jsonb)
    into v_cand
    from jsonb_array_elements(p_lines) e;
  select coalesce(jsonb_agg(e.value order by e.value ->> 'user_id'), '[]'::jsonb) into v_ready
    from jsonb_array_elements(v_cand) e
   where jsonb_typeof(e.value -> 'account') = 'object'
     and public.payroll_recon_acct_key(e.value -> 'account' ->> 'bank_code', e.value -> 'account' ->> 'branch_code',
                                       e.value -> 'account' ->> 'account_type', e.value -> 'account' ->> 'account_number') is not null
     and public.payroll_recon_kana_norm(e.value -> 'account' ->> 'account_holder_kana') <> '';
  v_unready := jsonb_array_length(v_cand) - jsonb_array_length(v_ready);
  if v_unready > 0 then
    return jsonb_build_object('ok', false, 'reason', 'unready', 'unready_count', v_unready, 'account_source', v_src,
                              'message', '振込先が用意できない人がいます（給料確定のときの控え、または登録口座を確かめてください）');
  end if;

  select count(*), coalesce(sum((e.value ->> 'amount')::numeric), 0),
         encode(sha256(convert_to(coalesce(string_agg(concat_ws('|', e.value ->> 'user_id', e.value ->> 'amount',
                  public.payroll_recon_acct_key(e.value -> 'account' ->> 'bank_code', e.value -> 'account' ->> 'branch_code',
                                                e.value -> 'account' ->> 'account_type', e.value -> 'account' ->> 'account_number'),
                  public.payroll_recon_kana_norm(e.value -> 'account' ->> 'account_holder_kana'),
                  coalesce(e.value ->> 'retry_of_line_id', '')), E'\n' order by e.value ->> 'user_id'), ''), 'UTF8')), 'hex')
    into v_count, v_total, v_hash
    from jsonb_array_elements(v_ready) e;

  select coalesce(max(b.batch_seq), 0) + 1 into v_seq from payroll_transfer_batches b where b.year_month = p_year_month and b.corporation_id = p_corp_id;

  perform set_config('payroll.recon_ok', '1', true);
  insert into payroll_transfer_batches(year_month, corporation_id, batch_seq, batch_kind, kind_reason, scheduled_date, expected_count, expected_total, lines_hash, frozen_by)
  values (p_year_month, p_corp_id, v_seq, p_kind, btrim(p_reason), p_scheduled_date, v_count, v_total, v_hash, v_uid)
  returning id into v_batch;
  insert into payroll_transfer_batch_lines(batch_id, year_month, corporation_id, user_id, amount, account, acct_key, kana_norm, retry_of_line_id, account_source, line_note)
  select v_batch, p_year_month, p_corp_id, (e.value ->> 'user_id')::uuid, (e.value ->> 'amount')::numeric, e.value -> 'account',
         public.payroll_recon_acct_key(e.value -> 'account' ->> 'bank_code', e.value -> 'account' ->> 'branch_code',
                                       e.value -> 'account' ->> 'account_type', e.value -> 'account' ->> 'account_number'),
         public.payroll_recon_kana_norm(e.value -> 'account' ->> 'account_holder_kana'),
         (e.value ->> 'retry_of_line_id')::uuid, v_src, nullif(btrim(e.value ->> 'note'), '')
    from jsonb_array_elements(v_ready) e;
  -- 再振込: 元の行の側にも「再振込を作った」と履歴を足す（元の行そのものは変えない）
  for v_rl in
    select o.id as line_id, o.batch_id from payroll_transfer_batch_lines n join payroll_transfer_batch_lines o on o.id = n.retry_of_line_id where n.batch_id = v_batch
  loop
    perform public.payroll_recon_log(v_rl.batch_id, v_rl.line_id, 'retry_created', null, null, 'human', btrim(p_reason), jsonb_build_object('retry_batch_id', v_batch, 'retry_batch_seq', v_seq));
  end loop;
  perform public.payroll_recon_log(v_batch, null, 'frozen', null, 'planned', 'human', btrim(p_reason),
                                   jsonb_build_object('batch_seq', v_seq, 'batch_kind', p_kind, 'count', v_count, 'scheduled_date', p_scheduled_date, 'account_source', v_src));
  perform public.payroll_recon_eval(v_batch, 'auto_bank');
  perform set_config('payroll.recon_ok', '', true);

  return jsonb_build_object('ok', true, 'batch_id', v_batch, 'batch_seq', v_seq, 'batch_kind', p_kind, 'count', v_count, 'account_source', v_src);
end $$;
revoke all on function public.payroll_transfer_batch_freeze_custom(text, uuid, text, date, jsonb, text, text) from public, anon;
grant execute on function public.payroll_transfer_batch_freeze_custom(text, uuid, text, date, jsonb, text, text) to authenticated;

-- 固めまちがえたバッチを取り下げる（まだ何とも照合していない「振込予定」のときだけ。理由が必須・履歴に残る）
create or replace function public.payroll_transfer_batch_discard(p_batch_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_b payroll_transfer_batches%rowtype;
begin
  if auth.uid() is null or not public.payroll_pay_can() then raise exception '権限がありません'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception '理由を入力してください'; end if;
  select * into v_b from payroll_transfer_batches b where b.id = p_batch_id for update;
  if v_b.id is null then raise exception 'バッチが見つかりません'; end if;
  if v_b.status <> 'planned'
     or exists (select 1 from bank_bulk_transfers t where t.batch_id = v_b.id)
     or exists (select 1 from payroll_mf_total_matches m where m.batch_id = v_b.id)
     or exists (select 1 from payroll_transfer_batch_lines l where l.batch_id = v_b.id and (l.bank_detail_id is not null or l.manual_confirmation_id is not null))
     or exists (select 1 from payroll_transfer_batch_lines l join payroll_transfer_batch_lines r on r.retry_of_line_id = l.id where l.batch_id = v_b.id) then
    raise exception '照合・確認・再振込の記録があるバッチは、取り下げられません';
  end if;
  perform set_config('payroll.recon_ok', '1', true);
  delete from payroll_transfer_batch_lines l where l.batch_id = v_b.id;
  delete from payroll_transfer_batches b where b.id = v_b.id;
  perform public.payroll_recon_log(v_b.id, null, 'discarded', 'planned', null, 'human', p_reason,
                                   jsonb_build_object('year_month', v_b.year_month, 'corporation_id', v_b.corporation_id, 'batch_seq', v_b.batch_seq, 'batch_kind', v_b.batch_kind, 'count', v_b.expected_count));
  perform set_config('payroll.recon_ok', '', true);
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.payroll_transfer_batch_discard(uuid, text) from public, anon;
grant execute on function public.payroll_transfer_batch_discard(uuid, text) to authenticated;

-- ===== 6. 第 1 段階: マネーフォワードの出金 1 件を、バッチの合計と比べて記録する =====
--   「一致」の条件: 摘要に「WEB総振」／取引日＝振込指定日／預金の科目名が、その法人の設定（mf_deposit_accounts）にある／金額＝バッチの合計。
--   一致しても、変わるのはバッチの状態だけ（振込予定 → マネーフォワード総額照合済み）。予定者の行は 1 つも変えない。
--   同じ MF の出金を、別のバッチの「一致」には使えない。p_conclusive = true のときだけ、不一致を「確認待ち」にする（呼ぶ側が、ほかに候補が無いと判断したとき）。
create or replace function public.payroll_transfer_mf_total_record(p_batch_id uuid, p_tenant_id text, p_journal_id text, p_branch_no integer, p_transaction_date date,
                                                                   p_deposit_account text, p_amount numeric, p_remark text default null, p_conclusive boolean default false)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_b payroll_transfer_batches%rowtype; v_branch integer := coalesce(p_branch_no, 0); v_other uuid; v_allowed jsonb; v_result text; v_same integer;
begin
  if not public.payroll_recon_can() then raise exception '権限がありません'; end if;
  if coalesce(p_tenant_id, '') = '' or coalesce(p_journal_id, '') = '' or p_transaction_date is null or p_amount is null then
    raise exception 'マネーフォワードの出金の情報（事業者・仕訳 ID・取引日・金額）が足りません';
  end if;
  select * into v_b from payroll_transfer_batches b where b.id = p_batch_id for update;
  if v_b.id is null then raise exception 'バッチが見つかりません'; end if;

  select m.batch_id into v_other from payroll_mf_total_matches m
   where m.tenant_id = p_tenant_id and m.mf_journal_id = p_journal_id and m.branch_no = v_branch and m.result = 'matched';
  if v_other is not null and v_other <> v_b.id then
    return jsonb_build_object('ok', false, 'reason', 'mf_journal_used_by_other_batch');
  end if;
  if exists (select 1 from payroll_mf_total_matches m where m.batch_id = v_b.id and m.tenant_id = p_tenant_id and m.mf_journal_id = p_journal_id and m.branch_no = v_branch) then
    return jsonb_build_object('ok', true, 'already', true,
                              'result', (select m.result from payroll_mf_total_matches m where m.batch_id = v_b.id and m.tenant_id = p_tenant_id and m.mf_journal_id = p_journal_id and m.branch_no = v_branch));
  end if;

  v_allowed := public.payroll_recon_setting() -> 'corps' -> (v_b.corporation_id::text) -> 'mf_deposit_accounts';
  v_result := case
    when public.payroll_recon_kana_norm(p_remark) not like '%WEB総振%' then 'remark_mismatch'
    when p_transaction_date <> v_b.scheduled_date then 'date_mismatch'
    when v_allowed is null or jsonb_typeof(v_allowed) <> 'array' or jsonb_array_length(v_allowed) = 0 then 'deposit_account_not_configured'
    when not (v_allowed ? coalesce(p_deposit_account, '')) then 'deposit_account_mismatch'
    when p_amount <> v_b.expected_total then 'amount_mismatch'
    else 'matched' end;

  perform set_config('payroll.recon_ok', '1', true);
  insert into payroll_mf_total_matches(batch_id, tenant_id, mf_journal_id, branch_no, transaction_date, deposit_account, amount, remark, result, checked_by)
  values (v_b.id, p_tenant_id, p_journal_id, v_branch, p_transaction_date, p_deposit_account, p_amount, p_remark, v_result, auth.uid());

  if v_result = 'matched' then
    select count(*) into v_same from payroll_mf_total_matches m where m.batch_id = v_b.id and m.result = 'matched';
    if v_same > 1 then
      -- 一致する出金が 2 件以上: どちらか決められない
      if v_b.status in ('planned', 'mf_total_matched') then
        perform public.payroll_recon_set_batch(v_b.id, 'pending_check', 'mf_multiple_candidates', 'auto_mf', jsonb_build_object('matched', v_same));
      end if;
    else
      update payroll_transfer_batches b set mf_matched_at = coalesce(b.mf_matched_at, now()), updated_at = now() where b.id = v_b.id;
      if v_b.status = 'planned' or (v_b.status = 'pending_check' and coalesce(v_b.status_reason, '') like 'mf!_%' escape '!') then
        perform public.payroll_recon_set_batch(v_b.id, 'mf_total_matched', null, 'auto_mf', jsonb_build_object('transaction_date', p_transaction_date));
      else
        perform public.payroll_recon_log(v_b.id, null, 'mf_total_matched', v_b.status, v_b.status, 'auto_mf', null, jsonb_build_object('transaction_date', p_transaction_date));
      end if;
    end if;
  else
    perform public.payroll_recon_log(v_b.id, null, 'mf_total_checked', v_b.status, v_b.status, 'auto_mf', v_result, jsonb_build_object('transaction_date', p_transaction_date));
    if coalesce(p_conclusive, false) and v_b.status in ('planned', 'mf_total_matched') then
      perform public.payroll_recon_set_batch(v_b.id, 'pending_check', 'mf_' || v_result, 'auto_mf', null);
    end if;
  end if;
  perform set_config('payroll.recon_ok', '', true);

  return jsonb_build_object('ok', true, 'already', false, 'result', v_result,
                            'status', (select b.status from payroll_transfer_batches b where b.id = v_b.id));
end $$;
revoke all on function public.payroll_transfer_mf_total_record(uuid, text, text, integer, date, text, numeric, text, boolean) from public, anon;
grant execute on function public.payroll_transfer_mf_total_record(uuid, text, text, integer, date, text, numeric, text, boolean) to authenticated, service_role;

-- ===== 7. 第 2 段階: 1 対 1 の照合（内部用。呼ぶ側が payroll.recon_ok を立てておく） =====
--   ① まだ銀行取引と結んでいないバッチ: 出金口座がその法人のもの・振込指定日が同じ・件数が同じ・合計が同じ・まだどのバッチにも結ばれていない取引が、
--      ちょうど 1 件のときだけ結ぶ。2 件以上あるときは、明細がこのバッチの予定者とぴったり合う取引が 1 件だけなら、それを結ぶ。それでも決まらない → 確認待ち。
--      件数や合計が合わないものしか無い → 確認待ち。無い → 何も変えない。
--      同じ日・同じ件数・同じ合計の別のバッチ（追加・再振込・差額など）にぴったり合う取引は、このバッチの候補にしない（取りちがえを防ぐ）。
--      1 つの銀行取引は、1 つのバッチにだけ結べる（batch_id の 1 列）。
--   ② 予定者の行と明細: 金融機関・支店・種別・口座番号（acct_key）＋受取人カナ＋金額が、すべて一致する明細が 1 件だけのときに結ぶ。
--      0 件・2 件以上・同じ口座の人がバッチに 2 人 → 結ばずに確認待ち。氏名だけ・金額だけでは結ばない。
--   ③ 全員が結べて（または手動確認済みで）、銀行の結果が全件「成功」・取引の状態が「処理済み」:
--        手動確認を含む → 振込完了（手動確認）／スイッチ auto_complete が true → 振込完了／false → PayPay 銀行明細照合済み（ここで止める）
--      1 件でも失敗・返却 → 振込失敗。受付・処理中・不明 → 確認待ち。
create or replace function public.payroll_recon_eval(p_batch_id uuid, p_actor_kind text default 'auto_bank')
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_b payroll_transfer_batches%rowtype; v_t bank_bulk_transfers%rowtype; v_allowed jsonb;
  v_exact integer; v_full integer; v_near integer; v_exact_ids uuid[]; v_full_ids uuid[]; v_pick uuid; v_l record; v_cnt integer; v_did uuid; v_reason text;
  v_total integer; v_linked integer; v_manual integer; v_failed integer; v_notfinal integer; v_extra integer; v_counts jsonb;
begin
  select * into v_b from payroll_transfer_batches b where b.id = p_batch_id for update;
  if v_b.id is null then raise exception 'バッチが見つかりません'; end if;

  select * into v_t from bank_bulk_transfers t where t.batch_id = v_b.id;
  if v_t.id is null then
    v_allowed := public.payroll_recon_setting() -> 'corps' -> (v_b.corporation_id::text) -> 'source_account_keys';
    if v_allowed is null or jsonb_typeof(v_allowed) <> 'array' or jsonb_array_length(v_allowed) = 0 then
      if exists (select 1 from bank_bulk_transfers t where t.batch_id is null and t.designated_date = v_b.scheduled_date) then
        perform public.payroll_recon_set_batch(v_b.id, 'pending_check', 'source_account_not_configured', p_actor_kind, null);
      end if;
      return jsonb_build_object('batch_id', v_b.id, 'linked', false, 'status', (select b.status from payroll_transfer_batches b where b.id = v_b.id));
    end if;
    select array_agg(c.id order by c.id) filter (where c.exact), array_agg(c.id order by c.id) filter (where c.exact and c.full_match), count(*)
      into v_exact_ids, v_full_ids, v_near
      from (
        select t.id,
               (t.total_count = v_b.expected_count and t.total_amount = v_b.expected_total) as exact,
               public.payroll_recon_lines_match(v_b.id, t.id) as full_match
          from bank_bulk_transfers t
         where t.batch_id is null and t.designated_date = v_b.scheduled_date and v_allowed ? t.source_account_key
           -- ほかのバッチ（まだ銀行取引と結んでいないもの）にぴったり合う取引は、このバッチの候補にしない。このバッチにもぴったり合うときは候補に残す
           and (public.payroll_recon_lines_match(v_b.id, t.id)
                or not exists (select 1 from payroll_transfer_batches b2
                                where b2.id <> v_b.id and b2.scheduled_date = t.designated_date
                                  and b2.expected_count = t.total_count and b2.expected_total = t.total_amount
                                  and not exists (select 1 from bank_bulk_transfers t2 where t2.batch_id = b2.id)
                                  and public.payroll_recon_lines_match(b2.id, t.id)))
      ) c;
    v_exact := coalesce(array_length(v_exact_ids, 1), 0);
    v_full := coalesce(array_length(v_full_ids, 1), 0);
    v_pick := case when v_exact = 1 then v_exact_ids[1] when v_exact > 1 and v_full = 1 then v_full_ids[1] else null end;
    if v_pick is not null then
      update bank_bulk_transfers t set batch_id = v_b.id, linked_at = now()
       where t.id = v_pick and t.batch_id is null
      returning * into v_t;
      perform public.payroll_recon_log(v_b.id, null, 'bank_linked', null, null, p_actor_kind, null, jsonb_build_object('bank_transfer_id', v_t.id, 'candidates', v_exact));
    elsif v_exact > 1 then
      perform public.payroll_recon_set_batch(v_b.id, 'pending_check', 'multiple_bank_candidates', p_actor_kind, jsonb_build_object('candidates', v_exact));
      return jsonb_build_object('batch_id', v_b.id, 'linked', false, 'status', 'pending_check');
    elsif v_near > 0 then
      perform public.payroll_recon_set_batch(v_b.id, 'pending_check', 'bank_total_mismatch', p_actor_kind, jsonb_build_object('same_day_transfers', v_near));
      return jsonb_build_object('batch_id', v_b.id, 'linked', false, 'status', 'pending_check');
    else
      return jsonb_build_object('batch_id', v_b.id, 'linked', false, 'status', v_b.status);
    end if;
  end if;

  if not exists (select 1 from bank_bulk_transfer_details d where d.transfer_id = v_t.id) then
    perform public.payroll_recon_set_batch(v_b.id, 'pending_check', 'bank_details_missing', p_actor_kind, null);
    return jsonb_build_object('batch_id', v_b.id, 'linked', true, 'status', 'pending_check');
  end if;

  -- 予定者の行と明細を結ぶ（まだ結んでいない行だけ）
  for v_l in
    select l.id, l.acct_key, l.kana_norm, l.amount, l.line_status
      from payroll_transfer_batch_lines l where l.batch_id = v_b.id and l.bank_detail_id is null order by l.user_id
  loop
    v_reason := null; v_did := null;
    if (select count(*) from payroll_transfer_batch_lines l2 where l2.batch_id = v_b.id and l2.acct_key = v_l.acct_key) > 1 then
      v_reason := 'same_account_two_people';
    else
      select count(*), (array_agg(d.id))[1] into v_cnt, v_did
        from bank_bulk_transfer_details d
       where d.transfer_id = v_t.id and d.acct_key = v_l.acct_key and d.kana_norm = v_l.kana_norm and d.amount = v_l.amount
         and not exists (select 1 from payroll_transfer_batch_lines lx where lx.bank_detail_id = d.id);
      if v_cnt = 1 then
        v_reason := null;
      elsif v_cnt > 1 then
        v_reason := 'multiple_candidates';
      elsif exists (select 1 from bank_bulk_transfer_details d where d.transfer_id = v_t.id and d.acct_key = v_l.acct_key and d.kana_norm = v_l.kana_norm) then
        v_reason := 'amount_mismatch';
      elsif exists (select 1 from bank_bulk_transfer_details d where d.transfer_id = v_t.id and d.acct_key = v_l.acct_key) then
        v_reason := 'kana_mismatch';
      elsif exists (select 1 from bank_bulk_transfer_details d where d.transfer_id = v_t.id and d.kana_norm = v_l.kana_norm and d.amount = v_l.amount and d.acct_key is not null) then
        v_reason := 'account_mismatch';
      elsif exists (select 1 from bank_bulk_transfer_details d where d.transfer_id = v_t.id and d.acct_key is null) then
        v_reason := 'bank_account_unreadable';
      else
        v_reason := 'not_found_in_bank';
      end if;
    end if;
    if v_reason is null then
      update payroll_transfer_batch_lines l set bank_detail_id = v_did, updated_at = now() where l.id = v_l.id;
      perform public.payroll_recon_log(v_b.id, v_l.id, 'line_linked', null, null, p_actor_kind, null, null);
    elsif v_l.line_status <> 'manual_confirmed' then
      perform public.payroll_recon_set_line(v_l.id, 'pending_check', v_reason, p_actor_kind);
    end if;
  end loop;

  -- 結べた行の状態を、銀行の結果に合わせる
  for v_l in
    select l.id, l.line_status, d.result
      from payroll_transfer_batch_lines l join bank_bulk_transfer_details d on d.id = l.bank_detail_id
     where l.batch_id = v_b.id
  loop
    if v_l.result = 'failed' then
      perform public.payroll_recon_set_line(v_l.id, 'failed', 'bank_failed', p_actor_kind);
    elsif v_l.result = 'returned' then
      perform public.payroll_recon_set_line(v_l.id, 'returned', 'bank_returned', p_actor_kind);
    elsif v_l.result = 'success' then
      if v_l.line_status <> 'completed' then
        perform public.payroll_recon_set_line(v_l.id, 'bank_matched', null, p_actor_kind);
      end if;
    else
      perform public.payroll_recon_set_line(v_l.id, 'bank_matched', 'bank_result_' || v_l.result, p_actor_kind);
    end if;
  end loop;

  select count(*),
         count(*) filter (where l.bank_detail_id is not null),
         count(*) filter (where l.bank_detail_id is null and l.line_status = 'manual_confirmed'),
         count(*) filter (where d.result in ('failed', 'returned')),
         count(*) filter (where l.bank_detail_id is not null and d.result not in ('success', 'failed', 'returned'))
    into v_total, v_linked, v_manual, v_failed, v_notfinal
    from payroll_transfer_batch_lines l left join bank_bulk_transfer_details d on d.id = l.bank_detail_id
   where l.batch_id = v_b.id;
  select count(*) into v_extra from bank_bulk_transfer_details d
   where d.transfer_id = v_t.id and not exists (select 1 from payroll_transfer_batch_lines l where l.bank_detail_id = d.id);
  v_counts := jsonb_build_object('people', v_total, 'linked', v_linked, 'manual', v_manual, 'failed', v_failed, 'not_final', v_notfinal, 'bank_extra', v_extra);

  if v_failed > 0 then
    perform public.payroll_recon_set_batch(v_b.id, 'failed', 'bank_failed_or_returned', p_actor_kind, v_counts);
  elsif v_linked + v_manual < v_total then
    perform public.payroll_recon_set_batch(v_b.id, 'pending_check', 'lines_not_matched', p_actor_kind, v_counts);
  elsif v_extra > v_manual then
    perform public.payroll_recon_set_batch(v_b.id, 'pending_check', 'bank_has_extra_details', p_actor_kind, v_counts);
  elsif v_notfinal > 0 or v_t.bank_status <> 'done' then
    perform public.payroll_recon_set_batch(v_b.id, 'pending_check', 'bank_result_not_final', p_actor_kind, v_counts);
  elsif v_manual > 0 then
    perform public.payroll_recon_complete(v_b.id, 'manual', p_actor_kind, null);
  else
    update payroll_transfer_batches b set bank_matched_at = coalesce(b.bank_matched_at, now()), updated_at = now() where b.id = v_b.id;
    if public.payroll_recon_flag('auto_complete') then
      perform public.payroll_recon_complete(v_b.id, 'auto', p_actor_kind, null);
    elsif (select b.status from payroll_transfer_batches b where b.id = v_b.id) <> 'completed' then
      perform public.payroll_recon_set_batch(v_b.id, 'bank_matched', null, p_actor_kind, v_counts);
    end if;
  end if;

  return jsonb_build_object('batch_id', v_b.id, 'linked', true, 'status', (select b.status from payroll_transfer_batches b where b.id = v_b.id), 'counts', v_counts);
end $$;
revoke all on function public.payroll_recon_eval(uuid, text) from public, anon, authenticated;

-- 照合をやり直す（画面・定期実行から。スイッチを変えたあとにも使う）
create or replace function public.payroll_transfer_recon_run(p_batch_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_res jsonb;
begin
  if not public.payroll_recon_can() then raise exception '権限がありません'; end if;
  perform set_config('payroll.recon_ok', '1', true);
  v_res := public.payroll_recon_eval(p_batch_id, 'auto_bank');
  perform set_config('payroll.recon_ok', '', true);
  return jsonb_build_object('ok', true) || v_res;
end $$;
revoke all on function public.payroll_transfer_recon_run(uuid) from public, anon;
grant execute on function public.payroll_transfer_recon_run(uuid) to authenticated, service_role;

-- ===== 8. 銀行の取り込みの入口（総合振込 1 件＋明細 N 件） =====
--   p_transfer: { bank?, source_account_key, bank_ref, designated_date, total_count, total_amount, fee_total?, bank_status, bank_status_raw?, login_profile? }
--   p_details : [ { line_no, bank_code, branch_code, account_type, account_number, holder_kana, amount, result, result_raw? }, … ]（null＝明細はまだ読めていない）
--   同じ受付番号（bank × source_account_key × bank_ref）の再投入では、行は増えない。結果が変わったときだけ、前後を履歴に残して更新する。
--   明細の件数・合計が、総合振込の件数・合計と合わないときは、取り込まない（読み取りが途中で切れた可能性）。
--   同じ受付番号なのに、振込指定日・件数・合計・振込先・金額が前回と違うときも、取り込まない。
create or replace function public.bank_bulk_transfer_ingest(p_transfer jsonb, p_details jsonb default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_bank text; v_key text; v_ref text; v_date date; v_cnt integer; v_total numeric; v_status text; v_raw text;
  v_t bank_bulk_transfers%rowtype; v_old bank_bulk_transfer_details%rowtype; v_d record;
  v_new boolean := false; v_changed integer := 0; v_dn integer; v_dsum numeric; v_dlines integer; v_akey text; v_kana text;
  v_batch uuid; v_evals jsonb := '[]'::jsonb; v_line uuid;
begin
  if not public.payroll_recon_can() then raise exception '権限がありません'; end if;
  if p_transfer is null or jsonb_typeof(p_transfer) <> 'object' then raise exception '総合振込の情報がありません'; end if;
  v_bank := coalesce(nullif(btrim(p_transfer ->> 'bank'), ''), 'paypay');
  v_key := nullif(btrim(p_transfer ->> 'source_account_key'), '');
  v_ref := nullif(btrim(p_transfer ->> 'bank_ref'), '');
  v_date := (p_transfer ->> 'designated_date')::date;
  v_cnt := (p_transfer ->> 'total_count')::integer;
  v_total := (p_transfer ->> 'total_amount')::numeric;
  v_raw := p_transfer ->> 'bank_status_raw';
  v_status := coalesce(nullif(btrim(p_transfer ->> 'bank_status'), ''), 'unknown');
  if v_key is null or v_ref is null or v_date is null or v_cnt is null or v_total is null then
    raise exception '総合振込の情報（出金口座の印・受付番号・振込指定日・件数・合計）が足りません';
  end if;
  if v_status not in ('accepted', 'processing', 'done', 'partial', 'failed', 'unknown') then raise exception '銀行の状態の値が不正です: %', v_status; end if;

  if p_details is not null then
    if jsonb_typeof(p_details) <> 'array' then raise exception '明細は配列で渡してください'; end if;
    select count(*), coalesce(sum((d.value ->> 'amount')::numeric), 0), count(distinct (d.value ->> 'line_no')::integer)
      into v_dn, v_dsum, v_dlines from jsonb_array_elements(p_details) d;
    if v_dn <> v_cnt or v_dsum <> v_total or v_dlines <> v_dn then
      raise exception '明細の件数・合計が、総合振込の件数・合計と合いません（読み取りが途中で切れた可能性）。取り込みません';
    end if;
    if exists (select 1 from jsonb_array_elements(p_details) d
                where coalesce(nullif(btrim(d.value ->> 'result'), ''), 'unknown') not in ('success', 'failed', 'returned', 'accepted', 'processing', 'unknown')) then
      raise exception '明細の結果の値が不正です';
    end if;
  end if;

  perform set_config('payroll.recon_ok', '1', true);
  perform pg_advisory_xact_lock(hashtext('bank_bulk_transfer:' || v_bank || ':' || v_key || ':' || v_ref));
  select * into v_t from bank_bulk_transfers t where t.bank = v_bank and t.source_account_key = v_key and t.bank_ref = v_ref for update;
  if v_t.id is null then
    insert into bank_bulk_transfers(bank, source_account_key, bank_ref, designated_date, total_count, total_amount, fee_total, bank_status_raw, bank_status, login_profile)
    values (v_bank, v_key, v_ref, v_date, v_cnt, v_total, (p_transfer ->> 'fee_total')::numeric, v_raw, v_status, p_transfer ->> 'login_profile')
    returning * into v_t;
    v_new := true;
    perform public.payroll_recon_log(null, null, 'bank_imported', null, v_status, 'auto_bank', null, jsonb_build_object('bank_transfer_id', v_t.id, 'designated_date', v_date, 'count', v_cnt));
  else
    if v_t.designated_date <> v_date or v_t.total_count <> v_cnt or v_t.total_amount <> v_total then
      raise exception '同じ受付番号なのに、振込指定日・件数・合計が前回と違います。取り込みません';
    end if;
    if v_t.bank_status is distinct from v_status then
      perform public.payroll_recon_log(v_t.batch_id, null, 'bank_status_changed', v_t.bank_status, v_status, 'auto_bank', null, jsonb_build_object('bank_transfer_id', v_t.id));
    end if;
    update bank_bulk_transfers t set bank_status = v_status, bank_status_raw = coalesce(v_raw, t.bank_status_raw), last_seen_at = now() where t.id = v_t.id
    returning * into v_t;
  end if;

  if p_details is not null then
    for v_d in
      select (d.value ->> 'line_no')::integer as line_no, d.value ->> 'bank_code' as bank_code, d.value ->> 'branch_code' as branch_code,
             d.value ->> 'account_type' as account_type, d.value ->> 'account_number' as account_number, d.value ->> 'holder_kana' as holder_kana,
             (d.value ->> 'amount')::numeric as amount, coalesce(nullif(btrim(d.value ->> 'result'), ''), 'unknown') as result, d.value ->> 'result_raw' as result_raw
        from jsonb_array_elements(p_details) d
    loop
      v_akey := public.payroll_recon_acct_key(v_d.bank_code, v_d.branch_code, v_d.account_type, v_d.account_number);
      v_kana := public.payroll_recon_kana_norm(v_d.holder_kana);
      select * into v_old from bank_bulk_transfer_details x where x.transfer_id = v_t.id and x.line_no = v_d.line_no;
      if v_old.id is null then
        insert into bank_bulk_transfer_details(transfer_id, line_no, bank_code, branch_code, account_type, account_number, holder_kana, acct_key, kana_norm, amount, result_raw, result)
        values (v_t.id, v_d.line_no, v_d.bank_code, v_d.branch_code, v_d.account_type, v_d.account_number, v_d.holder_kana, v_akey, v_kana, v_d.amount, v_d.result_raw, v_d.result);
      else
        if v_old.acct_key is distinct from v_akey or v_old.kana_norm is distinct from v_kana or v_old.amount <> v_d.amount then
          raise exception '同じ受付番号・同じ行番号なのに、振込先や金額が前回と違います。取り込みません';
        end if;
        if v_old.result is distinct from v_d.result then
          select l.id into v_line from payroll_transfer_batch_lines l where l.bank_detail_id = v_old.id;
          update bank_bulk_transfer_details x set result = v_d.result, result_raw = coalesce(v_d.result_raw, x.result_raw), last_seen_at = now() where x.id = v_old.id;
          perform public.payroll_recon_log(v_t.batch_id, v_line, 'bank_result_changed', v_old.result, v_d.result, 'auto_bank', null, jsonb_build_object('bank_transfer_id', v_t.id, 'line_no', v_d.line_no));
          v_changed := v_changed + 1;
        else
          update bank_bulk_transfer_details x set last_seen_at = now() where x.id = v_old.id;
        end if;
      end if;
    end loop;
  end if;

  -- 照合: 結び済みならそのバッチ、まだなら、振込指定日が同じで銀行取引と結んでいないバッチを順に確かめる
  if v_t.batch_id is not null then
    v_evals := v_evals || jsonb_build_array(public.payroll_recon_eval(v_t.batch_id, 'auto_bank'));
  else
    for v_batch in
      select b.id from payroll_transfer_batches b
       where b.scheduled_date = v_date and not exists (select 1 from bank_bulk_transfers t2 where t2.batch_id = b.id)
       order by public.payroll_recon_lines_match(b.id, v_t.id) desc, b.year_month, b.batch_seq   -- 明細がぴったり合うバッチを先に
    loop
      v_evals := v_evals || jsonb_build_array(public.payroll_recon_eval(v_batch, 'auto_bank'));
    end loop;
  end if;
  perform set_config('payroll.recon_ok', '', true);

  return jsonb_build_object('ok', true, 'bank_transfer_id', v_t.id, 'new', v_new, 'results_changed', v_changed, 'batches', v_evals);
end $$;
revoke all on function public.bank_bulk_transfer_ingest(jsonb, jsonb) from public, anon;
grant execute on function public.bank_bulk_transfer_ingest(jsonb, jsonb) to authenticated, service_role;

-- ===== 9. 人の操作 =====

-- 「PayPay 銀行明細照合済み」を、人が「振込完了」にする（自動完了のスイッチが OFF のあいだの操作）
create or replace function public.payroll_transfer_batch_complete(p_batch_id uuid, p_note text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_b payroll_transfer_batches%rowtype;
begin
  if auth.uid() is null or not public.payroll_pay_can() then raise exception '権限がありません'; end if;
  select * into v_b from payroll_transfer_batches b where b.id = p_batch_id for update;
  if v_b.id is null then raise exception 'バッチが見つかりません'; end if;
  if v_b.status <> 'bank_matched' then
    raise exception '「PayPay 銀行明細照合済み」のバッチだけ、完了にできます（いまの状態: %）', public.payroll_transfer_status_label(v_b.status, v_b.completed_kind);
  end if;
  perform set_config('payroll.recon_ok', '1', true);
  perform public.payroll_recon_complete(v_b.id, 'human', 'human', p_note);
  perform set_config('payroll.recon_ok', '', true);
  return jsonb_build_object('ok', true, 'status', 'completed', 'completed_kind', 'human');
end $$;
revoke all on function public.payroll_transfer_batch_complete(uuid, text) from public, anon;
grant execute on function public.payroll_transfer_batch_complete(uuid, text) to authenticated;

-- 手動確認: 銀行の証跡が取れないとき、「人が確認した」と記録する（銀行の自動照合とは別の記録。確認者・根拠・理由が必須）
--   p_user_id = null で、まだ銀行の明細と結べていない行すべて。自分の給与の行は、自分では確認済みにできない。
--   銀行の明細と結べている行は対象外（銀行の結果を待つ）。bank_matched_at は入らない＝自動照合が通っていないことが分かる。
create or replace function public.payroll_transfer_manual_confirm(p_batch_id uuid, p_user_id uuid, p_basis text, p_reason text, p_evidence_id uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := auth.uid(); v_b payroll_transfer_batches%rowtype; v_l record; v_conf bigint; v_n integer := 0; v_res jsonb;
begin
  if v_uid is null or not public.payroll_pay_can() then raise exception '権限がありません（確認者が分かるログインが必要です）'; end if;
  if coalesce(btrim(p_basis), '') = '' then raise exception '何を見て確かめたか（確認の根拠）を入力してください'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception '理由を入力してください'; end if;
  select * into v_b from payroll_transfer_batches b where b.id = p_batch_id for update;
  if v_b.id is null then raise exception 'バッチが見つかりません'; end if;
  if exists (select 1 from payroll_transfer_batch_lines l
              where l.batch_id = v_b.id and l.bank_detail_id is null and l.line_status <> 'manual_confirmed'
                and (p_user_id is null or l.user_id = p_user_id) and l.user_id = v_uid) then
    raise exception '自分の給与の振込を、自分で確認済みにはできません';
  end if;
  if not exists (select 1 from payroll_transfer_batch_lines l
                  where l.batch_id = v_b.id and l.bank_detail_id is null and l.line_status <> 'manual_confirmed'
                    and (p_user_id is null or l.user_id = p_user_id)) then
    raise exception '対象の行がありません（銀行の明細と結べている行・確認済みの行は、手動確認の対象外です）';
  end if;

  perform set_config('payroll.recon_ok', '1', true);
  for v_l in
    select l.id, l.user_id from payroll_transfer_batch_lines l
     where l.batch_id = v_b.id and l.bank_detail_id is null and l.line_status <> 'manual_confirmed'
       and (p_user_id is null or l.user_id = p_user_id)
     order by l.user_id
  loop
    insert into payroll_transfer_manual_confirmations(batch_id, line_id, user_id, action, basis, reason, evidence_id, confirmed_by)
    values (v_b.id, v_l.id, v_l.user_id, 'confirm', btrim(p_basis), btrim(p_reason), p_evidence_id, v_uid)
    returning id into v_conf;
    update payroll_transfer_batch_lines l set manual_confirmation_id = v_conf, updated_at = now() where l.id = v_l.id;
    perform public.payroll_recon_set_line(v_l.id, 'manual_confirmed', 'manual', 'human');
    v_n := v_n + 1;
  end loop;
  perform public.payroll_recon_log(v_b.id, null, 'manual_confirmed', v_b.status, v_b.status, 'human', btrim(p_reason), jsonb_build_object('lines', v_n, 'basis', btrim(p_basis)));

  if exists (select 1 from bank_bulk_transfers t where t.batch_id = v_b.id) then
    v_res := public.payroll_recon_eval(v_b.id, 'human');
  elsif not exists (select 1 from payroll_transfer_batch_lines l where l.batch_id = v_b.id and l.line_status <> 'manual_confirmed') then
    perform public.payroll_recon_complete(v_b.id, 'manual', 'human', btrim(p_reason));   -- 全員が手動確認済み（銀行のデータなし）
  end if;
  perform set_config('payroll.recon_ok', '', true);

  return jsonb_build_object('ok', true, 'confirmed', v_n,
                            'status', (select b.status from payroll_transfer_batches b where b.id = v_b.id),
                            'completed_kind', (select b.completed_kind from payroll_transfer_batches b where b.id = v_b.id));
end $$;
revoke all on function public.payroll_transfer_manual_confirm(uuid, uuid, text, text, uuid) from public, anon;
grant execute on function public.payroll_transfer_manual_confirm(uuid, uuid, text, text, uuid) to authenticated;

-- 手動確認の取り消し（記録は消さず、「取り消した」と足す。理由が必須）
create or replace function public.payroll_transfer_manual_revoke(p_batch_id uuid, p_user_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := auth.uid(); v_b payroll_transfer_batches%rowtype; v_l payroll_transfer_batch_lines%rowtype; v_has_bank boolean;
begin
  if v_uid is null or not public.payroll_pay_can() then raise exception '権限がありません'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception '理由を入力してください'; end if;
  select * into v_b from payroll_transfer_batches b where b.id = p_batch_id for update;
  if v_b.id is null then raise exception 'バッチが見つかりません'; end if;
  select * into v_l from payroll_transfer_batch_lines l where l.batch_id = v_b.id and l.user_id = p_user_id and l.line_status = 'manual_confirmed';
  if v_l.id is null then raise exception '手動確認済みの行が見つかりません'; end if;
  v_has_bank := exists (select 1 from bank_bulk_transfers t where t.batch_id = v_b.id);

  perform set_config('payroll.recon_ok', '1', true);
  insert into payroll_transfer_manual_confirmations(batch_id, line_id, user_id, action, ref_id, reason, confirmed_by)
  values (v_b.id, v_l.id, v_l.user_id, 'revoke', v_l.manual_confirmation_id, btrim(p_reason), v_uid);
  update payroll_transfer_batch_lines l set manual_confirmation_id = null, updated_at = now() where l.id = v_l.id;
  perform public.payroll_recon_set_line(v_l.id, case when v_has_bank then 'pending_check' else 'planned' end, 'manual_revoked', 'human');
  perform public.payroll_recon_set_batch(v_b.id, 'pending_check', 'manual_revoked', 'human', null);
  if v_has_bank then perform public.payroll_recon_eval(v_b.id, 'human'); end if;
  perform set_config('payroll.recon_ok', '', true);

  return jsonb_build_object('ok', true, 'status', (select b.status from payroll_transfer_batches b where b.id = v_b.id));
end $$;
revoke all on function public.payroll_transfer_manual_revoke(uuid, uuid, text) from public, anon;
grant execute on function public.payroll_transfer_manual_revoke(uuid, uuid, text) to authenticated;

-- ===== 10. 証憑 =====

-- 証憑の記録を足す（ファイルそのものは、先に Storage へ「上書きなし」で置く。ここは記録だけ）。
--   同じ月 × 法人 × 種類 × SHA-256 がすでにあれば、足さずに「保存済み」を返す。同じ保存先がすでに使われていれば、止める（上書きしない）。
create or replace function public.payroll_transfer_evidence_add(p_year_month text, p_corp_id uuid, p_kind text, p_storage_bucket text, p_storage_path text, p_sha256 text,
                                                                p_size_bytes bigint, p_mime text, p_fetched_at timestamptz, p_source text, p_fetched_by text default null,
                                                                p_batch_id uuid default null, p_bank_transfer_id uuid default null, p_bank_status text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_sha text := lower(btrim(coalesce(p_sha256, ''))); v_id uuid; v_by text := coalesce(nullif(btrim(p_fetched_by), ''), auth.uid()::text);
begin
  if not public.payroll_recon_can() then raise exception '権限がありません'; end if;
  if p_kind is null or p_kind not in ('detail_pdf', 'result_pdf', 'detail_csv', 'result_csv', 'manual_upload') then raise exception '証憑の種類が不正です'; end if;
  if v_sha !~ '^[0-9a-f]{64}$' then raise exception 'SHA-256 が不正です'; end if;
  if coalesce(btrim(p_storage_bucket), '') = '' or coalesce(btrim(p_storage_path), '') = '' then raise exception '保存先がありません'; end if;
  if p_fetched_at is null or coalesce(btrim(p_source), '') = '' or v_by is null then raise exception '取得日時・取得元・取得した人（またはロボットの名前）が必要です'; end if;

  select e.id into v_id from payroll_transfer_evidence e
   where e.year_month = p_year_month and e.corporation_id = p_corp_id and e.kind = p_kind and e.sha256 = v_sha;
  if v_id is not null then
    return jsonb_build_object('ok', true, 'duplicate', true, 'evidence_id', v_id);
  end if;
  if exists (select 1 from payroll_transfer_evidence e where e.storage_bucket = p_storage_bucket and e.storage_path = p_storage_path) then
    raise exception '同じ保存先が、すでに別の証憑で使われています（上書きはしません）';
  end if;

  perform set_config('payroll.recon_ok', '1', true);
  insert into payroll_transfer_evidence(year_month, corporation_id, batch_id, bank_transfer_id, kind, storage_bucket, storage_path, sha256, size_bytes, mime,
                                        fetched_at, source, fetched_by, bank_status_at_fetch)
  values (p_year_month, p_corp_id, p_batch_id, p_bank_transfer_id, p_kind, p_storage_bucket, p_storage_path, v_sha, p_size_bytes, p_mime,
          p_fetched_at, btrim(p_source), v_by, p_bank_status)
  returning id into v_id;
  perform public.payroll_recon_log(p_batch_id, null, 'evidence_saved', null, null, case when auth.uid() is null then 'auto_bank' else 'human' end, null,
                                   jsonb_build_object('evidence_id', v_id, 'kind', p_kind, 'year_month', p_year_month));
  perform set_config('payroll.recon_ok', '', true);
  return jsonb_build_object('ok', true, 'duplicate', false, 'evidence_id', v_id);
end $$;
revoke all on function public.payroll_transfer_evidence_add(text, uuid, text, text, text, text, bigint, text, timestamptz, text, text, uuid, uuid, text) from public, anon;
grant execute on function public.payroll_transfer_evidence_add(text, uuid, text, text, text, text, bigint, text, timestamptz, text, text, uuid, uuid, text) to authenticated, service_role;

-- 証憑が取れなかったことを記録する（理由が必須）
create or replace function public.payroll_transfer_evidence_unavailable(p_year_month text, p_corp_id uuid, p_wanted_kind text, p_reason text, p_source text, p_fetched_by text default null,
                                                                        p_batch_id uuid default null, p_bank_transfer_id uuid default null, p_bank_status text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid; v_by text := coalesce(nullif(btrim(p_fetched_by), ''), auth.uid()::text);
begin
  if not public.payroll_recon_can() then raise exception '権限がありません'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception '取れなかった理由を入力してください'; end if;
  if coalesce(btrim(p_source), '') = '' or v_by is null then raise exception '取得元・取得しようとした人（またはロボットの名前）が必要です'; end if;
  perform set_config('payroll.recon_ok', '1', true);
  insert into payroll_transfer_evidence(year_month, corporation_id, batch_id, bank_transfer_id, kind, wanted_kind, fetched_at, source, fetched_by, bank_status_at_fetch, unavailable_reason)
  values (p_year_month, p_corp_id, p_batch_id, p_bank_transfer_id, 'unavailable', p_wanted_kind, now(), btrim(p_source), v_by, p_bank_status, btrim(p_reason))
  returning id into v_id;
  perform public.payroll_recon_log(p_batch_id, null, 'evidence_unavailable', null, null, case when auth.uid() is null then 'auto_bank' else 'human' end, btrim(p_reason),
                                   jsonb_build_object('evidence_id', v_id, 'wanted_kind', p_wanted_kind, 'year_month', p_year_month));
  perform set_config('payroll.recon_ok', '', true);
  return jsonb_build_object('ok', true, 'evidence_id', v_id);
end $$;
revoke all on function public.payroll_transfer_evidence_unavailable(text, uuid, text, text, text, text, uuid, uuid, text) from public, anon;
grant execute on function public.payroll_transfer_evidence_unavailable(text, uuid, text, text, text, text, uuid, uuid, text) to authenticated, service_role;

-- ===== 11. 画面用・Slack 用（読むだけ） =====

-- 画面用の状況（本部・社長・マスターだけ）。その月（× 法人）のバッチを、法人・連番の順に並べて返す（通常・追加・再振込・差額）。
--   口座番号・名義カナ・口座の鍵は返さない（金融機関名だけ）
create or replace function public.payroll_transfer_recon_status(p_year_month text, p_corp_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public.payroll_pay_can() then raise exception '権限がありません'; end if;
  return jsonb_build_object(
    'ok', true, 'year_month', p_year_month,
    'switches', jsonb_build_object('mf_total_enabled', public.payroll_recon_flag('mf_total_enabled'), 'bank_read_enabled', public.payroll_recon_flag('bank_read_enabled'),
                                   'auto_complete', public.payroll_recon_flag('auto_complete'), 'slack_enabled', public.payroll_recon_flag('slack_enabled')),
    'batch_count', (select count(*) from payroll_transfer_batches b where b.year_month = p_year_month and (p_corp_id is null or b.corporation_id = p_corp_id)),
    'batches', (
      select coalesce(jsonb_agg(x.j order by x.corp_name, x.batch_seq), '[]'::jsonb)
        from (
          select coalesce((select c.name from corporations c where c.id = b.corporation_id), '') as corp_name, b.batch_seq,
                 jsonb_build_object(
                   'batch_id', b.id, 'corporation_id', b.corporation_id, 'corp_name', (select c.name from corporations c where c.id = b.corporation_id),
                   'batch_seq', b.batch_seq, 'batch_kind', b.batch_kind, 'batch_kind_label', public.payroll_transfer_kind_label(b.batch_kind), 'kind_reason', b.kind_reason,
                   'scheduled_date', b.scheduled_date, 'status', b.status, 'status_label', public.payroll_transfer_status_label(b.status, b.completed_kind),
                   'status_reason', b.status_reason, 'expected_count', b.expected_count, 'expected_total', b.expected_total,
                   'mf_matched_at', b.mf_matched_at, 'bank_matched_at', b.bank_matched_at, 'completed_at', b.completed_at, 'completed_kind', b.completed_kind,
                   'failed_at', b.failed_at, 'frozen_at', b.frozen_at,
                   'mf', (select coalesce(jsonb_agg(jsonb_build_object('result', m.result, 'transaction_date', m.transaction_date, 'deposit_account', m.deposit_account, 'checked_at', m.checked_at) order by m.checked_at), '[]'::jsonb)
                            from payroll_mf_total_matches m where m.batch_id = b.id),
                   'bank', (select jsonb_build_object('bank_transfer_id', t.id, 'bank', t.bank, 'designated_date', t.designated_date, 'total_count', t.total_count,
                                                      'bank_status', t.bank_status, 'bank_status_raw', t.bank_status_raw, 'linked_at', t.linked_at, 'last_seen_at', t.last_seen_at)
                              from bank_bulk_transfers t where t.batch_id = b.id),
                   'line_counts', (select coalesce(jsonb_object_agg(s.line_status, s.n), '{}'::jsonb)
                                     from (select l.line_status, count(*) as n from payroll_transfer_batch_lines l where l.batch_id = b.id group by l.line_status) s),
                   'lines', (select coalesce(jsonb_agg(jsonb_build_object('line_id', l.id, 'user_id', l.user_id, 'name', (select u.name from users u where u.id = l.user_id), 'line_status', l.line_status,
                                                                         'reason', l.status_reason, 'amount', l.amount, 'bank_name', l.account ->> 'bank_name',
                                                                         'linked', l.bank_detail_id is not null, 'manual', l.manual_confirmation_id is not null,
                                                                         'retry_of_line_id', l.retry_of_line_id, 'note', l.line_note,
                                                                         -- この行（失敗・組戻し）に対して作られた再振込（あれば、そのバッチの連番と行の状態）
                                                                         'retried_by', (select jsonb_build_object('batch_id', rb.id, 'batch_seq', rb.batch_seq, 'line_status', r.line_status,
                                                                                                                   'batch_status_label', public.payroll_transfer_status_label(rb.status, rb.completed_kind))
                                                                                          from payroll_transfer_batch_lines r join payroll_transfer_batches rb on rb.id = r.batch_id
                                                                                         where r.retry_of_line_id = l.id))
                                                      order by (l.line_status in ('completed', 'bank_matched')), l.user_id), '[]'::jsonb)
                               from payroll_transfer_batch_lines l where l.batch_id = b.id),
                   'manual', (select coalesce(jsonb_agg(jsonb_build_object('id', mc.id, 'user_id', mc.user_id, 'action', mc.action, 'basis', mc.basis, 'reason', mc.reason,
                                                                          'confirmed_by', mc.confirmed_by, 'confirmed_by_name', (select u.name from users u where u.id = mc.confirmed_by),
                                                                          'confirmed_at', mc.confirmed_at) order by mc.id), '[]'::jsonb)
                                from payroll_transfer_manual_confirmations mc where mc.batch_id = b.id),
                   'evidence', (select coalesce(jsonb_agg(jsonb_build_object('evidence_id', e.id, 'kind', e.kind, 'wanted_kind', e.wanted_kind, 'storage_bucket', e.storage_bucket,
                                                                            'storage_path', e.storage_path, 'size_bytes', e.size_bytes, 'fetched_at', e.fetched_at, 'source', e.source,
                                                                            'fetched_by', e.fetched_by, 'unavailable_reason', e.unavailable_reason) order by e.fetched_at), '[]'::jsonb)
                                  from payroll_transfer_evidence e where e.batch_id = b.id),
                   'events', (select coalesce(jsonb_agg(ev.j order by ev.id desc), '[]'::jsonb)
                                from (select v.id, jsonb_build_object('id', v.id, 'event', v.event, 'from', v.from_status, 'to', v.to_status, 'actor_kind', v.actor_kind,
                                                                      'actor_name', (select u.name from users u where u.id = v.actor_id), 'reason', v.reason, 'line_id', v.line_id, 'at', v.created_at) as j
                                        from payroll_transfer_recon_events v where v.batch_id = b.id order by v.id desc limit 100) ev)
                 ) as j
            from payroll_transfer_batches b
           where b.year_month = p_year_month and (p_corp_id is null or b.corporation_id = p_corp_id)
        ) x),
    -- どのバッチにも結び付けていない証憑（その月 × 法人）
    'evidence_other', (select coalesce(jsonb_agg(jsonb_build_object('evidence_id', e.id, 'corporation_id', e.corporation_id, 'kind', e.kind, 'wanted_kind', e.wanted_kind,
                                                                   'storage_bucket', e.storage_bucket, 'storage_path', e.storage_path, 'size_bytes', e.size_bytes, 'fetched_at', e.fetched_at,
                                                                   'source', e.source, 'fetched_by', e.fetched_by, 'unavailable_reason', e.unavailable_reason) order by e.fetched_at), '[]'::jsonb)
                         from payroll_transfer_evidence e
                        where e.year_month = p_year_month and (p_corp_id is null or e.corporation_id = p_corp_id) and e.batch_id is null)
  );
end $$;
revoke all on function public.payroll_transfer_recon_status(text, uuid) from public, anon;
grant execute on function public.payroll_transfer_recon_status(text, uuid) to authenticated;

-- Slack 用の要約（状況だけ）。金額・口座・氏名・ファイルの場所は返さない。返すのは、対象月・法人・状態・人数・理由の種類だけ
create or replace function public.payroll_transfer_recon_slack_summary(p_batch_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_b payroll_transfer_batches%rowtype;
begin
  if not public.payroll_recon_can() then raise exception '権限がありません'; end if;
  select * into v_b from payroll_transfer_batches b where b.id = p_batch_id;
  if v_b.id is null then raise exception 'バッチが見つかりません'; end if;
  return jsonb_build_object(
    'ok', true,
    'enabled', public.payroll_recon_flag('slack_enabled'),
    'channel_key', public.payroll_recon_setting() ->> 'slack_channel_key',
    'year_month', v_b.year_month,
    'corp_name', (select c.name from corporations c where c.id = v_b.corporation_id),
    'batch_seq', v_b.batch_seq,
    'batch_kind', v_b.batch_kind,
    'batch_kind_label', public.payroll_transfer_kind_label(v_b.batch_kind),
    'status', v_b.status,
    'status_label', public.payroll_transfer_status_label(v_b.status, v_b.completed_kind),
    'status_reason', v_b.status_reason,
    'people_total', v_b.expected_count,
    'people_ok', (select count(*) from payroll_transfer_batch_lines l where l.batch_id = v_b.id
                     and (l.line_status in ('completed', 'manual_confirmed') or (l.line_status = 'bank_matched' and l.status_reason is null))),
    'people_pending', (select count(*) from payroll_transfer_batch_lines l where l.batch_id = v_b.id
                          and (l.line_status in ('planned', 'pending_check') or (l.line_status = 'bank_matched' and l.status_reason is not null))),
    'people_failed', (select count(*) from payroll_transfer_batch_lines l where l.batch_id = v_b.id and l.line_status in ('failed', 'returned')),
    'reason_kinds', (select coalesce(jsonb_agg(distinct l.status_reason), '[]'::jsonb) from payroll_transfer_batch_lines l where l.batch_id = v_b.id and l.status_reason is not null and l.status_reason <> 'manual')
  );
end $$;
revoke all on function public.payroll_transfer_recon_slack_summary(uuid) from public, anon;
grant execute on function public.payroll_transfer_recon_slack_summary(uuid) to authenticated, service_role;
