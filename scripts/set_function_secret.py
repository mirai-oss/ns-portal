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
val = getpass.getpass(f'{name} の値を貼り付けて Enter（表示されません）: ').strip()
if not val or '\n' in val:
    print('空（または改行入り）なので何もしませんでした'); sys.exit(1)
fd, path = tempfile.mkstemp(prefix='fnsecret_', suffix='.env'); os.close(fd); os.chmod(path, 0o600)
try:
    with open(path, 'w', encoding='utf-8') as f: f.write(f'{name}={val}\n')
    r = subprocess.run(['npx', 'supabase', 'secrets', 'set', '--env-file', path, '--project-ref', 'uuvsxzhpxtghojoubjcc'], capture_output=True, text=True)
    if r.returncode == 0: print(f'保存OK: {name}（長さ {len(val)}）')
    else: print('エラー:', (r.stderr or r.stdout).replace(val, '***')[:400]); sys.exit(1)
finally:
    try: os.remove(path)
    except OSError: pass
