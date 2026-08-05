#!/usr/bin/env python3
"""ns-info-system(public) → ハブ(info スキーマ) の DDL を生成する。
データ移送は別スクリプト。ここでは構造だけ。"""
import json

BASE = '/private/tmp/claude-501/-Users-mirai-Claude/0cb30dcf-0335-40af-b44e-12dcec6762ec/scratchpad'
S = json.load(open(f'{BASE}/info_schema.json'))

cols, cons, idx = S['columns'], S['constraints'], S['indexes']
# identity列（information_schema.columns の is_identity='YES'）
IDENTITY = {('audit_logs', 'id'), ('credential_secret_history', 'id')}
tables = sorted({c['table_name'] for c in cols})

# 依存順（FK先を先に作る）にテーブルを並べる
fk_deps = {t: set() for t in tables}
for c in cons:
    if c['constraint_type'] == 'FOREIGN KEY':
        d = c['def']  # FOREIGN KEY (x) REFERENCES target(y)
        ref = d.split('REFERENCES', 1)[1].strip().split('(')[0].strip().strip('"')
        if ref in fk_deps and ref != c['table_name']:
            fk_deps[c['table_name']].add(ref)
ordered, seen = [], set()
def visit(t, stack=()):
    if t in seen or t in stack:
        return
    for d in sorted(fk_deps.get(t, ())):
        visit(d, stack + (t,))
    seen.add(t); ordered.append(t)
for t in tables:
    visit(t)

def qtype(c):
    dt = c['data_type']
    return {'USER-DEFINED': 'text', 'ARRAY': 'text[]'}.get(dt, dt)

def fix_default(d, tname):
    if d is None:
        return None
    # public. 参照を info. に付け替え（連番シーケンス等）
    return d.replace('public.', 'info.').replace("'public.", "'info.")

lines = ['-- ============================================================',
         '-- 社内情報管理システム → ハブ(info スキーマ) 構造移送',
         '-- 生成: gen_info_ddl.py（元DB wciefkpooncglahqdtmu の public を写像）',
         '-- 冪等: create schema/table if not exists',
         '-- ============================================================',
         'create schema if not exists info;', '']

for t in ordered:
    tcols = [c for c in cols if c['table_name'] == t]
    defs = []
    for c in tcols:
        piece = f'  "{c["column_name"]}" {qtype(c)}'
        if (t, c['column_name']) in IDENTITY:
            piece += ' generated always as identity'
        d = fix_default(c['column_default'], t)
        if d:
            piece += f' default {d}'
        if c['is_nullable'] == 'NO':
            piece += ' not null'
        defs.append(piece)
    # PK / UNIQUE / CHECK はテーブル内に、FKは後段でまとめて（循環回避）
    for c in cons:
        if c['table_name'] != t:
            continue
        if c['constraint_type'] in ('PRIMARY KEY', 'UNIQUE', 'CHECK'):
            d = c['def']
            if c['constraint_type'] == 'CHECK' and 'IS NOT NULL' in d:
                continue  # not null 制約の内部表現は除外
            defs.append(f'  constraint "{c["constraint_name"]}" {d}')
    lines.append(f'create table if not exists info."{t}" (')
    lines.append(',\n'.join(defs))
    lines.append(');')
    lines.append('')

lines.append('-- ---------- 外部キー ----------')
for c in cons:
    if c['constraint_type'] != 'FOREIGN KEY':
        continue
    d = c['def']
    # 参照先を info スキーマに（auth.users はそのまま）
    tgt = d.split('REFERENCES', 1)[1].strip().split('(')[0].strip().strip('"')
    if tgt in tables:
        d = d.replace(f'REFERENCES {tgt}(', f'REFERENCES info."{tgt}"(')
    lines.append(f'do $$ begin\n  alter table info."{c["table_name"]}" add constraint "{c["constraint_name"]}" {d};\nexception when duplicate_object then null; when duplicate_table then null; end $$;')
lines.append('')

lines.append('-- ---------- インデックス ----------')
for i in idx:
    name = i['indexname']
    if any(c['constraint_name'] == name for c in cons):
        continue  # PK/UNIQUE由来は上で作成済み
    d = i['indexdef'].replace(' ON public.', ' ON info.').replace('CREATE INDEX ', 'CREATE INDEX IF NOT EXISTS ').replace('CREATE UNIQUE INDEX ', 'CREATE UNIQUE INDEX IF NOT EXISTS ')
    lines.append(d + ';')

open(f'{BASE}/info_ddl.sql', 'w').write('\n'.join(lines) + '\n')
print(f'tables={len(ordered)} 生成完了 → info_ddl.sql')
print('順序:', ', '.join(ordered[:8]), '...')
