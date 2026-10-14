-- 2026-10-14 取引先の「名前の対応表」（段階1）
-- 設計書: docs/設計書_取引先名の対応づけ_社内情報を正本に_2026-10-14.md
--
-- 目的: 社内情報（info.suppliers）を取引先の正本とし、1社に「請求書での名前／明細での名前／MFでの名前／通帳の名前」を
--       ぶら下げて見られるようにする。名前の置き場所は既存のまま（vendor_aliases・vendor_line_rules・vendors）で、
--       ここでは (1) 別名に「どの用途の名前か」の区分を足し、(2) 全部を1つにまとめて見るビューを足すだけ。
--       既存のEdge Function（invoice-auto-ingest／invoice-auto-create／vendor-master）は
--       vendor_aliases から (vendor_id, alias) だけを読むので、動作は変わらない（kind の既定値='invoice'）。
-- 冪等（何度実行しても同じ）。データの書き換えは無い（列追加とビュー作成のみ）。

-- (1) 別名の用途区分
alter table public.vendor_aliases
  add column if not exists kind text not null default 'invoice';

alter table public.vendor_aliases drop constraint if exists vendor_aliases_kind_chk;
alter table public.vendor_aliases
  add constraint vendor_aliases_kind_chk check (kind in ('invoice', 'statement', 'bank'));

comment on column public.vendor_aliases.kind is
  '別名の用途: invoice=請求書（Infomart・メール・OCR）の請求元名／statement=明細・CSV上の名前／bank=通帳・振込の摘要。
   MFの補助科目名は vendor_line_rules（法人・科目ごと）が持つので、ここには入れない。';

-- (2) 1社の名前を横断して見るビュー（長い形式: 取引先 × 用途 × 法人 × 科目）
create or replace view public.v_vendor_name_map
with (security_invoker = true) as
  -- 登録名（請求書の正式名・Infomartの会計データの名前）
  select v.id as vendor_id, 'official'::text as kind, null::text as tenant_id, null::text as account_name,
         v.name as name, 'vendors.name'::text as source
    from public.vendors v
  union all
  -- MF上の取引先名（任意項目）
  select v.id, 'mf_partner', null, null, v.mf_partner_name, 'vendors.mf_partner_name'
    from public.vendors v where nullif(btrim(v.mf_partner_name), '') is not null
  union all
  -- 別名（請求書／明細／通帳）
  select a.vendor_id, a.kind, null, null, a.alias, 'vendor_aliases:' || a.source
    from public.vendor_aliases a where a.is_active
  union all
  -- MFの借方補助科目（仕入高/○○ 等・法人×科目ごと）
  select r.vendor_id, 'mf_debit_sub', r.tenant_id, r.account_name, r.sub_account_name, 'vendor_line_rules'
    from public.vendor_line_rules r
   where r.is_active and r.vendor_id is not null and nullif(btrim(r.sub_account_name), '') is not null
  union all
  -- MFの貸方補助科目（買掛金/○○ 等・法人ごと）。credit_sub_mode='vendor' の行は登録名そのものを使うので別行にしない
  select r.vendor_id, 'mf_credit_sub', r.tenant_id, r.credit_account, r.credit_sub_name, 'vendor_line_rules'
    from public.vendor_line_rules r
   where r.is_active and r.vendor_id is not null and nullif(btrim(r.credit_sub_name), '') is not null;

comment on view public.v_vendor_name_map is
  '取引先1社あたりの名前の一覧（登録名／MF取引先名／請求書・明細・通帳の別名／MF借方・貸方補助科目）。
   社内情報の取引先名は vendors.info_supplier_id → info.suppliers で別に引く（info スキーマの権限を分けるため含めない）。';

grant select on public.v_vendor_name_map to authenticated;

-- (3) 取引先の紐付け状況（社内情報との紐付け有無・名前の揃い具合）
create or replace view public.v_vendor_link_status
with (security_invoker = true) as
select v.id as vendor_id,
       v.name,
       v.is_active,
       v.info_supplier_id,
       (v.info_supplier_id is not null) as linked_info,
       (select count(*) from public.vendor_aliases a where a.vendor_id = v.id and a.is_active and a.kind = 'invoice')   as n_invoice_names,
       (select count(*) from public.vendor_aliases a where a.vendor_id = v.id and a.is_active and a.kind = 'statement') as n_statement_names,
       (select count(*) from public.vendor_line_rules r where r.vendor_id = v.id and r.is_active
          and (nullif(btrim(r.credit_sub_name), '') is not null or nullif(btrim(r.sub_account_name), '') is not null)) as n_mf_names
  from public.vendors v;

grant select on public.v_vendor_link_status to authenticated;
