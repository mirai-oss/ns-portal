-- 担当C: 給与仕訳の全自動化 §4「法人×区分（社員/アルバイト）の自動パターン」
-- 設計の正: docs/設計書_給与仕訳の全自動化_2026-10-06.md §4・§9（Q1=a）
--
-- 【事前報告様式（DB変更）】
-- 理由: 給与仕訳のテンプレート（仕訳辞書）を人ごとに手で割り当てる運用をやめ、「法人×区分（社員/アルバイト）」で
--       自動に割り当てたい（人ごとの手動割当は例外の上書きとして残す）。
-- 現構造: mf_journal_templates に給与用の区分・法人を持つ列が無い（target_corporation_id は請求書の自動適用用で意味が違うため流用しない）。
-- 変更（既存の列・行・RLS・APIは不変。追加のみ・null許容）:
--   mf_journal_templates.payroll_kind            text   — 'employee'（社員）/'parttime'（アルバイト）。null=自動割当の対象外
--   mf_journal_templates.payroll_corporation_id  uuid   — 自動割当の対象法人（corporations.id）。null=法人を問わず
-- 既存データへの影響: なし（新規列は全行null＝従来どおり人ごとの手動割当だけで動く）。
-- migration: 本ファイル(何度流しても壊れない)。 rollback: alter table mf_journal_templates drop column payroll_kind, drop column payroll_corporation_id;

alter table public.mf_journal_templates add column if not exists payroll_kind text;
alter table public.mf_journal_templates add column if not exists payroll_corporation_id uuid references public.corporations(id) on delete set null;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'mf_journal_templates_payroll_kind_check') then
    alter table public.mf_journal_templates add constraint mf_journal_templates_payroll_kind_check
      check (payroll_kind is null or payroll_kind in ('employee','parttime'));
  end if;
end $$;

comment on column public.mf_journal_templates.payroll_kind is '給与仕訳の自動割当: employee=社員 / parttime=アルバイト（users.role=ALがアルバイト）';
comment on column public.mf_journal_templates.payroll_corporation_id is '給与仕訳の自動割当の対象法人（所属店舗の法人）。nullは法人を問わない';
