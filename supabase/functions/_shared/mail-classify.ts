// 請求書メール自動処理 Phase1: メール自動分類（担当C・2026-10-13）
// 順序: ①既知送信元ルール(invoice_mail_rules: from_domain/from_contains) → ②件名・添付有無ルール(subject_contains)
//       → ③軽量AI(Haiku) → ④確信度が低いものだけ上位AI(Sonnet) → それでも低ければ needs_review
// 結果は invoice_emails.auto_category / auto_category_by / auto_confidence / auto_category_reason に記録し、
// mail_kind が NULL（未分類）のときだけ mail_kind へ写す（人の手動分類は常に優先）。請求書以外のメールにPDF解析をしない前提。
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";

export type AutoCategory = "invoice_attachment" | "invoice_notice" | "invoice_download" | "sales_deposit" | "irrelevant" | "needs_review";
export interface MailInput {
  from_address?: string | null; subject?: string | null; body_text?: string | null;
  attachments: { file_name: string; mime_type?: string | null }[];
}
export interface ClassifyResult { category: AutoCategory; by: "rule" | "ai"; confidence: number; reason: string }

const CATEGORIES: AutoCategory[] = ["invoice_attachment", "invoice_notice", "invoice_download", "sales_deposit", "irrelevant", "needs_review"];

// 分類 → 既存の mail_kind（invoice/sales/contract）。irrelevant / needs_review は写さない（人が見る）
export function categoryToMailKind(c: AutoCategory): "invoice" | "sales" | null {
  if (c === "invoice_attachment" || c === "invoice_notice" || c === "invoice_download") return "invoice";
  if (c === "sales_deposit") return "sales";
  return null;
}

function fromParts(raw: string): { email: string; domain: string } {
  const m = raw.match(/<([^>]+)>/);
  const email = (m ? m[1] : raw).toLowerCase().trim();
  return { email, domain: email.includes("@") ? email.split("@").pop()! : "" };
}

// ①②: ルール判定。優先度の小さい順に最初に当たったもの
export function classifyByRules(mail: MailInput, rules: any[]): ClassifyResult | null {
  const { email, domain } = fromParts(String(mail.from_address ?? ""));
  const subject = String(mail.subject ?? "").toLowerCase();
  const hasAtt = mail.attachments.length > 0;
  const sorted = [...rules].filter((r) => r.is_active).sort((a, b) => a.priority - b.priority);
  for (const r of sorted) {
    const pat = String(r.pattern ?? "").toLowerCase().trim();
    if (!pat) continue;
    if (r.needs_attachment === true && !hasAtt) continue;
    if (r.needs_attachment === false && hasAtt) continue;
    let hit = false;
    if (r.rule_type === "from_domain") hit = domain === pat || domain.endsWith("." + pat);
    else if (r.rule_type === "from_contains") hit = email.includes(pat);
    else if (r.rule_type === "subject_contains") hit = subject.includes(pat);
    if (hit) return { category: r.category, by: "rule", confidence: 1, reason: `ルール: ${r.rule_type}=${r.pattern}${r.note ? "（" + r.note + "）" : ""}` };
  }
  return null;
}

const TOOL = {
  name: "classify_mail",
  description: "受信メールを分類する",
  input_schema: {
    type: "object",
    properties: {
      category: { type: "string", enum: CATEGORIES, description:
        "invoice_attachment=請求書・領収書などがPDF/画像で添付されている／invoice_notice=請求の通知だが請求書本体は添付されていない（パスワード通知・送付のお知らせ・本文に金額が書かれている等）／invoice_download=請求書はサイトからダウンロードする型（インフォマート・マイページ等）／sales_deposit=当社への入金・送金・精算の明細／irrelevant=請求・入金と無関係（営業・宣伝・採用・アカウント通知など）／needs_review=判断がつかない" },
      confidence: { type: "number", description: "0〜1。確信が持てないほど低く" },
      reason: { type: "string", description: "判断理由を日本語で1文" },
    },
    required: ["category", "confidence", "reason"],
  },
};

async function askModel(apiKey: string, model: string, mail: MailInput): Promise<ClassifyResult> {
  const att = mail.attachments.length
    ? mail.attachments.map((a) => `${a.file_name}（${a.mime_type ?? "不明"}）`).join("、")
    : "なし";
  const text = `送信元: ${mail.from_address ?? ""}\n件名: ${mail.subject ?? ""}\n添付ファイル: ${att}\n本文（先頭）:\n${String(mail.body_text ?? "").slice(0, 1500)}`;
  // モデルによっては tool_choice の強制（type:"tool"）に未対応のため、400で拒否されたら自動選択(auto)で再試行する
  const call = (toolChoice: unknown) => fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "content-type": "application/json", "x-api-key": apiKey, "anthropic-version": "2023-06-01" },
    body: JSON.stringify({
      model, max_tokens: 300,
      system: "あなたは日本の飲食企業（有限会社トーホーエージェンシー等）の経理受付です。届いたメールが、支払うべき請求書に関するものか、入金・精算の明細か、無関係かを分類します。不明なら無理に決めず needs_review と低い確信度にしてください。必ず classify_mail ツールで答えてください。",
      tools: [TOOL], tool_choice: toolChoice,
      messages: [{ role: "user", content: text }],
    }),
  });
  let res = await call({ type: "tool", name: "classify_mail" });
  if (res.status === 400) {
    const errText = await res.clone().text().catch(() => "");
    if (errText.includes("tool_choice")) res = await call({ type: "auto" });
  }
  if (!res.ok) throw new Error(`AI分類に失敗（${res.status}）: ${(await res.text().catch(() => "")).slice(0, 200)}`);
  const j = await res.json();
  const tu = (j.content ?? []).find((c: any) => c.type === "tool_use");
  const inp = tu?.input ?? {};
  const category: AutoCategory = CATEGORIES.includes(inp.category) ? inp.category : "needs_review";
  const confidence = Math.max(0, Math.min(1, Number(inp.confidence) || 0));
  return { category, by: "ai", confidence, reason: `AI(${model}): ${String(inp.reason ?? "").slice(0, 200)}` };
}

export async function classifyMail(db: SupabaseClient, mail: MailInput): Promise<ClassifyResult> {
  const { data: rules } = await db.from("invoice_mail_rules").select("*").eq("is_active", true);
  const byRule = classifyByRules(mail, rules ?? []);
  if (byRule) return byRule;

  const { data: setting } = await db.from("automation_rule_settings").select("enabled, params").eq("key", "email_classify_ai").maybeSingle();
  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!setting?.enabled || !apiKey) return { category: "needs_review", by: "rule", confidence: 0, reason: "ルールに該当せず、AI分類は停止中（または未設定）" };
  const p = (setting.params ?? {}) as any;
  const minConf = Number(p.min_confidence ?? 0.7);
  try {
    const fast = await askModel(apiKey, String(p.model_fast ?? "claude-haiku-5-5"), mail);
    if (fast.confidence >= minConf && fast.category !== "needs_review") return fast;
    const strong = await askModel(apiKey, String(p.model_strong ?? "claude-sonnet-5-5"), mail);
    if (strong.confidence >= minConf && strong.category !== "needs_review") return { ...strong, reason: strong.reason + "（軽量AIで確信度不足→上位AIで再判定）" };
    return { category: "needs_review", by: "ai", confidence: strong.confidence, reason: "上位AIでも確信度が低い: " + strong.reason };
  } catch (e) {
    return { category: "needs_review", by: "ai", confidence: 0, reason: "AI分類エラー: " + String((e as Error)?.message ?? e).slice(0, 200) };
  }
}

// 分類結果を保存。mail_kind は未分類(NULL)のときだけ写す。履歴を invoice_audit_logs に残す
export async function saveClassification(db: SupabaseClient, emailId: string, r: ClassifyResult, writeKind: boolean) {
  await db.from("invoice_emails").update({
    auto_category: r.category, auto_category_by: r.by, auto_confidence: r.confidence,
    auto_category_reason: r.reason, auto_classified_at: new Date().toISOString(),
  }).eq("id", emailId);
  const kind = categoryToMailKind(r.category);
  let kindSet = false;
  if (writeKind && kind) {
    const { data } = await db.from("invoice_emails").update({ mail_kind: kind, updated_at: new Date().toISOString() })
      .eq("id", emailId).is("mail_kind", null).select("id");
    kindSet = !!(data && data.length);
  }
  await db.from("invoice_audit_logs").insert({
    entity_type: "invoice_email", entity_id: emailId, action: "auto_classified", actor_type: "ai",
    new_value: { auto_category: r.category, by: r.by, confidence: r.confidence, mail_kind_set: kindSet ? kind : null },
    note: r.reason,
  });
  return { kindSet };
}
