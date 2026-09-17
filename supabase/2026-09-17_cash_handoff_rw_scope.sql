-- 2026-09-17 担当B（nippo）
-- 【担当A経由でのユーザー報告】「チーム長・本部・社長が全従業員分の引き出しチェック・
-- 写真添付をできるようにしたい」「間違えて引き出しチェックした場合の取り消しができない」
--
-- 【原因】2026-09-14_cash_handoff_role_scope.sqlで「一覧の閲覧範囲」
-- （cash_handoff_targets関数）はTEAM=全店舗に変更済みだったが、実際に
-- チェックを入れる・写真を添付する・取り消す【書き込み側】のRLS
-- （sf_cash_handoff_signatures.cash_handoff_rw、2026-09-08_cash_handoff_signatures.sqlで
-- 定義）は更新されておらず、TEAM（チーム長）は今も自チーム店舗のみのままだった。
-- 一覧には全店舗の対象者が出るのに、チーム外の分は書き込み（チェック・写真・取り消し
-- いずれも）が拒否される、という状態になっていた。取り消しボタン自体は既に実装済み
-- （cash-withdraw-undo。2026-09-08追加）で、原因はこのRLSのみ。
--
-- 【今回の変更】cash_handoff_role_scopeテーブル（閲覧範囲の設定＝正）を書き込み側の
-- RLSからも参照するよう統一する。今後、閲覧範囲の設定を変えれば書き込み範囲も
-- 自動的に揃うようにするため（担当Aからの提案どおり）。
--
-- RLSポリシーの述語から直接テーブル設定を都度引く形にすると、権限が無い呼び出し元に
-- 対しても各行ごとに例外(RAISE)が飛ぶ実装は不適切（PostgreSQLはRLS述語内の例外で
-- クエリ全体を失敗させてしまうため）。そのため、権限が無い場合は例外を投げず
-- 単にfalseを返す専用関数(cash_handoff_can_write)を新設し、それをUSING/WITH CHECK
-- の述語として使う。
--
-- 【既存データへの影響】無し（RLSポリシーの再定義のみ）
-- 【rollback】cash_handoff_rwポリシーを2026-09-08_cash_handoff_signatures.sqlの元の定義
-- （TEAM=team_store_ids(team_id)固定）に戻せばよい

create or replace function public.cash_handoff_can_write(p_store_id uuid)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_caller users%rowtype; v_scope text; v_stores uuid[];
begin
  select * into v_caller from users u0 where u0.id = auth.uid() and u0.is_active;
  if v_caller.id is null then return false; end if;
  if v_caller.is_master then return true; end if;
  if not (v_caller.role in ('CEO','HQ','TENCHO','TEAM')) then return false; end if;
  select scope into v_scope from cash_handoff_role_scope where role = v_caller.role;
  v_scope := coalesce(v_scope, 'own'); -- 設定が無い役職は最も安全側（自店舗のみ）にフォールバック
  if v_scope = 'all' then return true; end if;
  if v_scope = 'team' then
    v_stores := team_store_ids(v_caller.team_id) || user_store_ids(v_caller.id);
  else
    v_stores := user_store_ids(v_caller.id);
  end if;
  return p_store_id = any(v_stores);
end;
$function$;
comment on function public.cash_handoff_can_write(uuid) is
  '現金手渡し・サイン画面の書き込み（チェック・写真添付・取り消し）が許可されるかを、
   cash_handoff_role_scope（閲覧範囲と同じ設定テーブル）を見て判定する。
   RLS述語専用のため、権限が無い場合は例外を投げずfalseを返す。2026-09-17新設';

drop policy if exists cash_handoff_rw on sf_cash_handoff_signatures;
create policy cash_handoff_rw on sf_cash_handoff_signatures for all using (
  cash_handoff_can_write(store_id)
) with check (
  cash_handoff_can_write(store_id)
);
