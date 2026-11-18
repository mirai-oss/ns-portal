-- 2026-11-18 担当B: 「求人応募通知（Slack）」の通知ルールを止める（社長指示: #採用-応募通知 の「Indeedから新しい応募…」は不要。
-- 応募ごとの『採用管理』の親投稿＋スレッドが本体なので、重複する route 通知だけを止める）。削除ではなく is_active=false（戻すときは true に）。
-- 【影響】lark_routes の該当 1 行だけ。ほかのルール（入社通知（Slack）・役員チームの日報・中山通知専用）は触らない
-- 【rollback】update lark_routes set is_active = true where name = '求人応募通知（Slack）';
do $$
declare n int;
begin
  update lark_routes set is_active = false where name = '求人応募通知（Slack）' and is_active;
  get diagnostics n = row_count;
  if n > 1 then raise exception '想定外: % 行が対象になりました（1 行のはず）。中止します', n; end if;
  raise notice '止めた行数: %（0 ならすでに止まっています）', n;
end $$;
