import 'package:activefriends/features/import/data/auto_sync_preferences.dart';
import 'package:activefriends/features/import/data/feature_flag_service.dart';
import 'package:activefriends/features/import/presentation/watch_import_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('shows the Auto-Sync toggle reflecting the stored pref',
      (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await AutoSyncPreferences(prefs: prefs).setEnabled(true);
    var toggled = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: WatchImportSection(
          autoSyncPrefs: AutoSyncPreferences(prefs: prefs),
          flags: FeatureFlagService(
              fetchAutoSyncRow: () async => {'value': {'enabled': true}},
              prefs: prefs),
          onToggle: () async => toggled++,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Auto-Sync'), findsOneWidget);
    final sw = tester.widget<Switch>(find.byType(Switch));
    expect(sw.value, isTrue);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(toggled, 1);
  });
}
