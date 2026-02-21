import type { FridgeItem, Notice, NoticeTone } from "@/components/tabs/types";

type HomeTabProps = {
  fridgeItems: Pick<FridgeItem, "id" | "name" | "expiryDate">[];
  notices: Notice[];
  missingEssentialItems: string[];
  onDismissNotice: (noticeId: string) => void;
  onGoFridge: () => void;
  onGoRecommend: () => void;
  onGoShopping: () => void;
  onStartFirstRun: () => void;
  onAddMissingEssentialToShopping: () => void;
  getDaysDiff: (dateText: string) => number;
  toneClass: (tone: NoticeTone) => string;
};

export function HomeTab({
  fridgeItems,
  notices,
  missingEssentialItems,
  onDismissNotice,
  onGoFridge,
  onGoRecommend,
  onGoShopping,
  onStartFirstRun,
  onAddMissingEssentialToShopping,
  getDaysDiff,
  toneClass,
}: HomeTabProps) {
  const urgentItems = fridgeItems.filter((item) => {
    const diff = getDaysDiff(item.expiryDate);
    return diff >= 0 && diff <= 3;
  });

  const expiredItems = fridgeItems.filter((item) => getDaysDiff(item.expiryDate) < 0);

  const getBadgeClass = (diff: number) => {
    if (diff < 0) return "bg-rose-100 text-rose-700";
    if (diff === 0) return "bg-red-500 text-white";
    if (diff === 1) return "bg-orange-500 text-white";
    if (diff <= 3) return "bg-amber-100 text-amber-700";
    if (diff <= 7) return "bg-yellow-100 text-yellow-700";
    return "bg-slate-100 text-slate-600";
  };

  return (
    <div className="space-y-6 p-4 pb-24">
      <header className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-[44px] font-extrabold tracking-tight text-slate-900">우리집 냉장고</h1>
          <p className="mt-1 text-2xl text-slate-500">냉장고 파먹기를 시작해볼까요?</p>
        </div>
        <div className="flex h-16 w-16 items-center justify-center rounded-full bg-orange-100 text-3xl">🍳</div>
      </header>

      {notices.length > 0 ? (
        <div className="space-y-2">
          {notices.map((notice) => (
            <div
              key={notice.id}
              className={`flex items-center justify-between rounded-2xl border p-3 text-base ${toneClass(notice.tone)}`}
            >
              <div className="flex items-center gap-2">
                <span aria-hidden="true">ℹ️</span>
                <span>{notice.message}</span>
              </div>
              <button
                type="button"
                onClick={() => onDismissNotice(notice.id)}
                className="opacity-60 transition hover:opacity-100"
                aria-label="알림 닫기"
              >
                ✕
              </button>
            </div>
          ))}
        </div>
      ) : null}

      {fridgeItems.length === 0 ? (
        <section className="space-y-3 rounded-2xl border border-orange-200 bg-orange-50 p-4">
          <h3 className="text-xl font-bold text-orange-700">처음 오셨군요! 냉장고부터 채워볼까요?</h3>
          <ol className="list-decimal space-y-1 pl-5 text-sm text-orange-700">
            <li>빠른 등록(⚡)으로 자주 쓰는 재료 선택</li>
            <li>유통기한 확인 후 저장</li>
            <li>추천 메뉴에서 바로 조리 시작</li>
          </ol>
          <button
            type="button"
            onClick={onStartFirstRun}
            className="w-full rounded-xl bg-orange-500 px-4 py-2 text-sm font-semibold text-white"
          >
            첫 재료 등록 시작하기
          </button>
        </section>
      ) : null}

      <section className="rounded-[28px] bg-gradient-to-br from-orange-400 to-orange-500 p-5 text-white shadow-md">
        <div className="flex items-center justify-between">
          <div>
            <h2 className="text-4xl font-bold">냉장고 속 재료</h2>
            <p className="mt-1 text-xl text-orange-100">총 {fridgeItems.length}개의 재료가 있어요</p>
          </div>
          <span className="text-4xl">🧊</span>
        </div>
        <button
          type="button"
          onClick={onGoFridge}
          className="mt-4 w-full rounded-full bg-white px-4 py-2 text-xl font-semibold text-orange-600"
        >
          냉장고 관리하기
        </button>
      </section>

      <section className="grid grid-cols-2 gap-4">
        <button
          type="button"
          onClick={onGoRecommend}
          className="rounded-3xl border border-slate-100 bg-white p-5 shadow-sm"
        >
          <div className="mx-auto flex h-14 w-14 items-center justify-center rounded-full bg-yellow-100 text-3xl">✨</div>
          <p className="mt-2 text-4xl font-bold text-slate-800">메뉴 추천</p>
        </button>
        <button
          type="button"
          onClick={onGoShopping}
          className="rounded-3xl border border-slate-100 bg-white p-5 shadow-sm"
        >
          <div className="mx-auto flex h-14 w-14 items-center justify-center rounded-full bg-emerald-100 text-3xl">🛒</div>
          <p className="mt-2 text-4xl font-bold text-slate-800">장보기 목록</p>
        </button>
      </section>

      {missingEssentialItems.length > 0 ? (
        <section className="rounded-2xl border border-sky-100 bg-sky-50 p-4">
          <h3 className="text-lg font-bold text-sky-700">부족한 필수 재료를 한 번에 추가할까요?</h3>
          <p className="mt-1 text-sm text-sky-600">{missingEssentialItems.join(", ")}</p>
          <button
            type="button"
            onClick={onAddMissingEssentialToShopping}
            className="mt-3 rounded-full bg-sky-600 px-4 py-2 text-sm font-semibold text-white"
          >
            장보기에 한 번에 담기
          </button>
        </section>
      ) : null}

      {urgentItems.length > 0 || expiredItems.length > 0 ? (
        <section>
          <h3 className="mb-3 flex items-center gap-2 text-xl font-bold text-slate-800">
            <span aria-hidden="true">⚡</span>
            유통기한 임박!
          </h3>
          <div className="overflow-hidden rounded-2xl border border-slate-100 bg-white shadow-sm">
            {[...expiredItems, ...urgentItems].slice(0, 3).map((item) => {
              const diff = getDaysDiff(item.expiryDate);
              const badgeClass = getBadgeClass(diff);

              return (
                <div key={item.id} className="flex items-center justify-between border-b border-slate-50 p-3 last:border-b-0">
                  <span className="font-semibold text-slate-700">{item.name}</span>
                  <span className={`rounded-full px-2 py-1 text-sm font-bold ${badgeClass}`}>
                    {diff < 0 ? `D+${Math.abs(diff)}` : `D-${diff}`}
                  </span>
                </div>
              );
            })}
          </div>
        </section>
      ) : null}
    </div>
  );
}
