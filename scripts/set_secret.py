#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ハブ Supabase の app_secrets に値を入れる小さな道具（画面にもログにも値を出さない）。
使い方: python3 scripts/set_secret.py ekispert_key
  → 「値を貼り付けて Enter」と聞かれるので、メールで届いたキーを貼る（画面には表示されません）。
  → 保存後は「保存OK: ekispert_key（長さ 32）」のように長さだけ出ます。
鍵は ~/.config/ns-portal/supabase_pat（Personal Access Token）から読む。
"""
import getpass, json, os, re, sys, urllib.request
if len(sys.argv) < 2 or not re.fullmatch(r'[a-z0-9_]{1,64}', sys.argv[1]):
    print(__doc__); sys.exit(1)
key = sys.argv[1]
val = getpass.getpass(f'{key} の値を貼り付けて Enter（表示されません）: ').strip()
if not val:
    print('空なので何もしませんでした'); sys.exit(1)
pat = open(os.path.expanduser('~/.config/ns-portal/supabase_pat')).read().strip()
# 値は SQL 文字列に直接埋めず、ドル引用で安全に渡す
tag = '$sec$'
if tag in val: print('この値は保存できません（$sec$ を含む）'); sys.exit(1)
sql = f"insert into app_secrets(key, value, updated_at) values ('{key}', {tag}{val}{tag}, now()) on conflict (key) do update set value = excluded.value, updated_at = now(); select key, length(value) len from app_secrets where key = '{key}';"
req = urllib.request.Request('https://api.supabase.com/v1/projects/uuvsxzhpxtghojoubjcc/database/query',
    data=json.dumps({'query': sql}).encode(), headers={'Authorization': 'Bearer ' + pat, 'Content-Type': 'application/json'})
try:
    rows = json.loads(urllib.request.urlopen(req).read().decode())
    print(f"保存OK: {rows[0]['key']}（長さ {rows[0]['len']}）")
except urllib.error.HTTPError as e:
    print('エラー HTTP', e.code); print(e.read().decode()[:500]); sys.exit(1)
