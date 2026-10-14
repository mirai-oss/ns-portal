-- 【事前報告様式（DB変更）】担当C・2026-10-14「メールで来る売上入金（不動産の送金明細）を自動で仕訳下書き→承認待ちへ」
-- 理由: ゼン・ランド（管理会社）から毎月届く「送金明細書」（物件ごと・PDF）は売上入金で、手作業で仕訳（仕訳辞書）を作っていた。
--       物件ごとの仕訳の型（売掛金／売上高の補助科目・部門・手数料）を表にして、AIが読み取った金額を当てはめ、承認待ちまで自動で持っていく。
-- 追加（新規のみ・既存の表・列は変更なし）:
--   receivable_property_rules … 物件ごとの仕訳の型（管理会社×物件名→売掛金・売上高の補助科目、部門、手数料の補助科目、摘要名）。既存の仕訳辞書3件(マンタビル/外神田/与野スカイ)から作成。
--   vendors に「株式会社ゼン・ランド」を追加（無ければ）／invoice_mail_rules にゼン・ランドの送信元ルールを追加（無ければ）
-- 既存データへの影響: なし。 rollback: drop table receivable_property_rules; 追加した vendors / invoice_mail_rules の行を削除。
create table if not exists public.receivable_property_rules (
  id uuid primary key default gen_random_uuid(),
  vendor_key text not null,                         -- 管理会社（送金者）の取引先名 例: 株式会社ゼン・ランド
  property_pattern text not null,                   -- 送金明細の「物件名」に含まれる文字（全角半角・空白を除いて比較）
  property_label text,                              -- 表示名
  receivable_account text not null default '売掛金',
  receivable_sub text not null,                     -- 例: 【不動産】千歳船橋マンタビル
  revenue_account text not null default '売上高',
  revenue_sub text not null,
  fee_account text not null default '支払手数料',
  fee_sub text,                                     -- 例: ゼンランド（管理委託料）
  department_name text,                             -- MFの部門名 例: 千歳船橋/マンタビル
  remark_label text,                                -- 摘要の頭 例: 世田谷マンタビル（→「世田谷マンタビル　9月分」）
  tenant_id text not null default 'nstyle',         -- MF事業者
  corporation_id uuid references public.corporations(id),
  is_active boolean not null default true,
  note text,
  created_at timestamptz not null default now()
);
create unique index if not exists receivable_property_rules_uk on public.receivable_property_rules (vendor_key, property_pattern) where is_active;
alter table public.receivable_property_rules enable row level security;
drop policy if exists receivable_property_rules_all_inv on public.receivable_property_rules;
create policy receivable_property_rules_all_inv on public.receivable_property_rules for all using (invoice_can_access()) with check (invoice_can_access());

insert into public.receivable_property_rules (vendor_key, property_pattern, property_label, receivable_sub, revenue_sub, fee_sub, department_name, remark_label, corporation_id, note)
select * from (values
  ('株式会社ゼン・ランド','マンタビル','千歳船橋マンタビル','【不動産】千歳船橋マンタビル','【不動産】千歳船橋マンタビル','ゼンランド','千歳船橋/マンタビル','世田谷マンタビル','a8754755-622d-4954-b34c-40ee9442bd27'::uuid,'仕訳辞書「千歳船橋マンタビル」より'),
  ('株式会社ゼン・ランド','ナガシマビル','外神田 第Ⅲナガシマビル','【不動産】外神田一丁目','【不動産】外神田一丁目','ゼンランド','外神田一丁目/佐藤ビル','外神田1丁目','a8754755-622d-4954-b34c-40ee9442bd27'::uuid,'仕訳辞書「外神田 第Ⅲナガシマビル」より'),
  ('株式会社ゼン・ランド','スカイレジデンシャル','与野スカイレジデンシャル','【不動産】与野スカイタワー','【不動産】与野スカイタワー','ゼンランド','与野スカイタワー','与野スカイ','a8754755-622d-4954-b34c-40ee9442bd27'::uuid,'仕訳辞書「与野スカイレジデンシャル」より（摘要は仮）')
) as v(vendor_key,property_pattern,property_label,receivable_sub,revenue_sub,fee_sub,department_name,remark_label,corporation_id,note)
where not exists (select 1 from public.receivable_property_rules);

insert into public.vendors (name, name_aliases, email_domains, default_corporation_id, is_active)
select '株式会社ゼン・ランド', array['ゼン・ランド','ゼンランド','(株)ゼン・ランド'], array['zenland.jp'], 'a8754755-622d-4954-b34c-40ee9442bd27'::uuid, true
where not exists (select 1 from public.vendors where is_active and name in ('株式会社ゼン・ランド'));

insert into public.invoice_mail_rules (rule_type, pattern, needs_attachment, category, priority, note)
select 'from_domain','zenland.jp', true, 'sales_deposit', 25, 'ゼン・ランド（管理会社）の送金明細書＝売上入金'
where not exists (select 1 from public.invoice_mail_rules where pattern='zenland.jp');
