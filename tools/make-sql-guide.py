#!/usr/bin/env python3
"""SQL Editor 用の「小学生でもできる」手順書HTMLを作る（担当F・2026-10-17）。

使い方:
  tools/make-sql-guide.py --title "題名" --sql path/to/migration.sql \
      --check "確認1の名前::select ..." --check "確認2の名前::select ..." \
      --expect "確認1の見方（表の項目と出てほしい数字を1行ずつ）" ... --out guide.html

★コピーボタンの作り（2026-10-17 ユーザー指摘「青いボタンを押してもコピーされなかった」の対策）:
  - SQLは <pre> ではなく <textarea readonly> に入れる（選択状態にしてから execCommand('copy') を最初に試す。
    アプリ内の埋め込み表示（sandbox）では navigator.clipboard が使えないことがあるため）
  - 失敗したら「枠をクリック→⌘+A→⌘+C」を画面に出し、枠の全文を選択済みにする（枠をクリックしても全選択される）
  - ページ先頭に「コピーできない時」の説明を常に出す
"""
import argparse, html

def esc(s): return html.escape(s)

def box(i, title, code):
    return f'''<div class="box"><div class="bh"><b>{esc(title)}</b><button class="copy" onclick="cp('{i}',this)">📋 コピー</button></div>
<textarea id="{i}" readonly spellcheck="false" onclick="this.select()">{esc(code)}</textarea>
<div class="cpmsg" id="{i}_m"></div></div>'''

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--title', required=True)
    ap.add_argument('--sql', required=True)
    ap.add_argument('--check', action='append', default=[], help='"名前::SQL"')
    ap.add_argument('--intro', default='')
    ap.add_argument('--expect', action='append', default=[], help='確認の見方（HTML可・確認の順に1つずつ）')
    ap.add_argument('--out', required=True)
    ap.add_argument('--url', default='https://supabase.com/dashboard/project/uuvsxzhpxtghojoubjcc/sql/new')
    a = ap.parse_args()
    sql = open(a.sql, encoding='utf-8').read()
    parts = [f'''<!DOCTYPE html><html lang="ja"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{esc(a.title)}</title>
<style>body{{font-family:-apple-system,"Hiragino Sans",sans-serif;max-width:860px;margin:0 auto;padding:20px 16px 80px;line-height:1.8;color:#26221e;background:#faf9f6}}
h1{{font-size:22px}}h2{{font-size:18px;margin-top:30px;border-left:6px solid #1f5fbf;padding-left:10px}}
.step{{background:#fff;border:1px solid #e7e3dc;border-radius:12px;padding:12px 18px;margin:12px 0}}
.num{{display:inline-block;background:#1f5fbf;color:#fff;border-radius:99px;width:26px;height:26px;text-align:center;line-height:26px;font-weight:700;margin-right:8px}}
.ok{{background:#e9f6ef;border:1px solid #bfe3cd;border-radius:10px;padding:8px 14px;margin:8px 0}}.ng{{background:#fdecec;border:1px solid #f1bcbc;border-radius:10px;padding:8px 14px;margin:8px 0}}.warn{{background:#fff7dc;border:1px solid #ecd48a;border-radius:10px;padding:8px 14px;margin:8px 0}}
.box{{border:2px solid #1f5fbf;border-radius:12px;margin:12px 0;overflow:hidden;background:#fff}}.bh{{display:flex;justify-content:space-between;align-items:center;background:#e8f0fd;padding:8px 12px}}
.copy{{background:#1f5fbf;color:#fff;border:0;border-radius:8px;padding:9px 18px;font-size:15px;font-weight:700;cursor:pointer}}.copy.done{{background:#2e7d32}}
textarea{{display:block;width:100%;height:200px;border:0;border-top:1px solid #cfd9ee;padding:10px 12px;font-size:11px;line-height:1.5;font-family:ui-monospace,Menlo,monospace;background:#fbfbfb;color:#26221e;resize:vertical}}
.cpmsg{{font-size:13px;padding:0 12px}}.cpmsg.bad{{padding:8px 12px;background:#fdecec;color:#a02020}}
table{{border-collapse:collapse;margin:8px 0}}td,th{{border:1px solid #d8d3ca;padding:5px 12px;font-size:14px}}th{{background:#f1efe9}}
a.big{{display:inline-block;background:#1f5fbf;color:#fff;text-decoration:none;padding:10px 18px;border-radius:10px;font-weight:700}}kbd{{background:#eee;border:1px solid #ccc;border-radius:4px;padding:1px 6px;font-size:13px}}</style></head><body>
<h1>📘 {esc(a.title)}</h1>
{a.intro}
<div class="warn">📋 <b>「コピー」ボタンが効かない時</b>：下の枠の中を<b>クリック</b>（全部が青く選ばれます）→ <kbd>⌘</kbd>+<kbd>C</kbd>。そのあと SQL Editor で <kbd>⌘</kbd>+<kbd>V</kbd> です。</div>
<h2>1. SQL Editor を開く</h2>
<div class="step"><span class="num">1</span><a class="big" href="{esc(a.url)}" target="_blank">🔗 SQL Editor を開く</a></div>
<h2>2. 実行する</h2>
<div class="step"><span class="num">2</span>下の<b>「📋 コピー」</b>を押します（効かない時は枠をクリック→⌘+C）。</div>
{box('sql', '実行するSQL', sql)}
<div class="step"><span class="num">3</span>SQL Editor の「＋ New query」で<b>まっさらな入力欄</b>を出し、クリック → <kbd>⌘</kbd>+<kbd>V</kbd>（貼り付け）。</div>
<div class="step"><span class="num">4</span>右下の緑の <b>Run</b>。黄色い「Potential issue」画面が出たら<b>「Run this query」</b>（決まりの注意です）。</div>
<div class="step"><div class="ok">✅ 「Success. No rows returned」なら成功です。</div><div class="ng">❌ 赤い文字（Error）が出たら、そこで止めて<b>スクリーンショット</b>を私に送ってください。</div></div>''']
    if a.check:
        parts.append('<h2>3. 確認</h2>')
        n = 5
        for k, c in enumerate(a.check):
            name, _, q = c.partition('::')
            parts.append(f'<div class="step"><span class="num">{n}</span>「＋ New query」→ 下の<b>{esc(name)}</b>をコピー → 貼り付け → Run。</div>')
            parts.append(box(f'chk{k+1}', name, q))
            if k < len(a.expect): parts.append(f'<div class="step">{a.expect[k]}</div>')
            n += 1
    parts.append('<h2>おわったら</h2><div class="step">私に <b>「適用できた」</b> と送ってください。うまくいかなかった時は、<b>赤い文字（Error）のスクリーンショット</b>を送ってください。</div>')
    parts.append('''<script>
function cp(id,btn){
  var ta=document.getElementById(id), msg=document.getElementById(id+'_m');
  var done=function(){btn.textContent='✅ コピーしました';btn.classList.add('done');msg.className='cpmsg';msg.textContent='';setTimeout(function(){btn.textContent='📋 コピー';btn.classList.remove('done')},2500)};
  var fail=function(){ta.focus();ta.select();msg.className='cpmsg bad';msg.textContent='自動でコピーできませんでした。枠は全部選ばれています → ⌘+C を押してください（そのあと SQL Editor で ⌘+V）。'};
  ta.focus(); ta.select(); ta.setSelectionRange(0, ta.value.length);
  var ok=false; try{ ok=document.execCommand('copy'); }catch(e){}
  if(ok){ done(); return; }
  if(navigator.clipboard && navigator.clipboard.writeText){ navigator.clipboard.writeText(ta.value).then(done, fail); } else { fail(); }
}
</script></body></html>''')
    open(a.out, 'w', encoding='utf-8').write('\n'.join(parts))
    print('wrote', a.out)

if __name__ == '__main__':
    main()
