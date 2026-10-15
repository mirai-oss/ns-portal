-- 【事前報告様式（DB変更）】担当C・2026-10-15「N-Style→トーホーの業務委託精算書（メール）を、2つの仕訳の下書き（トーホー=売上／N-Style=支払）に自動で」
-- 理由: 毎月、精算ダッシュボードから「【重要】◯月分業務委託料精算書のご送付」のメール（精算書PDF＋NTT・電気料金・カード売上などの添付）が届く。
--       ユーザーはこれを、トーホーのMFに売上（売掛金／飲食売上・業務委託売上）、N-StyleのMFに支払（運営委託費／未払金・トーホー）として手入力している
--       （2026-08分 黒霧屋 新横浜: トーホー取引No5231・N-Style取引No744。ユーザーのMF画面で確認済み）。同じ仕訳を下書きにして承認待ちへ並べる。
-- 追加（新規のみ・既存の表・データは変更なし）:
--   seisan_statement_rules … 店舗ごとの仕訳の型（トーホー側・N-Style側の科目・補助科目・部門・摘要の雛形）。黒霧屋 新横浜を1件登録
--   invoice_mail_rules … 件名に「業務委託料精算書」を含む添付ありのメール → 売上入金（優先度5）
-- rollback: drop table seisan_statement_rules; 追加した invoice_mail_rules の行を削除。
create table if not exists public.seisan_statement_rules (
  id uuid primary key default gen_random_uuid(),
  store_patterns text[] not null,                    -- 精算書の店舗名に含まれる文字（空白を除く）。どれか1つに一致 例: {新横浜黒霧屋,黒霧屋新横浜}
  store_label text,
  date_basis text not null default 'month_end',      -- 計上日: month_end=対象月の末日
  -- トーホー側（売上）
  sales_tenant text not null default 'default',
  sales_corporation_id uuid references public.corporations(id),
  sales_customer_vendor text not null default '株式会社N-Style',
  sales_receivable_account text not null default '売掛金', sales_receivable_sub text not null default 'N-Style',
  sales_revenue_account text not null default '飲食売上', sales_revenue_sub text not null default '業務委託売上',
  sales_department text, sales_remark_tpl text,      -- {mo}=「8月」
  -- N-Style側（支払）
  exp_tenant text not null default 'nstyle',
  exp_corporation_id uuid references public.corporations(id),
  exp_payee_vendor text not null default '有限会社トーホーエージェンシー',
  exp_account text not null default '運営委託費', exp_sub text, exp_department text,
  exp_payable_account text not null default '未払金', exp_payable_sub text, exp_remark_tpl text,
  is_active boolean not null default true,
  note text,
  created_at timestamptz not null default now()
);
alter table public.seisan_statement_rules enable row level security;
drop policy if exists seisan_statement_rules_all_inv on public.seisan_statement_rules;
create policy seisan_statement_rules_all_inv on public.seisan_statement_rules for all using (invoice_can_access()) with check (invoice_can_access());

insert into public.seisan_statement_rules (store_patterns, store_label, sales_corporation_id, sales_department, sales_remark_tpl, exp_corporation_id, exp_sub, exp_department, exp_payable_sub, exp_remark_tpl, note)
select array['新横浜黒霧屋','黒霧屋新横浜'], '新横浜 黒霧屋', '9f3f5239-d346-42b9-86cf-144e246cebeb'::uuid, '06新横浜黒霧屋', '{mo}分黒霧屋　新横浜',
       'a8754755-622d-4954-b34c-40ee9442bd27'::uuid, '黒霧屋/新横浜', '黒霧屋/新横浜', '有）トーホーエージェンシー', '{mo}/黒霧屋/運営委託費',
       'MF: トーホー取引No5231(売掛金/N-Style→飲食売上/業務委託売上・08/30)・N-Style取引No744(運営委託費/黒霧屋/新横浜→未払金/有）トーホーエージェンシー・08/31)。計上日はどちらも対象月末で統一（要確認）'
where not exists (select 1 from public.seisan_statement_rules);

insert into public.invoice_mail_rules (rule_type, pattern, needs_attachment, category, priority, note)
select 'subject_contains','業務委託料精算書', true, 'sales_deposit', 5, '精算ダッシュボードから届く業務委託料精算書（N-Style→トーホー）'
where not exists (select 1 from public.invoice_mail_rules where pattern='業務委託料精算書');
