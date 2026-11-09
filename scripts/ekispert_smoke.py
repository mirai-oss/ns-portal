#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""駅すぱあと API のキーが使えるかを確かめる（キーは DB から読み、画面に出さない）。
使い方: python3 scripts/ekispert_smoke.py [出発駅 到着駅]   （既定: 田町 新橋）
  やること: ① 駅名→駅コード（/station） ② 経路検索（/search/course/plain・bus=true） を 1 回ずつ呼ぶ（2 リクエスト）。
  出力: HTTP 状態・見つかった駅コード・経路の件数・最安の片道/往復・定期1か月・応答の項目名（Course/Route/Price の形）。
  ★ 応答の形（単数/配列・kind 名・Line.Type）が supabase/functions/_shared/commute-mock.ts の仮定と違えば、ここで分かる。
鍵: ~/.config/ns-portal/supabase_pat（PAT）で app_secrets.ekispert_key を読む。
"""
import json, os, sys, urllib.parse, urllib.request
pat = open(os.path.expanduser('~/.config/ns-portal/supabase_pat')).read().strip()
def sql(q):
    req = urllib.request.Request('https://api.supabase.com/v1/projects/uuvsxzhpxtghojoubjcc/database/query', data=json.dumps({'query': q}).encode(), headers={'Authorization': 'Bearer ' + pat, 'Content-Type': 'application/json'})
    return json.loads(urllib.request.urlopen(req).read().decode())
rows = sql("select value from app_secrets where key = 'ekispert_key'")
key = (rows[0]['value'] if rows else '') or ''
if not key.strip():
    print('app_secrets.ekispert_key が未設定です。先に python3 scripts/set_secret.py ekispert_key'); sys.exit(1)
key = key.strip()
frm, to = (sys.argv[1], sys.argv[2]) if len(sys.argv) >= 3 else ('田町', '新橋')
BASE = 'https://api.ekispert.jp/v1/json'
def call(path, params):
    u = BASE + path + '?' + urllib.parse.urlencode({**params, 'key': key})
    try:
        r = urllib.request.urlopen(urllib.request.Request(u, headers={'Accept': 'application/json'}), timeout=30)
        return r.status, json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        try: body = json.loads(e.read().decode())
        except Exception: body = None
        return e.code, body
arr = lambda x: [] if x is None else (x if isinstance(x, list) else [x])
def station(name):
    st, j = call('/station', {'name': name, 'type': 'train'})
    pts = arr((j or {}).get('ResultSet', {}).get('Point'))
    code = (pts[0].get('Station', {}).get('code') if pts else None)
    print(f"① 駅検索「{name}」: HTTP {st}・候補 {len(pts)} 件・先頭の駅コード {code}" + (f"・エラー {json.dumps((j or {}).get('ResultSet', {}).get('Error'), ensure_ascii=False)}" if (j or {}).get('ResultSet', {}).get('Error') else ''))
    return code
a, b = station(frm), station(to)
if not a or not b: print('駅コードが取れないため経路検索は省略'); sys.exit(2)
st, j = call('/search/course/plain', {'from': a, 'to': b, 'bus': 'true', 'answerCount': '6'})
rs = (j or {}).get('ResultSet', {})
courses = arr(rs.get('Course'))
print(f"② 経路検索 {frm}→{to}: HTTP {st}・経路 {len(courses)} 件" + (f"・エラー {json.dumps(rs.get('Error'), ensure_ascii=False)}" if rs.get('Error') else ''))
for i, c in enumerate(courses[:6]):
    route = c.get('Route', {}); prices = arr(c.get('Price'))
    kinds = [p.get('kind') for p in prices]
    fare = next((p for p in prices if p.get('kind') == 'FareSummary'), None) or next((p for p in prices if p.get('kind') == 'Fare'), None)
    teiki = next((p for p in prices if p.get('kind') in ('Teiki1Summary', 'Teiki1')), None)
    lines = [ (l.get('Name'), l.get('Type')) for l in arr(route.get('Line')) ]
    print(f"  {i+1}. 乗車{route.get('timeOnBoard')}分 徒歩{route.get('timeWalk')}分 他{route.get('timeOther')}分 乗換{route.get('transferCount')}／片道 {fare and fare.get('Oneway')} 往復 {fare and fare.get('Round')} 定期1 {teiki and teiki.get('Oneway')}／路線 {lines}／Price.kind {kinds}")
print('③ 形の確認: Course は', '配列' if isinstance(rs.get('Course'), list) else type(rs.get('Course')).__name__, '／ Route のキー', sorted(list((courses[0].get('Route', {}) if courses else {}).keys()))[:12])
