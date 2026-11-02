import 'package:activefriends/features/import/data/auto_sync_preferences.dart';
import 'package:activefriends/features/import/data/feature_flag_service.dart';

typedef RegisterWorker = Future<void> Function();
typedef TeardownWorker = Future<void> Function();

/// Resolves the two-gate (remote kill switch AND per-user toggle) and either
/// registers the OS background worker/observer or tears it down. "Off" MUST
/// stop the OS waking the app — not merely no-op — so teardown is called
/// whenever either gate is off.
class AutoSyncManager {
  AutoSyncManager({
    required this._flags,
    required this._prefs,
    required this._register,
    required this._teardown,
  });

  final FeatureFlagService _flags;
  final AutoSyncPreferences _prefs;
  final RegisterWorker _register;
  final TeardownWorker _teardown;

  /// Remote switch always wins; a user cannot force it on while ops has it off.
  static bool shouldAutoSyncRun({
    required bool remoteEnabled,
    required bool userEnabled,
  }) =>
      remoteEnabled && userEnabled;

  /// Resolve both gates and register or tear down accordingly. Returns whether
  /// auto-sync is now active.
  Future<bool> syncRegistration() async {
    final remote = await _flags.autoSyncEnabled();
    final user = await _prefs.isEnabled();
    if (shouldAutoSyncRun(remoteEnabled: remote, userEnabled: user)) {
      await _register();
      await _prefs.markRegistered();
      return true;
    }
    await _teardown();
    return false;
  }
}
