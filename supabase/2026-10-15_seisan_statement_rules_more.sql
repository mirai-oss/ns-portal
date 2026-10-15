-- 【事前報告様式（DB変更）】担当C・2026-10-15「N-Style側の業務委託精算書の仕訳の型を、秋葉原 肉寿司・じんべぇ川崎・じんべぇ新横浜・エース本厚木にも広げる」
-- 理由: ユーザーのMF画面（N-Style・2026-08・取引No743/745）で、これらの店舗の運営委託費の仕訳を確認した。
--       743: 運営委託費/肉寿司/秋葉原（部門 肉寿司/秋葉原・課仕10%）／未払金/株）FAM Dining（対象外）・摘要「8月/秋葉原肉寿司/運営委託費」・8/31
--       745: じんべぇ川崎・じんべぇ新横浜・エース本厚木の3店舗を1つの複合仕訳（未払金/株）MostFun 25,286,002）・摘要「運営委託費（MostFun）」・8/31
--       ユーザー回答: 「同じ法人はまとめて仕訳になっているが、1店舗ずつの仕訳でも問題なし」→ 店舗ごとの下書きにする（まとめない）。
-- 変更（追加のみ）: seisan_statement_rules に sales_enabled 列（false=トーホー側の売上の下書きは作らない。これらの店舗は売上側の型が未確認のため）／4店舗の型を追加。
-- rollback: 追加した4行と sales_enabled 列を削除。
alter table public.seisan_statement_rules add column if not exists sales_enabled boolean not null default true;

insert into public.seisan_statement_rules (store_patterns, store_label, sales_enabled, sales_corporation_id, exp_corporation_id, exp_payee_vendor, exp_sub, exp_department, exp_payable_sub, exp_remark_tpl, note)
select * from (values
  (array['秋葉原肉寿司','肉寿司'], '秋葉原 肉寿司', false, null::uuid, 'a8754755-622d-4954-b34c-40ee9442bd27'::uuid, 'FAM Dining', '肉寿司/秋葉原', '肉寿司/秋葉原', '株）FAM Dining', '{mo}/秋葉原肉寿司/運営委託費', 'MF取引No743(2026-08・8/31)'),
  (array['じんべぇ川崎','じんべえ川崎'], 'じんべぇ 川崎', false, null::uuid, 'a8754755-622d-4954-b34c-40ee9442bd27'::uuid, 'Mostfun', 'じんべぇ/川崎', 'じんべぇ/川崎', '株）MostFun', '運営委託費（MostFun）', 'MF取引No745(2026-08・8/31)の1行（実際は3店舗まとめた複合仕訳。店舗ごとに分ける）'),
  (array['じんべぇ新横浜','じんべえ新横浜'], 'じんべぇ 新横浜', false, null::uuid, 'a8754755-622d-4954-b34c-40ee9442bd27'::uuid, 'Mostfun', 'じんべぇ/新横浜', 'じんべぇ/新横浜', '株）MostFun', '運営委託費（MostFun）', 'MF取引No745の1行'),
  (array['エース本厚木'], 'エース 本厚木', false, null::uuid, 'a8754755-622d-4954-b34c-40ee9442bd27'::uuid, 'Mostfun', 'エース/本厚木', 'エース/本厚木', '株）MostFun', '運営委託費（MostFun）', 'MF取引No745の1行')
) as v(store_patterns, store_label, sales_enabled, sales_corporation_id, exp_corporation_id, exp_payee_vendor, exp_sub, exp_department, exp_payable_sub, exp_remark_tpl, note)
where not exists (select 1 from public.seisan_statement_rules r where r.store_label = v.store_label);
