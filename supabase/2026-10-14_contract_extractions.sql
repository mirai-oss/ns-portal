-- 2026-10-14 契約書AI読み取りの結果保存（info.contract_extractions）
-- 設計書: docs/設計書_契約書の自動読み取り_2026-10-14.md
-- 目的: 契約書（info.documents）をAIで読み取った結果を保存し、同じ契約書での二重の課金・読み取りを避ける。
--       何を根拠にどの値を反映したかの記録にもなる。properties は直接変更しない（画面で人が確認して保存する）。
-- 冪等。既存のデータは変更しない。

create table if not exists info.contract_extractions (
  id             uuid primary key default gen_random_uuid(),
  document_id    uuid not null references info.documents(id) on delete cascade,
  corporation_id uuid references info.corporations(id),
  result         jsonb not null,            -- { is_lease_contract, fields, evidence, warnings, needs_review }
  model          text,
  created_by     uuid,
  created_at     timestamptz not null default now()
);
create index if not exists contract_extractions_doc_idx on info.contract_extractions (document_id, created_at desc);

comment on table info.contract_extractions is '契約書のAI読み取り結果（Edge Function contract-extract が保存）。物件・契約フォームへの自動入力の元データ。';

alter table info.contract_extractions enable row level security;
drop policy if exists select_contract_extractions on info.contract_extractions;
create policy select_contract_extractions on info.contract_extractions
  for select using (auth.uid() is not null and info.has_edit_perm('property'));

grant select on info.contract_extractions to authenticated;
grant select, insert, update, delete on info.contract_extractions to service_role;
