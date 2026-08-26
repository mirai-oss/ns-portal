// =====================================================================
// invoice-intake: 請求書メール取込＋返信送信（新規独立GASプロジェクト）
// 設置場所: script.google.com（shunji.nakayama@ns0314.com のアカウント）
// 指示書: ns-portal/docs/実装指示書_請求書メール管理Phase1_2026-08-23.md §3・§4.5
//
// 【重要】indeed-intake.gs（nippoリポジトリ・n-style-projects/nippo/gas/）とは
// 完全に独立した別プロジェクト。過去に共有GASプロジェクトへの追記で取込が全滅した
// 事故があったため、障害を分離する目的で新規に作っている。このファイル・この
// プロジェクトの内容を既存のindeed-intake.gsへ追記・統合しない。
//
// 初回セットアップ手順（実施済み・参考用。別アカウント等へ作り直す場合はこの順で）:
//   1. スクリプトエディタ「プロジェクトの設定」→「スクリプト プロパティ」に
//      INVOICE_INTAKE_SECRET を登録する（値はSupabaseの
//      `select value from app_secrets where key='invoice_intake_secret'` と同じもの。
//      コードには絶対に書かない＝2026-08-21のINTAKE_SECRET平文露出事故の教訓）
//   2. 関数「setup」を1回実行（実行時に権限の承認が出たら許可）
//      → ラベル「請求書」「請求書取込済」作成＋5分ごとのトリガー登録＋即時1回実行
//   3. 初回のみ「importAllLabeled」を1回実行（対象条件に合う過去メールをまとめて
//      取込む。1回の呼び出しで最大200スレッドまでのため、件数が多ければ「取込済」が
//      付いていないメールが無くなるまで複数回実行。実行時間の上限にも注意）
//   4. 「デプロイ」→「新しいデプロイ」→種類=ウェブアプリ、実行ユーザー=自分、
//      アクセスできるユーザー=全員、で公開しURLを控える
//      （Supabase Edge Function invoice-send の環境変数 INVOICE_GAS_WEBAPP_URL に設定する）
//   5. Gmail設定「アカウントとインポート」→「名前を付けて送信」に info@ns0314.com の
//      エイリアスが登録済みであること（差出人をinfo@にするために必須・ユーザー確認1分）
//
// 【取込の判定基準（2026-08-24確定・ユーザー確認済み／2026-08-26 C-5でエイリアス追加）】
//   info@ns0314.com・toho.info@ns0314.com宛（To/CC。ともにshunji.nakayama@ns0314.com
//   アカウントの同一エイリアス・実機確認済み）のメールは件名・ラベルに関わらずすべて取込対象。
//   どちらのエイリアス宛だったかはinvoice_emails.target_aliasに記録する（ALIASES配列参照）。
//   「請求書」ラベルが付いたメールも（上記エイリアス宛でなくても）追加で拾う。
//   ただしshunji.nakayama@ns0314.com（社長個人）がToに直接指定されているメールは対象外
//   （CCに入っているだけの正規の請求書スレッドまでは除外しない）。
//   ラベル・宛先のみで判定＝実際の受信箱で既読にする・アーカイブするなど（is:unread/
//   in:inbox等）は一切条件に含めない＝本人のメール操作とは完全に無関係に動く。
//   （検討過程で「請求書」ラベル限定にした時期もあったが、件名にキーワードが無い
//   メールを取りこぼす実例が出たため上記の形に戻した）
// =====================================================================

const SUPA_URL = "https://uuvsxzhpxtghojoubjcc.supabase.co";
const SUPA_ANON = "sb_publishable_MrwPJAx_Ws_fdRutprKCiQ_dg3wCiTr";
const INTAKE_FN_URL = SUPA_URL + "/functions/v1/invoice-intake";
const SOURCE_LABEL_NAME = "請求書";       // 付いていれば追加で取込対象にするラベル（必須ではない）
const PROCESSED_LABEL_NAME = "請求書取込済"; // 取込済みの印（このスクリプトが付ける・重複防止）
// 2026-08-26 C-5追加: toho.info@ns0314.com宛も取込対象に追加（同一アカウントのエイリアス、
// 実機確認済み）。ALIASESに追加すればSEARCH_QUERY・target_alias判定とも自動的に対応する
const ALIASES = ["info@ns0314.com", "toho.info@ns0314.com"];
const SEARCH_QUERY = '(' + ALIASES.map(function (a) { return 'to:' + a + ' OR cc:' + a; }).join(' OR ')
  + ' OR label:' + SOURCE_LABEL_NAME + ') -to:shunji.nakayama@ns0314.com -label:' + PROCESSED_LABEL_NAME;
const FROM_ALIAS = "info@ns0314.com";

// 実際にどのエイリアス宛だったかをinvoice_emails.target_aliasへ記録するための判定
// （複数該当する場合はALIASESの先頭を優先＝info@を既定として扱う）
function resolveTargetAlias_(msg) {
  var to = (msg.getTo() || "").toLowerCase();
  var cc = (msg.getCc() || "").toLowerCase();
  for (var i = 0; i < ALIASES.length; i++) {
    var a = ALIASES[i].toLowerCase();
    if (to.indexOf(a) >= 0 || cc.indexOf(a) >= 0) return ALIASES[i];
  }
  return ALIASES[0]; // 「請求書」ラベル経由等、いずれのエイリアスにも一致しない場合の既定値
}
const MAX_ATTACHMENT_BYTES = 20 * 1024 * 1024; // invoice-filesバケットの上限(20MB)に合わせる

function getSecret_() {
  var s = PropertiesService.getScriptProperties().getProperty("INVOICE_INTAKE_SECRET");
  if (!s) throw new Error("スクリプトプロパティ INVOICE_INTAKE_SECRET が未設定です");
  return s;
}

// 初回セットアップ（1回だけ実行）
function setup() {
  GmailApp.createLabel(SOURCE_LABEL_NAME);    // 既にあれば何もしない（作成済みでもエラーにならない）
  GmailApp.createLabel(PROCESSED_LABEL_NAME);
  ScriptApp.getProjectTriggers().forEach(function (t) {
    if (t.getHandlerFunction() === "runAll") ScriptApp.deleteTrigger(t);
  });
  ScriptApp.newTrigger("runAll").timeBased().everyMinutes(5).create();
  runAll();
}

// 5分ごとに実行される本体
function runAll() {
  checkInvoiceMails();
  sendQueuedReplies();
}

// 「請求書」ラベルが付いている過去メールのまとめ取込（初回・ラベルを大量に付けた直後などに手動実行）。
// GmailApp.searchは1回の呼び出しで最大200スレッドしか返さないため、対象が200を超える場合は
// 「請求書」ラベルはあるのに「請求書取込済」が付いていないメールが無くなるまで複数回実行する
// （実行のたびに次の200件が進む。安全に何度でも再実行できる＝取込済みは自動的にスキップされる）
function importAllLabeled() {
  checkInvoiceMails_(SEARCH_QUERY, 200);
}

function checkInvoiceMails() {
  checkInvoiceMails_(SEARCH_QUERY, 50);
}

// =====================================================================
// 取込
// =====================================================================
function checkInvoiceMails_(query, maxThreads) {
  var label = GmailApp.getUserLabelByName(PROCESSED_LABEL_NAME) || GmailApp.createLabel(PROCESSED_LABEL_NAME);
  var threads = GmailApp.search(query, 0, maxThreads || 50);
  for (var t = 0; t < threads.length; t++) {
    var thread = threads[t];
    var messages = thread.getMessages();
    var threadOk = true;
    for (var m = 0; m < messages.length; m++) {
      try {
        if (!postMessage_(thread, messages[m])) threadOk = false;
      } catch (e) {
        console.error("invoice-intake postMessage failed: " + e);
        threadOk = false;
      }
    }
    // スレッド内の全メッセージが正常に送れたときだけラベルを付ける
    // （途中で失敗したメッセージが残っていると、次回検索から漏れて取りこぼす）
    if (threadOk) thread.addLabel(label);
  }
}

// 2026-08-24: includeInlineImages:falseだと本物の請求書PDFまで取りこぼす実例が見つかった
// （Outlook for iOS等、送信元によってPDF添付にContent-Disposition:inlineが付くことがあり、
// Gmail側がそれを「インライン」として扱うため）。true に変更し、代わりに「署名ロゴ等の小さい
// 画像」だけを除外する方式にした（PDF・Office文書等は画像でないのでサイズに関わらず必ず残す）
// 2026-08-24: 実機で49.7KBの署名ロゴが紛れ込む例を確認したため30KB→100KBへ引き上げ
var SIGNATURE_IMAGE_MAX_BYTES = 100 * 1024; // これ未満のimage/*は署名ロゴ等とみなしスキップ

function postMessage_(thread, msg) {
  var rawAttachments = msg.getAttachments({ includeInlineImages: true, includeAttachments: true });
  var attPayload = [];
  for (var i = 0; i < rawAttachments.length; i++) {
    var blob = rawAttachments[i];
    var bytes = blob.getBytes();
    var mime = blob.getContentType() || "";
    if (mime.indexOf("image/") === 0 && bytes.length < SIGNATURE_IMAGE_MAX_BYTES) continue; // 署名ロゴ等をスキップ
    if (bytes.length > MAX_ATTACHMENT_BYTES) {
      console.error("添付が20MB超のためスキップ: " + blob.getName());
      continue;
    }
    attPayload.push({
      file_name: blob.getName(),
      mime_type: mime,
      size_bytes: bytes.length,
      base64: Utilities.base64Encode(bytes)
    });
  }

  var payload = {
    secret: getSecret_(),
    gmail_message_id: msg.getId(),
    gmail_thread_id: thread.getId(),
    from_address: msg.getFrom(),
    to_address: msg.getTo(),
    delivered_to: (msg.getHeader && msg.getHeader("Delivered-To")) || "",
    cc_address: msg.getCc(),
    target_alias: resolveTargetAlias_(msg), // 2026-08-26 C-5追加
    subject: msg.getSubject(),
    received_at: msg.getDate().toISOString(),
    body_text: msg.getPlainBody(),
    body_html: msg.getBody(),
    attachments: attPayload
  };

  var res = UrlFetchApp.fetch(INTAKE_FN_URL, {
    method: "post",
    contentType: "application/json",
    headers: { apikey: SUPA_ANON, Authorization: "Bearer " + SUPA_ANON },
    payload: JSON.stringify(payload),
    muteHttpExceptions: true
  });
  var code = res.getResponseCode();
  var txt = res.getContentText();
  if (code >= 300) { console.error("invoice-intake: " + code + " " + txt); return false; }
  // 添付の一部だけ保存に失敗した場合はレスポンスがsuccess:trueでも見逃さないよう警告を出す
  try {
    var j = JSON.parse(txt);
    if (j.attachments_failed && j.attachments_failed.length) {
      console.error("添付の一部が保存できませんでした（" + msg.getSubject() + "）: " + JSON.stringify(j.attachments_failed));
    }
  } catch (e) { /* ignore */ }
  return true;
}

// =====================================================================
// 返信送信
// =====================================================================

// WebApp（トークン認証）: Edge Function invoice-send からの即時送信リクエスト
function doPost(e) {
  var body;
  try {
    body = JSON.parse(e.postData.contents);
  } catch (err) {
    return jsonOut_({ success: false, error: "invalid json" });
  }
  if (!body || body.token !== getSecret_()) {
    return jsonOut_({ success: false, error: "unauthorized" });
  }
  try {
    var sentId = body.mode === "compose"
      ? sendCompose_(body.to, body.subject, body.body)
      : sendReply_(body.thread_id, body.body);
    return jsonOut_({ success: true, sent_message_id: sentId });
  } catch (err) {
    return jsonOut_({ success: false, error: String(err) });
  }
}

function jsonOut_(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}

// 5分トリガーの保険ルート: Edge Function側の即時送信が失敗しqueuedのまま残っている
// 返信を拾って再送する（即時＋保険の二段構え。指示書§4.5）
function sendQueuedReplies() {
  var res = UrlFetchApp.fetch(SUPA_URL + "/rest/v1/rpc/invoice_outbox_pull_queued", {
    method: "post",
    contentType: "application/json",
    headers: { apikey: SUPA_ANON, Authorization: "Bearer " + SUPA_ANON },
    payload: JSON.stringify({ p_secret: getSecret_() }),
    muteHttpExceptions: true
  });
  if (res.getResponseCode() >= 300) {
    console.error("invoice_outbox_pull_queued: " + res.getResponseCode() + " " + res.getContentText());
    return;
  }
  var rows = JSON.parse(res.getContentText());
  for (var i = 0; i < rows.length; i++) trySendOne_(rows[i]);
}

function trySendOne_(ob) {
  try {
    var sentId;
    if (ob.send_mode === "compose") {
      sentId = sendCompose_(ob.to_address, ob.subject, ob.body_text);
    } else {
      var info = fetchEmailInfo_(ob.email_id);
      if (!info) { console.error("invoice outbox: email not found " + ob.email_id); return; }
      sentId = sendReply_(info.gmail_thread_id, ob.body_text);
    }
    markSent_(ob.id, sentId);
  } catch (e) {
    console.error("invoice outbox send failed: " + ob.id + " " + e);
    markFailed_(ob.id, String(e));
  }
}

function fetchEmailInfo_(emailId) {
  var url = SUPA_URL + "/rest/v1/invoice_emails?id=eq." + emailId + "&select=gmail_thread_id,from_address,subject";
  var res = UrlFetchApp.fetch(url, {
    method: "get",
    headers: { apikey: SUPA_ANON, Authorization: "Bearer " + SUPA_ANON },
    muteHttpExceptions: true
  });
  if (res.getResponseCode() >= 300) return null;
  var rows = JSON.parse(res.getContentText());
  return rows && rows[0] ? rows[0] : null;
}

function markSent_(outboxId, sentMessageId) {
  UrlFetchApp.fetch(SUPA_URL + "/rest/v1/rpc/invoice_outbox_mark_sent", {
    method: "post",
    contentType: "application/json",
    headers: { apikey: SUPA_ANON, Authorization: "Bearer " + SUPA_ANON },
    payload: JSON.stringify({ p_secret: getSecret_(), p_outbox_id: outboxId, p_gmail_sent_message_id: sentMessageId }),
    muteHttpExceptions: true
  });
}

function markFailed_(outboxId, errMsg) {
  UrlFetchApp.fetch(SUPA_URL + "/rest/v1/rpc/invoice_outbox_mark_failed", {
    method: "post",
    contentType: "application/json",
    headers: { apikey: SUPA_ANON, Authorization: "Bearer " + SUPA_ANON },
    payload: JSON.stringify({ p_secret: getSecret_(), p_outbox_id: outboxId, p_error: errMsg }),
    muteHttpExceptions: true
  });
}

// 元スレッドへ差出人=info@ns0314.comで返信する（宛先=元メールのFrom固定。
// GmailMessage.reply()は自動的に元メッセージのFrom/Reply-Toへ返信するため、
// 宛先を明示的に受け取って上書きすることはしない＝指示書§4.5の「編集不可」を構造的に担保）
function sendReply_(threadId, bodyText) {
  var thread = GmailApp.getThreadById(threadId);
  if (!thread) throw new Error("スレッドが見つかりません: " + threadId);
  var msgs = thread.getMessages();
  var last = msgs[msgs.length - 1];
  last.reply(bodyText, { from: FROM_ALIAS });
  var after = thread.getMessages();
  return after[after.length - 1].getId();
}

// 新規メール作成（2026-08-24追加。返信ではなく新しいスレッドを起こす）。
// 差出人=info@ns0314.com固定。createDraft().send()を使うのは、送信済みメッセージの
// IDをその場で取得するため（GmailApp.sendEmailは戻り値が無くIDが取れない）
function sendCompose_(to, subject, bodyText) {
  if (!to) throw new Error("宛先が指定されていません");
  var draft = GmailApp.createDraft(to, subject || "（件名なし）", bodyText, { from: FROM_ALIAS });
  var sent = draft.send();
  return sent.getId();
}
