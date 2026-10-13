-- 担当C: 請求書自動処理 Phase5「行ルール」の土台（設計書_請求書メール自動処理と仕訳承認フロー §9-1／実装指示書 追記Sync11／seed_定期請求書10社 §3・§6）
--
-- 【事前報告様式（DB変更）】
-- 理由: 取引先×明細の仕訳ルール（科目・補助・税区分・部門・貸方）を、仕訳辞書ではなく専用表で持つ。
--       ルールの出どころ（総勘定元帳の実績→承認した自動仕訳→最終修正）と修正回数を記録し、
--       直近90日で2回以上修正されたものを「ルール不安定」として要確認に落とせるようにする。
-- 現構造: vendor_line_rules は存在しない（vendors・mf_journal_templatesは既存のまま触らない）。
-- 変更（新規2表・1ビュー・1関数・seed。既存の表/列/ポリシーは一切変更しない）:
--   vendor_line_rules       … 行ルール本体。1つの「取引先×明細パターン」につき有効(is_active)なのは1行だけ。
--                             修正して承認するたび version+1 の新しい行を積み、古い行は is_active=false で履歴に残す（上書きで消さない）。
--                             source = ledger（総勘定元帳の実績）／approved（人が承認した自動仕訳）／corrected（人が修正して承認）
--   vendor_invoice_policies … 取引先ごとの請求書全体の決まり（貸方・税の1円調整・証憑警告）
--   v_vendor_line_rule_status … 直近90日の修正回数を「今」の時点で数え直し、2回以上なら unstable=true
--   save_vendor_line_rule() … 承認画面から呼ぶ保存関数（同じ内容なら何もしない／違えば新バージョンを積む）
--   seed … seed_定期請求書10社 §3・§6（Q1〜Q4=a）の10社分
-- 取引先マスタ(vendors)には現状10社中プレコ1社しか居ないため、vendor_id は null 可・vendor_key（正式名）で持つ。
-- 取引先登録・別名(vendor_aliases)は担当Fの管轄。登録後に vendor_id を埋める（下の末尾の UPDATE）。
-- 既存データへの影響: なし。
-- migration: 本ファイル（何度流しても壊れない）。 rollback: drop view v_vendor_line_rule_status; drop function save_vendor_line_rule(text,text,text,jsonb,text); drop table vendor_invoice_policies; drop table vendor_line_rules;

create table if not exists public.vendor_line_rules (
  id uuid primary key default gen_random_uuid(),
  vendor_id uuid references public.vendors(id) on delete set null,
  vendor_key text not null,                         -- 取引先の正式名（vendor_id が未解決でも持てる）
  tenant_id text not null default 'default',        -- MF事業者（default=トーホー／nstyle）
  line_pattern text not null default '*',           -- 明細名パターン（'*'=その取引先の全明細）
  account_name text not null,                       -- 借方 勘定科目
  sub_account_mode text not null default 'fixed' check (sub_account_mode in ('fixed','vendor','none')),
  sub_account_name text,                            -- fixed のときの補助科目名
  tax_mode text not null default 'by_line' check (tax_mode in ('by_line','fixed')),  -- by_line=請求書の行の税率に従う
  tax_name text,                                    -- fixed のときの税区分名
  expected_tax_rates int[],                         -- この取引先で想定する税率（外れたら要確認）例 {8} {8,10} {10}
  credit_account text,                              -- 貸方（買掛金／未払金）
  credit_sub_mode text not null default 'vendor' check (credit_sub_mode in ('fixed','vendor','none')),
  credit_sub_name text,
  dept_mode text not null default 'line_store' check (dept_mode in ('line_store','primary_store','hq')),
  source text not null check (source in ('ledger','approved','corrected')),
  version int not null default 1,
  is_active boolean not null default true,
  corrected_count_90d int not null default 0,      -- 保存時点の90日内修正回数（判定は view の live 値を使う）
  last_corrected_at timestamptz,
  note text,
  created_by uuid,
  created_at timestamptz not null default now()
);
create unique index if not exists vendor_line_rules_active_uk
  on public.vendor_line_rules (vendor_key, tenant_id, line_pattern) where is_active;
create index if not exists vendor_line_rules_vendor_idx on public.vendor_line_rules (vendor_key, tenant_id, line_pattern, created_at desc);

create table if not exists public.vendor_invoice_policies (
  vendor_key text not null,
  tenant_id text not null default 'default',
  vendor_id uuid references public.vendors(id) on delete set null,
  tax_adjust_policy text not null default 'largest_line_1yen' check (tax_adjust_policy in ('largest_line_1yen','stop')),
  evidence_warning text,                            -- 証憑に関する警告（例: 本請求書がインボイスではない）
  note text,
  updated_at timestamptz not null default now(),
  primary key (vendor_key, tenant_id)
);

alter table public.vendor_line_rules enable row level security;
alter table public.vendor_invoice_policies enable row level security;
drop policy if exists vendor_line_rules_all_inv on public.vendor_line_rules;
create policy vendor_line_rules_all_inv on public.vendor_line_rules for all using (invoice_can_access()) with check (invoice_can_access());
drop policy if exists vendor_invoice_policies_all_inv on public.vendor_invoice_policies;
create policy vendor_invoice_policies_all_inv on public.vendor_invoice_policies for all using (invoice_can_access()) with check (invoice_can_access());

-- 直近90日の修正回数を今の時点で数え直す。2回以上＝ルール不安定（アラート＋要確認・自動OKにしない）
create or replace view public.v_vendor_line_rule_status as
select r.*,
  (select count(*) from public.vendor_line_rules h
     where h.vendor_key=r.vendor_key and h.tenant_id=r.tenant_id and h.line_pattern=r.line_pattern
       and h.source='corrected' and h.created_at >= now() - interval '90 days')::int as corrected_90d_live,
  ((select count(*) from public.vendor_line_rules h
     where h.vendor_key=r.vendor_key and h.tenant_id=r.tenant_id and h.line_pattern=r.line_pattern
       and h.source='corrected' and h.created_at >= now() - interval '90 days') >= 2) as unstable
from public.vendor_line_rules r
where r.is_active;
alter view public.v_vendor_line_rule_status set (security_invoker = true);

-- 承認画面から呼ぶ保存関数。
--   有効なルールが無い             → version 1 で作成（p_source は 'ledger' か 'approved'）
--   有効なルールがあり内容が同じ    → 何もしない（そのまま返す）
--   有効なルールがあり内容が違う    → 旧ルールを is_active=false で履歴に残し、version+1 を source='corrected' で積む
-- p_fields の項目: account_name, sub_account_mode, sub_account_name, tax_mode, tax_name, expected_tax_rates,
--                  credit_account, credit_sub_mode, credit_sub_name, dept_mode, vendor_id, note
create or replace function public.save_vendor_line_rule(
  p_vendor_key text, p_tenant_id text, p_line_pattern text, p_fields jsonb, p_source text default 'approved'
) returns public.vendor_line_rules
language plpgsql security invoker as $$
declare
  cur public.vendor_line_rules;
  nw public.vendor_line_rules;
  same boolean;
  cnt int;
begin
  if not invoice_can_access() then raise exception '権限がありません'; end if;
  if p_source not in ('ledger','approved') then raise exception 'p_source は ledger か approved（修正は自動でcorrectedになります）'; end if;
  select * into cur from public.vendor_line_rules
    where vendor_key=p_vendor_key and tenant_id=p_tenant_id and line_pattern=p_line_pattern and is_active
    for update;
  if found then
    same := cur.account_name is not distinct from coalesce(p_fields->>'account_name', cur.account_name)
      and coalesce(cur.sub_account_mode,'') = coalesce(p_fields->>'sub_account_mode', cur.sub_account_mode)
      and cur.sub_account_name is not distinct from coalesce(p_fields->>'sub_account_name', cur.sub_account_name)
      and coalesce(cur.tax_mode,'') = coalesce(p_fields->>'tax_mode', cur.tax_mode)
      and cur.tax_name is not distinct from coalesce(p_fields->>'tax_name', cur.tax_name)
      and cur.credit_account is not distinct from coalesce(p_fields->>'credit_account', cur.credit_account)
      and coalesce(cur.credit_sub_mode,'') = coalesce(p_fields->>'credit_sub_mode', cur.credit_sub_mode)
      and cur.credit_sub_name is not distinct from coalesce(p_fields->>'credit_sub_name', cur.credit_sub_name)
      and coalesce(cur.dept_mode,'') = coalesce(p_fields->>'dept_mode', cur.dept_mode);
    if same then return cur; end if;
    update public.vendor_line_rules set is_active=false where id=cur.id;
    select count(*)::int + 1 into cnt from public.vendor_line_rules
      where vendor_key=p_vendor_key and tenant_id=p_tenant_id and line_pattern=p_line_pattern
        and source='corrected' and created_at >= now() - interval '90 days';
    insert into public.vendor_line_rules (vendor_id, vendor_key, tenant_id, line_pattern, account_name, sub_account_mode, sub_account_name,
        tax_mode, tax_name, expected_tax_rates, credit_account, credit_sub_mode, credit_sub_name, dept_mode,
        source, version, corrected_count_90d, last_corrected_at, note, created_by)
      values (coalesce((p_fields->>'vendor_id')::uuid, cur.vendor_id), p_vendor_key, p_tenant_id, p_line_pattern,
        coalesce(p_fields->>'account_name', cur.account_name),
        coalesce(p_fields->>'sub_account_mode', cur.sub_account_mode), coalesce(p_fields->>'sub_account_name', cur.sub_account_name),
        coalesce(p_fields->>'tax_mode', cur.tax_mode), coalesce(p_fields->>'tax_name', cur.tax_name),
        coalesce(case when p_fields ? 'expected_tax_rates' then (select array_agg(x::int) from jsonb_array_elements_text(p_fields->'expected_tax_rates') x) end, cur.expected_tax_rates),
        coalesce(p_fields->>'credit_account', cur.credit_account),
        coalesce(p_fields->>'credit_sub_mode', cur.credit_sub_mode), coalesce(p_fields->>'credit_sub_name', cur.credit_sub_name),
        coalesce(p_fields->>'dept_mode', cur.dept_mode),
        'corrected', cur.version + 1, cnt, now(), coalesce(p_fields->>'note', cur.note), auth.uid())
      returning * into nw;
    return nw;
  end if;
  insert into public.vendor_line_rules (vendor_id, vendor_key, tenant_id, line_pattern, account_name, sub_account_mode, sub_account_name,
      tax_mode, tax_name, expected_tax_rates, credit_account, credit_sub_mode, credit_sub_name, dept_mode, source, version, note, created_by)
    values ((p_fields->>'vendor_id')::uuid, p_vendor_key, p_tenant_id, p_line_pattern, p_fields->>'account_name',
      coalesce(p_fields->>'sub_account_mode','fixed'), p_fields->>'sub_account_name',
      coalesce(p_fields->>'tax_mode','by_line'), p_fields->>'tax_name',
      case when p_fields ? 'expected_tax_rates' then (select array_agg(x::int) from jsonb_array_elements_text(p_fields->'expected_tax_rates') x) end,
      p_fields->>'credit_account', coalesce(p_fields->>'credit_sub_mode','vendor'), p_fields->>'credit_sub_name',
      coalesce(p_fields->>'dept_mode','line_store'), p_source, 1, p_fields->>'note', auth.uid())
    returning * into nw;
  return nw;
end $$;

-- seed: seed_定期請求書10社 §3・§6（Q1〜Q4=a）。出どころ=総勘定元帳の実績（取引先ルール一覧_トーホーエージェンシー.xlsx）→ source='ledger'
--   科目=仕入高／補助=取引先名（RSSのみ 衛生管理費／おしぼり）。税=請求書の行の税率に従う（8%軽減／10%）。部門=行の店舗。
--   貸方=買掛金（RSSのみ未払金）・補助は取引先名と仮定（MF実仕訳で確認次第、再学習で更新）。
insert into public.vendor_line_rules (vendor_key, tenant_id, line_pattern, account_name, sub_account_mode, sub_account_name, tax_mode, expected_tax_rates, credit_account, credit_sub_mode, dept_mode, source, version, note)
select v.k, 'default', '*', v.acc, 'fixed', v.sub, 'by_line', v.rates, v.credit, 'vendor', 'line_store', 'ledger', 1, v.note
from (values
  ('有限会社染谷商店','仕入高','㈲染谷商店', array[8], '買掛金', null::text),
  ('有限会社森和','仕入高','㈲森和', array[8], '買掛金', null),
  ('コカ・コーラボトラーズジャパン株式会社','仕入高','コカ・コーラボトラーズ', array[8], '買掛金', null),
  ('株式会社フレッシュエージェント','仕入高','フレッシュエージェント', array[8], '買掛金', null),
  ('株式会社プレコフーズ','仕入高','㈱プレコフーズ', array[8,10], '買掛金', '10%分（備品・容器等）も仕入高のまま（Q1=a）'),
  ('株式会社西原商会','仕入高','㈱西原商会', array[8,10], '買掛金', '10%分（酒類・備品）も仕入高のまま（Q2=a）'),
  ('株式会社タジマフーズ','仕入高','㈱タジマフーズ', array[8], '買掛金', '旧: 成瀬商店'),
  ('株式会社シモヤマ','仕入高','㈱シモヤマ', array[8], '買掛金', null),
  ('有限会社伊勢五本店','仕入高','㈲伊勢五本店', array[10], '買掛金', '酒類。仕入高のまま・補助=取引先名（Q2=a）'),
  ('株式会社アールエスエス','衛生管理費','おしぼり', array[10], '未払金', '仕入ではなく経費（貸方=未払金・Q4=a）')
) as v(k, acc, sub, rates, credit, note)
on conflict do nothing;

insert into public.vendor_invoice_policies (vendor_key, tenant_id, tax_adjust_policy, evidence_warning, note)
select k, 'default', 'largest_line_1yen', w, n from (values
  ('有限会社染谷商店', null::text, null::text), ('有限会社森和', null, null), ('コカ・コーラボトラーズジャパン株式会社', null, null),
  ('株式会社フレッシュエージェント', null, null),
  ('株式会社プレコフーズ', '本請求書はインボイスではありません。納品書（インボイス）を証憑に添付してください。', '納品書がインボイス'),
  ('株式会社西原商会', null, null), ('株式会社タジマフーズ', null, null), ('株式会社シモヤマ', null, null),
  ('有限会社伊勢五本店', null, null), ('株式会社アールエスエス', null, null)
) as t(k, w, n)
on conflict do nothing;

-- 取引先マスタに同名の取引先が既にあれば vendor_id を埋める（無ければ null のまま＝担当Fの取引先登録・vendor_aliases投入後に再実行）
update public.vendor_line_rules r set vendor_id = v.id from public.vendors v where r.vendor_id is null and v.name = r.vendor_key;
update public.vendor_invoice_policies p set vendor_id = v.id from public.vendors v where p.vendor_id is null and v.name = p.vendor_key;
