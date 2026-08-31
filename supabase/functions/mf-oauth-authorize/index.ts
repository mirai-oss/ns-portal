// マネーフォワード クラウド会計 OAuth連携「開始」用リンク（2026-08-31新規）
//
// 背景: これまで認可URル（https://api.biz.moneyforward.com/authorize?client_id=...&scope=...）は
// 誰かが手作業で組み立てて開いていた（client_id等をコード・ドキュメントに書かないため、
// 再認可のたびに管理者がMF_CLIENT_IDをどこかで確認して手打ちする必要があった）。
// このEndpointはMF_CLIENT_IDをサーバー側（Edge Functionのシークレット）から読んで
// 認可URLを組み立て、そのままMoneyForwardの認可画面へリダイレクトする。
// ＝ユーザーはこのURLをブラウザで開くだけでよい（client_idを一切見ない・扱わない）。
//
// 使い方:
//   /functions/v1/mf-oauth-authorize?tenant_id=default&label=有限会社トーホーエージェンシー
//   /functions/v1/mf-oauth-authorize?tenant_id=nstyle&label=株式会社N-Style
//   tenant_id省略時は'default'。既存の事業者を「再認可」する場合も同じtenant_idを指定すればよい
//   （mf-oauth-callback側がupsertするため、同じidの行が新しいトークン・scopeで上書きされる）
//
// スコープ: 既存で使っているもの（journal.write/voucher.write/accounts.read/report.read/journal.read）に
// 加えて、2026-08-31にユーザーから「会計入力の部門プルダウンに一部の部門が出ない」との報告を受けて
// departments.read を追加した。これまでGET /api/v3/departmentsが403（スコープ不足）だったため、
// 部門一覧は代わりに過去の仕訳履歴から実際に使われた部門をユニーク抽出して代用しており
// （mf-journal/index.tsのsuggest/list_journals/list_departments action）、まだ一度もMF側の仕訳で
// 使われたことのない部門（新規出店直後の店舗等）が候補に出てこないのが原因だった。
// departments.readが取得できれば、mf-journal側もGET /api/v3/departmentsを直接呼ぶ実装に切り替え、
// 全部門が確実に出るようにする（このEdge Functionでの再認可が済んでからの作業）。
//
// デプロイ: supabase functions deploy mf-oauth-authorize --no-verify-jwt
//   （ユーザーがブラウザで直接開くリンクのため。JWT検証はしない）

const AUTHORIZE_URL = "https://api.biz.moneyforward.com/authorize";
const REDIRECT_URI = "https://uuvsxzhpxtghojoubjcc.supabase.co/functions/v1/mf-oauth-callback";
const SCOPES = [
  "mfc/accounting/journal.write",
  "mfc/accounting/voucher.write",
  "mfc/accounting/accounts.read",
  "mfc/accounting/report.read",
  "mfc/accounting/journal.read",
  "mfc/accounting/departments.read", // 2026-08-31追加（部門一覧が一部欠けていた不具合の対応）
].join(" ");

const html = (body: string, status = 200) =>
  new Response(
    `<!doctype html><html lang="ja"><head><meta charset="utf-8"><title>MoneyForward連携</title>
    <style>body{font-family:-apple-system,sans-serif;background:#f4f1eb;color:#231f1a;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
    .box{background:#fff;border-radius:16px;padding:32px 40px;box-shadow:0 8px 24px rgba(0,0,0,.08);max-width:480px;text-align:center}
    h1{font-size:18px;margin:0 0 12px}p{font-size:14px;color:#5f574f;line-height:1.7}</style></head>
    <body><div class="box">${body}</div></body></html>`,
    { status, headers: { "Content-Type": "text/html; charset=utf-8" } },
  );

Deno.serve((req: Request) => {
  const url = new URL(req.url);
  const tenantId = url.searchParams.get("tenant_id") || "default";
  const label = url.searchParams.get("label") || tenantId;

  const clientId = Deno.env.get("MF_CLIENT_ID");
  if (!clientId) {
    return html(`<h1>⚠️ 設定未完了</h1><p>MF_CLIENT_IDがサーバー側に設定されていません。管理者に連絡してください。</p>`, 500);
  }

  const state = `tenant|${tenantId}|${encodeURIComponent(label)}`;
  const authorizeUrl = new URL(AUTHORIZE_URL);
  authorizeUrl.searchParams.set("client_id", clientId);
  authorizeUrl.searchParams.set("redirect_uri", REDIRECT_URI);
  authorizeUrl.searchParams.set("response_type", "code");
  authorizeUrl.searchParams.set("scope", SCOPES);
  authorizeUrl.searchParams.set("state", state);

  return Response.redirect(authorizeUrl.toString(), 302);
});
