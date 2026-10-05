# PL入力のSupabase正本化（F3）— 切替計画

作成: 2026-10-05 担当A ／ 相手: レーンP ／ 背景: 2026-09-26〜28 にPL管理システム「✍販管費入力」の年月列が人の編集で空になり、DB_PL→BQ(stg_pl)→kd→画面と全てに波及した事故（版履歴から復元済み）。

## 現状（2026-10-05）
- Supabase pl_entries（正本・年月必須・履歴つき）と RPC は稼働中。DB_PL 復元後の772行を取込済み（月別の件数・金額が kd_pl_entries と全月一致）。
- 画面: PLタブ「📝 PL入力（表）」(app.js v246) が pl_entries を直接読み書き。**切替前の保存は試験扱い**（切替時に再取込で上書きされる）。
- kd_pl_monthly_summary / kd_pl_entries の元は まだ従来(GAS→stg_pl)。切替スイッチ app_secrets.pl_source='entries'（既定=従来）。

## PLを書いている処理の棚卸し（切替で書込先を pl_entries にする対象）
| # | 処理 | 場所 | 現在の書込先 | 切替後 |
|---|---|---|---|---|
| 1 | 運営委託費の自動計上 syncSeisanFeeToPl | tori-dashboard GAS | DB_PL+PL管理システム+stg_pl | pl_entries replace_source(source=運営委託費（自動計上）×年月) |
| 2 | 精算書科目の自動計上 syncSeisanCategoriesToPl | 同上 | 同上 | replace_source(source=自動｜精算書×年月) |
| 3 | スポット人件費→PL syncSpotLaborToPl_ | 同上 | 同上 | replace_source(source=自動｜スポット人件費×年月) |
| 4 | 借入利息 syncBankLoanToPl_ | 同上 | 同上 | replace_source(source=自動｜支払利息×年月) |
| 5 | 請求書連携 writeAccountCostToPl_ (writePlFee/writeAdCost) | 同上 | 同上 | upsert(source_key=外部連携:… ×店舗) |
| 6 | 旧入力画面 savePlEntries / savePlBulk / MF取込 mfConfirmImport | 同上 | 同上 | 新「PL入力（表）」へ誘導 or replace_month_store |
| 7 | 店舗間仕入れ移動 costTransfer* | 同上 | DB_PL(2行1組) | upsert(source=店舗間移動, source_key=移動ID:元/先) |
| 8 | 媒体販促費(自動計上) autoPromoToDbPl_ ほか | **PL管理システムの別GASプロジェクト** | DB_PL | 要検討（広告費→pl_entries）。切替前に停止 or 書込先変更 |
| 9 | ✍販管費入力→DB_PL 洗い替え plSyncDaily_/plSyncTick_/plOnInputEdit_ | **PL管理システムの別GASプロジェクト** | DB_PL | **切替時に停止**（シートは読み取り専用ミラーになるため） |

## 方針
- 書込先の切替は **スクリプトプロパティ PL_SOURCE=entries で ON/OFF**（既定OFF＝今の動き）。旧コードは消さず、フラグだけで即戻せる。
- 切替当日の順序: ①（8・9）の停止/切替準備 ②GAS新版デプロイ(PL_SOURCE=OFF のまま) ③レーンP: pl_entries を空にして再取込→pl_source=entries→pl_monthly→月別合計を突合 ④PL_SOURCE=entries に ON ⑤シート(DB_PL/✍販管費入力)を pl_entries からの読み取り専用ミラーにする(plMirrorReplace) ⑥シートを「編集不可」に保護。
- ロールバック: PL_SOURCE を外し、pl_source を従来に戻し、シートは版履歴/ミラーで復元。
- 年月が空の行は DB が拒否（NOT NULL＋形式チェック）。GASのbqSyncPLにも空年月ガードを入れた。

## 未決
- 店長(TENCHO)に自店舗の手入力を許すか／TEAMに書かせるか（RPCは1行で変更可）。
- 区分S(その他売上)・X(銀行返済)の扱い（データ上は現状なし）。
- 切替日（#8・#9 の別GAS側の停止・変更が必要。PL管理システムの別プロジェクトを触る）。
