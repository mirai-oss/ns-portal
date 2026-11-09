-- =============================================================
-- 2026-11-09 入社登録ワークフロー Phase 1: 旧通知 → 新通知への切替（段階的・各ステップは別々にユーザー承認のうえ実行）
--   前提: 2026-11-09_onboarding_phase1.sql が適用済み・EF onboarding-notify / slack-interact / hr-wage-notify / smaregi-sync がデプロイ済み
--   ★ このファイルは「全部いっぺんに」流さない。ステップごとにコメントを外して apply_sql.py で流す（既定はすべてコメントアウト）
-- =============================================================

-- ---- ステップ A: 新しい通知を ON（従来文面も残す＝動作確認期間。人事チャンネルには 2 通届く）---- ✅ 2026-11-09 11:40 適用済み（ユーザー承認・Claude Code 実行）
--   B 以降の条件（ユーザー指示 11/09）: 次の実入社 1〜2 名で「親メッセージ作成・賃金反映・照合・本部タスク完了」まで確認できるまで進めない
-- update public.app_settings set value = value || '{"enabled": true, "legacy_wage_text": true}'::jsonb, updated_at = now() where key = 'onboarding_slack';

-- ---- ステップ B: 従来の「賃金登録をお願いします（準備中）」の文面を止める（新しい親メッセージだけにする）----
-- update public.app_settings set value = value || '{"enabled": true, "legacy_wage_text": false}'::jsonb, updated_at = now() where key = 'onboarding_slack';

-- ---- ステップ C: Chatwork の入社通知（lark_routes join_registered・ルーム 382748319）を止める（削除はしない。戻すときは is_active=true）----
-- update public.lark_routes set is_active = false where id = 'ed20e532-19d3-4b10-9224-3166818ed994' and 'join_registered' = any(events);

-- ---- ステップ D: LINE の賃金返信（_shared/wage-line-handler.ts）を事実上止める: 承認待ちの依頼をすべて閉じる（本部の LINE 連携は既に外れており到達不能）----
--   以後は Slack 側で賃金が入ると onboarding_set_item が hr_wage_requests を done にするので、新しい pending は残らない
-- update public.hr_wage_requests set status = 'cancelled', done_at = now() where status = 'pending';

-- ---- 戻し方（ロールバック）----
-- update public.app_settings set value = value || '{"enabled": false, "legacy_wage_text": true}'::jsonb, updated_at = now() where key = 'onboarding_slack';
-- update public.lark_routes set is_active = true where id = 'ed20e532-19d3-4b10-9224-3166818ed994';
select 'このファイルはステップごとにコメントを外して実行してください（既定では何もしません）' as note;
