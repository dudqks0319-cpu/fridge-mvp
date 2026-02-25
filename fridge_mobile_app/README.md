# fridge_mobile_app

Flutter mobile app for iOS/Android.

## 1) Install dependencies

```bash
flutter pub get
```

## 2) Configure runtime keys

Copy and edit:

```bash
cp config/dart_defines.example.json config/dart_defines.local.json
```

Run with:

```bash
flutter run --dart-define-from-file=config/dart_defines.local.json
```

## 3) Firebase files

Add platform files before enabling crash/analytics in production:

- `android/app/google-services.json`
- `ios/Runner/GoogleService-Info.plist`

## 4) Quality and release

- Maestro smoke tests: `maestro test maestro/home_smoke.yaml`
- Fastlane iOS beta: `bundle exec fastlane ios beta`
- Fastlane Android beta: `bundle exec fastlane android beta`

## 5) iOS local build

If `xcode-select -p` points to `CommandLineTools`, run iOS builds with:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer flutter build ios --simulator --debug
```

This project also overrides `objective_c` to a local patched copy under `third_party/objective_c` to avoid SDK path lookup failures in that environment.

## 6) Notes

App bootstrap initializes integrations safely:

- Supabase
- OneSignal
- RevenueCat
- Firebase Analytics
- Firebase Crashlytics

If required keys are missing, the integration is skipped and logged.
