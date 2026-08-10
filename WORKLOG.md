# WORKLOG

## 2026-08-05
- プロジェクト開始。要件定義ヒアリング（統合レベル=A案、ハブ=日報Supabase、役割7種、店舗番号06〜12採番、委託先は精算専用のまま）
- docs/要件定義書.md 作成
- supabase/2026-08-05_unify.sql 作成（stores.store_no/signs追加、09〜12店舗追加、store_aliases新設、users.is_master追加。冪等）
- index.html ポータル初版（Supabase Authログイン、役割別タイル、パスワード変更）
- GitHub公開 + GitHub Pages有効化
- フェーズ1b実行: ユーザーのSupabase PATでManagement API経由SQL実行。stores 01〜12反映（09〜12はis_active=false）、store_aliases 34件、users.is_master追加、中山俊士（CEO）にis_master=true付与。確認クエリで検証済み
- フェーズ1c実装: tori-dashboardにSSO追加（GAS action=supalogin / アカウントシートK列メール / ログイン画面に統合ログインUI）。一時Supabaseユーザーで実機E2E（認証成功→旧GAS検知→案内表示）を確認後ユーザー削除。app.js v91公開済み。**GAS再デプロイ（sso-v46）待ち**
- 認証情報の置き場: ~/.config/ns-portal/supabase_pat と hub_service_role（chmod 600・リポジトリ外）
- 経営DのSSO本番開通をユーザーが確認（shunji.nakayama@ns0314.com ↔ shachoアカウント。アカウント1本化第一号）
- **権限設定画面を実装**: supabase/2026-08-05_portal_permissions.sql（portal_permissions=役割×システム既定24行、portal_user_overrides=個人例外、portal_is_master()、RLS=読み全員/書きマスターのみ）。ポータルに⚙️権限設定（マスター専用）＝役割マトリクス＋個人別例外（既定に従う/表示/非表示）。一時マスター・一時アルバイトユーザーで実機E2E（マトリクス保存→DB反映→復元、個人例外keiei=表示→アルバイト側ログインで経営Dタイル出現を確認）後、テストデータ全削除
- フェーズ2a: 精算ダッシュボードにSSO実装（sd_supaLogin／権限シートG列メール／委託先はサーバー側で明示拒否）。SD_VERSION v5.4→v5.5-sso。**GAS再デプロイ待ち**
- ポータル自動ログイン: ns-portal/tori/seisanは同一オリジン(mirai-oss.github.io)なのでlocalStorageを共有できる。両ダッシュボードが起動時にポータルのセッションを検出→期限切れならrefresh→supalogin。失敗時は静かに通常ログイン画面（実機で確認）
- フェーズ2b調査: 社内情報管理システムは別Supabase(wciefkpooncglahqdtmu)・28テーブル/239列/53ポリシー/8関数/12MB・ストレージ1ファイル・利用者1人(中山さん、is_master)。**利用者が1人なのは連携待ちのためで今後増える**とユーザーから情報あり
- 移設キット作成: supabase/migrate-info/（構造抽出→DDL生成）。ハブに一時スキーマを作り28テーブル/239列/FK43本の完全再現を検証済み→検証用スキーマは削除。本番切替はVercel環境変数変更が必要なため未実施
- 要件定義書に「6.5 データ横断の方針」追記（人=users.id・店舗=store_no・評価はハブに置く・給与は分離金庫・正は1箇所）
- 精算ダッシュボードのGAS再デプロイをユーザーが実施 → ping `v5.5-sso` を確認。本番で sd_supaLogin が期待どおり応答（未登録メールは「設定タブのメール欄に登録してください」）。検証用ユーザーは削除済み
- 要件定義書をv2.0に更新: フェーズ3の機能配置地図（4つの家の役割固定・機能①〜⑫の配置表・決定事項10〜15・実施順3a〜3i）。労務書類=社内情報管理、本部タスクボード=ポータル、評価KPI横断=ハブ、AI窓口=アプリ内から、シフトシミュレーションは作成画面に同時表示
- フェーズ3a実装: ポータルに検索（機能ガイドGUIDE＋お知らせ横断・権限のないシステムは候補に出さない・準備中機能は🚧表示）と掲示板（portal_posts、投稿=マスター/社長/本部、📌固定・YouTube埋め込み・投稿者名表示・削除）。実機E2E＝本部で投稿/検索/埋め込み確認、アルバイトで閲覧のみ・API直POSTはRLSが403拒否。テスト後データ全削除
- お知らせ改善: ✏️編集機能（マスター/社長/本部、フォーム流用でPATCH・キャンセル可）＋ホームでお知らせを検索より上（最上部）に移動。E2E済（投稿→編集→更新反映→フォームリセット）
- フェーズ3b実装: 日報アプリに「☑️チェック」タブ＝店舗チェックシート。checklist_templates/items/checks（RLS: テンプレ書き込み=checklist_can_manage()、チェック取消=本人or管理者）。写真必須項目はreport-photosバケットの既存ポリシー準拠で {uid}/checklist_* パスに保存。E2E＝本部でテンプレ作成/項目追加/チェック/写真、アルバイトで所属店舗のみ表示・編集ボタン非表示・テンプレ作成RLS拒否・他人チェック削除RLS拒否。テストデータ（テンプレ・写真・ユーザー）全削除
- 本部タスクボード（機能⑩）の詳細設計書v1.0を作成: docs/本部タスクボード設計書.html（Artifact: https://claude.ai/code/artifact/20680db4-421a-4fa7-8584-072076580fce ）。UIモック3画面（ボード/詳細/設定）・停滞判定ルール・hq_7テーブル案・アラート設計・権限。**確認待ち4点**=①tasks拡張→専用テーブルへの変更承認②チーム長の閲覧範囲③完了の定義（確認ステップ挟むか）④Lark通知の宛先グループ
- 本部タスクボード設計書をv1.1確定版に更新: 確認4点の回答反映（専用テーブル承認／公開範囲=登録時に設定しRLS強制／全工程完了で自動完了・確認要は「社長確認」工程を入れる方式で3列化／通知=チャンネル登録×ルール方式）＋追加要望4点（👤自分フィルタは頻度横断・毎日タスクのシンプルUI[店舗別2択＋異常メモ必須で形骸化防止]・フリーワード検索[過去分含む]・📁過去タスク=月別無期限保存）。実装ステップ3d-1〜3d-4を定義
- 設計書v1.2: シフト連携＝出勤日ベースの期限定義を追加（第5.5章）。休みでもタスクは対象日ごとに生成・表示継続、期限内=完了日≦対象日以降最初の出勤日。期限内フラグは保存せず対象日×完了日時×出勤日から都度計算（シフト導入後に遡及再判定可）。暫定はスマレジ勤怠実績→3eでシフト予定に切替。期限内完了率を評価KPIへ自動連携。たまりすぎ防止=出勤したのに未消化の日だけ数えて3日で停滞通知。実装ステップに3d-5追加
- 実行スレッド用の実装指示書を作成: docs/実装指示書_本部タスクボード.md（並行セッション対策=git fetch必須・hq_接頭辞限定・既存ALTER禁止・新規ファイル中心／接続情報・SQL実行方法(curl必須)・実装手順3d-1〜3・テストの流儀・コミット規約・スコープ外を明記）。設計書v1.2が仕様の正

## 2026-08-10 フェーズ3d-1実装（本部タスクボード 基盤＋ボード＋詳細）
- supabase/2026-08-10_hq_tasks.sql 新規作成→Management API経由で適用（hq_接頭辞13テーブル: templates/template_steps/tasks/task_members/task_steps/links/photos/alerts/activity/generation_log/notify_channels/notify_rules/notifications ＋ hq_can_manage()等の関数・RLS一式・工程完了トリガー・親タスク自動完了トリガー）。既存テーブルは無変更。冪等・再適用で確認済み
- **重要なバグ調査**: hq_tasksへのINSERT...RETURNINGがRLSで常に403拒否される不具合を発見。原因はSELECT方針`hq_task_visible(id)`が自テーブルをidで再クエリする設計だったため、INSERT直後の新規行をその内部サブクエリが認識できずRLS拒否になる（PostgreSQL/PostgRESTの既知の挙動。RETURNINGなしのINSERTや別テーブルからの参照では発生しない）。生SQLで最小再現（トリビアルなsecurity definer関数でも同様に失敗）してから特定。**対策**: hq_tasks自身のSELECT方針だけ`hq_task_visible_self(id, visibility, template_id)`という「行の列を直接渡す」版に変更（自己再クエリをやめる）。他テーブル（steps/links/photos/alerts/activity）は別テーブル参照のため元のhq_task_visible(task_id)のままで問題なし
- tasks.html 新規実装: かんばん3列（未着手/進行中/完了）・サマリー信号（期限超過/今日期限/3日以上停止/今月完了、タップで絞り込み）・法人×頻度×👤自分の絞り込み（掛け合わせ可）・フリーワード検索（タイトル/注意事項/工程名/異常メモ/コメントを対象、過去分含む全期間）・🔁繰り返しタブ（月次表）・タスク詳細（工程の完了操作＝2択判定/異常メモ必須/写真必須をDBトリガーで強制、⚠️注意事項、リンク追加url/manual/credential、写真アップロード、履歴）・単発タスク作成UI。ログインはポータルのlocalStorageセッションをそのまま使用（SDKなし素fetch、index.htmlと同パターン）
- index.html: 「📌 本部タスク」タイルを追加（表示条件はTEAM/HQ/CEO。既存タイル・ロジックは無変更、2行追加のみ）
- **実機E2E**: service_roleで一時ユーザー3種（HQ役/TEAM役/AL役、*-test@example.com）を作成し検証
  - HQ役: 単発タスク作成（工程2件）→両工程完了→親タスクが自動的に「完了」へ遷移することを確認。検索（「振込」でヒット）・繰り返しタブ（空状態）も確認
  - TEAM役: 本部タスクタイル表示・ボード閲覧（visibility=all のタスクが見える）・自分が担当の工程を完了できることを確認。「単発タスク作成」ボタンが非表示であることを確認
  - **RLS敵対テスト**: TEAM役でテンプレート作成・通知チャンネル登録を直接API POST→ともに403拒否を確認。他人のタスクのnotesを直接PATCH→RLSにより0件更新（実質拒否）を確認。AL役でタイルが表示されないこと、tasks.htmlを直接開いても担当外タスクは0件しか見えないこと、hq_tasks/hq_task_stepsへの直接SELECT/INSERTがそれぞれ空配列/403になることを確認
  - テスト後: hq_tasks（カスケードでsteps等も含む）を全削除、一時ユーザー3件をauth.admin経由で削除。`select count(*) from users where email like '%test@example.com'`が0、`hq_tasks`/`hq_task_steps`が0件、ceo@example.comは健在であることを確認
- 構文チェック: tasks.html・index.htmlのscriptブロックを`node -c`で確認
- 未検証: 3d-2（繰り返しテンプレート・自動生成・毎日タスクUI）以降は未着手。GitHub Pagesへのデプロイ確認はコミット後に実施
