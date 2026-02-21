import type { Dispatch, SetStateAction } from "react";
import type { FridgeFilterStatus, FridgeItem, QuickItem } from "@/components/tabs/types";

type FridgeTabProps = {
  model: {
    showQuickAdd: boolean;
    setShowQuickAdd: Dispatch<SetStateAction<boolean>>;
    showManualAdd: boolean;
    setShowManualAdd: Dispatch<SetStateAction<boolean>>;
    manualName: string;
    setManualName: Dispatch<SetStateAction<string>>;
    manualExpiryDate: string;
    setManualExpiryDate: Dispatch<SetStateAction<string>>;
    addManualItem: () => void;
    fridgeSearch: string;
    setFridgeSearch: Dispatch<SetStateAction<string>>;
    fridgeFilterStatus: FridgeFilterStatus;
    setFridgeFilterStatus: Dispatch<SetStateAction<FridgeFilterStatus>>;
    fridgeCategories: string[];
    fridgeFilterCategory: string;
    setFridgeFilterCategory: Dispatch<SetStateAction<string>>;
    fridgeActionMessage: string | null;
    filteredFridgeItems: FridgeItem[];
    fridgeItems: FridgeItem[];
    getDaysDiff: (dateText: string) => number;
    openExpiryEditor: (item: FridgeItem) => void;
    getCoupangLink: (keyword: string) => string;
    removeFridgeItem: (id: string) => void;
    editingExpiryTarget: FridgeItem | null;
    editingExpiryDate: string;
    setEditingExpiryDate: Dispatch<SetStateAction<string>>;
    setEditingExpiryTarget: Dispatch<SetStateAction<FridgeItem | null>>;
    saveExpiryDate: () => void;
    configuredQuickItems: Array<{ title: string; items: QuickItem[] }>;
    quickSelectedNames: Set<string>;
    toggleQuickItem: (item: QuickItem) => void;
  };
};

export function FridgeTab({ model }: FridgeTabProps) {
  const {
    showQuickAdd,
    setShowQuickAdd,
    showManualAdd,
    setShowManualAdd,
    manualName,
    setManualName,
    manualExpiryDate,
    setManualExpiryDate,
    addManualItem,
    fridgeSearch,
    setFridgeSearch,
    fridgeFilterStatus,
    setFridgeFilterStatus,
    fridgeCategories,
    fridgeFilterCategory,
    setFridgeFilterCategory,
    fridgeActionMessage,
    filteredFridgeItems,
    fridgeItems,
    getDaysDiff,
    openExpiryEditor,
    getCoupangLink,
    removeFridgeItem,
    editingExpiryTarget,
    editingExpiryDate,
    setEditingExpiryDate,
    setEditingExpiryTarget,
    saveExpiryDate,
    configuredQuickItems,
    quickSelectedNames,
    toggleQuickItem,
  } = model;

  return (
    <div className="space-y-4 p-4 pb-24">
      <div className="mb-4 flex items-center justify-between">
        <h2 className="text-5xl font-extrabold tracking-tight text-slate-900">내 냉장고 관리</h2>
        <div className="flex gap-2">
          <button
            type="button"
            onClick={() => setShowQuickAdd(true)}
            className="flex h-12 w-12 items-center justify-center rounded-full bg-yellow-400 text-xl text-white"
            aria-label="빠른 등록"
          >
            ⚡
          </button>
          <button
            type="button"
            onClick={() => setShowManualAdd((prev) => !prev)}
            className="flex h-12 w-12 items-center justify-center rounded-full bg-orange-500 text-2xl text-white"
            aria-label="직접 등록"
          >
            +
          </button>
        </div>
      </div>

      {showManualAdd ? (
        <div className="flex gap-2 rounded-2xl border border-slate-100 bg-white p-3 shadow-sm">
          <input
            value={manualName}
            onChange={(event) => setManualName(event.target.value)}
            placeholder="재료명"
            className="flex-1 rounded-xl bg-slate-50 px-3 py-2 text-sm outline-none ring-orange-300 focus:ring"
          />
          <input
            type="date"
            value={manualExpiryDate}
            onChange={(event) => setManualExpiryDate(event.target.value)}
            className="w-44 rounded-xl bg-slate-50 px-3 py-2 text-center text-sm outline-none ring-orange-300 focus:ring"
            aria-label="유통기한 날짜"
          />
          <button
            type="button"
            onClick={addManualItem}
            disabled={!manualName.trim() || !manualExpiryDate}
            className="rounded-xl bg-orange-500 px-4 py-2 text-sm font-bold text-white disabled:cursor-not-allowed disabled:bg-slate-300"
          >
            추가
          </button>
        </div>
      ) : null}

      <div className="space-y-3 rounded-2xl border border-slate-100 bg-white p-3 shadow-sm">
        <input
          value={fridgeSearch}
          onChange={(event) => setFridgeSearch(event.target.value)}
          placeholder="재료 검색"
          className="w-full rounded-xl bg-slate-50 px-3 py-2 text-sm outline-none ring-orange-300 focus:ring"
        />

        <div className="flex flex-wrap gap-2">
          {([
            ["all", "전체"],
            ["urgent", "임박"],
            ["expired", "만료"],
            ["safe", "여유"],
          ] as const).map(([key, label]) => (
            <button
              key={key}
              type="button"
              onClick={() => setFridgeFilterStatus(key)}
              className={`rounded-full px-3 py-1.5 text-xs font-semibold ${fridgeFilterStatus === key ? "bg-orange-500 text-white" : "bg-slate-100 text-slate-600"}`}
            >
              {label}
            </button>
          ))}
        </div>

        <div className="flex flex-wrap gap-2">
          {fridgeCategories.map((category) => (
            <button
              key={category}
              type="button"
              onClick={() => setFridgeFilterCategory(category)}
              className={`rounded-full px-3 py-1.5 text-xs font-semibold ${fridgeFilterCategory === category ? "bg-slate-900 text-white" : "bg-slate-100 text-slate-600"}`}
            >
              {category}
            </button>
          ))}
        </div>
      </div>

      {fridgeActionMessage ? (
        <p className="rounded-xl border border-emerald-200 bg-emerald-50 px-3 py-2 text-sm text-emerald-700">
          {fridgeActionMessage}
        </p>
      ) : null}

      {filteredFridgeItems.length === 0 ? (
        <div className="py-12 text-center text-slate-400">
          <div className="text-6xl">🧊</div>
          <p className="mt-2 text-xl">
            {fridgeItems.length === 0 ? "냉장고가 비어 있어요." : "조건에 맞는 재료가 없어요."}
            <br />
            {fridgeItems.length === 0 ? "재료를 먼저 등록해 주세요." : "검색어/필터를 바꿔서 다시 확인해 주세요."}
          </p>
        </div>
      ) : (
        <div className="space-y-3">
          {filteredFridgeItems.map((item) => {
            const diff = getDaysDiff(item.expiryDate);
            const badgeClass = diff < 0
              ? "bg-rose-100 text-rose-700"
              : diff === 0
                ? "bg-red-500 text-white"
                : diff === 1
                  ? "bg-orange-500 text-white"
                  : diff <= 3
                    ? "bg-amber-100 text-amber-700"
                    : diff <= 7
                      ? "bg-yellow-100 text-yellow-700"
                      : "bg-slate-100 text-slate-600";

            return (
              <div key={item.id} className="flex items-center justify-between rounded-3xl border border-slate-100 bg-white p-4 shadow-sm">
                <div>
                  <h4 className="text-4xl font-extrabold text-slate-900">{item.name}</h4>
                  <p className="mt-1 text-base text-slate-400">등록: {item.addedDate}</p>
                </div>
                <div className="flex items-center gap-2">
                  <button
                    type="button"
                    onClick={() => openExpiryEditor(item)}
                    className={`rounded-full px-3 py-1 text-xl font-bold ${badgeClass}`}
                  >
                    {diff < 0 ? `D+${Math.abs(diff)}` : `D-${diff}`}
                  </button>
                  <a
                    href={getCoupangLink(item.name)}
                    target="_blank"
                    rel="noreferrer"
                    className="rounded-full bg-blue-50 p-1.5 text-2xl text-blue-500"
                    aria-label={`${item.name} 쿠팡 링크`}
                  >
                    🛒
                  </a>
                  <button
                    type="button"
                    onClick={() => removeFridgeItem(item.id)}
                    className="rounded-full bg-red-50 p-1.5 text-2xl text-red-400"
                    aria-label="삭제"
                  >
                    🗑️
                  </button>
                </div>
              </div>
            );
          })}
        </div>
      )}

      {editingExpiryTarget ? (
        <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/40">
          <div className="w-full max-w-[430px] rounded-t-3xl bg-white p-5">
            <h3 className="text-xl font-bold text-slate-900">유통기한 수정</h3>
            <p className="mt-1 text-sm text-slate-500">{editingExpiryTarget.name}의 디데이를 변경합니다.</p>

            <input
              type="date"
              value={editingExpiryDate}
              onChange={(event) => setEditingExpiryDate(event.target.value)}
              className="mt-4 w-full rounded-xl border border-slate-200 bg-slate-50 px-3 py-3 text-center text-sm outline-none ring-orange-300 focus:ring"
              aria-label="유통기한 수정"
            />

            <div className="mt-4 flex gap-2">
              <button
                type="button"
                onClick={() => setEditingExpiryTarget(null)}
                className="flex-1 rounded-xl bg-slate-100 px-4 py-3 text-sm font-semibold text-slate-600"
              >
                취소
              </button>
              <button
                type="button"
                onClick={saveExpiryDate}
                className="flex-1 rounded-xl bg-orange-500 px-4 py-3 text-sm font-semibold text-white"
              >
                저장
              </button>
            </div>
          </div>
        </div>
      ) : null}

      {showQuickAdd ? (
        <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/50">
          <div className="flex h-[75%] w-full max-w-[430px] flex-col rounded-t-3xl bg-white p-5">
            <div className="mb-4 flex items-center justify-between">
              <h3 className="text-xl font-bold text-slate-900">빠른 재료 등록</h3>
              <button type="button" onClick={() => setShowQuickAdd(false)} className="text-2xl text-slate-500" aria-label="닫기">
                ✕
              </button>
            </div>

            <div className="flex-1 space-y-6 overflow-y-auto pb-10">
              {configuredQuickItems.length === 0 ? (
                <div className="rounded-2xl border border-slate-100 bg-slate-50 p-4 text-sm text-slate-500">
                  설정에서 빠른 재료 항목을 선택해 주세요.
                </div>
              ) : null}

              {configuredQuickItems.map((category) => (
                <section key={category.title}>
                  <h4 className="mb-2 text-sm font-semibold text-slate-500">{category.title}</h4>
                  <div className="flex flex-wrap gap-2">
                    {category.items.map((item) => {
                      const isSelected = quickSelectedNames.has(item.name.toLowerCase());

                      return (
                        <button
                          key={item.name}
                          type="button"
                          onClick={() => toggleQuickItem(item)}
                          className={`rounded-full px-3 py-1.5 text-sm font-semibold transition ${isSelected ? "bg-orange-100 text-orange-700 ring-1 ring-orange-300" : "bg-slate-100 text-slate-700 hover:bg-orange-100 hover:text-orange-600"}`}
                        >
                          {isSelected ? "✓ " : "+ "}
                          {item.name}
                        </button>
                      );
                    })}
                  </div>
                </section>
              ))}
            </div>

            <button
              type="button"
              onClick={() => setShowQuickAdd(false)}
              className="rounded-xl bg-slate-900 px-4 py-3 text-sm font-semibold text-white"
            >
              완료
            </button>
          </div>
        </div>
      ) : null}
    </div>
  );
}
