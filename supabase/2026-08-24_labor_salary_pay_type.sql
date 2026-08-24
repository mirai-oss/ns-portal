-- D-2 追補: 給与体系（固定給/時給）の暫定管理
-- docs/実装指示書_担当D_勤怠給与監視_2026-08-24.md D-2
--
-- 背景（2026-08-24ユーザー確認）:
--   users.role（CEO/HQ/TEAM/TENCHO/SHAIN/AL）はポータルの権限区分であり、
--   「固定給か時給か」という給与体系とは別概念（例: 齋藤隆治さんはrole=HQだが時給）。
--   roleを給与体系の代わりに流用すると権限判定に影響するため使わない。
--
--   本来「全社員の給料体系・雇用形態・時給」を一元管理する場所は`ns-info-system`
--   （社内情報管理システム・担当F専任）が適切だが、今回はD-2の按分計算を進めるための
--   **暫定措置**として、判明している人だけをD管轄の小さな表で先に登録する。
--   本表は担当Fが社内情報側に正式な給与体系管理を実装したら移行・廃止する前提
--   （WORKLOG「担当Fへの依頼」参照）。

create table if not exists labor_salary_pay_type (
  user_id uuid primary key references users(id),
  pay_type text not null check (pay_type in ('fixed_salary', 'hourly')),
  note text,                -- 例: '固定給+インセンティブ'（2026-08-24ユーザー確認の原文メモ）
  updated_at timestamptz not null default now()
);

-- 2026-08-24 ユーザー確認済みの4名（固定給。インセンティブ込みでも「社員人件費DB」の
-- 按分対象という位置づけでfixed_salaryとして扱う）
insert into labor_salary_pay_type (user_id, pay_type, note)
select u.id, 'fixed_salary', v.note
from (values
  ('青山純', '固定給'),
  ('佐藤俊一', '固定給+インセンティブ'),
  ('坂本龍太郎', '固定給+インセンティブ'),
  ('鍋倉巧', '固定給+インセンティブ')
) as v(name, note)
join users u on u.name = v.name
on conflict (user_id) do update set pay_type = excluded.pay_type, note = excluded.note, updated_at = now();

-- labor_salary_daily_weight を再定義: users.role ではなく labor_salary_pay_type.pay_type='fixed_salary' で判定
create or replace view labor_salary_daily_weight as
select
  l.store_id,
  s.name as store_name,
  l.work_date,
  date_trunc('month', l.work_date)::date as ym,
  sum(l.worked_minutes) as daily_minutes
from labor_cost_daily l
join labor_salary_pay_type pt on pt.user_id = l.user_id and pt.pay_type = 'fixed_salary'
join stores s on s.id = l.store_id
group by l.store_id, s.name, l.work_date, date_trunc('month', l.work_date)::date;
