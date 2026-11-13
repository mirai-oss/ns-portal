-- 既存社員の「月給」の賃金設定の変更と、スマレジへの同期を、確認が終わるまで止める（2026-11-13・社長の指示）
--
-- 背景: 管理システムの月給の行は、基本賃金しか持っていない（固定残業代・含める労働区分が無い）。
--   今の送信（smaregi-sync の wage_push）は、月給を「区分・適用開始・賃金」の 3 つだけで送る。
--   固定残業代のある人の月給を管理システムから送ると、スマレジ側の固定残業代が外れるおそれがある（仕様に書かれていない＝要実測）。
--   → 差異の確認が終わるまで、既存社員の月給を、管理システムから「送る待ち」に出来ないようにする。
--
-- しくみ: 送信は「送る待ち（pending）・エラー（error）」の行だけを送る。月給の行が、人の操作で新しく入らない・中身が変わらない・
--   送る待ちに戻らないようにすれば、どの入口（保存・修正・承認の直後・契約コピー・LINE など）からも送られない。
--
-- 足すもの: 設定のキー 2 つ（app_settings.employee_change の monthly_wage_sync_hold・monthly_wage_sync_hold_exempt）と、
--   表 employee_wage_settings のトリガー 1 本。既存の関数・トリガー・行は変えない。
-- 止めないもの: 時給・日給の行／入社手続き中の人（入社登録の決まりに任せる）／確認が終わった人（exempt に入れた users.id）／
--   スマレジからの取り込み（システムの処理で、最初から「同期済み」で入る行・更新）／同期の結果の書き込み（同期済み・エラー）。
-- 止められないもの（弱い所）: 画面の「削除」は、先にスマレジ側を消してから DB の行を消す作り。DB の見張りでは、スマレジ側の削除を防げない
--   （行き違いを作らないため、システムの処理からの削除は通す）。→ 月給の行の削除は、確認が終わるまで操作しない運用にする。Edge Function 側の止めは別途。
-- 戻し方: select … monthly_wage_sync_hold を false に（下の rollback の 1 行目）。または 2026-12-03_monthly_wage_sync_hold_rollback.sql。

update app_settings
   set value = value || jsonb_build_object('monthly_wage_sync_hold', true)
                     || case when value ? 'monthly_wage_sync_hold_exempt' then '{}'::jsonb else '{"monthly_wage_sync_hold_exempt": []}'::jsonb end
 where key = 'employee_change';

create or replace function public.monthly_wage_sync_hold_guard()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare
  c_msg constant text := '社員の月給は、スマレジとの差（固定残業代など）の確認が終わるまで、変更と同期を止めています。本部に確認してください';
  v_cfg jsonb; v_user uuid; v_is_monthly boolean; v_same boolean;
begin
  select s.value into v_cfg from app_settings s where s.key = 'employee_change';
  if coalesce((v_cfg ->> 'monthly_wage_sync_hold')::boolean, false) is not true then return coalesce(new, old); end if;

  if tg_op = 'DELETE' then
    v_user := old.user_id; v_is_monthly := (old.division = 2);
  elsif tg_op = 'INSERT' then
    v_user := new.user_id; v_is_monthly := (new.division = 2);
  else
    v_user := new.user_id; v_is_monthly := (new.division = 2 or old.division = 2);
  end if;
  if v_is_monthly is not true then return coalesce(new, old); end if;                                    -- 時給・日給は対象外

  if coalesce(v_cfg -> 'monthly_wage_sync_hold_exempt', '[]'::jsonb) ? v_user::text then return coalesce(new, old); end if;   -- 確認が終わった人
  if exists (select 1 from onboarding_workflows w where w.user_id = v_user and w.status in ('hired_confirmed', 'form_sent', 'registering')) then
    return coalesce(new, old);                                                                           -- 入社手続き中（入社登録の決まりに任せる）
  end if;

  if tg_op = 'DELETE' then
    if auth.uid() is null then return old; end if;                                                       -- システムの処理（スマレジ側を先に消した後の片づけ）は通す
    raise exception '%', c_msg;
  end if;

  if tg_op = 'INSERT' then
    -- スマレジからの取り込み（システムの処理・入力者なし・最初から同期済み）は通す
    if auth.uid() is null and new.created_by is null and new.sync_status = 'synced' then return new; end if;
    raise exception '%', c_msg;
  end if;

  -- UPDATE
  v_same := (new.wage, new.holiday_wage, new.effective_date, new.division, new.store_id, new.contract_id)
            is not distinct from (old.wage, old.holiday_wage, old.effective_date, old.division, old.store_id, old.contract_id);
  if v_same is true then
    -- 中身は同じ。「送る待ち」へ変えるのだけ断る（同期済み・エラーなど、結果の書き込みは通す）
    if new.sync_status = 'pending' and old.sync_status is distinct from 'pending' then raise exception '%', c_msg; end if;
    return new;
  end if;
  -- 中身が変わる: スマレジからの取り込み（システムの処理で、同期済みとして書く）だけ通す
  if auth.uid() is null and new.sync_status = 'synced' then return new; end if;
  raise exception '%', c_msg;
end $$;
revoke all on function public.monthly_wage_sync_hold_guard() from public, anon, authenticated;

drop trigger if exists monthly_wage_sync_hold_guard on public.employee_wage_settings;
create trigger monthly_wage_sync_hold_guard before insert or update or delete on public.employee_wage_settings
  for each row execute function public.monthly_wage_sync_hold_guard();

-- 確認用:
--   select value -> 'monthly_wage_sync_hold', value -> 'monthly_wage_sync_hold_exempt' from app_settings where key = 'employee_change';
--   確認が終わった人を外す: update app_settings set value = jsonb_set(value, '{monthly_wage_sync_hold_exempt}', (value -> 'monthly_wage_sync_hold_exempt') || to_jsonb('<users.id>'::text)) where key = 'employee_change';
