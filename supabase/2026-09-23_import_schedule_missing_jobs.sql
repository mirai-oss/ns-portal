-- =====================================================================
-- import_scheduleへ、後から追加されたのに登録漏れだった6ジョブを追加
-- =====================================================================
-- 背景: ユーザー報告「管理権限のシステム利用状況・自動取込ジョブ一覧に、ロケットナウ取り込み
--   とかが入ってない」。ns-daily-import/config.jsのSCHEDULE/MONTHLY_SCHEDULE/DAILY_INDEPENDENTと
--   Supabaseのimport_schedule（一覧の表示元）を突き合わせたところ、以下6ジョブが2026-09-14〜17に
--   config.jsへ追加されたのに、import_scheduleへの追加（2026-09-11作成時点の13件のまま）が
--   漏れていたと判明:
--     rocketnow-sales（9/14追加）・rocketnow-settlement（9/17追加）・morning-refresh（8/23追加、
--     実は当初から漏れ）・tabelog-note-reservation/dinii-reservation/bq-reservation-sync（8/27追加）
--
-- 恒久対応: ns-daily-import側に自動同期の仕組みを追加済み（コミット6593c99・lib/schedule-sync.js。
--   dispatch.jsの起動のたびconfig.jsから自動upsertするため、以後この手動SQLは不要になる）。
--   **ただしMac miniのns-daily-importが`git pull`しないと有効にならない**ため、今回はその場しのぎ
--   として今すぐ一覧に出るよう、この1回だけ手動でも投入しておく（自動同期が効き始めれば
--   このSQLの内容と重複するだけで害はない・on conflict do updateなので安全）。
--
-- 実行場所: Supabase SQL Editor（https://supabase.com/dashboard/project/uuvsxzhpxtghojoubjcc/sql/new）
--   何度実行しても壊れません。
-- =====================================================================

insert into public.import_schedule (job, label, source, kind, frequency, expected_time_jst, monthly_days, grace_minutes) values
  ('rocketnow-sales',          'ロケットナウ 日次売上',    'playwright', 'sales',       'daily',   '06:25', null,     180),
  ('rocketnow-settlement',     'ロケットナウ 月次精算',    'playwright', 'sales',       'monthly', '07:10', '{5}',    1440),
  ('morning-refresh',          '朝の分析テーブル再生成',   'reconcile',  'other',       'daily',   '08:45', null,     180),
  ('tabelog-note-reservation', '食べログ/ネット予約取込',  'playwright', 'reservation', 'daily',   '10:00', null,     180),
  ('dinii-reservation',        'Dinii予約取込',           'playwright', 'reservation', 'daily',   '10:05', null,     180),
  ('bq-reservation-sync',      '予約BQミラー同期',        'reconcile',  'reservation', 'daily',   '10:15', null,     180)
on conflict (job) do update set
  label=excluded.label, source=excluded.source, kind=excluded.kind, frequency=excluded.frequency,
  expected_time_jst=excluded.expected_time_jst, monthly_days=excluded.monthly_days,
  grace_minutes=excluded.grace_minutes, updated_at=now();

-- 確認用（実行後、19件になっているはず＝既存13件+今回6件）:
-- select count(*) from import_schedule;
