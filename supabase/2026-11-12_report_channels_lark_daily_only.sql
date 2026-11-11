-- 2026-11-12 担当A（27番・ユーザー承認）: Lark グループ1〜3 の配信を日報のみにする（週報・月報は Slack #経営-レポート／#経営-レポート-nstyle だけ）。★未適用★
-- 影響: report_channels の group1〜3（kind=lark）の report_kinds を {daily} に。日報は第3段階（店舗別Slack・3日連続成功後に別承認）まで Lark にも残す。Slack 行（slack_tori・slack_nstyle）は変更なし。
-- 【rollback】update public.report_channels set report_kinds = array['daily','weekly','monthly']::text[] where name in ('group1','group2','group3');
do $g$
begin
  if (select count(*) from public.report_channels where name in ('group1','group2','group3') and kind = 'lark' and report_kinds @> array['weekly','monthly']::text[]) <> 3 then
    raise exception 'group1〜3 の report_kinds が想定（weekly/monthly を含む3行）と違います。中止します';
  end if;
end $g$;
update public.report_channels set report_kinds = array['daily']::text[] where name in ('group1', 'group2', 'group3') and kind = 'lark';
-- 確認: select name, kind, report_kinds, is_active from public.report_channels order by sort_order;
