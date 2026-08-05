#!/usr/bin/env python3
"""社内情報管理システム(public) → ハブ(info) のデータ移送。

- 何度実行してもよい（毎回 info 側を空にしてから入れ直す）
- profiles.id は「メールが一致するハブ users.id」へ付け替える
  （＝ログインがハブのアカウントに一本化されるため）
"""
import json, subprocess, sys, datetime

PAT = open('/Users/mirai/.config/ns-portal/supabase_pat').read().strip()
SRC = 'wciefkpooncglahqdtmu'   # 社内情報管理システム（移設元・読むだけ）
HUB = 'uuvsxzhpxtghojoubjcc'   # ハブ（移設先）

def q(ref, sql):
    p = subprocess.run(
        ['curl', '-s', '-X', 'POST',
         f'https://api.supabase.com/v1/projects/{ref}/database/query',
         '-H', f'Authorization: Bearer {PAT}',
         '-H', 'Content-Type: application/json',
         '-d', json.dumps({'query': sql})],
        capture_output=True, text=True)
    try:
        r = json.loads(p.stdout)
    except Exception:
        print('QUERY FAILED:', p.stdout[:400], file=sys.stderr)
        sys.exit(1)
    if isinstance(r, dict) and r.get('message'):
        print('SQL ERROR:', r['message'][:400], file=sys.stderr)
        sys.exit(1)
    return r

BASE = __file__.rsplit('/', 1)[0]
S = json.load(open(f'{BASE}/info_schema.json'))
cols = S['columns']
tables = sorted({c['table_name'] for c in cols})

# FK依存順（親→子）。DDL生成と同じ理屈。
fk = {t: set() for t in tables}
for c in S['constraints']:
    if c['constraint_type'] == 'FOREIGN KEY':
        tgt = c['def'].split('REFERENCES', 1)[1].strip().split('(')[0].strip().strip('"')
        if tgt in fk and tgt != c['table_name']:
            fk[c['table_name']].add(tgt)
order, seen = [], set()
def visit(t, stack=()):
    if t in seen or t in stack:
        return
    for d in sorted(fk.get(t, ())):
        visit(d, stack + (t,))
    seen.add(t); order.append(t)
for t in tables:
    visit(t)

# --- 人の対応付け: 移設元のprofiles.id → ハブのusers.id（メール一致） ---
src_profiles = q(SRC, "select p.id, p.name, u.email from profiles p join auth.users u on u.id=p.id")
hub_users = q(HUB, "select id, email from users")
hub_by_email = {u['email'].lower(): u['id'] for u in hub_users if u.get('email')}

id_map, unmatched = {}, []
for p in src_profiles:
    em = (p.get('email') or '').lower()
    if em in hub_by_email:
        id_map[p['id']] = hub_by_email[em]
    else:
        unmatched.append(f"{p['name']} <{em}>")

print(f'人の対応付け: {len(id_map)}件マッピング, 未対応 {len(unmatched)}件')
for u in unmatched:
    print('  ⚠️ ハブに同じメールのアカウントが無い:', u)

def lit(v, dtype):
    if v is None:
        return 'null'
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, (dict, list)):
        return "'" + json.dumps(v, ensure_ascii=False).replace("'", "''") + "'::jsonb"
    s = str(v)
    # uuid列の値が対応表にあれば付け替える（人のIDのみ）
    if s in id_map:
        s = id_map[s]
    return "'" + s.replace("'", "''") + "'"

# 子→親の順で全消し（再実行できるように）
print('\ninfo スキーマを空にします…')
for t in reversed(order):
    q(HUB, f'delete from info."{t}"')

total = 0
identity_tables = {'audit_logs', 'credential_secret_history'}
print('データ移送:')
for t in order:
    tcols = [c['column_name'] for c in sorted((c for c in cols if c['table_name'] == t),
                                              key=lambda x: x['ordinal_position'])]
    types = {c['column_name']: c['data_type'] for c in cols if c['table_name'] == t}
    rows = q(SRC, f'select * from public."{t}"')
    if not rows:
        print(f'  {t:28s} 0')
        continue
    collist = ', '.join(f'"{c}"' for c in tcols)
    values = []
    for r in rows:
        values.append('(' + ', '.join(lit(r.get(c), types.get(c)) for c in tcols) + ')')
    ov = ' overriding system value' if t in identity_tables else ''
    # 1文が長くなりすぎないよう200行ずつ
    for i in range(0, len(values), 200):
        chunk = ',\n'.join(values[i:i+200])
        q(HUB, f'insert into info."{t}" ({collist}){ov} values\n{chunk}')
    total += len(rows)
    print(f'  {t:28s} {len(rows)}')

print(f'\n合計 {total} 行を移送しました（{datetime.datetime.now():%Y-%m-%d %H:%M}）')

# 件数の突き合わせ
print('\n件数チェック:')
bad = 0
for t in order:
    a = q(SRC, f'select count(*) as n from public."{t}"')[0]['n']
    b = q(HUB, f'select count(*) as n from info."{t}"')[0]['n']
    if a != b:
        print(f'  ✗ {t}: 移設元={a} ハブ={b}')
        bad += 1
print('  ✓ 全テーブル一致' if bad == 0 else f'  {bad}テーブルで不一致')
