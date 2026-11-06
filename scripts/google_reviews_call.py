#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Edge Function google-reviews-fetch を手元から呼ぶ小さな道具（初期解決・確認・手動取得用）。
使い方: python3 scripts/google_reviews_call.py health
        python3 scripts/google_reviews_call.py resolve [--dry-run] [--listing <uuid>]
        python3 scripts/google_reviews_call.py fetch [--listing <uuid>]
        python3 scripts/google_reviews_call.py confirm --listing <uuid> --place <ChIJ...>
合言葉は ~/.config/ns-portal/notify_slack_secret から読む（画面に出さない）。
"""
import json, os, sys, urllib.request
if len(sys.argv) < 2: print(__doc__); sys.exit(1)
op = sys.argv[1]; args = sys.argv[2:]
body = {'op': op}
if '--dry-run' in args: body['dry_run'] = True
if '--listing' in args: body['listing_id'] = args[args.index('--listing') + 1]
if '--place' in args: body['place_id'] = args[args.index('--place') + 1]
if op == 'confirm': body['by'] = os.environ.get('USER', 'cli')
secret = open(os.path.expanduser('~/.config/ns-portal/notify_slack_secret')).read().strip()
req = urllib.request.Request('https://uuvsxzhpxtghojoubjcc.supabase.co/functions/v1/google-reviews-fetch',
    data=json.dumps(body).encode(), headers={'Content-Type': 'application/json', 'x-notify-secret': secret})
try:
    res = urllib.request.urlopen(req, timeout=180).read().decode()
except urllib.error.HTTPError as e:
    print('エラー HTTP', e.code); print(e.read().decode()[:1500]); sys.exit(1)
print(json.dumps(json.loads(res), ensure_ascii=False, indent=1))
