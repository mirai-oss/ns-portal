#!/usr/bin/env python3
"""スマレジの交通費（事業所別を含む）を読み取って、管理システムと照合する（読み取り専用）。
  python3 scripts/commute_pull.py            … 照合して件数だけ表示（何も記録しない）
  python3 scripts/commute_pull.py --apply    … 違いを commute_external_changes に「未承認」で記録（正式な設定は変えない）
  --user 氏名 … 1人だけ
スマレジへは GET（staff_get）しか送らない。金額は画面に出さず、件数と人数だけ表示する。"""
import sys, json, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'tools', 'dev'))
import sqlh

DIV = {'0': 'per_shift', '1': 'monthly', '2': 'per_day'}
apply = '--apply' in sys.argv
only = sys.argv[sys.argv.index('--user') + 1] if '--user' in sys.argv else None

contracts = {r['contract_id']: r['corporation_id'] for r in sqlh.sql("select contract_id, corporation_id from smaregi_contracts where is_active")}
stores = sqlh.sql("select id, smaregi_store_id, corporation_id from stores where smaregi_store_id is not null")
def store_uuid(contract, sid):
    corp = contracts.get(contract)
    c = [s for s in stores if str(s['smaregi_store_id']) == str(sid) and (corp is None or s['corporation_id'] == corp)]
    return c[0]['id'] if len(c) == 1 else None

q = "select l.user_id, l.contract_id, l.smaregi_staff_id, u.name from employee_smaregi_links l join users u on u.id=l.user_id where l.effective_to is null and u.is_active"
if only: q += " and u.name = '%s'" % only.replace("'", "''")
links = sqlh.sql(q)
sysrows = sqlh.sql("select id, user_id, contract_id, pay_type, effective_date, scope, amount, store_amounts, cap_amount from employee_commute_settings")

items, checked, errors, unmapped = [], [], 0, 0
for L in links:
    out = sqlh.ef('smaregi-sync', {'action': 'staff_get', 'smaregi_staff_id': str(L['smaregi_staff_id']), 'contract_id': L['contract_id']}, timeout=60)
    if not out.get('ok'): errors += 1; continue
    checked.append(L['user_id'])
    groups = {}
    for t in (out.get('transportationCostApply') or []):
        cost = int(float(t.get('transportationCost') or 0)); lim = t.get('transportationCostLimit'); limS = t.get('transportationCostLimitByStore')
        eff = str(t.get('effectiveDate') or '')[:10]
        if cost <= 0 and lim is None and eff.startswith('1970'): continue      # 未設定の初期行
        g = groups.setdefault((eff[:7], DIV.get(str(t.get('division')), 'per_day')), {'eff': eff, 'all': None, 'stores': {}, 'caps': []})
        if lim is not None: g['caps'].append(int(lim))
        if limS is not None: g['caps'].append(int(limS))
        if str(t.get('storeId') or '') == '': g['all'] = cost
        else:
            u = store_uuid(L['contract_id'], t['storeId'])
            if u is None: unmapped += 1
            else: g['stores'][u] = cost
    mine = [r for r in sysrows if r['user_id'] == L['user_id'] and r['contract_id'] == L['contract_id']]
    for (ym, pt), g in groups.items():
        scope = 'per_store' if g['stores'] else 'all'
        amount = None if scope == 'per_store' else g['all']
        cap = max(g['caps']) if g['caps'] else None
        row = next((r for r in mine if str(r['effective_date'])[:7] == ym and r['pay_type'] == pt), None)
        if row and row['scope'] == scope and row['amount'] == amount and (row['store_amounts'] or None) == (g['stores'] or None) and (row['cap_amount'] is None or row['cap_amount'] == cap):
            continue
        items.append({'user_id': L['user_id'], 'contract_id': L['contract_id'], 'effective_date': g['eff'], 'pay_type': pt, 'scope': scope, 'amount': amount,
                      'store_amounts': g['stores'] or None, 'cap_amount': cap, 'kind': 'changed' if row else 'new_row', 'system_id': row['id'] if row else None,
                      'smaregi_value': {'effective_date': g['eff'], 'pay_type': pt}})
print('照合した人: %d人 / 読み取り失敗: %d人 / 事業所が対応づかない行: %d' % (len(checked), errors, unmapped))
print('違い: %d件（追加 %d・違う %d）／対象 %d人' % (len(items), sum(i['kind'] == 'new_row' for i in items), sum(i['kind'] == 'changed' for i in items), len({i['user_id'] for i in items})))
if apply:
    esc = lambda s: s.replace("'", "''")
    r = sqlh.sql("select set_config('request.jwt.claims','{\"role\":\"service_role\"}',true); select hr_commute_external_record('%s'::jsonb, array[%s]::uuid[]) r" % (esc(json.dumps(items, ensure_ascii=False)), ','.join("'%s'" % c for c in checked)))
    print('記録:', r)
