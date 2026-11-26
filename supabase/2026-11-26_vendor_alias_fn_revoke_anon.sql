-- 取引先の別名の登録・編集関数を、ログインなし(anon)から実行できないようにする（担当C・社長承認 2026-11-26）
-- authenticated / service_role の権限は変えない。
-- 戻し: grant execute on function public.register_vendor_name(uuid,text,text,uuid), public.set_vendor_alias_meta(uuid,text,uuid) to anon;
begin;
revoke execute on function public.register_vendor_name(uuid,text,text,uuid) from public, anon;
revoke execute on function public.set_vendor_alias_meta(uuid,text,uuid) from public, anon;
commit;
