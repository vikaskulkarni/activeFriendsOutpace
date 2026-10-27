import 'package:activefriends/features/import/data/health_import_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression tests for `HealthImportService.chooseSourceAwareDistance`.
///
/// Background: commit `ceb118c` ("cleanup") made the multi-source branch
/// return `totalDistance`, which Health Connect computes by SUMMING every
/// source's DistanceRecords. On Android a watch app (Garmin / Samsung Health /
/// HealthSync) and the phone's own Health Connect aggregator
/// (`com.android.healthconnect.phone.*`) both record walk/run distance, so the
/// sum is ~2x real. The fix restores owner-source selection.
///
/// Fixtures below are REAL per-source splits captured from production
/// `import_diagnostics` (payload type `distance_debug`).
void main() {
  const garmin = 'name:com.garmin.android.apps.connectmobile';
  const shealth = 'name:com.sec.android.app.shealth';
  const healthsync = 'name:nl.appyhapps.healthsync';
  const phone =
      'name:com.android.healthconnect.phone.j88230a8e45c137cb94699a4814b853bc';

  group('chooseSourceAwareDistance — real production splits', () {
    test('Garmin walk: picks the watch, not the doubled sum', () {
      final r = HealthImportService.chooseSourceAwareDistance(
        distanceBySource: const {garmin: 12010, phone: 11592},
        ownerKey: garmin,
        fallback: 23601, // totalDistance = garmin + phone (the old, wrong value)
      );
      expect(r.distance, 12010);
      expect(r.decision, 'source_match');
    });

    test('Garmin short walk: owner wins even when the phone sum is larger', () {
      final r = HealthImportService.chooseSourceAwareDistance(
        distanceBySource: const {garmin: 1331, phone: 1408},
        ownerKey: garmin,
        fallback: 2779,
      );
      expect(r.distance, 1331);
      expect(r.decision, 'source_match');
    });

    test('Garmin cycle: mildly inflated sum still corrected to the watch', () {
      final r = HealthImportService.chooseSourceAwareDistance(
        distanceBySource: const {garmin: 12522, phone: 1250},
        ownerKey: garmin,
        fallback: 13876,
      );
      expect(r.distance, 12522);
      expect(r.decision, 'source_match');
    });

    test('Samsung Health walk: owner picked (refutes "complementary" claim)',
        () {
      final r = HealthImportService.chooseSourceAwareDistance(
        distanceBySource: const {shealth: 3164, phone: 2832},
        ownerKey: shealth,
        fallback: 5996,
      );
      expect(r.distance, 3164);
      expect(r.decision, 'source_match');
    });

    test('Samsung Health walk: owner preferred over a larger phone total', () {
      final r = HealthImportService.chooseSourceAwareDistance(
        distanceBySource: const {shealth: 988, phone: 1060},
        ownerKey: shealth,
        fallback: 2048,
      );
      expect(r.distance, 988);
      expect(r.decision, 'source_match');
    });

    test('HealthSync walk: picks the owner, not the sum', () {
      final r = HealthImportService.chooseSourceAwareDistance(
        distanceBySource: const {healthsync: 3820, phone: 3263},
        ownerKey: healthsync,
        fallback: 7215,
      );
      expect(r.distance, 3820);
      expect(r.decision, 'source_match');
    });

    test('never returns the cross-source sum for any real split', () {
      const splits = <Map<String, double>>[
        {garmin: 12010, phone: 11592},
        {garmin: 1331, phone: 1408},
        {shealth: 3164, phone: 2832},
        {healthsync: 3820, phone: 3263},
      ];
      for (final s in splits) {
        final owner = s.keys.first;
        final sum = s.values.reduce((a, b) => a + b);
        final r = HealthImportService.chooseSourceAwareDistance(
          distanceBySource: s,
          ownerKey: owner,
          fallback: sum,
        );
        expect(r.distance, lessThan(sum),
            reason: 'must not double-count via the sum');
        expect(r.distance, s[owner]);
      }
    });
  });

  group('chooseSourceAwareDistance — edge cases', () {
    test('single source that is the owner → source_match', () {
      final r = HealthImportService.chooseSourceAwareDistance(
        distanceBySource: const {shealth: 5014},
        ownerKey: shealth,
        fallback: 5013,
      );
      expect(r.distance, 5014);
      expect(r.decision, 'source_match');
    });

    test('owner wrote no in-window records → largest single source', () {
      final r = HealthImportService.chooseSourceAwareDistance(
        distanceBySource: const {phone: 5000, 'name:other': 3000},
        ownerKey: garmin, // not present
        fallback: 8000,
      );
      expect(r.distance, 5000);
      expect(r.decision, 'largest_source');
    });

    test('no per-source records at all → totalDistance fallback', () {
      final r = HealthImportService.chooseSourceAwareDistance(
        distanceBySource: const {},
        ownerKey: garmin,
        fallback: 4242,
      );
      expect(r.distance, 4242);
      expect(r.decision, 'fallback_no_sources');
    });
  });
}
