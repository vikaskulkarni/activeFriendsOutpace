import 'package:activefriends/features/tracking/data/gps_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

/// Auto-pause must stop counting only when the user is REALLY stopped.
///
/// The iOS bug: `CLLocation.speed` is often unavailable at walking pace, so
/// `Position.speed` arrives as a `0.0` placeholder (`hasSpeed == false`). The
/// old logic read that as "stopped" and false-paused mid-walk, dropping ~half
/// the distance. The detector must judge movement by displacement when speed is
/// unknown, while preserving the speed-based behaviour where speed IS reported
/// (Android).
void main() {
  AutoPauseDetector walk({bool paused = false}) => AutoPauseDetector(
        pauseSpeedMs: 0.5,
        resumeSpeedMs: 0.8,
        initiallyPaused: paused,
      );

  const baseLat = 47.0;
  const lon = 8.0;
  DateTime t(int s) => DateTime(2026, 1, 1).add(Duration(seconds: s));
  // Metres north of baseLat → latitude (1 deg lat ≈ 111320 m).
  double latAfter(double metres) => baseLat + metres / 111320.0;

  group('known speed (Android reports speed) — behaviour preserved', () {
    test('steady walking speed never auto-pauses', () {
      final d = walk();
      for (var s = 0; s <= 40; s += 2) {
        d.update(
            speedKnown: true,
            speed: 1.4,
            latitude: baseLat,
            longitude: lon,
            timestamp: t(s));
      }
      expect(d.isPaused, isFalse);
    });

    test('genuine stop (speed below threshold for ≥20s) auto-pauses', () {
      final d = walk();
      for (var s = 0; s <= 22; s += 2) {
        d.update(
            speedKnown: true,
            speed: 0.1,
            latitude: baseLat,
            longitude: lon,
            timestamp: t(s));
      }
      expect(d.isPaused, isTrue);
    });

    test('resumes once speed exceeds the resume threshold', () {
      final d = walk(paused: true);
      d.update(
          speedKnown: true,
          speed: 1.0,
          latitude: baseLat,
          longitude: lon,
          timestamp: t(0));
      expect(d.isPaused, isFalse);
    });

    test('hysteresis: between pause and resume thresholds stays paused', () {
      final d = walk(paused: true);
      d.update(
          speedKnown: true,
          speed: 0.6, // > pause 0.5 but < resume 0.8
          latitude: baseLat,
          longitude: lon,
          timestamp: t(0));
      expect(d.isPaused, isTrue);
    });
  });

  group('unknown speed (iOS withholds speed) — judged by displacement', () {
    test('continuous walking with unknown speed does NOT pause (the bug)', () {
      final d = walk();
      // ~1 m/s: position advances 1 m per second; speed arrives as 0.0.
      for (var s = 0; s <= 40; s += 2) {
        d.update(
            speedKnown: false,
            speed: 0.0,
            latitude: latAfter(s.toDouble()),
            longitude: lon,
            timestamp: t(s));
      }
      expect(d.isPaused, isFalse);
    });

    test('truly stationary with unknown speed pauses after the window', () {
      final d = walk();
      for (var s = 0; s <= 24; s += 2) {
        d.update(
            speedKnown: false,
            speed: 0.0,
            latitude: baseLat, // no displacement
            longitude: lon,
            timestamp: t(s));
      }
      expect(d.isPaused, isTrue);
    });

    test('resumes when displacement shows real movement again', () {
      final d = walk(paused: true);
      d.update(
          speedKnown: false,
          speed: 0.0,
          latitude: baseLat,
          longitude: lon,
          timestamp: t(0)); // anchors
      d.update(
          speedKnown: false,
          speed: 0.0,
          latitude: latAfter(20), // 20 m beyond the anchor
          longitude: lon,
          timestamp: t(2));
      expect(d.isPaused, isFalse);
    });
  });

  test('reset() clears pause and movement anchor', () {
    final d = walk(paused: true);
    d.reset();
    expect(d.isPaused, isFalse);
  });
}
