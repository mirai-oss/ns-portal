-- 2026-08-29 担当B（nippo）続き
-- sf_payroll_allocationsに(user_id,store_id,period_key,kind)のunique制約を追加。
-- 管理画面から金額を編集するたびに新しい行を増やすのではなく、同じ内訳（例:この人のこの店舗の
-- この半月の「基本給」）は1行を上書き保存できるようにする（upsertのonConflictキーとして使う）。
alter table sf_payroll_allocations
  add constraint sf_payroll_allocations_unique unique (user_id, store_id, period_key, kind);
