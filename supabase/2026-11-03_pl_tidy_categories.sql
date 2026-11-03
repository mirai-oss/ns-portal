-- PLの区分(F/L/A/R/O)整理（担当A・2026-11-03・ユーザー確定: 旅費交通費=O・通勤手当=L・MFの考え方に合わせる）。手入力行の区分を科目マスタに合わせる。履歴はトリガで残る。
-- 戻す: pl_entries_historyのold_rowから復元。
begin;
select set_config('app.actor', 'pl-tidy-2026-11-03', true);
with m(item, cat) as (values
 ('役員報酬','L'),('法定福利費','L'),('通勤手当','L'),('賞与積立','L'),('退職金等','L'),
 ('家賃','R'),('リース料','R'),('家賃更新按分','R'),('広告宣伝費','A'),('販売促進費','A'),
 ('水道光熱費','O'),('通信費','O'),('消耗品・備品費','O'),('修繕費','O'),('衛生管理費','O'),('カード手数料','O'),('支払手数料','O'),('支払報酬料','O'),
 ('採用教育費','O'),('接待交際費','O'),('会議費','O'),('慶弔見舞費','O'),('保険料','O'),('租税公課','O'),('減価償却費','O'),('福利厚生費','O'),
 ('諸会費','O'),('雑費','O'),('本部経費（按分）','O'),('媒体販促費（自動）','O'),('運営委託費','O'),('旅費交通費','O'),
 ('その他売上','S'),('銀行返済','X'),('仕入（食材・飲料）','F'))
update public.pl_entries p set category = m.cat, updated_at = now(), updated_by = 'pl-tidy-2026-11-03'
  from m where p.item = m.item and p.deleted_at is null and p.source = '手入力' and p.category <> m.cat
    and not (p.item = '旅費交通費' and p.sub_item like '%通勤手当%');
update public.pl_entries p set category = 'L', updated_at = now(), updated_by = 'pl-tidy-2026-11-03'
  where p.deleted_at is null and p.source = '手入力' and p.item = '旅費交通費' and p.sub_item like '%通勤手当%' and p.category <> 'L';
update public.account_items set category = 'O', updated_at = now() where name = '旅費交通費' and category <> 'O';
commit;
select category, count(*) from public.pl_entries where deleted_at is null and source='手入力' and item in ('減価償却費','家賃','リース料','旅費交通費','通信費','水道光熱費') group by item, category order by 1;
