import 'package:activefriends/features/import/data/auto_sync_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('defaults to disabled', () async {
    final prefs = await SharedPreferences.getInstance();
    expect(await AutoSyncPreferences(prefs: prefs).isEnabled(), isFalse);
  });

  test('setEnabled round-trips', () async {
    final prefs = await SharedPreferences.getInstance();
    final p = AutoSyncPreferences(prefs: prefs);
    await p.setEnabled(true);
    expect(await p.isEnabled(), isTrue);
  });

  test('lastSuccess round-trips as a DateTime', () async {
    final prefs = await SharedPreferences.getInstance();
    final p = AutoSyncPreferences(prefs: prefs);
    final t = DateTime(2026, 10, 31, 9, 15);
    await p.setLastSuccess(t);
    expect(await p.lastSuccess(), t);
  });
}
