#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR="$ROOT_DIR/fridge_mobile_app"
IOS_DIR="$APP_DIR/ios"

IOS_DEVICE="${IOS_DEVICE:-iPhone 17}"
ANDROID_BUILD_MODE="${ANDROID_BUILD_MODE:-debug}"

LOG_DIR="${TMPDIR:-/tmp}/fridge-mvp-mobile-test-logs"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
IOS_LOG="$LOG_DIR/ios-test-$TIMESTAMP.log"
ANDROID_LOG="$LOG_DIR/android-build-$TIMESTAMP.log"

if [ ! -d "$APP_DIR" ]; then
  echo "fridge_mobile_app directory not found: $APP_DIR" >&2
  exit 1
fi

mkdir -p "$LOG_DIR"

if [ ! -f "$APP_DIR/android/app/google-services.json" ]; then
  echo "warning: android/app/google-services.json not found."
  echo "         Android build may fail until Firebase config is added."
fi

echo "== Dual Mobile Check =="
echo "iOS device: $IOS_DEVICE"
echo "Android mode: $ANDROID_BUILD_MODE"
echo "iOS log: $IOS_LOG"
echo "Android log: $ANDROID_LOG"

(
  cd "$IOS_DIR"
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    xcodebuild \
      -workspace Runner.xcworkspace \
      -scheme Runner \
      -configuration Debug \
      -sdk iphonesimulator \
      -destination "platform=iOS Simulator,name=$IOS_DEVICE" \
      test
) >"$IOS_LOG" 2>&1 &
ios_pid=$!

(
  cd "$APP_DIR"
  flutter build apk --"$ANDROID_BUILD_MODE"
) >"$ANDROID_LOG" 2>&1 &
android_pid=$!

set +e
wait "$ios_pid"
ios_exit=$?
wait "$android_pid"
android_exit=$?
set -e

echo
echo "== Result =="
echo "iOS test exit code: $ios_exit"
echo "Android build exit code: $android_exit"

if [ "$ios_exit" -eq 0 ] && [ "$android_exit" -eq 0 ]; then
  echo "All checks passed."
  exit 0
fi

if [ "$ios_exit" -ne 0 ]; then
  echo
  echo "--- iOS failure tail ---"
  tail -n 80 "$IOS_LOG" || true
fi

if [ "$android_exit" -ne 0 ]; then
  echo
  echo "--- Android failure tail ---"
  tail -n 80 "$ANDROID_LOG" || true
fi

exit 1
