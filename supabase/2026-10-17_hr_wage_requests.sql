-- ============================================================
-- 2026-10-17 担当B（nippo）— 入社登録のLINE通知に返信して賃金（時給・月給）を登録する仕組みの受け皿
-- 【状態】事前報告（ユーザー確認待ち・未適用）。前提: employee_wage_settings（2026-10-17_employee_wage_settings.sql）適用済み
--
-- 【理由】ユーザー要望: 入社登録したらその人の情報が公式LINEで本部に通知され、そのLINEに「時給 1200」などと返信すれば賃金が登録され、
--   スマレジ・タイムカードへ反映される（最終形）。返信がどの人の賃金かを結びつけ、「はい」の確認を挟むために、状態を持つ表が要る。
-- 【現構造】賃金の登録は従業員編集の画面のみ。LINEからの入力口は無い
-- 【変更】新規テーブル3つ（Edge Functionだけが使う＝RLSで画面・anonからは触れない）:
--   ① hr_wage_requests: 入社した人ごとの「賃金の入力待ち」（人ごとに1件・pending/done）
--   ② hr_wage_request_msgs: 通知したLINEメッセージのID（本部の人ごと）。「返信（引用）」でどの人の賃金か判定する用
--   ③ hr_wage_pending_confirm: 返信を読み取った結果の確認待ち（本部の人ごとに1件）。「はい」で登録
-- 【影響】新規テーブルのみ。既存の表・関数は変えない。通知・返信の処理は新しいEdge Function（hr-wage-notify）と
--   line-webhookへの追加（返信の判定）。賃金の登録は従来の employee_wage_settings とスマレジ反映(wage_push)を使う
-- 【migration】本ファイル（冪等）
-- 【rollback】drop table if exists hr_wage_pending_confirm, hr_wage_request_msgs, hr_wage_requests;
-- ============================================================

create table if not exists hr_wage_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references users(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'done', 'cancelled')),
  created_at timestamptz not null default now(),
  notified_at timestamptz,
  done_at timestamptz,
  done_by uuid references users(id)
);
create table if not exists hr_wage_request_msgs (
  request_id uuid not null references hr_wage_requests(id) on delete cascade,
  line_user_id text not null,
  message_id text,
  created_at timestamptz not null default now(),
  primary key (request_id, line_user_id)
);
create index if not exists hr_wage_request_msgs_msg_idx on hr_wage_request_msgs (line_user_id, message_id);
create table if not exists hr_wage_pending_confirm (
  line_user_id text primary key,
  request_id uuid not null references hr_wage_requests(id) on delete cascade,
  parsed jsonb not null,
  created_at timestamptz not null default now()
);
alter table hr_wage_requests enable row level security;
alter table hr_wage_request_msgs enable row level security;
alter table hr_wage_pending_confirm enable row level security;
revoke all on hr_wage_requests, hr_wage_request_msgs, hr_wage_pending_confirm from anon, authenticated;
-- ポリシーを作らない＝画面からは読み書きできない（service_role＝Edge Functionだけ）
comment on table hr_wage_requests is '入社登録後の「賃金の入力待ち」（担当B・2026-10-17新設）。LINE返信での賃金登録用。Edge Function(service_role)のみ';
