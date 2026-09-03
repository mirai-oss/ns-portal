-- 仕訳辞書の拡張（会計・請求書処理の全面刷新 フェーズA-4・2026-09-03）
--
-- 既存のmf_journal_templates（「よく使う仕訳のプリセット」）に、判定条件（取引先・キーワード・
-- 金額条件・取得元）と連携先（PL科目・広告対象・精算書対象・支払方法）・自動化設定を追加する。
-- 既存行は全列nullのままでも今まで通り「プリセット選択」として機能する＝後方互換。
-- payroll_journal_drafts/payroll_journal_recordsのFK（template_id）には影響しない。
alter table mf_journal_templates add column if not exists vendor_id uuid references vendors(id);
alter table mf_journal_templates add column if not exists match_keywords text[];          -- 判定キーワード（件名・本文・OCR結果の部分一致）
alter table mf_journal_templates add column if not exists match_from_addresses text[];    -- 差出人メールアドレス（完全/部分一致）
alter table mf_journal_templates add column if not exists target_corporation_id uuid references corporations(id);
alter table mf_journal_templates add column if not exists target_store_id uuid references stores(id);
alter table mf_journal_templates add column if not exists amount_min numeric;
alter table mf_journal_templates add column if not exists amount_max numeric;
alter table mf_journal_templates add column if not exists source_filter text[];           -- 取得元を絞る場合（mail/upload等）
alter table mf_journal_templates add column if not exists pl_account text;                -- PL科目（表示用ラベル）
alter table mf_journal_templates add column if not exists ad_target boolean not null default false;
alter table mf_journal_templates add column if not exists settlement_target boolean not null default false;
alter table mf_journal_templates add column if not exists payment_method text not null default 'bank_transfer' check (payment_method in ('bank_transfer','cash'));
alter table mf_journal_templates add column if not exists auto_apply boolean not null default false;         -- 自動処理候補にしてよいか
alter table mf_journal_templates add column if not exists require_human_review boolean not null default true; -- 人間確認必須か
alter table mf_journal_templates add column if not exists priority int not null default 100; -- 複数ルールが同時マッチしたときの優先順位（小さいほど優先）
create index if not exists mft_vendor_idx on mf_journal_templates(vendor_id);
