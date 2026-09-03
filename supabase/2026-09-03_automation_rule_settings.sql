-- 自動処理ルール設定（会計・請求書処理の全面刷新 フェーズA-5・2026-09-03）
--
-- ユーザー要望「AIの判断ではなくシステムとして決めるルールを確認・設定できるUIにしてほしい」に対応。
-- 汎用的なルールビルダーではなく、固定の判定ゲート（8種）をON/OFF・動作（自動候補/要確認/停止）
-- だけ調整できる形にする（お金にかかわる自動化のため、自由度が高すぎるルールエンジンは作らない）。
create table if not exists automation_rule_settings (
  key text primary key,
  label text not null,
  description text,
  enabled boolean not null default true,
  action text not null check (action in ('auto_candidate','require_review','block')),
  params jsonb not null default '{}',
  updated_by uuid references users(id),
  updated_at timestamptz not null default now()
);
alter table automation_rule_settings enable row level security;
drop policy if exists ars_read on automation_rule_settings;
create policy ars_read on automation_rule_settings for select
  using (invoice_can_access());
drop policy if exists ars_write on automation_rule_settings;
create policy ars_write on automation_rule_settings for all
  using (coalesce((select u.is_master or u.role in ('CEO','HQ') from users u where u.id = auth.uid() and u.is_active), false))
  with check (coalesce((select u.is_master or u.role in ('CEO','HQ') from users u where u.id = auth.uid() and u.is_active), false));

insert into automation_rule_settings (key, label, description, enabled, action, params) values
  ('journal_rule_exact_match', '仕訳辞書完全一致', '仕訳辞書（取引先・キーワード・金額条件）に完全一致する請求書は自動会計候補にする', true, 'auto_candidate', '{}'),
  ('new_vendor', '新規取引先', '取引先マスタに登録が無い取引先からの請求書は人間確認が必要', true, 'require_review', '{}'),
  ('bank_account_change', '振込先口座変更', '登録済み口座と異なる口座を検知した場合は必ず人間確認（無効化しても安全のため常に確認扱いを推奨）', true, 'require_review', '{}'),
  ('duplicate_suspected', '重複請求疑い', '重複請求の可能性がある場合は自動処理を停止する', true, 'block', '{}'),
  ('corporation_unknown', '法人不明', '対象法人が判定できない場合は自動処理を停止する', true, 'block', '{}'),
  ('store_unknown', '店舗不明', '対象店舗が判定できない場合は人間確認が必要', true, 'require_review', '{}'),
  ('amount_anomaly', '金額異常', '過去実績と比べて金額が大きく外れている場合は人間確認が必要', true, 'require_review', '{"threshold_pct":150}'),
  ('mf_api_error', 'MF APIエラー', 'マネーフォワードAPIがエラーを返した場合は人間確認が必要', true, 'require_review', '{}')
on conflict (key) do nothing;
