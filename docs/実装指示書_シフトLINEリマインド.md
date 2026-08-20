# 実装指示書: シフト未提出者へのLINEリマインド（機能④の4f）

対象読者: この続きを実装する実行スレッド。まず`docs/引継ぎ書_2026-08-20_シフトLINEリマインド続き.md`を読んでから着手すること。仕様の正=`docs/要件定義書.md`、シフト全体の設計=`docs/シフト打刻_設計書.md`。

**現在の状態**: `public.users`へのALTER（`line_code`/`line_linked_at`列追加）は**実行済み**。それ以外（新規RPC・新規テーブル・`line-webhook`改修・nippo側UI）は**未着手**。このスレッドから続ける。

---

## 0. 前提として理解しておくこと

- 求人用LINE公式アカウントを**従業員向けリマインドと共用する**ことがユーザー決定済み（別アカウントは作らない）
- 既存の応募者向けLINE連携（`applicants`テーブル・`line_intake`・`apply_line_code`等）には**絶対に手を加えない**。従業員向けは全て新規・独立した関数で作る
- 自動実行の外部cronは存在しない（`hq_generate_today()`と同じ「ページ読み込み時にチェック」方式を踏襲する）
- V1のリマインドは**締切当日のみ・1日1回**というシンプルな仕様（`sf_reminder_targets()`の実装を参照）。より丁寧な複数回リマインドは将来拡張

---

## 1. Step1: 新規RPC・新規テーブルを適用

`supabase/2026-08-20_shift_reminders_functions.sql`は書き上げ済み（`public`スキーマの新規オブジェクトのみなので、Claude自身がManagement API経由で直接実行してよい＝ユーザー確認は不要）。

```bash
PAT=$(cat ~/.config/ns-portal/supabase_pat)
REF=uuvsxzhpxtghojoubjcc
python3 -c "
import json
sql = open('/Users/mirai/Claude/ns-portal/supabase/2026-08-20_shift_reminders_functions.sql').read()
print(json.dumps({'query': sql}))
" > /tmp/payload.json
curl -s -X POST "https://api.supabase.com/v1/projects/$REF/database/query" \
  -H "Authorization: Bearer $PAT" -H "Content-Type: application/json" \
  --data-binary @/tmp/payload.json
```

実行後、`user_issue_line_code`・`user_unlink_line`・`line_intake_user`・`sf_reminder_targets`・`sf_mark_reminded`の5関数と`sf_reminder_log`テーブルができていることを確認する。

---

## 2. Step2: `line-webhook` Edge Functionのデプロイ

改修版は`supabase/functions/line-webhook/index.ts`に用意済み。**この改修は「既存の応募者向けロジックには一切触れず、2箇所だけ追加した」もの**（詳細はファイル内のコメント、および前スレッドがdiffで無変更を確認済み＝`WORKLOG.md`参照）。念のため、デプロイ前にもう一度この前提を疑ってよい（特に本番の`line-webhook`が前スレッド終了後に別の理由で更新されていないか、`GET .../functions/line-webhook`のversion番号を確認してから進めること）。

```bash
PAT=$(cat ~/.config/ns-portal/supabase_pat)
REF=uuvsxzhpxtghojoubjcc
curl -s "https://api.supabase.com/v1/projects/$REF/functions" -H "Authorization: Bearer $PAT" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); [print(f['slug'],f['version']) for f in d if f['slug']=='line-webhook']"
# version番号をメモしてから、念のためもう一度バイナリを取得してdiffし直すことを推奨
```

問題なければデプロイ:

```bash
FILE="/Users/mirai/Claude/ns-portal/supabase/functions/line-webhook/index.ts"
curl -s -X POST "https://api.supabase.com/v1/projects/$REF/functions/deploy?slug=line-webhook" \
  -H "Authorization: Bearer $PAT" \
  -F "file=@$FILE;filename=index.ts" \
  -F 'metadata={"entrypoint_path":"index.ts","verify_jwt":false};type=application/json'
```

**verify_jwt=false**にすること（LINE自体からのWebhook呼び出しはSupabaseのJWTを持たないため。既存もfalseのはず。アプリからの`push_user`アクション等は関数内部で`jwtUid(req)`により独自にログイン確認している）。

デプロイ後、**既存の応募者向け機能が壊れていないことを実機で1回は確認する**（採用管理タブから、実在または使い捨ての応募者に「テスト送信」something軽い操作でよい。本番の応募者へ余計なメッセージを送らないよう注意）。

---

## 3. Step3: nippo側UI実装

### 3.1 従業員のLINE連携画面
「⚙️設定」ページ（`nippo/index.html`の`settingsView()`あたり）に追加:
- 現在の連携状態表示（`me.line_user_id`があれば「連携済み」、無ければ未連携）
- 未連携なら「LINE連携する」ボタン→`sb.rpc("user_issue_line_code")`を呼び、返ってきた`code`と`oa`（LINE公式アカウントのbasicId）を使って、**求人用LINEの友だち追加リンク**（`https://line.me/R/ti/p/@{oa}` の形。既存の応募者側フロー`apply_line_code`の使い方を参考にする。既にコード内に類似実装がある可能性が高いので`joinView`周辺を探すこと）を案内し、「このLINEに '合言葉' をそのまま送ってください」と表示
- 連携済みなら「連携を解除する」ボタン→`sb.rpc("user_unlink_line")`

### 3.2 管理画面（シフト管理・公開画面）でのリマインド送信
`sfManageView()`（`nippo/index.html`のシフト機能）に手動トリガーボタンを追加、または`shiftView()`が呼ばれるたびに自動チェックする方式（後者が要件に近い＝`hq_generate_today`と同じ「ページを開いたら自動でチェック」）。

推奨実装（自動チェック方式）:
```js
// shiftView() の冒頭あたりで、管理者ロールの場合のみ1回だけ試みる
async function sfEnsureReminders(){
 if(!(me.is_master||["CEO","HQ","TEAM","TENCHO"].includes(me.role)))return;
 if(sessionStorage.getItem("sf_reminder_checked_"+todayStr()))return; // 同じセッション内で2回叩かない
 sessionStorage.setItem("sf_reminder_checked_"+todayStr(),"1");
 const {data:targets,error}=await sb.rpc("sf_reminder_targets");
 if(error||!targets||!targets.length)return;
 for(const t of targets){
  if(!t.line_user_id)continue; // LINE未連携の人はスキップ（送れない）
  const text=`${t.name}さん\n\nシフト提出のリマインドです。\n本日 ${t.deadline} が「${t.period_key}」期間の提出期限です。\nお手数ですが、日報アプリの📅シフトからご提出をお願いします。`;
  const {data:sess}=await sb.auth.getSession();
  const token=sess&&sess.session?sess.session.access_token:null;
  const r=await fetch(SUPA_URL+"/functions/v1/line-webhook",{method:"POST",headers:{Authorization:"Bearer "+token,"Content-Type":"application/json"},body:JSON.stringify({action:"push_user",user_id:t.user_id,text})});
  const j=await r.json().catch(()=>null);
  if(j&&j.ok)await sb.rpc("sf_mark_reminded",{p_user_id:t.user_id,p_period_key:t.period_key});
 }
}
```

**注意点**:
- `sf_reminder_targets()`はサーバー側で「締切当日かどうか」を判定して返す（締切日以外は空配列）。誰かがシフト管理画面を締切当日に一度でも開けば、その日の対象者全員に自動送信される設計
- 二重送信防止は`sf_mark_reminded`のDB側ユニーク制約（`work_date, period_key, user_id`）が最終防衛線。`sessionStorage`のチェックは無駄な問い合わせを減らすためのおまけ
- LINE未連携の人には送れない（`sf_reminder_targets`が返す`line_user_id`がnull）。この場合は管理画面の「未提出者」欄に「⚠️LINE未連携」のような表示を追加すると親切（必須ではない）

---

## 4. Step4: 実機E2E（必須）

D-1〜D-4式のテストを実施し、`WORKLOG.md`に記録すること:

1. 使い捨てテストユーザー（TENCHO役、実店舗の`user_stores`に紐付け）を作成
2. **実際にそのテストユーザーで「LINE連携する」を押し、実際のLINEアプリ（またはLINE公式アカウントとのやりとり）で合言葉を送って連携が完了することを確認**（本物のLINEとのやりとりになるため、テスト用の一時的な会話がLINE公式アカウント側のトーク履歴に残ることは許容する。既存の応募者テストと同じ扱い）
3. `sf_reminder_targets()`を締切日以外の日に呼んで空配列が返ることを確認
4. 締切当日をシミュレートするか、または`sf_shifts`に締切日ちょうどの未提出データを用意して`sf_reminder_targets()`が正しく対象者を返すことを確認
5. `push_user`アクションで実際にLINEメッセージが届くことを確認
6. `sf_mark_reminded`後、同じ日に再度`sf_reminder_targets()`を呼んでも同じ人が返らない（二重送信防止）ことを確認
7. 応募者向けの既存フロー（他の使い捨て応募者データ、または軽い操作）が壊れていないことを確認
8. テストデータ（テストユーザー・LINE連携・`sf_reminder_log`・`sf_shifts`）を完全に削除し、削除後の件数0を確認

---

## 5. 完了後にやること

- `WORKLOG.md`に実装・E2E結果を記録
- `docs/シフト打刻_設計書.md`の§8実装ステップに「4f完了」を追記
- Claudeの永続メモリ（`portal-project.md`）にも要約を追記
- 次の優先項目は要件定義書の開発スケジュール通り: 3:役職テスト → 4:評価制度 → 5:AIエージェント化 → 6:発注管理 → 7:カレンダー/ドメイン。または⑤打刻（GPS位置情報付き。`timecard.attendances:write`スコープの追加申請から）
