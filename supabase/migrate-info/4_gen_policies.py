#!/usr/bin/env python3
"""関数とRLSポリシーを info スキーマ向けに書き換えて SQL を生成する。

方針:
- 関数は info スキーマに作り、`SET search_path = info, public` を付ける
  （関数内の裸のテーブル名が info 側を指すようにするため）
- **handle_new_user は移植しない**。移設元では新規ログインユーザーに自動で
  profiles を作っていたが、ハブでは日報の全従業員が対象になってしまい、
  機密情報（口座・給与・ID/PW金庫）へ勝手に入れてしまうため。
  社内情報管理システムを使える人は info.profiles に明示的に追加する運用にする。
"""
import json, re

BASE = __file__.rsplit('/', 1)[0]
S = json.load(open(f'{BASE}/info_schema.json'))

SKIP_FUNCTIONS = {'handle_new_user'}
FUNC_NAMES = [f['proname'] for f in S['functions'] if f['proname'] not in SKIP_FUNCTIONS]

out = ['-- ============================================================',
       '-- 社内情報管理システム: 関数とRLSポリシーを info スキーマへ',
       '-- 生成: 4_gen_policies.py',
       '-- ※ handle_new_user は意図的に移植しない（下記コメント参照）',
       '-- ============================================================', '']

# ---------- 関数 ----------
out.append('-- ---------- 関数 ----------')
for f in S['functions']:
    if f['proname'] in SKIP_FUNCTIONS:
        out.append(f"-- [移植しない] {f['proname']}: 新規認証ユーザーに自動で社内情報の権限を与える処理。")
        out.append("--   ハブでは日報の全従業員が新規ユーザーになるため、自動付与は危険。")
        out.append("--   社内情報を使う人は info.profiles に明示的に行を追加すること。")
        out.append('')
        continue
    d = f['def']
    d = d.replace('FUNCTION public.', 'FUNCTION info.', 1)
    # SECURITY DEFINER の直後に search_path を差し込む（未指定なら）
    if 'SET search_path' not in d:
        d = d.replace(' SECURITY DEFINER\n', " SECURITY DEFINER\n SET search_path TO 'info', 'public'\n", 1)
    out.append(d.rstrip() + ';')
    out.append('')

# ---------- RLS有効化 ----------
tables = sorted({c['table_name'] for c in S['columns']})
out.append('-- ---------- 行レベルセキュリティを有効化 ----------')
for t in tables:
    out.append(f'alter table info."{t}" enable row level security;')
out.append('')

# ---------- ポリシー ----------
def fix_expr(e):
    """ポリシー式の中の関数呼び出し・テーブル参照を info 側へ向ける"""
    if not e:
        return e
    e = e.replace('public.', 'info.')
    for fn in FUNC_NAMES:
        # 裸の関数呼び出し（info. が付いていないもの）を info. 付きに
        e = re.sub(rf'(?<![\w.]){fn}\s*\(', f'info.{fn}(', e)
    # FROM/JOIN の裸テーブル名を info. 付きに
    for t in tables:
        e = re.sub(rf'(?<![\w."])(from|join)\s+{t}(?![\w."])', rf'\1 info.{t}', e, flags=re.I)
    return e

out.append('-- ---------- ポリシー ----------')
for p in S['policies']:
    t, name = p['tablename'], p['policyname']
    cmd = p['cmd'] if p['cmd'] != 'ALL' else 'ALL'
    roles = p.get('roles') or '{public}'
    if isinstance(roles, str):
        roles = roles.strip('{}').split(',')
    roles = ', '.join(r.strip().strip('"') for r in roles if r.strip())
    parts = [f'create policy "{name}" on info."{t}"',
             f'  as {"permissive" if p.get("permissive") != "RESTRICTIVE" else "restrictive"}',
             f'  for {cmd.lower()}',
             f'  to {roles}']
    if p.get('qual'):
        parts.append(f'  using ({fix_expr(p["qual"])})')
    if p.get('with_check'):
        parts.append(f'  with check ({fix_expr(p["with_check"])})')
    out.append(f'drop policy if exists "{name}" on info."{t}";')
    out.append('\n'.join(parts) + ';')
    out.append('')

# ---------- トリガー ----------
out.append('-- ---------- トリガー ----------')
for tg in S['triggers']:
    if 'handle_new_user' in tg['def'] or tg['tbl'] == 'users':
        out.append(f"-- [移植しない] {tg['tgname']} on {tg['tbl']}（handle_new_user と同じ理由）")
        continue
    d = tg['def'].replace(' ON public.', ' ON info.').replace('EXECUTE FUNCTION public.', 'EXECUTE FUNCTION info.')
    # pg_get_triggerdef は関数名を修飾せずに返すことがあるので info. を補う
    for fn in FUNC_NAMES:
        d = re.sub(rf'EXECUTE FUNCTION\s+{fn}\s*\(', f'EXECUTE FUNCTION info.{fn}(', d)
    out.append(f'drop trigger if exists "{tg["tgname"]}" on info."{tg["tbl"]}";')
    out.append(d + ';')
out.append('')

# ---------- API公開用の権限 ----------
out.append('-- ---------- PostgREST から使えるように ----------')
out.append('grant usage on schema info to anon, authenticated, service_role;')
out.append('grant all on all tables in schema info to anon, authenticated, service_role;')
out.append('grant all on all routines in schema info to anon, authenticated, service_role;')
out.append('grant all on all sequences in schema info to anon, authenticated, service_role;')
out.append("alter default privileges in schema info grant all on tables to anon, authenticated, service_role;")

open(f'{BASE}/info_policies.generated.sql', 'w').write('\n'.join(out) + '\n')
print(f'関数 {len(FUNC_NAMES)}件（移植しない {len(SKIP_FUNCTIONS)}件）/ ポリシー {len(S["policies"])}件 を生成')
