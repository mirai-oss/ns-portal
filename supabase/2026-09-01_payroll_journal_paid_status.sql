-- 給与仕訳: 振込完了状態を記録できるようにする（2026-09-01）
-- ユーザー要望: 「会計入力（仕訳登録）は終わったが振込がまだ」と「振込も完了した」を
-- 区別して一覧で分かるようにしたい・振込が終わったら手動で「振込完了」を押せるようにしたい
-- （現金手渡しの人はPayPay銀行CSVの対象外＝振込実行という行為自体が無いため、手動確認ボタンが必須）。
alter table payroll_journal_records add column if not exists paid_at timestamptz;
alter table payroll_journal_records add column if not exists paid_by uuid references users(id);
