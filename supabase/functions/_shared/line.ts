// LINE共通ヘルパー（2026-10-05・担当: 仕入れ移動公開フォームのSupabase直結化）
// line-webhook（push_order_group）と cost-transfer-submit の両方から import して使う。
// 「発注グループLINEへ通知」のメッセージ組み立て・送信ロジックを1箇所にまとめ、
// 呼び出し元ごとの重複を避ける。

export async function linePush(token: string, to: string, text: string) {
  const res = await fetch("https://api.line.me/v2/bot/message/push", {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
    body: JSON.stringify({ to, messages: [{ type: "text", text: text.slice(0, 4900) }] }),
  });
  return { ok: res.ok, status: res.status, body: (await res.text()).slice(0, 300) };
}

function buildOrderGroupText(params: {
  date?: string;
  fromStore?: string;
  toStore?: string;
  items?: Array<{ name?: string; qty?: string | number; amount?: number }>;
  note?: string;
}): string {
  const { date, fromStore, toStore, items, note } = params;
  const list = Array.isArray(items) ? items : [];
  const itemLines = list
    .map((it) => `・${String(it?.name ?? "")} ×${String(it?.qty ?? "")}（${Number(it?.amount ?? 0).toLocaleString("ja-JP")}円）`)
    .join("\n");
  const total = list.reduce((s, it) => s + (Number(it?.amount) || 0), 0);
  return (
    `🔀 仕入れ移動の申請がありました\n` +
    `${String(fromStore ?? "")} → ${String(toStore ?? "")}（${String(date ?? "")}）\n\n` +
    `${itemLines || "（商品なし）"}\n\n` +
    `合計: ${total.toLocaleString("ja-JP")}円` +
    (note ? `\nメモ: ${String(note)}` : "")
  );
}

// 発注グループLINEへ通知する（トークン・グループIDはapp_secretsから自前で取得する自己完結型ヘルパー）。
// 呼び出し元（line-webhook・cost-transfer-submit）は合言葉チェック済みの状態でこれを呼ぶこと。
export async function linePushOrderGroup(
  sb: any,
  params: { date?: string; fromStore?: string; toStore?: string; items?: Array<{ name?: string; qty?: string | number; amount?: number }>; note?: string }
): Promise<{ ok: boolean; error?: string }> {
  const { data } = await sb.from("app_secrets").select("key,value").in("key", ["line_channel_token", "line_order_group_id"]);
  const m: Record<string, string> = {};
  (data ?? []).forEach((r: any) => { m[r.key] = (r.value ?? "").trim(); });
  const token = m.line_channel_token ?? "";
  const orderGroupId = m.line_order_group_id ?? "";
  if (!token) return { ok: false, error: "チャネルアクセストークンが未設定です" };
  if (!orderGroupId) return { ok: false, error: "発注グループが未登録です（LINEでBotをグループに招待してください）" };
  const sent = await linePush(token, orderGroupId, buildOrderGroupText(params));
  if (!sent.ok) return { ok: false, error: `LINEの応答: ${sent.status} ${sent.body}` };
  return { ok: true };
}
