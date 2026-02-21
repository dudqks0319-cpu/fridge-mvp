import type { Dispatch, SetStateAction } from "react";
import type { RecipeCard, RecipeFilterCategory } from "@/components/tabs/types";

type RecommendTabProps = {
  model: {
    selectedRecipe: RecipeCard | null;
    setSelectedRecipeId: Dispatch<SetStateAction<string | null>>;
    recommendActionMessage: string | null;
    addMissingToShopping: (items: string[], recipeName: string) => void;
    hasOwnedIngredient: (ingredient: string) => boolean;
    getCheckedStepCount: (recipeId: string) => number;
    recipeStepChecked: Record<string, number[]>;
    toggleRecipeStep: (recipeId: string, stepIndex: number) => void;
    recipeCategoryFilter: RecipeFilterCategory;
    setRecipeCategoryFilter: Dispatch<SetStateAction<RecipeFilterCategory>>;
    recommendOnlyReady: boolean;
    setRecommendOnlyReady: Dispatch<SetStateAction<boolean>>;
    visibleRecipeCards: RecipeCard[];
    toggleRecipeCard: (recipeId: string) => void;
  };
};

export function RecommendTab({ model }: RecommendTabProps) {
  const {
    selectedRecipe,
    setSelectedRecipeId,
    recommendActionMessage,
    addMissingToShopping,
    hasOwnedIngredient,
    getCheckedStepCount,
    recipeStepChecked,
    toggleRecipeStep,
    recipeCategoryFilter,
    setRecipeCategoryFilter,
    recommendOnlyReady,
    setRecommendOnlyReady,
    visibleRecipeCards,
    toggleRecipeCard,
  } = model;

  if (selectedRecipe) {
    return (
      <div className="space-y-4 p-4 pb-24">
        <button
          type="button"
          onClick={() => setSelectedRecipeId(null)}
          className="rounded-full bg-white px-4 py-2 text-sm font-semibold text-slate-700"
        >
          ← 추천 목록으로
        </button>

        {recommendActionMessage ? (
          <p className="rounded-xl border border-emerald-200 bg-emerald-50 px-3 py-2 text-sm text-emerald-700">
            {recommendActionMessage}
          </p>
        ) : null}

        <article className="rounded-3xl border border-slate-100 bg-white p-4 shadow-sm">
          <div className="mb-4 flex items-start gap-4">
            <div className="flex h-20 w-20 items-center justify-center rounded-2xl bg-orange-50 text-5xl">{selectedRecipe.image}</div>
            <div className="flex-1">
              <h3 className="text-3xl font-extrabold text-slate-900">{selectedRecipe.name}</h3>
              <div className="mt-2 flex flex-wrap items-center gap-2 text-sm text-slate-500">
                <span>⏱ {selectedRecipe.time}</span>
                <span>⭐ {selectedRecipe.difficulty}</span>
                <span className={`rounded-full px-2 py-0.5 text-xs font-semibold ${selectedRecipe.category === "baby" ? "bg-sky-100 text-sky-700" : "bg-orange-100 text-orange-700"}`}>
                  {selectedRecipe.category === "baby" ? "영유아" : "일반요리"}
                </span>
                <span className="rounded-full bg-rose-50 px-3 py-1 text-xs font-bold text-rose-600">일치율 {selectedRecipe.matchRate}%</span>
              </div>
            </div>
          </div>

          {selectedRecipe.missingMain.length > 0 ? (
            <div className="mb-4 rounded-xl border border-rose-100 bg-rose-50 p-3">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <div>
                  <p className="text-sm font-semibold text-rose-500">재료 {selectedRecipe.missingMain.length}개만 더 있으면 만들 수 있어요!</p>
                  <p className="text-xs text-rose-400">부족 재료: {selectedRecipe.missingMain.join(", ")}</p>
                </div>
                <button
                  type="button"
                  onClick={() => addMissingToShopping(selectedRecipe.missingMain, selectedRecipe.name)}
                  className="rounded-full bg-orange-500 px-4 py-2 text-sm font-semibold text-white"
                >
                  장보기
                </button>
              </div>
            </div>
          ) : (
            <p className="mb-4 rounded-xl bg-emerald-50 px-3 py-2 text-sm font-semibold text-emerald-700">지금 바로 만들 수 있어요 🎉</p>
          )}

          <div className="mb-4 space-y-2 rounded-lg bg-slate-50 p-3">
            <p className="text-xs font-semibold text-slate-500">레시피 재료</p>
            <div className="flex flex-wrap gap-2">
              {Array.from(new Set([...selectedRecipe.mainIngredients, ...selectedRecipe.subIngredients])).map((ingredient) => {
                const owned = hasOwnedIngredient(ingredient);

                return (
                  <span
                    key={`${selectedRecipe.id}-${ingredient}`}
                    className={`rounded-full px-2 py-1 text-xs font-semibold ${owned ? "bg-red-50 text-red-600" : "bg-slate-100 text-slate-600"}`}
                  >
                    {ingredient}
                  </span>
                );
              })}
            </div>
            <p className="text-[11px] text-slate-400">빨간 글씨 = 내 냉장고에 있는 재료</p>
          </div>

          <p className="text-xs font-semibold text-slate-500">
            조리 진행도: {getCheckedStepCount(selectedRecipe.id)} / {selectedRecipe.steps.length}
          </p>
          <ol className="mt-2 space-y-2 text-sm text-slate-700">
            {selectedRecipe.steps.map((step: string, index: number) => {
              const checked = (recipeStepChecked[selectedRecipe.id] ?? []).includes(index);

              return (
                <li key={`${selectedRecipe.id}-step-${index}`}>
                  <button
                    type="button"
                    onClick={() => toggleRecipeStep(selectedRecipe.id, index)}
                    className="flex w-full items-start gap-2 rounded-lg px-2 py-1 text-left hover:bg-slate-50"
                  >
                    <span className="pt-0.5 text-base" aria-hidden="true">{checked ? "✅" : "⬜️"}</span>
                    <span className={checked ? "text-slate-400 line-through" : "text-slate-700"}>
                      <span className="mr-1 font-semibold text-slate-500">{index + 1}.</span>
                      {step}
                    </span>
                  </button>
                </li>
              );
            })}
          </ol>

          <div className="mt-4 flex flex-wrap items-center gap-2">
            <a
              href={selectedRecipe.sourceUrl}
              target="_blank"
              rel="noreferrer"
              className="rounded-full bg-blue-50 px-3 py-1.5 text-xs font-semibold text-blue-600"
            >
              원문 레시피
            </a>
            <span className="text-xs text-slate-400">출처: {selectedRecipe.source}</span>
          </div>
        </article>
      </div>
    );
  }

  return (
    <div className="space-y-4 p-4 pb-24">
      <h2 className="text-[52px] font-extrabold tracking-tight text-slate-900">오늘 뭐 해먹지?</h2>
      <p className="text-2xl text-slate-500">내 냉장고 재료를 바탕으로 한 추천 메뉴입니다.</p>

      <div className="flex flex-wrap gap-2">
        {([
          ["all", "전체"],
          ["general", "일반요리"],
          ["baby", "영유아"],
        ] as const).map(([key, label]) => (
          <button
            key={key}
            type="button"
            onClick={() => setRecipeCategoryFilter(key)}
            className={`rounded-full px-4 py-2 text-sm font-semibold ${recipeCategoryFilter === key ? "bg-slate-900 text-white" : "bg-white text-slate-600"}`}
          >
            {label}
          </button>
        ))}

        <button
          type="button"
          onClick={() => setRecommendOnlyReady((prev) => !prev)}
          className={`rounded-full px-4 py-2 text-sm font-semibold ${recommendOnlyReady ? "bg-emerald-500 text-white" : "bg-white text-slate-600"}`}
        >
          {recommendOnlyReady ? "✅ 지금 바로 가능한 메뉴만" : "전체 메뉴 보기"}
        </button>
      </div>

      <p className="text-sm text-slate-400">총 {visibleRecipeCards.length}개 레시피를 표시 중입니다.</p>

      {recommendActionMessage ? (
        <p className="rounded-xl border border-emerald-200 bg-emerald-50 px-3 py-2 text-sm text-emerald-700">
          {recommendActionMessage}
        </p>
      ) : null}

      {visibleRecipeCards.length === 0 ? (
        <div className="rounded-2xl border border-slate-100 bg-white px-4 py-6 text-center text-slate-500">
          조건에 맞는 메뉴가 아직 없어요.
        </div>
      ) : null}

      {visibleRecipeCards.map((recipe) => (
        <article
          key={recipe.id}
          role="button"
          tabIndex={0}
          onClick={() => toggleRecipeCard(recipe.id)}
          onKeyDown={(event) => {
            if (event.key === "Enter" || event.key === " ") {
              event.preventDefault();
              toggleRecipeCard(recipe.id);
            }
          }}
          className="cursor-pointer rounded-3xl border border-slate-100 bg-white p-4 shadow-sm"
        >
          <div className="flex gap-4">
            <div className="flex h-24 w-24 items-center justify-center rounded-2xl bg-orange-50 text-5xl">{recipe.image}</div>
            <div className="flex-1">
              <div className="flex flex-wrap items-start justify-between gap-2">
                <h3 className="text-3xl font-extrabold text-slate-900">{recipe.name}</h3>
                <span className="rounded-full bg-rose-50 px-3 py-1 text-sm font-bold text-rose-600">일치율 {recipe.matchRate}%</span>
              </div>

              <div className="mt-2 flex flex-wrap items-center gap-2 text-sm text-slate-500">
                <span>⏱ {recipe.time}</span>
                <span>⭐ {recipe.difficulty}</span>
                <span className={`rounded-full px-2 py-0.5 text-xs font-semibold ${recipe.category === "baby" ? "bg-sky-100 text-sky-700" : "bg-orange-100 text-orange-700"}`}>
                  {recipe.category === "baby" ? "영유아" : "일반요리"}
                </span>
              </div>

              {recipe.missingMain.length > 0 ? (
                <div className="mt-3 border-t border-slate-100 pt-3">
                  <div className="flex items-center justify-between gap-2">
                    <div>
                      <p className="text-sm font-semibold text-rose-500">재료 {recipe.missingMain.length}개만 더 있으면 만들 수 있어요!</p>
                      <p className="text-xs text-rose-400">{recipe.missingMain.slice(0, 2).join(", ")}{recipe.missingMain.length > 2 ? ` 외 ${recipe.missingMain.length - 2}개` : ""}</p>
                    </div>
                    <button
                      type="button"
                      onTouchStart={(event) => event.stopPropagation()}
                      onClick={(event) => {
                        event.stopPropagation();
                        addMissingToShopping(recipe.missingMain, recipe.name);
                      }}
                      className="rounded-full bg-orange-500 px-4 py-2 text-sm font-semibold text-white"
                    >
                      장보기
                    </button>
                  </div>
                </div>
              ) : (
                <p className="mt-3 rounded-xl bg-emerald-50 px-3 py-2 text-sm font-semibold text-emerald-700">지금 바로 만들 수 있어요 🎉</p>
              )}

              <div className="mt-3 flex flex-wrap items-center gap-2">
                <span className="rounded-full bg-slate-900 px-3 py-1.5 text-xs font-semibold text-white">
                  카드 누르면 조리법 화면으로 이동
                </span>
                <a
                  href={recipe.sourceUrl}
                  target="_blank"
                  rel="noreferrer"
                  onTouchStart={(event) => event.stopPropagation()}
                  onClick={(event) => event.stopPropagation()}
                  className="rounded-full bg-blue-50 px-3 py-1.5 text-xs font-semibold text-blue-600"
                >
                  원문 레시피
                </a>
                <span className="text-xs text-slate-400">출처: {recipe.source}</span>
              </div>
            </div>
          </div>
        </article>
      ))}
    </div>
  );
}
