// マネーフォワード クラウド会計 API呼び出し用の共通ヘルパー（2026-08-27新規）
// mf-pl-sync・mf-journal-create等、今後追加する消費側Edge Functionから import して使う。
//
// getValidAccessToken(): mf_oauth_tokensに保存済みのトークンを見て、
//   有効期限（1時間）が近ければ自動でリフレッシュしてから返す。
//   refresh_tokenは使うたびにローテートされる仕様のため、リフレッシュのたびにDBを上書きする。
import { createClient } from "npm:@supabase/supabase-js@2";

const TOKEN_URL = "https://api.biz.moneyforward.com/token"; // OAuth専用サーバー（認可・トークン交換のみ）
const API_BASE = "https://api-accounting.moneyforward.com"; // 会計リソースAPI本体（勘定科目・仕訳等）はこちら別ホスト。
// 2026-08-27に実アクセストークンでの直接probeで確定。当初api.biz.moneyforward.comのまま
// 書いてしまいNOT_FOUNDが出続ける不具合になっていた（ユーザー実機報告で発覚・修正）

function svc() {
  return createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
}

export async function getValidAccessToken(tenantId = "default"): Promise<{ accessToken: string; officeId: string | null }> {
  const db = svc();
  const { data: row, error } = await db.from("mf_oauth_tokens").select("*").eq("id", tenantId).maybeSingle();
  if (error) throw new Error("mf_oauth_tokens読み取りエラー: " + error.message);
  if (!row) throw new Error(`マネーフォワード未連携です（事業者:${tenantId}）。管理者が一度 /functions/v1/mf-oauth-callback 経由の認可を完了する必要があります。`);

  const expiresAt = new Date(row.expires_at).getTime();
  const bufferMs = 5 * 60 * 1000; // 期限5分前から更新する
  if (Date.now() < expiresAt - bufferMs) {
    return { accessToken: row.access_token, officeId: row.office_id };
  }

  // 期限切れ間近 → リフレッシュ
  const clientId = Deno.env.get("MF_CLIENT_ID");
  const clientSecret = Deno.env.get("MF_CLIENT_SECRET");
  if (!clientId || !clientSecret) throw new Error("MF_CLIENT_ID/MF_CLIENT_SECRET未設定です");

  const basic = btoa(`${clientId}:${clientSecret}`);
  const res = await fetch(TOKEN_URL, {
    method: "POST",
    headers: { Authorization: `Basic ${basic}`, "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "refresh_token", refresh_token: row.refresh_token }),
  });
  if (!res.ok) {
    // refresh_tokenは使い捨て（ローテート）のため、ほぼ同時に2つのリクエストが両方
    // リフレッシュを試みると片方は「既に使われたrefresh_token」として失敗する。
    // その場合は少し待ってDBを再読み込みし、もう一方が更新した最新トークンがあればそれを使う
    // （自分では再リフレッシュしない＝refresh_tokenをさらに消費して悪化させない）
    await new Promise((r) => setTimeout(r, 400));
    const { data: freshRow } = await db.from("mf_oauth_tokens").select("*").eq("id", tenantId).maybeSingle();
    if (freshRow && new Date(freshRow.updated_at).getTime() > new Date(row.updated_at).getTime()) {
      return { accessToken: freshRow.access_token, officeId: freshRow.office_id };
    }
    const text = await res.text();
    throw new Error(`トークン更新に失敗しました(${res.status}): ${text}`);
  }
  const text = await res.text();
  const tok = JSON.parse(text) as { access_token: string; refresh_token: string; scope?: string; token_type?: string; expires_in: number };

  const newExpiresAt = new Date(Date.now() + tok.expires_in * 1000).toISOString();
  await db.from("mf_oauth_tokens").update({
    access_token: tok.access_token,
    refresh_token: tok.refresh_token,
    scope: tok.scope ?? row.scope,
    expires_at: newExpiresAt,
    updated_at: new Date().toISOString(),
  }).eq("id", tenantId);
  await db.from("mf_sync_logs").insert({ action: "oauth_refreshed", actor_type: "system", detail: { tenant_id: tenantId } });

  return { accessToken: tok.access_token, officeId: row.office_id };
}

export async function mfFetch(path: string, accessToken: string, init: RequestInit = {}): Promise<Response> {
  return fetch(`${API_BASE}${path}`, {
    ...init,
    headers: { ...(init.headers ?? {}), Authorization: `Bearer ${accessToken}` },
  });
}
