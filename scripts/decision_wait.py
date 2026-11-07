#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Slack に出した判断依頼（decision_requests）の答えを読む小さな道具。読むだけ・何も書かない。
使い方:
  python3 scripts/decision_wait.py <request_id>      … その依頼の状態を JSON で表示
  python3 scripts/decision_wait.py --list            … 答え待ち（pending）の一覧
終了コード: 0=answered（答えあり） 2=pending（まだ） 3=expired/cancelled（締切・取消） 4=見つからない
ポーリングは呼び出し側（Claude セッションの /loop など）が行う。この道具は 1 回読むだけ。
鍵: ~/.config/ns-portal/supabase_pat（画面には出さない）。
"""
import json, os, sys, urllib.request

PROJECT = 'uuvsxzhpxtghojoubjcc'
DB_QUERY = f'https://api.supabase.com/v1/projects/{PROJECT}/database/query'

def db(query):
    pat = open(os.path.expanduser('~/.config/ns-portal/supabase_pat')).read().strip()
    req = urllib.request.Request(DB_QUERY, data=json.dumps({'query': query}).encode(),
        headers={'Authorization': 'Bearer ' + pat, 'Content-Type': 'application/json'})
    try:
        return json.loads(urllib.request.urlopen(req, timeout=60).read().decode())
    except urllib.error.HTTPError as e:
        sys.exit(f'DB エラー HTTP {e.code}: {e.read().decode()[:600]}')

COLS = ("d.id as request_id, d.status, d.question, d.options, d.answer, d.answer_label, u.name as answered_by_name, "
        "d.answered_via, d.answered_at, d.channel_key, d.asked_by, d.created_at, d.expires_at, "
        "(d.status='pending' and d.expires_at < now()) as past_due")

def main(argv):
    if not argv or argv[0] in ('-h', '--help'): print(__doc__); sys.exit(1)
    if argv[0] == '--list':
        rows = db(f"select {COLS} from decision_requests d left join users u on u.id=d.answered_by where d.status='pending' order by d.created_at desc limit 50")
        print(json.dumps(rows, ensure_ascii=False, indent=1)); return
    rid = argv[0].replace("'", "")
    rows = db(f"select {COLS} from decision_requests d left join users u on u.id=d.answered_by where d.id='{rid}'::uuid")
    if not rows: print(json.dumps({'status': 'not_found', 'request_id': rid}, ensure_ascii=False)); sys.exit(4)
    r = rows[0]
    # 期限を過ぎた pending は「expired 扱い」で返す（DB の status は RPC か次の整理で変わる。ここは読むだけ）
    if r.get('past_due'): r['status'] = 'expired'
    print(json.dumps(r, ensure_ascii=False, indent=1))
    sys.exit({'answered': 0, 'pending': 2}.get(r['status'], 3))

if __name__ == '__main__':
    main(sys.argv[1:])
