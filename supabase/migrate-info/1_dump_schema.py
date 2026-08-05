#!/usr/bin/env python3
"""ns-info-system(public schema) の構造を Management API 経由で抽出して要約する。"""
import json, subprocess, sys

PAT = open('/Users/mirai/.config/ns-portal/supabase_pat').read().strip()
REF = 'wciefkpooncglahqdtmu'

def q(sql):
    payload = json.dumps({'query': sql})
    p = subprocess.run(
        ['curl', '-s', '-X', 'POST',
         f'https://api.supabase.com/v1/projects/{REF}/database/query',
         '-H', f'Authorization: Bearer {PAT}',
         '-H', 'Content-Type: application/json',
         '-d', payload],
        capture_output=True, text=True)
    try:
        return json.loads(p.stdout)
    except Exception:
        print('QUERY FAILED:', p.stdout[:300], file=sys.stderr)
        return []

# 1) テーブルと列
cols = q("""
select table_name, ordinal_position, column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema='public'
order by table_name, ordinal_position
""")

# 2) 制約（PK/FK/UNIQUE/CHECK）
cons = q("""
select tc.table_name, tc.constraint_name, tc.constraint_type,
       pg_get_constraintdef(pc.oid) as def
from information_schema.table_constraints tc
join pg_constraint pc on pc.conname = tc.constraint_name
join pg_namespace n on n.oid = pc.connamespace and n.nspname='public'
where tc.table_schema='public'
order by tc.table_name, tc.constraint_type
""")

# 3) インデックス
idx = q("select tablename, indexname, indexdef from pg_indexes where schemaname='public' order by tablename")

# 4) RLSポリシー
pol = q("select tablename, policyname, cmd, permissive, roles, qual, with_check from pg_policies where schemaname='public' order by tablename, policyname")

# 5) 関数
fns = q("""select p.proname, pg_get_functiondef(p.oid) as def
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' order by p.proname""")

# 6) トリガー
trg = q("""select c.relname as tbl, t.tgname, pg_get_triggerdef(t.oid) as def
from pg_trigger t join pg_class c on c.oid=t.tgrelid
join pg_namespace n on n.oid=c.relnamespace
where n.nspname in ('public','auth') and not t.tgisinternal order by c.relname""")

out = {'columns': cols, 'constraints': cons, 'indexes': idx,
       'policies': pol, 'functions': fns, 'triggers': trg}
base = '/private/tmp/claude-501/-Users-mirai-Claude/0cb30dcf-0335-40af-b44e-12dcec6762ec/scratchpad'
json.dump(out, open(f'{base}/info_schema.json', 'w'), ensure_ascii=False, indent=1)

tables = sorted({c['table_name'] for c in cols})
print(f"tables={len(tables)} columns={len(cols)} constraints={len(cons)} indexes={len(idx)} policies={len(pol)} functions={len(fns)} triggers={len(trg)}")
print("\n".join(tables))
