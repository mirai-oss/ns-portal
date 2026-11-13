-- 採用の担当者の設定と、決裁・日程調整の権限の設定（2026-11-13・社長の指示）
--   アルバイト・パート: 主担当と予備の担当／社員採用: 主担当＝社長／雇用区分が分からない応募: 確認先＝アルバイト・パートの主担当
--   担当者の設定と、採用を決める権限は別。社員採用の最終決定は社長だけ（マスター権限には付けない）＝ hire_shain_allow_master=false
--   社員採用でも、面接の日程調整は担当者に任せられる＝ interview_shain_ceo_only=false
--   値は users.id（氏名はここに書かない）。戻し方: 4 つの値を null に戻す／2 つのキーを消す
update app_settings set value = value || jsonb_build_object(
    'part_main',       'd00919e0-8a53-457e-aa07-270748a8413f'::uuid,
    'part_backup',     '8e989a75-0234-4611-af72-3c71f7c4f170'::uuid,
    'employee_main',   'cf394dcb-2184-4c68-8119-a3f25a4a86b1'::uuid,
    'unknown_confirm', 'd00919e0-8a53-457e-aa07-270748a8413f'::uuid)
 where key = 'recruit_assign';
update app_settings set value = value || '{"interview_shain_ceo_only": false, "hire_shain_allow_master": false}'::jsonb
 where key = 'recruit_actions';
