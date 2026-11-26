-- =====================================================================
-- 店舗・法人の正本まわりの関数から「ログインなし(anon)」の実行権限を外す（担当F・2026-11-26・ユーザー承認）
--
-- 【事前報告】
-- 理由: これらの関数はログインした人（と管理用の処理）だけが使う設計だったが、Supabase の既定の権限付与で
--       anon にも実行権限が付いていた（作成時の「revoke ... from public」だけでは anon の分は外れない）。
-- 変更: 下の18関数の EXECUTE を anon（と PUBLIC）から外すだけ。authenticated / service_role の権限・関数の中身・
--       表・データは一切変えない。
-- 影響: 利用元はログイン済みの画面（authenticated）と管理用の鍵（service_role）、およびDB内の definer 関数だけ
--       （全リポジトリの最新mainを確認）。RLSポリシー・ビューからの参照なし。
-- 注意: 今後これらの関数を drop して作り直すと権限が元に戻るので、このファイルを続けて実行する。
--       新しい関数を作るときは「revoke execute on function ... from public, anon;」まで書く。
-- 冪等。 rollback: grant execute on function public.<関数> to anon; （通常は戻さない）
-- =====================================================================
revoke execute on function public.resolve_store(text,text,text,text,text,boolean,date) from public, anon;
revoke execute on function public.smv2_pick_mapping(text,text,text,uuid,date) from public, anon;
revoke execute on function public.kd_report_unresolved_name(text,text,text,jsonb) from public, anon;
revoke execute on function public.kd_resolve_unresolved_name(uuid) from public, anon;
revoke execute on function public.store_master_can_edit() from public, anon;
revoke execute on function public.register_store_mapping(text,text,text,text,uuid,uuid) from public, anon;
revoke execute on function public.register_vendor_alias(uuid,text,text) from public, anon;
revoke execute on function public.set_vendor_alias_active(uuid,boolean) from public, anon;
revoke execute on function public.smv2_update_corporation(uuid,text,text,boolean) from public, anon;
revoke execute on function public.smv2_add_corporation_alias(uuid,text,text) from public, anon;
revoke execute on function public.smv2_set_corporation_alias_active(uuid,boolean) from public, anon;
revoke execute on function public.smv2_update_store(uuid,text,text) from public, anon;
revoke execute on function public.smv2_add_brand(text,text) from public, anon;
revoke execute on function public.smv2_set_store_brands(uuid,uuid[]) from public, anon;
revoke execute on function public.smv2_add_operation_relation(uuid,text,text,uuid,text,uuid,text,uuid,date,integer,boolean,text) from public, anon;
revoke execute on function public.smv2_end_operation_relation(uuid,date) from public, anon;
revoke execute on function public.smv2_correct_operation_relation(uuid,date,integer,boolean,text) from public, anon;
revoke execute on function public.smv2_set_mapping_active(uuid,boolean) from public, anon;
