import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

typedef ConfigFetcher = Future<Map<String, dynamic>?> Function();

/// Supabase-controlled global kill switch for background auto-sync.
///
/// FAIL-SAFE: any error (offline, RLS, missing row, malformed value) resolves
/// to the last-known-good cached value, and to `false` when there is no cache.
/// Auto-sync never turns itself on by accident.
class FeatureFlagService {
  FeatureFlagService({
    ConfigFetcher? fetchAutoSyncRow,
    SharedPreferences? prefs,
    SupabaseClient? client,
  })  : _fetch = fetchAutoSyncRow,
        _prefs = prefs, // ignore: prefer_initializing_formals
        _client = client; // ignore: prefer_initializing_formals

  static const cacheKey = 'auto_sync_remote_enabled';

  final ConfigFetcher? _fetch;
  SharedPreferences? _prefs;
  final SupabaseClient? _client;

  Future<bool> autoSyncEnabled() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    try {
      final row = await (_fetch ?? _supabaseFetch)();
      final value = row?['value'];
      final enabled =
          (value is Map && value['enabled'] is bool) ? value['enabled'] as bool : false;
      await prefs.setBool(cacheKey, enabled);
      return enabled;
    } catch (_) {
      return prefs.getBool(cacheKey) ?? false;
    }
  }

  Future<Map<String, dynamic>?> _supabaseFetch() async {
    final client = _client ?? Supabase.instance.client;
    final row = await client
        .from('app_config')
        .select('value')
        .eq('key', 'auto_sync')
        .maybeSingle();
    return row;
  }
}
