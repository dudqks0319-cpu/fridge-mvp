import type { Dispatch, SetStateAction } from "react";

export type NoticeTone = "danger" | "warning" | "info";

export type Notice = {
  id: string;
  message: string;
  tone: NoticeTone;
};

export type FridgeFilterStatus = "all" | "urgent" | "expired" | "safe";

export type FridgeItem = {
  id: string;
  name: string;
  category: string;
  addedDate: string;
  expiryDate: string;
  imageDataUrl?: string;
};

export type ShoppingItem = {
  id: string;
  name: string;
  reason: string;
  recipeName?: string;
  checked: boolean;
};

export type QuickItem = {
  name: string;
  category: string;
  defaultExpiryDays: number;
};

export type RecipeCategory = "general" | "baby";

export type RecipeFilterCategory = "all" | RecipeCategory;

export type RecipeCard = {
  id: string;
  name: string;
  image: string;
  category: RecipeCategory;
  time: string;
  difficulty: string;
  mainIngredients: string[];
  subIngredients: string[];
  steps: string[];
  source: string;
  sourceUrl: string;
  matchRate: number;
  missingMain: string[];
};

export type StringSetter = Dispatch<SetStateAction<string>>;
export type BooleanSetter = Dispatch<SetStateAction<boolean>>;
