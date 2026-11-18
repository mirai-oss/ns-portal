-- 2026-11-19 担当B（社長の承認）— 採用ボタン復活 ①: LINE を本番モードにして、テスト用の応募者で確認する
-- 【安全】送信スイッチ（send_enabled）が OFF のままであることを確かめてから行う。OFF のあいだは、テスト用の応募者（answers._test=true）以外へは、LINE は送られない（DB の関数が断る）。
-- 【やること】(1) テスト用の応募者「テスト応募者（社長）」を「採用済み」→「連絡済み（選考中）」に戻す（従業員との結びつきは無いので影響なし）。Slack の採用管理の親投稿・カードが、選考中の形（ボタンつき）に更新される。
--             (2) 設定 recruit_actions.line_mode を 'live' にする（カレンダー calendar_mode と送信スイッチ send_enabled は、そのまま）。
-- 【戻し方】update app_settings set value = value || '{"line_mode":"dry"}'::jsonb where key = 'recruit_actions';
do $do$
declare n int;
begin
  if coalesce((select value ->> 'send_enabled' from app_settings where key = 'recruit_actions'), 'false') <> 'false' then raise exception '停止: 送信スイッチが OFF ではありません'; end if;
  update applicants set status = 'contacted', hired_at = null, status_changed_at = now()
   where id = 'cc181aa6-6c93-44f5-885e-ce5dc92385e4' and answers ->> '_test' = 'true' and status = 'hired' and user_id is null;
  get diagnostics n = row_count;
  if n <> 1 then raise exception '停止: テスト用の応募者の状態が想定と違います（%件）', n; end if;
  update app_settings set value = value || '{"line_mode":"live"}'::jsonb, updated_at = now() where key = 'recruit_actions';
end $do$;
