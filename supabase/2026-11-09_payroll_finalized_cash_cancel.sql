-- ============================================================
-- 2026-11-09 担当B（nippo）— ①cash_handoff_complete の退行修正 ②給料確定の「確定の印」（法人IDキー）
--   ③現金手渡し対象者を確定済み(月×法人)に限定 ④手渡し取消（サイン等のリセット＋取消履歴）
-- 【状態】事前報告（未適用）。設計(U-23/U-24=全部推奨)・修正4点を反映。U-25=推奨で回答済み（2026-11-09）:
--   ①既存の11月テンプレ振込タスクに確認工程を足して紐づける ②取消時に給与仕訳の「振込完了」印も戻す（MF登録済み仕訳は消さず注意通知）。
--   ユーザー方針「連携・自動化は全部やる。ミスが起きたらアラートで分かるように」→ 確定・取消・チェック連携失敗・毎朝の整合チェックでLark/Slack通知
-- 【前提】2026-11-03_payroll_funcs_concurrent_staff.sql 適用済み ＋ 2026-11-09_cash_handoff_complete_restore.sql（退行修正・先に適用）。
--   本ファイルの§5（cash_handoff_complete）はその復元版を法人ID対応にして置き換える
--
-- 【① 退行の修正】11-03のSQLで cash_handoff_complete を作り直した際、09-08版にあった次の3点を落としていた:
--    (a) 既に完了済みの再実行で completed_at を上書きしない（二重通知ガード）
--    (b) 本部タスクのチェックリスト連携（hq_check_payroll_task_item）
--    (c) 全員完了時のLark/Slack完了通知
--   本ファイルで復元（11-03で追加した契約別の動きは維持）。
-- 【② キーは法人ID（corporation_id）】表示名(p_corp)ではなく corporations.id で持つ。
--   payroll_finalized(year_month, corporation_id) 新設。payroll_task_links に corporation_id を足し、主キーを (year_month,kind,corporation_id) へ。
-- 【移行(backfill)】2026-11 より前の既存データだけ、トーホー(既定契約の法人)として入れる。2026-11以降は入れない（＝11月分は給料確定ボタンを押すまで手渡し画面は空）
-- 【③】cash_handoff_targets を「確定済み(月×法人)の分だけ」返す形に。元の中身は cash_handoff_targets_raw（内部用・確定判定なし）へ移す
-- 【④】sf_cash_handoff_cancellations 新設 + cash_handoff_cancel RPC。サイン画像は消さず archive 名へコピー(クライアントがコピーしてpathsを渡す)
-- 【権限】新テーブルはRLS有効・anon/PUBLIC無権限・authenticatedは必要最小限。書き込みは RPC(SECURITY DEFINER) 経由のみ。
--   取消は cash_handoff_can_write(store_id)（既存の書き込み範囲）で判定
-- 【影響】過去月(〜2026-10)の手渡し画面は backfill で従来どおり見える。11月分は確定後に出る。兼務は法人別に確定・取消が独立
-- 【rollback】旧定義へ戻さず修正して進める方針。どうしても戻す場合:
--   cash_handoff_targets を raw の本文で作り直し／drop table payroll_finalized, sf_cash_handoff_cancellations／
--   payroll_task_links の主キーを (year_month,kind) に戻し列 corporation_id を削除（法人2件以上のタスクが入る前なら可）
-- ============================================================

-- ---------- 0. 新テーブル ----------
create table if not exists payroll_finalized (
  year_month text not null check (year_month ~ '^\d{4}-\d{2}$'),
  corporation_id uuid not null references corporations(id),
  finalized_at timestamptz not null default now(),
  finalized_by uuid references users(id),
  primary key (year_month, corporation_id)
);
comment on table payroll_finalized is '給料確定ボタン(hq_create_payroll_tasks)を押した「月×法人」の印（担当B・2026-11-09）。現金手渡し画面の表示対象の根拠。書き込みはRPC経由のみ';
alter table payroll_finalized enable row level security;
revoke all on payroll_finalized from public, anon;
drop policy if exists payroll_finalized_read on payroll_finalized;
create policy payroll_finalized_read on payroll_finalized for select to authenticated using (
  exists(select 1 from users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO','HQ','TENCHO','TEAM')))
);
grant select on payroll_finalized to authenticated;

-- ---------- 1. payroll_task_links を法人IDキーへ（1トランザクション） ----------
alter table payroll_task_links add column if not exists corporation_id uuid references corporations(id);
do $$
declare v_toho uuid;
begin
  select sc.corporation_id into v_toho from smaregi_contracts sc where sc.is_default limit 1;
  if v_toho is null then raise exception '既定のスマレジ契約(is_default)の法人が見つかりません'; end if;
  -- 既存行はすべてトーホーとして扱う（11月以降のリンクはまだ無い。念のため年月で限定）
  update payroll_task_links set corporation_id = v_toho where corporation_id is null and year_month < '2026-11';
  if exists (select 1 from payroll_task_links where corporation_id is null) then
    raise exception '2026-11以降の payroll_task_links が存在します。法人を確認してから適用してください';
  end if;
  alter table payroll_task_links alter column corporation_id set not null;
  alter table payroll_task_links drop constraint if exists payroll_task_links_pkey;
  alter table payroll_task_links add constraint payroll_task_links_pkey primary key (year_month, kind, corporation_id);

  -- 確定の印の backfill: 既存の給料確定タスク（リンク）と、サイン記録のある月（〜2026-10・トーホー契約）
  insert into payroll_finalized(year_month, corporation_id, finalized_at)
  select x.year_month, v_toho, min(x.at) from (
    select year_month, created_at as at from payroll_task_links where year_month < '2026-11'
    union all
    select year_month, created_at from sf_cash_handoff_signatures
      where year_month < '2026-11' and contract_id = (select sc.contract_id from smaregi_contracts sc where sc.is_default limit 1)
  ) x group by x.year_month
  on conflict do nothing;
end $$;

-- ---------- 2. 取消履歴 ----------
create table if not exists sf_cash_handoff_cancellations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id),
  year_month text not null,
  contract_id text not null,
  corporation_id uuid references corporations(id),
  cancelled_at timestamptz not null default now(),
  cancelled_by uuid references users(id),
  reason text not null,
  prev_payer_id uuid, prev_payer_checked_at timestamptz, prev_receiver_checked_at timestamptz, prev_completed_at timestamptz,
  archived_paths jsonb not null default '{}'::jsonb,  -- {payer_signature, receiver_signature, handoff_photo} のarchive後パス
  paid_at_reset integer not null default 0             -- paid_atを戻した給与仕訳の件数
);
comment on table sf_cash_handoff_cancellations is '現金手渡しの取消履歴（誰が・いつ・理由・戻す前の状態・退避した画像）。担当B・2026-11-09。書き込みはcash_handoff_cancel経由のみ';
alter table sf_cash_handoff_cancellations enable row level security;
revoke all on sf_cash_handoff_cancellations from public, anon;
drop policy if exists cash_cancel_read on sf_cash_handoff_cancellations;
create policy cash_cancel_read on sf_cash_handoff_cancellations for select to authenticated using (
  exists(select 1 from users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO','HQ','TENCHO','TEAM')))
);
grant select on sf_cash_handoff_cancellations to authenticated;
create index if not exists sf_cash_cancel_ym_idx on sf_cash_handoff_cancellations(year_month, user_id);

-- ---------- 3. cash_handoff_targets_raw（11-03版の本文そのまま・確定判定なし／内部用） ----------
drop function if exists public.cash_handoff_targets_raw(text);
create or replace function public.cash_handoff_targets_raw(p_year_month text)
 returns table(user_id uuid, name text, store_id uuid, amount numeric, is_active boolean, contract_id text, corp_name text)
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_caller users%rowtype; v_stores uuid[]; v_scope text; v_def text;
begin
  select * into v_caller from users u0 where u0.id = auth.uid() and u0.is_active;
  if v_caller.id is null or not (v_caller.is_master or v_caller.role in ('CEO','HQ','TENCHO','TEAM')) then
    raise exception '権限がありません';
  end if;
  if v_caller.is_master then
    v_stores := null;
  else
    select scope into v_scope from cash_handoff_role_scope where role = v_caller.role;
    v_scope := coalesce(v_scope, 'own');
    if v_scope = 'all' then v_stores := null;
    elsif v_scope = 'team' then v_stores := team_store_ids(v_caller.team_id) || user_store_ids(v_caller.id);
    else v_stores := user_store_ids(v_caller.id);
    end if;
  end if;
  select sc.contract_id into v_def from smaregi_contracts sc where sc.is_default limit 1;
  return query
    select u.id, u.name,
      (select us.store_id from user_stores us where us.user_id = u.id order by us.is_primary desc limit 1),
      coalesce(s.amt, 0), u.is_active, coalesce(s.contract_id, v_def),
      (select c.name from smaregi_contracts sc2 join corporations c on c.id = sc2.corporation_id where sc2.contract_id = coalesce(s.contract_id, v_def))
    from payroll_bank_accounts pba
    join users u on u.id = pba.user_id
    left join (select sp.user_id, sp.contract_id, sum(sp.net_pay) as amt
                 from sf_payroll_sync sp where sp.year_month = p_year_month group by sp.user_id, sp.contract_id) s on s.user_id = u.id
    where pba.payment_method = 'cash'
      and (v_stores is null or (select us2.store_id from user_stores us2 where us2.user_id = u.id order by us2.is_primary desc limit 1) = any(v_stores));
end;
$function$;
revoke all on function public.cash_handoff_targets_raw(text) from public, anon;
grant execute on function public.cash_handoff_targets_raw(text) to authenticated;

-- ③ 画面用: 給料確定済み(月×法人)の分だけ返す（戻り値の形は11-03版と同じ）
create or replace function public.cash_handoff_targets(p_year_month text)
 returns table(user_id uuid, name text, store_id uuid, amount numeric, is_active boolean, contract_id text, corp_name text)
 language sql
 stable
 security definer
 set search_path to 'public'
as $function$
  select r.* from cash_handoff_targets_raw(p_year_month) r
   where exists (select 1 from smaregi_contracts sc join payroll_finalized f on f.corporation_id = sc.corporation_id and f.year_month = p_year_month
                  where sc.contract_id = r.contract_id);
$function$;
revoke all on function public.cash_handoff_targets(text) from public, anon;
grant execute on function public.cash_handoff_targets(text) to authenticated;

-- 画面の案内用: 給料確定済みの法人一覧（未確定月に「給料確定後に表示されます」と出す）
create or replace function public.cash_handoff_finalized_corps(p_year_month text)
 returns table(corporation_id uuid, corp_name text, finalized_at timestamptz)
 language sql
 stable
 security definer
 set search_path to 'public'
as $function$
  select f.corporation_id, c.name, f.finalized_at
    from payroll_finalized f join corporations c on c.id = f.corporation_id
   where f.year_month = p_year_month
     and exists(select 1 from users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO','HQ','TENCHO','TEAM')));
$function$;
revoke all on function public.cash_handoff_finalized_corps(text) from public, anon;
grant execute on function public.cash_handoff_finalized_corps(text) to authenticated;

-- ---------- 4. hq_check_payroll_task_item（法人IDキー。3引数の呼び出しは既定=トーホー法人で互換） ----------
drop function if exists public.hq_check_payroll_task_item(text, text, text);
create or replace function public.hq_check_payroll_task_item(p_year_month text, p_kind text, p_person_name text, p_corp_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_caller users%rowtype; v_link payroll_task_links%rowtype; v_item hq_step_checklist_items%rowtype;
  v_total int; v_done int; v_task hq_tasks%rowtype; v_was_done boolean; v_corp uuid;
begin
  select * into v_caller from users u0 where u0.id = auth.uid() and u0.is_active;
  if v_caller.id is null or not (v_caller.is_master or v_caller.role in ('CEO','HQ','TENCHO','TEAM')) then
    raise exception '権限がありません';
  end if;
  if p_kind not in ('transfer','cash') then raise exception 'kindはtransferかcashを指定してください'; end if;
  v_corp := coalesce(p_corp_id, (select sc.corporation_id from smaregi_contracts sc where sc.is_default limit 1));

  select * into v_link from payroll_task_links where year_month = p_year_month and kind = p_kind and corporation_id = v_corp;
  if v_link.step_id is null then
    return jsonb_build_object('ok', false, 'reason', '対応する本部タスクが見つかりません（給料確定が未実行の可能性があります）');
  end if;
  select * into v_item from hq_step_checklist_items
   where step_id = v_link.step_id
     and replace(replace(title,' ',''),chr(12288),'') = replace(replace(p_person_name,' ',''),chr(12288),'');
  if v_item.id is null then
    return jsonb_build_object('ok', false, 'reason', p_person_name||' はこのタスクのチェック項目に見つかりません');
  end if;
  if v_item.checked_at is null then
    update hq_step_checklist_items set checked_at = now(), checked_by = auth.uid() where id = v_item.id;
  end if;
  select count(*), count(*) filter (where checked_at is not null) into v_total, v_done
    from hq_step_checklist_items where step_id = v_link.step_id;
  select * into v_task from hq_tasks where id = v_link.task_id;
  v_was_done := v_task.status = 'done';
  if v_total > 0 and v_total = v_done then
    update hq_task_steps set completed_at = coalesce(completed_at, now()), completed_by = coalesce(completed_by, auth.uid())
      where id = v_link.step_id;
    if not v_was_done then
      perform notify_lark('✅ '||v_task.title||' が完了しました（全'||v_total||'件チェック済み）');
    end if;
  end if;
  return jsonb_build_object('ok', true, 'checked', v_done, 'total', v_total);
end;
$function$;
revoke all on function public.hq_check_payroll_task_item(text, text, text, uuid) from public, anon;
grant execute on function public.hq_check_payroll_task_item(text, text, text, uuid) to authenticated;

-- ---------- 5. cash_handoff_complete（退行修正: 09-08版の3機能を復元 + 11-03の契約別を維持） ----------
create or replace function public.cash_handoff_complete(p_user_id uuid, p_year_month text, p_contract_id text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_row sf_cash_handoff_signatures%rowtype; v_synced_rows integer := 0; v_contract text; v_tenant text;
  v_already_done boolean; v_uname text; v_total int; v_done int; v_corp uuid; v_corp_name text; v_def text; v_chk jsonb;
begin
  if not exists(select 1 from users where id = auth.uid() and is_active and (is_master or role in ('CEO','HQ','TENCHO','TEAM'))) then
    raise exception '権限がありません';
  end if;
  select sc.contract_id into v_def from smaregi_contracts sc where sc.is_default limit 1;
  v_contract := coalesce(p_contract_id, v_def);
  select * into v_row from sf_cash_handoff_signatures where user_id = p_user_id and year_month = p_year_month and contract_id = v_contract;
  if v_row.id is null then raise exception '対象の記録が見つかりません'; end if;
  if v_row.payer_checked_at is null or v_row.receiver_checked_at is null then
    raise exception '渡した側・受け取った側、両方の確認が必要です';
  end if;

  v_already_done := v_row.completed_at is not null;                                    -- (a) 復元
  update sf_cash_handoff_signatures set completed_at = coalesce(completed_at, now()), updated_at = now() where id = v_row.id;

  select case sc.corporation_hint when 'toho' then 'default' else sc.corporation_hint end, sc.corporation_id, c.name
    into v_tenant, v_corp, v_corp_name
    from smaregi_contracts sc left join corporations c on c.id = sc.corporation_id where sc.contract_id = v_contract;
  begin
    update payroll_journal_records set paid_at = now(), paid_by = auth.uid()
     where user_id = p_user_id and year_month = p_year_month and paid_at is null
       and (v_tenant is null or tenant_id = v_tenant);
    get diagnostics v_synced_rows = row_count;
  exception when undefined_table then v_synced_rows := 0;
  end;

  if not v_already_done then
    begin                                                                              -- (b) 復元: 本部タスクのチェックリスト連携（法人別）
      select name into v_uname from users where id = p_user_id;
      if v_uname is not null then
        v_chk := hq_check_payroll_task_item(p_year_month, 'cash', v_uname, v_corp);
        -- 自動連携が効かなかったときは黙らず通知（本部タスクの手動チェックが必要）
        if not coalesce((v_chk->>'ok')::boolean, false) then
          perform notify_lark('⚠️ 現金手渡し: 本部タスクのチェックを自動で付けられませんでした（'||p_year_month||'・'||coalesce(v_corp_name,'')||'・'||v_uname||'さん）。理由: '||coalesce(v_chk->>'reason','不明')||'。本部タスクを手動で確認してください');
        end if;
      end if;
    exception when others then
      begin perform notify_lark('⚠️ 現金手渡し: 本部タスクの自動チェックでエラーが出ました（'||p_year_month||'・'||coalesce(v_corp_name,'')||'）。本部タスクを手動で確認してください'); exception when others then null; end;
    end;
    begin                                                                              -- (c) 復元: この月×この契約の対象者が全員完了したら通知
      select count(distinct pba.user_id) into v_total
        from payroll_bank_accounts pba join users u on u.id = pba.user_id and u.is_active
       where pba.payment_method = 'cash'
         and (exists (select 1 from sf_payroll_sync sp where sp.user_id = pba.user_id and sp.year_month = p_year_month and sp.contract_id = v_contract)
              or (v_contract = v_def and not exists (select 1 from sf_payroll_sync sp where sp.user_id = pba.user_id and sp.year_month = p_year_month)));
      select count(distinct s.user_id) into v_done
        from sf_cash_handoff_signatures s
        join payroll_bank_accounts pba on pba.user_id = s.user_id and pba.payment_method = 'cash'
        join users u on u.id = s.user_id and u.is_active
       where s.year_month = p_year_month and s.contract_id = v_contract and s.completed_at is not null;
      if v_total > 0 and v_total = v_done then
        perform notify_lark('💴 現金手渡し完了：'||p_year_month||'分（'||coalesce(v_corp_name,'')||'）の現金手渡し対象者 全'||v_total||'名の受け渡しが完了しました（nippo「現金手渡し・サイン」）');
      end if;
    exception when others then null;
    end;
  end if;
  return jsonb_build_object('ok', true, 'journal_marked_paid', v_synced_rows > 0);
end;
$function$;
grant execute on function public.cash_handoff_complete(uuid, text, text) to authenticated;

-- ---------- 6. 手渡し取消（U-24） ----------
--  ・渡した側/受け取った側のサイン・確認日時・完了日時をリセット（引き出し確認と金額は残す）→ 再サイン可能
--  ・サイン画像は消さない: 画面側(nippo)が cash-signatures 内で archive 名へコピーし、そのパスを p_archived で渡す（履歴に保存）
--  ・paid_at は p_reset_paid=true のときだけ、この人×月×この契約の法人(tenant)の給与仕訳だけ戻す（既定false＝U-25の回答待ち）。mf_* 等の項目は触らない
--  ・本部タスクのチェックも戻す（対象人のチェックを外し、工程の完了印も外す）。失敗しても取消自体は止めない
create or replace function public.cash_handoff_cancel(p_user_id uuid, p_year_month text, p_contract_id text default null, p_reason text default null, p_archived jsonb default '{}'::jsonb, p_reset_paid boolean default true)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_row sf_cash_handoff_signatures%rowtype; v_contract text; v_def text; v_tenant text; v_corp uuid; v_reset int := 0;
  v_uname text; v_link payroll_task_links%rowtype; v_reason text := btrim(coalesce(p_reason,'')); v_mf int := 0; v_corp_name text;
begin
  select sc.contract_id into v_def from smaregi_contracts sc where sc.is_default limit 1;
  v_contract := coalesce(p_contract_id, v_def);
  select * into v_row from sf_cash_handoff_signatures where user_id = p_user_id and year_month = p_year_month and contract_id = v_contract;
  if v_row.id is null then raise exception '対象の記録が見つかりません'; end if;
  if not cash_handoff_can_write(v_row.store_id) then raise exception '権限がありません'; end if;
  if length(v_reason) < 1 or length(v_reason) > 200 then raise exception '取消の理由を入力してください（200文字まで）'; end if;
  if v_row.payer_checked_at is null and v_row.receiver_checked_at is null and v_row.completed_at is null then
    raise exception '取り消す内容がありません（渡した側・受け取った側とも未確認です）';
  end if;

  select sc.corporation_id, case sc.corporation_hint when 'toho' then 'default' else sc.corporation_hint end into v_corp, v_tenant
    from smaregi_contracts sc where sc.contract_id = v_contract;

  select c.name into v_corp_name from corporations c where c.id = v_corp;
  if p_reset_paid then
    begin
      -- 会計ソフト(MF)へ登録済みの仕訳は自動では消さない（印だけ戻す）。登録済みの件数を数えて注意を出す
      select count(*) into v_mf from payroll_journal_records
       where user_id = p_user_id and year_month = p_year_month and paid_at is not null and mf_journal_id is not null
         and (v_tenant is null or tenant_id = v_tenant);
      update payroll_journal_records set paid_at = null, paid_by = null
       where user_id = p_user_id and year_month = p_year_month and paid_at is not null
         and (v_tenant is null or tenant_id = v_tenant);
      get diagnostics v_reset = row_count;
    exception when undefined_table then v_reset := 0;
    end;
  end if;

  insert into sf_cash_handoff_cancellations(user_id, year_month, contract_id, corporation_id, cancelled_by, reason,
      prev_payer_id, prev_payer_checked_at, prev_receiver_checked_at, prev_completed_at, archived_paths, paid_at_reset)
  values (p_user_id, p_year_month, v_contract, v_corp, auth.uid(), v_reason,
      v_row.payer_id, v_row.payer_checked_at, v_row.receiver_checked_at, v_row.completed_at,
      coalesce(p_archived,'{}'::jsonb) || jsonb_build_object('orig_payer_signature', v_row.payer_signature_path,
          'orig_receiver_signature', v_row.receiver_signature_path, 'orig_handoff_photo', v_row.handoff_photo_path), v_reset);

  update sf_cash_handoff_signatures set
      payer_id = null, payer_checked_at = null, payer_signature_path = null, handoff_photo_path = null,
      receiver_checked_at = null, receiver_signature_path = null, completed_at = null, updated_at = now()
   where id = v_row.id;

  begin
    select name into v_uname from users where id = p_user_id;
    select * into v_link from payroll_task_links where year_month = p_year_month and kind = 'cash' and corporation_id = v_corp;
    if v_link.step_id is not null and v_uname is not null then
      update hq_step_checklist_items set checked_at = null, checked_by = null
       where step_id = v_link.step_id
         and replace(replace(title,' ',''),chr(12288),'') = replace(replace(v_uname,' ',''),chr(12288),'');
      update hq_task_steps set completed_at = null, completed_by = null where id = v_link.step_id and completed_at is not null;
    end if;
  exception when others then null;
  end;

  begin
    perform notify_lark('↩️ 現金手渡しを取り消しました: '||p_year_month||'・'||coalesce(v_corp_name,'')||'・'||coalesce(v_uname,'')||'さん／理由: '||v_reason
      ||case when v_reset > 0 then '／給与仕訳の「振込完了」印を'||v_reset||'件戻しました' else '' end
      ||case when v_mf > 0 then E'\n⚠️ 会計ソフト(MF)に登録済みの仕訳が'||v_mf||'件あります。自動では消していないので、必要なら会計側で確認してください' else '' end);
  exception when others then null;
  end;
  return jsonb_build_object('ok', true, 'paid_at_reset', v_reset, 'mf_registered', v_mf);
end;
$function$;
revoke all on function public.cash_handoff_cancel(uuid, text, text, text, jsonb, boolean) from public, anon;
grant execute on function public.cash_handoff_cancel(uuid, text, text, text, jsonb, boolean) to authenticated;

-- ---------- 7. hq_create_payroll_tasks（法人ID版）: 確定の印を付け、タスクを法人別に発行 ----------
-- 引数を増やすので旧シグネチャ(text,text)を同じトランザクションで drop し、既定値つき末尾引数の1本だけにする（同名オーバーロードを残さない）
drop function if exists public.hq_create_payroll_tasks(text, text);
create or replace function public.hq_create_payroll_tasks(p_year_month text, p_corp text default null, p_corp_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_caller users%rowtype;
  v_month_start date; v_due_month_start date; v_mon int;
  v_transfer_due date; v_cash_due date;
  v_transfer_task uuid; v_transfer_step uuid; v_cash_task uuid; v_cash_step uuid;
  v_transfer_names text[]; v_cash_names text[];
  v_name text; v_sort int; v_assignees uuid[];
  v_existing payroll_task_links%rowtype;
  v_contracts text[]; v_corp_id uuid;
  v_tpl uuid[]; v_ttask hq_tasks%rowtype; v_attached boolean := false; v_warn text := '';
begin
  select * into v_caller from users u0 where u0.id = auth.uid() and u0.is_active;
  if v_caller.id is null or not (v_caller.is_master or v_caller.role in ('CEO','HQ')) then
    raise exception '権限がありません（マスター・本部・社長のみ）';
  end if;
  if p_year_month !~ '^\d{4}-\d{2}$' then raise exception 'year_monthは YYYY-MM 形式で指定してください'; end if;
  v_month_start := to_date(p_year_month || '-01', 'YYYY-MM-DD');
  v_mon := extract(month from v_month_start)::int;
  v_due_month_start := v_month_start + interval '1 month';
  v_transfer_due := jp_prev_business_day((v_due_month_start + 14)::date);
  v_cash_due := jp_prev_business_day((v_due_month_start + 24)::date);

  -- 法人の決め方（担当C確認: ボタンが渡す名前は corporations.name と完全一致）:
  --   ① p_corp_id（法人ID）があればそれを優先（実在しなければエラー） ② 無ければ p_corp（名前）→ID。名前が無い呼び出し（引数なし）だけ従来の既定 'N-Style'
  --   ID も名前も解決できないときは既定へ落とさずエラーで止める（別法人の確定をトーホー等として記録する事故を防ぐ）
  if p_corp_id is not null then
    select c.id, c.name into v_corp_id, p_corp from corporations c where c.id = p_corp_id;
    if v_corp_id is null then raise exception '法人IDが見つかりません'; end if;
  else
    p_corp := coalesce(p_corp, 'N-Style');
    select c.id into v_corp_id from corporations c where c.name = p_corp limit 1;
    if v_corp_id is null then raise exception '法人名「%」が見つかりません（corporations.name と一致する名前、または法人IDを指定してください）', p_corp; end if;
  end if;
  select array_agg(sc.contract_id) into v_contracts from smaregi_contracts sc where sc.corporation_id = v_corp_id and sc.is_active;
  if v_contracts is not null and array_length(v_contracts, 1) = 0 then v_contracts := null; end if;

  -- 確定の印（月×法人）。以降、現金手渡し画面にこの法人の対象者が出る
  insert into payroll_finalized(year_month, corporation_id, finalized_by) values (p_year_month, v_corp_id, auth.uid())
  on conflict (year_month, corporation_id) do nothing;

  select array_agg(u.name order by u.name) into v_transfer_names
    from payroll_bank_accounts pba join users u on u.id = pba.user_id
    where pba.payment_method = 'bank_transfer'
      and exists (select 1 from sf_payroll_sync s where s.user_id = u.id and s.year_month = p_year_month and coalesce(s.net_pay, 0) > 0
                    and (v_contracts is null or s.contract_id = any(v_contracts)))
      and not exists (select 1 from sf_payroll_hidden h where h.user_id = u.id and h.year_month = p_year_month);
  select array_agg(t.name order by t.name) into v_cash_names
    from cash_handoff_targets_raw(p_year_month) t where coalesce(t.amount, 0) > 0
      and (v_contracts is null or t.contract_id = any(v_contracts))
      and not exists (select 1 from sf_payroll_hidden h where h.user_id = t.user_id and h.year_month = p_year_month);

  select * into v_existing from payroll_task_links where year_month = p_year_month and kind = 'transfer' and corporation_id = v_corp_id;
  if v_existing.task_id is not null then
    v_transfer_task := v_existing.task_id;
  elsif v_transfer_names is not null and array_length(v_transfer_names,1) > 0 then
    select coalesce(array_agg(id), array[]::uuid[]) into v_assignees
      from users where is_active and replace(replace(name,' ',''),chr(12288),'') = any(array['青山純','原美香','中山俊士']);
    -- 月次テンプレ由来の既存「【振込◯◯】給料」タスク（同じ月・同じ法人・未削除）があれば新規に作らず、そこに確認工程を足して紐づける（二重防止・U-25①）
    select array_agg(t.id) into v_tpl from hq_tasks t
     where t.corp = p_corp and t.template_id is not null and t.deleted_at is null
       and t.title ~ ('^'||v_mon||'月分[[:space:]　]*【振込[^】]*】給料$') and t.title not like '%口振%'
       and t.due_date >= v_month_start and t.due_date <= (v_month_start + 75);
    if v_tpl is not null and array_length(v_tpl,1) > 1 then
      v_warn := v_warn || '既存の振込タスクが'||array_length(v_tpl,1)||'件見つかったため、自動では紐づけず新規作成もしていません。本部で整理してください。';
    elsif v_tpl is not null then
      select * into v_ttask from hq_tasks where id = v_tpl[1];
      if v_ttask.status = 'done' then
        v_warn := v_warn || '既存の振込タスクが完了済みのため、紐づけも新規作成もしていません。';
      else
        v_transfer_task := v_ttask.id;
        insert into hq_task_steps(task_id, title, assignee_ids, due_date, sort_order, kind)
        values (v_transfer_task, '振込対象者の確認（給料確定リスト）', v_assignees, v_ttask.due_date,
                (select coalesce(max(sort_order),0) + 10 from hq_task_steps where task_id = v_transfer_task), 'step')
        returning id into v_transfer_step;
        v_sort := 10;
        foreach v_name in array v_transfer_names loop
          insert into hq_step_checklist_items(step_id, title, sort_order) values (v_transfer_step, v_name, v_sort);
          v_sort := v_sort + 10;
        end loop;
        insert into payroll_task_links(year_month, kind, task_id, step_id, corporation_id) values (p_year_month, 'transfer', v_transfer_task, v_transfer_step, v_corp_id);
        v_attached := true;
      end if;
    else
      insert into hq_tasks(title, corp, freq, target_date, due_date, notes, description, visibility, created_by)
      values (v_mon||'月分　給料振込　'||p_corp, p_corp, 'once', current_date, v_transfer_due, '',
        '給料確定ボタンにより自動発行（対象'||array_length(v_transfer_names,1)||'名）', 'all', auth.uid())
      returning id into v_transfer_task;
      insert into hq_task_steps(task_id, title, assignee_ids, due_date, sort_order, kind)
      values (v_transfer_task, '振込完了を確認', v_assignees, v_transfer_due, 10, 'step') returning id into v_transfer_step;
      v_sort := 10;
      foreach v_name in array v_transfer_names loop
        insert into hq_step_checklist_items(step_id, title, sort_order) values (v_transfer_step, v_name, v_sort);
        v_sort := v_sort + 10;
      end loop;
      insert into payroll_task_links(year_month, kind, task_id, step_id, corporation_id) values (p_year_month, 'transfer', v_transfer_task, v_transfer_step, v_corp_id);
    end if;
  end if;

  select * into v_existing from payroll_task_links where year_month = p_year_month and kind = 'cash' and corporation_id = v_corp_id;
  if v_existing.task_id is not null then
    v_cash_task := v_existing.task_id;
  elsif v_cash_names is not null and array_length(v_cash_names,1) > 0 then
    select coalesce(array_agg(id), array[]::uuid[]) into v_assignees
      from users where is_active and replace(replace(name,' ',''),chr(12288),'') = any(array['青山純','原美香','中山俊士','坂本龍太郎','佐藤俊一','鍋倉巧']);
    insert into hq_tasks(title, corp, freq, target_date, due_date, notes, description, visibility, created_by)
    values (v_mon||'月分　現金手渡し　'||p_corp, p_corp, 'once', current_date, v_cash_due, '',
      '給料確定ボタンにより自動発行（対象'||array_length(v_cash_names,1)||'名）', 'all', auth.uid())
    returning id into v_cash_task;
    insert into hq_task_steps(task_id, title, assignee_ids, due_date, sort_order, kind)
    values (v_cash_task, '手渡し完了を確認', v_assignees, v_cash_due, 10, 'step') returning id into v_cash_step;
    v_sort := 10;
    foreach v_name in array v_cash_names loop
      insert into hq_step_checklist_items(step_id, title, sort_order) values (v_cash_step, v_name, v_sort);
      v_sort := v_sort + 10;
    end loop;
    insert into payroll_task_links(year_month, kind, task_id, step_id, corporation_id) values (p_year_month, 'cash', v_cash_task, v_cash_step, v_corp_id);
  end if;

  -- 確定の結果を通知。0名・紐づけ失敗などは ⚠️ を付けて知らせる（黙って終わらせない）
  if coalesce(array_length(v_transfer_names,1),0) = 0 and coalesce(array_length(v_cash_names,1),0) = 0 then
    v_warn := v_warn || '振込・現金とも対象者が0名でした。給与データの取り込み漏れがないか確認してください。';
  end if;
  begin
    perform notify_lark('💰 給料確定: '||p_year_month||'（'||p_corp||'） 振込'||coalesce(array_length(v_transfer_names,1),0)||'名・現金'||coalesce(array_length(v_cash_names,1),0)||'名'
      ||case when v_attached then '（既存の振込タスクに確認工程を追加）' else '' end
      ||case when v_warn <> '' then E'\n⚠️ '||v_warn else '' end);
  exception when others then null;
  end;

  return jsonb_build_object(
    'corporation_id', v_corp_id, 'transfer_attached', v_attached, 'warning', nullif(v_warn, ''),
    'transfer_task_id', v_transfer_task, 'transfer_due', v_transfer_due, 'transfer_count', coalesce(array_length(v_transfer_names,1),0),
    'cash_task_id', v_cash_task, 'cash_due', v_cash_due, 'cash_count', coalesce(array_length(v_cash_names,1),0)
  );
end;
$function$;
revoke all on function public.hq_create_payroll_tasks(text, text, uuid) from public, anon;
grant execute on function public.hq_create_payroll_tasks(text, text, uuid) to authenticated;

-- ---------- 7b. 関連5関数の権限を揃える（PUBLIC・anon を外し authenticated のみ。内部に auth.uid()+ロール判定があるが多重防御）----------
--   （cash_handoff_complete / hq_check_payroll_task_item / hq_create_payroll_tasks / cash_handoff_targets は上で個別に設定済み。残りの cash_handoff_can_write をここで）
revoke all on function public.cash_handoff_can_write(uuid) from public, anon;
grant execute on function public.cash_handoff_can_write(uuid) to authenticated;

-- ---------- 7c. 毎朝の整合チェック（ミスや取りこぼしを黙らせない。件数のみ通知）----------
--   ①手渡し完了済みなのに本部タスクのチェックが未 ②手渡し完了済みなのに給与仕訳の「振込完了」印が未
--   ③給料確定済みなのに対象者がいてタスクが1件も無い。直近3か月が対象。解消されるまで毎朝通知。実行は cron（別SQL: 2026-11-09_payroll_consistency_cron.sql）
create or replace function public.payroll_consistency_check(p_notify boolean default true)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_from text := to_char((now() at time zone 'Asia/Tokyo') - interval '3 months', 'YYYY-MM');
  c1 int; c2 int; c3 int; v_msg text := '';
begin
  select count(*) into c1
    from sf_cash_handoff_signatures s
    join users u on u.id = s.user_id
    join smaregi_contracts sc on sc.contract_id = s.contract_id
    join payroll_task_links l on l.year_month = s.year_month and l.kind = 'cash' and l.corporation_id = sc.corporation_id
    join hq_step_checklist_items i on i.step_id = l.step_id
         and replace(replace(i.title,' ',''),chr(12288),'') = replace(replace(u.name,' ',''),chr(12288),'') and i.checked_at is null
   where s.completed_at is not null and s.year_month >= v_from;
  select count(*) into c2
    from sf_cash_handoff_signatures s
    join smaregi_contracts sc on sc.contract_id = s.contract_id
   where s.completed_at is not null and s.year_month >= v_from
     and exists (select 1 from payroll_journal_records j where j.user_id = s.user_id and j.year_month = s.year_month
                    and j.tenant_id = (case sc.corporation_hint when 'toho' then 'default' else sc.corporation_hint end) and j.paid_at is null);
  select count(*) into c3
    from payroll_finalized f
   where f.year_month >= v_from
     and not exists (select 1 from payroll_task_links l where l.year_month = f.year_month and l.corporation_id = f.corporation_id)
     and exists (select 1 from sf_payroll_sync sp join smaregi_contracts sc on sc.contract_id = sp.contract_id
                  where sp.year_month = f.year_month and sc.corporation_id = f.corporation_id and coalesce(sp.net_pay,0) > 0);
  if c1 > 0 then v_msg := v_msg || E'\n・手渡し完了済みなのに本部タスクのチェックが付いていない人: '||c1||'名'; end if;
  if c2 > 0 then v_msg := v_msg || E'\n・手渡し完了済みなのに給与仕訳の「振込完了」印が付いていない人: '||c2||'名'; end if;
  if c3 > 0 then v_msg := v_msg || E'\n・給料確定済みなのに本部タスクが1件も無い月×法人: '||c3||'件'; end if;
  if v_msg <> '' and p_notify then
    perform notify_lark('⚠️ 給与・現金手渡しの整合チェック（毎朝・直近3か月）'||v_msg||E'\n解消されるまで毎朝お知らせします。nippo「現金手渡し・サイン」と本部タスクを確認してください');
  end if;
  return jsonb_build_object('tasks_unchecked', c1, 'paid_unmarked', c2, 'finalized_without_tasks', c3);
end;
$function$;
revoke all on function public.payroll_consistency_check(boolean) from public, anon, authenticated;
grant execute on function public.payroll_consistency_check(boolean) to service_role;

-- ---------- 8. 適用後の確認（結果を担当B→司令塔へ報告） ----------
-- 同名関数が1本ずつであること（オーバーロードが残っていない）
select proname, count(*) as 本数, string_agg(pg_get_function_identity_arguments(oid), ' / ') as 引数
  from pg_proc where pronamespace = 'public'::regnamespace
   and proname in ('hq_create_payroll_tasks','hq_check_payroll_task_item','cash_handoff_complete','cash_handoff_targets','cash_handoff_cancel')
 group by proname order by 1;
-- 移行件数
select 'payroll_finalized' as t, year_month, count(*) from payroll_finalized group by year_month
union all select 'task_links', year_month, count(*) from payroll_task_links group by year_month order by 1, 2;
-- 権限表（anon/PUBLICに権限が無いこと・authenticatedはselectのみ）
select c.relname, c.relrowsecurity as rls, a.grantee::regrole::text as grantee, a.privilege_type
  from pg_class c left join lateral aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a on true
 where c.relname in ('payroll_finalized','sf_cash_handoff_cancellations','payroll_task_links') and c.relnamespace = 'public'::regnamespace
 order by 1, 3, 4;
-- 関連5関数の権限表（PUBLIC・anon が無いこと）
select p.proname, a.grantee::regrole::text as grantee, a.privilege_type
  from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
 where p.pronamespace = 'public'::regnamespace
   and p.proname in ('cash_handoff_complete','cash_handoff_targets','hq_create_payroll_tasks','hq_check_payroll_task_item','cash_handoff_can_write','cash_handoff_cancel','cash_handoff_targets_raw','cash_handoff_finalized_corps','payroll_consistency_check')
 order by 1, 2;
