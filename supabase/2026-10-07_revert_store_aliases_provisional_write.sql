-- 担当C: store_aliases への暫定登録の取り消し（司令塔の順序変更・設計書_店舗法人運営関係の正本再設計 Q4）
-- 事前報告様式（DB変更・本番データの修正）:
-- 理由: 給与仕訳 §2「タイムカード事業所名の登録」は、担当Fが作る store_external_mappings ＋ register_store_mapping（Phase1）へ登録する方針に
--       変更された。暫定として入れた「store_aliases への書き込み」（ポリシー store_aliases_write_inv・2026-10-06適用）と、そのボタンで入った
--       登録1件を元に戻す。画面側の登録ボタン・別名追加欄は既に停止済み（BUILD_TAG v62）。
-- 現状（2026-10-07 実データで確認）: store_aliases に source='smaregi_timecard' または 'pl' の行が1件
--       （alias「社員」→ 黒霧屋 新横浜）。「社員」を含む事業所名が部分一致で「黒霧屋 新横浜」に解決され得るうえ、広告・予約など
--       他システムも store_aliases を読むため、残すと誤判定の原因になる。
-- 変更: ① 上記の暫定登録行を削除（source が smaregi_timecard / pl の行のみ） ② 書き込みポリシー store_aliases_write_inv を削除
--       （読み取りポリシー store_aliases_read は不変）
-- 影響: store_aliases の既存の正規・日報・精算システム等の別名には一切触れない。給与仕訳の店舗判定は、削除後は「社員」を別名として使わなくなる。
-- migration: 本ファイル（何度流しても壊れない）。 rollback: 2026-10-06_store_aliases_write_policy.sql を再実行（行は必要なら再登録）。

delete from public.store_aliases where source in ('smaregi_timecard', 'pl');
drop policy if exists store_aliases_write_inv on public.store_aliases;
