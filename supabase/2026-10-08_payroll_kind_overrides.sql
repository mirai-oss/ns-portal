-- 担当C: 給与仕訳の「区分（社員／アルバイト）」の月ごとの上書き
-- 事前報告様式（DB変更）:
-- 理由: ユーザー要望（2026-10-08）「区分は毎月自動で決まるようにし、一応プルダウンで選び直せるように。アルバイトだった人を社員に
--       できるように。管理システムで区分（役職）を変えたら自動で変わるように」。区分は既定で役職(users.role)から自動で決まるので、
--       上書きは「その月だけ」の例外として持つ（人ごとに永続させると、後で役職を変えても自動で変わらなくなるため）。
-- 現構造: 区分を保存する場所は無い（payroll_journal_assignments は人ごとの仕訳辞書(template_id)のみ）。
-- 変更（新規テーブルのみ・既存の表は変更しない）:
--   payroll_kind_overrides(user_id, year_month, kind 'employee'|'parttime', updated_by, updated_at)  主キー=(user_id, year_month)
--   RLSは他の給与仕訳テーブルと同じ invoice_can_access()
-- 既存データへの影響: なし。画面側は表が無い間も既定の「自動（役職から）」で動く。
-- migration: 本ファイル(何度流しても壊れない)。 rollback: drop table payroll_kind_overrides;

create table if not exists public.payroll_kind_overrides (
  user_id uuid not null references public.users(id) on delete cascade,
  year_month text not null,
  kind text not null check (kind in ('employee','parttime')),
  updated_by uuid references public.users(id),
  updated_at timestamptz not null default now(),
  primary key (user_id, year_month)
);
alter table public.payroll_kind_overrides enable row level security;
drop policy if exists pko_all on public.payroll_kind_overrides;
create policy pko_all on public.payroll_kind_overrides for all
  using (invoice_can_access()) with check (invoice_can_access());
