#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ハブ Supabase（uuvsxzhpxtghojoubjcc）に SQL ファイルを適用する小さな道具。
使い方: python3 scripts/apply_sql.py supabase/<file>.sql [--dry-run]
  --dry-run は begin … rollback で包んで構文・依存エラーだけ確かめる（何も残らない）。
鍵は ~/.config/ns-portal/supabase_pat（Personal Access Token）から読む。画面には出さない。
"""
import json, os, sys, urllib.request
if len(sys.argv) < 2:
    print(__doc__); sys.exit(1)
path = sys.argv[1]; dry = '--dry-run' in sys.argv
sql = open(path, encoding='utf-8').read()
pat = open(os.path.expanduser('~/.config/ns-portal/supabase_pat')).read().strip()
q = ('begin;\n' + sql + '\nrollback;') if dry else sql
req = urllib.request.Request(
    'https://api.supabase.com/v1/projects/uuvsxzhpxtghojoubjcc/database/query',
    data=json.dumps({'query': q}).encode(),
    headers={'Authorization': 'Bearer ' + pat, 'Content-Type': 'application/json'})
try:
    body = urllib.request.urlopen(req).read().decode()
    print(('空振りOK（何も残っていません）: ' if dry else '適用OK: ') + path); print(body[:800])
except urllib.error.HTTPError as e:
    print('エラー HTTP', e.code); print(e.read().decode()[:1500]); sys.exit(1)
