#!/bin/bash
set -euo pipefail

echo "[1/6] Install core CLIs (pnpm, supabase, ruby, fastlane, openjdk)"
brew install pnpm supabase/tap/supabase ruby fastlane openjdk || true

echo "[2/6] Install EAS CLI (Expo Build/Submit)"
npm install -g eas-cli || true

echo "[3/6] Install Flutter SDK (macOS cask)"
brew install --cask flutter || true

echo "[4/6] Install Maestro"
curl -Ls "https://get.maestro.mobile.dev" | bash || true

echo "[5/6] Verify fastlane"
fastlane --version || true

echo "[6/6] Tool status"
bash "$(dirname "$0")/doctor.sh" || true

echo "Bootstrap completed. Review missing items above."
