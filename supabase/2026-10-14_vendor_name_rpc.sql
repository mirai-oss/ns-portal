-- 2026-10-14 取引先の名前対応画面（設定タブ「🔗 取引先の名前対応」）用の登録口
-- 設計書: docs/設計書_取引先名の対応づけ_社内情報を正本に_2026-10-14.md
-- 前提: 2026-10-14_vendor_name_map.sql（kind列）と 2026-10-14_supplier_branches.sql（branch_id列）が適用済み。
-- 冪等。既存の register_vendor_alias(3引数)／set_vendor_alias_active は変更しない。

-- 名前（請求書／明細／通帳）を、取引先に追加する。支店を指定できる（任意）。
create or replace function public.register_vendor_name(
  p_vendor_id uuid, p_name text, p_kind text default 'invoice', p_branch_id uuid default null
) returns uuid language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid; v_other uuid; v_sup uuid; v_bsup uuid;
begin
  if not (store_master_can_edit() or invoice_can_access()) then raise exception '権限がありません'; end if;
  if nullif(btrim(p_name),'') is null then raise exception '名前を入力してください'; end if;
  if p_kind not in ('invoice','statement','bank') then raise exception '種別が正しくありません'; end if;
  select info_supplier_id into v_sup from public.vendors where id = p_vendor_id;
  if not found then raise exception '取引先が存在しません'; end if;
  if p_branch_id is not null then
    select supplier_id into v_bsup from info.supplier_branches where id = p_branch_id;
    if v_bsup is null then raise exception '支店が存在しません'; end if;
    if v_sup is distinct from v_bsup then raise exception 'この支店は、この取引先の支店ではありません'; end if;
  end if;
  select vendor_id into v_other from public.vendor_aliases
   where alias = btrim(p_name) and is_active and vendor_id <> p_vendor_id limit 1;
  if v_other is not null then raise exception 'この名前は既に別の取引先に登録されています'; end if;
  insert into public.vendor_aliases (vendor_id, alias, source, kind, branch_id, created_by)
  values (p_vendor_id, btrim(p_name), 'manual', p_kind, p_branch_id, auth.uid())
  on conflict (alias, source) do update
     set vendor_id = excluded.vendor_id, kind = excluded.kind, branch_id = excluded.branch_id, is_active = true
  returning id into v_id;
  return v_id;
end $$;
revoke all on function public.register_vendor_name(uuid,text,text,uuid) from public;
grant execute on function public.register_vendor_name(uuid,text,text,uuid) to authenticated;

-- 既にある名前の「用途」と「支店」を直す
create or replace function public.set_vendor_alias_meta(
  p_id uuid, p_kind text, p_branch_id uuid default null
) returns void language plpgsql security definer set search_path to 'public' as $$
declare v_vendor uuid; v_sup uuid; v_bsup uuid;
begin
  if not (store_master_can_edit() or invoice_can_access()) then raise exception '権限がありません'; end if;
  if p_kind not in ('invoice','statement','bank') then raise exception '種別が正しくありません'; end if;
  select vendor_id into v_vendor from public.vendor_aliases where id = p_id;
  if v_vendor is null then raise exception '名前が存在しません'; end if;
  if p_branch_id is not null then
    select info_supplier_id into v_sup from public.vendors where id = v_vendor;
    select supplier_id into v_bsup from info.supplier_branches where id = p_branch_id;
    if v_bsup is null then raise exception '支店が存在しません'; end if;
    if v_sup is distinct from v_bsup then raise exception 'この支店は、この取引先の支店ではありません'; end if;
  end if;
  update public.vendor_aliases set kind = p_kind, branch_id = p_branch_id where id = p_id;
end $$;
revoke all on function public.set_vendor_alias_meta(uuid,text,uuid) from public;
grant execute on function public.set_vendor_alias_meta(uuid,text,uuid) to authenticated;
