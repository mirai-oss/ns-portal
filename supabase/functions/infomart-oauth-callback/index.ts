// インフォマート BtoBプラットフォーム受発注API OAuth連携コールバック（2026-08-31新規・D-9）
//
// 役割: インフォマートの認証ページ（https://auth.infomart.co.jp/openam/oauth2/authorize?realm=/api）で
// PFID（インフォマートプラットフォームID）のログインが完了した後、ブラウザがこのURLへリダイレクトされてくる。
// ここで受け取った許可コード(code)をアクセストークン・リフレッシュトークンに交換し、
// infomart_oauth_tokens テーブル（service_roleしか読めない）へ保存する。
//
// 仕様の出典: 「外部システム連携API仕様書 認証・認可機能」（株式会社インフォマート・2023/04/26）。
// mf-oauth-callback（マネーフォワード連携）と同じ設計方針だが、以下がMFと異なる点:
//   - トークンエンドポイントへの認証はBasic認証ヘッダーではなく、client_id/client_secretを
//     フォームパラメータとして送る（インフォマート仕様書どおり）
//   - access_tokenの有効期限は5分（300秒）と非常に短い。refresh_tokenの有効期限は31日。
//     以後の消費側Edge Function（未実装・stg_infomart_order取込時に作る）は毎回に近い頻度で
//     refresh_tokenによる再発行が必要になる見込み
//   - インフォマートは複数事業者(tenant)の概念が無い（1社の受発注API利用）ため、
//     MFのようなstateパラメータでのtenant振り分けは行わず、常にid='default'の1行のみを扱う
//
// 必要な環境変数: INFOMART_CLIENT_ID・INFOMART_CLIENT_SECRET（Supabase Edge Functionのシークレットのみ。
//   API利用申込み完了後にインフォマートから発行された値を登録する。まだ未登録でもデプロイ自体は可能
//   ＝「設定未完了」画面を返すだけで、フォーム申込み時点でCallBackURLとして提示するには支障ない）
//
// デプロイ: supabase functions deploy infomart-oauth-callback --no-verify-jwt
//   （インフォマートからの素のブラウザリダイレクトを受けるため。JWT検証はしない代わりに
//    codeは1回しか使えず・有効期限120秒とインフォマート側が発行者を保証するので安全）
import { createClient } from "npm:@supabase/supabase-js@2";

const TOKEN_URL = "https://auth.infomart.co.jp/openam/oauth2/access_token?realm=/api";
const REDIRECT_URI = "https://uuvsxzhpxtghojoubjcc.supabase.co/functions/v1/infomart-oauth-callback";

const html = (body: string, status = 200) =>
  new Response(
    `<!doctype html><html lang="ja"><head><meta charset="utf-8"><title>インフォマート連携</title>
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
    return html(`<h1>❌ 連携が許可されませんでした</h1><p>インフォマート側の応答: ${esc(err)}</p>`, 400);
  }
  if (!code) {
    return html(`<h1>⚠️ 許可コードがありません</h1><p>インフォマートの認証ページから遷移してきたURLではない可能性があります。</p>`, 400);
  }

  const clientId = Deno.env.get("INFOMART_CLIENT_ID");
  const clientSecret = Deno.env.get("INFOMART_CLIENT_SECRET");
  if (!clientId || !clientSecret) {
    return html(`<h1>⚠️ 設定未完了</h1><p>INFOMART_CLIENT_ID / INFOMART_CLIENT_SECRETがサーバー側に設定されていません。インフォマートからAPI利用申込みの認証情報（クライアントID・シークレット）を受領後、管理者が登録してください。</p>`, 500);
  }

  try {
    // インフォマート仕様: Basic認証ヘッダーではなく、client_id/client_secretをフォームパラメータで送る
    const tokenRes = await fetch(TOKEN_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "authorization_code",
        code,
        redirect_uri: REDIRECT_URI,
        client_id: clientId,
        client_secret: clientSecret,
      }),
    });
    const tokenText = await tokenRes.text();
    if (!tokenRes.ok) {
      return html(`<h1>❌ トークン取得に失敗しました</h1><p>インフォマート応答(${tokenRes.status}): ${esc(tokenText)}</p>`, 502);
    }
    const tok = JSON.parse(tokenText) as {
      access_token: string; refresh_token: string; scope?: string; token_type?: string; expires_in: number;
    };

    const db = svc();
    const expiresAt = new Date(Date.now() + tok.expires_in * 1000).toISOString();
    const { error: upErr } = await db.from("infomart_oauth_tokens").upsert({
      id: "default",
      access_token: tok.access_token,
      refresh_token: tok.refresh_token,
      scope: tok.scope ?? null,
      token_type: tok.token_type ?? "Bearer",
      expires_at: expiresAt,
      updated_at: new Date().toISOString(),
      label: "インフォマート受発注API",
    });
    if (upErr) {
      return html(`<h1>❌ 保存に失敗しました</h1><p>${esc(upErr.message)}</p>`, 500);
    }

    return html(`<h1>✅ インフォマートとの連携が完了しました</h1><p>このタブは閉じて大丈夫です。<br>アクセストークンの有効期限は5分と短いため、以後の利用ではリフレッシュトークン（有効期限31日）による自動再取得が必要です。</p>`);
  } catch (e) {
    return html(`<h1>❌ エラーが発生しました</h1><p>${esc(String(e))}</p>`, 500);
  }
});

function esc(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
