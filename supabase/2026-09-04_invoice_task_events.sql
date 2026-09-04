-- 本部タスクevent_type→hq_task_step_id マッピングの完成（2026-09-04・指示書②③④⑤）
-- 6イベント（invoice_created/invoice_review_completed/mf_journal_created/payment_ready/
-- payment_completed/payment_verified）を扱える構造にする。すべてのinvoiceが6工程を持つ
-- 必要はなく、明示的にマッピングされたイベントだけが対象（マッピング無し＝何もしない）。
--
-- 設計：
-- - mf_journal_created / payment_completed は既存列（invoices.linked_hq_step_id /
--   linked_hq_step_id_payment）をそのままマッピング先として使う（後方互換・UI無改修）
-- - 残り4イベント（invoice_created/invoice_review_completed/payment_ready/payment_verified）は
--   新規列 invoices.event_task_links（jsonb、{event_type: hq_task_step_id}）をマッピング先とする
-- - invoice_task_events：発火ログ兼・冪等性の担保。(invoice_id, event_type)にunique制約を持たせ、
--   一度処理された組み合わせは二度と処理しない（invoice_id×event_type×hq_task_step_idの
--   再実行安全性を、テーブルのunique制約というDBレベルの保証で実現する）

alter table invoices add column if not exists event_task_links jsonb not null default '{}'::jsonb;

create table if not exists invoice_task_events (
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references invoices(id) on delete cascade,
  event_type text not null check (event_type in (
    'invoice_created','invoice_review_completed','mf_journal_created',
    'payment_ready','payment_completed','payment_verified'
  )),
  hq_task_step_id uuid references hq_task_steps(id),
  hq_task_id uuid references hq_tasks(id),
  result text not null check (result in ('completed','skipped_no_mapping','skipped_already_completed','error')),
  detail text,
  triggered_by uuid references users(id),
  created_at timestamptz not null default now(),
  unique (invoice_id, event_type)
);
create index if not exists invoice_task_events_invoice_idx on invoice_task_events (invoice_id, created_at desc);

alter table invoice_task_events enable row level security;
drop policy if exists inv_task_events_read on invoice_task_events;
create policy inv_task_events_read on invoice_task_events for select using (invoice_can_access());
-- insertは直接policyを設けない＝invoice_fire_task_event RPC経由のみ（監査ログとしての一貫性を保証）

-- イベント発火RPC。同じ(invoice_id,event_type)が既に処理済みなら、その結果をそのまま返すだけで
-- 何もしない（真の冪等性＝再実行してもhq_task_stepsに影響しない）。マッピングが無ければ
-- skipped_no_mappingとして記録するだけ（勝手に工程を推測して完了させたりはしない）
create or replace function invoice_fire_task_event(p_invoice_id uuid, p_event_type text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_inv invoices;
  v_step_id uuid;
  v_task_id uuid;
  v_existing invoice_task_events;
  v_result text;
  v_detail text;
  v_step_completed_now boolean := false;
begin
  if not invoice_can_access() then raise exception '権限がありません'; end if;

  select * into v_existing from invoice_task_events where invoice_id = p_invoice_id and event_type = p_event_type;
  if found then
    return jsonb_build_object('success', true, 'already_processed', true, 'result', v_existing.result, 'hq_task_step_id', v_existing.hq_task_step_id);
  end if;

  select * into v_inv from invoices where id = p_invoice_id;
  if v_inv.id is null then raise exception '対象が見つかりません'; end if;

  if p_event_type = 'mf_journal_created' then
    v_step_id := v_inv.linked_hq_step_id;
  elsif p_event_type = 'payment_completed' then
    v_step_id := v_inv.linked_hq_step_id_payment;
  else
    v_step_id := nullif(v_inv.event_task_links ->> p_event_type, '')::uuid;
  end if;

  if v_step_id is null then
    v_result := 'skipped_no_mapping';
    v_detail := 'この請求書にはこのイベントに対する本部タスク工程の紐付けがありません';
  else
    select task_id into v_task_id from hq_task_steps where id = v_step_id;
    update hq_task_steps set completed_at = now() where id = v_step_id and completed_at is null;
    get diagnostics v_step_completed_now = row_count;
    if v_step_completed_now then
      v_result := 'completed';
      v_detail := null;
    else
      v_result := 'skipped_already_completed';
      v_detail := 'この工程は既に完了済みでした（他の操作で先に完了した可能性があります）';
    end if;
  end if;

  insert into invoice_task_events(invoice_id, event_type, hq_task_step_id, hq_task_id, result, detail, triggered_by)
  values (p_invoice_id, p_event_type, v_step_id, v_task_id, v_result, v_detail, auth.uid())
  on conflict (invoice_id, event_type) do nothing;

  return jsonb_build_object('success', true, 'already_processed', false, 'result', v_result, 'hq_task_step_id', v_step_id);
end;
$$;

-- event_task_links（4イベント分）の設定RPC。呼び出し元の検索UIから使う（手動タスクリンク
-- ボックスと同じ検索→選択パターン）。null指定で解除できる
create or replace function invoice_set_event_task_link(p_invoice_id uuid, p_event_type text, p_hq_task_step_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not invoice_can_access() then raise exception '権限がありません'; end if;
  if p_event_type not in ('invoice_created','invoice_review_completed','payment_ready','payment_verified') then
    raise exception 'このイベントは専用の列（linked_hq_step_id等）を使うため、このRPCでは設定できません: %', p_event_type;
  end if;
  update invoices
    set event_task_links = case
      when p_hq_task_step_id is null then event_task_links - p_event_type
      else jsonb_set(event_task_links, array[p_event_type], to_jsonb(p_hq_task_step_id::text))
    end
  where id = p_invoice_id;
end;
$$;
