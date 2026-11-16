# -*- coding: utf-8 -*-
# 新しい SQL とテストを、1 つの取引（begin … rollback）で流す。本番には何も残らない。
#   使い方: python3 tools/dev/run_in_tx.py <SQL のファイル…> <テストのファイル>
#   テストは、最後に raise exception 'RESULT …' で結果を返す形（begin／commit／rollback は書かない）。
import sys, os, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sqlh import sql
parts = [open(x, encoding='utf-8').read() for x in sys.argv[1:]]
r = sql("begin;\n" + "\n".join(parts) + "\nrollback;")
body = r.get('body', '') if isinstance(r, dict) else json.dumps(r, ensure_ascii=False)
try: body = json.loads(body)['message']
except Exception: pass
i = body.find('RESULT')
print(body[i:].split('\nCONTEXT')[0].replace('｜', '\n ・') if i >= 0 else body[:3000])
