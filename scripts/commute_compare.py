#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""駅すぱあと評価版での「20〜30 人分の比較」（正式ルールを決めるための材料づくり。何も書き込まない）。
使い方: python3 scripts/commute_compare.py [人数=30] [--csv 出力先.csv]
  対象: 有効な従業員のうち 最寄り駅（employee_profiles.extra.最寄り駅）が入っていてスマレジに紐づいている人。
  やること（1 人ずつ）:
    ① EF commute-route を dry_run=true で呼ぶ（employee_commute には保存しない）→ 算出額・候補・仮判定・自動承認の可否
    ② EF smaregi-sync action=staff_get で、今スマレジに登録されている交通費（transportationCostApply）を読む
    ③ 並べて表にする（氏名は先頭 1 文字だけ・住所は扱わない）
  出力: 画面に表、--csv を付ければ CSV（リポジトリの外に置くこと。例: ~/Desktop/commute_compare.csv）。
  件数の目安: 1 人あたり駅すぱあと 3 リクエスト（駅 2＋経路 1）。30 人で約 90 リクエスト。
鍵: ~/.config/ns-portal/supabase_pat（PAT・DB 読み取り）と ~/.config/ns-portal/notify_slack_secret（EF の合言葉）。
"""
import csv, json, os, sys, urllib.request
N = int(next((a for a in sys.argv[1:] if a.isdigit()), '30'))
csv_path = sys.argv[sys.argv.index('--csv') + 1] if '--csv' in sys.argv else None
pat = open(os.path.expanduser('~/.config/ns-portal/supabase_pat')).read().strip()
secret = open(os.path.expanduser('~/.config/ns-portal/notify_slack_secret')).read().strip()
FN = 'https://uuvsxzhpxtghojoubjcc.supabase.co/functions/v1/'
def sql(q):
    req = urllib.request.Request('https://api.supabase.com/v1/projects/uuvsxzhpxtghojoubjcc/database/query', data=json.dumps({'query': q}).encode(), headers={'Authorization': 'Bearer ' + pat, 'Content-Type': 'application/json'})
    return json.loads(urllib.request.urlopen(req).read().decode())
def ef(name, body):
    req = urllib.request.Request(FN + name, data=json.dumps(body).encode(), headers={'Content-Type': 'application/json', 'x-notify-secret': secret})
    try: return json.loads(urllib.request.urlopen(req, timeout=90).read().decode())
    except urllib.error.HTTPError as e:
        try: return json.loads(e.read().decode())
        except Exception: return {'ok': False, 'error': f'HTTP {e.code}'}
people = sql(f"""
select p.user_id, left(u.name,1)||'***' as nm, u.role, p.extra->>'最寄り駅' as st, s.name as store, s.nearest_station, l.contract_id, l.smaregi_staff_id,
       (select claimed_oneway_fare from employee_commute c where c.user_id = p.user_id) as claimed
  from employee_profiles p join users u on u.id = p.user_id
  join user_stores us on us.user_id = p.user_id and us.is_primary join stores s on s.id = us.store_id
  join employee_smaregi_links l on l.user_id = p.user_id and l.effective_to is null
 where u.is_active and coalesce(p.extra->>'最寄り駅','') <> '' and s.nearest_station is not null
 order by u.created_at desc limit {N}""")
print(f'対象 {len(people)} 人（最寄り駅あり・スマレジ紐づけあり・店舗の最寄り駅あり）')
rows = []
for i, p in enumerate(people, 1):
    r = ef('commute-route', {'user_id': p['user_id'], 'dry_run': True})
    g = ef('smaregi-sync', {'action': 'staff_get', 'smaregi_staff_id': str(p['smaregi_staff_id']), 'contract_id': p['contract_id']})
    tc = (g.get('transportationCostApply') or []) if g.get('ok') else []
    cur = '／'.join(f"{ {'0':'回','1':'月','2':'日'}.get(str(t.get('division')), t.get('division')) }{t.get('transportationCost')}" + (f"(上限{t.get('transportationCostLimit')})" if t.get('transportationCostLimit') is not None else '') for t in tc) or ('未登録' if g.get('ok') else f"取得失敗:{g.get('error')}")
    comp = (r.get('computed') or {}).get('fare') if r.get('ok') else None
    row = {'no': i, 'name': p['nm'], 'role': p['role'], 'store': p['store'], 'home': p['st'], 'to': r.get('to') or p['nearest_station'], 'from_used': r.get('from'),
           'computed_oneway': comp, 'computed_round': (r.get('computed') or {}).get('round') if r.get('ok') else None, 'teiki1': (r.get('computed') or {}).get('teiki1') if r.get('ok') else None,
           'candidates': len(r.get('candidates') or []), 'judgement': r.get('judgement'), 'auto_eligible': (r.get('auto') or {}).get('eligible'), 'claimed': p['claimed'], 'smaregi_now': cur, 'error': r.get('error')}
    rows.append(row)
    print(f"{i:2d}. {row['name']} {row['role']:6s} {row['store']}: {row['home']}→{row['to']}  算出片道 {comp}  往復 {row['computed_round']}  定期1 {row['teiki1']}  判定 {row['judgement']}  スマレジ現在 {cur}" + (f"  ⚠️ {row['error']}" if row['error'] else ''))
if csv_path:
    with open(csv_path, 'w', newline='', encoding='utf-8-sig') as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()) if rows else ['no']); w.writeheader(); w.writerows(rows)
    print('CSV:', csv_path)
ok = [r for r in rows if r['computed_oneway'] is not None]
print(f"算出できた {len(ok)}/{len(rows)} 人。スマレジ登録値と比べて、往復＝算出片道×2 と一致する人数などは CSV で確認してください")
