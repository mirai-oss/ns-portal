-- 担当C: 請求書メール自動処理 Phase3「明細OCR」（実装指示書 Phase3／設計書）
--
-- 【事前報告様式（DB変更）】
-- 理由: 請求書の明細行（店舗別・税率別など）を読み取って行単位で持ち、Phase4（店舗の解決）・Phase5（仕訳下書き）・
--       Phase6（検算）の材料にする。1枚に複数店舗が混ざる請求書と、1店舗だけの請求書の両方に対応する。
-- 現構造: invoices は請求書1枚の合計(amount)だけ。明細行を持つ表は無い（invoice_attachments／auto_ocr jsonb に読み取り結果の断片のみ）。
-- 変更（追加のみ。既存の表・列・ポリシーは変更しない）:
--   invoice_lines（新規）: 請求書の明細行。明細名・品目・店舗表記・店舗コード・ブランド・数量・単価・金額・税区分(税率)・備考、
--                          店舗の解決先(resolved_store_id・resolved_by)はPhase4で埋める（今は空）。取れない項目はNULL。
--   invoices に subtotal_amount(税抜合計) / tax_amount(税額) / target_year_month(対象年月) / lines_check(検算結果jsonb) /
--             lines_extracted_at を追加（税込合計は既存の amount）。振込先は既存の auto_ocr（jsonb）に入っている。
--   automation_rule_settings に invoice_lines_ai（明細OCRのモデル名。paramsで切替）を追加
-- 既存データへの影響: なし。
-- migration: 本ファイル（何度流しても壊れない）。 rollback: drop table invoice_lines; alter table invoices drop column subtotal_amount, drop column tax_amount, drop column target_year_month, drop column lines_check, drop column lines_extracted_at;

create table if not exists public.invoice_lines (
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references public.invoices(id) on delete cascade,
  line_no int not null,
  description text,                -- 明細名
  item text,                       -- 品目
  store_text text,                 -- 請求書上の店舗表記（例: 鳥一代 本店）
  store_code text,                 -- 請求書上の店舗コード（例: 01）
  brand_text text,                 -- ブランド表記
  quantity numeric,
  unit_price numeric,
  amount numeric,                  -- 明細の金額（請求書に書かれている額。税抜の請求書では税抜）
  tax_rate int,                    -- 8 / 10 / 0（非課税）。行に書かれていなければNULL
  tax_amount numeric,
  note text,
  resolved_store_id uuid references public.stores(id) on delete set null,   -- Phase4で埋める
  resolved_by text check (resolved_by in ('rule','mapping','ai','human')),
  source text not null default 'ocr',
  created_at timestamptz not null default now(),
  unique (invoice_id, line_no)
);
create index if not exists invoice_lines_invoice_idx on public.invoice_lines (invoice_id);
alter table public.invoice_lines enable row level security;
drop policy if exists invoice_lines_all_inv on public.invoice_lines;
create policy invoice_lines_all_inv on public.invoice_lines for all using (invoice_can_access()) with check (invoice_can_access());

alter table public.invoices
  add column if not exists subtotal_amount numeric,
  add column if not exists tax_amount numeric,
  add column if not exists target_year_month date,
  add column if not exists lines_check jsonb,
  add column if not exists lines_extracted_at timestamptz;

insert into public.automation_rule_settings (key, label, description, enabled, action, params) values
  ('invoice_lines_ai', '請求書の明細OCR', '請求書PDFの明細行・税の内訳・対象年月を読み取る。モデル名はparamsで切替。', true, 'auto_candidate',
   '{"model":"claude-sonnet-5-5"}'::jsonb)
on conflict (key) do nothing;
