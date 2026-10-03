-- ============================================================
-- 2026-10-03 担当B（nippo）— 本人向け書類（源泉徴収票等）の保管・配布の受け皿
-- 実装指示書_退職手続きタスクと書類配布_担当BE_2026-10-03.md §3-2
-- 【状態】事前報告（ユーザー確認待ち）。まだ本番へ適用していない
--
-- 【理由】退職承認後の本部タスク「退職手続き」の最終工程（源泉徴収票）で、本部がアップロードした
--   PDFを本人のマイページ「📄 自分の書類」に表示するため。担当Eの工程5ボタン
--   （action_kind='offboarding_tax_slip'）が、PDFをStorage `hr-documents` へ置いたあとRPC
--   hr_register_document を呼び、続けて本人へLINE案内（PDF/URLは送らない）する。
-- 【現構造】該当テーブル・RPC・バケットは存在しない（本番は未確認＝PAT失効のためリポジトリ内のgrepのみ。
--   hr_documents／hr_register_document／hr-documents はns-portal・nippoのどこにも未定義）。
--   同種の前例: payroll-pdfsバケット（従業員×月の給与明細PDF・非公開・本人は自分のフォルダ読取のみ）
-- 【影響】新規テーブル1・新規RPC2・新規バケット1・storageポリシー4を追加するだけ。
--   既存テーブル・既存RPC・既存バケットへの変更なし。既存データへの影響なし
-- 【補足Q1=a（退職後も書類ページだけは本人が見られる）の実現】本人の読取ポリシー（テーブル・
--   Storage）には「is_active」条件を付けない（users.is_active=falseの退職者でも自分の行・自分の
--   フォルダは読める）。書き込み側（本部/社長/マスター）は従来どおりis_active必須。nippo側は
--   hr_documentsに自分の行がある退職者に限り、書類ページ専用でログインを通す（他のテーブルは
--   RLSがis_active必須のため見えない）
-- 【migration】本ファイル（CREATE TABLE IF NOT EXISTS／CREATE OR REPLACE／ポリシーはdrop→create）。冪等
-- 【rollback】
--   drop function if exists public.hr_register_document(uuid,text,int,text);
--   drop function if exists public.hr_mark_document_notified(uuid);
--   drop table if exists hr_documents;
--   drop policy if exists hr_documents_read on storage.objects;  (insert/update/deleteも同様)
--   delete from storage.buckets where id='hr-documents';  ※中身(PDF)があれば先に削除が必要
-- ============================================================

-- ① テーブル
create table if not exists hr_documents (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id),
  kind text not null,              -- 現状は'withholding_slip'（源泉徴収票）のみ。将来の書類種別はRPC側の許可リストに足す
  year int,                        -- 対象年（源泉徴収票=その年分）
  path text not null,              -- Storage hr-documentsバケット内のパス。規約: {user_id}/withholding_{year}.pdf
  uploaded_by uuid references users(id),
  uploaded_at timestamptz not null default now(),
  line_notified_at timestamptz,    -- 本人へLINE案内を送った時刻（担当Eのボタンがhr_mark_document_notifiedで記録）
  unique (user_id, kind, year)     -- 同じ年の同種書類は1件（再アップロード＝差し替え）
);
comment on table hr_documents is '本人向け配布書類（源泉徴収票等）の登録簿（担当B・nippo所有・2026-10-03新設）。書き込みはRPC経由のみ';

alter table hr_documents enable row level security;
drop policy if exists hr_documents_read on hr_documents;
create policy hr_documents_read on hr_documents for select using (
  user_id = auth.uid()   -- 本人は自分の行を読める（is_active不問＝退職後も可。補足Q1=a）
  or exists(select 1 from users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO','HQ')))
);
-- insert/update/delete のポリシーは作らない＝直接の書き込みは全面拒否。書き込みは下のRPC(security definer)のみ

-- ② RPC: 書類の登録（担当Eの工程5が、PDFをStorageへ置いた後に呼ぶ）。本部・社長・マスターのみ
create or replace function public.hr_register_document(p_user uuid, p_kind text, p_year int, p_path text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_id uuid; v_replaced boolean;
begin
  if not exists(select 1 from users where id = auth.uid() and is_active and (is_master or role in ('CEO','HQ'))) then
    raise exception '権限がありません（本部・社長・マスターのみ）';
  end if;
  if p_kind not in ('withholding_slip') then
    raise exception '未対応の書類種別です: %', p_kind;
  end if;
  if not exists(select 1 from users where id = p_user) then
    raise exception '対象の従業員が見つかりません';
  end if;
  if p_path is null or p_path not like (p_user::text || '/%') then
    raise exception 'パスは「{対象者のuser_id}/ファイル名」の形式にしてください（本人フォルダ以外には登録できません）';
  end if;
  select exists(select 1 from hr_documents where user_id = p_user and kind = p_kind and year is not distinct from p_year) into v_replaced;
  insert into hr_documents(user_id, kind, year, path, uploaded_by, uploaded_at, line_notified_at)
  values (p_user, p_kind, p_year, p_path, auth.uid(), now(), null)
  on conflict (user_id, kind, year) do update
    set path = excluded.path, uploaded_by = excluded.uploaded_by, uploaded_at = now(),
        line_notified_at = null -- 差し替え時は新しいファイルとして再度LINE案内できるようにする
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'replaced', v_replaced);
end;
$function$;
grant execute on function public.hr_register_document(uuid, text, int, text) to authenticated;

-- ③ RPC: LINE案内を送った時刻の記録（担当Eのボタンが、line-webhook push_user成功後に呼ぶ）
create or replace function public.hr_mark_document_notified(p_document uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if not exists(select 1 from users where id = auth.uid() and is_active and (is_master or role in ('CEO','HQ'))) then
    raise exception '権限がありません（本部・社長・マスターのみ）';
  end if;
  update hr_documents set line_notified_at = now() where id = p_document;
  if not found then raise exception '対象の書類が見つかりません'; end if;
  return jsonb_build_object('ok', true);
end;
$function$;
grant execute on function public.hr_mark_document_notified(uuid) to authenticated;

-- ④ Storageバケット（非公開・PDFのみ・20MB。payroll-pdfsと同方針）
-- パス規約: {user_id}/withholding_{year}.pdf
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('hr-documents', 'hr-documents', false, 20971520, array['application/pdf'])
on conflict (id) do update set allowed_mime_types = array['application/pdf'];

drop policy if exists hr_documents_obj_read on storage.objects;
create policy hr_documents_obj_read on storage.objects for select using (
  bucket_id = 'hr-documents' and (
    (storage.foldername(name))[1] = auth.uid()::text   -- 本人は自分のフォルダだけ読める（is_active不問＝退職後も可。補足Q1=a）
    or exists(select 1 from users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO','HQ')))
  )
);
drop policy if exists hr_documents_obj_insert on storage.objects;
create policy hr_documents_obj_insert on storage.objects for insert with check (
  bucket_id = 'hr-documents' and exists(select 1 from users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO','HQ')))
);
drop policy if exists hr_documents_obj_update on storage.objects; -- 同じパスへの差し替え(upsert)に必要
create policy hr_documents_obj_update on storage.objects for update using (
  bucket_id = 'hr-documents' and exists(select 1 from users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO','HQ')))
);
drop policy if exists hr_documents_obj_delete on storage.objects;
create policy hr_documents_obj_delete on storage.objects for delete using (
  bucket_id = 'hr-documents' and exists(select 1 from users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO','HQ')))
);
