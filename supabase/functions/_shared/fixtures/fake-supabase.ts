// テスト専用: メモリ上の「にせの Supabase」（PostgREST の絞り込みのうち、keiei-api-* が使う分だけを再現する）。
// 本番コードからは読まれない。keiei-api-* の index.ts を、import map（keiei-test-import-map.json）で
//   npm:@supabase/supabase-js@2 → このファイル に差し替えて、本物のハンドラーを動かすために使う。
// 使い方: globalThis.__fakeDb = { tables, rpcs, auth } を、テストが設定する。
//   tables: { "stores": [...], "info.user_corporations": [...] }（public は表名だけ、info は "info." を付ける）
//   rpcs:   { 関数名: (args) => rows }
//   auth:   { トークン: ユーザー id }
//   failTables: 読むと error を返す表の名前の一覧（失敗時の動きの確認用）
// deno-lint-ignore-file no-explicit-any

type Row = Record<string, any>;
type Db = { tables: Record<string, Row[]>; rpcs: Record<string, (a: any) => Row[]>; auth: Record<string, string>; failTables?: string[]; log?: string[] };
const db = (): Db => (globalThis as any).__fakeDb;

function splitTop(s: string): string[] {
  const out: string[] = []; let depth = 0, cur = "";
  for (const ch of s) {
    if (ch === "(") depth++;
    if (ch === ")") depth--;
    if (ch === "," && depth === 0) { out.push(cur); cur = ""; } else cur += ch;
  }
  out.push(cur);
  return out;
}
function cmp(a: any, b: any): number {
  if (a === b) return 0;
  if (a === null || a === undefined) return 1;   // PostgREST の既定: 昇順で null は最後
  if (b === null || b === undefined) return -1;
  return a < b ? -1 : 1;
}
function matchOp(v: any, op: string, arg: string, neg = false): boolean {
  let r: boolean;
  if (op === "eq") r = v !== null && v !== undefined && String(v) === arg;
  else if (op === "in") r = splitTop(arg.replace(/^\(|\)$/g, "")).map((x) => x.replace(/^"|"$/g, "")).includes(String(v));
  else if (op === "ilike") { const re = new RegExp("^" + arg.replace(/[.*+?^${}()|[\]\\]/g, "\\$&").replace(/%/g, ".*") + "$", "i"); r = re.test(String(v ?? "")); }
  else throw new Error("fake: 未対応の演算子 " + op);
  return neg ? !r : r;
}

class Q {
  private filters: Array<(r: Row) => boolean> = [];
  private orders: Array<{ col: string; asc: boolean }> = [];
  private cols = "*"; private rng: [number, number] | null = null; private lim: number | null = null;
  private countMode = false; private single: "maybe" | "one" | null = null;
  constructor(private key: string, private rpc?: (a: any) => Row[], private rpcArgs?: any) {}
  select(cols = "*", opts?: { count?: string }) { this.cols = cols; this.countMode = opts?.count === "exact"; return this; }
  eq(c: string, v: any) { this.filters.push((r) => r[c] === v); return this; }
  neq(c: string, v: any) { this.filters.push((r) => r[c] !== v); return this; }
  in(c: string, vs: any[]) { this.filters.push((r) => vs.includes(r[c])); return this; }
  gte(c: string, v: any) { this.filters.push((r) => r[c] !== null && r[c] !== undefined && r[c] >= v); return this; }
  gt(c: string, v: any) { this.filters.push((r) => r[c] !== null && r[c] !== undefined && r[c] > v); return this; }
  lte(c: string, v: any) { this.filters.push((r) => r[c] !== null && r[c] !== undefined && r[c] <= v); return this; }
  lt(c: string, v: any) { this.filters.push((r) => r[c] !== null && r[c] !== undefined && r[c] < v); return this; }
  is(c: string, v: any) { this.filters.push((r) => (v === null ? r[c] === null || r[c] === undefined : r[c] === v)); return this; }
  not(c: string, op: string, v: any) {
    if (op === "is") this.filters.push((r) => !(v === null ? r[c] === null || r[c] === undefined : r[c] === v));
    else this.filters.push((r) => matchOp(r[c], op, String(v), true));
    return this;
  }
  ilike(c: string, p: string) { this.filters.push((r) => matchOp(r[c], "ilike", p)); return this; }
  or(spec: string) {
    const parts = splitTop(spec).map((p) => { const m = /^([a-z_]+)\.([a-z]+)\.(.*)$/.exec(p)!; return { c: m[1], op: m[2], a: m[3] }; });
    this.filters.push((r) => parts.some((p) => matchOp(r[p.c], p.op, p.a)));
    return this;
  }
  order(c: string, o?: { ascending?: boolean }) { this.orders.push({ col: c, asc: o?.ascending !== false }); return this; }
  range(a: number, b: number) { this.rng = [a, b]; return this; }
  limit(n: number) { this.lim = n; return this; }
  maybeSingle() { this.single = "maybe"; return this; }
  // deno-lint-ignore no-thenable
  then(res: (v: any) => any, rej?: (e: any) => any) { return Promise.resolve(this.exec()).then(res, rej); }
  private exec() {
    const d = db();
    d.log?.push(this.key);
    if (d.failTables?.includes(this.key)) return { data: null, error: { message: "fake failure " + this.key }, count: null };
    let rows: Row[] = this.rpc ? this.rpc(this.rpcArgs) : (d.tables[this.key] ?? []);
    for (const f of this.filters) rows = rows.filter(f);
    if (this.orders.length) rows = [...rows].sort((x, y) => { for (const o of this.orders) { const c = cmp(x[o.col], y[o.col]); if (c) return o.asc ? c : -c; } return 0; });
    const count = this.countMode ? rows.length : null;
    if (this.rng) rows = rows.slice(this.rng[0], this.rng[1] + 1);
    if (this.lim !== null) rows = rows.slice(0, this.lim);
    if (this.cols !== "*") {
      const names = this.cols.split(",").map((c) => c.trim()).filter(Boolean);
      rows = rows.map((r) => Object.fromEntries(names.map((n) => [n, r[n]])));
    }
    rows = rows.map((r) => ({ ...r }));
    if (this.single) {
      if (rows.length > 1) return { data: null, error: { message: "multiple rows" }, count };
      return { data: rows[0] ?? null, error: null, count };
    }
    return { data: rows, error: null, count };
  }
}

export function createClient(_url: string, _key: string) {
  const mk = (schema: string) => ({ from: (t: string) => new Q(schema === "public" ? t : `${schema}.${t}`) });
  return {
    ...mk("public"),
    schema: (s: string) => mk(s),
    rpc: (fn: string, args: any) => new Q("rpc:" + fn, (db().rpcs[fn] ?? (() => [])), args),
    auth: {
      getUser(jwt?: string) {
        const id = jwt ? db().auth[jwt] : undefined;
        return Promise.resolve(id ? { data: { user: { id } }, error: null } : { data: { user: null }, error: { message: "invalid JWT" } });
      },
    },
  };
}
