# -*- coding: utf-8 -*-
# 読み取りの SQL と Edge Function の呼び出しの小道具（鍵はリポジトリに置かない。~/.config/ns-portal/ から読む）。
#   sql(q)        … Management API で SQL を流す（書き込みも出来てしまうので、読むだけに使う。適用は scripts/apply_sql.py）
#   ef(name, body)… Edge Function を合言葉（x-notify-secret）つきで呼ぶ
import json, os, urllib.request, urllib.error
REF = 'uuvsxzhpxtghojoubjcc'
PAT = open(os.path.expanduser('~/.config/ns-portal/supabase_pat')).read().strip()
NS = open(os.path.expanduser('~/.config/ns-portal/notify_slack_secret')).read().strip()
def sql(q):
    req = urllib.request.Request('https://api.supabase.com/v1/projects/%s/database/query' % REF, data=json.dumps({'query': q}).encode(),
                                 headers={'Authorization': 'Bearer ' + PAT, 'Content-Type': 'application/json'})
    try: return json.loads(urllib.request.urlopen(req).read().decode())
    except urllib.error.HTTPError as e: return {'http_error': e.code, 'body': e.read().decode()[:600]}
def ef(name, body, timeout=120):
    req = urllib.request.Request('https://%s.supabase.co/functions/v1/%s' % (REF, name), data=json.dumps(body).encode(),
                                 headers={'Content-Type': 'application/json', 'x-notify-secret': NS})
    try: return json.loads(urllib.request.urlopen(req, timeout=timeout).read().decode())
    except urllib.error.HTTPError as e: return {'http': e.code, 'body': e.read().decode()[:400]}
def show(x): print(json.dumps(x, ensure_ascii=False, indent=1, default=str))
