-- 【事前報告様式（DB変更）】担当C・2026-10-15「売上入金メールの自動処理を Thumz（龍馬池袋）の業務委託精算書にも広げる」
-- 理由: Thumz（運営委託先）から毎月届く「業務委託精算書」（1通に精算書・御請求書・立替経費の請求書が入っている）は、ユーザーが
--       1つの複合仕訳（売掛金／売上高／支払手数料）でMFに入力している（取引No703・8/31・ユーザーのMF画面で確認済み）。同じ流れで自動化する。
-- 変更（追加のみ・既存データは変更なし）:
--   receivable_property_rules に列を追加: layout（by_tenant=入居者×税区分ごと／total=収入・支出の合計1行ずつ）, date_basis（remit_date=送金日／month_end=対象月末）,
--     remark_recv_tpl / remark_rev_tpl / remark_fee_tpl（摘要の雛形。{label}=摘要名 {m}=「8月分」）
--   Thumz（龍馬池袋）の型を1件追加／取引先「株式会社Thumz」を追加（無ければ）／メール分類ルール thumz.co.jp → 売上入金（優先度8＝件名の「請求書」ルールより先）
-- rollback: 追加した列・行を削除（drop column / delete）。
alter table public.receivable_property_rules
  add column if not exists layout text not null default 'by_tenant',
  add column if not exists date_basis text not null default 'remit_date',
  add column if not exists remark_recv_tpl text,
  add column if not exists remark_rev_tpl text,
  add column if not exists remark_fee_tpl text;

insert into public.receivable_property_rules (vendor_key, property_pattern, property_label, receivable_sub, revenue_sub, fee_sub, department_name, remark_label, corporation_id, layout, date_basis, remark_recv_tpl, remark_rev_tpl, remark_fee_tpl, note)
select '株式会社Thumz','龍馬池袋','龍馬池袋（Thumz業務委託）','【不動産】池袋龍馬','【不動産】池袋龍馬','ゼンランド','池袋/龍馬','(株)サムライズ','a8754755-622d-4954-b34c-40ee9442bd27'::uuid,
  'total','month_end','{m}　業務委託費支払額　{label}','{m}　{label}','手数料　{m}　{label}','MF取引No703（2026-08・N-Style）の入力どおり。経費の補助科目は実際の入力に合わせて「ゼンランド」'
where not exists (select 1 from public.receivable_property_rules where vendor_key='株式会社Thumz' and property_pattern='龍馬池袋' and is_active);

insert into public.vendors (name, name_aliases, email_domains, default_corporation_id, is_active)
select '株式会社Thumz', array['Thumz','サムズ','(株)サムライズ'], array['thumz.co.jp'], 'a8754755-622d-4954-b34c-40ee9442bd27'::uuid, true
where not exists (select 1 from public.vendors where is_active and name='株式会社Thumz');

insert into public.invoice_mail_rules (rule_type, pattern, needs_attachment, category, priority, note)
select 'from_domain','thumz.co.jp', true, 'sales_deposit', 8, 'Thumz（運営委託先）の業務委託精算書＝売上入金（件名に「請求書」を含むが売上の精算書）'
where not exists (select 1 from public.invoice_mail_rules where pattern='thumz.co.jp');
