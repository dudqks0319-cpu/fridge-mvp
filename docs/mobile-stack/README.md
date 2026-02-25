# Mobile Stack Setup (All 10 Tools)

This project now includes wiring for the full stack you requested:

1. FlutterFlow + Supabase
2. Supabase RLS
3. Supabase MCP Server
4. Expo EAS Build/Submit
5. OneSignal
6. RevenueCat
7. Firebase Crashlytics + Analytics
8. Maestro
9. GitHub Actions
10. Fastlane

## Current Status

- Applied in code/config: 2, 4, 5, 6, 7, 8, 9, 10
- Applied as integration guide/template: 1, 3
- Needs your account credentials: 3, 4, 5, 6, 7, 9, 10

## Quick Apply (non-dev friendly)

1. Copy template:

```bash
cp .env.mobile-stack.example .env.mobile-stack.local
```

2. Fill values in `.env.mobile-stack.local`.
3. Apply all local keys + MCP + GitHub Secrets (if `gh auth` is ready):

```bash
pnpm mobile:secrets:apply
```

This command writes:

- `.env.local` (web Supabase keys)
- `fridge_mobile_app/config/dart_defines.local.json` (Flutter runtime keys)
- Supabase MCP config via `~/.codex/scripts/enable-supabase-mcp.sh` (when token/project ref exist)

## Key Files

- Supabase schema + RLS:
  - `supabase/schema.sql`
  - `supabase/migrations/20260224190000_mobile_stack.sql`
- Supabase edge functions:
  - `supabase/functions/revenuecat-webhook/index.ts`
  - `supabase/functions/onesignal-device-sync/index.ts`
- Flutter mobile integration:
  - `fridge_mobile_app/lib/bootstrap/app_bootstrap.dart`
  - `fridge_mobile_app/lib/config/app_env.dart`
  - `fridge_mobile_app/config/dart_defines.example.json`
- Android/iOS setup:
  - `fridge_mobile_app/android/settings.gradle.kts`
  - `fridge_mobile_app/android/app/build.gradle.kts`
  - `fridge_mobile_app/android/app/src/main/AndroidManifest.xml`
  - `fridge_mobile_app/ios/Runner/Info.plist`
- CI/CD and automation:
  - `.github/workflows/ci.yml`
  - `.github/workflows/mobile-release.yml`
  - `.github/workflows/maestro.yml`
  - `fridge_mobile_app/fastlane/Fastfile`
  - `fridge_mobile_app/maestro/*.yaml`
  - `scripts/mobile/*.sh`

## 1) FlutterFlow + Supabase

Use FlutterFlow for UI and keep Supabase as backend source of truth.

- Connect FlutterFlow project to your Supabase project.
- Keep auth/data in Supabase only.
- Use this repo schema (`supabase/schema.sql`) as baseline.

## 2) Supabase RLS

RLS is enabled for:

- `fridge_app_state`
- `notification_devices`
- `subscription_state`
- `revenuecat_events` (read-only to owner)

Apply SQL:

```bash
supabase db push
```

## 3) Supabase MCP Server

Prepared scripts (credentials required):

```bash
bash ~/.codex/scripts/enable-supabase-mcp.sh <your_project_ref>
```

Detailed steps: `docs/mobile-stack/supabase-mcp.md`.

## 4) Expo EAS Build/Submit

EAS config is included at root: `eas.json`.

Commands:

```bash
pnpm mobile:eas:build:ios
pnpm mobile:eas:build:android
```

## 5) OneSignal

- Flutter SDK wired in bootstrap.
- Supabase table: `notification_devices`.
- Sync function: `onesignal-device-sync`.

Set:

- `ONESIGNAL_APP_ID`

## 6) RevenueCat

- Flutter SDK wired in bootstrap.
- Supabase table: `subscription_state`.
- Webhook function: `revenuecat-webhook`.

Set:

- `REVENUECAT_APPLE_API_KEY`
- `REVENUECAT_GOOGLE_API_KEY`
- `REVENUECAT_WEBHOOK_SECRET`

## 7) Firebase Crashlytics + Analytics

Integrated in app bootstrap (with safe skip if not configured).

Required files:

- `fridge_mobile_app/android/app/google-services.json`
- `fridge_mobile_app/ios/Runner/GoogleService-Info.plist`

## 8) Maestro

Smoke tests included:

- `fridge_mobile_app/maestro/home_smoke.yaml`
- `fridge_mobile_app/maestro/recipe_smoke.yaml`

Run:

```bash
pnpm mobile:maestro
```

## 9) GitHub Actions

Workflows included:

- CI for web + flutter checks
- Mobile release workflow
- Maestro cloud workflow

Configure repository secrets before release workflows.

## 10) Fastlane

Configured:

- `fridge_mobile_app/Gemfile`
- `fridge_mobile_app/fastlane/Appfile`
- `fridge_mobile_app/fastlane/Fastfile`

Release lanes:

- `bundle exec fastlane ios beta`
- `bundle exec fastlane android beta`

## Install Everything (macOS)

Bootstrap script:

```bash
bash scripts/mobile/bootstrap-tools.sh
```
