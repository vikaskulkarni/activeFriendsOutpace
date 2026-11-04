import 'package:activefriends/features/import/domain/duplicate_detector.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

/// A health import that may duplicate a just-saved GPS activity.
class ImportCandidate {
  const ImportCandidate({
    required this.id,
    required this.source,
    required this.startedAt,
    required this.endedAt,
    required this.excluded,
  });

  final String id;
  final String source;
  final DateTime startedAt;
  final DateTime endedAt;
  final bool excluded;
}

/// Reverse-direction cross-source dedup.
///
/// When an Outpace GPS activity is saved, the SAME real-world activity may
/// already have been imported from Health Connect / HealthKit — e.g. the
/// phone's own background tracker, auto-synced mid-activity before the user
/// tapped stop. The GPS record is primary (it carries the map route), so those
/// imports are superseded: marked `excluded` (which zeroes their points and
/// leaderboard totals) and linked to the GPS activity by a shared
/// `dup_group_id`.
///
/// This is the mirror image of [HealthSyncCore]'s import-time overlap skip,
/// which only fires when the GPS row already exists. Together the two cover
/// both orderings; this path handles the common case where the import lands
/// first. Both reuse [DuplicateDetector.overlapExceeds] for identical math.
class CrossSourceDedup {
  CrossSourceDedup(this._client);

  final SupabaseClient _client;

  /// Import sources a GPS activity can supersede.
  static const importSources = {'health_connect', 'healthkit'};

  /// Pure selection: the ids of [imports] that the GPS window
  /// [gpsStart]–[gpsEnd] supersedes (type-agnostic, > [threshold] overlap of
  /// the shorter duration). Skips already-excluded rows and any source that is
  /// not a health import (never touches another `phone_gps` activity).
  static Set<String> importIdsSupersededByGps({
    required DateTime gpsStart,
    required DateTime gpsEnd,
    required List<ImportCandidate> imports,
    double threshold = 0.7,
  }) {
    final ids = <String>{};
    for (final candidate in imports) {
      if (candidate.excluded) continue;
      if (!importSources.contains(candidate.source)) continue;
      if (DuplicateDetector.overlapExceeds(
        gpsStart,
        gpsEnd,
        candidate.startedAt,
        candidate.endedAt,
        threshold: threshold,
      )) {
        ids.add(candidate.id);
      }
    }
    return ids;
  }

  /// Find health imports overlapping the GPS activity [gpsActivityId]
  /// ([start]–[end]) and mark the matches excluded, linking them and the GPS
  /// activity under one `dup_group_id`. Returns the number superseded.
  ///
  /// Best-effort: any failure returns 0 and never throws, so a save is never
  /// blocked or broken (mirrors the import path's offline-safety). The query
  /// window is widened ±2 minutes to catch starts/stops a few seconds apart;
  /// the exact overlap test uses the original timestamps.
  Future<int> supersedeImportsForGpsActivity({
    required String userId,
    required String gpsActivityId,
    required DateTime start,
    required DateTime end,
  }) async {
    try {
      final windowStart = start.subtract(const Duration(minutes: 2));
      final windowEnd = end.add(const Duration(minutes: 2));
      final rows = await _client
          .from('activities')
          .select('id, source, started_at, ended_at, excluded')
          .eq('user_id', userId)
          .inFilter('source', importSources.toList())
          .lte('started_at', windowEnd.toUtc().toIso8601String())
          .gte('ended_at', windowStart.toUtc().toIso8601String());

      final candidates = <ImportCandidate>[
        for (final row in rows as List<dynamic>)
          if (row['id'] != null &&
              row['started_at'] != null &&
              row['ended_at'] != null)
            ImportCandidate(
              id: row['id'] as String,
              source: row['source'] as String? ?? '',
              startedAt: DateTime.parse(row['started_at'] as String),
              endedAt: DateTime.parse(row['ended_at'] as String),
              excluded: row['excluded'] as bool? ?? false,
            ),
      ];

      final ids = importIdsSupersededByGps(
        gpsStart: start,
        gpsEnd: end,
        imports: candidates,
      );
      if (ids.isEmpty) return 0;

      final groupId = const Uuid().v4();
      await _client
          .from('activities')
          .update({'excluded': true, 'dup_group_id': groupId})
          .inFilter('id', ids.toList());
      // Link the primary GPS activity to the same group for traceability.
      await _client
          .from('activities')
          .update({'dup_group_id': groupId}).eq('id', gpsActivityId);
      return ids.length;
    } catch (_) {
      // Best-effort: never break the save over a dedup failure (offline, RLS,
      // schema). The import-time skip remains a backstop for future imports.
      return 0;
    }
  }
}
