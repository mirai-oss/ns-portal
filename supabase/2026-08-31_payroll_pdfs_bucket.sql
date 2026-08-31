-- 2026-08-31 担当B（nippo）続き
-- ユーザー要望: スマレジの給与明細一括ダウンロード（ZIP、手動でしか取れない）を人間が解凍して、
-- 従業員ごとにPDFをアップロードしたら、その人の記録に添付されるようにしたい（可能であれば）。
-- ここでは「保管場所」を用意する。マネーフォワードの証憑としての添付（会計側）は担当C(C-7)の
-- 領域のため、置き場所とパス規約を決めて連携しやすくする（invoice-filesと同じ非公開バケット方針）。
-- パス規約: {user_id}/{year_month}.pdf （例: 550e8400-.../2026-08.pdf）。1人1ヶ月1ファイル
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('payroll-pdfs', 'payroll-pdfs', false, 20971520, array['application/pdf'])
on conflict (id) do update set allowed_mime_types = array['application/pdf'];

drop policy if exists payroll_pdfs_read on storage.objects;
create policy payroll_pdfs_read on storage.objects for select using (
  bucket_id = 'payroll-pdfs' and (
    exists(select 1 from users u where u.id = auth.uid() and u.is_active and u.is_master)
    or has_feature(auth.uid(), 'labor_cost_view')
    or (storage.foldername(name))[1] = auth.uid()::text -- 本人は自分の明細を見られる
  )
);
-- アップロードはマスター・本部のみ（給与明細を扱えるのはこの範囲。ns-portal/2026-08-23_invoices.sqlと同方針）
drop policy if exists payroll_pdfs_insert on storage.objects;
create policy payroll_pdfs_insert on storage.objects for insert with check (
  bucket_id = 'payroll-pdfs' and exists(select 1 from users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role = 'HQ'))
);
drop policy if exists payroll_pdfs_delete on storage.objects;
create policy payroll_pdfs_delete on storage.objects for delete using (
  bucket_id = 'payroll-pdfs' and exists(select 1 from users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role = 'HQ'))
);
