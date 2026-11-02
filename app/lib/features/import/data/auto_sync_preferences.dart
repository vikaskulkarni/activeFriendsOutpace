import 'package:shared_preferences/shared_preferences.dart';

/// Per-user (device-local) auto-sync toggle + last-sync timestamp. This is the
/// SECOND gate — it is AND'd with the remote `FeatureFlagService` kill switch.
/// The remote switch always wins; a user cannot force auto-sync on while ops
/// has it off.
class AutoSyncPreferences {
  AutoSyncPreferences({this._prefs});

  static const kEnabled = 'auto_sync_enabled';
  static const kRegisteredAt = 'auto_sync_registered_at';
  static const kLastSuccess = 'auto_sync_last_success';

  SharedPreferences? _prefs;
  Future<SharedPreferences> get _p async =>
      _prefs ??= await SharedPreferences.getInstance();

  Future<bool> isEnabled() async => (await _p).getBool(kEnabled) ?? true;

  Future<void> setEnabled(bool value) async =>
      (await _p).setBool(kEnabled, value);

  Future<void> markRegistered() async =>
      (await _p).setString(kRegisteredAt, DateTime.now().toIso8601String());

  Future<DateTime?> lastSuccess() async {
    final raw = (await _p).getString(kLastSuccess);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  Future<void> setLastSuccess(DateTime at) async =>
      (await _p).setString(kLastSuccess, at.toIso8601String());
}
