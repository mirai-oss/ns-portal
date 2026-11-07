#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Claude セッションから Slack に「質問＋選択肢ボタン」を送り、ユーザーの判断を待てる状態にする小さな道具。
使い方:
  python3 scripts/decision_ask.py "質問文" a=A案 b=B案 [c=見送り] [--channel hq.dev_system] [--hours 24]
                                  [--by claude:<セッション名>] [--roles HQ] [--preview]
  python3 scripts/decision_ask.py --cancel <request_id>        … まだ答えが無い依頼を取り消す（Slack の本文も差し替える）
  選択肢は key=表示名（key は英小文字・数字・_ の 1〜32 字、2〜5 個、表示名 75 字まで）。
  --preview は送らずに Block Kit の中身を表示するだけ。答えられるのは既定でマスター（is_master）だけ。--roles は例外的に広げるとき。
出力: 1 行目に request_id（この値を scripts/decision_wait.py に渡す）。
仕組み: decision_requests に pending 行を insert（PAT）→ notify-slack send（合言葉）→ 行に notification_id を書く。
鍵: ~/.config/ns-portal/supabase_pat と notify_slack_secret から読む（画面には出さない）。
"""
import json, os, sys, uuid, re, urllib.request

PROJECT = 'uuvsxzhpxtghojoubjcc'
DB_QUERY = f'https://api.supabase.com/v1/projects/{PROJECT}/database/query'
NOTIFY = f'https://{PROJECT}.supabase.co/functions/v1/notify-slack'
ACTION_PREFIX = 'decision.request.'

def read_key(name):
    return open(os.path.expanduser(f'~/.config/ns-portal/{name}')).read().strip()

def db(query, params=None):
    """PAT で SQL を実行（params は $1.. ではなく文字列を安全に埋める: 値は JSON 経由で渡す）"""
    req = urllib.request.Request(DB_QUERY, data=json.dumps({'query': query}).encode(),
        headers={'Authorization': 'Bearer ' + read_key('supabase_pat'), 'Content-Type': 'application/json'})
    try:
        return json.loads(urllib.request.urlopen(req, timeout=60).read().decode())
    except urllib.error.HTTPError as e:
        sys.exit(f'DB エラー HTTP {e.code}: {e.read().decode()[:600]}')

def lit(s):
    """SQL 文字列リテラル（シングルクォートを二重化）"""
    return "'" + str(s).replace("'", "''") + "'"

def notify(body):
    req = urllib.request.Request(NOTIFY, data=json.dumps(body, ensure_ascii=False).encode(),
        headers={'Content-Type': 'application/json', 'x-notify-secret': read_key('notify_slack_secret')})
    try:
        return json.loads(urllib.request.urlopen(req, timeout=60).read().decode())
    except urllib.error.HTTPError as e:
        return {'ok': False, 'http': e.code, 'error': e.read().decode()[:600]}

def build_blocks(question, options, request_id, notification_id, hours):
    buttons = []
    for i, o in enumerate(options):
        b = {'type': 'button', 'text': {'type': 'plain_text', 'text': o['label'], 'emoji': True},
             'action_id': ACTION_PREFIX + o['key'],
             'value': json.dumps({'request_id': request_id, 'notification_id': notification_id, 'key': o['key']})}
        if i == 0: b['style'] = 'primary'
        buttons.append(b)
    return [
        {'type': 'section', 'text': {'type': 'mrkdwn', 'text': f'❓ *判断をお願いします*\n{question}'}},
        {'type': 'actions', 'block_id': 'decision', 'elements': buttons},
        {'type': 'context', 'elements': [{'type': 'mrkdwn', 'text': f'依頼 `{request_id[:8]}`・期限 {hours} 時間・ボタンを押すと管理システムに記録されます'}]},
    ]

def main(argv):
    if not argv or argv[0] in ('-h', '--help'): print(__doc__); sys.exit(1)
    if argv[0] == '--cancel':
        rid = argv[1]
        rows = db(f"update decision_requests set status='cancelled', updated_at=now() where id={lit(rid)}::uuid and status='pending' returning id, notification_id")
        if not rows: sys.exit('取り消せませんでした（pending ではない・または存在しない）')
        if rows[0].get('notification_id'):
            notify({'action': 'update', 'notification_id': rows[0]['notification_id'], 'text': '⏹️ この判断依頼は取り消されました（答えは不要です）'})
        print(rid); return

    def take(flag, default=None):
        if flag in argv:
            i = argv.index(flag); v = argv[i + 1]; del argv[i:i + 2]; return v
        return default
    preview = '--preview' in argv
    if preview: argv.remove('--preview')
    channel = take('--channel', 'hq.dev_system')
    hours = int(take('--hours', '24'))
    asked_by = take('--by', 'claude:' + os.environ.get('CLAUDE_SESSION', os.environ.get('USER', 'cli')))
    roles = [r.strip() for r in take('--roles', '').split(',') if r.strip()]   # 既定=空（マスターだけが答えられる）。--roles で広げるのは例外
    question = argv[0]
    options = []
    for a in argv[1:]:
        if '=' not in a: sys.exit(f'選択肢の形が違います: {a}（key=表示名）')
        k, label = a.split('=', 1)
        if not re.fullmatch(r'[a-z0-9_]{1,32}', k): sys.exit(f'key は英小文字・数字・_ の 1〜32 字: {k}')
        if not 1 <= len(label) <= 75: sys.exit(f'表示名は 1〜75 字: {label}')
        options.append({'key': k, 'label': label})
    if not 2 <= len(options) <= 5: sys.exit('選択肢は 2〜5 個')
    if len({o['key'] for o in options}) != len(options): sys.exit('key が重複しています')

    request_id = str(uuid.uuid4()); notification_id = str(uuid.uuid4())
    blocks = build_blocks(question, options, request_id, notification_id, hours)
    if preview:
        print(json.dumps({'request_id': request_id, 'channel_key': channel, 'blocks': blocks}, ensure_ascii=False, indent=1)); return

    # 1) pending 行（Slack 送信前に作る: ボタンが押された時点で行が無い、を避ける）
    roles_sql = 'array[' + ','.join(lit(r) for r in roles) + ']::text[]'
    db(f"insert into decision_requests (id, asked_by, channel_key, question, options, allow_roles, expires_at) values "
       f"({lit(request_id)}::uuid, {lit(asked_by)}, {lit(channel)}, {lit(question)}, {lit(json.dumps(options, ensure_ascii=False))}::jsonb, "
       f"{roles_sql}, now() + interval '{hours} hours')")
    # 2) Slack へ（notification_id を先に採番して渡す＝notify-slack が同じ id で台帳に書く）
    res = notify({'action': 'send', 'notification_id': notification_id, 'channel_key': channel,
                  'text': f'❓ 判断をお願いします: {question}', 'blocks': blocks,
                  'event': 'decision_request', 'source': asked_by,
                  'ref': {'table': 'decision_requests', 'id': request_id},
                  'username': 'Claude（判断依頼）', 'icon_emoji': ':robot_face:'})
    if not res.get('ok'):
        db(f"update decision_requests set status='cancelled', context=jsonb_build_object('send_error', {lit(json.dumps(res, ensure_ascii=False))}::jsonb), updated_at=now() where id={lit(request_id)}::uuid")
        sys.exit('Slack に送れませんでした: ' + json.dumps(res, ensure_ascii=False))
    # 3) 行に notification_id を書く
    db(f"update decision_requests set notification_id={lit(notification_id)}::uuid, updated_at=now() where id={lit(request_id)}::uuid")
    print(request_id)
    print(json.dumps({'ok': True, 'request_id': request_id, 'notification_id': notification_id, 'channel_key': channel, 'ts': res.get('ts'), 'status': res.get('status')}, ensure_ascii=False))

if __name__ == '__main__':
    main(sys.argv[1:])
