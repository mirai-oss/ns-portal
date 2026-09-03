-- 統合請求書一覧・自動判定・振込一覧のための列追加（会計・請求書処理の全面刷新 フェーズA-6・2026-09-03）
alter table invoices add column if not exists intake_source text check (intake_source in ('mail','paper','pdf','infomart','api','manual'));
alter table invoices add column if not exists corporation_id uuid references corporations(id);
alter table invoices add column if not exists store_id uuid references stores(id);
create index if not exists invoices_store_id_idx on invoices(store_id);
alter table invoices add column if not exists vendor_id uuid references vendors(id);
alter table invoices add column if not exists ai_match_status text check (ai_match_status in ('auto','review','error'));
alter table invoices add column if not exists ai_match_reasons text[];
alter table invoices add column if not exists ai_confidence jsonb;
alter table invoices add column if not exists ai_matched_rule_id uuid references mf_journal_templates(id);
alter table invoices add column if not exists bank_account_change_detected boolean not null default false;
alter table invoices add column if not exists payment_status text not null default 'not_ready' check (payment_status in ('not_ready','wait','csv','processing','paid','blocked'));
alter table invoices add column if not exists paid_at timestamptz;
alter table invoices add column if not exists paid_by uuid references users(id);
alter table invoices add column if not exists transfer_csv_exported_at timestamptz;
create index if not exists invoices_payment_status_idx on invoices(payment_status);
create index if not exists invoices_ai_match_status_idx on invoices(ai_match_status);

-- 法人・店舗・部門マッピング画面用: 店舗↔マネーフォワード部門名のマッピング
-- （storesテーブル自体はns-info-system管轄のため列追加のみ。既存の店舗名あいまい一致
-- =plfeeFindStoreByNameは、この列が未設定の店舗ではフォールバックとして引き続き使う）
alter table stores add column if not exists mf_department_name text;
