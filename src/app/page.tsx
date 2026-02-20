"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import type { Provider, Session, SupabaseClient } from "@supabase/supabase-js";
import { getSupabaseClient } from "@/lib/supabaseClient";

type TabKey = "home" | "fridge" | "recommend" | "shopping" | "settings";
type MeasureMode = "simple" | "precise";
type NoticeTone = "danger" | "warning" | "info";

type FridgeItem = {
  id: string;
  name: string;
  category: string;
  addedDate: string;
  expiryDate: string;
};

type ShoppingItem = {
  id: string;
  name: string;
  reason: string;
  recipeName?: string;
  checked: boolean;
};

type Notice = {
  id: string;
  message: string;
  tone: NoticeTone;
};

type Recipe = {
  id: string;
  name: string;
  image: string;
  time: string;
  difficulty: "쉬움" | "보통";
  mainIngredients: string[];
  subIngredients: string[];
};

type QuickItem = {
  name: string;
  category: string;
  defaultExpiryDays: number;
};

const LEGACY_STORAGE_KEYS = {
  fridgeItems: "our-fridge:v1:fridge-items",
  shoppingList: "our-fridge:v1:shopping-list",
  essentialItems: "our-fridge:v1:essential-items",
  measureMode: "our-fridge:v1:measure-mode",
} as const;

const OAUTH_PROVIDERS = [
  { key: "google", label: "Google로 로그인", icon: "🟢" },
  { key: "kakao", label: "카카오로 로그인", icon: "💬" },
  { key: "naver", label: "네이버로 로그인", icon: "🟩" },
] as const;

type OAuthProviderKey = (typeof OAUTH_PROVIDERS)[number]["key"];

type StorageKeys = {
  fridgeItems: string;
  shoppingList: string;
  essentialItems: string;
  measureMode: string;
};

const GUEST_STORAGE_USER_ID = "guest";

function getStorageKeys(userId: string): StorageKeys {
  return {
    fridgeItems: `our-fridge:v2:${userId}:fridge-items`,
    shoppingList: `our-fridge:v2:${userId}:shopping-list`,
    essentialItems: `our-fridge:v2:${userId}:essential-items`,
    measureMode: `our-fridge:v2:${userId}:measure-mode`,
  };
}

function migrateUserStorage(userId: string, guestKeys: StorageKeys): StorageKeys {
  const nextKeys = getStorageKeys(userId);

  if (typeof window === "undefined") {
    return nextKeys;
  }

  const hasScopedData = Object.values(nextKeys).some((key) => window.localStorage.getItem(key) !== null);

  if (hasScopedData) {
    return nextKeys;
  }

  const guestEntries: Array<[keyof StorageKeys, string]> = [
    ["fridgeItems", guestKeys.fridgeItems],
    ["shoppingList", guestKeys.shoppingList],
    ["essentialItems", guestKeys.essentialItems],
    ["measureMode", guestKeys.measureMode],
  ];

  let migratedFromGuest = false;

  for (const [field, guestKey] of guestEntries) {
    const guestValue = window.localStorage.getItem(guestKey);
    if (guestValue) {
      window.localStorage.setItem(nextKeys[field], guestValue);
      migratedFromGuest = true;
    }
  }

  if (migratedFromGuest) {
    return nextKeys;
  }

  const legacyEntries: Array<[keyof typeof LEGACY_STORAGE_KEYS, string]> = [
    ["fridgeItems", LEGACY_STORAGE_KEYS.fridgeItems],
    ["shoppingList", LEGACY_STORAGE_KEYS.shoppingList],
    ["essentialItems", LEGACY_STORAGE_KEYS.essentialItems],
    ["measureMode", LEGACY_STORAGE_KEYS.measureMode],
  ];

  for (const [field, legacyKey] of legacyEntries) {
    const legacyValue = window.localStorage.getItem(legacyKey);
    if (legacyValue) {
      window.localStorage.setItem(nextKeys[field], legacyValue);
    }
  }

  return nextKeys;
}

const QUICK_ITEMS: Array<{ title: string; items: QuickItem[] }> = [
  {
    title: "🥩 자주 쓰는 고기",
    items: [
      { name: "돼지고기 삼겹살", category: "육류", defaultExpiryDays: 3 },
      { name: "닭가슴살", category: "육류", defaultExpiryDays: 2 },
      { name: "스팸", category: "가공식품", defaultExpiryDays: 180 },
    ],
  },
  {
    title: "🥬 자주 쓰는 채소",
    items: [
      { name: "양파", category: "채소", defaultExpiryDays: 14 },
      { name: "대파", category: "채소", defaultExpiryDays: 7 },
      { name: "감자", category: "채소", defaultExpiryDays: 14 },
      { name: "버섯", category: "채소", defaultExpiryDays: 5 },
    ],
  },
  {
    title: "🥚 계란/유제품",
    items: [
      { name: "계란", category: "유제품", defaultExpiryDays: 21 },
      { name: "우유", category: "유제품", defaultExpiryDays: 7 },
      { name: "두부", category: "유제품", defaultExpiryDays: 7 },
    ],
  },
  {
    title: "🧂 기본 양념",
    items: [
      { name: "진간장", category: "양념", defaultExpiryDays: 365 },
      { name: "고추장", category: "양념", defaultExpiryDays: 180 },
      { name: "식용유", category: "양념", defaultExpiryDays: 365 },
    ],
  },
];

const RECIPES: Recipe[] = [
  {
    id: "r1",
    name: "돼지고기 김치찌개",
    image: "🥘",
    time: "20분",
    difficulty: "쉬움",
    mainIngredients: ["돼지고기 삼겹살", "김치", "양파", "대파"],
    subIngredients: ["다진마늘", "고춧가루", "국간장"],
  },
  {
    id: "r2",
    name: "계란말이",
    image: "🍳",
    time: "10분",
    difficulty: "쉬움",
    mainIngredients: ["계란", "대파"],
    subIngredients: ["소금", "식용유"],
  },
  {
    id: "r3",
    name: "스팸 볶음밥",
    image: "🍚",
    time: "15분",
    difficulty: "쉬움",
    mainIngredients: ["밥", "스팸", "계란", "양파"],
    subIngredients: ["진간장", "참기름", "식용유"],
  },
];

const MEASURE_GUIDE = [
  { icon: "🥄", title: "큰술 (T)", value: "밥숟가락 1개 = 약 15ml" },
  { icon: "🫖", title: "작은술 (t)", value: "티스푼 1개 = 약 5ml" },
  { icon: "🥛", title: "종이컵", value: "종이컵 1컵 = 약 180ml" },
  { icon: "🤏", title: "한 꼬집", value: "엄지+검지로 집은 양 = 약 1g" },
];

function readJson<T>(key: string, fallback: T): T {
  if (typeof window === "undefined") {
    return fallback;
  }

  const raw = window.localStorage.getItem(key);

  if (!raw) {
    return fallback;
  }

  try {
    return JSON.parse(raw) as T;
  } catch {
    return fallback;
  }
}

function toDateInputValue(date: Date): string {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");

  return `${year}-${month}-${day}`;
}

function dateAfter(days: number): string {
  const target = new Date();
  target.setDate(target.getDate() + Math.max(0, days));

  return toDateInputValue(target);
}

function getDaysDiff(dateText: string): number {
  const today = new Date();
  today.setHours(0, 0, 0, 0);

  const target = new Date(dateText);
  target.setHours(0, 0, 0, 0);

  return Math.ceil((target.getTime() - today.getTime()) / (1000 * 60 * 60 * 24));
}

function getCoupangLink(keyword: string): string {
  return `https://www.coupang.com/np/search?q=${encodeURIComponent(keyword)}`;
}

function toneClass(tone: NoticeTone): string {
  if (tone === "danger") {
    return "border-red-200 bg-red-50 text-red-700";
  }

  if (tone === "warning") {
    return "border-amber-200 bg-amber-50 text-amber-800";
  }

  return "border-blue-200 bg-blue-50 text-blue-700";
}

export default function HomePage() {
  const supabase = useMemo<SupabaseClient | null>(() => getSupabaseClient(), []);
  const [session, setSession] = useState<Session | null>(null);
  const [authLoading, setAuthLoading] = useState(Boolean(supabase));
  const [authError, setAuthError] = useState<string | null>(null);
  const [authPendingProvider, setAuthPendingProvider] = useState<OAuthProviderKey | null>(null);

  const [tab, setTab] = useState<TabKey>("home");
  const [fridgeItems, setFridgeItems] = useState<FridgeItem[]>([]);
  const [shoppingList, setShoppingList] = useState<ShoppingItem[]>([]);
  const [essentialItems, setEssentialItems] = useState<string[]>(["계란", "우유", "대파"]);
  const [measureMode, setMeasureMode] = useState<MeasureMode>("simple");
  const [activeStorageKeys, setActiveStorageKeys] = useState<StorageKeys | null>(null);
  const [notifEnabled, setNotifEnabled] = useState<boolean>(() => {
    if (typeof window === "undefined" || !("Notification" in window)) {
      return false;
    }

    return Notification.permission === "granted";
  });

  const [showQuickAdd, setShowQuickAdd] = useState(false);
  const [showManualAdd, setShowManualAdd] = useState(false);
  const [manualName, setManualName] = useState("");
  const [manualExpiryDays, setManualExpiryDays] = useState(7);
  const [newShoppingName, setNewShoppingName] = useState("");
  const [newEssentialName, setNewEssentialName] = useState("");
  const [showGuide, setShowGuide] = useState(false);
  const [dismissedNoticeIds, setDismissedNoticeIds] = useState<string[]>([]);

  const guestStorageKeys = useMemo(() => getStorageKeys(GUEST_STORAGE_USER_ID), []);

  const fridgeSeq = useRef(1);
  const shoppingSeq = useRef(1);

  useEffect(() => {
    if (!supabase) {
      return;
    }

    let mounted = true;

    const bootstrapSession = async () => {
      const { data, error } = await supabase.auth.getSession();

      if (!mounted) {
        return;
      }

      if (error) {
        setAuthError(error.message);
      }

      setSession(data.session);
      setAuthLoading(false);
    };

    bootstrapSession();

    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange((_event, nextSession) => {
      setSession(nextSession);
      setAuthLoading(false);
      setAuthPendingProvider(null);
    });

    return () => {
      mounted = false;
      subscription.unsubscribe();
    };
  }, [supabase]);

  useEffect(() => {
    const keys = session?.user?.id
      ? migrateUserStorage(session.user.id, guestStorageKeys)
      : guestStorageKeys;

    // eslint-disable-next-line react-hooks/set-state-in-effect
    setActiveStorageKeys(keys);
    setFridgeItems(readJson<FridgeItem[]>(keys.fridgeItems, []));
    setShoppingList(readJson<ShoppingItem[]>(keys.shoppingList, []));
    setEssentialItems(readJson<string[]>(keys.essentialItems, ["계란", "우유", "대파"]));

    const storedMode = readJson<string>(keys.measureMode, "simple");
    setMeasureMode(storedMode === "precise" ? "precise" : "simple");
    setDismissedNoticeIds([]);
    setTab("home");
  }, [guestStorageKeys, session?.user?.id]);

  useEffect(() => {
    if (!activeStorageKeys) {
      return;
    }

    window.localStorage.setItem(activeStorageKeys.fridgeItems, JSON.stringify(fridgeItems));
  }, [activeStorageKeys, fridgeItems]);

  useEffect(() => {
    if (!activeStorageKeys) {
      return;
    }

    window.localStorage.setItem(activeStorageKeys.shoppingList, JSON.stringify(shoppingList));
  }, [activeStorageKeys, shoppingList]);

  useEffect(() => {
    if (!activeStorageKeys) {
      return;
    }

    window.localStorage.setItem(activeStorageKeys.essentialItems, JSON.stringify(essentialItems));
  }, [activeStorageKeys, essentialItems]);

  useEffect(() => {
    if (!activeStorageKeys) {
      return;
    }

    window.localStorage.setItem(activeStorageKeys.measureMode, JSON.stringify(measureMode));
  }, [activeStorageKeys, measureMode]);

  useEffect(() => {
    fridgeSeq.current = Math.max(fridgeSeq.current, fridgeItems.length + 1);
  }, [fridgeItems.length]);

  useEffect(() => {
    shoppingSeq.current = Math.max(shoppingSeq.current, shoppingList.length + 1);
  }, [shoppingList.length]);

  const notices = useMemo<Notice[]>(() => {
    const result: Notice[] = [];

    const expired = fridgeItems.filter((item) => getDaysDiff(item.expiryDate) < 0);
    const urgent = fridgeItems.filter((item) => {
      const diff = getDaysDiff(item.expiryDate);
      return diff >= 0 && diff <= 3;
    });

    if (expired.length > 0) {
      result.push({
        id: `expired:${expired.map((item) => item.name).join(",")}`,
        message: `유통기한 지난 재료: ${expired.map((item) => item.name).join(", ")}`,
        tone: "danger",
      });
    }

    if (urgent.length > 0) {
      result.push({
        id: `urgent:${urgent.map((item) => item.name).join(",")}`,
        message: `3일 내 소진 필요: ${urgent.map((item) => item.name).join(", ")}`,
        tone: "warning",
      });
    }

    const fridgeNames = fridgeItems.map((item) => item.name.toLowerCase());
    const missingEssential = essentialItems.filter(
      (name) => !fridgeNames.some((fridgeName) => fridgeName.includes(name.toLowerCase())),
    );

    if (missingEssential.length > 0) {
      result.push({
        id: `essential:${missingEssential.join(",")}`,
        message: `필수 재료 부족: ${missingEssential.join(", ")}`,
        tone: "info",
      });
    }

    return result.filter((notice) => !dismissedNoticeIds.includes(notice.id));
  }, [dismissedNoticeIds, essentialItems, fridgeItems]);

  const sortedFridgeItems = useMemo(
    () => [...fridgeItems].sort((a, b) => getDaysDiff(a.expiryDate) - getDaysDiff(b.expiryDate)),
    [fridgeItems],
  );

  const recipeCards = useMemo(() => {
    const fridgeNames = fridgeItems.map((item) => item.name);

    return RECIPES.map((recipe) => {
      const hasMain = recipe.mainIngredients.filter((ingredient) =>
        fridgeNames.some((fridgeName) => ingredient.includes(fridgeName) || fridgeName.includes(ingredient)),
      );

      const missingMain = recipe.mainIngredients.filter(
        (ingredient) => !fridgeNames.some((fridgeName) => ingredient.includes(fridgeName) || fridgeName.includes(ingredient)),
      );

      const matchRate = Math.round((hasMain.length / recipe.mainIngredients.length) * 100);

      return {
        ...recipe,
        hasMain,
        missingMain,
        matchRate,
      };
    }).sort((a, b) => b.matchRate - a.matchRate);
  }, [fridgeItems]);

  const uncheckedShopping = shoppingList.filter((item) => !item.checked);
  const checkedShopping = shoppingList.filter((item) => item.checked);

  const addFridgeItem = (name: string, category: string, expiryDays: number) => {
    const trimmed = name.trim();

    if (!trimmed) {
      return;
    }

    const item: FridgeItem = {
      id: `fridge-${fridgeSeq.current}`,
      name: trimmed,
      category,
      addedDate: toDateInputValue(new Date()),
      expiryDate: dateAfter(expiryDays),
    };

    fridgeSeq.current += 1;
    setFridgeItems((prev) => [...prev, item]);
  };

  const addQuickItem = (item: QuickItem) => {
    addFridgeItem(item.name, item.category, item.defaultExpiryDays);
  };

  const addManualItem = () => {
    addFridgeItem(manualName, "기타", manualExpiryDays);
    setManualName("");
    setManualExpiryDays(7);
    setShowManualAdd(false);
  };

  const removeFridgeItem = (id: string) => {
    setFridgeItems((prev) => prev.filter((item) => item.id !== id));
  };

  const addShoppingItem = (name: string, reason: string, recipeName?: string) => {
    const trimmed = name.trim();

    if (!trimmed) {
      return;
    }

    setShoppingList((prev) => {
      if (prev.some((item) => item.name.toLowerCase() === trimmed.toLowerCase())) {
        return prev;
      }

      const nextItem: ShoppingItem = {
        id: `shopping-${shoppingSeq.current}`,
        name: trimmed,
        reason,
        recipeName,
        checked: false,
      };

      shoppingSeq.current += 1;
      return [...prev, nextItem];
    });
  };

  const addMissingToShopping = (items: string[], recipeName: string) => {
    items.forEach((itemName) => addShoppingItem(itemName, "레시피 부족 재료", recipeName));
  };

  const toggleShoppingCheck = (id: string) => {
    setShoppingList((prev) =>
      prev.map((item) => (item.id === id ? { ...item, checked: !item.checked } : item)),
    );
  };

  const removeShoppingItem = (id: string) => {
    setShoppingList((prev) => prev.filter((item) => item.id !== id));
  };

  const removeCheckedShopping = () => {
    setShoppingList((prev) => prev.filter((item) => !item.checked));
  };

  const addEssentialItem = () => {
    const trimmed = newEssentialName.trim();

    if (!trimmed) {
      return;
    }

    setEssentialItems((prev) => (prev.includes(trimmed) ? prev : [...prev, trimmed]));
    setNewEssentialName("");
  };

  const removeEssentialItem = (name: string) => {
    setEssentialItems((prev) => prev.filter((item) => item !== name));
  };

  const dismissNotice = (noticeId: string) => {
    setDismissedNoticeIds((prev) => [...prev, noticeId]);
  };

  const toggleNotification = async () => {
    if (!("Notification" in window)) {
      return;
    }

    if (notifEnabled) {
      setNotifEnabled(false);
      return;
    }

    const permission = await Notification.requestPermission();

    if (permission === "granted") {
      setNotifEnabled(true);
      new Notification("알림 설정 완료", {
        body: "유통기한 임박 재료를 알려드릴게요.",
      });
    }
  };

  const startOAuthLogin = async (providerKey: OAuthProviderKey) => {
    if (!supabase) {
      setAuthError("Supabase 설정이 없어 OAuth 로그인을 시작할 수 없습니다.");
      return;
    }

    setAuthError(null);
    setAuthPendingProvider(providerKey);

    const { error } = await supabase.auth.signInWithOAuth({
      provider: providerKey as Provider,
      options: {
        redirectTo: typeof window === "undefined" ? undefined : window.location.origin,
      },
    });

    if (error) {
      setAuthError(error.message);
      setAuthPendingProvider(null);
    }
  };

  const signOut = async () => {
    if (!supabase) {
      setSession(null);
      return;
    }

    await supabase.auth.signOut();
    setTab("home");
  };

  const renderHome = () => {
    const urgentItems = fridgeItems.filter((item) => {
      const diff = getDaysDiff(item.expiryDate);
      return diff >= 0 && diff <= 3;
    });

    const expiredItems = fridgeItems.filter((item) => getDaysDiff(item.expiryDate) < 0);

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
                  onClick={() => dismissNotice(notice.id)}
                  className="opacity-60 transition hover:opacity-100"
                  aria-label="알림 닫기"
                >
                  ✕
                </button>
              </div>
            ))}
          </div>
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
            onClick={() => setTab("fridge")}
            className="mt-4 w-full rounded-full bg-white px-4 py-2 text-xl font-semibold text-orange-600"
          >
            냉장고 관리하기
          </button>
        </section>

        <section className="grid grid-cols-2 gap-4">
          <button
            type="button"
            onClick={() => setTab("recommend")}
            className="rounded-3xl border border-slate-100 bg-white p-5 shadow-sm"
          >
            <div className="mx-auto flex h-14 w-14 items-center justify-center rounded-full bg-yellow-100 text-3xl">✨</div>
            <p className="mt-2 text-4xl font-bold text-slate-800">메뉴 추천</p>
          </button>
          <button
            type="button"
            onClick={() => setTab("shopping")}
            className="rounded-3xl border border-slate-100 bg-white p-5 shadow-sm"
          >
            <div className="mx-auto flex h-14 w-14 items-center justify-center rounded-full bg-emerald-100 text-3xl">🛒</div>
            <p className="mt-2 text-4xl font-bold text-slate-800">장보기 목록</p>
          </button>
        </section>

        {urgentItems.length > 0 || expiredItems.length > 0 ? (
          <section>
            <h3 className="mb-3 flex items-center gap-2 text-xl font-bold text-slate-800">
              <span aria-hidden="true">⚡</span>
              유통기한 임박!
            </h3>
            <div className="overflow-hidden rounded-2xl border border-slate-100 bg-white shadow-sm">
              {[...expiredItems, ...urgentItems].slice(0, 3).map((item) => {
                const diff = getDaysDiff(item.expiryDate);
                const badgeClass = diff < 0 ? "bg-red-100 text-red-600" : "bg-orange-100 text-orange-600";

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
  };

  const renderFridge = () => (
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
            type="number"
            min={1}
            value={manualExpiryDays}
            onChange={(event) => setManualExpiryDays(Number(event.target.value) || 1)}
            className="w-20 rounded-xl bg-slate-50 px-3 py-2 text-center text-sm outline-none ring-orange-300 focus:ring"
            aria-label="유통기한 일수"
          />
          <button
            type="button"
            onClick={addManualItem}
            className="rounded-xl bg-orange-500 px-4 py-2 text-sm font-bold text-white"
          >
            추가
          </button>
        </div>
      ) : null}

      {sortedFridgeItems.length === 0 ? (
        <div className="py-12 text-center text-slate-400">
          <div className="text-6xl">🧊</div>
          <p className="mt-2 text-xl">
            냉장고가 비어 있어요.
            <br />
            재료를 먼저 등록해 주세요.
          </p>
        </div>
      ) : (
        <div className="space-y-3">
          {sortedFridgeItems.map((item) => {
            const diff = getDaysDiff(item.expiryDate);
            const badgeClass = diff < 0
              ? "bg-red-100 text-red-600"
              : diff <= 3
                ? "bg-orange-100 text-orange-600"
                : "bg-slate-100 text-slate-600";

            return (
              <div key={item.id} className="flex items-center justify-between rounded-3xl border border-slate-100 bg-white p-4 shadow-sm">
                <div>
                  <h4 className="text-4xl font-extrabold text-slate-900">{item.name}</h4>
                  <p className="mt-1 text-base text-slate-400">등록: {item.addedDate}</p>
                </div>
                <div className="flex items-center gap-2">
                  <span className={`rounded-full px-3 py-1 text-xl font-bold ${badgeClass}`}>
                    {diff < 0 ? `D+${Math.abs(diff)}` : `D-${diff}`}
                  </span>
                  <button
                    type="button"
                    onClick={() => {
                      removeFridgeItem(item.id);
                      addShoppingItem(item.name, "재료 소진");
                    }}
                    className="p-1 text-2xl text-blue-500"
                    aria-label="장보기로 이동"
                  >
                    🛒
                  </button>
                  <button
                    type="button"
                    onClick={() => removeFridgeItem(item.id)}
                    className="p-1 text-2xl text-slate-300"
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
              {QUICK_ITEMS.map((category) => (
                <section key={category.title}>
                  <h4 className="mb-2 text-sm font-semibold text-slate-500">{category.title}</h4>
                  <div className="flex flex-wrap gap-2">
                    {category.items.map((item) => (
                      <button
                        key={item.name}
                        type="button"
                        onClick={() => addQuickItem(item)}
                        className="rounded-full bg-slate-100 px-3 py-1.5 text-sm transition hover:bg-orange-100 hover:text-orange-600"
                      >
                        + {item.name}
                      </button>
                    ))}
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

  const renderRecommend = () => (
    <div className="space-y-4 p-4 pb-24">
      <h2 className="text-[52px] font-extrabold tracking-tight text-slate-900">오늘 뭐 해먹지?</h2>
      <p className="text-2xl text-slate-500">내 냉장고 재료를 바탕으로 한 추천 메뉴입니다.</p>

      {recipeCards.map((recipe) => (
        <article key={recipe.id} className="rounded-3xl border border-slate-100 bg-white p-4 shadow-sm">
          <div className="flex gap-4">
            <div className="flex h-24 w-24 items-center justify-center rounded-2xl bg-orange-50 text-5xl">{recipe.image}</div>
            <div className="flex-1">
              <div className="flex flex-wrap items-start justify-between gap-2">
                <h3 className="text-5xl font-extrabold text-slate-900">{recipe.name}</h3>
                <span className="rounded-full bg-rose-50 px-3 py-1 text-2xl font-bold text-rose-600">일치율 {recipe.matchRate}%</span>
              </div>
              <p className="mt-2 text-2xl text-slate-500">⏱ {recipe.time} &nbsp; ⭐ {recipe.difficulty}</p>

              {recipe.missingMain.length > 0 ? (
                <div className="mt-3 border-t border-slate-100 pt-3">
                  <div className="flex items-center justify-between gap-2">
                    <p className="text-xl text-rose-400">부족: {recipe.missingMain.join(", ")}</p>
                    <button
                      type="button"
                      onClick={() => addMissingToShopping(recipe.missingMain, recipe.name)}
                      className="rounded-full bg-orange-500 px-4 py-2 text-sm font-semibold text-white"
                    >
                      장보기
                    </button>
                  </div>
                </div>
              ) : (
                <p className="mt-3 rounded-xl bg-emerald-50 px-3 py-2 text-sm font-semibold text-emerald-700">지금 바로 만들 수 있어요 🎉</p>
              )}
            </div>
          </div>
        </article>
      ))}
    </div>
  );

  const renderShopping = () => (
    <div className="space-y-4 p-4 pb-24">
      <div className="mb-2 flex items-center justify-between">
        <h2 className="text-5xl font-extrabold text-slate-900">장보기 목록</h2>
        {checkedShopping.length > 0 ? (
          <button type="button" onClick={removeCheckedShopping} className="text-sm text-slate-500">
            완료항목 비우기
          </button>
        ) : null}
      </div>

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

      {uncheckedShopping.length > 0 ? (
        <section className="space-y-2">
          <p className="text-sm font-semibold text-slate-500">사야 할 것 ({uncheckedShopping.length})</p>
          {uncheckedShopping.map((item) => (
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

      {checkedShopping.length > 0 ? (
        <section className="space-y-2 opacity-70">
          <p className="text-sm font-semibold text-slate-500">완료됨</p>
          {checkedShopping.map((item) => (
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
      ) : null}
    </div>
  );

  const renderSettings = () => (
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
            {MEASURE_GUIDE.map((guide) => (
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
    </div>
  );

  const renderTab = () => {
    if (tab === "fridge") return renderFridge();
    if (tab === "recommend") return renderRecommend();
    if (tab === "shopping") return renderShopping();
    if (tab === "settings") return renderSettings();
    return renderHome();
  };

  if (authLoading) {
    return (
      <main className="min-h-screen bg-slate-100">
        <div className="mx-auto flex min-h-screen w-full max-w-[430px] items-center justify-center border-x border-slate-200 bg-slate-50 shadow-2xl">
          <div className="text-center">
            <p className="text-3xl">🔐</p>
            <p className="mt-2 text-sm text-slate-500">로그인 상태를 확인하는 중입니다...</p>
          </div>
        </div>
      </main>
    );
  }

  // 게스트 모드에서도 앱을 바로 사용할 수 있습니다.

  const navItems: Array<{ key: TabKey; label: string; icon: string }> = [
    { key: "home", label: "홈", icon: "🏠" },
    { key: "fridge", label: "냉장고", icon: "🧊" },
    { key: "recommend", label: "추천", icon: "✨" },
    { key: "shopping", label: "장보기", icon: "🛒" },
    { key: "settings", label: "설정", icon: "⚙️" },
  ];

  return (
    <main className="min-h-screen bg-slate-100">
      <div className="mx-auto min-h-screen w-full max-w-[430px] border-x border-slate-200 bg-slate-50 shadow-2xl">
        <header className="sticky top-0 z-30 space-y-2 border-b border-slate-200 bg-white/95 px-4 py-2 backdrop-blur">
          <div className="flex items-center justify-between gap-2">
            <div className="min-w-0">
              <p className="truncate text-xs font-medium text-slate-600">
                {session?.user?.email ?? "게스트 모드 (로그인 없이 테스트 가능)"}
              </p>
              <p className="truncate text-[11px] text-slate-400">
                {session
                  ? "로그인 상태: 사용자 전용 데이터로 저장 중"
                  : "게스트 데이터는 로그인 시 자동으로 이어서 사용됩니다."}
              </p>
            </div>

            {session ? (
              <button
                type="button"
                onClick={signOut}
                className="rounded-full bg-slate-100 px-3 py-1 text-xs font-semibold text-slate-600"
              >
                로그아웃
              </button>
            ) : null}
          </div>

          {!session ? (
            <div className="flex gap-2 overflow-x-auto pb-1">
              {OAUTH_PROVIDERS.map((provider) => (
                <button
                  key={provider.key}
                  type="button"
                  onClick={() => startOAuthLogin(provider.key)}
                  disabled={authPendingProvider !== null}
                  className="shrink-0 rounded-full border border-slate-200 bg-white px-3 py-1 text-xs font-semibold text-slate-700 disabled:cursor-not-allowed disabled:opacity-60"
                >
                  {authPendingProvider === provider.key ? "연결 중..." : `${provider.icon} ${provider.label}`}
                </button>
              ))}
            </div>
          ) : null}

          {authError ? (
            <p className="rounded-xl border border-rose-200 bg-rose-50 px-3 py-2 text-xs text-rose-700">{authError}</p>
          ) : null}
        </header>

        {renderTab()}

        <nav className="fixed bottom-0 z-40 w-full max-w-[430px] border-t border-slate-200 bg-white px-1 pb-[calc(env(safe-area-inset-bottom)+6px)] pt-1 shadow-[0_-4px_6px_-1px_rgba(0,0,0,0.05)]">
          <div className="grid grid-cols-5">
            {navItems.map((item) => {
              const active = tab === item.key;

              return (
                <button
                  key={item.key}
                  type="button"
                  onClick={() => setTab(item.key)}
                  className={`flex min-h-[56px] flex-col items-center justify-center gap-1 rounded-xl text-[11px] font-semibold ${active ? "text-orange-500" : "text-slate-400"}`}
                >
                  <span className="text-lg" aria-hidden="true">{item.icon}</span>
                  {item.label}
                </button>
              );
            })}
          </div>
        </nav>
      </div>
    </main>
  );
}
