import 'package:activefriends/features/import/data/auto_sync_manager.dart';
import 'package:activefriends/features/import/data/auto_sync_preferences.dart';
import 'package:activefriends/features/import/data/feature_flag_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('two-gate AND is pure', () {
    expect(
        AutoSyncManager.shouldAutoSyncRun(
            remoteEnabled: true, userEnabled: true),
        isTrue);
    for (final pair in [
      [true, false],
      [false, true],
      [false, false]
    ]) {
      expect(
          AutoSyncManager.shouldAutoSyncRun(
              remoteEnabled: pair[0], userEnabled: pair[1]),
          isFalse);
    }
  });

  Future<AutoSyncManager> build({
    required bool remote,
    required bool user,
    required List<String> log,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await AutoSyncPreferences(prefs: prefs).setEnabled(user);
    return AutoSyncManager(
      flags: FeatureFlagService(
          fetchAutoSyncRow: () async => {'value': {'enabled': remote}},
          prefs: prefs),
      prefs: AutoSyncPreferences(prefs: prefs),
      register: () async => log.add('register'),
      teardown: () async => log.add('teardown'),
    );
  }

  test('both gates on → registers', () async {
    final log = <String>[];
    expect(await (await build(remote: true, user: true, log: log))
        .syncRegistration(), isTrue);
    expect(log, ['register']);
  });

  test('remote off → tears down even if user on', () async {
    final log = <String>[];
    expect(await (await build(remote: false, user: true, log: log))
        .syncRegistration(), isFalse);
    expect(log, ['teardown']);
  });
}
