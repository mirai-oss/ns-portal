-- 担当C: 給与仕訳の「仕訳辞書パターン」選択を「区分（社員／アルバイト）」の選択へ
-- 事前報告様式（DB変更）:
-- 理由: ユーザー要望（2026-10-08）「仕訳辞書を選ぶのをやめ、社員かアルバイトだけを選べば、その区分の仕訳が自動で組まれるように」。
--       区分は既定で役職（users.role。AL=アルバイト・それ以外=社員）から自動で決まり、人ごとに区分を上書きしたいときだけ保存する。
-- 現構造: payroll_journal_assignments(user_id pk, tenant_id, template_id, updated_by, updated_at)。人ごとに仕訳辞書(template_id)を覚える表。
-- 変更（追加のみ・既存の列/行/ポリシーは不変）:
--   payroll_journal_assignments.kind text（'employee'=社員 / 'parttime'=アルバイト / null=役職から自動）
-- 既存データへの影響: なし（新列は全行null＝従来どおり。既存の template_id も消さない）。
-- migration: 本ファイル(何度流しても壊れない)。 rollback: alter table payroll_journal_assignments drop column kind;

alter table public.payroll_journal_assignments add column if not exists kind text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'payroll_journal_assignments_kind_check') then
    alter table public.payroll_journal_assignments add constraint payroll_journal_assignments_kind_check
      check (kind is null or kind in ('employee','parttime'));
  end if;
end $$;
comment on column public.payroll_journal_assignments.kind is '給与仕訳の区分の上書き: employee=社員 / parttime=アルバイト / null=役職(users.role)から自動';
