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
// 初回セットアップ手順:
//   1. スクリプトエディタ「プロジェクトの設定」→「スクリプト プロパティ」に
//      INVOICE_INTAKE_SECRET を登録する（値はSupabaseの
//      `select value from app_secrets where key='invoice_intake_secret'` と同じもの。
//      コードには絶対に書かない＝2026-08-21のINTAKE_SECRET平文露出事故の教訓）
//   2. 関数「setup」を1回実行（実行時に権限の承認が出たら許可）
//      → ラベル「請求書」「請求書取込済」作成＋5分ごとのトリガー登録＋即時1回実行
//   3. 初回のみ「importAllLabeled」を1回実行（「請求書」ラベルが付いている過去メールを
//      まとめて取込む。件数が多ければ複数回実行。実行時間の上限に注意）
//   4. 「デプロイ」→「新しいデプロイ」→種類=ウェブアプリ、実行ユーザー=自分、
//      アクセスできるユーザー=全員、で公開しURLを控える
//      （Supabase Edge Function invoice-send の環境変数 INVOICE_GAS_WEBAPP_URL に設定する）
//   5. Gmail設定「アカウントとインポート」→「名前を付けて送信」に info@ns0314.com の
//      エイリアスが登録済みであること（差出人をinfo@にするために必須・ユーザー確認1分）
//
// 【取込の判定基準】2026-08-24変更: 当初「info@宛の全メール」を対象にしていたが、
// 実機検証でIndeed応募通知・銀行通知等まで無差別に取り込んでしまうことが判明（ユーザー
// 確認済み）。判定を「Gmailのラベル」に変更した＝Gmail側で「請求書」ラベルが付いている
// メールだけをこのシステムの対象とする。ラベル付けは手動でもGmail側のフィルタ自動振り分け
// でもよい。過去メールも「請求書」ラベルさえ付いていれば取込対象になる（日付の制限なし）。
// =====================================================================

const SUPA_URL = "https://uuvsxzhpxtghojoubjcc.supabase.co";
const SUPA_ANON = "sb_publishable_MrwPJAx_Ws_fdRutprKCiQ_dg3wCiTr";
const INTAKE_FN_URL = SUPA_URL + "/functions/v1/invoice-intake";
const SOURCE_LABEL_NAME = "請求書";       // これが付いているメールだけを取込対象とする（人・Gmailフィルタが付ける）
const PROCESSED_LABEL_NAME = "請求書取込済"; // 取込済みの印（このスクリプトが付ける・重複防止）
const SEARCH_QUERY = 'label:' + SOURCE_LABEL_NAME + ' -label:' + PROCESSED_LABEL_NAME;
const FROM_ALIAS = "info@ns0314.com";
const MAX_ATTACHMENT_BYTES = 20 * 1024 * 1024; // invoice-filesバケットの上限(20MB)に合わせる

// 2026-08-24: 誤って「info@宛の全メール」を取込んでしまった際の後始末用（1回限りの手動実行）。
// 「請求書取込済」ラベルが569スレッドに付いたまま残っており、このままだと本物の請求書に
// 「請求書」ラベルを付けても「取込済」判定で除外されてしまうため、ラベルを削除→空で作り直す
// （Gmailはラベルを削除すると全メッセージから一括で外れる。メール自体は削除されない）。
// 役目を終えたら削除してよい関数。
function resetProcessedLabel_oneOff() {
  var old = GmailApp.getUserLabelByName(PROCESSED_LABEL_NAME);
  if (old) old.deleteLabel();
  GmailApp.createLabel(PROCESSED_LABEL_NAME);
}

// 2026-08-24: 過去メールへの初回ラベル付け（1回限りの手動実行）。
// 直近90日で件名に請求書関連キーワードを含むスレッドを目視確認し（広告・お知らせ等の
// 誤検出3件は除外済み、パスワード通知メールは実務上必要なので含める＝ユーザー確認済み）、
// 「請求書」ラベルを一括で付ける。役目を終えたら削除してよい関数。
function applyInvoiceLabelBulk_oneOff() {
  var ids = [
    "1a00d9a19878573f","19ffed7481d9b977","19ff8f4a288448e1","19feb1a8259e0794","19fea07dc94f20b6",
    "19fe9ae532577b97","19fe107bb7f67158","19fd9dae72a254be","19fd9a1f10bfd17e","19fd63aba472d54c",
    "19fd623e4cdeaced","19fd6204cad692b5","19fd4a7bf7da744b","19fd4a7bd9df25fb","19fd48650b2ef62d",
    "19fd111ad5a002b3","19fcf30d5060da0d","19fcc4f3bcfbd506","19fca8b0de66b0ef","19fc66d4aee10080",
    "19fc65c83a07154f","19fc1ac4c69b3973","19fb59e2837d04ab","19f936c5d16b2bc5","19f936c484035cf4",
    "19f68fb2079ac9d2","19f634c6e9928e21","19f5978a1551dec1","19f49d32345b61e2","19f4617dc254a85a",
    "19f443d816a9b1e7","19f405747edf929d","19f3a07966b66061","19f36c54089419ac","19f36c2024b559a5",
    "19f36b5da631f1d2","19f3680988f62576","19f368092765aa95","19f34e83e202df7f","19f26fd76b8ee04c",
    "19f25f98303345b8","19f2539e08ef8894","19f1ccf6914cc365","19e26212a9770c28","19ec9741afb74922",
    "19eb668161408ba1","19eb086df91686ae","19ea5ba828e8cc35","19e9642fe1634f63",
    "19e95b2d334d43d8","19e95af4bd343286","19e906e12250bfdf","19e906ce57629ff9","19e8bd45fb1bb59d",
    "19e8bd45e393391f","19e8b1b667e18a00","19e860974ac08aef","19e82be0b6b0c603","19e8286721b3e976"
  ];
  var label = GmailApp.getUserLabelByName(SOURCE_LABEL_NAME) || GmailApp.createLabel(SOURCE_LABEL_NAME);
  var okCount = 0, ngIds = [];
  for (var i = 0; i < ids.length; i++) {
    try {
      var thread = GmailApp.getThreadById(ids[i]);
      if (!thread) { ngIds.push(ids[i]); continue; }
      thread.addLabel(label);
      okCount++;
    } catch (e) {
      console.error("label failed: " + ids[i] + " " + e);
      ngIds.push(ids[i]);
    }
  }
  console.log("ラベル付け完了: " + okCount + "/" + ids.length + (ngIds.length ? "  失敗: " + ngIds.join(",") : ""));
}

// 2026-08-24: 添付の取りこぼし修正（includeInlineImages:false→true）を既存の取込済みメールにも
// 適用するための再スキャン（1回限りの手動実行）。「請求書」ラベルが付いた全メールを対象に
// もう一度送信し直すが、Edge Function側が「既に登録済み・添付0件・今回添付あり」の場合だけ
// 追加保存する自己修復方式になっているため、正常に添付がある分は変更されず安全に再実行できる。
// 「請求書取込済」ラベルの有無は見ない（既に付いていても対象にする）
function resyncAllLabeledAttachments_oneOff() {
  var threads = GmailApp.search('label:' + SOURCE_LABEL_NAME, 0, 200);
  var okCount = 0, ngCount = 0;
  for (var t = 0; t < threads.length; t++) {
    var messages = threads[t].getMessages();
    for (var m = 0; m < messages.length; m++) {
      try {
        if (postMessage_(threads[t], messages[m])) okCount++; else ngCount++;
      } catch (e) {
        console.error("resync failed: " + e);
        ngCount++;
      }
    }
  }
  console.log("再スキャン完了: 成功" + okCount + "件 失敗" + ngCount + "件");
}

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
    var sentId = sendReply_(body.thread_id, body.body);
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
    var info = fetchEmailInfo_(ob.email_id);
    if (!info) { console.error("invoice outbox: email not found " + ob.email_id); return; }
    var sentId = sendReply_(info.gmail_thread_id, ob.body_text);
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
