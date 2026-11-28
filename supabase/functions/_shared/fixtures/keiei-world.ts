// テスト専用: 3 法人・4 店舗・各種ユーザーの「にせの世界」（実在の名前・id・金額ではない）。
// deno-lint-ignore-file no-explicit-any

// 法人（public.corporations.id と info の legacy id）
export const CORP_A = "pub-corp-A", CORP_B = "pub-corp-B", CORP_Z = "pub-corp-Z";
export const INFO_A = "info-corp-A", INFO_B = "info-corp-B", INFO_GHOST = "info-corp-ghost"; // GHOST: public 側に対応する法人が無い
// 店舗
export const A1 = "store-A1", A2 = "store-A2", B1 = "store-B1", Z1 = "store-Z1";

export const TOKENS: Record<string, string> = {
  "t.master.sig": "u-master",            // マスター（個人の許可があっても制限なし）
  "t.ceo.sig": "u-ceo",                  // 社長（役職 CEO・許可なし）
  "t.hqfree.sig": "u-hq-free",           // 本部・許可なし → 制限なし
  "t.hqA.sig": "u-hq-A",                 // 本部・個人の許可 = 法人 A
  "t.teamroleB.sig": "u-team-roleB",     // チーム長・個人の許可なし・役職の許可 = 法人 B
  "t.teamghost.sig": "u-team-ghost",     // チーム長・個人の許可 = public に無い法人 → 何も見えない
  "t.teaminactive.sig": "u-team-inactive", // チーム長・役職の許可はあるが profile が無効 → 制限なし（DB の判定と同じ）
  "t.teamucOverRole.sig": "u-team-ucOverRole", // チーム長・個人の許可 = A と、役職の許可 = B（個人が優先 → A だけ）
  "t.tenchoA.sig": "u-tencho-A",         // 店長・担当店 A1,B1・個人の許可 = A → A1 だけ
  "t.tenchoplain.sig": "u-tencho-plain", // 店長・担当店 A1・許可なし → A1（従来どおり）
  "t.staff.sig": "u-staff",              // 権限なし（役職 STAFF）
};
export const SERVICE_KEY = "svc.test.key";

export function makeTables(): Record<string, any[]> {
  const ym = ["2026-10", "2026-11"];
  const stores = [
    { id: A1, name: "A一号店", dash_store_name: "A1", sort_order: 1, is_active: true, corporation_id: CORP_A },
    { id: A2, name: "A二号店", dash_store_name: "A2", sort_order: 2, is_active: false, corporation_id: CORP_A },   // 閉店済み
    { id: B1, name: "B一号店", dash_store_name: "B1", sort_order: 3, is_active: true, corporation_id: CORP_B },
    { id: Z1, name: "Z一号店", dash_store_name: "Z1", sort_order: 4, is_active: true, corporation_id: CORP_Z },
  ];
  const corpOf = (s: string) => stores.find((x) => x.id === s)!.corporation_id;
  const perStoreMonth = (extra: (s: string, m: string) => any) =>
    stores.flatMap((s) => ym.map((m) => ({ store_id: s.id, corporation_id: s.corporation_id, year_month: m, computed_at: "2026-11-28T00:00:00Z", ...extra(s.id, m) })));
  const perStoreDay = (extra: (s: string, d: string) => any) =>
    stores.flatMap((s) => ["2026-11-01", "2026-11-02"].map((d) => ({ store_id: s.id, ...extra(s.id, d) })));
  return {
    users: [
      { id: "u-master", role: "HQ", is_master: true, is_active: true },
      { id: "u-ceo", role: "CEO", is_master: false, is_active: true },
      { id: "u-hq-free", role: "HQ", is_master: false, is_active: true },
      { id: "u-hq-A", role: "HQ", is_master: false, is_active: true },
      { id: "u-team-roleB", role: "TEAM", is_master: false, is_active: true },
      { id: "u-team-ghost", role: "TEAM", is_master: false, is_active: true },
      { id: "u-team-inactive", role: "TEAM", is_master: false, is_active: true },
      { id: "u-team-ucOverRole", role: "TEAM", is_master: false, is_active: true },
      { id: "u-tencho-A", role: "TENCHO", is_master: false, is_active: true },
      { id: "u-tencho-plain", role: "TENCHO", is_master: false, is_active: true },
      { id: "u-staff", role: "STAFF", is_master: false, is_active: true },
    ],
    user_stores: [
      { user_id: "u-tencho-A", store_id: A1 }, { user_id: "u-tencho-A", store_id: B1 },
      { user_id: "u-tencho-plain", store_id: A1 },
    ],
    stores,
    corporations: [
      { id: CORP_A, legacy_info_id: INFO_A }, { id: CORP_B, legacy_info_id: INFO_B }, { id: CORP_Z, legacy_info_id: "info-corp-Z" },
    ],
    "info.user_corporations": [
      { user_id: "u-master", corporation_id: INFO_A },
      { user_id: "u-hq-A", corporation_id: INFO_A },
      { user_id: "u-team-ghost", corporation_id: INFO_GHOST },
      { user_id: "u-team-ucOverRole", corporation_id: INFO_A },
      { user_id: "u-tencho-A", corporation_id: INFO_A },
    ],
    "info.profiles": [
      { id: "u-team-roleB", role_id: "role-1", is_active: true },
      { id: "u-team-inactive", role_id: "role-1", is_active: false },
      { id: "u-team-ucOverRole", role_id: "role-1", is_active: true },
      { id: "u-hq-free", role_id: "role-free", is_active: true },       // この役職には許可の設定が無い
    ],
    "info.role_corporations": [{ role_id: "role-1", corporation_id: INFO_B }],

    // ---- kd_* ----
    kd_pl_monthly_summary: [
      ...perStoreMonth((s, m) => ({ sales: 1000, cost_total: 300, id: `pl-${s}-${m}` })),
      { store_id: null, corporation_id: null, year_month: "2026-11", sales: 0, cost_total: 50, id: "pl-common", computed_at: "2026-11-28T00:00:00Z" },   // 全社共通経費
    ],
    kd_media_monthly_summary: [
      ...perStoreMonth((s, m) => ({ media_name: "食べログ", net_sales: 100 })),
      ...perStoreMonth((s, m) => ({ media_name: "ホットペッパー", net_sales: 200 })),
    ],
    kd_deposit_monthly_summary: perStoreMonth(() => ({ deposit_total: 500, deposit_count: 5 })),
    kd_store_monthly_summary: perStoreMonth(() => ({ sales: 900 })),
    kd_daily_store_full: stores.flatMap((s) => ["2026-11-01", "2026-11-02"].map((d) => ({ store_id: s.id, corporation_id: s.corporation_id, date: d, net_sales: 10 }))),
    kd_deposit_daily_v: perStoreDay((s, d) => ({ date: d, cash_sales: 1, deposit_amount: 1 })),
    kd_deposit_carry_v: perStoreMonth(() => ({ carry: 0 })).map(({ corporation_id, ...r }: any) => r),
    kd_ad_monthly: perStoreMonth(() => ({ media_name: "広告X", brand_name: "b", ad_cost: 10 })).map((r: any, i: number) => ({ ...r, id: `ad-${i}` })),
    kd_target_monthly_v: perStoreMonth(() => ({ ym: "x", sales_target: 1 })).map(({ corporation_id, ...r }: any) => r),
    dash_sales_target_daily: perStoreDay((s, d) => ({ biz_date: d, sales_target: 5 })),
    kd_delivery_daily: perStoreDay((s, d) => ({ biz_date: d, channel: "ubr", orders: 1, net_sales: 1080 })).map((r: any, i: number) => ({ ...r, id: `dv-${i}` })),
    kd_media_daily: perStoreDay((s, d) => ({ biz_date: d, media_raw: "r", media_name: "m", net_sales: 1 })).map((r: any, i: number) => ({ ...r, id: `md-${i}` })),
    kd_pl_entries: [
      ...perStoreMonth(() => ({ item: "家賃", amount: 1, store_name: "x" })).map(({ corporation_id, ...r }: any, i: number) => ({ ...r, id: `pe-${i}` })),
      { id: "pe-common", year_month: "2026-11", store_id: null, store_name: "", item: "全社共通", amount: 9 },
    ],
    kd_spot_entries: perStoreDay((s, d) => ({ work_date: d, kind: "k", amount: 1, store_name: "x" })).map((r: any, i: number) => ({ ...r, id: `sp-${i}` })),
    kd_loan_entries: [
      ...perStoreMonth(() => ({ principal: 1, store_name: "x" })).map(({ corporation_id, ...r }: any, i: number) => ({ ...r, id: `ln-${i}` })),
      { id: "ln-common", year_month: "2026-11", store_id: null, store_name: "", principal: 7 },
    ],
    kd_detail_item_daily: [{ logic_ver: "v1", computed_at: "2026-11-28T00:00:00Z" }],

    // ---- home ----
    kd_home_kpi_snapshot: stores.map((s) => ({ store_id: s.id, period_date: "2026-11-28", data_date: "2026-11-27", today_sales: 100, today_guests: 10, today_parties: 5, mtd_sales: 2000, budget_achievement_rate: 1, daily_report_submission_rate: 1, checklist_completion_rate: 1, hq_task_overdue_count: 1, source_updated_at: null, computed_at: "2026-11-28T00:00:00Z" })),
    kd_dashboard_daily_summary: stores.flatMap((s) => ["2026-11-27"].map((d) => ({ store_id: s.id, period_date: d, net_sales: 100, guests: 10, parties: 5, avg_check: 10, prior_year_same_weekday_sales: 50, prior_year_same_weekday_ratio: 2, cost: 30, labor: 20 }))),
    kd_reservation_daily_summary: stores.flatMap((s) => ["2026-11-27", "2026-11-28"].map((d) => ({ store_id: s.id, corporation_id: s.corporation_id, period_date: d, reservation_count: 3, party_size_sum: 9, same_day_count: 1, same_day_party: 2, walkin_count: 0, walkin_party: 0, expected_sales: 100, cancel_breakdown: { noshow: { count: 1, party: 2 } }, channel_breakdown: { web: { count: 2, party: 4 } } }))),
    pl_entries: [],
    dash_sales_daily: [],
    dash_target_monthly: [],
    rsv_reservations: stores.flatMap((s) => [1, 2].map((i) => ({ reservation_key: `${s.id}-${i}`, store_id: s.id, source: "dinii", store_account: "acc", visit_date: "2026-11-28", visit_time: `1${i}:00`, party_size: 2, status_normalized: "confirmed", customer_name: "客" }))),
  };
}
export const corpOf = (store: string) => makeTables().stores.find((s: any) => s.id === store)!.corporation_id as string;
