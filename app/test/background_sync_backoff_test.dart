import 'package:activefriends/features/import/data/background_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 10, 31, 12, 0);

  test('fewer than 3 failures never skips', () {
    expect(
        BackgroundSyncService.shouldSkipForBackoff(
            consecutiveFailures: 2, lastAttemptAt: now, now: now),
        isFalse);
  });

  test('3 failures: skip within 15 min of last attempt, run after', () {
    // 2^(3-3)=1 cycle * 15 min = 15 min backoff.
    expect(
        BackgroundSyncService.shouldSkipForBackoff(
            consecutiveFailures: 3,
            lastAttemptAt: now.subtract(const Duration(minutes: 10)),
            now: now),
        isTrue);
    expect(
        BackgroundSyncService.shouldSkipForBackoff(
            consecutiveFailures: 3,
            lastAttemptAt: now.subtract(const Duration(minutes: 20)),
            now: now),
        isFalse);
  });

  test('10+ failures always skips (until manual trigger)', () {
    expect(
        BackgroundSyncService.shouldSkipForBackoff(
            consecutiveFailures: 10,
            lastAttemptAt: now.subtract(const Duration(days: 7)),
            now: now),
        isTrue);
  });
}
