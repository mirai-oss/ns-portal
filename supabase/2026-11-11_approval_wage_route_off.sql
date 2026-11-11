-- 賃金の 2 段階承認を無効に戻す（これまでどおりの 1 段階の承認に戻る）  ★実行は別途承認
--   表・履歴は消さない（案件と操作の履歴は残る）。進行中の案件があるときは止まる（本部確認まで済んだ申請が、1 段階で確定できてしまうため）
do $$
declare n int;
begin
  select count(*) into n from approval_cases where request_type = 'wage' and status in ('pending', 'returned');
  if n > 0 then raise exception '進行中の案件が % 件あります。先に 最終承認・却下・取り下げ で 0 件にしてください', n; end if;
end $$;
update approval_routes set active = false where request_type = 'wage';
select request_type, active, updated_at from approval_routes where request_type = 'wage';
