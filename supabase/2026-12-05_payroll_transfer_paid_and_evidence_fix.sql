-- 振込照合の直し 2 点（2026-11-15・社長の指摘への対応）
--
-- ① 給与の画面の「振込済」が 0 人のまま
--    原因: 給与の画面の「振込済」は、昔からの印 payroll_journal_records.paid_at（「💰振込済みにする」で入る）だけを見ていて、
--          新しい照合の表（payroll_transfer_batch_lines）を見ていない。
--    直し: 照合で「振込完了」「人が確認済み」になった行の人について、その月の仕訳の行の paid_at が空なら入れる関数を足す。
--          すでに paid_at が入っている行・仕訳の行が無い人・その月に仕訳の行が 2 つ以上ある人は触らない。
--          照合に行が無い人（＝銀行と照合した根拠が無い人）には、何もしない。
--          どの印を照合が入れたかを、表 payroll_transfer_paid_marks に残す（あとで外すときは、照合が入れた印だけを外せる）。
--
-- ② 証憑に、説明用の画像が正式な証憑として入っていた
--    直し: 証憑の行とファイルは消さない・書きかえない（今までの決まりのまま）。「正式な証憑から除外した／戻した」の記録を、
--          別の表 payroll_transfer_evidence_corrections に残す。手動確認の根拠になっている証憑は除外できない。
--
-- 足すもの: 表 2 つ・関数 4 本。既存の表の列・既存の関数・トリガーは変えない。
-- 戻し方: 2026-12-05_payroll_transfer_paid_and_evidence_fix_rollback.sql

-- ============ ① 昔からの印へ写す ============
create table if not exists public.payroll_transfer_paid_marks (
  line_id            uuid primary key references public.payroll_transfer_batch_lines(id),
  batch_id           uuid not null,
  journal_record_id  uuid not null,
  user_id            uuid not null,
  year_month         text not null,
  paid_at_set        timestamptz not null,       -- 照合が入れた paid_at の値
  paid_by_set        uuid,                       -- 照合が入れた paid_by の値（確認した人）
  basis              text not null,              -- 何を根拠に入れたか（completed／manual_confirmed）
  marked_by          uuid,                       -- この写しを実行した人
  marked_at          timestamptz not null default now(),
  cleared_at         timestamptz,                -- 外した日時（外していなければ null）
  cleared_by         uuid,
  cleared_reason     text
);
comment on table public.payroll_transfer_paid_marks is '振込照合が、昔からの印（payroll_journal_records.paid_at）へ写した記録。照合が入れた印だけを、あとで外せるようにする。';
alter table public.payroll_transfer_paid_marks enable row level security;   -- ポリシーなし＝画面からは直接読めない・書けない
revoke all on public.payroll_transfer_paid_marks from public, anon, authenticated;

create or replace function public.payroll_transfer_paid_backfill(p_batch_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_uid uuid := auth.uid(); v_b payroll_transfer_batches%rowtype; v_l record; v_n integer; v_j payroll_journal_records%rowtype;
  v_at timestamptz; v_by uuid;
  v_marked integer := 0; v_already integer := 0; v_no_journal integer := 0; v_multi integer := 0; v_done_before integer := 0; v_not_final integer := 0;
begin
  if v_uid is null or public.payroll_pay_can() is not true then raise exception '権限がありません（給与の担当者としてログインしてください）'; end if;
  select * into v_b from payroll_transfer_batches b where b.id = p_batch_id;
  if v_b.id is null then raise exception 'バッチが見つかりません'; end if;
  perform pg_advisory_xact_lock(hashtext('payroll_transfer_paid_backfill:' || p_batch_id::text));

  for v_l in select l.id, l.user_id, l.year_month, l.line_status from payroll_transfer_batch_lines l where l.batch_id = p_batch_id order by l.user_id loop
    if v_l.line_status not in ('completed', 'manual_confirmed') then v_not_final := v_not_final + 1; continue; end if;   -- 完了でない行は触らない
    if exists (select 1 from payroll_transfer_paid_marks m where m.line_id = v_l.id and m.cleared_at is null) then v_done_before := v_done_before + 1; continue; end if;
    select count(*) into v_n from payroll_journal_records j where j.user_id = v_l.user_id and j.year_month = v_l.year_month;
    if v_n = 0 then v_no_journal := v_no_journal + 1; continue; end if;       -- 仕訳の行が無い人は触らない
    if v_n > 1 then v_multi := v_multi + 1; continue; end if;                 -- その月に仕訳の行が 2 つ以上ある人は、どれか決められないので触らない
    select * into v_j from payroll_journal_records j where j.user_id = v_l.user_id and j.year_month = v_l.year_month for update;
    if v_j.paid_at is not null then v_already := v_already + 1; continue; end if;   -- すでに印がある行は触らない
    -- 印の日時と人: 手動確認ならその確認の日時と確認者。そうでなければ、バッチの完了の日時
    select c.confirmed_at, c.confirmed_by into v_at, v_by
      from payroll_transfer_manual_confirmations c where c.line_id = v_l.id and c.action = 'confirm' order by c.confirmed_at desc limit 1;
    v_at := coalesce(v_at, v_b.completed_at, now());
    update payroll_journal_records j set paid_at = v_at, paid_by = v_by where j.id = v_j.id and j.paid_at is null;
    insert into payroll_transfer_paid_marks(line_id, batch_id, journal_record_id, user_id, year_month, paid_at_set, paid_by_set, basis, marked_by)
    values (v_l.id, p_batch_id, v_j.id, v_l.user_id, v_l.year_month, v_at, v_by, v_l.line_status, v_uid)
    on conflict (line_id) do update set journal_record_id = excluded.journal_record_id, paid_at_set = excluded.paid_at_set, paid_by_set = excluded.paid_by_set,
      basis = excluded.basis, marked_by = excluded.marked_by, marked_at = now(), cleared_at = null, cleared_by = null, cleared_reason = null;
    v_marked := v_marked + 1;
  end loop;
  return jsonb_build_object('ok', true, 'marked', v_marked, 'already_paid', v_already, 'marked_before', v_done_before, 'no_journal', v_no_journal,
                            'multiple_journal_rows', v_multi, 'not_final', v_not_final);
end $$;
revoke all on function public.payroll_transfer_paid_backfill(uuid) from public, anon;
grant execute on function public.payroll_transfer_paid_backfill(uuid) to authenticated, service_role;

-- 照合が入れた印だけを外す（その行が、完了でなくなったとき用。人が入れた印・入れたあとに値が変わった印は外さない）
create or replace function public.payroll_transfer_paid_unmark(p_line_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := auth.uid(); v_m payroll_transfer_paid_marks%rowtype; v_cnt integer;
begin
  if v_uid is null or public.payroll_pay_can() is not true then raise exception '権限がありません（給与の担当者としてログインしてください）'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception '理由を入力してください'; end if;
  select * into v_m from payroll_transfer_paid_marks m where m.line_id = p_line_id and m.cleared_at is null for update;
  if v_m.line_id is null then return jsonb_build_object('ok', false, 'reason', 'no_mark', 'message', 'この行には、照合が入れた印がありません'); end if;
  update payroll_journal_records j set paid_at = null, paid_by = null
   where j.id = v_m.journal_record_id and j.paid_at = v_m.paid_at_set and j.paid_by is not distinct from v_m.paid_by_set;
  get diagnostics v_cnt = row_count;
  update payroll_transfer_paid_marks m set cleared_at = now(), cleared_by = v_uid,
         cleared_reason = btrim(p_reason) || case when v_cnt = 0 then '（印は、入れたあとに変わっていたので外していません）' else '' end
   where m.line_id = p_line_id;
  return jsonb_build_object('ok', true, 'cleared_paid_mark', v_cnt = 1);
end $$;
revoke all on function public.payroll_transfer_paid_unmark(uuid, text) from public, anon;
grant execute on function public.payroll_transfer_paid_unmark(uuid, text) to authenticated, service_role;

-- ============ ② 証憑の除外（訂正）の記録 ============
create table if not exists public.payroll_transfer_evidence_corrections (
  id           bigint generated always as identity primary key,
  evidence_id  uuid not null references public.payroll_transfer_evidence(id),
  action       text not null check (action in ('excluded', 'reinstated')),
  reason       text not null check (btrim(reason) <> ''),
  actor_id     uuid not null,
  created_at   timestamptz not null default now()
);
comment on table public.payroll_transfer_evidence_corrections is '証憑を「正式な証憑から除外した／戻した」の記録。証憑の行とファイルは消さない。記録は足すだけ（書きかえ・削除なし）。';
create index if not exists payroll_transfer_evidence_corrections_ev_idx on public.payroll_transfer_evidence_corrections (evidence_id, id desc);
alter table public.payroll_transfer_evidence_corrections enable row level security;
revoke all on public.payroll_transfer_evidence_corrections from public, anon, authenticated;

create or replace function public.payroll_transfer_evidence_correct(p_evidence_id uuid, p_action text, p_reason text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := auth.uid(); v_last text;
begin
  if v_uid is null or public.payroll_pay_can() is not true then raise exception '権限がありません（給与の担当者としてログインしてください）'; end if;
  if p_action is null or p_action not in ('excluded', 'reinstated') then raise exception '操作が不正です（excluded＝正式な証憑から除外／reinstated＝戻す）'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception '理由を入力してください'; end if;
  if not exists (select 1 from payroll_transfer_evidence e where e.id = p_evidence_id) then raise exception '証憑が見つかりません'; end if;
  select c.action into v_last from payroll_transfer_evidence_corrections c where c.evidence_id = p_evidence_id order by c.id desc limit 1;
  if p_action = 'excluded' then
    if v_last is not distinct from 'excluded' then return jsonb_build_object('ok', true, 'already', true, 'state', 'excluded'); end if;
    if exists (select 1 from payroll_transfer_manual_confirmations m where m.evidence_id = p_evidence_id and m.action = 'confirm') then
      raise exception 'この証憑は、手動確認の根拠になっているので、除外できません（先に、手動確認の取り消しが要ります）';
    end if;
  else
    if v_last is distinct from 'excluded' then return jsonb_build_object('ok', true, 'already', true, 'state', 'official'); end if;
  end if;
  insert into payroll_transfer_evidence_corrections(evidence_id, action, reason, actor_id) values (p_evidence_id, p_action, btrim(p_reason), v_uid);
  return jsonb_build_object('ok', true, 'state', case when p_action = 'excluded' then 'excluded' else 'official' end);
end $$;
revoke all on function public.payroll_transfer_evidence_correct(uuid, text, text) from public, anon;
grant execute on function public.payroll_transfer_evidence_correct(uuid, text, text) to authenticated, service_role;

-- 画面用: その月・その法人の証憑のうち、いま「除外」になっているものと、訂正の履歴（口座番号・金額は入らない）
create or replace function public.payroll_transfer_evidence_corrections_list(p_year_month text, p_corp_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if public.payroll_pay_can() is not true then raise exception '権限がありません'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('evidence_id', c.evidence_id, 'action', c.action, 'reason', c.reason, 'created_at', c.created_at,
                                        'actor_name', (select u.name from users u where u.id = c.actor_id),
                                        'is_latest', c.id = (select max(c2.id) from payroll_transfer_evidence_corrections c2 where c2.evidence_id = c.evidence_id)) order by c.id)
      from payroll_transfer_evidence_corrections c join payroll_transfer_evidence e on e.id = c.evidence_id
     where e.year_month = p_year_month and (p_corp_id is null or e.corporation_id = p_corp_id)), '[]'::jsonb);
end $$;
revoke all on function public.payroll_transfer_evidence_corrections_list(text, uuid) from public, anon;
grant execute on function public.payroll_transfer_evidence_corrections_list(text, uuid) to authenticated, service_role;

-- 確認用:
--   select basis, count(*), count(*) filter (where cleared_at is null) from payroll_transfer_paid_marks group by 1;
--   select e.kind, c.action, c.reason, c.created_at from payroll_transfer_evidence_corrections c join payroll_transfer_evidence e on e.id = c.evidence_id order by c.id;
