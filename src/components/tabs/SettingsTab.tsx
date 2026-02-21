import type { Dispatch, SetStateAction } from "react";
import type { QuickItem } from "@/components/tabs/types";

type SettingsTabProps = {
  model: {
    measureMode: "simple" | "precise";
    setMeasureMode: Dispatch<SetStateAction<"simple" | "precise">>;
    showGuide: boolean;
    setShowGuide: Dispatch<SetStateAction<boolean>>;
    measureGuide: Array<{ icon: string; title: string; value: string }>;
    quickItemGroups: Array<{ title: string; items: QuickItem[] }>;
    quickAddEnabledItems: string[];
    setQuickAddEnabledItems: Dispatch<SetStateAction<string[]>>;
    quickAddEnabledNameSet: Set<string>;
    toggleQuickAddOption: (itemName: string) => void;
    toggleNotification: () => void | Promise<void>;
    notifEnabled: boolean;
    newEssentialName: string;
    setNewEssentialName: Dispatch<SetStateAction<string>>;
    addEssentialItem: () => void;
    essentialItems: string[];
    removeEssentialItem: (name: string) => void;
    exportAppData: () => Promise<void>;
    importAppData: () => void;
    importPayload: string;
    setImportPayload: Dispatch<SetStateAction<string>>;
    dataOpsMessage: string | null;
    allQuickItemNames: string[];
  };
};

export function SettingsTab({ model }: SettingsTabProps) {
  const {
    measureMode,
    setMeasureMode,
    showGuide,
    setShowGuide,
    measureGuide,
    quickItemGroups,
    quickAddEnabledItems,
    setQuickAddEnabledItems,
    quickAddEnabledNameSet,
    toggleQuickAddOption,
    toggleNotification,
    notifEnabled,
    newEssentialName,
    setNewEssentialName,
    addEssentialItem,
    essentialItems,
    removeEssentialItem,
    exportAppData,
    importAppData,
    importPayload,
    setImportPayload,
    dataOpsMessage,
    allQuickItemNames,
  } = model;

  return (
    <div className="space-y-8 p-4 pb-24">
      <h2 className="text-5xl font-extrabold text-slate-900">설정</h2>

      <section className="space-y-3">
        <h3 className="flex items-center gap-2 text-3xl font-bold text-slate-700">
          <span aria-hidden="true">⚖️</span>
          레시피 계량 단위
        </h3>
        <p className="text-xl text-slate-500">집에 계량컵/저울이 있으면 ml/g 모드, 없으면 간편 모드를 선택하세요.</p>

        <div className="grid grid-cols-2 gap-3">
          <button
            type="button"
            onClick={() => setMeasureMode("simple")}
            className={`rounded-2xl border-2 p-4 ${measureMode === "simple" ? "border-orange-500 bg-orange-50 text-orange-700" : "border-slate-100 bg-white text-slate-600"}`}
          >
            <div className="text-3xl">🥄</div>
            <p className="mt-1 text-2xl font-bold">간편 (숟가락)</p>
          </button>
          <button
            type="button"
            onClick={() => setMeasureMode("precise")}
            className={`rounded-2xl border-2 p-4 ${measureMode === "precise" ? "border-blue-500 bg-blue-50 text-blue-700" : "border-slate-100 bg-white text-slate-600"}`}
          >
            <div className="text-3xl">⚖️</div>
            <p className="mt-1 text-2xl font-bold">정밀 (ml/g)</p>
          </button>
        </div>

        <button type="button" onClick={() => setShowGuide((prev) => !prev)} className="w-full rounded-xl bg-orange-50 py-2 text-base font-semibold text-orange-600">
          📖 계량법 가이드 보기
        </button>

        {showGuide ? (
          <div className="space-y-2 rounded-2xl border border-slate-100 bg-white p-4">
            {measureGuide.map((guide) => (
              <div key={guide.title} className="flex items-center gap-3 rounded-xl bg-slate-50 p-3">
                <span className="text-2xl">{guide.icon}</span>
                <div>
                  <p className="text-sm font-semibold text-slate-800">{guide.title}</p>
                  <p className="text-xs text-slate-500">{guide.value}</p>
                </div>
              </div>
            ))}
          </div>
        ) : null}
      </section>

      <hr className="border-slate-100" />

      <section className="space-y-3">
        <h3 className="flex items-center gap-2 text-3xl font-bold text-slate-700">
          <span aria-hidden="true">⚡</span>
          빠른 재료 등록 항목
        </h3>
        <p className="text-xl text-slate-500">냉장고 화면의 빠른 등록에서 보여줄 재료를 직접 선택하세요.</p>

        <div className="flex flex-wrap gap-2">
          <button
            type="button"
            onClick={() => setQuickAddEnabledItems(allQuickItemNames)}
            className="rounded-full bg-slate-900 px-3 py-1.5 text-xs font-semibold text-white"
          >
            전체 선택
          </button>
          <button
            type="button"
            onClick={() => setQuickAddEnabledItems([])}
            className="rounded-full bg-slate-100 px-3 py-1.5 text-xs font-semibold text-slate-600"
          >
            전체 해제
          </button>
          <span className="rounded-full bg-orange-50 px-3 py-1.5 text-xs font-semibold text-orange-600">
            선택됨 {quickAddEnabledItems.length}개
          </span>
        </div>

        <div className="space-y-3 rounded-2xl border border-slate-100 bg-white p-4 shadow-sm">
          {quickItemGroups.map((group) => (
            <div key={group.title}>
              <p className="mb-2 text-sm font-semibold text-slate-500">{group.title}</p>
              <div className="flex flex-wrap gap-2">
                {group.items.map((item) => {
                  const enabled = quickAddEnabledNameSet.has(item.name);

                  return (
                    <button
                      key={`setting-${item.name}`}
                      type="button"
                      onClick={() => toggleQuickAddOption(item.name)}
                      className={`rounded-full px-3 py-1.5 text-sm font-semibold transition ${enabled ? "bg-orange-100 text-orange-700 ring-1 ring-orange-300" : "bg-slate-100 text-slate-600"}`}
                    >
                      {enabled ? "✓ " : "+ "}
                      {item.name}
                    </button>
                  );
                })}
              </div>
            </div>
          ))}
        </div>
      </section>

      <hr className="border-slate-100" />

      <section className="space-y-3">
        <h3 className="flex items-center gap-2 text-3xl font-bold text-slate-700">
          <span aria-hidden="true">🔔</span>
          유통기한 푸시 알림
        </h3>

        <div className="flex items-center justify-between rounded-2xl border border-slate-100 bg-white p-4 shadow-sm">
          <div>
            <p className="text-2xl font-semibold text-slate-800">알림 수신</p>
            <p className="mt-1 text-xl text-slate-500">유통기한 3일 전부터 알려드려요</p>
          </div>
          <button
            type="button"
            onClick={toggleNotification}
            className={`relative h-6 w-12 rounded-full ${notifEnabled ? "bg-orange-500" : "bg-slate-300"}`}
            aria-label="알림 토글"
          >
            <span className={`absolute top-1 h-4 w-4 rounded-full bg-white transition-transform ${notifEnabled ? "translate-x-7" : "translate-x-1"}`} />
          </button>
        </div>
      </section>

      <hr className="border-slate-100" />

      <section className="space-y-3">
        <h3 className="text-3xl font-bold text-slate-700">📌 항상 있어야 하는 필수 재료</h3>
        <p className="text-xl text-slate-500">재료가 소진되면 홈 화면에서 바로 알려드려요.</p>

        <div className="flex gap-2">
          <input
            value={newEssentialName}
            onChange={(event) => setNewEssentialName(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Enter") {
                addEssentialItem();
              }
            }}
            placeholder="예: 양파, 우유"
            className="flex-1 rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm outline-none focus:border-orange-400"
          />
          <button type="button" onClick={addEssentialItem} className="rounded-xl bg-slate-900 px-4 text-sm font-bold text-white">
            추가
          </button>
        </div>

        <div className="flex flex-wrap gap-2">
          {essentialItems.map((name) => (
            <span key={name} className="flex items-center gap-2 rounded-full bg-slate-100 px-3 py-1.5 text-sm text-slate-700">
              {name}
              <button type="button" onClick={() => removeEssentialItem(name)} className="text-slate-400" aria-label={`${name} 삭제`}>
                ✕
              </button>
            </span>
          ))}
        </div>
      </section>

      <hr className="border-slate-100" />

      <section className="space-y-3">
        <h3 className="text-3xl font-bold text-slate-700">💾 데이터 백업/복원</h3>
        <p className="text-xl text-slate-500">앱 데이터를 JSON으로 저장하거나 다시 불러올 수 있어요.</p>

        <div className="flex gap-2">
          <button
            type="button"
            onClick={exportAppData}
            className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white"
          >
            백업 JSON 만들기
          </button>
          <button
            type="button"
            onClick={importAppData}
            className="rounded-xl bg-orange-500 px-4 py-2 text-sm font-semibold text-white"
          >
            JSON 가져오기
          </button>
        </div>

        <textarea
          value={importPayload}
          onChange={(event) => setImportPayload(event.target.value)}
          placeholder="여기에 백업 JSON을 붙여넣어 주세요"
          className="h-32 w-full rounded-xl border border-slate-200 bg-white px-3 py-2 text-xs outline-none focus:border-orange-400"
        />

        {dataOpsMessage ? <p className="text-sm text-slate-500">{dataOpsMessage}</p> : null}
      </section>
    </div>
  );
}
