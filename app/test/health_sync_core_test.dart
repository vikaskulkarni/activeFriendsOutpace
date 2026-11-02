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

  // The BACKGROUND authorization check must VERIFY permission, never REQUEST
  // it: requesting launches the Health Connect consent UI, which needs a
  // foreground Activity absent in a WorkManager isolate ("Permission launcher
  // not found"). This pure decision captures the platform split that
  // `ensureAuthorized()` wires up.
  group('resolveBackgroundAuthorization', () {
    test('Android: granted permissions authorize the background read', () {
      expect(
        HealthSyncCore.resolveBackgroundAuthorization(
          isAndroid: true,
          androidHasPermissions: true,
        ),
        isTrue,
      );
    });

    test('Android: missing permissions block the background read', () {
      expect(
        HealthSyncCore.resolveBackgroundAuthorization(
          isAndroid: true,
          androidHasPermissions: false,
        ),
        isFalse,
      );
    });

    test('Android: null hasPermissions is treated as not granted', () {
      expect(
        HealthSyncCore.resolveBackgroundAuthorization(
          isAndroid: true,
          androidHasPermissions: null,
        ),
        isFalse,
      );
    });

    test('iOS: never gated on hasPermissions (null still authorizes)', () {
      // HealthKit hides READ-permission status for privacy, so hasPermissions
      // returns null/false even when granted. Let the read proceed.
      expect(
        HealthSyncCore.resolveBackgroundAuthorization(
          isAndroid: false,
          androidHasPermissions: null,
        ),
        isTrue,
      );
    });

    test('iOS: false hasPermissions still authorizes (not gated)', () {
      expect(
        HealthSyncCore.resolveBackgroundAuthorization(
          isAndroid: false,
          androidHasPermissions: false,
        ),
        isTrue,
      );
    });
  });
}
