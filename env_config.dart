/// Environment configuration injected at compile time via `--dart-define`
/// or `--dart-define-from-file=env.json`.
class EnvConfig {
  const EnvConfig._();

  static const String supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const String supabaseAnonKey =
      String.fromEnvironment('SUPABASE_ANON_KEY');

  static bool get isConfigured {
    if (supabaseUrl.isEmpty || supabaseAnonKey.isEmpty) return false;
    if (supabaseUrl.contains('YOUR_PROJECT_REF') ||
        supabaseAnonKey.contains('YOUR_SUPABASE_ANON')) {
      return false;
    }
    return supabaseUrl.startsWith('https://');
  }
}
