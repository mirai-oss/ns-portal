// マネーフォワード クラウド会計 OAuth連携コールバック（2026-08-27新規）
//
// 役割: MoneyForwardの認可画面（https://api.biz.moneyforward.com/authorize）で
// ユーザーが「許可する」を押した後、ブラウザがこのURLへリダイレクトされてくる。
// ここで受け取った認可コード(code)をアクセストークン・リフレッシュトークンに交換し、
// mf_oauth_tokens テーブル（id='default'の1行のみ・service_roleしか読めない）へ保存する。
//
// これは「一度だけ手動で開く」画面。以後のトークン更新（リフレッシュ）は
// 各消費側Edge Function（mf-pl-sync・mf-journal-create等、今後追加予定）が
// _shared/mf.ts の getValidAccessToken() 経由で自動的に行う。
//
// 必要な環境変数: MF_CLIENT_ID・MF_CLIENT_SECRET（Supabase Edge Functionのシークレットのみ。
//   コード・リポジトリには一切書かない＝INVOICE_INTAKE_SECRET等と同じ方針）
//
// デプロイ: supabase functions deploy mf-oauth-callback --no-verify-jwt
//   （MoneyForwardからの素のブラウザリダイレクトを受けるため。JWT検証はしない代わりに
//    codeは1回しか使えずMF側が発行者を保証するので安全）
import { createClient } from "npm:@supabase/supabase-js@2";

const TOKEN_URL = "https://api.biz.moneyforward.com/token";

const html = (body: string, status = 200) =>
  new Response(
    `<!doctype html><html lang="ja"><head><meta charset="utf-8"><title>MoneyForward連携</title>
    <style>body{font-family:-apple-system,sans-serif;background:#f4f1eb;color:#231f1a;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
    .box{background:#fff;border-radius:16px;padding:32px 40px;box-shadow:0 8px 24px rgba(0,0,0,.08);max-width:480px;text-align:center}
    h1{font-size:18px;margin:0 0 12px}p{font-size:14px;color:#5f574f;line-height:1.7}</style></head>
    <body><div class="box">${body}</div></body></html>`,
    { status, headers: { "Content-Type": "text/html; charset=utf-8" } },
  );

const svc = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

Deno.serve(async (req: Request) => {
  const url = new URL(req.url);
  const code = url.searchParams.get("code");
  const err = url.searchParams.get("error");

  if (err) {
    return html(`<h1>❌ 連携が許可されませんでした</h1><p>MoneyForward側の応答: ${err}</p>`, 400);
  }
  if (!code) {
    return html(`<h1>⚠️ 認可コードがありません</h1><p>MoneyForwardの認可画面から遷移してきたURLではない可能性があります。</p>`, 400);
  }

  const clientId = Deno.env.get("MF_CLIENT_ID");
  const clientSecret = Deno.env.get("MF_CLIENT_SECRET");
  // MFアプリポータルに登録したリダイレクトURIと1文字違わず一致させる必要がある（動的生成せず固定値）
  const redirectUri = "https://uuvsxzhpxtghojoubjcc.supabase.co/functions/v1/mf-oauth-callback";
  if (!clientId || !clientSecret) {
    return html(`<h1>⚠️ 設定未完了</h1><p>MF_CLIENT_ID / MF_CLIENT_SECRETがサーバー側に設定されていません。管理者に連絡してください。</p>`, 500);
  }

  try {
    const basic = btoa(`${clientId}:${clientSecret}`);
    const tokenRes = await fetch(TOKEN_URL, {
      method: "POST",
      headers: {
        Authorization: `Basic ${basic}`,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: new URLSearchParams({
        grant_type: "authorization_code",
        code,
        redirect_uri: redirectUri,
      }),
    });
    const tokenText = await tokenRes.text();
    if (!tokenRes.ok) {
      return html(`<h1>❌ トークン取得に失敗しました</h1><p>MoneyForward応答(${tokenRes.status}): ${esc(tokenText)}</p>`, 502);
    }
    const tok = JSON.parse(tokenText) as {
      access_token: string; refresh_token: string; scope?: string; token_type?: string; expires_in: number;
    };

    const db = svc();
    const expiresAt = new Date(Date.now() + tok.expires_in * 1000).toISOString();
    const { error: upErr } = await db.from("mf_oauth_tokens").upsert({
      id: "default",
      access_token: tok.access_token,
      refresh_token: tok.refresh_token,
      scope: tok.scope ?? null,
      token_type: tok.token_type ?? "Bearer",
      expires_at: expiresAt,
      updated_at: new Date().toISOString(),
    });
    if (upErr) {
      return html(`<h1>❌ 保存に失敗しました</h1><p>${esc(upErr.message)}</p>`, 500);
    }

    await db.from("mf_sync_logs").insert({
      action: "oauth_connected",
      actor_type: "human",
      detail: { scope: tok.scope ?? null },
    });

    return html(`<h1>✅ マネーフォワードとの連携が完了しました</h1><p>このタブは閉じて大丈夫です。<br>今後1時間ごとの自動更新（リフレッシュ）も裏側で行われます。</p>`);
  } catch (e) {
    return html(`<h1>❌ エラーが発生しました</h1><p>${esc(String(e))}</p>`, 500);
  }
});

function esc(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
