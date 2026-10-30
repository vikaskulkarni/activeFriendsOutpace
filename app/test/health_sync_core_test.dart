import 'package:activefriends/features/import/data/health_sync_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// The source-aware distance regression suite lives in
/// `health_import_source_distance_test.dart` (its fixtures are the regression
/// net and must stay unchanged). This file covers the new value types
/// introduced by the `HealthSyncCore` extraction.
void main() {
  group('WorkoutWindow', () {
    test('holds the partitioned lists it was constructed with', () {
      const window = WorkoutWindow(
        workouts: [],
        distanceDeltas: [],
        heartRates: [],
      );
      expect(window.workouts, isEmpty);
      expect(window.distanceDeltas, isEmpty);
      expect(window.heartRates, isEmpty);
    });
  });

  group('SyncOutcome', () {
    test('exposes exactly the four import outcomes', () {
      expect(SyncOutcome.values, <SyncOutcome>[
        SyncOutcome.imported,
        SyncOutcome.skippedOverlap,
        SyncOutcome.queued,
        SyncOutcome.alreadySynced,
      ]);
    });
  });
}
