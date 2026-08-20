import { createClient } from "npm:@supabase/supabase-js@2";
const INTAKE_SECRET = "4259598a7ce747d54e2bf84326131129f21eb77f54dfdcdd";
const APP_URL = Deno.env.get("APP_URL") ?? "https://mirai-oss.github.io/nippo/";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info, x-line-signature"
};
const json = (o, status = 200)=>new Response(JSON.stringify(o), {
    status,
    headers: {
      ...cors,
      "Content-Type": "application/json"
    }
  });
const svc = ()=>createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
function jwtUid(req) {
  try {
    const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    return JSON.parse(atob(jwt.split(".")[1].replace(/-/g, "+").replace(/_/g, "/"))).sub ?? "";
  } catch  {
    return "";
  }
}
async function secrets(sb) {
  const { data } = await sb.from("app_secrets").select("key,value").in("key", [
    "line_channel_token",
    "line_channel_secret"
  ]);
  const m = {};
  (data ?? []).forEach((r)=>{
    m[r.key] = (r.value ?? "").trim();
  }); // 前後の空白・改行を落とす
  return {
    token: m.line_channel_token ?? "",
    secret: m.line_channel_secret ?? ""
  };
}
// LINEの署名検証（本文のHMAC-SHA256をBase64にしたものが x-line-signature と一致する）
async function validSignature(secret, body, sig) {
  if (!secret || !sig) return false;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), {
    name: "HMAC",
    hash: "SHA-256"
  }, false, [
    "sign"
  ]);
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body));
  const b64 = btoa(String.fromCharCode(...new Uint8Array(mac)));
  return b64 === sig;
}
async function lineReply(token, replyToken, text) {
  if (!token || !replyToken || !text) return;
  await fetch("https://api.line.me/v2/bot/message/reply", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`
    },
    body: JSON.stringify({
      replyToken,
      messages: [
        {
          type: "text",
          text: text.slice(0, 4900)
        }
      ]
    })
  }).catch(()=>{});
}
async function linePush(token, to, text) {
  const res = await fetch("https://api.line.me/v2/bot/message/push", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`
    },
    body: JSON.stringify({
      to,
      messages: [
        {
          type: "text",
          text: text.slice(0, 4900)
        }
      ]
    })
  });
  return {
    ok: res.ok,
    status: res.status,
    body: (await res.text()).slice(0, 300)
  };
}
Deno.serve(async (req)=>{
  if (req.method === "OPTIONS") return new Response("ok", {
    headers: cors
  });
  try {
    const raw = await req.text();
    let body = {};
    try {
      body = JSON.parse(raw || "{}");
    } catch  {
      body = {};
    }
    const sb = svc();
    const { token, secret } = await secrets(sb);
    // ---------------- 1) LINEからのWebhook ----------------
    if (Array.isArray(body.events)) {
      const sig = req.headers.get("x-line-signature") ?? "";
      if (!await validSignature(secret, raw, sig)) {
        return json({
          ok: false,
          error: "bad signature"
        }, 401);
      }
      for (const ev of body.events){
        const uid = ev?.source?.userId ?? "";
        if (!uid) continue;
        // v2.6.21: このアカウントは求人の返信用としても使われているため、
        // こちらから勝手に自動返信しない（あいさつはLINE側の設定にまかせる）
        if (ev.type === "follow") continue;
        if (ev.type !== "message" || ev.message?.type !== "text") continue;
        const { data: r } = await sb.rpc("line_intake", {
          p_secret: INTAKE_SECRET,
          p_line_user_id: uid,
          p_text: String(ev.message.text ?? ""),
          p_event_id: String(ev.message.id ?? ev.webhookEventId ?? ""),
          p_sent_at: new Date(Number(ev.timestamp ?? Date.now())).toISOString()
        });
        // v2.6.21: 返信するのは「連携が完了したとき」だけ。
        // 紐づかない相手（既存の求人やりとりの相手など）には何も返さず、手動チャットの邪魔をしない
        if (r?.linked && r?.reply) await lineReply(token, ev.replyToken, String(r.reply));
        // シフト機能: 応募者として認識できなかった場合だけ、従業員の連携合言葉として試す
        // （既存の応募者フローには一切影響しない。r.ok が false のときのみ実行）
        if (!r?.ok) {
          const { data: ur } = await sb.rpc("line_intake_user", {
            p_secret: INTAKE_SECRET,
            p_line_user_id: uid,
            p_text: String(ev.message.text ?? "")
          });
          if (ur?.linked && ur?.reply) await lineReply(token, ev.replyToken, String(ur.reply));
        }
      }
      return json({
        ok: true
      }); // LINEには常に200を返す
    }
    // ---------------- 2) 毎日の点検（GASから合言葉つきで呼ばれる） ----------------
    // ③ 面接日を過ぎた人のお知らせ ＋ ④ 入社登録フォーム未提出のリマインドLINE
    if (body.action === "daily") {
      if (body.secret !== INTAKE_SECRET) return json({
        ok: false,
        error: "認証エラー"
      }, 403);
      const { data: t, error } = await sb.rpc("recruit_daily_targets", {
        p_secret: INTAKE_SECRET
      });
      if (error) return json({
        ok: false,
        error: String(error.message ?? error)
      }, 500);
      const list = Array.isArray(t?.reminders) ? t.reminders : [];
      let sent = 0, failed = 0;
      for (const r of list){
        const { data: ap } = await sb.from("applicants").select("line_user_id").eq("id", r.id).maybeSingle();
        if (!ap?.line_user_id || !token) {
          failed++;
          continue;
        }
        // v2.6.36 送る文面はDB側で作って渡してくる（面接前日のリマインドなど）。
        // 無ければ今までどおり入社登録の催促を送る
        const url = `${APP_URL}?invite=${r.token}`;
        const text = typeof r.text === "string" && r.text.trim() ? r.text : `${r.name}さん\n\nお世話になっております。\n先日お送りした入社手続きのご登録がまだお済みでないようです。\nお手数ですが、下記より登録をお願いいたします。\n\n${url}\n\nご不明な点があれば、このままご返信ください。`;
        const res = await linePush(token, ap.line_user_id, text);
        if (res.ok) {
          await sb.rpc("line_log_out", {
            p_secret: INTAKE_SECRET,
            p_applicant: r.id,
            p_text: text
          });
          // v2.6.36 種類ごとに「送った印」を付け分ける
          if (r.kind === "interview") {
            await sb.rpc("mark_interview_reminded", {
              p_secret: INTAKE_SECRET,
              p_applicant: r.id
            });
          } else {
            await sb.rpc("recruit_mark_reminded", {
              p_secret: INTAKE_SECRET,
              p_applicant: r.id
            });
          }
          sent++;
        } else {
          failed++;
        }
      }
      return json({
        ok: true,
        alerts: t?.alerts ?? 0,
        reminded: sent,
        failed
      });
    }
    // ---------------- 2.5) 入社登録が完了した合図（v2.6.53・ログイン不要） ----------------
    // 入社登録を終えた本人の画面から呼ばれる。まだログインしていないので、
    // 招待トークン（本人しか知らないURLの一部）を身分証がわりにする。
    // 同じ人に二度送らないよう join_msg_sent_at で1回だけにしている。
    if (body.action === "join_done") {
      const tk = String(body.invite_token ?? "").trim();
      if (!tk) return json({
        ok: false,
        error: "招待トークンがありません"
      }, 400);
      const { data: ap } = await sb.from("applicants").select("id,name,line_user_id,join_msg_sent_at").eq("invite_token", tk).maybeSingle();
      if (!ap) return json({
        ok: false,
        error: "応募者が見つかりません"
      }, 404);
      if (ap.join_msg_sent_at) return json({
        ok: true,
        skipped: "送信済み"
      });
      if (!ap.line_user_id) return json({
        ok: false,
        error: "この方はLINEが連携されていません"
      }, 400);
      if (!token) return json({
        ok: false,
        error: "チャネルアクセストークンが未設定です"
      }, 400);
      const { data: text, error: mErr } = await sb.rpc("join_guide_message", {
        p_applicant: ap.id
      });
      if (mErr || !text) {
        return json({
          ok: false,
          error: `文面を作れませんでした（SQL v2_6_53 が未実行かもしれません）: ${mErr?.message ?? ""}`
        }, 500);
      }
      const sent = await linePush(token, ap.line_user_id, String(text));
      if (!sent.ok) return json({
        ok: false,
        error: `LINEの応答: ${sent.status} ${sent.body}`
      }, 400);
      await sb.rpc("line_log_out", {
        p_secret: INTAKE_SECRET,
        p_applicant: ap.id,
        p_text: String(text)
      });
      await sb.from("applicants").update({
        join_msg_sent_at: new Date().toISOString()
      }).eq("id", ap.id);
      return json({
        ok: true
      });
    }
    // ---------------- 2.7) シフト未提出リマインド（アプリから呼ばれる。募集権限=recruitとは別の権限） ----------------
    if (body.action === "push_user") {
      const puid = jwtUid(req);
      if (!puid) return json({
        ok: false,
        error: "ログインが必要です"
      }, 401);
      const { data: caller } = await sb.from("users").select("role,is_active,is_master").eq("id", puid).single();
      const allowed = !!caller?.is_active && (caller.is_master || [
        "CEO",
        "HQ",
        "TEAM",
        "TENCHO"
      ].includes(caller.role));
      if (!allowed) return json({
        ok: false,
        error: "権限がありません"
      }, 403);
      if (!token) return json({
        ok: false,
        error: "チャネルアクセストークンが未設定です"
      }, 400);
      const text = String(body.text ?? "").trim();
      if (!text) return json({
        ok: false,
        error: "本文が空です"
      }, 400);
      const { data: target } = await sb.from("users").select("id,line_user_id").eq("id", String(body.user_id ?? "")).maybeSingle();
      if (!target?.line_user_id) return json({
        ok: false,
        error: "この方はまだLINEが連携されていません"
      }, 400);
      const sent = await linePush(token, target.line_user_id, text);
      if (!sent.ok) return json({
        ok: false,
        error: `LINEの応答: ${sent.status} ${sent.body}`
      }, 400);
      return json({
        ok: true
      });
    }
    // ---------------- 3) アプリからの操作（ログイン必須） ----------------
    const uid = jwtUid(req);
    if (!uid) return json({
      ok: false,
      error: "ログインが必要です"
    }, 401);
    const { data: allowed } = await sb.rpc("has_feature", {
      p_user: uid,
      p_feature: "recruit"
    });
    if (!allowed) return json({
      ok: false,
      error: "権限がありません"
    }, 403);
    if (body.action === "test") {
      if (!token) return json({
        ok: false,
        error: "チャネルアクセストークンが未設定です"
      }, 400);
      const res = await fetch("https://api.line.me/v2/bot/info", {
        headers: {
          Authorization: `Bearer ${token}`
        }
      });
      const info = await res.json().catch(()=>({}));
      if (!res.ok) {
        // うまくいかないときの手がかり（値そのものは出さず、長さと形だけ知らせる）
        const hint = token.length <= 40 ? `貼り付けたトークンが${token.length}文字しかありません。チャネルシークレット（32文字）を①に貼っていませんか？` : `トークンは${token.length}文字です（通常170文字前後）。LINE Developersの「コピー」ボタンで取り直して貼り替えてください`;
        return json({
          ok: false,
          error: `LINEの応答: ${res.status} … ${hint}`,
          tokenLen: token.length,
          secretLen: secret.length
        }, 400);
      }
      return json({
        ok: true,
        name: info.displayName ?? "",
        basicId: info.basicId ?? ""
      });
    }
    if (body.action === "push") {
      if (!token) return json({
        ok: false,
        error: "チャネルアクセストークンが未設定です"
      }, 400);
      const text = String(body.text ?? "").trim();
      if (!text) return json({
        ok: false,
        error: "本文が空です"
      }, 400);
      const { data: ap } = await sb.from("applicants").select("id,name,line_user_id").eq("id", String(body.applicant_id ?? "")).maybeSingle();
      if (!ap) return json({
        ok: false,
        error: "応募者が見つかりません"
      }, 404);
      if (!ap.line_user_id) return json({
        ok: false,
        error: "この応募者はまだLINEが連携されていません"
      }, 400);
      const sent = await linePush(token, ap.line_user_id, text);
      if (!sent.ok) return json({
        ok: false,
        error: `LINEの応答: ${sent.status} ${sent.body}`
      }, 400);
      await sb.rpc("line_log_out", {
        p_secret: INTAKE_SECRET,
        p_applicant: ap.id,
        p_text: text
      });
      return json({
        ok: true
      });
    }
    return json({
      ok: false,
      error: "unknown action"
    }, 400);
  } catch (e) {
    return json({
      ok: false,
      error: String(e)
    }, 500);
  }
});
