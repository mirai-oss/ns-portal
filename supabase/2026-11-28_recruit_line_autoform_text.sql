-- 2026-11-28 LINE連携後の応募フォーム案内の文面を差し替え（社長指定）。戻し方: 2026-11-28_recruit_line_autoform.sql の中の文面を入れ直す。
update app_settings set value = jsonb_set(value, '{text}', to_jsonb($txt${name}さん、LINEの連携が完了しました。ご応募ありがとうございます。

面接の前に、下の応募フォームへのご回答をお願いいたします。
{url}
面接の希望日時も入れていただければスムーズです😊

ご回答を確認しましたら、担当者よりご連絡いたします。$txt$::text))
 where key = 'recruit_line_autoform';
