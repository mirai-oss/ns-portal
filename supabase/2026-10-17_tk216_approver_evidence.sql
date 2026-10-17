-- TK-216 残り（2026-10-17 担当C）: ②承認者列／④納品書の証憑（プレコフーズ）／⑤「ルール不安定」アラート表示
-- ②承認者: 承認してMFへ仕訳登録した人・時刻（mf-journal create が記録）
alter table public.invoices add column if not exists approved_by uuid references public.users(id);
alter table public.invoices add column if not exists approved_at timestamptz;
-- ⑤ルール不安定: 仕訳の下書きを作ったとき（直近90日に2回以上修正された取引先×明細）に invoice-journal-draft が立てる。一覧にバッジを出す
alter table public.invoices add column if not exists rule_unstable boolean not null default false;
-- ④納品書の証憑: 添付の種類（invoice=請求書本体／delivery_note=納品書）。取引先の方針に「必要な証憑の種類」を持たせ、足りなければ要対応にする
alter table public.invoice_attachments add column if not exists attachment_kind text not null default 'invoice';
alter table public.vendor_invoice_policies add column if not exists required_evidence text[];
update public.vendor_invoice_policies set required_evidence = array['delivery_note'], updated_at = now()
 where vendor_key = '株式会社プレコフーズ';   -- 本請求書はインボイスではなく、納品書がインボイス
