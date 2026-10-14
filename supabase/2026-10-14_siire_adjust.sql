-- 【事前報告様式（DB変更）】担当C・2026-10-14「仕入高の置き換え（インフォマート請求書の確定額でPLを置き換え）」
-- 理由: PLの仕入高（原価F）は、日次取込（infomart-siire・kd_pl_monthly_summary.cost_auto）の速報値で入っている。
--       インフォマートの請求書が全部承認・MF登録された月は、各店舗のPLの仕入高を「請求書の確定額（税抜）」に揃える（ユーザー決定 2026-10-14）。
-- 方式: 店舗ごとに 差額調整 = 請求書の仕入高（税抜）合計 − cost_auto を、PL正本 pl_entries に調整行（仕入高・区分F・負の値もあり）として入れる。
--       → PLの仕入高 = 日次取込 + 調整 = 請求書の確定額。現金仕入など請求書以外は触らない。
--       対象: intake_source='infomart' ・MF登録済み・対象月が一致・仕訳の借方科目=仕入高 の行。精算書ルートの店舗は対象外（精算書側で処理）。
--       請求書が1件も無い店舗は調整しない（日次取込のまま）。
-- 追加（新規のみ・既存テーブルは変更なし）:
--   siire_adjust_preview(p_ym)         … 店舗ごとの 日次取込/請求書合計/調整額 と、「全部確定したか」の判定を返す（読み取りのみ）
--   siire_adjust_apply(p_ym, p_mode)   … 'apply'=調整行を書く（全請求書がMF登録済みのときだけ）／'remove'=この月の調整行を消す。pl_entries_bulk_upsert経由（master/CEO/HQのみ・履歴が残る）
-- 調整行: source='自動｜仕入高差額調整'（memoも同じ・source_key='siire-adjust:YYYY-MM:店舗ID'）。PL取込(keiei-kd-refresh)の自動同期で消されないよう、同関数にも除外を追加する。
-- rollback: drop function siire_adjust_preview(text), siire_adjust_apply(text, text);（書いた調整行は siire_adjust_apply(月,'remove') で消してから）

create or replace function public.siire_adjust_preview(p_ym text)
returns jsonb language plpgsql stable security invoker set search_path = public as $$
declare v_stores jsonb; v_gate jsonb;
begin
  if p_ym !~ '^\d{4}-(0[1-9]|1[0-2])$' then raise exception '年月は YYYY-MM で指定してください'; end if;
  if not invoice_can_access() then raise exception '権限がありません'; end if;
  with inv as (
    select i.id, i.mf_journal_id, i.journal_draft, i.checks, i.vendor_name
    from invoices i
    where i.intake_source = 'infomart' and i.invoice_status <> 'cancelled'
      and to_char(coalesce(i.target_year_month, (i.journal_draft->>'transaction_date')::date), 'YYYY-MM') = p_ym
  ), lines as (
    select inv.id, (dl->>'store_id')::uuid as store_id, dl->'debit' as d,
           coalesce((select r->>'route' from jsonb_array_elements(coalesce(inv.checks->'routes','[]'::jsonb)) r where r->>'store_id' = dl->>'store_id' limit 1), 'pl') as route
    from inv, jsonb_array_elements(coalesce(inv.journal_draft->'debit_lines','[]'::jsonb)) dl
    where inv.mf_journal_id is not null and (dl->'debit'->>'account') = '仕入高' and dl->>'store_id' is not null
  ), p as (
    select store_id, count(distinct id) n,
           sum(round(coalesce((d->>'net_amount')::numeric,
                 (d->>'amount')::numeric - floor((d->>'amount')::numeric * coalesce((d->'tax'->>'rate')::numeric,0) / (100 + coalesce((d->'tax'->>'rate')::numeric,0)))))) total
    from lines where route <> 'seisan' group by store_id
  ), s as (
    select store_id, cost_auto from kd_pl_monthly_summary where year_month = p_ym and store_id is not null
  ), e as (
    select store_id, sum(amount) cur from pl_entries where source = '自動｜仕入高差額調整' and year_month = p_ym and deleted_at is null group by store_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'store_id', st.id, 'store_name', st.name, 'invoice_count', p.n, 'invoice_total', p.total,
      'siire', s.cost_auto, 'siire_missing', s.cost_auto is null,
      'adjust', p.total - coalesce(s.cost_auto, 0), 'applied', coalesce(e.cur, 0)) order by st.sort_order), '[]'::jsonb)
    into v_stores
  from p join stores st on st.id = p.store_id left join s on s.store_id = p.store_id left join e on e.store_id = p.store_id;

  select jsonb_build_object(
    'invoice_total_count', count(*),
    'registered_count', count(*) filter (where mf_journal_id is not null),
    'pending', coalesce(jsonb_agg(jsonb_build_object('id', id, 'vendor', vendor_name)) filter (where mf_journal_id is null), '[]'::jsonb))
    into v_gate
  from invoices i
  where i.intake_source = 'infomart' and i.invoice_status <> 'cancelled'
    and to_char(coalesce(i.target_year_month, (i.journal_draft->>'transaction_date')::date), 'YYYY-MM') = p_ym;

  return jsonb_build_object('year_month', p_ym, 'stores', v_stores, 'gate', v_gate);
end $$;
grant execute on function public.siire_adjust_preview(text) to authenticated;

create or replace function public.siire_adjust_apply(p_ym text, p_mode text default 'apply')
returns jsonb language plpgsql security invoker set search_path = public as $$
declare pv jsonb; rows jsonb := '[]'::jsonb; st jsonb; res jsonb; scope jsonb;
begin
  if p_mode not in ('apply','remove') then raise exception 'p_mode は apply か remove'; end if;
  pv := siire_adjust_preview(p_ym);
  scope := jsonb_build_array(jsonb_build_object('source','自動｜仕入高差額調整','year_month',p_ym));
  if p_mode = 'apply' then
    if (pv->'gate'->>'invoice_total_count')::int = 0 then raise exception 'この月のインフォマート請求書がありません'; end if;
    if jsonb_array_length(pv->'gate'->'pending') > 0 then
      raise exception '未承認（MF未登録）の請求書が % 件あります。すべて承認してから実行してください', jsonb_array_length(pv->'gate'->'pending');
    end if;
    for st in select * from jsonb_array_elements(pv->'stores') loop
      if (st->>'adjust')::numeric <> 0 then
        rows := rows || jsonb_build_object('year_month', p_ym, 'store_id', st->>'store_id', 'item', '仕入高', 'category', 'F',
          'amount', (st->>'adjust')::numeric, 'memo', '自動｜仕入高差額調整', 'sub_item', 'インフォマート請求書へ置き換え',
          'source', '自動｜仕入高差額調整', 'source_key', 'siire-adjust:' || p_ym || ':' || (st->>'store_id'));
      end if;
    end loop;
  end if;
  res := pl_entries_bulk_upsert(rows, 'replace_source', false, null, scope);
  if coalesce((res->>'ok')::boolean, false) is not true then raise exception 'PLへの書き込みに失敗しました: %', res; end if;
  return jsonb_build_object('mode', p_mode, 'rows', jsonb_array_length(rows), 'result', res);
end $$;
grant execute on function public.siire_adjust_apply(text, text) to authenticated;
