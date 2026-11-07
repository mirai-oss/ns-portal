-- =============================================================
-- Claude セッションが Slack 経由でユーザーの判断（A/B の選択・承認/却下）を受け取る土台（2026-11-07）
-- 状態: ★ 未適用 ★（dry-run 済み。ユーザー承認後に `python3 scripts/apply_sql.py supabase/2026-11-07_decision_requests.sql`）
-- 設計: docs/設計書_Slack通知基盤_Phase1_2026-10-29.md §10（action_id 規約 '<領域>.<対象>.<操作>' → 'decision.request.<選択肢key>'）
--
-- 流れ:
--   scripts/decision_ask.py  … decision_requests に pending 行を作り、notify-slack 経由で「質問＋選択肢ボタン」を送る
--   ユーザーがボタンを押す → slack-interact（署名検証 → user_slack で社内ユーザーに解決）
--     → RPC decision_request_answer（権限・状態・期限・選択肢の検査と更新をここで行う＝Slack から DB を直接更新しない）
--     → notify-slack update で元メッセージを「✅ ○○ が「A」を選択」に差し替え
--   scripts/decision_wait.py … status を読むだけ（ポーリングは呼び出し側）
--
-- RLS: authenticated は select のみ。書き込みは service_role（slack-interact・PAT の運用スクリプト）だけ。
-- =============================================================

-- 選択肢の形を検査する関数（check 制約から呼ぶ。[{"key":"a","label":"A案"},…] key は英小文字・数字・_ の 1〜32 字で重複なし）
create or replace function public.decision_options_valid(p jsonb)
returns boolean language sql immutable as $$
  select jsonb_typeof(p) = 'array'
     and jsonb_array_length(p) between 1 and 5
     and not exists (
       select 1 from jsonb_array_elements(p) o
       where jsonb_typeof(o) <> 'object'
          or coalesce(o->>'key', '') !~ '^[a-z0-9_]{1,32}$'
          or length(coalesce(o->>'label', '')) not between 1 and 75   -- Slack ボタン文言の上限 75 字
     )
     and (select count(distinct o->>'key') from jsonb_array_elements(p) o) = jsonb_array_length(p)
$$;

create table if not exists decision_requests (
  id              uuid primary key default gen_random_uuid(),       -- = request_id（ボタンの value に埋め込む）
  asked_by        text not null,                                    -- 送信元: 'claude:<セッション名>' など（source）
  channel_key     text not null,                                    -- slack_channels.channel_key（例 'hq.dev_system'）
  question        text not null check (length(question) between 1 and 2000),
  options         jsonb not null check (decision_options_valid(options)),
  status          text not null default 'pending' check (status in ('pending','answered','expired','cancelled')),
  answer          text,                                             -- 選ばれた選択肢の key
  answer_label    text,                                             -- 選ばれた選択肢の表示名（後で読む人のため）
  answer_text     text,                                             -- Phase 2: スレッド返信の文章（今は未使用）
  answered_by     uuid references users(id),                        -- user_slack → users.id
  answered_via    text,                                             -- 'slack' ほか
  answered_at     timestamptz,
  notification_id uuid references notification_deliveries(id),     -- 送った Slack メッセージ（台帳）
  allow_roles     text[] not null default array['CEO','HQ'],        -- 答えてよい役割。is_master は常に可
  context         jsonb,                                            -- 質問の背景（秘密情報は入れない）
  expires_at      timestamptz not null default now() + interval '24 hours',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint decision_requests_answered_chk check (status <> 'answered' or (answer is not null and answered_at is not null))
);
create index if not exists decision_requests_status_idx on decision_requests (status, created_at desc);
create index if not exists decision_requests_notification_idx on decision_requests (notification_id);
comment on table decision_requests is 'Claude セッション→Slack ボタン→ユーザーの判断。answered は RPC decision_request_answer だけが付ける（設計書§10）';

alter table decision_requests enable row level security;
drop policy if exists decision_requests_auth_read on decision_requests;
create policy decision_requests_auth_read on decision_requests for select to authenticated using (true);
-- 書き込みポリシーは作らない（= anon/authenticated は書けない。service_role は RLS をバイパス）

-- -------------------------------------------------------------
-- 回答 RPC（slack-interact が service_role で呼ぶ。鉄則: 権限確認・状態チェック・更新はここに集約）
-- 返り値 {ok, code, message} / ok=true のとき {request_id, answer, label, question, answered_by_name, notification_id}
-- -------------------------------------------------------------
create or replace function public.decision_request_answer(p_request_id uuid, p_answer text, p_actor uuid, p_via text default 'slack')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r decision_requests%rowtype;
  v_name text; v_role text; v_master boolean; v_active boolean;
  v_label text; v_prev text;
begin
  select name, role, coalesce(is_master, false), coalesce(is_active, false)
    into v_name, v_role, v_master, v_active from users where id = p_actor;
  if not found or not v_active then
    return jsonb_build_object('ok', false, 'code', 'no_actor', 'message', '操作者が管理システムに見つかりません');
  end if;

  select * into r from decision_requests where id = p_request_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'この判断依頼は見つかりません（取り消された可能性があります）');
  end if;
  if r.status = 'answered' then
    select name into v_prev from users where id = r.answered_by;
    return jsonb_build_object('ok', false, 'code', 'already_answered',
      'message', format('%s さんが先に「%s」を選んでいます', coalesce(v_prev, '別の人'), coalesce(r.answer_label, r.answer)));
  end if;
  if r.status <> 'pending' then
    return jsonb_build_object('ok', false, 'code', 'closed', 'message', 'この判断依頼は締め切られています（' || r.status || '）');
  end if;
  if r.expires_at < now() then
    update decision_requests set status = 'expired', updated_at = now() where id = r.id;
    return jsonb_build_object('ok', false, 'code', 'expired', 'message', 'この判断依頼は期限切れです');
  end if;
  if not (v_master or v_role = any (r.allow_roles)) then
    return jsonb_build_object('ok', false, 'code', 'forbidden', 'message', 'この判断を行う権限がありません');
  end if;
  select o->>'label' into v_label from jsonb_array_elements(r.options) o where o->>'key' = p_answer limit 1;
  if v_label is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_option', 'message', '選択肢が一致しません');
  end if;

  update decision_requests
     set status = 'answered', answer = p_answer, answer_label = v_label,
         answered_by = p_actor, answered_via = coalesce(p_via, 'slack'), answered_at = now(), updated_at = now()
   where id = r.id;

  return jsonb_build_object('ok', true, 'request_id', r.id, 'answer', p_answer, 'label', v_label,
    'question', r.question, 'answered_by_name', v_name, 'notification_id', r.notification_id);
end $$;

revoke all on function public.decision_request_answer(uuid, text, uuid, text) from public, anon, authenticated;
grant execute on function public.decision_request_answer(uuid, text, uuid, text) to service_role;

-- 確認用:
-- select id, status, question, answer_label, answered_at from decision_requests order by created_at desc limit 10;
