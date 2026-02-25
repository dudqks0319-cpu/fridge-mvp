import "dart:io";

import "package:firebase_analytics/firebase_analytics.dart";
import "package:firebase_core/firebase_core.dart";
import "package:firebase_crashlytics/firebase_crashlytics.dart";
import "package:flutter/foundation.dart";
import "package:onesignal_flutter/onesignal_flutter.dart";
import "package:purchases_flutter/purchases_flutter.dart";
import "package:supabase_flutter/supabase_flutter.dart";

import "../config/app_env.dart";

class AppBootstrap {
  static bool _initialized = false;
  static bool _firebaseReady = false;

  static Future<void> initialize() async {
    if (_initialized) {
      return;
    }

    await _initializeSupabase();
    await _initializeFirebase();
    await _initializeOneSignal();
    await _initializeRevenueCat();

    _initialized = true;
  }

  static Future<void> _initializeSupabase() async {
    if (!AppEnv.hasSupabase) {
      debugPrint(
        "[bootstrap] Supabase skipped. Set SUPABASE_URL and SUPABASE_ANON_KEY.",
      );
      return;
    }

    await Supabase.initialize(
      url: AppEnv.supabaseUrl,
      anonKey: AppEnv.supabaseAnonKey,
    );
    debugPrint("[bootstrap] Supabase initialized.");
  }

  static Future<void> _initializeFirebase() async {
    if (AppEnv.enableFirebase != "true") {
      debugPrint("[bootstrap] Firebase disabled by ENABLE_FIREBASE.");
      return;
    }

    try {
      await Firebase.initializeApp();
      _firebaseReady = true;
      debugPrint("[bootstrap] Firebase initialized.");
    } catch (error) {
      debugPrint("[bootstrap] Firebase skipped: $error");
      return;
    }

    if (AppEnv.enableAnalytics == "true") {
      await FirebaseAnalytics.instance.setAnalyticsCollectionEnabled(true);
      debugPrint("[bootstrap] Firebase Analytics enabled.");
    }

    if (AppEnv.enableCrashlytics == "true") {
      await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(true);

      FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;
      PlatformDispatcher.instance.onError = (error, stack) {
        FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
        return true;
      };

      debugPrint("[bootstrap] Firebase Crashlytics enabled.");
    }
  }

  static Future<void> _initializeOneSignal() async {
    if (AppEnv.onesignalAppId.isEmpty) {
      debugPrint("[bootstrap] OneSignal skipped. Set ONESIGNAL_APP_ID.");
      return;
    }

    OneSignal.Debug.setLogLevel(OSLogLevel.verbose);
    OneSignal.initialize(AppEnv.onesignalAppId);
    await OneSignal.Notifications.requestPermission(true);
    debugPrint("[bootstrap] OneSignal initialized.");
  }

  static Future<void> _initializeRevenueCat() async {
    final apiKey = _resolveRevenueCatApiKey();
    if (apiKey.isEmpty) {
      debugPrint(
        "[bootstrap] RevenueCat skipped. Set platform API key with dart-define.",
      );
      return;
    }

    await Purchases.setLogLevel(LogLevel.info);
    await Purchases.configure(PurchasesConfiguration(apiKey));
    debugPrint("[bootstrap] RevenueCat initialized.");
  }

  static String _resolveRevenueCatApiKey() {
    if (kIsWeb) {
      return "";
    }

    if (Platform.isIOS) {
      return AppEnv.revenuecatAppleApiKey;
    }

    if (Platform.isAndroid) {
      return AppEnv.revenuecatGoogleApiKey;
    }

    return "";
  }

  static bool get firebaseReady => _firebaseReady;
}
