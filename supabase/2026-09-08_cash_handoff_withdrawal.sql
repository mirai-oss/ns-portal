-- 2026-09-08 担当B（nippo）追加
-- ユーザー追加要望「合計で何件あって金額がいくらになっているか、店舗ごとに絞り込みできる
-- ように、引き出したかどうかわかるようにも、引き出しした金額の写真や本人に渡した写真を
-- 撮って添付できるようにも」に対応。
-- 件数・合計金額の表示／店舗ごとの絞り込みはnippo側のみのフロント実装のためDB変更不要。
-- ここでは①現金引き出しの確認(withdrawn_at・誰が・写真)②渡した側の電子サインに加えて
-- 本人へ手渡した瞬間の写真(handoff_photo_path)、の列を追加する。
-- 写真は任意添付（無くても引き出し確認・渡した側の確定は可能）。

alter table sf_cash_handoff_signatures
  add column if not exists withdrawn_at timestamptz,
  add column if not exists withdrawn_by uuid references users(id),
  add column if not exists withdrawn_photo_path text,
  add column if not exists handoff_photo_path text;

comment on column sf_cash_handoff_signatures.withdrawn_at is '銀行・ATMから現金を引き出した確認日時（2026-09-08追加）';
comment on column sf_cash_handoff_signatures.withdrawn_photo_path is '引き出した金額が分かる写真のstorageパス（cash-signaturesバケット、任意）';
comment on column sf_cash_handoff_signatures.handoff_photo_path is '本人へ現金を手渡した瞬間の写真のstorageパス（cash-signaturesバケット、任意。渡した側の電子サインに追加する形）';

-- サイン画像(PNG)と違いスマホカメラ撮影(JPEG)の写真も保存するため、許可mime typeを追加し
-- サイズ上限も引き上げる（既存のRLSポリシーはbucket_id基準のため変更不要）
update storage.buckets set
  allowed_mime_types = array['image/png','image/jpeg'],
  file_size_limit = 8388608
where id = 'cash-signatures';
