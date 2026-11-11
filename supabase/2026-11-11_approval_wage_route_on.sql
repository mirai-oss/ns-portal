-- 賃金の 2 段階承認（本部確認 → 社長の最終承認）を有効にする  ★実行は別途承認
--   前提: 2026-11-11_approval_base.sql を適用済み・nippo とポータルの画面を公開済み
--   実行前に: 承認待ちの賃金変更の申請が 0 件であること（残っていても、最初の段階から案件が付くだけで消えはしないが、混乱を避けるため 0 件で切り替える）
--   これで変わること: 賃金の変更申請は「本部確認 → 社長の最終承認」を通らないと確定しない。古い画面からの 1 段階の承認は DB が止める。社長本人を対象にした賃金の申請は受け付けない
--   これだけでは変わらないこと: 賃金の直接登録（申請を通らない登録）。直接登録を止めるのは wage_approval_required（別のフラグ・別途承認）
do $$
declare n int;
begin
  select count(*) into n from profile_change_requests where field = 'wage' and status = 'pending';
  if n > 0 then raise exception '承認待ちの賃金変更の申請が % 件あります。先に承認・却下・取り下げで 0 件にしてください', n; end if;
end $$;
update approval_routes set active = true where request_type = 'wage';
select request_type, active, updated_at from approval_routes where request_type = 'wage';
