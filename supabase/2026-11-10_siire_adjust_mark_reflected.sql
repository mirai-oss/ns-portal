-- 2026-11-10 担当C: 仕入高の置き換え（siire_adjust_apply）を実行した月のインフォマート請求書を、「PL反映済み」にする。
-- 経緯: 仕入高は請求書ごとの反映ではなく月ごとの置き換えのため、置き換えを実行しても請求書側のフラグが付かず、請求書一覧の「PL未反映」に残り続けた。
-- 動き: apply=その月（target_year_month）のMF登録済みインフォマート請求書に pl_fee_reflected_at を付ける（未設定のものだけ）。remove=付けたフラグを外す（請求書ごとの反映記録が無いものだけ）。
create or replace function public.siire_adjust_apply(p_ym text, p_mode text default 'apply')
returns jsonb language plpgsql set search_path to 'public' as $$
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
  -- 請求書側の「PL反映済み」フラグ（一覧の『PL未反映』から外す／戻す）
  if p_mode = 'apply' then
    update public.invoices set pl_fee_reflected_at = now(), updated_at = now()
     where intake_source = 'infomart' and mf_journal_id is not null and invoice_status <> 'cancelled'
       and target_year_month = (p_ym || '-01')::date and pl_fee_reflected_at is null;
  else
    update public.invoices i set pl_fee_reflected_at = null, pl_fee_reflected_by = null, updated_at = now()
     where i.intake_source = 'infomart' and i.target_year_month = (p_ym || '-01')::date and i.pl_fee_reflected_at is not null
       and not exists (select 1 from public.invoice_pl_reflections r where r.invoice_id = i.id);
  end if;
  return jsonb_build_object('mode', p_mode, 'rows', jsonb_array_length(rows), 'result', res);
end $$;

-- すでに置き換え済みの月（pl_entries に『自動｜仕入高差額調整』がある月）のインフォマート請求書も反映済みにする
update public.invoices i set pl_fee_reflected_at = now(), updated_at = now()
 where i.intake_source = 'infomart' and i.mf_journal_id is not null and i.invoice_status <> 'cancelled' and i.pl_fee_reflected_at is null
   and to_char(i.target_year_month, 'YYYY-MM') in (select distinct year_month from public.pl_entries where deleted_at is null and source = '自動｜仕入高差額調整');
