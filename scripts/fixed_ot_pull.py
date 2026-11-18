#!/usr/bin/env python3
"""スマレジの月給の行の固定残業代（読み取り）を、管理システムの月給の行（まだ unknown のもの）の基準として取り込む。
  python3 scripts/fixed_ot_pull.py          … 照合して件数だけ表示（何も書かない）
  python3 scripts/fixed_ot_pull.py --apply  … hr_fixed_ot_import で取り込む（社長の指示があってから。スマレジへは何も送らない）
スマレジへは wage_fixed_probe（GET のみ）。氏名・金額は表示しない。"""
import sys, json, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'tools', 'dev'))
import sqlh
CEO = os.environ.get('NS_ACTOR_ID', '')
apply = '--apply' in sys.argv
out = sqlh.ef('smaregi-sync', {'action': 'wage_fixed_probe', 'contract_id': 'sez093z1'}, timeout=120)
if not out.get('ok'): sys.exit('読み取りに失敗しました')
rows = sqlh.sql("select id, user_id, effective_date, fixed_ot_state from employee_wage_settings where division=2 and contract_id='sez093z1'")
items, skipped, same = [], 0, 0
for p in out['people']:
    mine = [r for r in rows if str(r['user_id']).startswith(p['u'])]
    for m in p.get('monthly', []):
        r = next((x for x in mine if str(x['effective_date'])[:7] == m['effectiveDate'][:7]), None)
        if not r: skipped += 1; continue
        if r['fixed_ot_state'] != 'unknown': same += 1; continue
        flag = str(m.get('fixedOvertimeWageFlag')) == '1'
        amt = int(float(m.get('fixedOvertimeWage') or 0))
        if flag and amt < 1: skipped += 1; continue
        items.append({'wage_id': r['id'], 'state': 'applied' if flag else 'none', 'amount': amt if flag else None})
print('スマレジの月給の行: %d人 / 取り込める: %d行（あり %d・なし %d）/ 対応する行が無い・金額が読めない: %d / すでに設定済み: %d' % (
    len(out['people']), len(items), sum(i['state'] == 'applied' for i in items), sum(i['state'] == 'none' for i in items), skipped, same))
if apply:
    if not CEO: sys.exit('NS_ACTOR_ID（操作者の users.id）を環境変数で渡してください')
    esc = lambda s: s.replace("'", "''")
    print(sqlh.sql("select set_config('request.jwt.claims','{\"role\":\"service_role\"}',true); select hr_fixed_ot_import('%s'::jsonb, '%s'::uuid) r" % (esc(json.dumps(items)), CEO)))
