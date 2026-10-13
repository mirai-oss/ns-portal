-- 担当C: 請求書メール自動処理 Phase6「検算・異常判定・処理の段階」（実装指示書 Phase6／設計書§10・§11）
--
-- 【事前報告様式（DB変更）】
-- 理由: 自動で作った請求書の下書きが「承認待ちに進めるか／どこで止まっているか」を段階で持ち、検算・重複・前月比・
--       振込先の一致などの判定結果を残す。自動処理中は手動の仕訳作成と二重にならないようにし、人が手動に切り替えた後は自動が書かない。
-- 現構造: invoices に処理の段階・止まっている理由・検算結果・自動/手動の別を持つ列は無い（invoice_status/ai_match_status/payment_status は並存のまま触らない）。
-- 変更（追加のみ。既存列の改名・意味変更なし）:
--   invoices に current_stage / blocked_reason / stage_updated_at / checks(jsonb) / auto_mode / manual_reason / manual_switched_by / manual_switched_at を追加
--     current_stage: received→parsed→mapping→journal_draft→ready_for_approval→approved→payment_waiting→paid→completed / error（既存の請求書は NULL のまま）
--     auto_mode: 'auto'(既定)／'manual'（人が「手動に切り替え」した。理由必須。以後、自動処理はこの請求書に書かない）
--   invoice_switch_to_manual(p_invoice_id, p_reason) … 手動に切り替える関数（理由必須・履歴を invoice_audit_logs に残す）
--   automation_rule_settings に invoice_exception_tasks（検算で止まった請求書を本部タスクの例外として発行するか。既定=OFF）を追加
-- 既存データへの影響: なし。 migration: 何度流しても壊れない。
-- rollback: drop function invoice_switch_to_manual(uuid,text); alter table invoices drop column current_stage, drop column blocked_reason, drop column stage_updated_at, drop column checks, drop column auto_mode, drop column manual_reason, drop column manual_switched_by, drop column manual_switched_at;

alter table public.invoices
  add column if not exists current_stage text check (current_stage in ('received','parsed','mapping','journal_draft','ready_for_approval','approved','payment_waiting','paid','completed','error')),
  add column if not exists blocked_reason text,
  add column if not exists stage_updated_at timestamptz,
  add column if not exists checks jsonb,
  add column if not exists auto_mode text not null default 'auto' check (auto_mode in ('auto','manual')),
  add column if not exists manual_reason text,
  add column if not exists manual_switched_by uuid,
  add column if not exists manual_switched_at timestamptz;
create index if not exists invoices_current_stage_idx on public.invoices (current_stage) where current_stage is not null;

create or replace function public.invoice_switch_to_manual(p_invoice_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_email uuid;
begin
  if not invoice_can_access() then raise exception '権限がありません'; end if;
  if p_reason is null or btrim(p_reason) = '' then raise exception '手動に切り替える理由を入力してください'; end if;
  update public.invoices set auto_mode='manual', manual_reason=btrim(p_reason), manual_switched_by=auth.uid(), manual_switched_at=now(), updated_at=now()
    where id = p_invoice_id returning email_id into v_email;
  if not found then raise exception '請求書が見つかりません'; end if;
  insert into public.invoice_audit_logs(entity_type, entity_id, action, user_id, note)
    values ('invoice_email', coalesce(v_email, p_invoice_id), 'switched_to_manual', auth.uid(), '自動処理から手動に切り替え: ' || btrim(p_reason));
  return jsonb_build_object('success', true);
end $$;

insert into public.automation_rule_settings (key, label, description, enabled, action, params) values
  ('invoice_exception_tasks', '請求書の例外を本部タスクへ', '検算・判定で止まった自動処理の請求書を、本部タスクの例外（理由別・べき等）として発行する。既定はOFF。', false, 'require_review', '{}'::jsonb)
on conflict (key) do nothing;
