-- 法人移行期間の検算（黒霧屋 新横浜の運営変更 2026-11-01・設計メモ_スマレジ複数契約対応 §10）
-- 対象店舗の明細を含む請求書で、対象年月が from〜to の間は、宛先法人と期待法人（その月の運営関係）を比べ、
-- 一致/不一致に関わらず「法人移行期間」として人が確認する。2027-01以降に通常ルールへ戻すには enabled=false か to を変える。
insert into public.automation_rule_settings (key, label, description, enabled, action, params)
values ('corp_transition', '法人移行期間（黒霧屋 新横浜）',
  '運営会社の切替（トーホー→LiveGate・2026-11-01）の前後は、請求書の宛先法人が取引先ごとに11月分/12月分でバラバラに変わるため、宛先法人と期待法人（その月の運営関係）を比べて必ず人が確認する。不一致は要対応。',
  true, 'require_review',
  '{"store_names":["黒霧屋 新横浜"],"from":"2026-11","to":"2026-12"}'::jsonb)
on conflict (key) do nothing;

-- 一覧で「法人移行期間」バッジを軽く出すためのフラグ（invoice-check が付ける。チェック本体はinvoices.checksに残る）
alter table public.invoices add column if not exists corp_transition boolean not null default false;
