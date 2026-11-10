-- 2026-11-12 担当A（TK-252）: Uber Eats 利用3店（本店・はなれ・芝）を「未連携デリバリーチャネル」として登録する草案（★未適用★）
-- ユーザー確定（2026-11）: Uber Eats の利用店は本店・はなれ・芝。売上は未連携（データ未取込）＝0円扱いにしない。
-- 影響: delivery_store_map に3行追加のみ。取込ジョブ・既存の rocketnow 行・kd_delivery_daily には影響なし（rocketnow 取込・精算は channel='rocketnow' で絞っている）。VM v6.3 適用後に「参考値＋評価保留」の表示になる。
-- 【rollback】delete from public.delivery_store_map where channel = 'ubereats' and channel_store_id like 'unlinked-%';
insert into public.delivery_store_map (channel, channel_store_id, store_id, channel_store_name, active)
select 'ubereats', 'unlinked-' || s.file_key, s.id, 'Uber Eats（未連携）', true
from public.stores s where s.name in ('鳥一代 本店', '鳥一代 はなれ', '芝の鳥一代')
on conflict (channel, channel_store_id) do nothing;
-- 確認: select m.channel, m.channel_store_id, s.name, m.active from public.delivery_store_map m join public.stores s on s.id = m.store_id order by m.channel, s.name;
