-- 入金まわりの既存の権限漏れの修正（kd_deposit_daily・kd_deposit_monthly_summary・ar_*（売上入金・請求）。2026-11-28）
-- 状態: **下書き（未適用）**。適用の承認は社長（段階5・6とは別。SQL・テスト・実環境リハーサル・ROLLBACK を添えて報告）。
--
-- 【問題（実環境で確認）】
--   ・ar_deposits（会計の実入金）・ar_receivables・ar_matching・ar_recurring_master・ar_receivable_attachments は、ポリシー authenticated_full_access（常に true）で、
--     ログインしている人なら誰でも（アルバイトを含む）全件の閲覧・登録・変更・削除ができた。画面（請求書・売上入金）の利用者は 社長・マスター・本部と、portal_user_overrides で許可された人だけ（invoice_can_access()）。
--   ・kd_deposit_daily・kd_deposit_monthly_summary（入金画面の元）は、社長・マスター・本部・チーム長なら、法人を限定された人でも全法人を読めた。
--   ・上の表・ビューに、ログインなし(anon)を含む全員へ、書き込み・TRUNCATE などの不要な権限が付いていた（RLS で書き込みは弾かれていたが、権限としては過剰）。
-- 【この SQL がやること】
--   ① ar_* を invoice_can_access()（請求書画面と同じ利用者）に限定し、法人を限定された人には自法人の分だけ（ar_receivables.corporation_id。実入金・消込・添付は請求（receivable）の法人で判定）。
--   ② kd_deposit_daily・kd_deposit_monthly_summary は、役職の条件（社長・マスター・本部・チーム長＝全店／店長＝担当店）はそのまま、法人を限定された人には自法人の分だけ。
--   ③ 不要な権限を外す（anon の全権限、authenticated の書き込み・TRUNCATE・REFERENCES・TRIGGER）。ログイン済みの利用者の「読む」「（ar_* は）画面からの登録・変更・削除」は変わらない。サービスロール・ai_reader は変更なし。
-- 【法人の判定】既存の info.user_corporations（無ければ info.role_corporations）に法人が載っている人だけを「限定された人」とし、限定の設定が無い人は従来どおり全法人（＝画面の見え方は変わらない）。
--   ※銀行台帳（bank_*）は「許可が無ければ拒否」だが、既存の画面を壊さないため、この SQL は従来の判定（設定が無ければ全法人）を保つ。
-- 【影響を受ける人（本番）】法人を限定された本部 1 人・チーム長 3 人は、他法人の入金・売上入金が見えなくなる。invoice_can_access() でない人（店長・社員・アルバイトなど）は ar_* が見えなくなる（画面の利用者ではないため、通常の操作は妨げない）。
-- 【ロールバック】2026-11-28_deposit_access_fix_ROLLBACK.sql（元のポリシーと権限に戻す）。

-- ---------- 法人の判定（既存の info の設定を読む）----------
create or replace function public.dep_unrestricted()
returns boolean language sql stable security definer set search_path to 'public' as $$
  select coalesce((select coalesce(u.is_master, false)
                          or not (exists (select 1 from info.user_corporations uc where uc.user_id = u.id)
                                  or exists (select 1 from info.profiles p join info.role_corporations rc on rc.role_id = p.role_id where p.id = u.id and p.is_active))
                     from public.users u where u.id = auth.uid() and u.is_active), false)
$$;
revoke all on function public.dep_unrestricted() from public, anon;
grant execute on function public.dep_unrestricted() to authenticated, service_role;
create or replace function public.dep_allowed_corp_ids()
returns uuid[] language sql stable security definer set search_path to 'public' as $$
  select case when public.dep_unrestricted() then (select coalesce(array_agg(c.id), '{}'::uuid[]) from public.corporations c)
              else (select coalesce(array_agg(c.id), '{}'::uuid[]) from public.corporations c
                     where c.legacy_info_id is not null and c.legacy_info_id in (
                       select uc.corporation_id from info.user_corporations uc where uc.user_id = auth.uid()
                       union
                       select rc.corporation_id from info.profiles p join info.role_corporations rc on rc.role_id = p.role_id
                        where p.id = auth.uid() and p.is_active and not exists (select 1 from info.user_corporations x where x.user_id = auth.uid()))) end
$$;
revoke all on function public.dep_allowed_corp_ids() from public, anon;
grant execute on function public.dep_allowed_corp_ids() to authenticated, service_role;
-- 見てよい請求（receivable）の ID（実入金・消込・添付の判定用）
create or replace function public.ar_visible_receivable_ids()
returns uuid[] language sql stable security definer set search_path to 'public' as $$
  select coalesce(array_agg(r.id), '{}'::uuid[]) from public.ar_receivables r
   where public.invoice_can_access() and ((select public.dep_unrestricted()) or r.corporation_id = any (coalesce((select public.dep_allowed_corp_ids()), '{}'::uuid[])))
$$;
revoke all on function public.ar_visible_receivable_ids() from public, anon;
grant execute on function public.ar_visible_receivable_ids() to authenticated, service_role;

-- ---------- ① ar_*（請求書画面の利用者だけ・法人別）----------
drop policy if exists authenticated_full_access on public.ar_receivables;
drop policy if exists ar_receivables_access on public.ar_receivables;
create policy ar_receivables_access on public.ar_receivables for all to authenticated
  using ((select public.invoice_can_access()) and ((select public.dep_unrestricted()) or corporation_id = any (coalesce((select public.dep_allowed_corp_ids()), '{}'::uuid[])))) with check ((select public.invoice_can_access()) and ((select public.dep_unrestricted()) or corporation_id = any (coalesce((select public.dep_allowed_corp_ids()), '{}'::uuid[]))));
drop policy if exists authenticated_full_access on public.ar_deposits;
drop policy if exists ar_deposits_access on public.ar_deposits;
create policy ar_deposits_access on public.ar_deposits for all to authenticated
  using ((select public.invoice_can_access()) and receivable_id = any (coalesce((select public.ar_visible_receivable_ids()), '{}'::uuid[])))
  with check ((select public.invoice_can_access()) and receivable_id = any (coalesce((select public.ar_visible_receivable_ids()), '{}'::uuid[])));
drop policy if exists authenticated_full_access on public.ar_matching;
drop policy if exists ar_matching_access on public.ar_matching;
create policy ar_matching_access on public.ar_matching for all to authenticated
  using ((select public.invoice_can_access()) and receivable_id = any (coalesce((select public.ar_visible_receivable_ids()), '{}'::uuid[])))
  with check ((select public.invoice_can_access()) and receivable_id = any (coalesce((select public.ar_visible_receivable_ids()), '{}'::uuid[])));
drop policy if exists authenticated_full_access on public.ar_receivable_attachments;
drop policy if exists ar_receivable_attachments_access on public.ar_receivable_attachments;
create policy ar_receivable_attachments_access on public.ar_receivable_attachments for all to authenticated
  using ((select public.invoice_can_access()) and receivable_id = any (coalesce((select public.ar_visible_receivable_ids()), '{}'::uuid[])))
  with check ((select public.invoice_can_access()) and receivable_id = any (coalesce((select public.ar_visible_receivable_ids()), '{}'::uuid[])));
drop policy if exists authenticated_full_access on public.ar_recurring_master;
drop policy if exists ar_recurring_master_access on public.ar_recurring_master;
create policy ar_recurring_master_access on public.ar_recurring_master for all to authenticated
  using ((select public.invoice_can_access())) with check ((select public.invoice_can_access()));

-- ---------- ② kd_deposit_*（役職の条件はそのまま＋法人別）----------
drop policy if exists kd_deposit_daily_select on public.kd_deposit_daily;
create policy kd_deposit_daily_select on public.kd_deposit_daily for select to authenticated
  using (((EXISTS ( SELECT 1
   FROM users u
  WHERE ((u.id = auth.uid()) AND u.is_active AND (u.is_master OR (u.role = ANY (ARRAY['CEO'::text, 'HQ'::text, 'TEAM'::text])) OR ((u.role = 'TENCHO'::text) AND (EXISTS ( SELECT 1
           FROM user_stores us
          WHERE ((us.user_id = u.id) AND (us.store_id = kd_deposit_daily.store_id)))))))))) and ((select public.dep_unrestricted()) or corporation_id = any (coalesce((select public.dep_allowed_corp_ids()), '{}'::uuid[]))));
drop policy if exists kd_deposit_monthly_summary_select on public.kd_deposit_monthly_summary;
create policy kd_deposit_monthly_summary_select on public.kd_deposit_monthly_summary for select to authenticated
  using (((EXISTS ( SELECT 1
   FROM users u
  WHERE ((u.id = auth.uid()) AND u.is_active AND (u.is_master OR (u.role = ANY (ARRAY['CEO'::text, 'HQ'::text, 'TEAM'::text])) OR ((u.role = 'TENCHO'::text) AND (EXISTS ( SELECT 1
           FROM user_stores us
          WHERE ((us.user_id = u.id) AND (us.store_id = kd_deposit_monthly_summary.store_id)))))))))) and ((select public.dep_unrestricted()) or corporation_id = any (coalesce((select public.dep_allowed_corp_ids()), '{}'::uuid[]))));

-- ---------- ③ 不要な権限を外す ----------
revoke all on public.kd_deposit_daily, public.kd_deposit_monthly_summary, public.kd_deposit_daily_v, public.kd_deposit_carry_v from anon;
revoke insert, update, delete, truncate, references, trigger on public.kd_deposit_daily, public.kd_deposit_monthly_summary, public.kd_deposit_daily_v, public.kd_deposit_carry_v from authenticated;
revoke all on public.ar_receivables, public.ar_deposits, public.ar_matching, public.ar_receivable_attachments, public.ar_recurring_master from anon;
revoke truncate, references, trigger on public.ar_receivables, public.ar_deposits, public.ar_matching, public.ar_receivable_attachments, public.ar_recurring_master from authenticated;
