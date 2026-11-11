-- ============================================================
-- 2026-11-11 担当B（設計了承・ユーザー承認待ち）— 中山さん個人宛の通知（タスク割当・日報コメント・いいね・チャット）を Slack の個人メッセージ(DM)にも送る行を追加
-- 【方式】lark_routes に Slack 行を1つ追加（kind='slack'・宛先='user:<社内ユーザーID>'）。Slack の ID は書かない（社内の user_slack 紐づけから EF notify-slack が引いて DM を開く）
--   イベント・対象は既存の Lark 行「中山通知専用」と同じ。追加時は【無効】（is_active=false）。画面の「テスト」で DM に届くのを確認してから、有効化 → Lark 行を無効化
-- 【安全ガード】既存の Lark 行「中山通知専用」が1件・対象ユーザー（名前が中山・役職 CEO）が1名・その人が user_slack で Slack 紐づけ済み・同名の Slack 行が未作成、でなければ停止（何も変更しない）
-- 【影響】1行の追加のみ（無効状態）。今の通知は一切変わらない
-- 【rollback】delete from lark_routes where name = '中山通知専用（Slack DM）' and kind = 'slack';
-- ============================================================
do $$
declare n_src int; n_user int; n_linked int; n_dup int; v_uid uuid;
begin
  select count(*) into n_src from lark_routes where name = '中山通知専用' and kind = 'lark';
  select count(*), min(u.id::text)::uuid into n_user, v_uid from users u where u.name like '中山%' and u.role = 'CEO' and u.is_active;
  select count(*) into n_linked from user_slack us where us.user_id = v_uid;
  select count(*) into n_dup from lark_routes where name = '中山通知専用（Slack DM）';
  if n_src <> 1 then raise exception '停止: 元の Lark 行「中山通知専用」が % 件です（1件のはず）', n_src; end if;
  if n_user <> 1 then raise exception '停止: 対象ユーザーが % 名です（1名のはず）', n_user; end if;
  if n_linked <> 1 then raise exception '停止: 対象ユーザーの Slack 紐づけがありません（user_slack）'; end if;
  if n_dup <> 0 then raise exception '停止: 同名の Slack 行が既にあります'; end if;

  insert into lark_routes (name, kind, webhook_url, role, team_id, store_id, kinds, events, is_active, sort_order)
  select '中山通知専用（Slack DM）', 'slack', 'user:' || v_uid::text, lr.role, lr.team_id, lr.store_id, lr.kinds, lr.events, false, lr.sort_order
    from lark_routes lr where lr.name = '中山通知専用' and lr.kind = 'lark';
end $$;

-- 確認（宛先の値そのものは出さない）
select name, kind, is_active, events, left(webhook_url, 5) as 宛先の種類 from lark_routes where name in ('中山通知専用', '中山通知専用（Slack DM）') order by kind;
