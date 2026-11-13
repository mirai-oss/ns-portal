-- 採用管理: Slack と管理システムの両方から呼ぶ「共通の操作」の土台と、担当者（2026-11-26 下書き）
--   設計: scratchpad ob18/設計_採用_面接確定とLINEのSlack操作.md ／ この段階のメモ: ob18/メモ_第1弾.md
--   ★ 本番未適用（下書き。適用は別途承認）。戻し方: 2026-11-26_recruit_action_base_rollback.sql
--
--   これを適用しただけでは、いまの動きは何も変わらない。
--     ・応募者へは何も送らない（LINE・メール・カレンダーを呼ぶ処理は、この中に 1 つも無い）。
--     ・Slack へも何も送らない（pg_net を呼ぶ処理は、この中に無い）。
--     ・担当者の設定（app_settings.recruit_assign）は枠だけで、値は全部 null。null のあいだ、初期の割り当ては何もしない＝今までどおり。
--     ・Slack のボタンのスイッチ（app_settings.recruit_slack.actions_enabled）は false。
--   足すもの: 表 1 つ（applicant_ops）・設定の項目 1 つ（recruit_assign）と設定のキー 1 つ（recruit_slack.actions_enabled）・関数 10 本・トリガー 1 本（applicants）。
--   変えないもの: 既存の表の列・既存の関数・既存のトリガー（applicant_auto_assign・recruit_notice_* など）。

-- ============ 0. 前提の確認（足りなければ、何も変えずに止まる） ============
do $$
declare v_missing text;
begin
  if to_regclass('public.applicants') is null or to_regclass('public.applicant_messages') is null or to_regclass('public.app_settings') is null then
    raise exception '表 applicants / applicant_messages / app_settings がありません';
  end if;
  if to_regprocedure('public.has_feature(uuid,text)') is null or to_regprocedure('public.can_see_applicant(uuid,uuid)') is null
     or to_regprocedure('public.onboarding_is_service()') is null then
    raise exception '関数 has_feature / can_see_applicant / onboarding_is_service がありません';
  end if;
  select string_agg(c, ', ') into v_missing
    from unnest(array['assignee_id','store_id','form_key','source','status','answers','last_actor_id','last_actor_at','updated_at','last_msg_at','last_msg_dir','handled_at']) c
   where not exists (select 1 from information_schema.columns k where k.table_schema = 'public' and k.table_name = 'applicants' and k.column_name = c);
  if v_missing is not null then raise exception 'applicants に、使う列がありません: %', v_missing; end if;
end $$;

-- ============ 1. 操作の記録（1 操作 1 行） ============
-- だれが・どこから・何を・前と後・結果・失敗理由。依頼の鍵（request_key）が一意＝同じ依頼の 2 回目は、行が増えない。
-- 氏名・電話・メール・本文は入れない（前と後には、利用者の id などの番号だけ）。応募者が統合・削除されても履歴は残す（外部キーは付けない）。
create table if not exists public.applicant_ops (
  id           uuid primary key default gen_random_uuid(),
  applicant_id uuid not null,
  op           text not null check (op ~ '^[a-z][a-z_]{1,39}$'),            -- assignee_set（人が担当を変えた）／assignee_auto（初期の割り当て）／backup_notice（予備の担当へ知らせた印）
  actor_id     uuid,                                                        -- 操作した人（自動のときは null）
  via          text not null check (via in ('slack', 'web', 'app', 'auto')),
  request_key  text not null check (length(request_key) between 8 and 200),
  before_state jsonb not null default '{}'::jsonb,
  after_state  jsonb not null default '{}'::jsonb,
  result       text not null check (result in ('done', 'noop', 'conflict', 'denied', 'failed')),
  error        text,
  reason       text,
  created_at   timestamptz not null default now(),
  constraint applicant_ops_request_key_uq unique (request_key)
);
create index if not exists applicant_ops_applicant_idx on public.applicant_ops (applicant_id, created_at desc);
alter table public.applicant_ops enable row level security;   -- ポリシーなし＝画面からは直接読めない・書けない（関数だけ）
revoke all on public.applicant_ops from anon, authenticated;

-- ============ 2. 設定 ============
-- 担当者の設定（枠だけ。値は依頼主が決めてから、別の SQL で入れる）。値は users.id（uuid の文字列）。
--   part_main＝アルバイト・パート採用の主担当／part_backup＝同じく予備／employee_main＝社員採用の主担当（社長）／
--   unknown_confirm＝雇用区分が分からない応募の確認先（null なら part_main を使う）／unhandled_hours＝未対応と見なすまでの時間
insert into app_settings (key, value)
select 'recruit_assign',
       '{"part_main": null, "part_backup": null, "employee_main": null, "unknown_confirm": null, "unhandled_hours": 24, "note": "採用の担当者の設定。値は users.id。null のあいだは、初期の割り当ても、予備の担当への知らせの対象の抽出も、何もしない"}'::jsonb
where not exists (select 1 from app_settings where key = 'recruit_assign');

-- Slack のカードに操作のボタンを出すかどうか（既定 false。false のあいだ、カードは今までと同じ）
update app_settings set value = value || '{"actions_enabled": false}'::jsonb
 where key = 'recruit_slack' and not (value ? 'actions_enabled');

-- ボタンのスイッチの切り替え（マスターのみ）。切り替えたら、選考中の応募者のカードを見回り（recruit_notice_sweep・5 分ごと）に書き直させる
create or replace function public.recruit_actions_set(p_enabled boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_value jsonb;
begin
  if not (onboarding_is_service() or coalesce((select is_master from users where id = auth.uid() and is_active), false)) then
    raise exception '権限がありません（マスターのみ）';
  end if;
  select value into v_value from app_settings where key = 'recruit_slack';
  if v_value is null then raise exception '設定 recruit_slack がありません'; end if;
  v_value := v_value || jsonb_build_object('actions_enabled', coalesce(p_enabled, false));
  update app_settings set value = v_value where key = 'recruit_slack';
  if to_regclass('public.notice_cases') is not null then
    update notice_cases set slack_refs = slack_refs || '{"dirty": true}'::jsonb
     where type_key = 'recruit' and ref_table = 'applicants' and slack_refs ? 'ts'
       and not (slack_refs ? 'merged_into') and not coalesce((slack_refs ->> 'tombstone')::boolean, false)
       and coalesce(status_code, '') <> 'done';
  end if;
  return v_value - 'note';
end $$;

-- ============ 3. 小さな部品 ============
-- 記録を 1 行足す（中からだけ呼ぶ。鍵が重なったら、エラーで止まる＝呼んだ側の変更も取り消される）
--   日時は、その瞬間の時計（同じ取引の中で続けて記録しても、順番が分かるように）
create or replace function public.recruit_op_log(
  p_applicant uuid, p_op text, p_actor uuid, p_via text, p_request_key text,
  p_before jsonb, p_after jsonb, p_result text, p_error text default null, p_reason text default null, p_at timestamptz default null)
returns uuid language sql security definer set search_path = public as $$
  insert into applicant_ops (applicant_id, op, actor_id, via, request_key, before_state, after_state, result, error, reason, created_at)
  values (p_applicant, p_op, p_actor, p_via, p_request_key, coalesce(p_before, '{}'::jsonb), coalesce(p_after, '{}'::jsonb), p_result, p_error, p_reason, coalesce(p_at, clock_timestamp()))
  returning id
$$;

-- 雇用区分: 応募フォームの種類（applicants.form_key）で見分ける。al＝アルバイト・パート／shain＝社員／それ以外（空を含む）＝分からない
--   （職種の文字 job_type からは見分けない。form_key が空の応募者に、job_type で区分が読めるものは 0 件だった＝2026-11-13 調べ）
create or replace function public.recruit_kind_of(p_form_key text)
returns text language sql immutable as $$
  select case coalesce(p_form_key, '') when 'al' then 'part' when 'shain' then 'employee' else 'unknown' end
$$;

-- 設定の 1 枠に入っている人（有効な利用者で、採用の権限がある人だけ。そうでなければ null＝設定が無いのと同じ）
create or replace function public.recruit_assign_user(p_slot text)
returns uuid language plpgsql stable security definer set search_path = public as $$
declare v_txt text; v_id uuid;
begin
  if p_slot is null or p_slot not in ('part_main', 'part_backup', 'employee_main', 'unknown_confirm') then return null; end if;
  select value ->> p_slot into v_txt from app_settings where key = 'recruit_assign';
  if v_txt is null or v_txt !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return null; end if;
  v_id := v_txt::uuid;
  if exists (select 1 from users u where u.id = v_id and u.is_active) and has_feature(v_id, 'recruit') then return v_id; end if;
  return null;
end $$;

-- 雇用区分から決まる担当（設定に値が無ければ null）。返す形: {"assignee_id": "<uuid>", "rule": "part_main|employee_main|unknown_confirm", "kind": "part|employee|unknown"}
create or replace function public.recruit_default_assignee(p_form_key text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_kind text := recruit_kind_of(p_form_key); v_id uuid; v_rule text;
begin
  if v_kind = 'part' then
    v_id := recruit_assign_user('part_main'); v_rule := 'part_main';
  elsif v_kind = 'employee' then
    v_id := recruit_assign_user('employee_main'); v_rule := 'employee_main';
  else
    v_id := coalesce(recruit_assign_user('unknown_confirm'), recruit_assign_user('part_main')); v_rule := 'unknown_confirm';
  end if;
  if v_id is null then return null; end if;
  return jsonb_build_object('assignee_id', v_id, 'rule', v_rule, 'kind', v_kind);
end $$;

-- ============ 4. 担当者を変える（Slack と管理システムの共通の入口） ============
-- 呼び方: 画面＝ログインしている本人（p_actor は見ない）／Slack＝service_role が p_actor に「押した人」を入れる。
-- 返す形: {"ok": true|false, "code": "done|noop|conflict|denied|invalid_assignee|not_found|key_reused", "message": "…", "replayed": true（同じ鍵の 2 回目）, …}
--   done＝変えた／noop＝すでにその担当／conflict＝押した人が見ていた担当と、いまの担当が違う（何も変えない）／denied＝権限なし（何も変えない）
create or replace function public.recruit_assignee_set(
  p_applicant uuid, p_assignee uuid, p_expected_assignee uuid, p_request_key text,
  p_actor uuid default null, p_via text default 'web', p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid; v_via text; v_key text := btrim(coalesce(p_request_key, ''));
  v_reason text := nullif(left(btrim(coalesce(p_reason, '')), 300), '');
  v_a record; v_prev applicant_ops%rowtype; v_op uuid; v_before jsonb; v_after jsonb; v_name text;
begin
  -- だれの操作か
  if auth.uid() is not null then v_actor := auth.uid();
  elsif onboarding_is_service() then v_actor := p_actor;
  else raise exception '認証が必要です';
  end if;
  if v_actor is null then raise exception '操作する人（p_actor）が指定されていません'; end if;
  v_via := coalesce(nullif(btrim(coalesce(p_via, '')), ''), 'web');
  if v_via not in ('slack', 'web', 'app') then raise exception 'p_via が正しくありません'; end if;
  if length(v_key) < 8 or length(v_key) > 200 then raise exception '依頼の鍵（p_request_key）が正しくありません'; end if;
  if p_applicant is null then raise exception '応募者が指定されていません'; end if;

  -- 応募者の行を押さえる（同じ応募者への操作は、ここで 1 つずつになる）
  select a.id, a.assignee_id, a.store_id into v_a from applicants a where a.id = p_applicant for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', '応募者が見つかりません'); end if;

  -- 同じ依頼の鍵の 2 回目: 何もせず、前の結果を返す
  select * into v_prev from applicant_ops where request_key = v_key;
  if found then
    if v_prev.applicant_id <> p_applicant or v_prev.op <> 'assignee_set' or v_prev.actor_id is distinct from v_actor then
      return jsonb_build_object('ok', false, 'code', 'key_reused', 'message', '同じ依頼の鍵が、別の操作で使われています');
    end if;
    return jsonb_build_object('ok', v_prev.result in ('done', 'noop'), 'code', v_prev.result, 'replayed', true, 'op_id', v_prev.id,
      'message', case v_prev.result when 'done' then '担当者を変更しました（処理済み）' when 'noop' then 'すでにその担当者です'
                                   when 'conflict' then '先に変更されています' when 'denied' then '権限がありません' else '変更できませんでした' end,
      'before_assignee', v_prev.before_state -> 'assignee_id', 'after_assignee', v_prev.after_state -> 'assignee_id');
  end if;

  v_before := jsonb_build_object('assignee_id', v_a.assignee_id);
  v_after  := jsonb_build_object('assignee_id', p_assignee, 'expected_assignee_id', p_expected_assignee);

  -- 権限（サーバー側で確かめる）: 有効な利用者で、採用の権限があり、この応募者の店舗を見られること
  if not (coalesce((select u.is_active from users u where u.id = v_actor), false)
          and has_feature(v_actor, 'recruit') and can_see_applicant(v_actor, v_a.store_id)) then
    v_op := recruit_op_log(p_applicant, 'assignee_set', v_actor, v_via, v_key, v_before, v_after, 'denied', 'no_permission', v_reason);
    return jsonb_build_object('ok', false, 'code', 'denied', 'op_id', v_op, 'message', '権限がありません');
  end if;

  -- 新しい担当: 有効な利用者で、この応募者を見られる（＝採用の権限がある）人だけ。null は「担当を外す」
  if p_assignee is not null and not (coalesce((select u.is_active from users u where u.id = p_assignee), false)
                                     and can_see_applicant(p_assignee, v_a.store_id)) then
    v_op := recruit_op_log(p_applicant, 'assignee_set', v_actor, v_via, v_key, v_before, v_after, 'failed', 'invalid_assignee', v_reason);
    return jsonb_build_object('ok', false, 'code', 'invalid_assignee', 'op_id', v_op,
      'message', '選んだ人は、この応募者の担当にできません（採用の権限が無い・退職している・担当外の店舗のいずれか）');
  end if;

  -- すでにその担当（結果は、押した人の望みどおり）
  if v_a.assignee_id is not distinct from p_assignee then
    v_op := recruit_op_log(p_applicant, 'assignee_set', v_actor, v_via, v_key, v_before, v_after, 'noop', null, v_reason);
    return jsonb_build_object('ok', true, 'code', 'noop', 'op_id', v_op, 'message', 'すでにその担当者です',
      'before_assignee', v_a.assignee_id, 'after_assignee', p_assignee);
  end if;

  -- 押した人が見ていた担当と、いまの担当が違う: 何も変えない（古い画面・古いカードからの上書きを防ぐ）
  if v_a.assignee_id is distinct from p_expected_assignee then
    select u.name into v_name from users u where u.id = v_a.assignee_id;
    v_op := recruit_op_log(p_applicant, 'assignee_set', v_actor, v_via, v_key, v_before, v_after, 'conflict', 'expected_mismatch', v_reason);
    return jsonb_build_object('ok', false, 'code', 'conflict', 'op_id', v_op, 'message', '先に変更されています',
      'current_assignee', v_a.assignee_id, 'current_name', v_name);
  end if;

  -- 変える（Slack への反映は、既存のトリガー recruit_notice_upd が拾う。ここからは Slack を呼ばない）
  update applicants set assignee_id = p_assignee, last_actor_id = v_actor, last_actor_at = now(), updated_at = now() where id = p_applicant;
  v_op := recruit_op_log(p_applicant, 'assignee_set', v_actor, v_via, v_key, v_before, v_after, 'done', null, v_reason);
  return jsonb_build_object('ok', true, 'code', 'done', 'op_id', v_op, 'message', '担当者を変更しました',
    'before_assignee', v_a.assignee_id, 'after_assignee', p_assignee);
end $$;

-- 担当にできる人の一覧（選ぶ窓に出す）。採用の権限があり、この応募者の店舗を見られる、有効な利用者だけ
create or replace function public.recruit_assignee_candidates(p_applicant uuid, p_actor uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_actor uuid; v_a record;
begin
  if auth.uid() is not null then v_actor := auth.uid();
  elsif onboarding_is_service() then v_actor := p_actor;
  else raise exception '認証が必要です';
  end if;
  if v_actor is null then raise exception '操作する人（p_actor）が指定されていません'; end if;
  select a.id, a.name, a.assignee_id, a.store_id into v_a from applicants a where a.id = p_applicant;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', '応募者が見つかりません'); end if;
  if not (coalesce((select u.is_active from users u where u.id = v_actor), false)
          and has_feature(v_actor, 'recruit') and can_see_applicant(v_actor, v_a.store_id)) then
    return jsonb_build_object('ok', false, 'code', 'denied', 'message', '権限がありません');
  end if;
  return jsonb_build_object('ok', true, 'applicant_id', v_a.id, 'applicant_name', v_a.name, 'assignee_id', v_a.assignee_id,
    'assignee_name', (select u.name from users u where u.id = v_a.assignee_id),
    'candidates', coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'name', u.name) order by u.name, u.id)
                              from users u where u.is_active and can_see_applicant(u.id, v_a.store_id)), '[]'::jsonb));
end $$;

-- ============ 5. 初期の割り当て（設定に値があるときだけ動く。無ければ今までどおり） ============
-- 順番: ① 店舗の面接担当（既存のトリガー applicant_auto_assign。変えない）→ ② それでも担当が空なら、雇用区分で決まる担当（このトリガー）。
--   このトリガーの名前は applicant_auto_assign_default。同じ「行の前」のトリガーは名前の順に動くので、既存の applicant_auto_assign のあとに動く。
-- 動くとき:
--   追加のとき … 選考中・CSV の取り込みではない・担当が空。
--   雇用区分が「分からない」から「決まった」に変わったとき … 担当が空（人が外した記録が無い）か、担当が「分からないとき」の自動の割り当てのまま、のときだけ付け替える。
-- 人が変えた担当は、戻さない（担当が入っていれば触らない／人が外した記録があれば入れ直さない）。失敗しても、応募の登録そのものは止めない。
create or replace function public.trg_applicant_assign_default()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_pick jsonb; v_last record; v_go boolean := false;
begin
  begin
    if new.status is null or new.status not in ('new', 'contacted', 'interview_set', 'interviewed') then return new; end if;
    if tg_op = 'INSERT' then
      if new.assignee_id is not null or new.source is not distinct from 'csv' then return new; end if;
      v_go := true;
    elsif tg_op = 'UPDATE' then
      if not (recruit_kind_of(old.form_key) = 'unknown' and recruit_kind_of(new.form_key) <> 'unknown') then return new; end if;
      if new.assignee_id is distinct from old.assignee_id then return new; end if;   -- 同じ保存の中で、人が担当を変えている
      select o.op, o.after_state into v_last from applicant_ops o
       where o.applicant_id = new.id and o.op in ('assignee_set', 'assignee_auto') and o.result = 'done'
       order by o.created_at desc, o.id desc limit 1;
      if new.assignee_id is null then
        v_go := not found;                                                           -- 人が外した記録があれば、入れ直さない
      else
        v_go := found and v_last.op = 'assignee_auto' and v_last.after_state ->> 'rule' = 'unknown_confirm'
                and v_last.after_state ->> 'assignee_id' = new.assignee_id::text;    -- 「分からないとき」の自動の割り当てのまま
      end if;
    end if;
    if v_go is not true then return new; end if;
    v_pick := recruit_default_assignee(new.form_key);
    if v_pick is null then return new; end if;                                       -- 設定に値が無い＝今までどおり
    if (v_pick ->> 'assignee_id')::uuid is not distinct from new.assignee_id then return new; end if;
    perform recruit_op_log(new.id, 'assignee_auto', null, 'auto', 'auto:assign:' || new.id::text || ':' || gen_random_uuid()::text,
                           jsonb_build_object('assignee_id', new.assignee_id), v_pick, 'done', null, null);
    new.assignee_id := (v_pick ->> 'assignee_id')::uuid;
  exception when others then
    raise warning 'applicant_assign_default: %', sqlerrm;
  end;
  return new;
end $$;

drop trigger if exists applicant_auto_assign_default on public.applicants;
create trigger applicant_auto_assign_default before insert or update of form_key on public.applicants
  for each row execute function public.trg_applicant_assign_default();

-- ============ 6. 24 時間の未対応（予備の担当へ知らせる対象を返すだけ。送信も、担当の変更も、しない） ============
-- 対象: 選考中・最後のやり取りが「応募者から」のまま・対応済みにしていない・アルバイト／パート（区分が分からないものを含む）・
--       返信していない最初のメッセージから p_hours（設定 unhandled_hours・既定 24）時間以上・直近 24 時間に「知らせた印」が無い・担当が予備の担当本人ではない。
-- 予備の担当（設定 part_backup）が決まっていなければ、何も返さない。テスト用の応募者（answers._test = true）は、p_include_test = true のときだけ返す。
-- 返す形: [{"applicant_id", "assignee_id", "backup_user_id", "waiting_since", "kind"}, …]（氏名・本文は返さない）
create or replace function public.recruit_unhandled_targets(p_now timestamptz default now(), p_include_test boolean default false)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_backup uuid; v_hours integer := 24; v_txt text; v_out jsonb;
begin
  if not onboarding_is_service() then raise exception '権限がありません（サーバー側の処理だけ）'; end if;
  v_backup := recruit_assign_user('part_backup');
  if v_backup is null then return '[]'::jsonb; end if;
  select value ->> 'unhandled_hours' into v_txt from app_settings where key = 'recruit_assign';
  if v_txt ~ '^[0-9]{1,3}$' then
    if v_txt::integer >= 1 then v_hours := v_txt::integer; end if;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('applicant_id', x.id, 'assignee_id', x.assignee_id, 'backup_user_id', v_backup,
                                               'waiting_since', x.since, 'kind', x.kind) order by x.since, x.id), '[]'::jsonb)
    into v_out
    from (
      select a.id, a.assignee_id, recruit_kind_of(a.form_key) as kind,
             coalesce((select min(m.sent_at) from applicant_messages m
                        where m.applicant_id = a.id and m.direction = 'in'
                          and m.sent_at > greatest(
                                coalesce((select max(r.sent_at) from applicant_messages r where r.applicant_id = a.id and r.direction = 'out'), '-infinity'::timestamptz),
                                coalesce(a.handled_at, '-infinity'::timestamptz))),
                      a.last_msg_at) as since
        from applicants a
       where a.status in ('new', 'contacted', 'interview_set', 'interviewed')
         and a.last_msg_dir = 'in' and a.last_msg_at is not null
         and not (a.handled_at is not null and a.handled_at >= a.last_msg_at)
         and recruit_kind_of(a.form_key) in ('part', 'unknown')
         and a.assignee_id is distinct from v_backup
         and (coalesce(p_include_test, false) or coalesce(a.answers ->> '_test', '') <> 'true')
    ) x
   where x.since <= p_now - make_interval(hours => v_hours)
     and not exists (select 1 from applicant_ops n
                      where n.applicant_id = x.id and n.op = 'backup_notice' and n.result = 'done' and n.created_at > p_now - interval '24 hours');
  return v_out;
end $$;

-- 「予備の担当へ知らせた」印を付ける（知らせる処理が、送る直前に呼ぶ。true＝いま印を付けた＝送ってよい／false＝直近 24 時間か、同じ日にもう付いている＝送らない）。
-- 同じ応募者に 1 日 1 回まで。担当者（applicants.assignee_id）は変えない＝知らせと、正式な担当の変更は別。
create or replace function public.recruit_unhandled_mark(p_applicant uuid, p_now timestamptz default now())
returns boolean language plpgsql security definer set search_path = public as $$
declare v_backup uuid; v_key text; v_id uuid;
begin
  if not onboarding_is_service() then raise exception '権限がありません（サーバー側の処理だけ）'; end if;
  v_backup := recruit_assign_user('part_backup');
  if p_applicant is null or v_backup is null then return false; end if;
  perform 1 from applicants a where a.id = p_applicant for update;   -- 同時に 2 回呼ばれても、1 つずつにする
  if not found then return false; end if;
  if exists (select 1 from applicant_ops n
              where n.applicant_id = p_applicant and n.op = 'backup_notice' and n.result = 'done' and n.created_at > p_now - interval '24 hours') then
    return false;
  end if;
  v_key := 'auto:backup_notice:' || p_applicant::text || ':' || to_char(p_now at time zone 'Asia/Tokyo', 'YYYYMMDD');
  insert into applicant_ops (applicant_id, op, actor_id, via, request_key, before_state, after_state, result, created_at)
  values (p_applicant, 'backup_notice', null, 'auto', v_key, '{}'::jsonb, jsonb_build_object('backup_user_id', v_backup), 'done', p_now)
  on conflict (request_key) do nothing
  returning id into v_id;
  return v_id is not null;
end $$;

-- ============ 7. 権限 ============
revoke all on function public.recruit_actions_set(boolean), public.recruit_kind_of(text), public.recruit_assign_user(text), public.recruit_default_assignee(text),
  public.recruit_op_log(uuid, text, uuid, text, text, jsonb, jsonb, text, text, text, timestamptz),
  public.recruit_assignee_set(uuid, uuid, uuid, text, uuid, text, text), public.recruit_assignee_candidates(uuid, uuid),
  public.trg_applicant_assign_default(), public.recruit_unhandled_targets(timestamptz, boolean), public.recruit_unhandled_mark(uuid, timestamptz)
  from public, anon, authenticated;
-- 画面（ログインしている人）と Edge Function の両方から呼ぶもの。中で、権限を確かめる
grant execute on function public.recruit_assignee_set(uuid, uuid, uuid, text, uuid, text, text), public.recruit_assignee_candidates(uuid, uuid),
  public.recruit_actions_set(boolean), public.recruit_kind_of(text) to authenticated, service_role;
-- Edge Function（service_role）だけ
grant execute on function public.recruit_assign_user(text), public.recruit_default_assignee(text),
  public.recruit_unhandled_targets(timestamptz, boolean), public.recruit_unhandled_mark(uuid, timestamptz) to service_role;

-- ============ 確認用（読むだけ） ============
-- select value - 'note' from app_settings where key in ('recruit_assign', 'recruit_slack');
-- select tgname from pg_trigger where tgrelid = 'public.applicants'::regclass and not tgisinternal order by tgname;   -- applicant_auto_assign の次に applicant_auto_assign_default
-- select op, via, result, count(*) from applicant_ops group by 1, 2, 3 order by 1, 2, 3;
