import 'package:activefriends/features/import/data/health_sync_core.dart';
import 'package:activefriends/features/import/domain/duplicate_detector.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression tests for the HealthKit duplicate-import bug.
///
/// Real production cause (Mahesh's iPhone): Strava writes its OWN HKWorkout into
/// Apple Health for each activity — separate UUID from the Apple Watch's native
/// one, and it re-exports under new UUIDs over time. Since Outpace dedups on
/// `external_id = HKSample.uuid`, each distinct UUID imported as a separate,
/// identical activity. Fix: skip a workout whose (type + >80% time-window)
/// matches an already-imported activity, keeping the first.
ActivityFingerprint _fp(String id, String type, String start, String end) =>
    ActivityFingerprint(
      externalId: id,
      activityType: type,
      startedAt: DateTime.parse(start),
      endedAt: DateTime.parse(end),
    );

void main() {
  group('HealthSyncCore.duplicateExternalIdsToSkip', () {
    test('skips a newcomer UUID that overlaps an already-imported activity', () {
      // Oct-21 walk already imported as UUID A; Strava re-exports it as UUID B
      // on a later run — same window, same type.
      final existing = [
        _fp('A', 'walk', '2026-10-21T01:51:45Z', '2026-10-21T04:47:36Z'),
      ];
      final incoming = [
        _fp('B', 'walk', '2026-10-21T01:51:45Z', '2026-10-21T04:47:36Z'),
      ];
      final skip = HealthSyncCore.duplicateExternalIdsToSkip(
        incoming: incoming,
        existing: existing,
      );
      expect(skip, {'B'});
    });

    test('within one batch, keeps the first and skips the overlapping second', () {
      final incoming = [
        _fp('A', 'walk', '2026-10-21T01:51:45Z', '2026-10-21T04:47:36Z'),
        _fp('B', 'walk', '2026-10-21T01:51:45Z', '2026-10-21T04:47:36Z'),
      ];
      final skip = HealthSyncCore.duplicateExternalIdsToSkip(
        incoming: incoming,
        existing: const [],
      );
      expect(skip, {'B'});
    });

    test('re-syncing the SAME activity (same id already imported) is NOT skipped', () {
      final existing = [
        _fp('A', 'walk', '2026-10-21T01:51:45Z', '2026-10-21T04:47:36Z'),
      ];
      final incoming = [
        _fp('A', 'walk', '2026-10-21T01:51:45Z', '2026-10-21T04:47:36Z'),
      ];
      final skip = HealthSyncCore.duplicateExternalIdsToSkip(
        incoming: incoming,
        existing: existing,
      );
      expect(skip, isEmpty);
    });

    test('two different same-type activities (no time overlap) are both kept', () {
      final incoming = [
        _fp('A', 'walk', '2026-10-21T01:00:00Z', '2026-10-21T02:00:00Z'),
        _fp('B', 'walk', '2026-10-21T06:00:00Z', '2026-10-21T07:00:00Z'),
      ];
      final skip = HealthSyncCore.duplicateExternalIdsToSkip(
        incoming: incoming,
        existing: const [],
      );
      expect(skip, isEmpty);
    });

    test('overlapping but different concrete types are both kept (not merged)', () {
      final incoming = [
        _fp('A', 'walk', '2026-10-21T01:00:00Z', '2026-10-21T02:00:00Z'),
        _fp('B', 'run', '2026-10-21T01:00:00Z', '2026-10-21T02:00:00Z'),
      ];
      final skip = HealthSyncCore.duplicateExternalIdsToSkip(
        incoming: incoming,
        existing: const [],
      );
      expect(skip, isEmpty);
    });
  });
}
