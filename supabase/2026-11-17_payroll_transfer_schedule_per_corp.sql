-- 振込予定の表 payroll_transfer_schedule を法人ごとに分ける（2026-11-17・ユーザー指示。LiveGate の給与が 11月分（12月払い）から始まるため）
--
-- 背景: この表は「対象月」で 1 行（主キー year_month）。同じ月にトーホーと LiveGate が出力すると、振込予定日・本部タスクとの結び付き・出力の印が、
--       あとの法人で上書きされる。
-- 直し:
--   ・列 corporation_id（法人）を足し、主キーを (year_month, corporation_id) に。既存の行はすべてトーホーの行にする。
--     既定値＝トーホー（更新前の古い画面が、法人を付けずに出力を記録しても、従来どおりトーホーの行になる）。
--   ・pay_run_date(月) … その月の全法人の振込予定日のうち最も遅い日（「その月は全部払い済み」を判定する共通の関数。行が 1 つなら今までと同じ）
--   ・payroll_transfer_batch_freeze … 振込予定日を渡さないとき、その法人の予定日を使う（以前は月の 1 行）
-- 変えないもの: 3 つのトリガー（出力の印・控え・除外は、月と利用者ごとのまま。法人をまたいでも二重にならない作り）・
--   pay_run_state／pay_transfer_invalid_export_task／pay_transfer_pending_holds／hr_payroll_transfer_prepare など（月の行の「有無」だけを見る）。
-- 戻し方: 2026-11-17_payroll_transfer_schedule_per_corp_rollback.sql（LiveGate の行があると戻せない＝先に消す）

alter table public.payroll_transfer_schedule
  add column if not exists corporation_id uuid not null default '9f3f5239-d346-42b9-86cf-144e246cebeb'::uuid references public.corporations(id);
comment on column public.payroll_transfer_schedule.corporation_id is '法人（既定＝トーホー）。主キーは (year_month, corporation_id)';
alter table public.payroll_transfer_schedule drop constraint if exists payroll_transfer_schedule_pkey;
alter table public.payroll_transfer_schedule add constraint payroll_transfer_schedule_pkey primary key (year_month, corporation_id);

CREATE OR REPLACE FUNCTION public.pay_run_date(p_year_month text)
 RETURNS date
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce((select max(scheduled_date) from payroll_transfer_schedule where year_month = p_year_month), (to_date(p_year_month || '-01', 'YYYY-MM-DD') + interval '1 month' + interval '14 days')::date)
$function$;

CREATE OR REPLACE FUNCTION public.payroll_transfer_batch_freeze(p_year_month text, p_corp_id uuid, p_scheduled_date date DEFAULT NULL::date, p_skip_unready boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_date date; v_seq integer; v_batch uuid; v_existing uuid; v_cand jsonb; v_ready jsonb;
  v_count integer := 0; v_total numeric := 0; v_hash text; v_unready integer := 0;
begin
  if not public.payroll_pay_can() then raise exception '権限がありません'; end if;
  if p_year_month is null or p_year_month !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then raise exception '月（YYYY-MM）が不正です'; end if;
  if p_corp_id is null then raise exception '法人が指定されていません'; end if;
  perform pg_advisory_xact_lock(hashtext('payroll_transfer_batch:' || p_year_month || ':' || p_corp_id::text));   -- 同時に押されても 1 つだけ

  select b.id into v_existing from payroll_transfer_batches b
   where b.year_month = p_year_month and b.corporation_id = p_corp_id and b.batch_kind = 'regular';
  if v_existing is not null then
    return jsonb_build_object('ok', true, 'already', true, 'batch_id', v_existing);
  end if;

  v_date := coalesce(p_scheduled_date, (select t.scheduled_date from payroll_transfer_schedule t where t.year_month = p_year_month and t.corporation_id = p_corp_id));
  if v_date is null then raise exception '振込指定日が決まっていません'; end if;

  -- 予定者の候補（まだどのバッチにも入っていない人）
  select coalesce(jsonb_agg(jsonb_build_object('user_id', c.user_id, 'amount', c.amt, 'account', c.account) order by c.user_id), '[]'::jsonb)
    into v_cand
    from (
      select sp.user_id, round(sum(sp.net_pay)) as amt,
             (select m.account from payroll_month_payments m
               where m.user_id = sp.user_id and m.year_month = p_year_month and m.status = 'fixed' and m.method = 'bank_transfer') as account
        from sf_payroll_sync sp
        join smaregi_contracts sc on sc.contract_id = sp.contract_id
       where sp.year_month = p_year_month and sc.corporation_id = p_corp_id
         and public.payroll_month_method(sp.user_id, p_year_month) = 'bank_transfer'
         and not exists (select 1 from sf_payroll_hidden h where h.user_id = sp.user_id and h.year_month = p_year_month)
         and not exists (select 1 from public.pay_transfer_pending_holds(p_year_month) ph where ph.user_id = sp.user_id)
         and not exists (select 1 from payroll_transfer_batch_lines l0
                          where l0.year_month = p_year_month and l0.corporation_id = p_corp_id and l0.user_id = sp.user_id)
       group by sp.user_id
      having round(sum(sp.net_pay)) > 0
    ) c;

  -- 振込先の控えが使える人だけを残す
  select coalesce(jsonb_agg(e.value order by e.value ->> 'user_id'), '[]'::jsonb) into v_ready
    from jsonb_array_elements(v_cand) e
   where jsonb_typeof(e.value -> 'account') = 'object'
     and public.payroll_recon_acct_key(e.value -> 'account' ->> 'bank_code', e.value -> 'account' ->> 'branch_code',
                                       e.value -> 'account' ->> 'account_type', e.value -> 'account' ->> 'account_number') is not null
     and public.payroll_recon_kana_norm(e.value -> 'account' ->> 'account_holder_kana') <> '';
  v_unready := jsonb_array_length(v_cand) - jsonb_array_length(v_ready);
  if v_unready > 0 and not coalesce(p_skip_unready, false) then
    return jsonb_build_object('ok', false, 'reason', 'unready', 'unready_count', v_unready,
                              'message', '振込先の控え（給料確定のときの口座）が無い人がいます。給料確定・口座を確かめてから、もう一度固めてください');
  end if;

  select count(*), coalesce(sum((e.value ->> 'amount')::numeric), 0),
         encode(sha256(convert_to(coalesce(string_agg(concat_ws('|', e.value ->> 'user_id', e.value ->> 'amount',
                  public.payroll_recon_acct_key(e.value -> 'account' ->> 'bank_code', e.value -> 'account' ->> 'branch_code',
                                                e.value -> 'account' ->> 'account_type', e.value -> 'account' ->> 'account_number'),
                  public.payroll_recon_kana_norm(e.value -> 'account' ->> 'account_holder_kana')), E'\n' order by e.value ->> 'user_id'), ''), 'UTF8')), 'hex')
    into v_count, v_total, v_hash
    from jsonb_array_elements(v_ready) e;
  if v_count = 0 then
    return jsonb_build_object('ok', false, 'reason', 'no_targets', 'unready_count', v_unready, 'message', '固める対象の人がいません');
  end if;

  select coalesce(max(b.batch_seq), 0) + 1 into v_seq from payroll_transfer_batches b where b.year_month = p_year_month and b.corporation_id = p_corp_id;

  perform set_config('payroll.recon_ok', '1', true);
  insert into payroll_transfer_batches(year_month, corporation_id, batch_seq, batch_kind, scheduled_date, expected_count, expected_total, lines_hash, frozen_by)
  values (p_year_month, p_corp_id, v_seq, 'regular', v_date, v_count, v_total, v_hash, auth.uid())
  returning id into v_batch;
  insert into payroll_transfer_batch_lines(batch_id, year_month, corporation_id, user_id, amount, account, acct_key, kana_norm, account_source)
  select v_batch, p_year_month, p_corp_id, (e.value ->> 'user_id')::uuid, (e.value ->> 'amount')::numeric, e.value -> 'account',
         public.payroll_recon_acct_key(e.value -> 'account' ->> 'bank_code', e.value -> 'account' ->> 'branch_code',
                                       e.value -> 'account' ->> 'account_type', e.value -> 'account' ->> 'account_number'),
         public.payroll_recon_kana_norm(e.value -> 'account' ->> 'account_holder_kana'), 'month'
    from jsonb_array_elements(v_ready) e;
  perform public.payroll_recon_log(v_batch, null, 'frozen', null, 'planned', 'human', null,
                                   jsonb_build_object('batch_seq', v_seq, 'batch_kind', 'regular', 'count', v_count, 'scheduled_date', v_date, 'skipped_unready', v_unready));
  perform public.payroll_recon_eval(v_batch, 'auto_bank');   -- 銀行のデータが先に取り込まれていた場合に備えて、すぐ照合する（無ければ何も変わらない）
  perform set_config('payroll.recon_ok', '', true);

  return jsonb_build_object('ok', true, 'already', false, 'batch_id', v_batch, 'batch_seq', v_seq, 'batch_kind', 'regular', 'count', v_count, 'skipped_unready', v_unready);
end $function$;
