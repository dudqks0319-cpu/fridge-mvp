#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="${1:-$ROOT_DIR/.env.mobile-stack.local}"

if [ ! -f "$ENV_FILE" ]; then
  cat <<EOF
Missing env file: $ENV_FILE

Create it first:
  cp $ROOT_DIR/.env.mobile-stack.example $ROOT_DIR/.env.mobile-stack.local
EOF
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

required_core=(
  NEXT_PUBLIC_SUPABASE_URL
  NEXT_PUBLIC_SUPABASE_ANON_KEY
)

missing=()
for key in "${required_core[@]}"; do
  if [ -z "${!key:-}" ]; then
    missing+=("$key")
  fi
done

if [ "${#missing[@]}" -gt 0 ]; then
  echo "Missing required values in $ENV_FILE:"
  printf " - %s\n" "${missing[@]}"
  exit 1
fi

cat > "$ROOT_DIR/.env.local" <<EOF
NEXT_PUBLIC_SUPABASE_URL=$NEXT_PUBLIC_SUPABASE_URL
NEXT_PUBLIC_SUPABASE_ANON_KEY=$NEXT_PUBLIC_SUPABASE_ANON_KEY
EOF
echo "Wrote $ROOT_DIR/.env.local"

mkdir -p "$ROOT_DIR/fridge_mobile_app/config"
python3 - "$ROOT_DIR/fridge_mobile_app/config/dart_defines.local.json" <<'PY'
import json
import os
import sys

out_path = sys.argv[1]

data = {
    "SUPABASE_URL": os.getenv("NEXT_PUBLIC_SUPABASE_URL", ""),
    "SUPABASE_ANON_KEY": os.getenv("NEXT_PUBLIC_SUPABASE_ANON_KEY", ""),
    "ONESIGNAL_APP_ID": os.getenv("ONESIGNAL_APP_ID", ""),
    "REVENUECAT_APPLE_API_KEY": os.getenv("REVENUECAT_APPLE_API_KEY", ""),
    "REVENUECAT_GOOGLE_API_KEY": os.getenv("REVENUECAT_GOOGLE_API_KEY", ""),
    "ENABLE_FIREBASE": os.getenv("ENABLE_FIREBASE", "true"),
    "ENABLE_ANALYTICS": os.getenv("ENABLE_ANALYTICS", "true"),
    "ENABLE_CRASHLYTICS": os.getenv("ENABLE_CRASHLYTICS", "true"),
}

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=True, indent=2)
    f.write("\n")
PY
echo "Wrote fridge_mobile_app/config/dart_defines.local.json"

if [ -n "${SUPABASE_PROJECT_REF:-}" ] && [ -n "${SUPABASE_ACCESS_TOKEN:-}" ]; then
  export SUPABASE_ACCESS_TOKEN
  bash "$HOME/.codex/scripts/enable-supabase-mcp.sh" "$SUPABASE_PROJECT_REF" || true
  echo "Supabase MCP configuration step completed."
else
  echo "Skipped Supabase MCP: SUPABASE_PROJECT_REF or SUPABASE_ACCESS_TOKEN missing."
fi

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  echo "GitHub auth detected. Syncing available GitHub Secrets..."
  gh_keys=(
    NEXT_PUBLIC_SUPABASE_URL
    NEXT_PUBLIC_SUPABASE_ANON_KEY
    SUPABASE_PROJECT_REF
    SUPABASE_ACCESS_TOKEN
    ONESIGNAL_APP_ID
    REVENUECAT_APPLE_API_KEY
    REVENUECAT_GOOGLE_API_KEY
    REVENUECAT_WEBHOOK_SECRET
    MAESTRO_API_KEY
    MAESTRO_PROJECT_ID
  )
  for key in "${gh_keys[@]}"; do
    value="${!key:-}"
    if [ -n "$value" ]; then
      gh secret set "$key" --body "$value"
      echo "  - set $key"
    fi
  done
else
  echo "Skipped GitHub Secrets sync: gh auth not ready."
fi

echo ""
echo "Next:"
echo "  1) pnpm mobile:doctor"
echo "  2) cd fridge_mobile_app && flutter run --dart-define-from-file=config/dart_defines.local.json"
echo "  3) SUPABASE_ACCESS_TOKEN=<token> pnpm mobile:supabase:functions:deploy"
