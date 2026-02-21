import type { Dispatch, SetStateAction } from "react";
import type { ShoppingItem } from "@/components/tabs/types";

type ShoppingTabProps = {
  model: {
    checkedShopping: ShoppingItem[];
    moveCheckedShoppingToFridge: () => void;
    removeCheckedShopping: () => void;
    shoppingSearch: string;
    setShoppingSearch: Dispatch<SetStateAction<string>>;
    newShoppingName: string;
    setNewShoppingName: Dispatch<SetStateAction<string>>;
    addShoppingItem: (name: string, reason: string, recipeName?: string) => boolean;
    visibleUncheckedShopping: ShoppingItem[];
    visibleCheckedShopping: ShoppingItem[];
    toggleShoppingCheck: (id: string) => void;
    getCoupangLink: (name: string) => string;
    removeShoppingItem: (id: string) => void;
    shoppingList: ShoppingItem[];
    shareShoppingList: () => Promise<void>;
    shoppingActionMessage: string | null;
  };
};

export function ShoppingTab({ model }: ShoppingTabProps) {
  const {
    checkedShopping,
    moveCheckedShoppingToFridge,
    removeCheckedShopping,
    shoppingSearch,
    setShoppingSearch,
    newShoppingName,
    setNewShoppingName,
    addShoppingItem,
    visibleUncheckedShopping,
    visibleCheckedShopping,
    toggleShoppingCheck,
    getCoupangLink,
    removeShoppingItem,
    shoppingList,
    shareShoppingList,
    shoppingActionMessage,
  } = model;

  return (
    <div className="space-y-4 p-4 pb-24">
      <div className="mb-2 flex items-center justify-between">
        <h2 className="text-5xl font-extrabold text-slate-900">장보기 목록</h2>
        <div className="flex items-center gap-2">
          <button type="button" onClick={shareShoppingList} className="text-sm text-slate-500">
            목록 공유
          </button>
          {checkedShopping.length > 0 ? (
            <>
              <button type="button" onClick={moveCheckedShoppingToFridge} className="text-sm text-blue-500">
                냉장고로 이동
              </button>
              <button type="button" onClick={removeCheckedShopping} className="text-sm text-slate-500">
                완료항목 비우기
              </button>
            </>
          ) : null}
        </div>
      </div>

      {shoppingActionMessage ? (
        <p className="rounded-xl border border-emerald-200 bg-emerald-50 px-3 py-2 text-sm text-emerald-700">
          {shoppingActionMessage}
        </p>
      ) : null}

      <input
        value={shoppingSearch}
        onChange={(event) => setShoppingSearch(event.target.value)}
        placeholder="장보기 항목 검색"
        className="w-full rounded-xl border border-slate-200 bg-white px-4 py-3 text-sm outline-none focus:border-orange-400"
      />

      <div className="flex gap-2">
        <input
          value={newShoppingName}
          onChange={(event) => setNewShoppingName(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter") {
              addShoppingItem(newShoppingName, "직접 추가");
              setNewShoppingName("");
            }
          }}
          placeholder="장볼 항목 추가"
          className="flex-1 rounded-xl border border-slate-200 bg-white px-4 py-3 text-sm outline-none focus:border-orange-400"
        />
        <button
          type="button"
          onClick={() => {
            addShoppingItem(newShoppingName, "직접 추가");
            setNewShoppingName("");
          }}
          className="rounded-xl bg-orange-500 px-4 text-white"
          aria-label="추가"
        >
          +
        </button>
      </div>

      {visibleUncheckedShopping.length > 0 ? (
        <section className="space-y-2">
          <p className="text-sm font-semibold text-slate-500">사야 할 것 ({visibleUncheckedShopping.length})</p>
          {visibleUncheckedShopping.map((item) => (
            <div key={item.id} className="flex items-center justify-between gap-3 rounded-2xl border border-slate-100 bg-white p-3 shadow-sm">
              <button
                type="button"
                onClick={() => toggleShoppingCheck(item.id)}
                className="h-6 w-6 shrink-0 rounded-full border-2 border-slate-300"
                aria-label="체크"
              />
              <div className="min-w-0 flex-1">
                <p className="truncate font-semibold text-slate-800">{item.name}</p>
                <p className="truncate text-xs text-slate-400">
                  {item.reason}
                  {item.recipeName ? ` (${item.recipeName})` : ""}
                </p>
              </div>
              <div className="flex items-center gap-1">
                <a
                  href={getCoupangLink(item.name)}
                  target="_blank"
                  rel="noreferrer"
                  className="rounded-lg bg-blue-50 px-2.5 py-2 text-xs font-bold text-blue-600"
                >
                  쿠팡
                </a>
                <button type="button" onClick={() => removeShoppingItem(item.id)} className="p-2 text-slate-400" aria-label="삭제">
                  ✕
                </button>
              </div>
            </div>
          ))}
        </section>
      ) : null}

      {visibleCheckedShopping.length > 0 ? (
        <section className="space-y-2 opacity-70">
          <p className="text-sm font-semibold text-slate-500">완료됨</p>
          {visibleCheckedShopping.map((item) => (
            <div key={item.id} className="flex items-center gap-3 rounded-xl bg-slate-100 p-3">
              <button type="button" onClick={() => toggleShoppingCheck(item.id)} className="h-6 w-6 rounded-full bg-emerald-500 text-white">
                ✓
              </button>
              <p className="line-through">{item.name}</p>
            </div>
          ))}
        </section>
      ) : null}

      {shoppingList.length === 0 ? (
        <div className="py-12 text-center text-slate-400">
          <div className="text-6xl">🛒</div>
          <p className="mt-2 text-xl">
            장보기 목록이 비어 있어요.
            <br />
            필요한 재료를 추가해 주세요.
          </p>
        </div>
      ) : visibleUncheckedShopping.length === 0 && visibleCheckedShopping.length === 0 ? (
        <div className="py-12 text-center text-slate-400">
          <div className="text-6xl">🔎</div>
          <p className="mt-2 text-xl">검색 조건에 맞는 장보기 항목이 없어요.</p>
        </div>
      ) : null}
    </div>
  );
}
