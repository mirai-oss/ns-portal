-- =============================================================
-- 勤怠修正申請の一次承認者を設定する（8 店・3 人。社長の指示どおり）。2026-11-15 下書き・★ 本番未適用 ★
--   前提: 2026-12-10_attendance_request_two_stage.sql が適用済み。★ 取引内テスト（test_stage2.sql）は、この SQL の前に流すこと（テストは一次承認者の表が空の前提）。
--   人も店舗も ID で指定する。流す前に、ID の人が「役割 TEAM・在職・Slack 連携あり・指示の姓」、ID の店舗が「指示の店名」であることを確かめ、
--   1 つでも合わなければ例外で止まる（＝何も設定しない。推測で紐付けない）。指示に無い 4 店は設定しない（＝申請は「確認待ち」）。
--   設定は関数 sf_attendance_first_approver_set を通す（変更の履歴が残る。操作者＝社長）。もう一度流しても同じ結果になる。
--   戻すとき: select sf_attendance_first_approver_set('<店舗 id>', null, '<社長の id>', '未設定に戻す'); を店舗ごとに（service_role で）。
-- =============================================================
do $$
declare
  c_sakamoto constant uuid := '8e989a75-0234-4611-af72-3c71f7c4f170';
  c_sato     constant uuid := 'f47e43d5-2fef-4df8-9f7e-4b52cb56e0c6';
  c_nabekura constant uuid := '6ce6d3da-e910-4017-b924-7b5e293900b4';
  v_ceo uuid; v_n int; v_bad text; v_res jsonb; q record;
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  select count(*) into v_n from users where role = 'CEO' and is_active;
  if v_n <> 1 then raise exception '社長（役割 CEO・在職）が 1 人に決まりません（% 人）。設定しません', v_n; end if;
  select id into v_ceo from users where role = 'CEO' and is_active;

  create temp table _fa_plan (store_id uuid primary key, store_name text not null, approver uuid not null, surname text not null) on commit drop;
  insert into _fa_plan values
    ('bee9f74a-2079-4cf1-87d6-eb758e193d33', '鳥一代 本店',   c_sakamoto, '坂本'),
    ('eecb30b6-3687-407c-8e11-54d9a6cccd18', '鳥一代 はなれ', c_sakamoto, '坂本'),
    ('3d3a49e6-05cb-4cd5-b304-02842aa32139', '芝の鳥一代',    c_sakamoto, '坂本'),
    ('496ba827-b4b7-4c0c-969d-187bd78b4b81', '鳥一代 新橋',   c_sakamoto, '坂本'),
    ('feeaa89e-800a-4c77-932e-e7f5e82b7671', '鳥一代 恵比寿', c_sato,     '佐藤'),
    ('c3e8e08a-4816-43b6-aee6-8ee72cb912f4', '鶏武者 川崎店', c_sato,     '佐藤'),
    ('142a47dd-a64f-45b0-b059-61b70beba01b', '鶏武者 新横浜', c_nabekura, '鍋倉'),
    ('1cbb4844-8583-494d-bbbc-d4f68a4a13fb', '黒霧屋 新横浜', c_nabekura, '鍋倉');

  -- 確かめ: 店舗（ID と店名・有効）／人（ID・役割 TEAM・在職・Slack 連携あり・指示の姓）。合わない行があれば、全部やめる
  select string_agg(p.store_name, '、') into v_bad
    from _fa_plan p left join stores s on s.id = p.store_id and s.is_active and s.name = p.store_name
   where s.id is null;
  if v_bad is not null then raise exception '店舗の ID と店名が合いません: %。設定しません', v_bad; end if;
  select string_agg(distinct p.surname, '、') into v_bad
    from _fa_plan p
    left join users u on u.id = p.approver and u.is_active and u.deactivated_at is null and u.role = 'TEAM' and u.name like '%' || p.surname || '%'
    left join user_slack k on k.user_id = u.id
   where u.id is null or k.user_id is null;
  if v_bad is not null then raise exception '一次承認者の ID が、指示の人（役割 TEAM・在職・Slack 連携あり・姓）と合いません: %。設定しません', v_bad; end if;

  for q in select store_id, store_name, approver from _fa_plan order by store_name loop
    v_res := sf_attendance_first_approver_set(q.store_id, q.approver, v_ceo, '社長の指示（2026-11-15）');
    if coalesce((v_res ->> 'ok')::boolean, false) is not true then raise exception '設定できませんでした（%）: %', q.store_name, v_res; end if;
  end loop;
  select count(*) into v_n from sf_attendance_first_approvers a join _fa_plan p on p.store_id = a.store_id and p.approver = a.approver_user_id;
  if v_n <> 8 then raise exception '設定の結果が 8 店になっていません（% 店）', v_n; end if;
  raise notice '一次承認者を 8 店に設定しました（指示に無い店舗は未設定のまま＝確認待ち）';
end $$;
