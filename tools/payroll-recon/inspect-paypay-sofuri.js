#!/usr/bin/env node
'use strict';
// PayPay 銀行（BA-PLUS）の「総合振込（WEB総振）」の画面の構造を、伏せ字で記録するための確認用スクリプト（下書き・2026-11-13）。
//
//   node inspect-paypay-sofuri.js <A|B>
//
// ■ このスクリプトがすること
//   ・専用プロファイル（ns-daily-import の profiles/paypayA または paypayB）でブラウザを開き、ログイン画面を表示する。
//   ・そのあとは、2 秒ごとに「いま開いている画面の構造」を読んで、伏せ字にしてから記録するだけ。
// ■ このスクリプトがしないこと（しない作りにしてある）
//   ・ボタンやリンクを押さない。文字を入力しない。画面を進めない（操作は、すべて人がする）。
//   ・ID・パスワード・.env を読まない（config.js も読み込まない）。入力欄の値を読まない。
//   ・画面の写真・HTML を保存しない。
// ■ 記録に残すもの（すべて伏せ字にしてから）
//   ・URL（? より後ろは捨てる）・画面のタイトル・見出し・ボタンとリンクの文字・入力欄の種類と名前（値は読まない）
//   ・表は「見出しの行」と「データの行の型」（例: 日付／数字7桁／カナ／金額）と行の数だけ。
//     ただし「状態」「結果」などの列は、状態の言葉を知るために文字を残す（数字・金額・カナは伏せる）。
//   ・4 桁以上の数字 → ＊数字、金額 → ＊金額、カタカナ（画面の決まり文句以外）→ カナ、「〜様」「株式会社〜」→ ＊名前。
//   ・ダウンロードしたファイルは、リポジトリの外（本人だけが読めるフォルダ）に置き、種類・大きさ・ハッシュ（と CSV の列の型）だけを記録して、すぐ消す。
//     （KEEP_DOWNLOADS=1 を付けたときだけ、ファイルを残す。確かめ終わったら人が消す）
// ■ 記録の場所: ~/.ns-payroll-inspect/paypay-sofuri-inspect-<paypayA|paypayB>.jsonl（本人だけが読める）
//
// 既存の inspect-paypay.js（入出金明細のときの確認用）を土台にしている。違い: 値を読まない・伏せ字・表は型だけ・ダウンロードを残さない。

const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');

const BASE = process.env.NS_DAILY_IMPORT_DIR || '/Users/mirai/ns-daily-import';
const LOGIN_URL = 'https://login.paypay-bank.co.jp/wctx/BALoginAction.do';   // 既存の config.js の PAYPAY_LOGIN_URL の既定値と同じ（config.js は読み込まない）
const key = String(process.argv[2] || '').toUpperCase();
if (key !== 'A' && key !== 'B') {
  console.error('使い方: node inspect-paypay-sofuri.js <A|B>   （A=paypayA のプロファイル／B=paypayB のプロファイル）');
  process.exit(2);
}
const profileKey = key === 'B' ? 'paypayB' : 'paypayA';
const PROFILE_DIR = path.join(BASE, 'profiles', profileKey);
const OUT_DIR = process.env.SOFURI_INSPECT_DIR || path.join(os.homedir(), '.ns-payroll-inspect');
const DL_DIR = path.join(OUT_DIR, 'downloads');
const LOG = path.join(OUT_DIR, 'paypay-sofuri-inspect-' + profileKey + '.jsonl');
const KEEP_DOWNLOADS = process.env.KEEP_DOWNLOADS === '1';

// 毎日のロボット（A=14:00・B=14:15）と同じプロファイルを使うので、その前後は動かさない
(function timeGuard() {
  const d = new Date();
  const hm = d.getHours() * 60 + d.getMinutes();
  if (hm >= 13 * 60 + 45 && hm <= 14 * 60 + 40 && process.env.FORCE !== '1') {
    console.error('13:45〜14:40 は、毎日の入出金明細のロボットと重なるため、このスクリプトは動かしません。時間をずらしてください。');
    process.exit(2);
  }
})();
if (!fs.existsSync(PROFILE_DIR)) {
  console.error('プロファイルのフォルダが見つかりません: ' + PROFILE_DIR + '\n（ns-daily-import の場所が違うときは、NS_DAILY_IMPORT_DIR で指定してください）');
  process.exit(2);
}
let chromium;
try {
  ({ chromium } = require(require.resolve('playwright', { paths: [BASE] })));
} catch (e) {
  console.error('playwright が見つかりません（' + BASE + ' の node_modules を使います）: ' + e.message);
  process.exit(2);
}

// ---------- 伏せ字の決まり（ページの中と、こちら側の両方で同じものを使う） ----------
const MASK_CFG = {
  // 画面の決まり文句として残してよいカタカナ（これ以外のカタカナの並びは「カナ」に置きかえる）
  uiKana: ['ログイン', 'ログアウト', 'メニュー', 'ダウンロード', 'アップロード', 'データ', 'ファイル', 'エラー', 'ステータス', 'トークン', 'パスワード', 'ページ',
    'サービス', 'メッセージ', 'ボックス', 'コード', 'キャンセル', 'デビット', 'バランス', 'インボイス', 'メモ', 'セキュリティ', 'カード', 'キャッシュ', 'メール', 'アドレス',
    'マニュアル', 'ヘルプ', 'ボタン', 'リスト', 'チェック', 'フォーマット', 'クリア', 'トップ', 'ホーム', 'ビジネス', 'ローン', 'カスタマー', 'センター', 'タイプ', 'ウェルカム',
    'マイナンバー', 'ワンタイム', 'ペイジー', 'フォーム', 'プライバシー', 'ポリシー', 'システム', 'メンテナンス', 'ユーザー', 'グループ', 'テンプレート', 'コメント', 'カレンダー',
    'プレビュー', 'ソート', 'オンライン', 'バンキング', 'アカウント', 'レコード', 'ヘッダー', 'トレーラー', 'エンド', 'スキップ', 'コピー', 'リセット', 'ウィンドウ', 'アイコン', 'カナ'],
  // 表のデータの行の中でも、文字のまま残してよい言葉（操作・状態・種別の言葉。人や口座を表さない）
  uiWords: ['照会', '詳細', '明細', '結果', '選択', '取消', '取消し', '修正', '削除', '印刷', 'PDF', 'CSV', '次へ', '戻る', '表示', '検索', '確認', '参照', '再利用', '複写',
    '成功', '正常', '完了', '済', '未', '処理済', '処理済み', '処理中', '受付', '受付済', '受付済み', '受付中', '承認待ち', '承認済', '承認済み', '予約中', '予約済', '予約済み',
    '不能', '振込不能', '振込済', '振込済み', 'エラー', '失敗', '返却', '資金返却', '組戻', '組戻し', '依頼中', '期限切れ', '普通', '当座', '貯蓄', '総合振込', '給与振込', '先方負担', '当方負担'],
  // この言葉が見出しに入る列（行）は、状態の言葉を知るために文字を残す（数字・金額・カナは伏せる）
  statusCol: '状態|結果|ステータス|状況|種別|科目|区分|取扱|エラー',
  // 画面のどこかにあるかどうかだけを記録する言葉（文字そのものは記録しない）
  words: ['受付番号', '振込指定日', '指定日', '合計金額', '合計件数', '件数', '手数料', '処理結果', '振込結果', '状態', 'ステータス', '受付', '承認待ち', '承認済', '予約中', '処理中',
    '処理済', '完了', '不能', '振込不能', 'エラー', '組戻', '資金返却', 'PDF', 'CSV', 'ダウンロード', '印刷', 'ワンタイム', 'トークン', '認証', '合言葉', '利用者', '管理者', '承認者',
    '振込依頼', '振込データ', '照会', '履歴', '明細', '受取人', '依頼人', '代表口座', '振込専用', '該当', 'ございません', 'タイムアウト'],
  // この言葉がボタン・リンク・見出しにある画面は「押してはいけないボタンがあるかもしれない画面」として注意を出す
  caution: '振込依頼|承認|実行|予約|登録|変更|取消|削除|送信|組戻',
};

// 伏せ字の関数をまとめて作る（外の変数を使わない書き方にしてある＝ページの中へそのまま渡せる）
function makeMaskers(cfg) {
  const UI_WORDS = new Set(cfg.uiWords);
  const kanaWords = cfg.uiKana.slice().sort(function (a, b) { return b.length - a.length; });
  const STATUS_COL = new RegExp(cfg.statusCol);
  const KANA_RUN = /[ァ-ヺー]{2,}/g;
  const nfkc = function (s) { return String(s == null ? '' : s).normalize('NFKC').replace(/\s+/g, ' ').trim(); };
  // カタカナの並びが、画面の決まり文句だけでできているか
  const isUiKana = function (run) {
    let i = 0;
    while (i < run.length) {
      let hit = null;
      for (let k = 0; k < kanaWords.length; k++) { if (run.startsWith(kanaWords[k], i)) { hit = kanaWords[k]; break; } }
      if (!hit) return false;
      i += hit.length;
    }
    return run.length > 0;
  };
  // 文字を残すときの伏せ字（見出し・メニュー・ボタン用）
  const maskText = function (s, max) {
    let t = nfkc(s);
    if (!t) return '';
    if (/様$/.test(t) || /(株式会社|有限会社|合同会社|\(株\)|\(有\)|\(同\))/.test(t)) return '＊名前';
    t = t.replace(/¥\s?\d[\d,]*/g, '＊金額').replace(/\d[\d,]*\s?円/g, '＊金額').replace(/\d{1,3}(?:,\d{3})+/g, '＊金額').replace(/\d{4,}/g, '＊数字');
    t = t.replace(KANA_RUN, function (m) { return isUiKana(m) ? m : 'カナ'; });
    return t.slice(0, max || 40);
  };
  // 文字を残さないときの「型」（表のデータ用）
  const typeOf = function (s) {
    const t = nfkc(s);
    if (!t) return '空';
    if (UI_WORDS.has(t)) return 'UI:' + t;
    if (/^\d{4}[\/.\-年]\d{1,2}[\/.\-月]\d{1,2}日?( ?\(.\))?$/.test(t)) return '日付';
    if (/^\d{1,2}[\/月]\d{1,2}日?$/.test(t)) return '月日';
    if (/^\d{1,2}:\d{2}(:\d{2})?$/.test(t)) return '時刻';
    if (/^¥? ?\d{1,3}(,\d{3})+ ?円?$/.test(t) || /^¥ ?\d+$/.test(t) || /^\d+ ?円$/.test(t)) return '金額';
    if (/^\d+$/.test(t)) return '数字' + t.length + '桁';
    if (/^[\d\-]+$/.test(t)) return '数字とハイフン' + t.replace(/\D/g, '').length + '桁';
    if (/[*＊●•×]/.test(t) && /^[*＊●•×xX\d\- ]+$/.test(t)) { const n = t.replace(/\D/g, '').length; return '伏せ字' + (n ? '+数字' + n + '桁' : ''); }
    if (/[ァ-ヺ]/.test(t) && /^[ァ-ヺー ().\-\/A-Z0-9]+$/.test(t)) return isUiKana(t) ? 'UI:' + t : 'カナ';
    const kinds = [];
    if (/[一-鿿]/.test(t)) kinds.push('漢字');
    if (/[ぁ-ゖ]/.test(t)) kinds.push('かな');
    if (/[ァ-ヺ]/.test(t)) kinds.push('カナ');
    if (/[A-Za-z]/.test(t)) kinds.push('英字');
    if (/\d/.test(t)) kinds.push('数字');
    return (kinds.join('+') || '記号') + t.length + '字';
  };
  // 属性（name・id・href・onclick・ファイル名）用: 日本語の入った引数・日本語の並び・4 桁以上の数字を伏せる（属性に日本語の名前が入っていても持ち出さない）
  const maskAttr = function (s, max) {
    return String(s == null ? '' : s).replace(/(['"])[^'"]*[^\x00-\x7F][^'"]*\1/g, "'*'").replace(/[^\x00-\x7F]+/g, '*').replace(/[0-9]{4,}/g, '*').slice(0, max || 80);
  };
  return { nfkc: nfkc, isUiKana: isUiKana, maskText: maskText, typeOf: typeOf, maskAttr: maskAttr, UI_WORDS: UI_WORDS, STATUS_COL: STATUS_COL };
}

// ---------- ページの中で動く部分（構造を読んで、伏せ字にしたものだけを返す。何も押さない・何も書きかえない） ----------
function pageSnapshot(cfg, makeMaskersFn) {
  const M = makeMaskersFn(cfg);
  const q = function (sel) { return Array.prototype.slice.call(document.querySelectorAll(sel)); };
  const CAUTION = new RegExp(cfg.caution);
  // 「データの表」（見出しのセル th がある表）の中のセルかどうか。見た目を整えるだけの表（th なし）は、データの表として扱わない
  const inDataCell = function (el) {
    const td = el.closest('td');
    if (!td) return false;
    const tb = td.closest('table');
    return !!(tb && tb.querySelector('th'));
  };
  const clickText = function (el) {
    const raw = el.textContent || el.value || el.getAttribute('alt') || el.getAttribute('title') || '';
    if (!inDataCell(el)) return M.maskText(raw, 40);
    const t = M.nfkc(raw);
    if (M.UI_WORDS.has(t) || M.isUiKana(t)) return t;
    return M.typeOf(t);   // データの表の中のリンク・ボタンは、決まり文句以外は型だけ
  };
  const pathOnly = function (u) {
    try { const x = new URL(u, location.href); return M.maskAttr(x.origin + x.pathname, 120); } catch (e) { return ''; }
  };
  const hrefOf = function (el) {
    const h = el.getAttribute('href') || '';
    if (!h) return '';
    if (/^javascript:/i.test(h)) return M.maskAttr(h, 80);
    if (h.charAt(0) === '#') return M.maskAttr(h, 40);
    return pathOnly(h);
  };

  const inputs = q('input,select,textarea').slice(0, 80).map(function (el) {
    const tag = el.tagName.toLowerCase();
    const type = (el.getAttribute('type') || (tag === 'select' ? 'select' : tag)).toLowerCase();
    const o = { tag: tag, type: type, name: M.maskAttr(el.name || '', 40), id: M.maskAttr(el.id || '', 40) };
    // 値そのものは読まない。ラジオ・チェックだけ、値の「型」（例: 数字10桁）を残す
    if (type === 'radio' || type === 'checkbox') { o.valueShape = M.typeOf(el.value || ''); o.checked = !!el.checked; }
    if (tag === 'select') { o.options = el.options ? el.options.length : 0; }
    if (type === 'hidden') { delete o.id; }
    return o;
  });

  const clickables = q('a,button,input[type=submit],input[type=button],input[type=image],area').slice(0, 120).map(function (el) {
    return {
      tag: el.tagName.toLowerCase(), text: clickText(el), id: M.maskAttr(el.id || '', 40), name: M.maskAttr(el.getAttribute('name') || '', 40),
      href: hrefOf(el), onclick: M.maskAttr(el.getAttribute('onclick') || '', 80), inData: inDataCell(el),
    };
  }).filter(function (c) { return c.text || c.id || c.href || c.onclick; });

  const headings = q('h1,h2,h3,h4,caption,legend,label,dt,th').slice(0, 80).map(function (el) { return M.maskText(el.textContent, 30); }).filter(Boolean);

  const tables = q('table').slice(0, 20).map(function (tb) {
    const rows = Array.prototype.slice.call(tb.rows || []);
    if (!rows.length || !tb.querySelector('th')) return null;   // 見出しの無い表（見た目用）は記録しない
    const cellsOf = function (r) { return Array.prototype.slice.call(r.cells || []); };
    let hi = -1;
    for (let i = 0; i < rows.length; i++) { if (cellsOf(rows[i]).length && cellsOf(rows[i]).every(function (c) { return c.tagName === 'TH'; })) { hi = i; break; } }
    const headers = hi >= 0 ? cellsOf(rows[hi]).slice(0, 25).map(function (c) { return M.maskText(c.textContent, 20); }) : [];
    const dataRows = rows.filter(function (r, i) { return i !== hi && cellsOf(r).some(function (c) { return c.tagName === 'TD'; }); });
    return {
      rows: rows.length, dataRows: dataRows.length, nested: !!tb.querySelector('table'), headers: headers,
      sample: dataRows.slice(0, 3).map(function (r) {
        const cs = cellsOf(r).slice(0, 25);
        const rowTh = cs.filter(function (c) { return c.tagName === 'TH'; })[0];
        const rowLabel = rowTh ? M.maskText(rowTh.textContent, 20) : '';
        return cs.map(function (c, ci) {
          let v;
          if (c.tagName === 'TH') v = '見出し:' + M.maskText(c.textContent, 20);
          else if (M.STATUS_COL.test(headers[ci] || '') || M.STATUS_COL.test(rowLabel)) v = '文字:' + M.maskText(c.textContent, 20);
          else v = M.typeOf(c.textContent);
          if (c.querySelector('a,button,input[type=button],input[type=submit],input[type=image]')) v += '+ボタン';
          if (c.querySelector('input[type=radio],input[type=checkbox]')) v += '+選択';
          return v;
        });
      }),
    };
  }).filter(Boolean);

  const forms = q('form').slice(0, 10).map(function (f) {
    return {
      name: M.maskAttr(f.getAttribute('name') || '', 30), method: (f.getAttribute('method') || '').toLowerCase(), action: pathOnly(f.getAttribute('action') || ''),
      hidden: Array.prototype.slice.call(f.querySelectorAll('input[type=hidden]')).slice(0, 40).map(function (h) { return M.maskAttr(h.name || '', 30); }),
    };
  });

  const body = M.nfkc(document.body ? document.body.innerText : '');
  const words = cfg.words.filter(function (w) { return body.indexOf(w) >= 0; });   // ある・なしだけ（文字そのものは持ち出さない）
  const caution = clickables.some(function (c) { return CAUTION.test(c.text); }) || headings.some(function (h) { return CAUTION.test(h); });

  return {
    url: pathOnly(location.href), title: M.maskText(document.title, 60), inputs: inputs, clickables: clickables, headings: headings,
    tables: tables, forms: forms, words: words, caution: caution,
  };
}

// ---------- こちら側（記録・ダウンロードの扱い） ----------
const M = makeMaskers(MASK_CFG);
let lateRedactions = 0;
let snapshotCount = 0;
let downloadCount = 0;

function hhmmss() {
  const d = new Date();
  const p = function (n) { return String(n).padStart(2, '0'); };
  return p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
}
// 記録に足す。足す前にもう一度、4 桁以上の数字が残っていないかを確かめて、残っていれば伏せる（二重の守り）
function append(obj) {
  try {
    obj.at = hhmmss();
    let line = JSON.stringify(obj);
    const scrubbed = line.replace(/[0-9０-９]{4,}/g, '＊');
    if (scrubbed !== line) { lateRedactions += 1; line = scrubbed; }
    fs.appendFileSync(LOG, line + '\n', { mode: 0o600 });
  } catch (e) { /* 記録の失敗で止めない */ }
}
// ハッシュは、数字を英字に置きかえて残す（同じファイルかどうかの見分けには十分。4 桁以上の数字の伏せ字にも当たらない）
function lettersOnlyHash(buf) {
  return crypto.createHash('sha256').update(buf).digest('hex').replace(/[0-9]/g, function (d) { return 'ghijklmnop'[Number(d)]; });
}
function kindOf(buf, ext) {
  if (buf.length >= 4 && buf.slice(0, 4).toString('latin1') === '%PDF') return 'PDF';
  if (buf.length >= 2 && buf[0] === 0x50 && buf[1] === 0x4b) return 'ZIP または Excel';
  if (ext === '.csv' || ext === '.txt' || ext === '.tsv') return 'CSV・テキスト';
  let ctrl = 0;
  const n = Math.min(buf.length, 2000);
  for (let i = 0; i < n; i++) { const b = buf[i]; if (b < 9 || (b > 13 && b < 32)) ctrl++; }
  return ctrl === 0 && n > 0 ? 'CSV・テキスト' : 'その他';
}
// CSV の形だけ（行の数・列の数・1 行目の見出し・2〜3 行目の型）。中身の文字は記録しない
function csvShape(buf) {
  try {
    let text;
    if (buf.length >= 3 && buf[0] === 0xef && buf[1] === 0xbb && buf[2] === 0xbf) text = new TextDecoder('utf-8').decode(buf);
    else text = new TextDecoder('shift_jis').decode(buf);
    const lines = text.split(/\r\n|\n|\r/).filter(function (l) { return l.length > 0; });
    const split = function (l) { return l.split(',').map(function (c) { return c.replace(/^"|"$/g, ''); }); };
    const first = lines.length ? split(lines[0]) : [];
    // 1 行目が「見出しらしい」（数字だけの列が無い）ときだけ、伏せ字にして残す。そうでなければ型だけ
    const looksHeader = first.length > 0 && first.every(function (c) { return !/^[\d,.\-¥ ]*$/.test(M.nfkc(c)) || M.nfkc(c) === ''; });
    return {
      lines: lines.length,
      columns: lines.slice(0, 5).map(function (l) { return split(l).length; }),
      header: looksHeader ? first.slice(0, 30).map(function (c) { return M.maskText(c, 20); }) : null,
      sample: lines.slice(looksHeader ? 1 : 0, looksHeader ? 3 : 2).map(function (l) { return split(l).slice(0, 30).map(function (c) { return M.typeOf(c); }); }),
    };
  } catch (e) { return { error: 'CSV の形を読めませんでした' }; }
}

fs.mkdirSync(OUT_DIR, { recursive: true, mode: 0o700 });
fs.mkdirSync(DL_DIR, { recursive: true, mode: 0o700 });
try { fs.chmodSync(OUT_DIR, 0o700); fs.chmodSync(DL_DIR, 0o700); } catch (e) { /* 無視 */ }
fs.writeFileSync(LOG, '', { mode: 0o600 });   // 前回の記録は消して、新しく始める

(async function main() {
  const ctx = await chromium.launchPersistentContext(PROFILE_DIR, {
    headless: false,
    viewport: { width: 1440, height: 900 },
    acceptDownloads: true,
    args: ['--disable-blink-features=AutomationControlled'],
  });
  const page = ctx.pages()[0] || (await ctx.newPage());

  let dlSeq = 0;
  function hookDownload(p) {
    p.on('download', async function (d) {
      dlSeq += 1;
      let fp = null;
      try {
        const sug = d.suggestedFilename() || '';
        const ext = (path.extname(sug) || '').toLowerCase().replace(/[^.a-z0-9]/g, '').slice(0, 6);
        fp = path.join(DL_DIR, 'dl-' + Date.now() + '-' + dlSeq + ext);
        await d.saveAs(fp);
        try { fs.chmodSync(fp, 0o600); } catch (e) { /* 無視 */ }
        const buf = fs.readFileSync(fp);
        const kind = kindOf(buf, ext);
        const rec = { event: 'download', kind: kind, size: buf.length.toLocaleString('en-US') + ' B', hash: lettersOnlyHash(buf), ext: ext, name: M.maskAttr(sug, 60) };
        if (kind === 'CSV・テキスト') rec.csv = csvShape(buf);
        append(rec);
        downloadCount += 1;
        console.log('⬇ ダウンロードを記録しました（' + kind + '・' + rec.size + '）' + (KEEP_DOWNLOADS ? ' ファイル: ' + fp : ' ※ファイルは残していません'));
      } catch (e) {
        append({ event: 'download_error', error: M.maskAttr(e && e.message, 80) });
      } finally {
        if (fp && !KEEP_DOWNLOADS) { try { fs.unlinkSync(fp); } catch (e) { /* 無視 */ } }
      }
    });
  }
  ctx.on('page', function (p) { hookDownload(p); });
  ctx.pages().forEach(hookDownload);

  console.log('\n=== PayPay 銀行 総合振込の画面の確認（プロファイル: ' + profileKey + '） ===');
  console.log('このスクリプトは、何も押しません・何も入力しません。操作は、すべて人がします。');
  console.log('★ 振込の依頼・承認・予約・取消・振込先の変更のボタンは、押さないでください（見るだけ・照会だけ）。');
  console.log('記録の場所: ' + LOG);
  console.log('終わったら、画面の「ログアウト」を押してから、ブラウザを閉じてください。\n');

  // このスクリプトがする操作は、これ 1 つだけ（ログイン画面を開く）
  await page.goto(LOGIN_URL).catch(function (e) { console.log('ログイン画面を開けませんでした: ' + e.message); });

  // 画面の構造を、ページの中で伏せ字にしてから受け取る式（関数の中身を文字として渡すだけ。ページの中で eval は使わない）
  const expr = '(' + pageSnapshot.toString() + ')(' + JSON.stringify(MASK_CFG) + ',' + makeMaskers.toString() + ')';
  const lastSig = new Map();
  let lastShown = '';
  let busy = false;
  const timer = setInterval(async function () {
    if (busy) return;
    busy = true;
    try {
      const pages = ctx.pages();
      for (let pi = 0; pi < pages.length; pi++) {
        const frames = pages[pi].frames();
        for (let fi = 0; fi < frames.length; fi++) {
          let snap = null;
          try { snap = await frames[fi].evaluate(expr); } catch (e) { snap = null; }   // 画面の切り替わり中は読めないことがある
          if (!snap || !snap.url || /^about:/.test(snap.url)) continue;
          const sig = crypto.createHash('sha1').update(JSON.stringify(snap)).digest('hex');
          const k = pi + ':' + fi;
          if (lastSig.get(k) === sig) continue;   // 変わっていない画面は、くり返し記録しない
          lastSig.set(k, sig);
          append(Object.assign({ event: 'snapshot', page: pi, frame: fi }, snap));
          snapshotCount += 1;
          const shown = snap.url + ' ｜ ' + snap.title;
          if (shown !== lastShown) { lastShown = shown; console.log('→ ' + shown); }
          if (snap.caution) console.log('   ⚠ この画面には、振込・承認・取消などのボタンがあるかもしれません。押さないでください（見るだけ）。');
        }
      }
    } catch (e) { /* 無視 */ } finally { busy = false; }
  }, 2000);

  await new Promise(function (resolve) { ctx.on('close', resolve); });
  clearInterval(timer);

  // 終わりの確かめ: 記録に、4 桁以上の数字が残っていないか
  let leftover = 0;
  try { leftover = (fs.readFileSync(LOG, 'utf8').match(/[0-9０-９]{4,}/g) || []).length; } catch (e) { leftover = -1; }
  console.log('\nブラウザを閉じました。記録を保存しました: ' + LOG);
  console.log('  画面の記録: ' + snapshotCount + ' 回 ／ ダウンロードの記録: ' + downloadCount + ' 件 ／ 書き出す直前に伏せた行: ' + lateRedactions + ' 行');
  console.log('  記録に残っている 4 桁以上の数字: ' + (leftover === 0 ? '0 件（OK）' : leftover + ' 件（★この記録は、だれにも渡さないでください）'));
  if (KEEP_DOWNLOADS) console.log('  ★ ダウンロードしたファイルが残っています: ' + DL_DIR + ' （確かめ終わったら消してください）');
  process.exit(0);
})().catch(function (e) {
  console.error('エラーで止まりました: ' + (e && e.message));
  process.exit(1);
});
