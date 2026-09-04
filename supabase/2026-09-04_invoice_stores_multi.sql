-- 請求書「対象店舗」の複数選択対応（2026-09-04・指示書「請求書『対象店舗』複数選択対応」）
--
-- 【Source of Truth】invoice_stores（中間テーブル）を正データとする。
-- 【既存 invoices.store_id との互換】いきなり削除・型変更しない（指示書§6）。
--   - invoice_storesがちょうど1件のときだけ、その値をstore_idへミラーする
--   - 0件または2件以上のときはstore_id=null（「単一値では表現できない」ことを既存コードにも
--     正しく伝える。既存の「店舗未設定」判定コードが誤動作しないようにするため）
--   - 既存のPL反映・広告費反映・給与仕訳等、store_idを直接参照する既存機能は今回変更しない
--     （指示書§13-14「金額配賦は今回やらない」「MF/PLの既存処理を壊さない」に対応）
create table if not exists invoice_stores (
  invoice_id uuid not null references invoices(id) on delete cascade,
  store_id uuid not null references stores(id),
  created_at timestamptz not null default now(),
  created_by uuid references users(id),
  primary key (invoice_id, store_id)
);
create index if not exists invoice_stores_store_idx on invoice_stores (store_id);

alter table invoice_stores enable row level security;
drop policy if exists inv_stores_read on invoice_stores;
create policy inv_stores_read on invoice_stores for select using (invoice_can_access());
drop policy if exists inv_stores_write on invoice_stores;
create policy inv_stores_write on invoice_stores for all using (invoice_can_access()) with check (invoice_can_access());

-- 対象店舗をまとめて保存するRPC（指示書§7・§16：invoice本体とinvoice_storesの保存を
-- 1トランザクションにまとめ、途中失敗で「invoiceだけ更新・店舗だけ消えた」を防ぐ。
-- store_idのミラーリングもここで一括して行う）
create or replace function invoice_set_stores(p_invoice_id uuid, p_store_ids uuid[])
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_count int;
  v_single uuid;
  v_corp_id uuid;
  v_bad_count int;
begin
  if not invoice_can_access() then raise exception '権限がありません'; end if;
  if not exists(select 1 from invoices where id = p_invoice_id) then raise exception '対象が見つかりません'; end if;

  select corporation_id into v_corp_id from invoices where id = p_invoice_id;
  -- 対象法人と異なる法人の店舗が混じっていないか確認（指示書§15。法人未設定invoiceは
  -- 店舗側の法人チェックをスキップ＝先に法人だけでも保存できるようにするため）
  if v_corp_id is not null and p_store_ids is not null and array_length(p_store_ids,1) > 0 then
    select count(*) into v_bad_count from stores where id = any(p_store_ids) and corporation_id is distinct from v_corp_id;
    if v_bad_count > 0 then raise exception '対象法人に属さない店舗が含まれています'; end if;
  end if;

  delete from invoice_stores where invoice_id = p_invoice_id;
  if p_store_ids is not null and array_length(p_store_ids,1) > 0 then
    insert into invoice_stores(invoice_id, store_id, created_by)
    select p_invoice_id, s, auth.uid() from unnest(p_store_ids) as s
    on conflict do nothing;
  end if;

  select count(*) into v_count from invoice_stores where invoice_id = p_invoice_id;
  if v_count = 1 then
    select store_id into v_single from invoice_stores where invoice_id = p_invoice_id;
  else
    v_single := null;
  end if;
  update invoices set store_id = v_single, updated_at = now() where id = p_invoice_id;

  return jsonb_build_object('success', true, 'store_count', v_count);
end;
$$;

-- 既存データの移行：既にstore_idが入っているinvoiceについて、invoice_storesへ1行だけ複製する
-- （Source of Truthをinvoice_storesへ寄せるための初期データ投入。store_id自体は消さない）
insert into invoice_stores(invoice_id, store_id)
select i.id, i.store_id from invoices i
where i.store_id is not null
on conflict do nothing;
