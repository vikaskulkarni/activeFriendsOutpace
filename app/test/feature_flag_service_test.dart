import 'package:activefriends/features/import/data/feature_flag_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<FeatureFlagService> serviceWith(ConfigFetcher fetch) async {
    final prefs = await SharedPreferences.getInstance();
    return FeatureFlagService(fetchAutoSyncRow: fetch, prefs: prefs);
  }

  test('enabled=true is returned and cached', () async {
    final svc = await serviceWith(() async => {'value': {'enabled': true}});
    expect(await svc.autoSyncEnabled(), isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(FeatureFlagService.cacheKey), isTrue);
  });

  test('missing/null enabled → false (never accidentally on)', () async {
    final svc = await serviceWith(() async => {'value': <String, dynamic>{}});
    expect(await svc.autoSyncEnabled(), isFalse);
  });

  test('row absent → false', () async {
    final svc = await serviceWith(() async => null);
    expect(await svc.autoSyncEnabled(), isFalse);
  });

  test('fetch throws → falls back to cached last-known-good', () async {
    SharedPreferences.setMockInitialValues(
        {FeatureFlagService.cacheKey: true});
    final prefs = await SharedPreferences.getInstance();
    final svc = FeatureFlagService(
      fetchAutoSyncRow: () async => throw Exception('offline'),
      prefs: prefs,
    );
    expect(await svc.autoSyncEnabled(), isTrue); // last-known-good
  });

  test('fetch throws with NO cache → false (fail safe)', () async {
    final prefs = await SharedPreferences.getInstance();
    final svc = FeatureFlagService(
      fetchAutoSyncRow: () async => throw Exception('offline'),
      prefs: prefs,
    );
    expect(await svc.autoSyncEnabled(), isFalse);
  });
}
