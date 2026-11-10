-- 賃金変更・銀行口座変更の承認と履歴（ステップ 3・2026-11-10）
--   設計: docs/設計書_従業員情報変更の連動_2026-11-10.md §9・§10
--   ★ 本番未適用（開発・テストのみ承認。適用は別途承認）。戻し方: 2026-11-10_pay_change_requests_rollback.sql
--   前提: 2026-11-10_employee_change_events.sql（適用済み）＝直接編集も含めて変更前後・変更者は必ず履歴に残る
--
--   再利用するもの（新しい申請の仕組みは作らない）:
--     ・申請の表 profile_change_requests（本人の口座変更申請 submit_profile_change_request／承認 review_profile_change_request はそのまま使える）
--     ・賃金の登録 hr_save_wage（適用開始日つき・スマレジ同期と読み戻しは既存の wage_push／wage_pull と employee_wage_settings.sync_status）
--     ・振込データの出力の印 payroll_transfer_schedule（出力時に行が出来る）・給与確定 payroll_finalized
--   足すもの:
--     ・申請に「適用開始日（賃金）」「何月分の給与＝何月何日支給分から（口座）」「理由」「反映の状態」
--     ・承認は申請者と別の人（マスターは自分の申請も承認可）。承認まで賃金・口座は変わらない＝スマレジ同期も承認後だけ
--     ・締め済みは自動で上書きしない: 賃金＝適用開始月が給与確定済みなら承認を止める（マスターが理由つきで明示したときだけ通す）
--                                     口座＝その支給回の振込データが出力済み・支給日を過ぎていれば反映しない（本部が支給回を選び直す）
--     ・口座は「前の支給回の振込データが出力されるまで」現在の口座を書き換えない（予約）。出力の直後に自動で切り替わる（承認済みの予約の実行）
--     ・振込データを出力した時点の口座の控え payroll_transfer_account_snapshots
--     ・直接編集の禁止（承認必須化）は app_settings.employee_change の bank_approval_required／wage_approval_required（既定 false＝これまでどおり直接編集も可・履歴は残る）
--
--   ★ 口座変更の運用方針（2026-11-10 夜・確定）に合わせた点:
--     ・通常の給与振込に承認の手順は足さない。登録済み（承認済み）の口座をそのまま使う。変更申請が無い人には何も起きない
--     ・申請があった人だけ、本部に確認・承認のタスクと通知（Slack・本部タスク。口座番号などは出さない。フラグ pay_request_notify_enabled・既定 false）
--     ・どの支給回から新しい口座にするかは「承認のとき」に確定する（申請の月は希望。未指定なら次の未出力の回）
--     ・承認済みの変更は、決めた支給回から自動で切り替わる（前の回の出力直後／振込画面を開いたとき hr_payroll_transfer_prepare）
--     ・振込データを出力した時点の口座は自動で控えを取り（人の承認なし）、あとで登録口座が変わっても控えは自動では変わらない。出し直しは控えの口座を使う
--     ・例外: 出力済みの回の口座を変える必要があるときだけ、本部の個別の確認・承認（理由つき）。控えに「個別承認」として残る
--     ・本部に対応を求めるのは 承認漏れ・同期エラー・出力済みデータとの競合 があるときだけ（hr_pay_change_attention）
--
--   ★ 本番反映前の修正（2026-11-10 深夜・ユーザー指示）:
--     ① 未承認の口座変更申請が今回の支給回に影響する人は、振込データに入れない・確定しない（控えを取らない）。除外したら本部タスク（振込漏れ防止）と警告。
--        全員分が必要な運用は transfer_pending_mode='block_all' で、解消するまでファイル全体の確定を止める（既定は 'exclude'＝その人だけ除外）
--     ② どの支給回から新しい口座にするかは、承認する人が必ず選ぶ（nippo・ポータル共通）。自動で「次の未出力の回」に決める動きは廃止。
--        一度決めた回・確定した振込先（控え）は、理由つきの例外承認（申請者・本人とは別の人）なしに変えられない
--     ③ 賃金の変更申請も本部タスクと Slack 通知に連動（申請で 1 件・承認／却下／取り下げで自動完了・二重に作らない。金額は出さない）
--     ④ 本部の直接編集も承認の対象にできる（フラグ ON 時）。ただし 入社時の初期登録・入社手続き中・スマレジ同期／取込（システム処理）は止めない
--
--   ★ 本番切り替えの安全対策（2026-11-11。画面より先に DB 側で守る）:
--     ⑤ 振込 CSV 出力の一時停止 transfer_export_paused。★この SQL を適用した瞬間から true（停止）で始まる。全画面の更新と動作確認のあと、手順書の SQL で false（再開）にする。
--        停止中は、出力の記録を受け付けず、振込口座の直接の読み出しも返さない（＝古い画面を開き直しても CSV を作れない）
--     ⑥ 新しい振込画面は、出力の直前に「準備」（hr_payroll_transfer_prepare）で 1 回かぎりの出力の印（export_token）を受け取り、出力の記録に付ける。
--        印の無い記録＝古い画面・直接の API からの出力 → 確定として扱わない（控え・除外の処理をしない）＋【要確認】の本部タスクと「対応が必要」
--     ⑦ 口座変更の申請が承認待ちの人の登録口座は、画面からの直接の読み出しでは返さない（古い画面でも、その人は振込データに入らない）。直接の書き換えもできない
--     ⑧ 口座・賃金の申請の行（profile_change_requests）は、画面・API から直接は書けない（申請・承認の関数だけが書く）

-- ============ 1. 申請の表を拡張 ============
alter table profile_change_requests add column if not exists payload jsonb;
alter table profile_change_requests add column if not exists effective_date date;            -- 賃金: 適用開始日
alter table profile_change_requests add column if not exists effective_year_month text;      -- 口座: この月分の給与から（例 2026-11 ＝ 12/15 支給分）
alter table profile_change_requests add column if not exists effective_pay_date date;        -- 口座: その支給日（表示用。予定日が決まっていればその日、無ければ翌月 15 日）
alter table profile_change_requests add column if not exists request_reason text;
alter table profile_change_requests add column if not exists apply_status text not null default 'none';
alter table profile_change_requests add column if not exists applied_at timestamptz;
alter table profile_change_requests add column if not exists apply_note text;
alter table profile_change_requests add column if not exists apply_ref jsonb;
alter table profile_change_requests add column if not exists hq_task_id uuid;                -- 申請時に作った本部タスク（承認・却下・取り下げで自動完了）
alter table profile_change_requests add column if not exists notify_log jsonb not null default '{}'::jsonb;   -- Slack 通知の二重防止（{"requested": 時刻, "conflict": 時刻}）
alter table profile_change_requests drop constraint if exists profile_change_requests_field_check;
alter table profile_change_requests add constraint profile_change_requests_field_check check (field = any (array['name','kana','phone','address','bank_account','contact_email','id_document','wage']));
alter table profile_change_requests drop constraint if exists profile_change_requests_status_check;
alter table profile_change_requests add constraint profile_change_requests_status_check check (status = any (array['pending','approved','rejected','cancelled']));
alter table profile_change_requests drop constraint if exists profile_change_requests_apply_status_check;
alter table profile_change_requests add constraint profile_change_requests_apply_status_check check (apply_status = any (array['none','applied','scheduled','blocked_exported','blocked_finalized']));
create unique index if not exists profile_change_requests_bank_pending on profile_change_requests(user_id) where field = 'bank_account' and status = 'pending';
create unique index if not exists profile_change_requests_bank_scheduled on profile_change_requests(user_id) where field = 'bank_account' and status = 'approved' and apply_status in ('scheduled','blocked_exported');

-- 振込データを出力した時点の口座の控え（どの口座に振り込んだかを支給回ごとに残す）
create table if not exists payroll_transfer_account_snapshots (
  year_month text not null, user_id uuid not null references users(id) on delete cascade,
  account jsonb not null, taken_at timestamptz not null default now(), taken_by uuid,
  source text not null default 'export' check (source in ('export', 'exception')),   -- export=出力時に自動で取った控え／exception=出力後に個別承認で差し替えた
  request_id uuid, previous_account jsonb, note text,
  primary key (year_month, user_id)
);
alter table payroll_transfer_account_snapshots enable row level security;
drop policy if exists payroll_transfer_account_snapshots_read on payroll_transfer_account_snapshots;
create policy payroll_transfer_account_snapshots_read on payroll_transfer_account_snapshots for select using (is_profile_approver());

update app_settings set value = '{"bank_approval_required": false, "wage_approval_required": false, "pay_request_notify_enabled": false, "transfer_pending_mode": "exclude"}'::jsonb || jsonb_build_object('transfer_guard_since', now()) || value where key = 'employee_change';
-- ⑤ 振込 CSV 出力の一時停止。適用した瞬間から停止（true）で始める。再開は docs/手順書_ステップ3-4_本番切り替え_2026-11-11.md の手順で false にする
update app_settings set value = value || '{"transfer_export_paused": true}'::jsonb where key = 'employee_change' and not (value ? 'transfer_export_paused');
create or replace function pay_transfer_paused() returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select (value ->> 'transfer_export_paused')::boolean from app_settings where key = 'employee_change'), false)
$$;
-- ⑥ 出力の印（新しい振込画面が「準備」で受け取り、出力の記録に付ける。1 回かぎり・2 時間有効）。hold_users＝その出力で除外するよう画面に伝えた人
create table if not exists payroll_transfer_export_tokens (
  token uuid primary key default gen_random_uuid(), year_month text not null, user_id uuid not null, hold_users uuid[] not null default '{}',
  issued_at timestamptz not null default now(), used_at timestamptz
);
alter table payroll_transfer_export_tokens enable row level security;   -- 方針なし＝画面からは読めない・書けない（関数だけ）
alter table payroll_transfer_schedule add column if not exists export_token uuid;
alter table payroll_transfer_schedule add column if not exists export_ok boolean;            -- null=この仕組みより前の記録／true=正しい手順の出力／false=印の無い出力（確定として扱わない）
alter table payroll_transfer_schedule add column if not exists invalid_export_at timestamptz;   -- 印の無い出力（古い画面・直接の API）があった時刻
alter table payroll_transfer_schedule add column if not exists invalid_task_id uuid;

-- 振込データから外した人（未承認の口座変更申請がその支給回に影響する人）。held=除外中／ready=申請が片付いた（その人の分の振込データを出す）／done=出力済み
create table if not exists payroll_transfer_holds (
  year_month text not null, user_id uuid not null references users(id) on delete cascade, request_id uuid,
  status text not null default 'held' check (status in ('held', 'ready', 'done')),
  created_at timestamptz not null default now(), resolved_at timestamptz, done_at timestamptz, hq_task_id uuid, checklist_item_id uuid,
  primary key (year_month, user_id)
);
alter table payroll_transfer_holds enable row level security;
drop policy if exists payroll_transfer_holds_read on payroll_transfer_holds;
create policy payroll_transfer_holds_read on payroll_transfer_holds for select using (hq_can_manage() or invoice_can_access());

-- 確定した振込先（控え）は、例外承認の処理からしか書き換えられない（削除は従業員の削除に伴うものだけ）
create or replace function payroll_transfer_account_snapshots_guard() returns trigger language plpgsql as $$
begin
  if coalesce(current_setting('employee_change.via_approval', true), '') = '' then raise exception '確定した振込先（出力時の口座の控え）は、例外承認なしに変更できません'; end if;
  return new;
end $$;
drop trigger if exists payroll_transfer_account_snapshots_guard on payroll_transfer_account_snapshots;
create trigger payroll_transfer_account_snapshots_guard before update on payroll_transfer_account_snapshots for each row execute function payroll_transfer_account_snapshots_guard();

-- ============ 2. 支給回の補助（給与は末日締め・翌月 15 日払い） ============
create or replace function pay_run_date(p_year_month text) returns date language sql stable security definer set search_path = public as $$
  select coalesce((select scheduled_date from payroll_transfer_schedule where year_month = p_year_month), (to_date(p_year_month || '-01', 'YYYY-MM-DD') + interval '1 month' + interval '14 days')::date)
$$;
-- 支給回の状態: open=まだ出力していない／exported=振込データを出力済み（支給日前）／paid=支給日を過ぎた
create or replace function pay_run_state(p_year_month text, p_today date default current_date) returns text language sql stable security definer set search_path = public as $$
  select case when p_today > pay_run_date(p_year_month) then 'paid' when exists (select 1 from payroll_transfer_schedule where year_month = p_year_month and export_ok is not false) then 'exported' else 'open' end
$$;
-- その支給回は「もう自動では変えられない」か（振込データを出力済み、または支給日を過ぎた）
create or replace function pay_run_closed(p_year_month text, p_today date default current_date) returns boolean language sql stable security definer set search_path = public as $$
  select pay_run_state(p_year_month, p_today) <> 'open'
$$;
-- 人ごとの支給回の状態。その回の振込データが出力済み・支給日を過ぎていても、その人が「除外中（held／ready）」なら、その人についてはまだ確定していない＝open
create or replace function pay_run_user_state(p_year_month text, p_user uuid, p_today date default current_date) returns text language sql stable security definer set search_path = public as $$
  select case when exists (select 1 from payroll_transfer_holds h where h.year_month = p_year_month and h.user_id = p_user and h.status in ('held', 'ready'))
              then 'open' else pay_run_state(p_year_month, p_today) end   -- 除外中の人は、支給日を過ぎても未確定のまま（振込が済むまで）
$$;
-- この支給回の振込データに入れてはいけない人（未承認の口座変更申請が、この回に影響する）。
--   影響する＝希望の開始がこの回以前、または希望なし（どの回からか未定）。この回の控えがもうある人（確定済み）は対象外。
--   支給日を過ぎてから出力する場合も同じように守る。この仕組みを入れる前に出力済みの月（控えが無い）だけは対象外
create or replace function pay_transfer_pending_holds(p_year_month text)
returns table(user_id uuid, request_id uuid) language sql stable security definer set search_path = public as $$
  select q.user_id, q.id from profile_change_requests q
   where q.field = 'bank_account' and q.status = 'pending' and (q.effective_year_month is null or q.effective_year_month <= p_year_month)
     -- いま銀行振込の口座が登録されている人だけ（口座が未登録・現金手渡しの人は、もともと振込データに入らない＝従来どおりの扱い）
     and exists (select 1 from payroll_bank_accounts b where b.user_id = q.user_id and coalesce(b.payment_method, 'bank_transfer') <> 'cash')
     and not exists (select 1 from payroll_transfer_schedule t where t.year_month = p_year_month
                      and t.created_at < coalesce((select (value ->> 'transfer_guard_since')::timestamptz from app_settings where key = 'employee_change'), '-infinity'::timestamptz))
     and not exists (select 1 from payroll_transfer_account_snapshots s where s.year_month = p_year_month and s.user_id = q.user_id)
$$;
-- 次に変えられる支給回（まだ出力していない最も早い月）
create or replace function pay_run_next_open(p_today date default current_date) returns text language sql stable security definer set search_path = public as $$
  select to_char(m, 'YYYY-MM') from generate_series(date_trunc('month', p_today) - interval '2 month', date_trunc('month', p_today) + interval '2 month', interval '1 month') m
   where not pay_run_closed(to_char(m, 'YYYY-MM'), p_today) order by m limit 1
$$;
create or replace function employee_change_group_of_request(p_field text)
returns text language sql immutable as $$
  select case p_field when 'name' then 'name' when 'kana' then 'name' when 'phone' then 'contact' when 'contact_email' then 'contact' when 'address' then 'address' when 'bank_account' then 'bank_account' when 'wage' then 'wage' else null end
$$;

-- ============ 3. 申請 ============
-- 賃金（本部・社長・マスター）と銀行口座（本人または本部）。この時点では賃金・口座は変わらない
create or replace function hr_pay_change_request(p_user uuid, p_kind text, p_payload jsonb, p_effective_date date default null, p_year_month text default null, p_reason text default null, p_actor uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_actor uuid; v_old jsonb; v_id uuid; v_warn text[] := '{}'; v_corp uuid; v_ym text;
begin
  if p_kind not in ('wage', 'bank_account') then raise exception '種類が不正です'; end if;
  if p_kind = 'bank_account' and auth.uid() is not null and auth.uid() = p_user then v_actor := auth.uid();     -- 本人の口座変更申請
  else v_actor := public.onboarding_resolve_actor(p_actor); end if;                                           -- それ以外は本部・社長・マスター
  if not exists (select 1 from users where id = p_user) then raise exception '対象の従業員が見つかりません'; end if;
  if nullif(trim(coalesce(p_reason, '')), '') is null and v_actor <> p_user then raise exception '変更の理由を入れてください'; end if;
  if p_kind = 'wage' then
    if p_effective_date is null then raise exception '適用開始日を指定してください'; end if;
    if coalesce((p_payload ->> 'wage')::int, 0) <= 0 or (p_payload ->> 'contract_id') is null or (p_payload ->> 'division') is null then raise exception '賃金の内容（契約・給与形態・金額）が足りません'; end if;
    if exists (select 1 from profile_change_requests where user_id = p_user and field = 'wage' and status = 'pending' and effective_date = p_effective_date
               and payload ->> 'contract_id' = p_payload ->> 'contract_id' and payload ->> 'division' = p_payload ->> 'division' and coalesce(payload ->> 'store_id', '') = coalesce(p_payload ->> 'store_id', '')) then
      raise exception '同じ適用開始日の賃金変更がすでに承認待ちです';
    end if;
    select jsonb_build_object('wage', w.wage, 'holiday_wage', w.holiday_wage, 'effective_date', w.effective_date) into v_old from employee_wage_settings w
     where w.user_id = p_user and w.contract_id = p_payload ->> 'contract_id' and w.division = (p_payload ->> 'division')::int and coalesce(w.store_id::text, '') = coalesce(p_payload ->> 'store_id', '') and w.effective_date <= p_effective_date
     order by w.effective_date desc limit 1;
    select s.corporation_id into v_corp from user_stores us join stores s on s.id = us.store_id where us.user_id = p_user order by us.is_primary desc, s.sort_order limit 1;
    v_ym := to_char(p_effective_date, 'YYYY-MM');
    if exists (select 1 from payroll_finalized f where f.year_month = v_ym and (v_corp is null or f.corporation_id = v_corp)) then v_warn := v_warn || text '適用開始月の給与は確定済みです（承認時に止まります。マスターが理由つきで明示したときだけ反映）'; end if;
    if p_effective_date < date_trunc('month', current_date)::date then v_warn := v_warn || text '適用開始日が過去の月です（さかのぼり分は自動では精算しません）'; end if;
    insert into profile_change_requests(user_id, field, old_value, new_value, payload, effective_date, request_reason, requested_by)
    values (p_user, 'wage', v_old::text, p_payload::text, p_payload, p_effective_date, nullif(trim(coalesce(p_reason, '')), ''), v_actor) returning id into v_id;
  else
    if coalesce(p_payload ->> 'payment_method', 'bank_transfer') = 'bank_transfer' and (nullif(p_payload ->> 'bank_code', '') is null or nullif(p_payload ->> 'branch_code', '') is null or nullif(p_payload ->> 'account_number', '') is null or nullif(p_payload ->> 'account_holder_kana', '') is null) then
      raise exception '口座の内容（銀行コード・支店コード・口座番号・名義カナ）が足りません';
    end if;
    if exists (select 1 from profile_change_requests where user_id = p_user and field = 'bank_account' and status = 'pending') then raise exception '口座変更の申請がすでに承認待ちです'; end if;
    -- 月は「希望」。どの支給回からにするかは、承認する人が必ず選んで確定する（未指定なら空のまま。自動では決めない）
    v_ym := nullif(trim(coalesce(p_year_month, '')), '');
    if v_ym is not null then
      if v_ym !~ '^\d{4}-\d{2}$' then raise exception '適用する月（YYYY-MM）が不正です'; end if;
      if pay_run_user_state(v_ym, p_user) = 'paid' then raise exception '% 月分の給与（% 支給）は支給日を過ぎています。次の支給回を選んでください', v_ym, pay_run_date(v_ym); end if;
      if pay_run_user_state(v_ym, p_user) = 'exported' then v_warn := v_warn || text '希望の支給回は振込データを出力済みです（この回から変えるには、本部の個別の確認・承認が必要です）'; end if;
    end if;
    select to_jsonb(b) - 'created_at' - 'updated_at' - 'updated_by' - 'user_id' into v_old from payroll_bank_accounts b where b.user_id = p_user;
    insert into profile_change_requests(user_id, field, old_value, new_value, payload, effective_year_month, effective_pay_date, request_reason, requested_by)
    values (p_user, 'bank_account', v_old::text, p_payload::text, p_payload, v_ym, case when v_ym is not null then pay_run_date(v_ym) end, nullif(trim(coalesce(p_reason, '')), ''), v_actor) returning id into v_id;
  end if;
  return jsonb_build_object('ok', true, 'request_id', v_id, 'warnings', to_jsonb(v_warn), 'effective_year_month', v_ym, 'effective_pay_date', case when p_kind = 'bank_account' and v_ym is not null then pay_run_date(v_ym) end);
end $$;

-- ============ 4. 口座の反映（承認済みの申請だけ。締め済みは書かない・前の支給回が済むまで予約） ============
-- 登録口座への書き込み（承認の処理からだけ呼ぶ）＋履歴に申請者・承認者をひも付ける
create or replace function hr_bank_change_write(p_request uuid, p_actor uuid default null)
returns void language plpgsql security definer set search_path = public as $$
declare q profile_change_requests%rowtype; b jsonb;
begin
  select * into q from profile_change_requests where id = p_request;
  b := coalesce(q.payload, q.new_value::jsonb);
  perform set_config('employee_change.via_approval', q.id::text, true);
  insert into payroll_bank_accounts(user_id, bank_code, bank_name, branch_code, branch_name, account_type, account_number, account_holder_kana, payment_method, updated_by, updated_at)
  values (q.user_id, b ->> 'bank_code', b ->> 'bank_name', b ->> 'branch_code', b ->> 'branch_name', coalesce(b ->> 'account_type', '1'), b ->> 'account_number', b ->> 'account_holder_kana', coalesce(b ->> 'payment_method', 'bank_transfer'), coalesce(q.reviewed_by, p_actor), now())
  on conflict (user_id) do update set bank_code = excluded.bank_code, bank_name = excluded.bank_name, branch_code = excluded.branch_code, branch_name = excluded.branch_name, account_type = excluded.account_type,
    account_number = excluded.account_number, account_holder_kana = excluded.account_holder_kana, payment_method = excluded.payment_method, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  perform set_config('employee_change.via_approval', '', true);
  update employee_change_events set source = 'request', request_table = 'profile_change_requests', request_id = q.id, requested_by = q.requested_by, requested_at = q.requested_at,
         approved_by = q.reviewed_by, approved_at = q.reviewed_at, effective_date = q.effective_pay_date
   where user_id = q.user_id and field_group = 'bank_account' and txid = txid_current();
end $$;
-- 例外: 振込データを出力済み（支給日前）の回から口座を変える。本部の個別の確認・承認（理由つき）があるときだけ呼ばれる。
--   登録口座をすぐ書き換え、その回の控えを「個別承認」として差し替える（前の控えも残す）。出力済みのファイル自体は変わらない＝出し直しが必要
create or replace function hr_bank_change_apply_exception(p_request uuid, p_year_month text, p_actor uuid, p_reason text)
returns text language plpgsql security definer set search_path = public as $$
declare q profile_change_requests%rowtype; v_new jsonb;
begin
  select * into q from profile_change_requests where id = p_request for update;
  if q.id is null or q.field <> 'bank_account' or q.status <> 'approved' then raise exception '対象が見つかりません'; end if;
  if pay_run_user_state(p_year_month, q.user_id) <> 'exported' then raise exception 'この支給回は個別承認の対象ではありません'; end if;
  if nullif(trim(coalesce(p_reason, '')), '') is null then raise exception '個別の確認・承認には理由が必要です'; end if;
  update profile_change_requests set effective_year_month = p_year_month, effective_pay_date = pay_run_date(p_year_month) where id = q.id;
  perform hr_bank_change_write(q.id, p_actor);
  select to_jsonb(b) - 'created_at' - 'updated_at' - 'updated_by' - 'user_id' into v_new from payroll_bank_accounts b where b.user_id = q.user_id;
  perform set_config('employee_change.via_approval', q.id::text, true);   -- 控えの差し替えは、この例外承認の処理からだけ
  insert into payroll_transfer_account_snapshots(year_month, user_id, account, taken_by, source, request_id, note)
  values (p_year_month, q.user_id, v_new, p_actor, 'exception', q.id, trim(p_reason))
  on conflict (year_month, user_id) do update set previous_account = payroll_transfer_account_snapshots.account, account = excluded.account, taken_at = now(), taken_by = excluded.taken_by, source = 'exception', request_id = excluded.request_id, note = excluded.note;
  perform set_config('employee_change.via_approval', '', true);
  update profile_change_requests set apply_status = 'applied', applied_at = now(),
         apply_note = p_year_month || ' 月分（' || pay_run_date(p_year_month) || ' 支給）は振込データ出力済み → 個別の確認・承認で反映（理由: ' || trim(p_reason) || '）。出力済みの振込ファイルは自動では変わりません。振込データを出し直してください' where id = q.id;
  return 'applied';
end $$;
create or replace function hr_bank_change_try_apply(p_request uuid, p_actor uuid default null)
returns text language plpgsql security definer set search_path = public as $$
declare q profile_change_requests%rowtype; v_prev text; v_status text;
begin
  select * into q from profile_change_requests where id = p_request for update;
  if q.id is null or q.field <> 'bank_account' or q.status <> 'approved' or q.apply_status = 'applied' then return q.apply_status; end if;
  if q.effective_year_month is null then return q.apply_status; end if;   -- 支給回が決まっていない承認は無い（承認のときに必ず選ぶ）
  v_prev := to_char(to_date(q.effective_year_month || '-01', 'YYYY-MM-DD') - interval '1 month', 'YYYY-MM');
  if pay_run_user_state(q.effective_year_month, q.user_id) <> 'open' then
    v_status := 'blocked_exported';   -- その支給回は出力済み／支給日を過ぎた → 自動では書かない（競合。本部に対応を求める）
    update profile_change_requests set apply_status = v_status, apply_note = q.effective_year_month || ' 月分（' || pay_run_date(q.effective_year_month) || ' 支給）は振込データを出力済みか支給日を過ぎています。支給回を選び直すか、個別の確認・承認をしてください' where id = q.id;
  elsif pay_run_user_state(v_prev, q.user_id) = 'open' then
    v_status := 'scheduled';          -- 前の支給回がまだ（この人の分が未確定）→ 今の口座は書き換えない（前の回の振込データを出力した直後に切り替わる）
    update profile_change_requests set apply_status = v_status, apply_note = v_prev || ' 月分の振込データを出力したあとに切り替わります（' || pay_run_date(q.effective_year_month) || ' 支給分から新しい口座）' where id = q.id;
  else
    perform hr_bank_change_write(q.id, p_actor);
    v_status := 'applied';
    update profile_change_requests set apply_status = v_status, applied_at = now(), apply_note = pay_run_date(q.effective_year_month) || ' 支給分から新しい口座' where id = q.id;
  end if;
  return v_status;
end $$;

-- ============ 5. 承認・却下 ============
--   口座: p_year_month＝どの支給回（何月分の給与）から新しい口座にするか。承認する人が必ず選ぶ（未指定はエラー。自動では決めない）
--         出力済み（支給日前）の回を選ぶのは例外 → p_force_closed=true と理由があるときだけ（本部の個別の確認・承認）
create or replace function hr_pay_change_review(p_request uuid, p_approve boolean, p_reason text default null, p_actor uuid default null, p_force_closed boolean default false, p_year_month text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_actor uuid; q profile_change_requests%rowtype; v_master boolean; v_corp uuid; v_ym text; r jsonb; v_apply text; v_state text;
begin
  v_actor := public.onboarding_resolve_actor(p_actor);
  select coalesce(is_master, false) into v_master from users where id = v_actor;
  select * into q from profile_change_requests where id = p_request and status = 'pending' for update;
  if q.id is null then raise exception '対象の申請が見つからないか、既に処理済みです'; end if;
  if q.field not in ('wage', 'bank_account') then raise exception 'この申請は対象外です'; end if;
  if not p_approve then
    if nullif(trim(coalesce(p_reason, '')), '') is null then raise exception '却下の理由を入れてください'; end if;
    update profile_change_requests set status = 'rejected', reviewed_by = v_actor, reviewed_at = now(), reject_reason = trim(p_reason) where id = q.id;
    return jsonb_build_object('ok', true, 'status', 'rejected');
  end if;
  -- 2 人目の確認: 申請した本人は承認できない（マスターだけは自分の申請も承認できる＝申請と承認の両方が記録に残る）
  if q.requested_by = v_actor and not v_master then raise exception '申請した人とは別の人が承認してください'; end if;
  if q.field = 'bank_account' and q.user_id = v_actor and not v_master then raise exception '自分の口座の変更は自分では承認できません'; end if;
  if q.field = 'wage' then
    v_ym := to_char(q.effective_date, 'YYYY-MM');
    select s.corporation_id into v_corp from user_stores us join stores s on s.id = us.store_id where us.user_id = q.user_id order by us.is_primary desc, s.sort_order limit 1;
    if exists (select 1 from payroll_finalized f where f.year_month = v_ym and (v_corp is null or f.corporation_id = v_corp)) then
      if not (coalesce(p_force_closed, false) and v_master and nullif(trim(coalesce(p_reason, '')), '') is not null) then
        update profile_change_requests set apply_status = 'blocked_finalized', apply_note = v_ym || ' の給与は確定済みのため自動では反映しません（適用開始日を変えて申請し直すか、マスターが理由つきで明示して承認）' where id = q.id;
        return jsonb_build_object('ok', false, 'blocked', 'finalized', 'error', v_ym || ' の給与は確定済みです。自動では上書きしません');
      end if;
    end if;
    update profile_change_requests set status = 'approved', reviewed_by = v_actor, reviewed_at = now(), reject_reason = null,
           apply_note = case when coalesce(p_force_closed, false) then '確定済みの月への反映をマスターが承認: ' || trim(p_reason) else null end where id = q.id;
    perform set_config('employee_change.via_approval', q.id::text, true);
    r := hr_save_wage(q.user_id, q.payload ->> 'contract_id', (q.payload ->> 'division')::int, nullif(q.payload ->> 'store_id', '')::uuid, (q.payload ->> 'wage')::int, nullif(q.payload ->> 'holiday_wage', '')::int, q.effective_date, v_actor);
    perform set_config('employee_change.via_approval', '', true);
    update profile_change_requests set apply_status = 'applied', applied_at = now(), apply_ref = jsonb_build_object('wage_setting_id', r ->> 'id') where id = q.id;
    update employee_change_events set source = 'request', request_table = 'profile_change_requests', request_id = q.id, requested_by = q.requested_by, requested_at = q.requested_at, approved_by = v_actor, approved_at = now()
     where user_id = q.user_id and field_group = 'wage' and txid = txid_current();
    -- スマレジへの同期はここでは行わない（登録された行は sync_status=pending。既存の賃金同期＝wage_push → 読み戻し wage_pull が拾う）
    return jsonb_build_object('ok', true, 'status', 'approved', 'apply_status', 'applied', 'wage_setting_id', r ->> 'id', 'sync', 'pending');
  end if;
  -- 口座: ここで支給回を確定する
  v_ym := nullif(trim(coalesce(p_year_month, '')), '');
  if v_ym is null then raise exception '適用する支給回（何月分の給与から新しい口座にするか）を選んでから承認してください'; end if;
  if v_ym !~ '^\d{4}-\d{2}$' then raise exception '適用する月（YYYY-MM）が不正です'; end if;
  v_state := pay_run_user_state(v_ym, q.user_id);
  if v_state = 'paid' then raise exception '% 月分の給与（% 支給）は支給日を過ぎています。次の支給回を選んでください', v_ym, pay_run_date(v_ym); end if;
  if v_state = 'exported' then
    if not (coalesce(p_force_closed, false) and nullif(trim(coalesce(p_reason, '')), '') is not null) then
      return jsonb_build_object('ok', false, 'blocked', 'exported', 'year_month', v_ym, 'pay_date', pay_run_date(v_ym), 'next_open', pay_run_next_open(),
        'error', v_ym || ' 月分（' || pay_run_date(v_ym) || ' 支給）は振込データを出力済みです。次の支給回からにするか、個別の確認・承認（理由つき）をしてください');
    end if;
    update profile_change_requests set status = 'approved', reviewed_by = v_actor, reviewed_at = now(), reject_reason = null where id = q.id;
    v_apply := hr_bank_change_apply_exception(q.id, v_ym, v_actor, p_reason);
  else
    update profile_change_requests set status = 'approved', reviewed_by = v_actor, reviewed_at = now(), reject_reason = null, effective_year_month = v_ym, effective_pay_date = pay_run_date(v_ym) where id = q.id;
    v_apply := hr_bank_change_try_apply(q.id, v_actor);
  end if;
  return jsonb_build_object('ok', true, 'status', 'approved', 'apply_status', v_apply, 'year_month', v_ym, 'pay_date', pay_run_date(v_ym), 'note', (select apply_note from profile_change_requests where id = q.id));
end $$;

-- 予約中の口座変更のうち、前の支給回が済んだものを反映（振込データの出力直後に自動で呼ばれる。本部が手で呼ぶこともできる）
create or replace function hr_apply_due_bank_changes_internal() returns integer language plpgsql security definer set search_path = public as $$
declare x record; n integer := 0;
begin
  for x in select id from profile_change_requests where field = 'bank_account' and status = 'approved' and apply_status = 'scheduled' order by reviewed_at loop
    if hr_bank_change_try_apply(x.id, null) = 'applied' then n := n + 1; end if;
  end loop;
  return n;
end $$;
create or replace function hr_apply_due_bank_changes(p_actor uuid default null) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform public.onboarding_resolve_actor(p_actor);
  return jsonb_build_object('ok', true, 'applied', hr_apply_due_bank_changes_internal());
end $$;
-- 一度決めた支給回を変える（予約中の変更・競合で止まった変更）。明示的な例外承認＝理由が必須・申請した人／本人とは別の人（マスターは可）。変更の記録を残す
--   出力済み（支給日前）の回にするときは、さらに p_force_closed=true（確定した振込先の差し替え）
create or replace function hr_bank_change_reschedule(p_request uuid, p_year_month text, p_actor uuid default null, p_force_closed boolean default false, p_reason text default null) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_actor uuid; q profile_change_requests%rowtype; v_master boolean; v_state text; v_hist jsonb;
begin
  v_actor := public.onboarding_resolve_actor(p_actor);
  select coalesce(is_master, false) into v_master from users where id = v_actor;
  select * into q from profile_change_requests where id = p_request and field = 'bank_account' and status = 'approved' and apply_status in ('blocked_exported', 'scheduled') for update;
  if q.id is null then raise exception '対象が見つかりません'; end if;
  if p_year_month !~ '^\d{4}-\d{2}$' then raise exception '適用する月（YYYY-MM）が不正です'; end if;
  if nullif(trim(coalesce(p_reason, '')), '') is null then raise exception '一度決めた支給回を変えるには、理由が必要です（例外承認）'; end if;
  if (q.requested_by = v_actor or q.user_id = v_actor) and not v_master then raise exception '一度決めた支給回の変更（例外承認）は、申請した人・本人とは別の人が行ってください'; end if;
  v_state := pay_run_user_state(p_year_month, q.user_id);
  if v_state = 'paid' then raise exception 'その支給回は選べません（支給日を過ぎています）'; end if;
  v_hist := coalesce(q.apply_ref, '{}'::jsonb) || jsonb_build_object('reschedules', coalesce(q.apply_ref -> 'reschedules', '[]'::jsonb)
            || jsonb_build_object('from', q.effective_year_month, 'to', p_year_month, 'by', v_actor, 'at', now(), 'reason', trim(p_reason)));
  if v_state = 'exported' then
    if not coalesce(p_force_closed, false) then
      return jsonb_build_object('ok', false, 'blocked', 'exported', 'error', p_year_month || ' 月分は振込データを出力済みです。別の支給回にするか、確定した振込先を差し替える個別の確認・承認をしてください');
    end if;
    update profile_change_requests set apply_ref = v_hist where id = q.id;
    return jsonb_build_object('ok', true, 'apply_status', hr_bank_change_apply_exception(q.id, p_year_month, v_actor, p_reason));
  end if;
  update profile_change_requests set effective_year_month = p_year_month, effective_pay_date = pay_run_date(p_year_month), apply_status = 'none', apply_ref = v_hist where id = q.id;
  return jsonb_build_object('ok', true, 'apply_status', hr_bank_change_try_apply(q.id, v_actor));
end $$;
-- 取り下げ（承認待ちのあいだだけ。申請者本人か本部）
create or replace function hr_pay_change_cancel(p_request uuid, p_actor uuid default null) returns jsonb language plpgsql security definer set search_path = public as $$
declare q profile_change_requests%rowtype; v_actor uuid;
begin
  select * into q from profile_change_requests where id = p_request and field in ('wage', 'bank_account') and status = 'pending' for update;
  if q.id is null then raise exception '対象の申請が見つからないか、既に処理済みです'; end if;
  if auth.uid() is not null and auth.uid() = q.requested_by then v_actor := auth.uid(); else v_actor := public.onboarding_resolve_actor(p_actor); end if;
  update profile_change_requests set status = 'cancelled', reviewed_by = v_actor, reviewed_at = now() where id = q.id;
  return jsonb_build_object('ok', true);
end $$;

-- ============ 6. 振込データの出力（既存: payroll_transfer_schedule に行が出来る）に合わせて、口座の控え・除外の記録・予約の実行 ============
-- 出力の記録の前処理: ⑤停止中は受け付けない ⑥出力の印を確かめる（無ければ「確定として扱わない」印を付ける）
--   全員分が必要な運用（transfer_pending_mode='block_all'）: 未承認の口座変更がこの回に影響する人がいるあいだ、確定を止める
create or replace function payroll_transfer_schedule_guard() returns trigger language plpgsql security definer set search_path = public as $$
declare v_names text; v_tok payroll_transfer_export_tokens%rowtype; v_valid boolean := false;
begin
  if coalesce(current_setting('employee_change.schedule_internal', true), '') <> '' then return new; end if;   -- 【要確認】タスクの印を付けるだけの内部の更新
  if pay_transfer_paused() then raise exception '切り替え作業中のため、振込 CSV の出力は一時停止しています。この CSV は使わないでください。再開の連絡のあと、画面を再読み込みしてから出力してください'; end if;
  if new.export_token is not null and (tg_op = 'INSERT' or new.export_token is distinct from old.export_token) then
    select * into v_tok from payroll_transfer_export_tokens t where t.token = new.export_token and t.year_month = new.year_month and t.user_id = auth.uid() and t.used_at is null and t.issued_at > now() - interval '2 hours' for update;
    v_valid := v_tok.token is not null;
  end if;
  if not v_valid then
    -- 古い画面・直接の API からの出力。記録は残すが、確定としては扱わない（控え・除外の処理をしない）。後処理で【要確認】のタスクを出す
    new.export_ok := case when tg_op = 'UPDATE' then old.export_ok else false end;
    new.export_token := case when tg_op = 'UPDATE' then old.export_token else null end;
    new.invalid_export_at := clock_timestamp();
    return new;
  end if;
  if coalesce((select value ->> 'transfer_pending_mode' from app_settings where key = 'employee_change'), 'exclude') = 'block_all' then
    select string_agg((select name from users u where u.id = h.user_id), '、') into v_names from pay_transfer_pending_holds(new.year_month) h;
    if v_names is not null then raise exception '% 月分の振込データは確定できません。口座変更の申請が承認待ちの人がいます（%）。承認または却下してから出力してください', new.year_month, v_names; end if;
  end if;
  new.export_ok := true;   -- 印を「使用済み」にするのは後処理で（画面の記録は「追加 → 既にあれば更新」の 2 段階で、前処理が 2 回走るため）
  return new;
end $$;
drop trigger if exists payroll_transfer_schedule_guard on payroll_transfer_schedule;
create trigger payroll_transfer_schedule_guard before insert or update on payroll_transfer_schedule for each row execute function payroll_transfer_schedule_guard();

-- 印の無い出力（古い画面・直接の API）があったときの本部タスク。そのファイルは除外・控えの確認を通っていない
create or replace function pay_transfer_invalid_export_task(p_year_month text) returns uuid language plpgsql security definer set search_path = public as $$
declare v_task uuid; v_assignee uuid;
begin
  select s.invalid_task_id into v_task from payroll_transfer_schedule s join hq_tasks k on k.id = s.invalid_task_id where s.year_month = p_year_month and k.status <> 'done' and k.deleted_at is null;
  if v_task is not null then return v_task; end if;   -- 開いているタスクがあれば二重に作らない
  select u.id into v_assignee from users u where u.name in ('青山純', '原　美香', '齋藤　隆治') and u.is_active order by array_position(array['青山純', '原　美香', '齋藤　隆治'], u.name) limit 1;
  insert into hq_tasks(title, corp, freq, target_date, due_date, notes, description, visibility, created_by, is_urgent)
  values ('【要確認】' || p_year_month || ' 月分の給与振込 CSV が、古い画面から出力されました', 'トーホー', 'once', current_date, current_date, '',
          p_year_month || ' 月分の給与振込 CSV が、更新前の古い画面（または正しい手順を通らない操作）から出力されました。' || E'\n'
          || 'そのファイルは、口座変更の承認待ちの人の除外や、確定済みの振込先の確認を通っていません。' || E'\n'
          || '① そのファイルは銀行に取り込まない（取り込み済みなら、すぐに本部の責任者へ連絡）② 振込画面を再読み込み（Cmd+Shift+R）してから、もう一度出力する ③ 確認できたら、このタスクを完了にする。', 'all', auth.uid(), true)
  returning id into v_task;
  insert into hq_task_steps(task_id, title, assignee_id, sort_order, kind, due_date) values (v_task, '古い画面から出力したファイルを使っていないことを確認し、出力し直す', v_assignee, 10, 'step', current_date);
  insert into hq_task_activity(task_id, actor_id, kind, detail) values (v_task, auth.uid(), 'create', '印の無い振込 CSV 出力を検知したため自動作成');
  perform set_config('employee_change.schedule_internal', '1', true);
  update payroll_transfer_schedule set invalid_task_id = v_task where year_month = p_year_month;
  perform set_config('employee_change.schedule_internal', '', true);
  return v_task;
end $$;

-- 除外した人がいるときの本部タスク（振込漏れ防止）。支給回ごとに 1 件・人ごとにチェック項目。出力という人の操作の結果なので、通知フラグに関係なく作る
create or replace function pay_transfer_hold_task_sync(p_year_month text) returns uuid language plpgsql security definer set search_path = public as $$
declare v_task uuid; v_step uuid; h record; v_item uuid; v_assignee uuid; v_open int; v_cstep uuid; v_title text;
begin
  -- 既存の「給与振込確認」タスク（出力のたびに作られる／更新される）。除外した人を「未振込」として載せる
  select st.id into v_cstep from transfer_confirm_task_links l join hq_tasks k on k.id = l.hq_task_id join hq_task_steps st on st.task_id = k.id
   where l.kind = 'payroll' and l.scope_key = p_year_month and k.deleted_at is null order by st.sort_order limit 1;
  for h in select * from payroll_transfer_holds where year_month = p_year_month loop
    v_title := '⚠️ 未振込: ' || coalesce((select name from users where id = h.user_id), '—') || 'さん（口座変更の承認待ちで除外）';
    if v_cstep is not null then
      if h.status in ('held', 'ready') and not exists (select 1 from hq_step_checklist_items c where c.step_id = v_cstep and c.title = v_title) then
        insert into hq_step_checklist_items(step_id, title, sort_order) values (v_cstep, v_title, 5);
      elsif h.status = 'done' then
        update hq_step_checklist_items set checked_at = now(), checked_by = auth.uid() where step_id = v_cstep and title = v_title and checked_at is null;
      end if;
    end if;
  end loop;
  select hq_task_id into v_task from payroll_transfer_holds where year_month = p_year_month and hq_task_id is not null limit 1;
  if v_task is null then
    if not exists (select 1 from payroll_transfer_holds where year_month = p_year_month and status in ('held', 'ready')) then return null; end if;
    select u.id into v_assignee from users u where u.name in ('青山純', '原　美香', '齋藤　隆治') and u.is_active order by array_position(array['青山純', '原　美香', '齋藤　隆治'], u.name) limit 1;
    insert into hq_tasks(title, corp, freq, target_date, due_date, notes, description, visibility, created_by, is_urgent)
    values ('【振込漏れ注意】' || p_year_month || ' 月分の給与振込: 口座変更の確認待ちで除外した人がいます', 'トーホー', 'once', current_date, least(pay_run_date(p_year_month), current_date + 3), '',
            p_year_month || ' 月分（' || pay_run_date(p_year_month) || ' 支給）の振込データから、口座変更の申請が承認待ちの人を除外しました。このままでは、その人に振り込まれません。'
            || E'\n' || '① 従業員ページで口座変更の申請を承認（どの支給回からかを選ぶ）または却下する ② 振込画面で「除外していた人の分を出力」して振り込む。'
            || E'\n' || '②まで終わると、このタスクのチェックは自動で付きます。口座番号などはここには表示しません。', 'all', auth.uid(), true)
    returning id into v_task;
    insert into hq_task_steps(task_id, title, assignee_id, sort_order, kind, due_date) values (v_task, '除外した人の申請を処理し、その人の分の振込データを出力する', v_assignee, 10, 'step', least(pay_run_date(p_year_month), current_date + 3)) returning id into v_step;
    insert into hq_task_activity(task_id, actor_id, kind, detail) values (v_task, auth.uid(), 'create', '振込データの出力で除外した人がいるため自動作成');
  else
    select id into v_step from hq_task_steps where task_id = v_task order by sort_order limit 1;
  end if;
  for h in select * from payroll_transfer_holds where year_month = p_year_month loop
    if h.checklist_item_id is null then
      insert into hq_step_checklist_items(step_id, title, sort_order) values (v_step, coalesce((select name from users where id = h.user_id), '—') || 'さん', 10) returning id into v_item;
      update payroll_transfer_holds set hq_task_id = v_task, checklist_item_id = v_item where year_month = h.year_month and user_id = h.user_id;
      h.checklist_item_id := v_item;
    end if;
    if h.status = 'done' then update hq_step_checklist_items set checked_at = coalesce(checked_at, now()), checked_by = coalesce(checked_by, auth.uid()) where id = h.checklist_item_id; end if;
  end loop;
  select count(*) into v_open from payroll_transfer_holds where year_month = p_year_month and status in ('held', 'ready');
  if v_open = 0 then update hq_task_steps set completed_at = now(), completed_by = auth.uid() where task_id = v_task and completed_at is null; end if;
  return v_task;
end $$;

-- 除外した人（held／ready）が残っているあいだ、その月の「給与振込確認」タスクは完了にできない（未解決のまま振込完了扱いにしない）
create or replace function payroll_transfer_confirm_step_guard() returns trigger language plpgsql security definer set search_path = public as $$
declare v_ym text; v_names text;
begin
  if not (new.completed_at is not null and old.completed_at is null) then return new; end if;
  begin
    select l.scope_key into v_ym from transfer_confirm_task_links l where l.kind = 'payroll' and l.hq_task_id = new.task_id limit 1;
    if v_ym is not null then
      select string_agg((select name from users u where u.id = h.user_id) || 'さん', '、') into v_names from payroll_transfer_holds h where h.year_month = v_ym and h.status in ('held', 'ready');
    end if;
  exception when others then v_names := null;   -- 判定そのものの失敗では、本部タスクの操作を止めない
  end;
  if v_names is not null then
    raise exception '% 月分の給与振込は、まだ完了にできません。口座変更の承認待ちで振込データから除外した人の振込が済んでいません（%）。申請を承認または却下し、振込画面で「除外していた人の分を出力」して振り込んでから完了にしてください', v_ym, v_names;
  end if;
  return new;
end $$;
drop trigger if exists payroll_transfer_confirm_step_guard on hq_task_steps;
create trigger payroll_transfer_confirm_step_guard before update of completed_at on hq_task_steps for each row execute function payroll_transfer_confirm_step_guard();

create or replace function payroll_transfer_schedule_after() returns trigger language plpgsql security definer set search_path = public as $$
declare v_new int := 0; v_on boolean; v_holds uuid[];
begin
  if coalesce(current_setting('employee_change.schedule_internal', true), '') <> '' then return null; end if;   -- 【要確認】タスクの印を付けるだけの内部の更新
  begin
    if new.invalid_export_at is not null and (tg_op = 'INSERT' or new.invalid_export_at is distinct from old.invalid_export_at) then
      -- ⑥ 印の無い出力: 確定として扱わない（控え・除外の処理をしない）。本部に知らせる
      perform pay_transfer_invalid_export_task(new.year_month);
      return null;
    end if;
    if new.export_ok is not true then return null; end if;
    if exists (select 1 from payroll_transfer_export_tokens t where t.token = new.export_token and t.used_at is not null) then return null; end if;   -- 同じ印では 1 回だけ処理する
    update payroll_transfer_export_tokens set used_at = now() where token = new.export_token;
    -- ① 画面に「除外する」と伝えた人（出力の印に控えてある）を、除外として記録。その後に申請が片付いていれば「その人の分が未出力」から始める
    select t.hold_users into v_holds from payroll_transfer_export_tokens t where t.token = new.export_token;
    with ins as (
      insert into payroll_transfer_holds(year_month, user_id, request_id, status, resolved_at)
      select new.year_month, u.id,
             (select q.id from profile_change_requests q where q.user_id = u.id and q.field = 'bank_account' order by (q.status = 'pending') desc, q.requested_at desc limit 1),
             case when exists (select 1 from profile_change_requests q where q.user_id = u.id and q.field = 'bank_account' and q.status = 'pending') then 'held' else 'ready' end,
             case when exists (select 1 from profile_change_requests q where q.user_id = u.id and q.field = 'bank_account' and q.status = 'pending') then null else now() end
        from unnest(coalesce(v_holds, '{}')) as u(id)
       where not exists (select 1 from payroll_transfer_account_snapshots sn where sn.year_month = new.year_month and sn.user_id = u.id)
      on conflict (year_month, user_id) do update set request_id = excluded.request_id, status = excluded.status, resolved_at = excluded.resolved_at where payroll_transfer_holds.status <> excluded.status and payroll_transfer_holds.status <> 'done'
      returning 1)
    select count(*) into v_new from ins;
    -- ② それ以外の人の口座の控え（最初の出力時点のもの。出し直しても自動では変えない。出力後に口座を登録した人・除外が解けた人だけ足される）
    insert into payroll_transfer_account_snapshots(year_month, user_id, account, taken_by)
    select new.year_month, b.user_id, to_jsonb(b) - 'created_at' - 'updated_at' - 'updated_by' - 'user_id', auth.uid() from payroll_bank_accounts b
     where not (b.user_id = any(coalesce(v_holds, '{}')))
    on conflict (year_month, user_id) do nothing;
    -- ③ 除外が解けていた人（ready）は、今回の出力で振込データに入った＝完了
    update payroll_transfer_holds h set status = 'done', done_at = now() where h.year_month = new.year_month and h.status = 'ready' and not (h.user_id = any(coalesce(v_holds, '{}')))
       and exists (select 1 from payroll_transfer_account_snapshots s where s.year_month = h.year_month and s.user_id = h.user_id);
    perform pay_transfer_hold_task_sync(new.year_month);
    if v_new > 0 then
      select coalesce((value ->> 'pay_request_notify_enabled')::boolean, false) into v_on from app_settings where key = 'employee_change';
      if coalesce(v_on, false) then perform pay_change_notify_op('transfer_hold', jsonb_build_object('year_month', new.year_month)); end if;
    end if;
    perform hr_apply_due_bank_changes_internal();   -- この回の出力が済んだので、次の回からの予約を反映
  exception when others then perform employee_change_log_error('payroll_transfer_schedule', lower(tg_op), null, sqlerrm);
  end;
  return null;
end $$;
drop trigger if exists payroll_transfer_schedule_after on payroll_transfer_schedule;
create trigger payroll_transfer_schedule_after after insert or update on payroll_transfer_schedule for each row execute function payroll_transfer_schedule_after();

-- ⑦ 口座変更の申請が承認待ちの人の登録口座は、画面からの直接の読み出しでは返さない（古い画面でも、その人は振込データに入らない）。
--    ⑤ 出力の一時停止中は、誰の口座も直接は返さない。承認の処理・控え・一覧の関数は影響を受けない（関数の中から読むため）
create or replace function pay_bank_row_visible(p_user uuid) returns boolean language sql stable security definer set search_path = public as $$
  select not pay_transfer_paused() and not exists (select 1 from profile_change_requests q where q.user_id = p_user and q.field = 'bank_account' and q.status = 'pending')
$$;
drop policy if exists pba_pay_change_guard on payroll_bank_accounts;
create policy pba_pay_change_guard on payroll_bank_accounts as restrictive for select to authenticated using (pay_bank_row_visible(user_id));

-- ⑧ 口座・賃金の申請の行は、画面・API から直接は書けない（申請・承認の関数だけが書く）。氏名・住所などの申請の行は従来どおり
create or replace function pay_change_request_direct_guard() returns trigger language plpgsql as $$
begin
  if current_user = 'authenticated' and coalesce(case when tg_op = 'DELETE' then old.field else new.field end, '') in ('bank_account', 'wage') then
    raise exception '口座・賃金の変更申請は、申請・承認の画面からだけ操作できます（直接の書き換えはできません）';
  end if;
  return coalesce(new, old);
end $$;
drop trigger if exists pay_change_request_direct_guard on profile_change_requests;
create trigger pay_change_request_direct_guard before insert or update or delete on profile_change_requests for each row execute function pay_change_request_direct_guard();

-- ============ 7. 直接編集の禁止（承認必須化）。既定 OFF＝これまでどおり（履歴は残る） ============
-- 直接の登録・編集を通してよいか（フラグ ON のとき）: 入社手続き中の人／その人（賃金はその契約）の初回の登録
create or replace function employee_change_pay_direct_allowed(p_table text, p_user uuid, p_contract text default null) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from onboarding_workflows w where w.user_id = p_user and w.status in ('hired_confirmed', 'form_sent', 'registering'))
      or case when p_table = 'payroll_bank_accounts' then not exists (select 1 from payroll_bank_accounts b where b.user_id = p_user)
              else not exists (select 1 from employee_wage_settings w where w.user_id = p_user and (p_contract is null or w.contract_id = p_contract)) end
$$;
-- 止めるのは「人の直接編集」だけ:
--   ・ログインしている人の書き込み（nippo・振込画面・hr_save_wage）
--   ・Slack の賃金設定（サービス経由の hr_save_wage＝新しい行に created_by が入る）
-- 通すもの（誤って止めない）:
--   ・承認の処理からの書き込み／同期状態だけの更新
--   ・システム処理（スマレジからの賃金取込 wage_pull・賃金同期 wage_push の更新・入社フォームの口座登録など＝ログインなし・created_by なし）
--   ・入社時の初期登録・入社手続き中の修正（employee_change_pay_direct_allowed）
create or replace function employee_change_pay_guard() returns trigger language plpgsql security definer set search_path = public as $$
declare v_on boolean; v_user uuid; v_contract text; v_human boolean;
begin
  select coalesce((value ->> case when tg_table_name = 'payroll_bank_accounts' then 'bank_approval_required' else 'wage_approval_required' end)::boolean, false) into v_on from app_settings where key = 'employee_change';
  if not coalesce(v_on, false) then return coalesce(new, old); end if;
  if coalesce(current_setting('employee_change.via_approval', true), '') <> '' then return coalesce(new, old); end if;   -- 承認の処理からの書き込み
  if tg_op = 'DELETE' then v_user := old.user_id; else v_user := new.user_id; end if;
  v_human := auth.uid() is not null;
  if tg_table_name = 'employee_wage_settings' then
    if tg_op = 'UPDATE' and (new.wage, new.holiday_wage, new.effective_date, new.division, new.store_id, new.contract_id) is not distinct from (old.wage, old.holiday_wage, old.effective_date, old.division, old.store_id, old.contract_id) then return new; end if;   -- 同期状態だけの更新
    if tg_op = 'DELETE' then v_contract := old.contract_id; else v_contract := new.contract_id; end if;
    if tg_op = 'INSERT' and new.created_by is not null then v_human := true; end if;   -- Slack の賃金設定（サービス経由でも人の操作）
  end if;
  if not v_human then return coalesce(new, old); end if;                                 -- システム処理（スマレジ同期・取込）
  if employee_change_pay_direct_allowed(tg_table_name::text, v_user, v_contract) then return coalesce(new, old); end if;   -- 初期登録・入社手続き中
  raise exception '賃金・銀行口座の変更は「申請 → 承認」が必要です（従業員ページの変更申請から）';
end $$;
drop trigger if exists employee_change_pay_guard on employee_wage_settings;
create trigger employee_change_pay_guard before insert or update or delete on employee_wage_settings for each row execute function employee_change_pay_guard();
drop trigger if exists employee_change_pay_guard on payroll_bank_accounts;
create trigger employee_change_pay_guard before insert or update or delete on payroll_bank_accounts for each row execute function employee_change_pay_guard();

-- ============ 7b. 本部に対応を求めるもの（これがあるときだけ）: 承認漏れ・同期エラー・出力済みデータとの競合 ============
--   口座番号などは返さない（氏名と項目名だけ）。p_year_month を渡すと、その月の振込に関係する賃金の承認待ちだけに絞る
create or replace function hr_pay_change_attention_internal(p_year_month text default null)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('kind', x.kind, 'field', x.field, 'request_id', x.id, 'user_id', x.user_id, 'user_name', x.user_name, 'message', x.message) order by x.ord, x.requested_at), '[]'::jsonb)
  from (
    select q.id, q.field, q.user_id, q.requested_at, (select name from users u where u.id = q.user_id) user_name,
      case when q.apply_status in ('blocked_exported', 'blocked_finalized') then 'conflict'
           when q.status = 'pending' then 'unapproved' else 'sync_error' end kind,
      case when q.apply_status in ('blocked_exported', 'blocked_finalized') then 1 when q.status = 'pending' then 2 else 3 end ord,
      case when q.apply_status = 'blocked_exported' then '口座変更が未反映です（決めた支給回は振込データ出力済み）。支給回を選び直すか、個別の確認・承認をしてください'
           when q.apply_status = 'blocked_finalized' then '賃金変更が未反映です（適用開始月の給与が確定済み）'
           when q.status = 'pending' and q.field = 'bank_account' then '口座変更の申請が承認待ちです（承認されるまで今の口座のまま振り込みます）'
           when q.status = 'pending' then '賃金変更の申請が承認待ちです（適用開始日 ' || coalesce(q.effective_date::text, '—') || '）'
           else 'スマレジへの賃金の同期がエラーです（賃金カードから再実行してください）' end message
    from profile_change_requests q
    where q.field in ('wage', 'bank_account') and (
         (q.status = 'approved' and q.apply_status in ('blocked_exported', 'blocked_finalized'))
      or (q.status = 'pending' and (q.field = 'bank_account' or p_year_month is null or q.effective_date <= (to_date(p_year_month || '-01', 'YYYY-MM-DD') + interval '1 month' - interval '1 day')::date))
      or (q.status = 'approved' and q.field = 'wage' and q.apply_status = 'applied' and exists (select 1 from employee_wage_settings w where w.id = nullif(q.apply_ref ->> 'wage_setting_id', '')::uuid and w.sync_status = 'error')))
    union all
    -- 振込データから除外した人（振込漏れ防止）: 除外中／申請は片付いたが、その人の分の振込データがまだ
    select h.request_id, 'bank_account', h.user_id, h.created_at, (select name from users u where u.id = h.user_id), 'transfer_hold', 0,
      case when h.status = 'held' then h.year_month || ' 月分の振込データから除外中です（口座変更の申請が承認待ち）。このままでは振り込まれません'
           else h.year_month || ' 月分の振込データが未出力です（口座変更の申請は処理済み）。振込画面で「除外していた人の分を出力」してください' end
      || case when pay_run_state(h.year_month) = 'paid' then '【支給日（' || pay_run_date(h.year_month) || '）を過ぎています】' else '' end
    from payroll_transfer_holds h where h.status in ('held', 'ready')   -- 振込が済む（done）まで、支給日を過ぎても出し続ける
    union all
    -- 古い画面・直接の API からの出力（【要確認】のタスクを完了にするまで出し続ける）
    select null::uuid, 'bank_account', null::uuid, sc.invalid_export_at, '振込画面', 'invalid_export', 0,
      sc.year_month || ' 月分の振込 CSV が古い画面から出力されました。そのファイルは使わず、画面を再読み込みして出力し直してください（本部タスク【要確認】を確認）'
    from payroll_transfer_schedule sc where sc.invalid_export_at is not null and exists (select 1 from hq_tasks k where k.id = sc.invalid_task_id and k.status <> 'done' and k.deleted_at is null)
  ) x
$$;
create or replace function hr_pay_change_attention(p_year_month text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not (hq_can_manage() or invoice_can_access() or onboarding_is_service()) then raise exception '権限がありません'; end if;
  return hr_pay_change_attention_internal(p_year_month);
end $$;

-- 画面用の設定（切り替えフラグと、選べる支給回の一覧）。p_user を渡すと、その人についての支給回の状態と、直接編集してよいか（初期登録・入社手続き中）も返す
create or replace function hr_pay_change_config(p_user uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb; v_bank boolean; v_wage boolean;
begin
  if not (hq_can_manage() or invoice_can_access() or onboarding_is_service()) then raise exception '権限がありません'; end if;
  select value into v from app_settings where key = 'employee_change';
  v_bank := coalesce((v ->> 'bank_approval_required')::boolean, false); v_wage := coalesce((v ->> 'wage_approval_required')::boolean, false);
  return jsonb_build_object('ok', true, 'bank_approval_required', v_bank, 'wage_approval_required', v_wage,
    'transfer_pending_mode', coalesce(v ->> 'transfer_pending_mode', 'exclude'),
    'bank_direct_ok', not v_bank or (p_user is not null and employee_change_pay_direct_allowed('payroll_bank_accounts', p_user, null)),
    'wage_direct_contracts', case when not v_wage or p_user is null then null else (select coalesce(jsonb_agg(c.contract_id), '[]'::jsonb) from smaregi_contracts c where c.is_active and employee_change_pay_direct_allowed('employee_wage_settings', p_user, c.contract_id)) end,
    'next_open', pay_run_next_open(),
    'runs', (select jsonb_agg(jsonb_build_object('year_month', to_char(m, 'YYYY-MM'), 'pay_date', pay_run_date(to_char(m, 'YYYY-MM')),
                      'state', case when p_user is null then pay_run_state(to_char(m, 'YYYY-MM')) else pay_run_user_state(to_char(m, 'YYYY-MM'), p_user) end) order by m)
               from generate_series(date_trunc('month', current_date) - interval '2 month', date_trunc('month', current_date) + interval '2 month', interval '1 month') m
              where pay_run_state(to_char(m, 'YYYY-MM')) <> 'paid'));
end $$;

-- 振込の画面を開いたとき・出力の直前に呼ぶ（人の承認は挟まない・自動）:
--   ①承認済みで時期が来た口座変更を反映 ②その月が出力済みなら、出力時点の口座の控えを返す（出し直しは控えを使う＝あとで登録口座が変わっても自動では変わらない）
--   ③対応が必要なもの（承認漏れ・同期エラー・競合）があれば返す。無ければ空
create or replace function hr_payroll_transfer_prepare(p_year_month text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_applied integer := 0; v_snap jsonb; v_token uuid; v_hold uuid[];
begin
  if not (invoice_can_access() or onboarding_is_service()) then raise exception '権限がありません'; end if;
  if p_year_month !~ '^\d{4}-\d{2}$' then raise exception '月（YYYY-MM）が不正です'; end if;
  if pay_transfer_paused() then   -- ⑤ 切り替え作業中: 何もしないで「停止中」だけ返す
    return jsonb_build_object('ok', true, 'paused', true, 'year_month', p_year_month, 'attention', '[]'::jsonb, 'hold', '[]'::jsonb, 'ready', '[]'::jsonb, 'hold_records', '[]'::jsonb);
  end if;
  begin v_applied := hr_apply_due_bank_changes_internal();
  exception when others then perform employee_change_log_error('payroll_transfer_prepare', 'apply_due', null, sqlerrm); end;
  -- 口座の控えは、登録口座を読める人（マスター・本部）にだけ返す
  if (is_profile_approver() or onboarding_is_service()) and exists (select 1 from payroll_transfer_schedule where year_month = p_year_month and export_ok is not false) then
    select jsonb_object_agg(s.user_id, s.account || jsonb_build_object('user_id', s.user_id, '_source', s.source)) into v_snap from payroll_transfer_account_snapshots s where s.year_month = p_year_month;
  end if;
  -- ⑥ 出力の印を発行（この呼び出しのあとの出力 1 回ぶん。除外するよう伝えた人を控える）
  select coalesce(array_agg(h.user_id), '{}') into v_hold from pay_transfer_pending_holds(p_year_month) h;
  if auth.uid() is not null then
    delete from payroll_transfer_export_tokens where issued_at < now() - interval '2 days';
    insert into payroll_transfer_export_tokens(year_month, user_id, hold_users) values (p_year_month, auth.uid(), v_hold) returning token into v_token;
  end if;
  return jsonb_build_object('ok', true, 'paused', false, 'export_token', v_token, 'year_month', p_year_month, 'state', pay_run_state(p_year_month), 'pay_date', pay_run_date(p_year_month), 'applied', v_applied,
    'snapshot', v_snap, 'attention', hr_pay_change_attention_internal(p_year_month),
    -- hold=この回の振込データに入れてはいけない人（未承認の口座変更が影響）／ready=除外していたが申請が片付いた人（その人の分を出す）
    'hold', (select coalesce(jsonb_agg(jsonb_build_object('user_id', h.user_id, 'user_name', (select name from users u where u.id = h.user_id), 'request_id', h.request_id)), '[]'::jsonb) from pay_transfer_pending_holds(p_year_month) h),
    'ready', (select coalesce(jsonb_agg(jsonb_build_object('user_id', h.user_id, 'user_name', (select name from users u where u.id = h.user_id))), '[]'::jsonb) from payroll_transfer_holds h where h.year_month = p_year_month and h.status = 'ready'),
    'transfer_pending_mode', coalesce((select value ->> 'transfer_pending_mode' from app_settings where key = 'employee_change'), 'exclude'),
    -- 除外の記録（誰が・なぜ・いまの状況）。振込が済んだもの（done）も履歴として返す
    'hold_records', (select coalesce(jsonb_agg(jsonb_build_object('user_id', h.user_id, 'user_name', (select name from users u where u.id = h.user_id), 'status', h.status,
                       'reason', '口座変更の申請が承認待ちだったため（振込先が確定していない）',
                       'status_label', case h.status when 'held' then '除外中（申請の承認・却下が必要）' when 'ready' then '申請は処理済み・この人の分の振込データが未出力' else '振込データ出力済み' end,
                       'request_status', (select q.status from profile_change_requests q where q.id = h.request_id), 'excluded_at', h.created_at, 'resolved_at', h.resolved_at, 'done_at', h.done_at) order by h.created_at), '[]'::jsonb)
                      from payroll_transfer_holds h where h.year_month = p_year_month),
    'bank_approval_required', coalesce((select (value ->> 'bank_approval_required')::boolean from app_settings where key = 'employee_change'), false));
end $$;

-- ============ 7c. 通知と本部タスク（口座・賃金の変更申請があったときだけ。フラグ pay_request_notify_enabled・既定 false） ============
-- Slack（EF onboarding-notify を呼ぶだけ。文面に口座番号・賃金の金額は入らない＝EF は申請の中身を読まない）
create or replace function pay_change_notify_op(p_op text, p_body jsonb)
returns void language plpgsql security definer set search_path = public, net, extensions as $$
declare
  c_fn   constant text := 'https://uuvsxzhpxtghojoubjcc.supabase.co/functions/v1/onboarding-notify';
  c_anon constant text := 'sb_publishable_MrwPJAx_Ws_fdRutprKCiQ_dg3wCiTr';
  v_secret text;
begin
  select value into v_secret from app_secrets where key = 'notify_slack_secret';
  if v_secret is null or length(trim(v_secret)) = 0 then raise warning 'pay_change_notify: notify_slack_secret 未設定'; return; end if;
  perform net.http_post(url := c_fn,
    headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', c_anon, 'Authorization', 'Bearer ' || c_anon, 'x-notify-secret', trim(v_secret)),
    body := jsonb_build_object('op', p_op) || p_body, timeout_milliseconds := 60000);
end $$;
create or replace function pay_change_notify(p_request uuid, p_event text)
returns void language sql security definer set search_path = public as $$
  select pay_change_notify_op('pay_change', jsonb_build_object('request_id', p_request, 'event', p_event))
$$;
-- 本部タスク（既存の本部タスクボード hq_tasks に、申請 1 件につき 1 件。題名は「誰の何の変更か」だけ・口座の中身や金額は書かない）
create or replace function pay_change_task_open(p_request uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare q profile_change_requests%rowtype; v_name text; v_corp text; v_task uuid; v_assignee uuid; v_what text;
begin
  select * into q from profile_change_requests where id = p_request for update;
  if q.id is null or q.field not in ('bank_account', 'wage') then return null; end if;
  if q.hq_task_id is not null then return q.hq_task_id; end if;   -- 二重に作らない
  v_what := case q.field when 'wage' then '賃金変更' else '口座変更' end;
  select name into v_name from users where id = q.user_id;
  select c.name into v_corp from user_stores us join stores s on s.id = us.store_id join corporations c on c.id = s.corporation_id where us.user_id = q.user_id order by us.is_primary desc, s.sort_order limit 1;
  -- 担当は既存の本部タスク（入社登録・振込確認）と同じ人から。申請した人・本人は承認できないので外す
  select u.id into v_assignee from users u where u.name in ('青山純', '原　美香', '齋藤　隆治') and u.is_active and u.id <> q.requested_by and u.id <> q.user_id
   order by array_position(array['青山純', '原　美香', '齋藤　隆治'], u.name) limit 1;
  insert into hq_tasks(title, corp, freq, target_date, due_date, notes, description, visibility, created_by)
  values (v_what || 'の確認・承認（' || coalesce(v_name, '—') || 'さん）', coalesce(v_corp, 'トーホー'), 'once', current_date, current_date + 3, '',
          case q.field when 'wage' then '賃金（時給・日給・月給）の変更申請があります（適用開始日 ' || coalesce(q.effective_date::text, '—') || '）。' || E'\n' || '従業員ページの「賃金・口座の変更申請（承認）」で内容を確認し、承認または却下してください（申請した人とは別の人が承認します）。'
               else '給与の振込口座の変更申請があります。' || E'\n' || '従業員ページの「賃金・口座の変更申請（承認）」で内容を確認し、どの支給回から新しい口座にするかを選んで、承認または却下してください（申請した人とは別の人が承認します）。' end
          || E'\n' || 'https://mirai-oss.github.io/nippo/?page=admin&u=' || q.user_id || E'\n' || '※ 口座番号・金額はここには表示しません。承認・却下・取り下げで、このタスクは自動で完了になります。',
          'all', q.requested_by)
  returning id into v_task;
  insert into hq_task_steps(task_id, title, assignee_id, sort_order, kind, due_date)
  values (v_task, case q.field when 'wage' then '申請内容を確認して承認（または却下）' else '申請内容を確認し、支給回を選んで承認（または却下）' end, v_assignee, 10, 'step', current_date + 3);
  insert into hq_task_activity(task_id, actor_id, kind, detail) values (v_task, q.requested_by, 'create', v_what || 'の申請により自動作成');
  update profile_change_requests set hq_task_id = v_task where id = q.id;
  return v_task;
end $$;
create or replace function pay_change_task_close(p_request uuid)
returns void language plpgsql security definer set search_path = public as $$
declare q profile_change_requests%rowtype;
begin
  select * into q from profile_change_requests where id = p_request;
  if q.hq_task_id is null then return; end if;
  if not exists (select 1 from hq_task_steps where task_id = q.hq_task_id and completed_at is null) then return; end if;   -- もう完了している
  update hq_task_steps set completed_at = now(), completed_by = q.reviewed_by where task_id = q.hq_task_id and completed_at is null;
  insert into hq_task_activity(task_id, actor_id, kind, detail)
  values (q.hq_task_id, q.reviewed_by, 'step_complete', case q.field when 'wage' then '賃金変更' else '口座変更' end || 'の申請が' || case q.status when 'approved' then '承認' when 'rejected' then '却下' else '取り下げ' end || 'されたため自動で完了');
end $$;
-- 申請が出来たとき／状態が変わったとき。通知やタスクが失敗しても、申請・承認そのものは止めない（エラーは employee_change_errors に残す）
create or replace function pay_change_trg_request() returns trigger language plpgsql security definer set search_path = public as $$
declare v_on boolean;
begin
  if new.field not in ('bank_account', 'wage') then return null; end if;
  begin
    select coalesce((value ->> 'pay_request_notify_enabled')::boolean, false) into v_on from app_settings where key = 'employee_change';
    if tg_op = 'INSERT' then
      if new.status = 'pending' and coalesce(v_on, false) then
        perform pay_change_task_open(new.id);
        perform pay_change_notify(new.id, 'requested');
      end if;
    else
      if old.status = 'pending' and new.status <> 'pending' then
        if new.hq_task_id is not null then perform pay_change_task_close(new.id); end if;
        -- 振込データから除外していた人: 申請が片付いた → その人の分の振込データを出す番
        if new.field = 'bank_account' then update payroll_transfer_holds set status = 'ready', resolved_at = now() where request_id = new.id and status = 'held'; end if;
      end if;
      if new.apply_status in ('blocked_exported', 'blocked_finalized') and old.apply_status is distinct from new.apply_status and coalesce(v_on, false) then perform pay_change_notify(new.id, 'conflict'); end if;
    end if;
  exception when others then perform employee_change_log_error('profile_change_requests', 'pay_notify', new.user_id, sqlerrm);
  end;
  return null;
end $$;
drop trigger if exists pay_change_request_after on profile_change_requests;
create trigger pay_change_request_after after insert or update on profile_change_requests for each row execute function pay_change_trg_request();

-- ============ 8. 一覧（本部系）。口座番号は マスター・本部以外には下 3 桁だけ ============
create or replace function hr_pay_change_list(p_user uuid default null, p_only_open boolean default false)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_full boolean := is_profile_approver() or onboarding_is_service();
begin
  if not (hq_can_manage() or onboarding_is_service() or (p_user is not null and auth.uid() = p_user)) then raise exception '権限がありません'; end if;
  if not (hq_can_manage() or onboarding_is_service()) then v_full := false; end if;
  return coalesce((select jsonb_agg(x order by x.requested_at desc) from (
    select q.id, q.user_id, (select name from users u where u.id = q.user_id) user_name, q.field, q.status, q.apply_status, q.apply_note, q.applied_at, q.request_reason, q.reject_reason,
           q.effective_date, q.effective_year_month, q.effective_pay_date, (select name from users u where u.id = q.requested_by) requested_by_name, q.requested_at,
           (select name from users u where u.id = q.reviewed_by) reviewed_by_name, q.reviewed_at,
           case when q.field = 'wage' then case when hq_can_manage() or onboarding_is_service() then coalesce(q.payload, q.new_value::jsonb) end
                else (case when v_full then coalesce(q.payload, q.new_value::jsonb) else coalesce(q.payload, q.new_value::jsonb) - 'account_number' || jsonb_build_object('account_number', '****' || right(coalesce(coalesce(q.payload, q.new_value::jsonb) ->> 'account_number', ''), 3)) end) end new_value,
           case when q.field = 'wage' then case when hq_can_manage() or onboarding_is_service() then q.old_value::jsonb end
                when q.old_value is null then null
                else (case when v_full then q.old_value::jsonb else q.old_value::jsonb - 'account_number' || jsonb_build_object('account_number', '****' || right(coalesce(q.old_value::jsonb ->> 'account_number', ''), 3)) end) end old_value,
           (select jsonb_build_object('sync_status', w.sync_status, 'synced_at', w.synced_at, 'sync_error', w.sync_error, 'smaregi_wage_apply_id', w.smaregi_wage_apply_id) from employee_wage_settings w where w.id = nullif(q.apply_ref ->> 'wage_setting_id', '')::uuid) sync,
           (q.requested_by = auth.uid()) mine
      from profile_change_requests q
     where q.field in ('wage', 'bank_account') and (p_user is null or q.user_id = p_user)
       and (not coalesce(p_only_open, false) or q.status = 'pending' or (q.status = 'approved' and q.apply_status in ('scheduled', 'blocked_exported', 'blocked_finalized')))
     order by q.requested_at desc limit 200) x), '[]'::jsonb);
end $$;

-- ============ 9. 既存の承認関数（ポータルの申請画面が使う）から共通の承認へ回す ============
CREATE OR REPLACE FUNCTION public.review_profile_change_request(p_request_id uuid, p_approve boolean, p_reason text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_req profile_change_requests%rowtype;
  v_bank jsonb;
begin
  if not is_profile_approver() then
    raise exception '権限がありません';
  end if;

  select * into v_req from profile_change_requests
    where id = p_request_id and status = 'pending' for update;
  if not found then
    raise exception '対象の申請が見つからないか、既に処理済みです';
  end if;

  -- 2026-11-10 ステップ 3: 銀行口座・賃金は「適用する支給回／適用開始日・締め済みの確認・2 人目の承認」を通す共通の承認へ回す
  if v_req.field in ('bank_account', 'wage') then
    -- 口座の承認は、どの支給回から新しい口座にするかを選ぶ必要がある（この古い呼び方では選べない → 承認画面の新しい版から）。却下・賃金はそのまま通す
    if v_req.field = 'bank_account' and p_approve then raise exception '口座変更の承認は、適用する支給回を選んでから行ってください（画面を再読み込みすると選べます）'; end if;
    v_bank := hr_pay_change_review(p_request_id, p_approve, p_reason, null, false, null);
    if coalesce((v_bank ->> 'ok')::boolean, false) is not true then raise exception '%', coalesce(v_bank ->> 'error', '反映できませんでした'); end if;
    return;
  end if;

  if p_approve then
    if v_req.field = 'name' then
      update users set name = v_req.new_value where id = v_req.user_id;
    elsif v_req.field = 'kana' then
      insert into employee_profiles (user_id, name_kana) values (v_req.user_id, v_req.new_value)
        on conflict (user_id) do update set name_kana = excluded.name_kana, updated_at = now();
    elsif v_req.field = 'phone' then
      insert into employee_profiles (user_id, phone) values (v_req.user_id, v_req.new_value)
        on conflict (user_id) do update set phone = excluded.phone, updated_at = now();
    elsif v_req.field = 'address' then
      insert into employee_profiles (user_id, address) values (v_req.user_id, v_req.new_value)
        on conflict (user_id) do update set address = excluded.address, updated_at = now();
    elsif v_req.field = 'contact_email' then
      insert into employee_profiles (user_id, extra) values (v_req.user_id, jsonb_build_object('contact_email', v_req.new_value))
        on conflict (user_id) do update set
          extra = coalesce(employee_profiles.extra, '{}'::jsonb) || jsonb_build_object('contact_email', v_req.new_value),
          updated_at = now();
    elsif v_req.field = 'id_document' then
      null; -- 反映先の列は無い。承認された記録がこの行自体に残ればよい
    elsif v_req.field = 'bank_account' then
      v_bank := v_req.new_value::jsonb;
      insert into payroll_bank_accounts
        (user_id, bank_code, bank_name, branch_code, branch_name,
         account_type, account_number, account_holder_kana, updated_by, updated_at)
      values (
        v_req.user_id,
        v_bank->>'bank_code', v_bank->>'bank_name',
        v_bank->>'branch_code', v_bank->>'branch_name',
        coalesce(v_bank->>'account_type','1'),
        v_bank->>'account_number', v_bank->>'account_holder_kana',
        auth.uid(), now()
      )
      on conflict (user_id) do update set
        bank_code = excluded.bank_code, bank_name = excluded.bank_name,
        branch_code = excluded.branch_code, branch_name = excluded.branch_name,
        account_type = excluded.account_type, account_number = excluded.account_number,
        account_holder_kana = excluded.account_holder_kana,
        updated_by = excluded.updated_by, updated_at = excluded.updated_at;
    end if;

    update profile_change_requests
      set status = 'approved', reviewed_by = auth.uid(), reviewed_at = now()
      where id = p_request_id;
  else
    update profile_change_requests
      set status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now(), reject_reason = p_reason
      where id = p_request_id;
  end if;
end $function$;

revoke all on function hr_bank_change_try_apply(uuid, uuid) from public, anon, authenticated;
revoke all on function hr_bank_change_write(uuid, uuid) from public, anon, authenticated;
revoke all on function hr_bank_change_apply_exception(uuid, text, uuid, text) from public, anon, authenticated;
revoke all on function hr_apply_due_bank_changes_internal() from public, anon, authenticated;
revoke all on function hr_pay_change_attention_internal(text) from public, anon, authenticated;
revoke all on function payroll_transfer_schedule_after() from public, anon, authenticated;
revoke all on function employee_change_pay_guard() from public, anon, authenticated;
revoke all on function pay_change_notify(uuid, text) from public, anon, authenticated;
revoke all on function pay_change_task_open(uuid) from public, anon, authenticated;
revoke all on function pay_change_task_close(uuid) from public, anon, authenticated;
revoke all on function pay_change_trg_request() from public, anon, authenticated;
revoke all on function pay_run_date(text) from public, anon;
revoke all on function pay_run_state(text, date) from public, anon;
revoke all on function pay_run_closed(text, date) from public, anon;
revoke all on function pay_run_next_open(date) from public, anon;
grant execute on function pay_run_date(text) to authenticated, service_role;
grant execute on function pay_run_state(text, date) to authenticated, service_role;
grant execute on function pay_run_closed(text, date) to authenticated, service_role;
grant execute on function pay_run_next_open(date) to authenticated, service_role;
revoke all on function hr_pay_change_request(uuid, text, jsonb, date, text, text, uuid) from public, anon;
revoke all on function hr_pay_change_review(uuid, boolean, text, uuid, boolean, text) from public, anon;
revoke all on function hr_apply_due_bank_changes(uuid) from public, anon;
revoke all on function hr_bank_change_reschedule(uuid, text, uuid, boolean, text) from public, anon;
revoke all on function hr_pay_change_cancel(uuid, uuid) from public, anon;
revoke all on function hr_pay_change_list(uuid, boolean) from public, anon;
revoke all on function hr_pay_change_attention(text) from public, anon;
revoke all on function hr_pay_change_config(uuid) from public, anon;
revoke all on function pay_run_user_state(text, uuid, date) from public, anon;
grant execute on function pay_run_user_state(text, uuid, date) to authenticated, service_role;
revoke all on function pay_transfer_pending_holds(text) from public, anon, authenticated;
revoke all on function pay_transfer_hold_task_sync(text) from public, anon, authenticated;
revoke all on function payroll_transfer_schedule_guard() from public, anon, authenticated;
revoke all on function payroll_transfer_confirm_step_guard() from public, anon, authenticated;
revoke all on function pay_transfer_invalid_export_task(text) from public, anon, authenticated;
revoke all on function pay_change_request_direct_guard() from public, anon, authenticated;
revoke all on function pay_transfer_paused() from public, anon;
revoke all on function pay_bank_row_visible(uuid) from public, anon;
grant execute on function pay_transfer_paused() to authenticated, service_role;
grant execute on function pay_bank_row_visible(uuid) to authenticated, service_role;
revoke all on function payroll_transfer_account_snapshots_guard() from public, anon, authenticated;
revoke all on function pay_change_notify_op(text, jsonb) from public, anon, authenticated;
revoke all on function employee_change_pay_direct_allowed(text, uuid, text) from public, anon, authenticated;
revoke all on function hr_payroll_transfer_prepare(text) from public, anon;
grant execute on function hr_pay_change_request(uuid, text, jsonb, date, text, text, uuid) to authenticated, service_role;
grant execute on function hr_pay_change_review(uuid, boolean, text, uuid, boolean, text) to authenticated, service_role;
grant execute on function hr_apply_due_bank_changes(uuid) to authenticated, service_role;
grant execute on function hr_bank_change_reschedule(uuid, text, uuid, boolean, text) to authenticated, service_role;
grant execute on function hr_pay_change_cancel(uuid, uuid) to authenticated, service_role;
grant execute on function hr_pay_change_list(uuid, boolean) to authenticated, service_role;
grant execute on function hr_pay_change_attention(text) to authenticated, service_role;
grant execute on function hr_pay_change_config(uuid) to authenticated, service_role;
grant execute on function hr_payroll_transfer_prepare(text) to authenticated, service_role;
