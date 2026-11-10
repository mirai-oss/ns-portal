#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Supabase Edge Function のシークレットを入れる小さな道具（値は画面・ログ・コマンド履歴に残さない）。
使い方: python3 scripts/set_function_secret.py EKISPERT_API_KEY
  → 「値を貼り付けて Enter」と聞かれるので、メールで届いたキーを貼る（表示されません）。
  → 成功すると「保存OK: EKISPERT_API_KEY（長さ 32）」のように長さだけ出ます。
仕組み: 一時ファイル（自分だけ読める）に書いて `supabase secrets set --env-file` に渡し、すぐ消す。
"""
import getpass, os, re, subprocess, sys, tempfile
if len(sys.argv) < 2 or not re.fullmatch(r'[A-Z][A-Z0-9_]{2,63}', sys.argv[1]):
    print(__doc__); sys.exit(1)
name = sys.argv[1]
def ask_hidden(name):
    # macOS: 伏せ字の入力ダイアログ（ターミナルの種類に関係なく動く。値は画面に出ない）。使えなければターミナルで伏せ字入力
    if sys.platform == 'darwin':
        script = f'text returned of (display dialog "{name} の値を貼り付けて OK を押してください（伏せ字で表示されます）" default answer "" with hidden answer with title "シークレットの登録")'
        r = subprocess.run(['osascript', '-e', script], capture_output=True, text=True)
        if r.returncode == 0: return r.stdout.rstrip('\n')
        if 'User canceled' in (r.stderr or ''): print('キャンセルされました'); sys.exit(1)
    if not sys.stdin.isatty():
        print('この画面では伏せ字入力ができません。ターミナル.app を開いて同じコマンドを実行してください'); sys.exit(1)
    return getpass.getpass(f'{name} の値を貼り付けて Enter（表示されません）: ')
val = ask_hidden(name).strip()
if not val or '\n' in val:
    print('空（または改行入り）なので何もしませんでした'); sys.exit(1)
fd, path = tempfile.mkstemp(prefix='fnsecret_', suffix='.env'); os.close(fd); os.chmod(path, 0o600)
try:
    with open(path, 'w', encoding='utf-8') as f: f.write(f'{name}={val}\n')
    r = subprocess.run(['npx', 'supabase', 'secrets', 'set', '--env-file', path, '--remote=uuvsxzhpxtghojoubjcc', '--yes'], capture_output=True, text=True, cwd=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    ok = r.returncode == 0 and '"_tag":"Error"' not in (r.stdout or '')
    if ok: print(f'保存OK: {name}（長さ {len(val)}）')
    else: print('エラー:', ((r.stderr or '') + (r.stdout or '')).replace(val, '***')[-500:]); sys.exit(1)
finally:
    try: os.remove(path)
    except OSError: pass
