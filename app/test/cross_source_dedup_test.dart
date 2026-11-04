import 'package:activefriends/features/import/data/cross_source_dedup.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reverse-direction dedup: when an Outpace GPS activity is saved, any
/// Health Connect / HealthKit import of the SAME real-world activity (e.g. the
/// phone's own background tracker, auto-synced mid-activity) is superseded.
///
/// Confirmed cause (Jax, 2026-11-04, no watch): background auto-sync imported
/// the phone's health_connect walk at 02:17 — ~11 min BEFORE the phone_gps
/// walk was saved at 02:28. The import-time skip could not fire (no GPS row
/// yet); this GPS-save path catches it.
ImportCandidate _import(
  String id,
  String source,
  String start,
  String end, {
  bool excluded = false,
}) =>
    ImportCandidate(
      id: id,
      source: source,
      startedAt: DateTime.parse(start),
      endedAt: DateTime.parse(end),
      excluded: excluded,
    );

void main() {
  // Jax's real duplicate window.
  final gpsStart = DateTime.parse('2026-11-04T01:36:15Z');
  final gpsEnd = DateTime.parse('2026-11-04T02:28:43Z');

  Set<String> superseded(List<ImportCandidate> imports) =>
      CrossSourceDedup.importIdsSupersededByGps(
        gpsStart: gpsStart,
        gpsEnd: gpsEnd,
        imports: imports,
      );

  group('CrossSourceDedup.importIdsSupersededByGps', () {
    test('supersedes a health_connect import overlapping the GPS window', () {
      final imports = [
        _import('hc', 'health_connect', '2026-11-04T01:35:18Z', '2026-11-04T02:16:40Z'),
      ];
      expect(superseded(imports), {'hc'});
    });

    test('supersedes a healthkit import too (iOS parity)', () {
      final imports = [
        _import('hk', 'healthkit', '2026-11-04T01:35:18Z', '2026-11-04T02:16:40Z'),
      ];
      expect(superseded(imports), {'hk'});
    });

    test('is type-agnostic: a differently-classified import still matches', () {
      // The phone auto-classified the walk as something else; same window.
      final imports = [
        _import('hc', 'health_connect', '2026-11-04T01:40:00Z', '2026-11-04T02:20:00Z'),
      ];
      expect(superseded(imports), {'hc'});
    });

    test('ignores an already-excluded import', () {
      final imports = [
        _import('hc', 'health_connect', '2026-11-04T01:35:18Z', '2026-11-04T02:16:40Z', excluded: true),
      ];
      expect(superseded(imports), isEmpty);
    });

    test('never supersedes another phone_gps activity', () {
      final imports = [
        _import('gps2', 'phone_gps', '2026-11-04T01:36:15Z', '2026-11-04T02:28:43Z'),
      ];
      expect(superseded(imports), isEmpty);
    });

    test('ignores a non-overlapping import', () {
      final imports = [
        _import('hc', 'health_connect', '2026-11-04T05:00:00Z', '2026-11-04T05:40:00Z'),
      ];
      expect(superseded(imports), isEmpty);
    });

    test('returns empty when there are no imports', () {
      expect(superseded(const []), isEmpty);
    });

    test('supersedes only the overlapping imports among several', () {
      final imports = [
        _import('hc1', 'health_connect', '2026-11-04T01:35:18Z', '2026-11-04T02:16:40Z'),
        _import('hc2', 'health_connect', '2026-11-04T09:00:00Z', '2026-11-04T09:40:00Z'),
      ];
      expect(superseded(imports), {'hc1'});
    });
  });
}
