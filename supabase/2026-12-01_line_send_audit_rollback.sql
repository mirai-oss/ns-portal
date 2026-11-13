-- 2026-12-01_line_send_audit.sql の戻し。記録の表を消す（記録は失われる。先に控えを取ること）。
-- Edge Function `line-webhook` は、この表が無くても送信を続ける（記録に失敗しても送信は止めない作り）。
-- ただし、表が無いあいだは「同じ相手・同じ文面の連続送信の防止」が効かない。
drop table if exists public.line_send_audit;
