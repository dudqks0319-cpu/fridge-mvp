"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { Provider, Session, SupabaseClient } from "@supabase/supabase-js";
import { RECIPE_CATALOG, type RecipeCatalogItem, type RecipeCategory } from "@/data/recipeCatalog";
import { getSupabaseClient } from "@/lib/supabaseClient";
import {
  isTableOrPolicyError,
  loadUserAppState,
  saveUserAppState,
  type PersistedAppState,
} from "@/lib/supabaseState";
import { HomeTab } from "@/components/tabs/HomeTab";
import { FridgeTab } from "@/components/tabs/FridgeTab";
import { RecommendTab } from "@/components/tabs/RecommendTab";
import { ShoppingTab } from "@/components/tabs/ShoppingTab";
import { SettingsTab } from "@/components/tabs/SettingsTab";

type TabKey = "home" | "fridge" | "recommend" | "shopping" | "settings";
type MeasureMode = "simple" | "precise";
type NoticeTone = "danger" | "warning" | "info";
type FridgeFilterStatus = "all" | "safe" | "urgent" | "expired";

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

type Recipe = RecipeCatalogItem;
type RecipeFilterCategory = "all" | RecipeCategory;

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
  quickAddItems: "our-fridge:v1:quick-add-items",
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
  quickAddItems: string;
};

const GUEST_STORAGE_USER_ID = "guest";

function getStorageKeys(userId: string): StorageKeys {
  return {
    fridgeItems: `our-fridge:v2:${userId}:fridge-items`,
    shoppingList: `our-fridge:v2:${userId}:shopping-list`,
    essentialItems: `our-fridge:v2:${userId}:essential-items`,
    measureMode: `our-fridge:v2:${userId}:measure-mode`,
    quickAddItems: `our-fridge:v2:${userId}:quick-add-items`,
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
    ["quickAddItems", guestKeys.quickAddItems],
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
    ["quickAddItems", LEGACY_STORAGE_KEYS.quickAddItems],
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

const QUICK_ITEM_NAME_LIST = Array.from(
  new Set(QUICK_ITEMS.flatMap((group) => group.items.map((item) => item.name))),
);

const RECIPES: Recipe[] = RECIPE_CATALOG;

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
  } catch (error) {
    reportError(`readJson(${key})`, error);
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

function getExpiryState(dateText: string): Exclude<FridgeFilterStatus, "all"> {
  const diff = getDaysDiff(dateText);

  if (diff < 0) {
    return "expired";
  }

  if (diff <= 3) {
    return "urgent";
  }

  return "safe";
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

function createUniqueId(prefix: "fridge" | "shopping"): string {
  return `${prefix}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

function ensureUniqueIds<T extends { id: string }>(items: T[], prefix: "fridge" | "shopping"): T[] {
  const seen = new Set<string>();

  return items.map((item) => {
    if (!item.id || seen.has(item.id)) {
      const nextId = createUniqueId(prefix);
      seen.add(nextId);
      return { ...item, id: nextId };
    }

    seen.add(item.id);
    return item;
  });
}

const INGREDIENT_NAME_MAX_LENGTH = 30;
const INGREDIENT_NAME_PATTERN = /^[\p{L}\p{N}\s()\-·,./]+$/u;

function reportError(scope: string, error: unknown): void {
  console.error(`[fridge-mvp] ${scope}`, error);
}

function normalizeIngredientName(raw: string): string {
  return raw.replace(/\s+/g, " ").trim();
}

function validateIngredientName(raw: string): { ok: true; value: string } | { ok: false; reason: string } {
  const normalized = normalizeIngredientName(raw);

  if (!normalized) {
    return { ok: false, reason: "재료명을 입력해 주세요." };
  }

  if (normalized.length > INGREDIENT_NAME_MAX_LENGTH) {
    return { ok: false, reason: `재료명은 ${INGREDIENT_NAME_MAX_LENGTH}자 이하로 입력해 주세요.` };
  }

  if (!INGREDIENT_NAME_PATTERN.test(normalized)) {
    return { ok: false, reason: "재료명에는 한글/영문/숫자와 기본 기호(-,/,.)만 사용할 수 있어요." };
  }

  return { ok: true, value: normalized };
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
  const [quickAddEnabledItems, setQuickAddEnabledItems] = useState<string[]>(QUICK_ITEM_NAME_LIST);
  const [notifEnabled, setNotifEnabled] = useState<boolean>(() => {
    if (typeof window === "undefined" || !("Notification" in window)) {
      return false;
    }

    return Notification.permission === "granted";
  });

  const [showQuickAdd, setShowQuickAdd] = useState(false);
  const [showManualAdd, setShowManualAdd] = useState(false);
  const [manualName, setManualName] = useState("");
  const [manualExpiryDate, setManualExpiryDate] = useState(() => dateAfter(7));
  const [newShoppingName, setNewShoppingName] = useState("");
  const [shoppingSearch, setShoppingSearch] = useState("");
  const [newEssentialName, setNewEssentialName] = useState("");
  const [showGuide, setShowGuide] = useState(false);
  const [dismissedNoticeIds, setDismissedNoticeIds] = useState<string[]>([]);
  const [fridgeSearch, setFridgeSearch] = useState("");
  const [fridgeFilterStatus, setFridgeFilterStatus] = useState<FridgeFilterStatus>("all");
  const [fridgeFilterCategory, setFridgeFilterCategory] = useState("전체");
  const [recommendOnlyReady, setRecommendOnlyReady] = useState(false);
  const [recipeCategoryFilter, setRecipeCategoryFilter] = useState<RecipeFilterCategory>("all");
  const [selectedRecipeId, setSelectedRecipeId] = useState<string | null>(null);
  const [recipeStepChecked, setRecipeStepChecked] = useState<Record<string, number[]>>({});
  const [fridgeActionMessage, setFridgeActionMessage] = useState<string | null>(null);
  const [recommendActionMessage, setRecommendActionMessage] = useState<string | null>(null);
  const [editingExpiryTarget, setEditingExpiryTarget] = useState<FridgeItem | null>(null);
  const [editingExpiryDate, setEditingExpiryDate] = useState(() => dateAfter(7));
  const [importPayload, setImportPayload] = useState("");
  const [dataOpsMessage, setDataOpsMessage] = useState<string | null>(null);

  const guestStorageKeys = useMemo(() => getStorageKeys(GUEST_STORAGE_USER_ID), []);
  const activeStorageKeys = session?.user?.id ? getStorageKeys(session.user.id) : guestStorageKeys;
  const supabaseSyncBlockedRef = useRef(true);

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
    let mounted = true;
    supabaseSyncBlockedRef.current = true;

    const keys = session?.user?.id
      ? migrateUserStorage(session.user.id, guestStorageKeys)
      : guestStorageKeys;

    const applyPersistedState = (state: PersistedAppState) => {
      if (Array.isArray(state.fridgeItems)) {
        setFridgeItems(ensureUniqueIds(state.fridgeItems as FridgeItem[], "fridge"));
      }

      if (Array.isArray(state.shoppingList)) {
        setShoppingList(ensureUniqueIds(state.shoppingList as ShoppingItem[], "shopping"));
      }

      if (Array.isArray(state.essentialItems)) {
        setEssentialItems(state.essentialItems);
      }

      if (state.measureMode === "simple" || state.measureMode === "precise") {
        setMeasureMode(state.measureMode);
      }

      if (Array.isArray(state.quickAddEnabledItems)) {
        const sanitizedQuickAddItems = state.quickAddEnabledItems.filter((name) => QUICK_ITEM_NAME_LIST.includes(name));
        setQuickAddEnabledItems(sanitizedQuickAddItems);
      }
    };

    const hydrateState = async () => {
      const loadedFridgeItems = ensureUniqueIds(readJson<FridgeItem[]>(keys.fridgeItems, []), "fridge");
      const loadedShoppingItems = ensureUniqueIds(readJson<ShoppingItem[]>(keys.shoppingList, []), "shopping");

      setFridgeItems(loadedFridgeItems);
      setShoppingList(loadedShoppingItems);
      setEssentialItems(readJson<string[]>(keys.essentialItems, ["계란", "우유", "대파"]));

      const storedQuickAddItems = readJson<string[]>(keys.quickAddItems, QUICK_ITEM_NAME_LIST);
      const sanitizedQuickAddItems = storedQuickAddItems.filter((name) => QUICK_ITEM_NAME_LIST.includes(name));
      const hasStoredQuickAddKey = typeof window !== "undefined" && window.localStorage.getItem(keys.quickAddItems) !== null;
      setQuickAddEnabledItems(hasStoredQuickAddKey ? sanitizedQuickAddItems : QUICK_ITEM_NAME_LIST);

      const storedMode = readJson<string>(keys.measureMode, "simple");
      setMeasureMode(storedMode === "precise" ? "precise" : "simple");
      setDismissedNoticeIds([]);
      setTab("home");

      if (session?.user?.id && supabase) {
        try {
          const remoteState = await loadUserAppState(supabase, session.user.id);

          if (mounted && remoteState) {
            applyPersistedState(remoteState);
          }
        } catch (error) {
          if (!mounted) {
            return;
          }

          if (isTableOrPolicyError(error as { code?: string; message?: string })) {
            setDataOpsMessage("Supabase 동기화 테이블 또는 RLS 정책이 없어 로컬 저장 모드로 동작 중입니다.");
          } else {
            reportError("loadUserAppState", error);
            setDataOpsMessage("Supabase 동기화 중 오류가 발생해 로컬 저장 모드로 동작합니다.");
          }
        }
      }

      if (mounted) {
        supabaseSyncBlockedRef.current = false;
      }
    };

    hydrateState();

    return () => {
      mounted = false;
      supabaseSyncBlockedRef.current = true;
    };
  }, [guestStorageKeys, session?.user?.id, supabase]);

  useEffect(() => {
    window.localStorage.setItem(activeStorageKeys.fridgeItems, JSON.stringify(fridgeItems));
  }, [activeStorageKeys, fridgeItems]);

  useEffect(() => {
    window.localStorage.setItem(activeStorageKeys.shoppingList, JSON.stringify(shoppingList));
  }, [activeStorageKeys, shoppingList]);

  useEffect(() => {
    window.localStorage.setItem(activeStorageKeys.essentialItems, JSON.stringify(essentialItems));
  }, [activeStorageKeys, essentialItems]);

  useEffect(() => {
    window.localStorage.setItem(activeStorageKeys.measureMode, JSON.stringify(measureMode));
  }, [activeStorageKeys, measureMode]);

  useEffect(() => {
    window.localStorage.setItem(activeStorageKeys.quickAddItems, JSON.stringify(quickAddEnabledItems));
  }, [activeStorageKeys, quickAddEnabledItems]);

  useEffect(() => {
    if (!session?.user?.id || !supabase || supabaseSyncBlockedRef.current) {
      return;
    }

    const payload: PersistedAppState = {
      fridgeItems,
      shoppingList,
      essentialItems,
      measureMode,
      quickAddEnabledItems,
    };

    const syncTimer = window.setTimeout(async () => {
      try {
        await saveUserAppState(supabase, session.user.id, payload);
      } catch (error) {
        if (isTableOrPolicyError(error as { code?: string; message?: string })) {
          setDataOpsMessage("Supabase 동기화 테이블 또는 RLS 정책이 없어 로컬 저장 모드로 동작 중입니다.");
        } else {
          reportError("saveUserAppState", error);
          setDataOpsMessage("Supabase 저장 중 오류가 발생해 로컬 저장 모드로 동작합니다.");
        }
      }
    }, 250);

    return () => window.clearTimeout(syncTimer);
  }, [
    essentialItems,
    fridgeItems,
    measureMode,
    quickAddEnabledItems,
    session?.user?.id,
    shoppingList,
    supabase,
  ]);

  const fridgeNamesLower = useMemo(
    () => fridgeItems.map((item) => normalizeIngredientName(item.name).toLowerCase()),
    [fridgeItems],
  );

  const fridgeTokenIndex = useMemo(() => {
    const tokenSet = new Set<string>();

    fridgeNamesLower.forEach((name) => {
      tokenSet.add(name);
      name
        .split(/[\s,./()]+/)
        .map((token) => token.trim())
        .filter(Boolean)
        .forEach((token) => tokenSet.add(token));
    });

    return tokenSet;
  }, [fridgeNamesLower]);

  const quickSelectedNames = useMemo(
    () => new Set(fridgeItems.map((item) => item.name.trim().toLowerCase())),
    [fridgeItems],
  );

  const quickAddEnabledNameSet = useMemo(
    () => new Set(quickAddEnabledItems),
    [quickAddEnabledItems],
  );

  const configuredQuickItems = useMemo(
    () => QUICK_ITEMS
      .map((group) => ({
        ...group,
        items: group.items.filter((item) => quickAddEnabledNameSet.has(item.name)),
      }))
      .filter((group) => group.items.length > 0),
    [quickAddEnabledNameSet],
  );

  const ingredientMatchesFridge = useCallback((ingredient: string) => {
    const normalized = normalizeIngredientName(ingredient).toLowerCase();

    if (fridgeTokenIndex.has(normalized)) {
      return true;
    }

    const ingredientTokens = normalized
      .split(/[\s,./()]+/)
      .map((token) => token.trim())
      .filter(Boolean);

    if (ingredientTokens.some((token) => fridgeTokenIndex.has(token))) {
      return true;
    }

    return fridgeNamesLower.some(
      (fridgeName) => normalized.includes(fridgeName) || fridgeName.includes(normalized),
    );
  }, [fridgeNamesLower, fridgeTokenIndex]);

  const hasOwnedIngredient = useCallback((ingredient: string) => ingredientMatchesFridge(ingredient), [ingredientMatchesFridge]);

  const missingEssentialItems = useMemo(() => {
    return essentialItems.filter(
      (name) => !fridgeNamesLower.some((fridgeName) => fridgeName.includes(name.toLowerCase())),
    );
  }, [essentialItems, fridgeNamesLower]);

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

    if (missingEssentialItems.length > 0) {
      result.push({
        id: `essential:${missingEssentialItems.join(",")}`,
        message: `필수 재료 부족: ${missingEssentialItems.join(", ")}`,
        tone: "info",
      });
    }

    return result.filter((notice) => !dismissedNoticeIds.includes(notice.id));
  }, [dismissedNoticeIds, fridgeItems, missingEssentialItems]);

  const sortedFridgeItems = useMemo(
    () => [...fridgeItems].sort((a, b) => getDaysDiff(a.expiryDate) - getDaysDiff(b.expiryDate)),
    [fridgeItems],
  );

  const fridgeCategories = useMemo(
    () => ["전체", ...Array.from(new Set(fridgeItems.map((item) => item.category)))],
    [fridgeItems],
  );

  const filteredFridgeItems = useMemo(() => {
    return sortedFridgeItems.filter((item) => {
      const matchSearch = item.name.toLowerCase().includes(fridgeSearch.trim().toLowerCase());

      if (!matchSearch) {
        return false;
      }

      if (fridgeFilterCategory !== "전체" && item.category !== fridgeFilterCategory) {
        return false;
      }

      if (fridgeFilterStatus !== "all" && getExpiryState(item.expiryDate) !== fridgeFilterStatus) {
        return false;
      }

      return true;
    });
  }, [fridgeFilterCategory, fridgeFilterStatus, fridgeSearch, sortedFridgeItems]);

  const recipeCards = useMemo(() => {
    return RECIPES.map((recipe) => {
      const hasMain = recipe.mainIngredients.filter((ingredient) => ingredientMatchesFridge(ingredient));
      const missingMain = recipe.mainIngredients.filter((ingredient) => !ingredientMatchesFridge(ingredient));

      const denominator = Math.max(recipe.mainIngredients.length, 1);
      const matchRate = Math.round((hasMain.length / denominator) * 100);

      return {
        ...recipe,
        hasMain,
        missingMain,
        matchRate,
      };
    }).sort((a, b) => b.matchRate - a.matchRate);
  }, [ingredientMatchesFridge]);

  const visibleRecipeCards = useMemo(
    () =>
      recipeCards.filter((recipe) => {
        if (recommendOnlyReady && recipe.missingMain.length > 0) {
          return false;
        }

        if (recipeCategoryFilter !== "all" && recipe.category !== recipeCategoryFilter) {
          return false;
        }

        return true;
      }),
    [recipeCards, recommendOnlyReady, recipeCategoryFilter],
  );

  const selectedRecipe = useMemo(
    () => recipeCards.find((recipe) => recipe.id === selectedRecipeId) ?? null,
    [recipeCards, selectedRecipeId],
  );

  const uncheckedShopping = shoppingList.filter((item) => !item.checked);
  const checkedShopping = shoppingList.filter((item) => item.checked);

  const normalizedShoppingSearch = shoppingSearch.trim().toLowerCase();
  const visibleUncheckedShopping = uncheckedShopping.filter((item) =>
    item.name.toLowerCase().includes(normalizedShoppingSearch),
  );
  const visibleCheckedShopping = checkedShopping.filter((item) =>
    item.name.toLowerCase().includes(normalizedShoppingSearch),
  );

  const addFridgeItem = (name: string, category: string, expiryDate: string) => {
    const validation = validateIngredientName(name);

    if (!validation.ok) {
      setFridgeActionMessage(validation.reason);
      return;
    }

    const item: FridgeItem = {
      id: createUniqueId("fridge"),
      name: validation.value,
      category,
      addedDate: toDateInputValue(new Date()),
      expiryDate,
    };

    setFridgeItems((prev) => [...prev, item]);
    setFridgeSearch("");
    setFridgeFilterStatus("all");
    setFridgeFilterCategory("전체");
    setFridgeActionMessage(`"${validation.value}" 재료를 추가했습니다.`);
  };

  const toggleQuickItem = (item: QuickItem) => {
    const normalized = item.name.trim().toLowerCase();
    const isSelected = fridgeItems.some(
      (fridgeItem) => fridgeItem.name.trim().toLowerCase() === normalized,
    );

    if (isSelected) {
      setFridgeItems((prev) =>
        prev.filter((fridgeItem) => fridgeItem.name.trim().toLowerCase() !== normalized),
      );

      if (editingExpiryTarget?.name.trim().toLowerCase() === normalized) {
        setEditingExpiryTarget(null);
      }

      setFridgeActionMessage(`"${item.name}" 재료 선택을 해제했습니다.`);
      return;
    }

    addFridgeItem(item.name, item.category, dateAfter(item.defaultExpiryDays));
  };

  const toggleQuickAddOption = (itemName: string) => {
    setQuickAddEnabledItems((prev) => {
      if (prev.includes(itemName)) {
        return prev.filter((name) => name !== itemName);
      }

      return [...prev, itemName];
    });
  };

  const addManualItem = () => {
    if (!manualExpiryDate) {
      setFridgeActionMessage("유통기한 날짜를 선택해 주세요.");
      return;
    }

    addFridgeItem(manualName, "기타", manualExpiryDate);
    setManualName("");
    setManualExpiryDate(dateAfter(7));
    setShowManualAdd(false);
  };

  const removeFridgeItem = (id: string) => {
    const target = fridgeItems.find((item) => item.id === id);

    setFridgeItems((prev) => prev.filter((item) => item.id !== id));

    if (target) {
      setFridgeActionMessage(`"${target.name}" 재료를 삭제했습니다.`);
    }

    if (editingExpiryTarget?.id === id) {
      setEditingExpiryTarget(null);
    }
  };

  const openExpiryEditor = (item: FridgeItem) => {
    setEditingExpiryTarget(item);
    setEditingExpiryDate(item.expiryDate);
  };

  const saveExpiryDate = () => {
    if (!editingExpiryTarget) {
      return;
    }

    if (!editingExpiryDate) {
      setFridgeActionMessage("유통기한 날짜를 선택해 주세요.");
      return;
    }

    setFridgeItems((prev) =>
      prev.map((item) =>
        item.id === editingExpiryTarget.id
          ? { ...item, expiryDate: editingExpiryDate }
          : item,
      ),
    );
    setFridgeActionMessage(`"${editingExpiryTarget.name}" 유통기한을 ${editingExpiryDate}로 변경했습니다.`);
    setEditingExpiryTarget(null);
  };

  const addShoppingItem = (name: string, reason: string, recipeName?: string): boolean => {
    const validation = validateIngredientName(name);

    if (!validation.ok) {
      setDataOpsMessage(validation.reason);
      return false;
    }

    let added = false;

    setShoppingList((prev) => {
      if (prev.some((item) => item.name.toLowerCase() === validation.value.toLowerCase())) {
        return prev;
      }

      const nextItem: ShoppingItem = {
        id: createUniqueId("shopping"),
        name: validation.value,
        reason,
        recipeName,
        checked: false,
      };

      added = true;
      return [...prev, nextItem];
    });

    return added;
  };

  const addMissingToShopping = (items: string[], recipeName: string) => {
    let addedCount = 0;

    items.forEach((itemName) => {
      if (addShoppingItem(itemName, "레시피 부족 재료", recipeName)) {
        addedCount += 1;
      }
    });

    if (addedCount > 0) {
      setRecommendActionMessage(`"${recipeName}" 부족 재료 ${addedCount}개를 장보기에 담았습니다.`);
      return;
    }

    setRecommendActionMessage("이미 장보기 목록에 있는 재료입니다.");
  };

  const addMissingEssentialToShopping = () => {
    missingEssentialItems.forEach((itemName) => addShoppingItem(itemName, "필수 재료 부족"));
    setDataOpsMessage(`부족한 필수 재료 ${missingEssentialItems.length}개를 장보기 목록에 추가했습니다.`);
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

  const moveCheckedShoppingToFridge = () => {
    const picked = shoppingList.filter((item) => item.checked);

    if (picked.length === 0) {
      return;
    }

    setFridgeItems((prev) => [
      ...prev,
      ...picked.map((item) => ({
        id: createUniqueId("fridge"),
        name: item.name,
        category: "기타",
        addedDate: toDateInputValue(new Date()),
        expiryDate: dateAfter(7),
      })),
    ]);

    setShoppingList((prev) => prev.filter((item) => !item.checked));
    setDataOpsMessage(`체크된 ${picked.length}개 항목을 냉장고로 이동했습니다.`);
  };

  const addEssentialItem = () => {
    const validation = validateIngredientName(newEssentialName);

    if (!validation.ok) {
      setDataOpsMessage(validation.reason);
      return;
    }

    setEssentialItems((prev) => (prev.includes(validation.value) ? prev : [...prev, validation.value]));
    setNewEssentialName("");
  };

  const removeEssentialItem = (name: string) => {
    setEssentialItems((prev) => prev.filter((item) => item !== name));
  };

  const exportAppData = async () => {
    const payload = {
      fridgeItems,
      shoppingList,
      essentialItems,
      measureMode,
      quickAddEnabledItems,
      exportedAt: new Date().toISOString(),
    };

    const serialized = JSON.stringify(payload, null, 2);
    setImportPayload(serialized);

    try {
      await navigator.clipboard.writeText(serialized);
      setDataOpsMessage("데이터 백업 JSON을 클립보드에 복사했습니다.");
    } catch (error) {
      reportError("exportAppData.clipboardWrite", error);
      setDataOpsMessage("데이터 백업 JSON을 아래 텍스트 영역에 준비했습니다.");
    }
  };

  const importAppData = () => {
    if (!importPayload.trim()) {
      setDataOpsMessage("가져올 JSON 데이터를 먼저 입력해 주세요.");
      return;
    }

    try {
      const parsed = JSON.parse(importPayload) as {
        fridgeItems?: FridgeItem[];
        shoppingList?: ShoppingItem[];
        essentialItems?: string[];
        measureMode?: MeasureMode;
        quickAddEnabledItems?: string[];
      };

      if (Array.isArray(parsed.fridgeItems)) {
        setFridgeItems(ensureUniqueIds(parsed.fridgeItems, "fridge"));
      }

      if (Array.isArray(parsed.shoppingList)) {
        setShoppingList(ensureUniqueIds(parsed.shoppingList, "shopping"));
      }

      if (Array.isArray(parsed.essentialItems)) {
        setEssentialItems(parsed.essentialItems);
      }

      if (parsed.measureMode === "simple" || parsed.measureMode === "precise") {
        setMeasureMode(parsed.measureMode);
      }

      if (Array.isArray(parsed.quickAddEnabledItems)) {
        const sanitizedQuickAddItems = parsed.quickAddEnabledItems.filter((name) => QUICK_ITEM_NAME_LIST.includes(name));
        setQuickAddEnabledItems(sanitizedQuickAddItems);
      }

      setDataOpsMessage("데이터를 성공적으로 가져왔습니다.");
    } catch (error) {
      reportError("importAppData", error);
      setDataOpsMessage("JSON 형식을 확인해 주세요. 데이터 가져오기에 실패했습니다.");
    }
  };

  const dismissNotice = (noticeId: string) => {
    setDismissedNoticeIds((prev) => [...prev, noticeId]);
  };

  const toggleRecipeStep = (recipeId: string, stepIndex: number) => {
    setRecipeStepChecked((prev) => {
      const next = new Set(prev[recipeId] ?? []);

      if (next.has(stepIndex)) {
        next.delete(stepIndex);
      } else {
        next.add(stepIndex);
      }

      return {
        ...prev,
        [recipeId]: Array.from(next).sort((a, b) => a - b),
      };
    });
  };

  const toggleRecipeCard = (recipeId: string) => {
    setSelectedRecipeId((prev) => (prev === recipeId ? null : recipeId));
  };

  const getCheckedStepCount = (recipeId: string) => recipeStepChecked[recipeId]?.length ?? 0;

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

  const renderHome = () => (
    <HomeTab
      fridgeItems={fridgeItems}
      notices={notices}
      missingEssentialItems={missingEssentialItems}
      onDismissNotice={dismissNotice}
      onGoFridge={() => setTab("fridge")}
      onGoRecommend={() => setTab("recommend")}
      onGoShopping={() => setTab("shopping")}
      onAddMissingEssentialToShopping={addMissingEssentialToShopping}
      getDaysDiff={getDaysDiff}
      toneClass={toneClass}
    />
  );

  const renderFridge = () => (
    <FridgeTab
      model={{
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
      }}
    />
  );

  const renderRecommend = () => (
    <RecommendTab
      model={{
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
      }}
    />
  );

  const renderShopping = () => (
    <ShoppingTab
      model={{
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
      }}
    />
  );

  const renderSettings = () => (
    <SettingsTab
      model={{
        measureMode,
        setMeasureMode,
        showGuide,
        setShowGuide,
        measureGuide: MEASURE_GUIDE,
        quickItemGroups: QUICK_ITEMS,
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
        allQuickItemNames: QUICK_ITEM_NAME_LIST,
      }}
    />
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
