-- =============================================================
-- user_slack の初期紐付け（2026-11-07）。状態: ★ 未適用 ★
-- 背景: Slack のボタン押下は slack-interact が user_slack で社内ユーザーに解決する。現状 user_slack は 0 件。
--       notify-slack の users_sync（メール自動照合）は service_role / 本部ユーザーの JWT が必要で手元から呼べないため、
--       手元で Slack users.list（users:read.email）とハブ users.email を照合した結果（4 人とも一致・不一致 0）を入れる。
-- 冪等: 既にある user_id は触らない。メールアドレスそのものはリポジトリに書かない（matched_email は適用時に users から補う）。
-- =============================================================
insert into user_slack (user_id, slack_user_id, matched_by, matched_email)
select u.id, m.slack_user_id, 'email', lower(trim(u.email))
from (values
  ('cf394dcb-2184-4c68-8119-a3f25a4a86b1'::uuid, 'U0C751GDZDG'),   -- 中山 俊士（CEO・master）
  ('f47e43d5-2fef-4df8-9f7e-4b52cb56e0c6'::uuid, 'U0C7L49ELHL'),   -- 佐藤俊一（TEAM）
  ('6ce6d3da-e910-4017-b924-7b5e293900b4'::uuid, 'U0C7GP7TXEH'),   -- 鍋倉巧（TEAM）
  ('8e989a75-0234-4611-af72-3c71f7c4f170'::uuid, 'U0C7ENECTDZ')    -- 坂本龍太郎（TEAM）
) as m(user_id, slack_user_id)
join users u on u.id = m.user_id and u.is_active
on conflict (user_id) do nothing;

-- 確認用: select us.slack_user_id, u.name, us.matched_by from user_slack us join users u on u.id = us.user_id order by u.name;
