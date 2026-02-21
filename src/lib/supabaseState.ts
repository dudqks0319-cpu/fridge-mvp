import type { SupabaseClient } from "@supabase/supabase-js";

type MeasureMode = "simple" | "precise";

export type PersistedAppState = {
  fridgeItems: unknown[];
  shoppingList: unknown[];
  essentialItems: string[];
  measureMode: MeasureMode;
  quickAddEnabledItems: string[];
};

type StateRow = {
  user_id: string;
  payload: PersistedAppState;
  updated_at: string;
};

const APP_STATE_TABLE = "fridge_app_state";
const NO_ROW_ERROR_CODE = "PGRST116";

export function isTableOrPolicyError(error: { code?: string; message?: string } | null): boolean {
  if (!error) {
    return false;
  }

  if (error.code === "42501") {
    return true;
  }

  return Boolean(error.message?.includes("relation") || error.message?.includes("does not exist"));
}

export async function loadUserAppState(
  supabase: SupabaseClient,
  userId: string,
): Promise<PersistedAppState | null> {
  const { data, error } = await supabase
    .from(APP_STATE_TABLE)
    .select("payload")
    .eq("user_id", userId)
    .maybeSingle<StateRow>();

  if (error) {
    if (error.code === NO_ROW_ERROR_CODE) {
      return null;
    }

    throw error;
  }

  return data?.payload ?? null;
}

export async function saveUserAppState(
  supabase: SupabaseClient,
  userId: string,
  payload: PersistedAppState,
): Promise<void> {
  const row: StateRow = {
    user_id: userId,
    payload,
    updated_at: new Date().toISOString(),
  };

  const { error } = await supabase
    .from(APP_STATE_TABLE)
    .upsert(row, { onConflict: "user_id" });

  if (error) {
    throw error;
  }
}
