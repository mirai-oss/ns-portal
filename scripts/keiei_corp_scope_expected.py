#!/usr/bin/env python3
"""経営ダッシュボード系 Edge Function の「法人の限定」の期待件数を、本番 DB の SELECT だけで出す（デプロイ後の確認用・2026-11-28）。

使える利用者（社長・本部・チーム長・店長）ごとに、_shared/corp-scope.ts と同じ判定
  （マスター=制限なし／個人の許可 info.user_corporations／無ければ役職の許可 info.role_corporations／無ければ制限なし）で
  「見てよい法人・店舗」を求め、指定した月の各表の期待件数を出す。実際の API の返り値の件数と見比べる（一致すれば OK）。
書き込みはしない（supabase CLI の `db query --read-only`。SELECT のみ）。氏名・メール・金額は出さない（利用者は id の先頭 8 文字だけ）。
使い方: python3 scripts/keiei_corp_scope_expected.py 2026-11 [2026-11-27]   # 年月, （ホームの有効店舗数を出すなら任意の日付）
前提: `supabase` CLI にログイン済み（npx supabase でも可）。プロジェクトは uuvsxzhpxtghojoubjcc。
列の意味: pl/media/deposit/store = keiei-api-dashboard-summary の kind 別の行数（limit 未指定なら最大500）、
          rsv日次 = kd_reservation_daily_summary の月の行数（keiei-api-reservation の monthly_summary が返す店舗数×日数の元）、
          home店舗 = keiei-api-home が返す店舗数（有効な店舗）。
"""
import json, subprocess, sys

REF = "uuvsxzhpxtghojoubjcc"


def q(sql):
    out = subprocess.run(["npx", "--no-install", "supabase", "db", "query", f"--remote={REF}", "--read-only", "--output-format", "json", sql],
                         capture_output=True, text=True)
    i = out.stdout.find("{")
    if i < 0:
        sys.exit("SQL の実行に失敗しました（CLI にログインしていますか）: " + (out.stderr or out.stdout)[:300])
    return json.loads(out.stdout[i:])["rows"]


def main():
    if len(sys.argv) < 2 or not sys.argv[1][:4].isdigit() or len(sys.argv[1]) != 7:
        sys.exit(__doc__)
    ym = sys.argv[1]
    users = q("select id, role, is_master from public.users where is_active and (is_master or role in ('CEO','HQ','TEAM','TENCHO')) order by role, id")
    uc = q("select user_id, corporation_id from info.user_corporations")
    prof = q("select id, role_id, is_active from info.profiles")
    rc = q("select role_id, corporation_id from info.role_corporations")
    corps = q("select id, legacy_info_id from public.corporations")
    stores = q("select id, corporation_id, is_active from public.stores")
    us = q("select user_id, store_id from public.user_stores")
    tabs = {}
    for t in ["kd_pl_monthly_summary", "kd_media_monthly_summary", "kd_deposit_monthly_summary", "kd_store_monthly_summary"]:
        tabs[t] = q(f"select store_id, corporation_id, count(*)::int n from public.{t} where year_month = '{ym}' group by 1,2")
    rsv = q(f"select store_id, count(*)::int n from public.kd_reservation_daily_summary where to_char(period_date,'YYYY-MM') = '{ym}' group by 1")

    def allowed_corps(u):
        """None=制限なし／list=その法人だけ（public.corporations.id）"""
        if u["is_master"]:
            return None
        mine = [r["corporation_id"] for r in uc if r["user_id"] == u["id"]]
        if not mine:
            p = next((p for p in prof if p["id"] == u["id"] and p["is_active"] and p["role_id"]), None)
            if p:
                mine = [r["corporation_id"] for r in rc if r["role_id"] == p["role_id"]]
        if not mine:
            return None
        return [c["id"] for c in corps if c["legacy_info_id"] in mine]

    print(f"年月={ym}（件数だけ。利用者は id の先頭 8 文字。role の * はマスター）")
    print("%-9s %-7s %-8s %-4s %-5s | %5s %6s %7s %5s %7s %8s" % ("user", "role", "制限", "法人", "店舗", "pl", "media", "deposit", "store", "rsv日次", "home店舗"))
    for u in users:
        ac = allowed_corps(u)
        role_stores = None
        if not u["is_master"] and u["role"] == "TENCHO":
            role_stores = {r["store_id"] for r in us if r["user_id"] == u["id"]}
        corp_stores = None if ac is None else {s["id"] for s in stores if s["corporation_id"] in ac}
        sset = corp_stores if role_stores is None else (role_stores if corp_stores is None else role_stores & corp_stores)

        def visible(rows):
            n = 0
            for r in rows:
                if role_stores is not None and r["store_id"] not in role_stores:
                    continue                       # 店長: 担当店だけ（全社共通行も出ない）
                if ac is not None and r["corporation_id"] not in ac:
                    continue                       # 法人の限定: 法人の列で絞る（法人が空の行は出ない）
                n += r["n"]
            return n
        cols = [visible(tabs[t]) for t in tabs]
        r_n = sum(r["n"] for r in rsv if sset is None or r["store_id"] in sset)
        home = sum(1 for s in stores if s["is_active"] and (sset is None or s["id"] in sset))
        kind = "なし" if ac is None and role_stores is None else ("法人" if role_stores is None else ("店舗" if ac is None else "法人+店舗"))
        print("%-9s %-7s %-8s %-4s %-5s | %5s %6s %7s %5s %7s %8s" % (
            u["id"][:8], u["role"] + ("*" if u["is_master"] else ""), kind,
            "全" if ac is None else len(ac), "全" if sset is None else len(sset), *cols, r_n, home))


main()
