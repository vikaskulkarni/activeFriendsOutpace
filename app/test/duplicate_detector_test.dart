import 'package:activefriends/features/import/domain/duplicate_detector.dart';
import 'package:flutter_test/flutter_test.dart';

ActivityFingerprint activity({
  required String id,
  required String type,
  required DateTime start,
  required DateTime end,
}) =>
    ActivityFingerprint(externalId: id, activityType: type, startedAt: start, endedAt: end);

void main() {
  final start = DateTime.utc(2026, 9, 10, 1);

  test('flags equal-type sessions overlapping more than 80 percent of the shorter duration', () {
    final current = activity(id: 'phone', type: 'run', start: start, end: start.add(const Duration(minutes: 30)));
    final candidate = activity(id: 'watch', type: 'run', start: start.add(const Duration(minutes: 2)), end: start.add(const Duration(minutes: 32)));

    expect(DuplicateDetector.findCandidate(activity: current, candidates: [candidate]), candidate);
  });

  test('does not flag sessions at exactly 80 percent overlap or differing canonical types', () {
    final current = activity(id: 'phone', type: 'run', start: start, end: start.add(const Duration(minutes: 30)));
    final exactThreshold = activity(id: 'watch', type: 'run', start: start.add(const Duration(minutes: 6)), end: start.add(const Duration(minutes: 36)));
    final differentType = activity(id: 'bike', type: 'cycle', start: start, end: start.add(const Duration(minutes: 30)));

    expect(DuplicateDetector.findCandidate(activity: current, candidates: [exactThreshold, differentType]), isNull);
  });

  test('treats other as an unspecified type that can match any session', () {
    final current = activity(id: 'unknown', type: 'other', start: start, end: start.add(const Duration(minutes: 20)));
    final candidate = activity(id: 'watch', type: 'walk', start: start, end: start.add(const Duration(minutes: 20)));

    expect(DuplicateDetector.findCandidate(activity: current, candidates: [candidate]), candidate);
  });

  group('overlapExceeds', () {
    // Jax's real 2026-11-04 duplicate: a phone_gps walk and a health_connect
    // import of the same walk, ~98% overlap of the shorter (import) duration.
    final gpsStart = DateTime.parse('2026-11-04T01:36:15Z');
    final gpsEnd = DateTime.parse('2026-11-04T02:28:43Z');
    final importStart = DateTime.parse('2026-11-04T01:35:18Z');
    final importEnd = DateTime.parse('2026-11-04T02:16:40Z');

    test('is true when overlap exceeds the threshold of the shorter duration', () {
      expect(DuplicateDetector.overlapExceeds(gpsStart, gpsEnd, importStart, importEnd), isTrue);
    });

    test('is order-independent', () {
      expect(DuplicateDetector.overlapExceeds(importStart, importEnd, gpsStart, gpsEnd), isTrue);
    });

    test('is false when overlap is below the threshold', () {
      // 30-min window overlapping a second 30-min window by only 9 min (30%).
      final a = activity(id: 'a', type: 'walk', start: start, end: start.add(const Duration(minutes: 30)));
      final b = activity(id: 'b', type: 'walk', start: start.add(const Duration(minutes: 21)), end: start.add(const Duration(minutes: 51)));
      expect(DuplicateDetector.overlapExceeds(a.startedAt, a.endedAt, b.startedAt, b.endedAt), isFalse);
    });

    test('is false at exactly the threshold (strict greater-than)', () {
      // Two 30-min windows overlapping by exactly 21 min = 70.0% of the shorter.
      final a = activity(id: 'a', type: 'walk', start: start, end: start.add(const Duration(minutes: 30)));
      final b = activity(id: 'b', type: 'walk', start: start.add(const Duration(minutes: 9)), end: start.add(const Duration(minutes: 39)));
      expect(DuplicateDetector.overlapExceeds(a.startedAt, a.endedAt, b.startedAt, b.endedAt), isFalse);
    });

    test('is false when the windows do not overlap', () {
      final a = activity(id: 'a', type: 'walk', start: start, end: start.add(const Duration(minutes: 30)));
      final b = activity(id: 'b', type: 'walk', start: start.add(const Duration(hours: 1)), end: start.add(const Duration(hours: 1, minutes: 30)));
      expect(DuplicateDetector.overlapExceeds(a.startedAt, a.endedAt, b.startedAt, b.endedAt), isFalse);
    });

    test('is false for a non-positive duration', () {
      final zero = activity(id: 'z', type: 'walk', start: start, end: start);
      final b = activity(id: 'b', type: 'walk', start: start, end: start.add(const Duration(minutes: 30)));
      expect(DuplicateDetector.overlapExceeds(zero.startedAt, zero.endedAt, b.startedAt, b.endedAt), isFalse);
    });

    test('honours a custom threshold', () {
      // 50% overlap: above a 0.4 threshold, below the default 0.7.
      final a = activity(id: 'a', type: 'walk', start: start, end: start.add(const Duration(minutes: 30)));
      final b = activity(id: 'b', type: 'walk', start: start.add(const Duration(minutes: 15)), end: start.add(const Duration(minutes: 45)));
      expect(DuplicateDetector.overlapExceeds(a.startedAt, a.endedAt, b.startedAt, b.endedAt, threshold: 0.4), isTrue);
      expect(DuplicateDetector.overlapExceeds(a.startedAt, a.endedAt, b.startedAt, b.endedAt), isFalse);
    });
  });
}