#!/bin/bash
set -euo pipefail

echo "== Mobile Toolchain Doctor =="
for cmd in flutter dart supabase eas fastlane maestro gh pnpm ruby bundler java; do
  if [ "$cmd" = "java" ]; then
    if java -version >/dev/null 2>&1; then
      printf "%-10s %s\n" "$cmd" "$(command -v java)"
      continue
    fi
    if [ -x "/opt/homebrew/opt/openjdk/bin/java" ]; then
      printf "%-10s %s\n" "$cmd" "/opt/homebrew/opt/openjdk/bin/java (PATH not loaded yet)"
      continue
    fi
    printf "%-10s %s\n" "$cmd" "MISSING"
    continue
  fi

  if command -v "$cmd" >/dev/null 2>&1; then
    printf "%-10s %s\n" "$cmd" "$(command -v "$cmd")"
    continue
  fi

  if [ "$cmd" = "maestro" ] && [ -x "$HOME/.maestro/bin/maestro" ]; then
    printf "%-10s %s\n" "$cmd" "$HOME/.maestro/bin/maestro (PATH not loaded yet)"
    continue
  fi

  printf "%-10s %s\n" "$cmd" "MISSING"
done

if command -v xcode-select >/dev/null 2>&1; then
  xcode_path="$(xcode-select -p 2>/dev/null || true)"
  printf "%-10s %s\n" "xcode" "${xcode_path:-UNKNOWN}"
  if [[ "$xcode_path" == *"CommandLineTools"* ]]; then
    echo "note       xcode-select points to CommandLineTools. For iOS builds, run:"
    echo "           DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer flutter build ios --simulator --debug"
  fi
fi
