// =============================================================
// 採用管理: 応募者へ送る「面接のご案内」の文面（2026-11-28 下書き・本番未適用）
//   いまの管理システムの画面（nippo/index.html の interviewText）と、1 文字も違わないこと。
//   確かめ方: 画面の関数をそのまま動かして作った見本（fixtures/recruit-interview-text.json）と比べる（recruit-interview-text.test.ts）。
//   画面は利用者の端末の時刻（日本時間）で日時を書くので、こちらは日本時間に固定して書く。
//   ★ 画面の文面を変えるときは、ここも同じに変え、見本を作り直すこと（scratchpad ob18/stage2/gen_interview_fixture.mjs）
// =============================================================
export type IvPlace = { name?: string | null; address?: string | null; note?: string | null };
export type IvInput = { name: string; interview_at: string; interview_mode?: string | null; interview_place?: string | null; interview_address?: string | null; interview_url?: string | null };

const pad2 = (n: number) => String(n).padStart(2, "0");

/** place＝設定（app_settings.interview_places）にある、その面接場所（画面の ivPlaceOf(a.interview_place) にあたる。無ければ null） */
/** 日時の書き方（画面と同じ: 11月20日(金) 14:00・日本時間） */
export function whenText(iso: string): string {
  const d = new Date(new Date(iso).getTime() + 9 * 3600e3);
  return `${d.getUTCMonth() + 1}月${d.getUTCDate()}日(${"日月火水木金土"[d.getUTCDay()]}) ${pad2(d.getUTCHours())}:${pad2(d.getUTCMinutes())}`;
}
export function interviewText(a: IvInput, place: IvPlace | null): string {
  const when = whenText(a.interview_at);
  let t = `${a.name}さん\n\nこの度はご応募いただきありがとうございます。\n面接の日時が決まりましたのでご連絡いたします。\n\n【面接日時】${when}`;
  if (a.interview_mode === "onsite") {
    const addr = a.interview_address || (place && place.address) || "";
    t += `\n【場所】${a.interview_place || ""}`;
    if (addr) t += `\n【住所】${addr}`;
    if (place && place.note) t += `\n${place.note}`;
    t += `\n\nお気をつけてお越しください。`;
  } else if (a.interview_url) {
    t += `\n【面接URL】${a.interview_url}\n\nお時間になりましたら、上のリンクからご参加ください。`;
  }
  t += `\n\nご都合が悪くなった場合は、このままご返信ください。\nお会いできるのを楽しみにしております。`;
  return t;
}

// ---- 2026-12-03 面接の変更・取り消しの案内（社長の指示: 変更は「変更」と分かる文面に・取り消しも LINE で知らせる） ----
//   いまの画面には無い文面（画面は、変更のときも「決まりました」の文面を送り、取り消しは何も送らない）。言い回しは、確定の文面に合わせてある。
//   ★ 文面は案。決まったら、ここと、テスト（recruit-interview-text.test.ts）の期待値を直す

/** 面接の変更の案内。prevAt＝変更前の日時（日時が同じ＝やり方・場所・URL だけ変わったときは、「変更前」の行を出さない）。URL・場所は、変更後のものを必ず書く */
export function interviewChangeText(a: IvInput, place: IvPlace | null, prevAt: string | null): string {
  const moved = !!prevAt && new Date(prevAt).getTime() !== new Date(a.interview_at).getTime();
  let t = `${a.name}さん\n\n${moved ? "面接の日時が変更になりましたのでご連絡いたします。" : "面接のご案内の内容が変更になりましたのでご連絡いたします。"}\n\n`;
  t += moved ? `【変更前】${whenText(prevAt as string)}\n【変更後の面接日時】${whenText(a.interview_at)}` : `【面接日時】${whenText(a.interview_at)}`;
  if (a.interview_mode === "onsite") {
    const addr = a.interview_address || (place && place.address) || "";
    t += `\n【場所】${a.interview_place || ""}`;
    if (addr) t += `\n【住所】${addr}`;
    if (place && place.note) t += `\n${place.note}`;
    t += `\n\nお気をつけてお越しください。`;
  } else if (a.interview_url) {
    t += `\n【面接URL】${a.interview_url}\n\nお時間になりましたら、上のリンクからご参加ください。`;
  }
  t += `\n\n以前にお送りしたご案内は、こちらの内容に読み替えてください。\nご都合が悪くなった場合は、このままご返信ください。\nお会いできるのを楽しみにしております。`;
  return t;
}

/** 面接の取り消しの案内。prevAt＝取り消す面接の日時 */
export function interviewCancelText(name: string, prevAt: string): string {
  return `${name}さん\n\n誠に恐れ入りますが、下記の面接は取り消し（キャンセル）となりましたのでご連絡いたします。\n\n【取り消しとなった面接】${whenText(prevAt)}\n\n`
    + `以前にお送りした面接のご案内（URL・場所）は、使えなくなります。\nご不明な点があれば、このままご返信ください。`;
}
