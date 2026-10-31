import 'package:activefriends/features/tracking/data/gps_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

/// Auto-pause must stop counting only when the user is REALLY stopped.
///
/// The iOS bug: `CLLocation.speed` is often unavailable at walking pace, so
/// `Position.speed` arrives as a `0.0` placeholder (`hasSpeed == false`). The
/// old logic read that as "stopped" and false-paused mid-walk, dropping ~half
/// the distance. The detector judges movement by displacement when speed is
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

  // Default to a tight accuracy so the accuracy gate never interferes unless a
  // test is specifically about it.
  void step(
    AutoPauseDetector d, {
    required bool speedKnown,
    required double speed,
    required int atS,
    double metres = 0,
    double accuracy = 5,
  }) {
    d.update(
      speedKnown: speedKnown,
      speed: speed,
      latitude: latAfter(metres),
      longitude: lon,
      accuracy: accuracy,
      timestamp: t(atS),
    );
  }

  group('known speed (Android reports speed) — behaviour preserved', () {
    test('steady walking speed never auto-pauses', () {
      final d = walk();
      for (var s = 0; s <= 40; s += 2) {
        step(d, speedKnown: true, speed: 1.4, atS: s);
      }
      expect(d.isPaused, isFalse);
    });

    test('genuine stop (speed below threshold for ≥20s) auto-pauses', () {
      final d = walk();
      for (var s = 0; s <= 22; s += 2) {
        step(d, speedKnown: true, speed: 0.1, atS: s);
      }
      expect(d.isPaused, isTrue);
    });

    test('resumes once speed exceeds the resume threshold', () {
      final d = walk(paused: true);
      step(d, speedKnown: true, speed: 1.0, atS: 0);
      expect(d.isPaused, isFalse);
    });

    test('hysteresis: between pause and resume thresholds stays paused', () {
      final d = walk(paused: true);
      step(d, speedKnown: true, speed: 0.6, atS: 0); // > pause 0.5, < resume 0.8
      expect(d.isPaused, isTrue);
    });
  });

  group('unknown speed (iOS withholds speed) — judged by displacement', () {
    test('continuous walking with unknown speed does NOT pause (the bug)', () {
      final d = walk();
      // ~1 m/s: position advances 1 m per second; speed arrives as 0.0.
      for (var s = 0; s <= 40; s += 2) {
        step(d, speedKnown: false, speed: 0.0, metres: s.toDouble(), atS: s);
      }
      expect(d.isPaused, isFalse);
    });

    test('truly stationary with unknown speed pauses after the window', () {
      final d = walk();
      for (var s = 0; s <= 24; s += 2) {
        step(d, speedKnown: false, speed: 0.0, atS: s); // no displacement
      }
      expect(d.isPaused, isTrue);
    });

    test('resumes when displacement shows real movement again', () {
      final d = walk(paused: true);
      step(d, speedKnown: false, speed: 0.0, atS: 0); // anchors
      step(d, speedKnown: false, speed: 0.0, metres: 20, atS: 2);
      expect(d.isPaused, isFalse);
    });

    test('loose-accuracy jitter while stationary still auto-pauses', () {
      // accuracy > 30 m: positions bounce >8 m but must NOT count as movement,
      // or a standstill would never auto-pause (review issue #1).
      final d = walk();
      for (var s = 0; s <= 24; s += 2) {
        step(d,
            speedKnown: false,
            speed: 0.0,
            metres: s % 4 == 0 ? 0 : 12, // >8 m jitter between fixes
            accuracy: 40,
            atS: s);
      }
      expect(d.isPaused, isTrue);
    });
  });

  group('transitions', () {
    test('moving → brief still (<20s) → moving does not pause', () {
      final d = walk();
      for (var s = 0; s <= 10; s += 2) {
        step(d, speedKnown: false, speed: 0.0, metres: s.toDouble(), atS: s);
      }
      for (var s = 12; s <= 22; s += 2) {
        step(d, speedKnown: false, speed: 0.0, metres: 10, atS: s); // still 10s
      }
      step(d, speedKnown: false, speed: 0.0, metres: 30, atS: 24); // moving
      expect(d.isPaused, isFalse);
    });

    test('speed availability flipping mid-walk does not spuriously pause', () {
      final d = walk();
      for (var s = 0; s <= 40; s += 2) {
        final known = s % 4 == 0;
        step(d,
            speedKnown: known,
            speed: known ? 1.4 : 0.0,
            metres: s.toDouble(),
            atS: s);
      }
      expect(d.isPaused, isFalse);
    });
  });

  test('reset() clears pause and movement anchor', () {
    final d = walk(paused: true);
    d.reset();
    expect(d.isPaused, isFalse);
  });
}
