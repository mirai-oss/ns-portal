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
export function interviewText(a: IvInput, place: IvPlace | null): string {
  const d = new Date(new Date(a.interview_at).getTime() + 9 * 3600e3);   // 日本時間
  const w = "日月火水木金土"[d.getUTCDay()];
  const when = `${d.getUTCMonth() + 1}月${d.getUTCDate()}日(${w}) ${pad2(d.getUTCHours())}:${pad2(d.getUTCMinutes())}`;
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
