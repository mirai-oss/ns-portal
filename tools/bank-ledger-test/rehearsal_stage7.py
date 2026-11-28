#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""閲覧専用権限（段階7）の実環境リハーサル: SQL を流し、実ユーザー（原・青山）に付与した状態で、読める範囲と書き込みの拒否を確かめ、必ず巻き戻す。"""
import json, os, re, sys, urllib.request, urllib.error
HERE = os.path.dirname(os.path.abspath(__file__))
S7 = open(os.path.join(HERE, '..', '..', 'supabase', '2026-11-28_bank_ledger_stage7_readonly.sql'), encoding='utf-8').read()
body = r"""
do $__r__$
declare s7 text := $__s7__$__S7__$__s7__$; u record; res jsonb := '[]'::jsonb; ceo uuid; tx uuid; a bigint; b bigint; d bigint; w jsonb; e text;
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  execute s7;
  select id into ceo from public.users where role = 'CEO' and is_active limit 1;
  select id into tx from public.bank_transactions where confirm_status = 'open' limit 1;
  insert into public.bank_ledger_global_users (user_id, granted_by, note) select id, ceo, 'リハーサル（巻き戻す）' from public.users where is_active and role = 'HQ' and (name like '原%美香' or name like '青山%');
  for u in select id, name, role, (select count(*) from public.bank_ledger_global_users g where g.user_id = users.id and g.revoked_at is null) granted from public.users where is_active and (role in ('CEO') or name like '原%美香' or name like '青山%' or name = '連携用') order by role, name loop
    perform set_config('request.jwt.claims', json_build_object('sub', u.id, 'role', 'authenticated')::text, true);
    set local role authenticated;
    select count(*) into a from public.bank_transactions; select count(*) into b from public.bank_accounts; select count(*) into d from public.bank_deposit_daily();
    w := '{}'::jsonb;
    begin perform public.bank_tx_correct(tx, '{"adj_description":"x"}'::jsonb, 'rehearsal'); w := w || '{"correct":"ALLOWED"}'; exception when others then w := w || jsonb_build_object('correct', case when sqlerrm like '%権限がありません%' then 'denied' else 'other:' || left(sqlerrm, 40) end); end;
    begin perform public.bank_tx_assign_store(array[tx], (select id from public.stores limit 1), 'rehearsal', true); w := w || '{"assign":"ALLOWED"}'; exception when others then w := w || jsonb_build_object('assign', case when sqlerrm like '%権限がありません%' then 'denied' else 'other' end); end;
    begin perform public.bank_ledger_global_set(u.id, true, 'rehearsal'); w := w || '{"grant":"ALLOWED"}'; exception when others then w := w || jsonb_build_object('grant', case when sqlerrm like '%権限がありません%' then 'denied' else 'other' end); end;
    begin perform public.store_corporation_change((select id from public.stores limit 1), (select id from public.corporations limit 1), date '2099-01-01', 'rehearsal'); w := w || '{"corp_change":"ALLOWED"}'; exception when others then w := w || jsonb_build_object('corp_change', case when sqlerrm like '%権限がありません%' then 'denied' else 'other' end); end;
    reset role;
    res := res || jsonb_build_object('name_initial', left(u.name, 1), 'role', u.role, 'granted', u.granted, 'tx', a, 'accts', b, 'daily', d, 'writes', w);
  end loop;
  raise exception '#S7#%', res::text;
end $__r__$;
"""
body = body.replace('__S7__', S7); assert '$__s7__$' not in S7
pat = open(os.path.expanduser('~/.config/ns-portal/supabase_pat')).read().strip()
req = urllib.request.Request('https://api.supabase.com/v1/projects/uuvsxzhpxtghojoubjcc/database/query', data=json.dumps({'query': body}).encode(), headers={'Authorization': 'Bearer ' + pat, 'Content-Type': 'application/json', 'User-Agent': 'curl/8'})
try: urllib.request.urlopen(req, timeout=300).read(); print('想定外'); sys.exit(2)
except urllib.error.HTTPError as e: raw = e.read().decode()
msg = json.loads(raw).get('message', raw); m = re.search(r'#S7#(\[.*\])', msg, re.S)
if not m: print(msg[:1500]); sys.exit(1)
for x in json.loads(m.group(1)): print(x)
