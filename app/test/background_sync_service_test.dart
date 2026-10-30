import 'package:activefriends/features/import/data/background_sync_service.dart';
import 'package:activefriends/features/import/data/feature_flag_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('flag OFF → returns skipped(flag_off) without syncing', () async {
    final prefs = await SharedPreferences.getInstance();
    final flags = FeatureFlagService(
      fetchAutoSyncRow: () async => {'value': {'enabled': false}},
      prefs: prefs,
    );
    final svc = BackgroundSyncService.forTest(flags: flags);

    final result = await svc.syncIncremental(userId: 'u1');

    expect(result.skippedReason, 'flag_off');
    expect(result.imported, 0);
  });
}
