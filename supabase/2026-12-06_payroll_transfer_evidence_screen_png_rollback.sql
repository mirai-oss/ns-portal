-- 2026-12-06_payroll_transfer_evidence_screen_png.sql の戻し方（screen_png の証憑がすでに入っているときは、先に行を確認すること。証憑の行は消さない決まり）
drop function if exists public.payroll_transfer_line_recon_view(uuid);
update storage.buckets set allowed_mime_types = array['text/csv', 'application/pdf'] where id = 'payroll-transfer-evidence';
-- 関数 payroll_transfer_evidence_add は、2026-11-24_payroll_transfer_recon.sql の定義を流し直すと元に戻る（origin 列は残してよい）
-- 種類の制約を戻すのは、screen_png の行が 0 件のときだけ:
--   alter table public.payroll_transfer_evidence drop constraint payroll_transfer_evidence_kind_check;
--   alter table public.payroll_transfer_evidence add constraint payroll_transfer_evidence_kind_check check (kind in ('detail_pdf','result_pdf','detail_csv','result_csv','manual_upload','unavailable'));
