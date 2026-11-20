-- 2026-11-20 担当B（社長の依頼）— 応募者「その人専用の応募フォームのリンク」を作れるようにする（待ち行列 9 番・案 C の続き）
-- 【やること】LINE 案内文（Slack の［LINE 案内文］・管理システムの応募者ページ）に、その人専用のフォームのリンクを入れる。
--   リンクを開くと、フォームの氏名欄に「Indeed に登録されている氏名」が入った状態（書き換え不可）で開く。
--   送信は今までのフォームと同じ（apply_submit）。氏名が必ず一致するので、その人の応募に確実にまとまり、完了画面にその人の LINE 登録ボタン（合言葉入り）が出る。
-- 【追加するもの（既存の表・関数は変えない）】
--   ① 表 applicant_form_tokens（応募者ごとの合言葉とは別の、推測できない長い印。画面・API からは直接読めない）
--   ② 関数 applicant_form_token(応募者)  … 印を取る（なければ作る）。使えるのは、サーバー（Slack）と、その応募者を見られる職員だけ
--   ③ 関数 apply_prefill(印)             … フォームが氏名を入れるために呼ぶ（未ログイン可）。返すのは氏名と「LINE 連携済みか」だけ。入社・離脱済みの人には返さない
-- 【戻し方】drop function if exists public.apply_prefill(text); drop function if exists public.applicant_form_token(uuid); drop table if exists public.applicant_form_tokens;
create table if not exists public.applicant_form_tokens (
  applicant_id uuid primary key references public.applicants(id) on delete cascade,
  token        text not null unique,
  created_at   timestamptz not null default now()
);
alter table public.applicant_form_tokens enable row level security;
revoke all on public.applicant_form_tokens from public, anon, authenticated;

create or replace function public.applicant_form_token(p_applicant uuid)
returns text language plpgsql security definer set search_path to 'public' as $$
declare v_a applicants%rowtype; v_t text;
begin
  select * into v_a from applicants where id = p_applicant;
  if v_a.id is null then return null; end if;
  if not (public.hq_slack_is_service() or coalesce(public.can_see_applicant(auth.uid(), v_a.store_id), false)) then raise exception '権限がありません'; end if;
  select token into v_t from applicant_form_tokens where applicant_id = p_applicant;
  if v_t is null then
    insert into applicant_form_tokens(applicant_id, token)
    values (p_applicant, replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''))
    on conflict (applicant_id) do nothing;
    select token into v_t from applicant_form_tokens where applicant_id = p_applicant;
  end if;
  return v_t;
end $$;
revoke all on function public.applicant_form_token(uuid) from public, anon;
grant execute on function public.applicant_form_token(uuid) to authenticated, service_role;

create or replace function public.apply_prefill(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_a applicants%rowtype;
begin
  if length(coalesce(p_token, '')) <> 64 then return jsonb_build_object('ok', false); end if;
  select a.* into v_a from applicant_form_tokens t join applicants a on a.id = t.applicant_id
   where t.token = p_token and a.hired_at is null and a.exited_at is null;
  if v_a.id is null then return jsonb_build_object('ok', false); end if;
  return jsonb_build_object('ok', true, 'name', v_a.name, 'linked', v_a.line_user_id is not null);
end $$;
revoke all on function public.apply_prefill(text) from public;
grant execute on function public.apply_prefill(text) to anon, authenticated, service_role;

-- 確認: 表 1・関数 2 が入っていれば 1 / 2 と出る
select (select count(*) from pg_tables where schemaname = 'public' and tablename = 'applicant_form_tokens') as 表の数,
       (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname in ('applicant_form_token', 'apply_prefill')) as 関数の数;
