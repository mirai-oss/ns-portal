-- ============================================================
-- 担当G: データ出力センター Phase 1 追補③
-- ユーザー要望（2026-08-25）: 広告費側の媒体名と売上側の媒体名が完全一致しない場合に、
-- コード変更なしで管理者が対応関係を登録できるようにする（tpl_templatesと同じ「自己管理」思想）。
-- 既存ファイルは編集せず新規ファイルで追補する。冪等。
-- ============================================================

-- 生の媒体名（広告DB・stg_media双方の表記ゆれ）→ 正規化後の媒体名（表示に使う統一名）。
-- canonMedia()のハードコードされた変換ルールで拾えない組み合わせを、管理者がここで追加登録する。
-- raw_mediaは大文字小文字・空白を問わず完全一致で引く（正規化はコード側でtrim+toUpperCase）。
create table if not exists tpl_media_alias (
  id uuid primary key default gen_random_uuid(),
  raw_media text not null,
  canonical_media text not null,
  created_by uuid references users(id),
  created_at timestamptz not null default now(),
  unique (raw_media)
);

alter table tpl_media_alias enable row level security;
drop policy if exists tpl_media_alias_read on tpl_media_alias;
create policy tpl_media_alias_read on tpl_media_alias for select using (export_can_access());
drop policy if exists tpl_media_alias_write on tpl_media_alias;
create policy tpl_media_alias_write on tpl_media_alias for all
  using (export_can_manage_templates()) with check (export_can_manage_templates());

-- 確認用（実行はしない・手動確認時のコメント）:
-- select * from tpl_media_alias order by raw_media;
