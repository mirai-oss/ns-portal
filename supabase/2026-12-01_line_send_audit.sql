-- LINE 送信の記録（だれが・いつ・だれへ・結果）と、同じ相手・同じ文面の連続送信の防止（2026-11-13・セキュリティ修正）
--
-- 背景: Edge Function `line-webhook` の「アプリからの操作」（push・push_user・onboarding_invite・test）は、
--   Authorization のトークンの中身を読むだけで、署名を確かめていなかった（関数は LINE の Webhook を受けるため verify_jwt=false）。
--   関数の側を「Supabase Auth でトークンを検証する」に直すのに合わせて、送信の記録の表を足す。
--
-- 足すもの: 表 1 つ（line_send_audit）だけ。既存の表・関数・トリガーは変えない。
-- 入れないもの: 本文（指紋 SHA-256 と長さだけ）・LINE の宛先の ID・電話・メール。
-- 読める人: サービス用の鍵だけ（RLS 有効・ポリシーなし）。画面からは直接読めない・書けない。
-- 戻し方: 2026-12-01_line_send_audit_rollback.sql（表を消す。関数は表が無くても送信を続ける作り）

create table if not exists public.line_send_audit (
  id            uuid primary key default gen_random_uuid(),
  created_at    timestamptz not null default now(),
  action        text not null,                       -- push（応募者へ）/ push_user（従業員へ）/ onboarding_invite（入社の案内）/ test ほか
  actor_id      uuid,                                -- 操作した人（検証できたログインの利用者 id）
  target_kind   text check (target_kind in ('applicant', 'user')),
  target_id     uuid,                                -- 応募者の id、または従業員の id
  text_sha256   text check (text_sha256 is null or text_sha256 ~ '^[0-9a-f]{64}$'),
  text_len      integer,
  window_start  timestamptz,                         -- 重複防止の区切り（30 秒ごと）
  result        text not null check (result in ('pending', 'ok', 'failed', 'denied', 'duplicate', 'invalid')),
  detail        text,                                -- 断った理由・失敗の種類（本文や宛先は入れない）
  finished_at   timestamptz
);
comment on table public.line_send_audit is 'LINE 送信の記録（line-webhook のアプリからの操作）。本文と宛先の LINE ID は入れない。';

create index if not exists line_send_audit_target_idx on public.line_send_audit (target_id, created_at desc);
create index if not exists line_send_audit_actor_idx on public.line_send_audit (actor_id, created_at desc);
-- 同じ操作・同じ相手・同じ文面は、同じ区切りの中で 1 つだけ（同時に 2 つ来たときの片方を落とす）
create unique index if not exists line_send_audit_dedupe_key
  on public.line_send_audit (action, target_id, text_sha256, window_start)
  where result in ('pending', 'ok');

alter table public.line_send_audit enable row level security;   -- ポリシーなし＝サービス用の鍵だけ
revoke all on public.line_send_audit from public, anon, authenticated;

-- 確認用:
--   select action, result, count(*) from line_send_audit group by 1, 2 order by 1, 2;
