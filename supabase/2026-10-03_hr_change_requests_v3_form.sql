-- ============================================================
-- 2026-10-03 担当B（nippo）— 退職申請 v3: ログイン不要の「申請フォームURL」（店長に渡す用）
-- 【状態】事前報告（ユーザー確認待ち・未適用）。前提: v1・v2 適用済み
--
-- 【理由】ユーザー要望: 管理システム（nippo）の画面とは切り分けて、tori-dashboardの「店舗間の仕入れ移動」
--   フォーム（?transferForm=…）のように、URLを開くだけの1枚のシンプルなフォームで退職申請を出せるようにしたい。
-- 【現構造】退職申請はnippoにログインして行う（RPC hr_request_retirement）。ログイン不要の入口は無い
-- 【方式】URLに「合言葉（推測できない長い文字列）」を付け、DB側で合言葉を確認する公開RPCを2つ追加する
--   （tori-dashboardのtransferFormと同じ考え方）。フォームから出た申請は「承認待ち」で入るだけで、
--   本部が承認するまで何も変わらない（＝間違い・いたずらでも被害は出ない）。申請者は本人の名乗り（任意入力の名前）で記録
-- 【セキュリティ】合言葉を知っている人は、①店舗と在籍従業員の「名前」を見られる ②承認待ちの申請を出せる、のみ
--   （個人情報・承認・停止はできない）。合言葉が漏れたら、本部がnippoの画面から「URLを作り直す」で古いURLを無効化できる。
--   直近1時間に20件を超えるフォーム申請があると受け付けない（いたずら・連打防止）
-- 【影響】新規テーブル1（hr_form_tokens。RLSで直接アクセス不可）・新規RPC5・hr_change_requestsに列2つ
--   （requester_name／note）追加。既存の行・既存の挙動は変えない
-- 【migration】本ファイル（冪等）
-- 【rollback】
--   drop function if exists public.hr_public_retire_options(text);
--   drop function if exists public.hr_public_request_retirement(text,uuid,uuid,date,text,text);
--   drop function if exists public.hr_get_retire_form_token();
--   drop function if exists public.hr_rotate_retire_form_token();
--   drop table if exists hr_form_tokens;
--   alter table hr_change_requests drop column if exists requester_name, drop column if exists note;
-- ============================================================

alter table hr_change_requests add column if not exists requester_name text; -- フォームから出した人の名乗り（ログイン申請ではnull＝requested_byを使う）
alter table hr_change_requests add column if not exists note text;           -- 備考（任意）

create table if not exists hr_form_tokens (
  token text primary key,
  purpose text not null default 'retirement',
  created_at timestamptz not null default now(),
  revoked_at timestamptz
);
alter table hr_form_tokens enable row level security; -- ポリシーを作らない＝直接の読み書きは全面拒否（RPC経由のみ）
comment on table hr_form_tokens is '公開フォームURLの合言葉（担当B・2026-10-03新設）。RLSで直接アクセス不可。RPC経由のみ';

-- 最初の合言葉を1つ作る（有効なものが無いときだけ）
insert into hr_form_tokens(token, purpose)
select replace(gen_random_uuid()::text, '-', ''), 'retirement'
where not exists (select 1 from hr_form_tokens where purpose = 'retirement' and revoked_at is null);

-- 内部用: 合言葉が有効か（例外で止める）
create or replace function public.hr_check_form_token(p_token text)
returns void
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
begin
  if p_token is null or not exists (select 1 from hr_form_tokens where token = p_token and purpose = 'retirement' and revoked_at is null) then
    raise exception 'このURLは無効です。本部に新しいURLをご確認ください';
  end if;
end;
$function$;
revoke all on function public.hr_check_form_token(text) from public, anon, authenticated;

-- ① フォームの選択肢（店舗と、その店舗の在籍従業員の名前）。公開（合言葉が必要）
create or replace function public.hr_public_retire_options(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v jsonb;
begin
  perform hr_check_form_token(p_token);
  select jsonb_build_object(
    'stores', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name) order by s.sort_order, s.name)
                         from stores s where s.is_active), '[]'::jsonb),
    'members', coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'name', u.name, 'store_id', us.store_id) order by u.name)
                          from user_stores us
                          join users u on u.id = us.user_id and u.is_active
                          join stores s on s.id = us.store_id and s.is_active
                          left join employee_profiles ep on ep.user_id = u.id
                         where ep.termination_date is null
                           and not exists (select 1 from hr_change_requests r where r.user_id = u.id and r.kind = 'retirement' and r.status = 'pending')), '[]'::jsonb)
  ) into v;
  return v;
end;
$function$;
revoke all on function public.hr_public_retire_options(text) from public;
grant execute on function public.hr_public_retire_options(text) to anon, authenticated;

-- ② フォームからの申請（承認待ちで入る。承認は本部がnippoで行う）。公開（合言葉が必要）
create or replace function public.hr_public_request_retirement(p_token text, p_store uuid, p_user uuid, p_date date, p_requester text, p_note text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_today date := (now() at time zone 'Asia/Tokyo')::date; v_id uuid; v_tdate date; v_req text := btrim(coalesce(p_requester, ''));
begin
  perform hr_check_form_token(p_token);
  if length(v_req) < 1 or length(v_req) > 30 then raise exception '申請者のお名前を入力してください（30文字まで）'; end if;
  if length(coalesce(p_note, '')) > 200 then raise exception '備考は200文字までです'; end if;
  if p_date is null or p_date < v_today - 30 then raise exception '退職日は30日前から先の日付を指定してください'; end if;
  if (select count(*) from hr_change_requests where requested_by is null and requested_at > now() - interval '1 hour') >= 20 then
    raise exception 'しばらく時間をおいてからもう一度お試しください';
  end if;
  if not exists (select 1 from stores where id = p_store and is_active) then raise exception '店舗を選んでください'; end if;
  if not exists (select 1 from user_stores where user_id = p_user and store_id = p_store) then
    raise exception 'この店舗に所属していない従業員です';
  end if;
  if not exists (select 1 from users where id = p_user and is_active) then raise exception '既に退職済み（無効）の従業員です'; end if;
  select termination_date into v_tdate from employee_profiles where user_id = p_user;
  if v_tdate is not null then raise exception '既に退職日が登録されている従業員です'; end if;
  begin
    insert into hr_change_requests(kind, store_id, user_id, effective_date, requested_by, requester_name, note)
    values ('retirement', p_store, p_user, p_date, null, v_req, nullif(btrim(coalesce(p_note, '')), '')) returning id into v_id;
  exception when unique_violation then
    raise exception 'この従業員の退職申請は既に出ています（本部の確認待ちです）';
  end;
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$function$;
revoke all on function public.hr_public_request_retirement(text, uuid, uuid, date, text, text) from public;
grant execute on function public.hr_public_request_retirement(text, uuid, uuid, date, text, text) to anon, authenticated;

-- ③ 本部・社長・マスターがnippoの画面でURL用の合言葉を見る／作り直す（作り直すと古いURLは使えなくなる）
create or replace function public.hr_get_retire_form_token()
returns text
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v text;
begin
  if not exists (select 1 from users where id = auth.uid() and is_active and (is_master or role in ('CEO','HQ'))) then
    raise exception '権限がありません（本部・社長・マスターのみ）';
  end if;
  select token into v from hr_form_tokens where purpose = 'retirement' and revoked_at is null order by created_at desc limit 1;
  return v;
end;
$function$;
revoke all on function public.hr_get_retire_form_token() from public, anon;
grant execute on function public.hr_get_retire_form_token() to authenticated;

create or replace function public.hr_rotate_retire_form_token()
returns text
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v text := replace(gen_random_uuid()::text, '-', '');
begin
  if not exists (select 1 from users where id = auth.uid() and is_active and (is_master or role in ('CEO','HQ'))) then
    raise exception '権限がありません（本部・社長・マスターのみ）';
  end if;
  update hr_form_tokens set revoked_at = now() where purpose = 'retirement' and revoked_at is null;
  insert into hr_form_tokens(token, purpose) values (v, 'retirement');
  return v;
end;
$function$;
revoke all on function public.hr_rotate_retire_form_token() from public, anon;
grant execute on function public.hr_rotate_retire_form_token() to authenticated;
