#!/usr/bin/env python3
"""Sync Flutter recipe/ingredient catalog from src/data/recipeCatalog.ts.

This script:
1) Loads the 129-item web catalog.
2) Downloads real recipe images from each source page og:image.
3) Expands Flutter ingredientOptions with missing ingredients.
4) Rewrites Flutter recipeCatalog with full entries.
"""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Dict, List, Tuple

ROOT = Path(__file__).resolve().parents[1]
MAIN_DART = ROOT / "fridge_mobile_app/lib/main.dart"
WEB_CATALOG_TS = ROOT / "src/data/recipeCatalog.ts"
RECIPE_ASSET_DIR = ROOT / "fridge_mobile_app/assets/images/recipes"


def run_cmd(args: List[str], timeout: int = 40) -> subprocess.CompletedProcess:
  return subprocess.run(
      args,
      stdout=subprocess.PIPE,
      stderr=subprocess.PIPE,
      text=True,
      timeout=timeout,
      check=False,
  )


def norm_token(value: str) -> str:
  value = value.replace("\u200b", "").replace("\ufeff", "")
  value = re.sub(r"\([^)]*\)", "", value)
  value = value.strip().lower()
  value = re.sub(r"[^가-힣a-z0-9]+", "", value)
  return value


def clean_name(value: str) -> str:
  value = value.replace("\u200b", "").replace("\ufeff", "")
  value = re.sub(r"\([^)]*\)", "", value)
  value = re.sub(r"\s+", " ", value).strip()
  return value


def dart_quote(value: str) -> str:
  escaped = value.replace("\\", "\\\\").replace("'", "\\'")
  return f"'{escaped}'"


def parse_web_catalog() -> List[dict]:
  raw = WEB_CATALOG_TS.read_text(encoding="utf-8")
  anchor = "export const RECIPE_CATALOG"
  pos = raw.index(anchor)
  eq = raw.index("=", pos)
  start = raw.index("[", eq)
  end = raw.rindex("];")
  return json.loads(raw[start : end + 1])


def parse_ingredient_options(main_text: str) -> List[dict]:
  start_marker = "final List<IngredientOption> ingredientOptions = ["
  end_marker = "final Map<String, IngredientOption> ingredientById = {"
  start = main_text.index(start_marker) + len(start_marker)
  end = main_text.index(end_marker)
  block = main_text[start:end]

  options = []
  for match in re.finditer(r"IngredientOption\((.*?)\),\n", block, re.S):
    entry = match.group(1)
    id_match = re.search(r"id:\s*'([^']+)'", entry)
    name_match = re.search(r"name:\s*'([^']+)'", entry)
    category_match = re.search(r"category:\s*'([^']+)'", entry)
    photo_match = re.search(r"photoUrl:\s*'([^']+)'", entry)
    if not (id_match and name_match and category_match and photo_match):
      continue

    default_unit = None
    unit_match = re.search(r"defaultUnit:\s*'([^']+)'", entry)
    if unit_match:
      default_unit = unit_match.group(1)

    aliases: List[str] = []
    alias_match = re.search(r"aliases:\s*\[([^\]]*)\]", entry, re.S)
    if alias_match:
      aliases = re.findall(r"'([^']+)'", alias_match.group(1))

    options.append(
        {
            "id": id_match.group(1),
            "name": name_match.group(1),
            "category": category_match.group(1),
            "photoUrl": photo_match.group(1),
            "defaultUnit": default_unit,
            "aliases": aliases,
        }
    )
  return options


def build_synonym_map() -> Dict[str, str]:
  return {
      "간장": "soy_sauce",
      "진간장": "soy_sauce",
      "국간장": "soy_sauce",
      "양조간장": "soy_sauce",
      "조선간장": "soy_sauce",
      "고추장": "gochujang",
      "고춧가루": "gochugaru",
      "고추가루": "gochugaru",
      "참기름": "sesame_oil",
      "식초": "vinegar",
      "후추": "black_pepper",
      "후춧가루": "black_pepper",
      "올리고당": "oligo_syrup",
      "맛술": "cooking_wine",
      "미림": "cooking_wine",
      "미향": "cooking_wine",
      "굴소스": "oyster_sauce",
      "된장": "doenjang",
      "다진마늘": "garlic",
      "마늘": "garlic",
      "양파": "onion",
      "대파": "green_onion",
      "쪽파": "green_onion",
      "파": "green_onion",
      "오이": "cucumber",
      "양배추": "cabbage",
      "배추": "napa_cabbage",
      "김치": "kimchi",
      "계란": "egg",
      "달걀": "egg",
      "두부": "tofu",
      "우유": "milk",
      "돼지고기": "pork",
      "소고기": "beef",
      "닭고기": "chicken",
      "스팸": "spam",
      "어묵": "fish_cake",
      "오뎅": "fish_cake",
      "감자": "potato",
      "고구마": "sweet_potato",
      "버섯": "mushroom",
      "무": "radish",
      "당근": "carrot",
      "가지": "eggplant",
      "상추": "lettuce",
      "시금치": "spinach",
      "깻잎": "perilla_leaf",
      "콩나물": "bean_sprout",
      "브로콜리": "broccoli",
      "토마토": "tomato",
      "치즈": "cheese",
      "버터": "butter",
      "요거트": "yogurt",
      "참치캔": "tuna_can",
      "참치": "tuna_can",
      "만두": "dumpling",
      "떡볶이떡": "rice_cake",
      "떡": "rice_cake",
      "김가루": "seaweed",
      "김": "seaweed",
      "라면": "ramen",
      "국수": "noodle",
      "우동": "udon",
      "스파게티": "spaghetti",
      "식빵": "bread",
      "쌀": "rice",
      "밥": "rice",
      "밀가루": "flour",
      "고추": "chili",
      "파프리카": "bell_pepper",
      "베이컨": "bacon",
      "소시지": "sausage",
      "설탕": "sugar",
      "소금": "salt",
  }


def guess_category(name: str) -> str:
  value = clean_name(name)
  seasonings = (
      "간장",
      "고추장",
      "고춧가루",
      "된장",
      "식초",
      "설탕",
      "소금",
      "후추",
      "기름",
      "액젓",
      "케찹",
      "케첩",
      "춘장",
      "카레",
      "전분",
      "소스",
      "물엿",
      "육수",
      "소주",
  )
  grains = ("쌀", "밥", "면", "가루", "우동", "국수", "라면", "파스타")
  dairy = ("우유", "치즈", "버터", "요거트")
  processed = ("통조림", "캔", "만두", "떡", "햄", "스팸", "김치", "어묵")
  seafood = ("오징어", "새우", "갈치", "고등어", "꽁치", "대구", "바지락", "멸치", "낙지")
  meat = ("돼지", "소고기", "닭", "목살", "갈비", "삼겹", "불고기", "고기")

  if any(key in value for key in seasonings):
    return "양념"
  if any(key in value for key in grains):
    return "곡물/면"
  if any(key in value for key in dairy):
    return "유제품"
  if any(key in value for key in processed):
    return "가공식품"
  if any(key in value for key in seafood):
    return "해산물"
  if any(key in value for key in meat):
    return "육류"
  return "채소"


def default_photo_for_category(category: str) -> str:
  return {
      "채소": "assets/images/ingredients/cucumber.jpg",
      "육류": "assets/images/ingredients/pork.jpg",
      "해산물": "assets/images/ingredients/fish-cake.jpg",
      "유제품": "assets/images/ingredients/milk.jpg",
      "가공식품": "assets/images/ingredients/spam.jpg",
      "양념": "assets/images/ingredients/soy-sauce.jpg",
      "곡물/면": "assets/images/ingredients/rice.jpg",
  }.get(category, "assets/images/ingredients/cucumber.jpg")


def build_search_index(options: List[dict]) -> List[Tuple[str, str]]:
  pairs: List[Tuple[str, str]] = []
  for item in options:
    pairs.append((norm_token(item["name"]), item["id"]))
    for alias in item.get("aliases", []):
      pairs.append((norm_token(alias), item["id"]))
    pairs.append((norm_token(item["id"]), item["id"]))
  pairs = [(k, v) for k, v in pairs if k]
  pairs.sort(key=lambda x: len(x[0]), reverse=True)
  return pairs


def make_extra_id(name: str) -> str:
  digest = hashlib.md5(name.encode("utf-8")).hexdigest()[:10]
  return f"extra_{digest}"


def sanitize_recipe_name(name: str) -> str:
  value = clean_name(name)
  value = value.replace("백종원", "").strip()
  value = re.sub(r"\s{2,}", " ", value)
  value = re.sub(r"^[~!@#%^&*]+", "", value)
  return value or "집밥 레시피"


def sanitize_step(step: str) -> str:
  value = clean_name(step)
  return value[:70]


def fetch_og_image(source_url: str) -> str | None:
  if not source_url.startswith("http"):
    return None
  html_res = run_cmd(
      ["curl", "-L", "--connect-timeout", "4", "--max-time", "10", source_url],
      timeout=16,
  )
  if html_res.returncode != 0 or not html_res.stdout:
    return None
  match = re.search(
      r"""<meta[^>]+property=['"]og:image['"][^>]+content=['"]([^'"]+)['"]""",
      html_res.stdout,
      flags=re.IGNORECASE,
  )
  if not match:
    match = re.search(
        r"""<meta[^>]+content=['"]([^'"]+)['"][^>]+property=['"]og:image['"]""",
        html_res.stdout,
        flags=re.IGNORECASE,
    )
  if not match:
    return None
  return match.group(1).strip()


def ensure_placeholder() -> Path:
  path = RECIPE_ASSET_DIR / "recipe_placeholder.jpg"
  if path.exists():
    return path

  candidates = sorted(RECIPE_ASSET_DIR.glob("*.png")) + sorted(RECIPE_ASSET_DIR.glob("*.jpg"))
  if candidates:
    source = candidates[0]
    data = source.read_bytes()
    path.write_bytes(data)
    return path

  raise RuntimeError("No existing image found for placeholder bootstrap")


def download_recipe_images(recipes: List[dict]) -> Dict[str, str]:
  RECIPE_ASSET_DIR.mkdir(parents=True, exist_ok=True)
  placeholder = ensure_placeholder()
  photo_by_recipe_id: Dict[str, str] = {}
  ok = 0
  fail = 0

  total = len(recipes)
  for idx, recipe in enumerate(recipes, start=1):
    rid = clean_name(str(recipe.get("id", "")))
    if not rid:
      continue

    dest_name = f"{rid}.jpg"
    dest_path = RECIPE_ASSET_DIR / dest_name
    rel_path = f"assets/images/recipes/{dest_name}"

    if dest_path.exists() and dest_path.stat().st_size > 5000:
      ok += 1
      photo_by_recipe_id[rid] = rel_path
      if idx % 10 == 0 or idx == total:
        print(f"[image] progress {idx}/{total} (downloaded={ok}, fallback={fail})", flush=True)
      continue

    source_url = str(recipe.get("sourceUrl", "")).strip()
    image_url = fetch_og_image(source_url)
    if image_url:
      dl = run_cmd(
          [
              "curl",
              "-L",
              "--connect-timeout",
              "4",
              "--max-time",
              "15",
              "-o",
              str(dest_path),
              image_url,
          ],
          timeout=25,
      )
      if dl.returncode == 0 and dest_path.exists() and dest_path.stat().st_size > 5000:
        # Limit decoded dimensions to keep app size in check.
        run_cmd(["sips", "-Z", "960", str(dest_path)], timeout=20)
        ok += 1
        photo_by_recipe_id[rid] = rel_path
      else:
        fail += 1
        photo_by_recipe_id[rid] = f"assets/images/recipes/{placeholder.name}"
    else:
      fail += 1
      photo_by_recipe_id[rid] = f"assets/images/recipes/{placeholder.name}"

    if idx % 10 == 0 or idx == total:
      print(f"[image] progress {idx}/{total} (downloaded={ok}, fallback={fail})", flush=True)

    time.sleep(0.02)

  print(f"[image] downloaded={ok}, fallback={fail}")
  return photo_by_recipe_id


def render_ingredient_options(options: List[dict]) -> str:
  lines = ["final List<IngredientOption> ingredientOptions = ["]
  for item in options:
    lines.append("  IngredientOption(")
    lines.append(f"    id: {dart_quote(item['id'])},")
    lines.append(f"    name: {dart_quote(item['name'])},")
    lines.append(f"    category: {dart_quote(item['category'])},")
    lines.append(f"    photoUrl: {dart_quote(item['photoUrl'])},")
    if item.get("defaultUnit"):
      lines.append(f"    defaultUnit: {dart_quote(item['defaultUnit'])},")
    aliases = item.get("aliases") or []
    if aliases:
      lines.append(
          "    aliases: ["
          + ", ".join(dart_quote(alias) for alias in aliases)
          + "],"
      )
    lines.append("  ),")
  lines.append("];")
  return "\n".join(lines)


def render_recipe_catalog(recipes: List[dict]) -> str:
  lines = ["final List<RecipeData> recipeCatalog = ["]
  for item in recipes:
    lines.append("  RecipeData(")
    lines.append(f"    id: {dart_quote(item['id'])},")
    lines.append(f"    name: {dart_quote(item['name'])},")
    lines.append(f"    summary: {dart_quote(item['summary'])},")
    lines.append(f"    source: {dart_quote(item['source'])},")
    lines.append(f"    sourceUrl: {dart_quote(item['sourceUrl'])},")
    lines.append(f"    photoUrl: {dart_quote(item['photoUrl'])},")
    lines.append("    ingredientIds: [")
    for ingredient_id in item["ingredientIds"]:
      lines.append(f"      {dart_quote(ingredient_id)},")
    lines.append("    ],")
    lines.append("  ),")
  lines.append("];")
  return "\n".join(lines)


def main() -> int:
  main_text = MAIN_DART.read_text(encoding="utf-8")
  web_recipes = parse_web_catalog()
  ingredient_options = parse_ingredient_options(main_text)
  synonyms = build_synonym_map()

  option_by_id = {item["id"]: item for item in ingredient_options}
  search_index = build_search_index(ingredient_options)

  extra_name_to_id: Dict[str, str] = {}
  extra_options: List[dict] = []

  def map_ingredient(raw_name: str) -> str:
    cleaned = clean_name(raw_name)
    token = norm_token(cleaned)
    if not token:
      return ""

    for key, ingredient_id in synonyms.items():
      if key in cleaned:
        return ingredient_id

    for search_key, ingredient_id in search_index:
      if search_key in token or token in search_key:
        return ingredient_id

    if cleaned in extra_name_to_id:
      return extra_name_to_id[cleaned]

    ingredient_id = make_extra_id(cleaned)
    while ingredient_id in option_by_id:
      ingredient_id = f"{ingredient_id}x"

    category = guess_category(cleaned)
    extra_option = {
        "id": ingredient_id,
        "name": cleaned,
        "category": category,
        "photoUrl": default_photo_for_category(category),
        "defaultUnit": None,
        "aliases": [],
    }
    extra_options.append(extra_option)
    option_by_id[ingredient_id] = extra_option
    extra_name_to_id[cleaned] = ingredient_id
    search_index.insert(0, (norm_token(cleaned), ingredient_id))
    return ingredient_id

  photo_by_recipe_id = download_recipe_images(web_recipes)
  normalized_recipes: List[dict] = []

  for recipe in web_recipes:
    recipe_id = clean_name(str(recipe.get("id", "")))
    if not recipe_id:
      continue

    ingredient_names = []
    ingredient_names.extend(recipe.get("mainIngredients", []) or [])
    ingredient_names.extend(recipe.get("subIngredients", []) or [])

    ingredient_ids: List[str] = []
    seen_ingredient_ids = set()
    for ingredient_name in ingredient_names:
      ingredient_id = map_ingredient(str(ingredient_name))
      if ingredient_id and ingredient_id not in seen_ingredient_ids:
        ingredient_ids.append(ingredient_id)
        seen_ingredient_ids.add(ingredient_id)

    steps = recipe.get("steps", []) or []
    first_step = sanitize_step(str(steps[0])) if steps else ""
    time_text = clean_name(str(recipe.get("time", "")))
    difficulty = clean_name(str(recipe.get("difficulty", "")))
    if first_step:
      summary = f"{time_text} · {difficulty} · {first_step}" if time_text or difficulty else first_step
    else:
      summary = f"{time_text} · {difficulty} · 집밥 추천 레시피입니다."
    summary = summary[:140]

    normalized_recipes.append(
        {
            "id": recipe_id,
            "name": sanitize_recipe_name(str(recipe.get("name", ""))),
            "summary": summary,
            "source": "오픈 레시피",
            "sourceUrl": str(recipe.get("sourceUrl", "")).strip(),
            "photoUrl": photo_by_recipe_id.get(
                recipe_id, "assets/images/recipes/recipe_placeholder.jpg"
            ),
            "ingredientIds": ingredient_ids,
        }
    )

  full_ingredient_options = ingredient_options + extra_options
  ingredient_block = render_ingredient_options(full_ingredient_options)
  recipe_block = render_recipe_catalog(normalized_recipes)

  ingredient_start = "final List<IngredientOption> ingredientOptions = ["
  ingredient_end = "final Map<String, IngredientOption> ingredientById = {"
  i_start = main_text.index(ingredient_start)
  i_end = main_text.index(ingredient_end)
  main_text = main_text[:i_start] + ingredient_block + "\n\n" + main_text[i_end:]

  recipe_start = "final List<RecipeData> recipeCatalog = ["
  r_start = main_text.index(recipe_start)
  r_end = main_text.rindex("];")
  main_text = main_text[:r_start] + recipe_block + "\n"

  MAIN_DART.write_text(main_text, encoding="utf-8")
  print(
      f"[sync] recipes={len(normalized_recipes)}, base_ingredients={len(ingredient_options)}, "
      f"extra_ingredients={len(extra_options)}"
  )
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
