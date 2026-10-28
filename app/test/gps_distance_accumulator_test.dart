import 'dart:math' as math;

import 'package:activefriends/features/tracking/data/gps_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for the net-displacement distance accumulator that replaced the old
/// `segmentM >= 1.5` per-segment gate (which under-counted walks 18-40% at
/// `distanceFilter: 1`). Synthetic tracks are laid along a meridian so
/// 1° latitude ≈ 111194.93 m and Haversine ≈ the intended metre offset.
///
/// Assertions use ranges: displacement anchoring yields the true path length
/// minus at most one trailing sub-threshold leg, so exact totals shift with the
/// commit cadence — the invariants (not inflated, not under by > threshold,
/// jitter suppressed, corner preserved) are what matter.

const double _mPerDegLat = 111194.93; // 6371000 * pi / 180

double _lat(double meters) => meters / _mPerDegLat;
double _lon(double meters) => meters / _mPerDegLat; // cos(0°) = 1 at equator

double _haversineM(double la1, double lo1, double la2, double lo2) {
  const r = 6371000.0;
  double rad(double d) => d * math.pi / 180.0;
  final dLa = rad(la2 - la1);
  final dLo = rad(lo2 - lo1);
  final a = math.sin(dLa / 2) * math.sin(dLa / 2) +
      math.cos(rad(la1)) * math.cos(rad(la2)) *
          math.sin(dLo / 2) * math.sin(dLo / 2);
  return r * 2 * math.asin(math.min(1.0, math.sqrt(a)));
}

void main() {
  group('GpsDistanceAccumulator', () {
    test('straight 100 m walk in 2 m steps: ≈ true, not inflated', () {
      final acc = GpsDistanceAccumulator(); // threshold 8 m
      for (var m = 0.0; m <= 100.0; m += 2.0) {
        acc.addFix(latitude: _lat(m), longitude: 0, accuracy: 10);
      }
      expect(acc.distanceM, greaterThanOrEqualTo(92)); // ≤ one trailing leg lost
      expect(acc.distanceM, lessThanOrEqualTo(100.5)); // never inflated
    });

    test('stationary jitter accumulates ~zero distance', () {
      final acc = GpsDistanceAccumulator();
      for (final j in <double>[0, 2, -2, 3, -3, 1, -1, 2.5, -2.5, 0]) {
        acc.addFix(latitude: _lat(j), longitude: _lon(j), accuracy: 8);
      }
      expect(acc.distanceM, 0);
    });

    test('lateral jitter is suppressed, not summed (vs naive raw sum)', () {
      final acc = GpsDistanceAccumulator();
      var rawSum = 0.0;
      double? prevLat, prevLon;
      for (var i = 0; i <= 50; i++) {
        final la = _lat(i * 2.0); // 2 m north each step
        final lo = _lon(i.isEven ? 1.0 : -1.0); // ±1 m lateral jitter
        if (prevLat != null) rawSum += _haversineM(prevLat, prevLon!, la, lo);
        acc.addFix(latitude: la, longitude: lo, accuracy: 10);
        prevLat = la;
        prevLon = lo;
      }
      expect(acc.distanceM, lessThan(rawSum)); // zig-zag not summed
      expect(acc.distanceM, greaterThanOrEqualTo(92));
      expect(acc.distanceM, lessThanOrEqualTo(105));
    });

    test('corner is preserved (L-shaped path ≈ sum of legs)', () {
      final acc = GpsDistanceAccumulator();
      for (var m = 0.0; m <= 48.0; m += 2.0) {
        acc.addFix(latitude: _lat(m), longitude: 0, accuracy: 10); // 48 m north
      }
      for (var m = 2.0; m <= 48.0; m += 2.0) {
        acc.addFix(latitude: _lat(48), longitude: _lon(m), accuracy: 10); // east
      }
      // ~96 m of real path, not the ~68 m straight-line diagonal.
      expect(acc.distanceM, greaterThan(80));
      expect(acc.distanceM, lessThanOrEqualTo(96.5));
    });

    test('a loose (>30 m) fix never anchors or fakes a jump', () {
      final acc = GpsDistanceAccumulator();
      acc.addFix(latitude: _lat(0), longitude: 0, accuracy: 10); // anchor at 0
      final jumped =
          acc.addFix(latitude: _lat(50), longitude: 0, accuracy: 40); // loose
      expect(jumped, 0);
      expect(acc.distanceM, 0); // 50 m jump ignored
      acc.addFix(latitude: _lat(12), longitude: 0, accuracy: 10); // real 12 m
      expect(acc.distanceM, closeTo(12, 0.6));
    });

    test('resetAnchor drops the gap (pause/resume not counted)', () {
      final acc = GpsDistanceAccumulator();
      acc.addFix(latitude: _lat(0), longitude: 0, accuracy: 10);
      acc.addFix(latitude: _lat(20), longitude: 0, accuracy: 10); // commit 20
      expect(acc.distanceM, closeTo(20, 0.6));
      acc.resetAnchor(); // pause
      acc.addFix(latitude: _lat(100), longitude: 0, accuracy: 10); // re-anchor
      expect(acc.distanceM, closeTo(20, 0.6)); // 20→100 gap NOT counted
      acc.addFix(latitude: _lat(112), longitude: 0, accuracy: 10); // commit 12
      expect(acc.distanceM, closeTo(32, 0.6));
    });

    test('initialDistanceM seeds a restored session', () {
      final acc = GpsDistanceAccumulator(initialDistanceM: 500);
      for (var m = 0.0; m <= 100.0; m += 2.0) {
        acc.addFix(latitude: _lat(m), longitude: 0, accuracy: 10);
      }
      expect(acc.distanceM, greaterThanOrEqualTo(592));
      expect(acc.distanceM, lessThanOrEqualTo(601));
    });
  });
}
