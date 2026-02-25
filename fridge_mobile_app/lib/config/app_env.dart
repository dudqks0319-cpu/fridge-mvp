class AppEnv {
  static const supabaseUrl = String.fromEnvironment("SUPABASE_URL");
  static const supabaseAnonKey = String.fromEnvironment("SUPABASE_ANON_KEY");

  static const onesignalAppId = String.fromEnvironment("ONESIGNAL_APP_ID");

  static const revenuecatAppleApiKey = String.fromEnvironment(
    "REVENUECAT_APPLE_API_KEY",
  );
  static const revenuecatGoogleApiKey = String.fromEnvironment(
    "REVENUECAT_GOOGLE_API_KEY",
  );

  static const enableFirebase = String.fromEnvironment(
    "ENABLE_FIREBASE",
    defaultValue: "true",
  );
  static const enableAnalytics = String.fromEnvironment(
    "ENABLE_ANALYTICS",
    defaultValue: "true",
  );
  static const enableCrashlytics = String.fromEnvironment(
    "ENABLE_CRASHLYTICS",
    defaultValue: "true",
  );

  static bool get hasSupabase =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;
}
