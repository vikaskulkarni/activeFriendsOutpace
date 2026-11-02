import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:activefriends/features/import/data/local_import_repository.dart';
import 'package:activefriends/features/import/domain/duplicate_detector.dart';
import 'package:health/health.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The in-window Health Connect / HealthKit read, partitioned by type.
///
/// Carries the full window context (all DISTANCE_DELTA and HEART_RATE records
/// for the read range) so that per-workout distance and HR are always computed
/// against the complete set of in-window records — never a single workout's
/// isolated `totalDistance`. Reading in isolation re-introduces the `ceb118c`
/// double-distance regression.
class WorkoutWindow {
  const WorkoutWindow({
    required this.workouts,
    required this.distanceDeltas,
    required this.heartRates,
  });

  final List<HealthDataPoint> workouts;
  final List<HealthDataPoint> distanceDeltas;
  final List<HealthDataPoint> heartRates;
}

/// Result of attempting to sync a single workout.
///
/// * [imported]       — new activity, upserted to Supabase successfully.
/// * [skippedOverlap] — overlaps an existing Outpace GPS activity; not imported.
/// * [queued]         — new activity, upsert failed (offline) and was queued.
/// * [alreadySynced]  — previously imported (external_id already in Supabase).
enum SyncOutcome { imported, skippedOverlap, queued, alreadySynced }

/// Reusable read / transform / upsert logic shared by the manual import
/// (`HealthImportService`) and the future background auto-sync path, so both
/// run the SAME code. This is a behaviour-preserving extraction of the logic
/// that previously lived inline in `HealthImportService.importRecentWorkouts`.
class HealthSyncCore {
  HealthSyncCore({
    required Health health,
    required SupabaseClient client,
    required LocalImportRepository localRepository,
  }) : _health = health, // ignore: prefer_initializing_formals
       _client = client, // ignore: prefer_initializing_formals
       _localRepository = localRepository; // ignore: prefer_initializing_formals

  final Health _health;
  final SupabaseClient _client;
  final LocalImportRepository _localRepository;

  // Types we actually READ and surface in the import.
  // DISTANCE_DELTA is read on Android so we can compute per-source distance
  // and avoid double-counting when multiple apps (Garmin + phone pedometer)
  // write DistanceRecords for the same time window.
  // ⚠️ DISTANCE_DELTA is Android-only in the health package — it has no iOS
  // HealthKit mapping. Passing it to getHealthDataFromTypes on iOS causes the
  // plugin to return FlutterError(INVALID_TYPE), which kills the entire read
  // (including WORKOUT and HEART_RATE). On iOS we fall back to the workout's
  // built-in totalDistance instead.
  static final readTypes = [
    HealthDataType.WORKOUT,
    HealthDataType.HEART_RATE,
    if (Platform.isAndroid) HealthDataType.DISTANCE_DELTA,
  ];

  // Types we must hold READ permission for. When the health package reads a
  // WORKOUT (ExerciseSessionRecord) on Android it internally reads
  // DistanceRecord, TotalCaloriesBurnedRecord and StepsRecord for the session
  // window to compute totals (HealthDataReader.handleWorkoutData). Health
  // Connect throws a SecurityException if we lack permission for ANY of them,
  // and the package swallows it and returns an EMPTY list — which looked like
  // "0 workouts". health 13.0.0 stopped auto-requesting DISTANCE_DELTA /
  // TOTAL_CALORIES_BURNED alongside WORKOUT, so they must be requested here.
  static const authTypes = [
    HealthDataType.WORKOUT,
    HealthDataType.HEART_RATE,
    HealthDataType.DISTANCE_DELTA,
    HealthDataType.TOTAL_CALORIES_BURNED,
    HealthDataType.STEPS,
  ];

  /// Verify (never request) READ authorization for the BACKGROUND path.
  ///
  /// Unlike the manual path, this runs in a context with no foreground
  /// Activity (an Android WorkManager isolate), so it must NOT call
  /// `requestAuthorization` / `requestHealthDataHistoryAuthorization` — those
  /// try to launch the Health Connect consent UI and fail with "Permission
  /// launcher not found", leaving the worker to report SUCCESS while importing
  /// nothing. The grant is instead requested in the foreground when the user
  /// enables auto-sync (see `AutoSyncPlatform._register`).
  ///
  /// Returns false only when we can positively tell the read will be denied:
  ///   • Android: `hasPermissions(authTypes, READ)` is false (null ⇒ false).
  ///   • iOS: never gated — HealthKit hides READ-permission status for privacy
  ///     (`hasPermissions` returns null/false even when granted), so we let the
  ///     read proceed (a granted read returns data; an ungranted one is empty).
  /// Safe to call repeatedly.
  Future<bool> ensureAuthorized() async {
    await _health.configure();
    if (!Platform.isAndroid) {
      return resolveBackgroundAuthorization(
        isAndroid: false,
        androidHasPermissions: null,
      );
    }
    final hasPermissions = await _health.hasPermissions(
      authTypes,
      permissions: authTypes.map((_) => HealthDataAccess.READ).toList(),
    );
    return resolveBackgroundAuthorization(
      isAndroid: true,
      androidHasPermissions: hasPermissions,
    );
  }

  /// Pure background-authorization decision, extracted so the platform split is
  /// unit-testable (`Platform.isAndroid` and the real `Health` plugin are not).
  /// See [ensureAuthorized] for the semantics.
  @visibleForTesting
  static bool resolveBackgroundAuthorization({
    required bool isAndroid,
    required bool? androidHasPermissions,
  }) {
    if (!isAndroid) return true; // iOS: never gate on hasPermissions.
    return androidHasPermissions ?? false;
  }

  /// Read the raw health data for [from]–[to] and partition it by type.
  ///
  /// Assumes `Health.configure()` + authorization have already run (the manual
  /// path does this before calling). Preserves the Android-only DISTANCE_DELTA
  /// guard via [readTypes].
  Future<WorkoutWindow> readWorkouts({
    required DateTime from,
    required DateTime to,
  }) async {
    final data = await _health.getHealthDataFromTypes(
      startTime: from,
      endTime: to,
      types: readTypes,
    );
    final heartRates = data
        .where((point) => point.type == HealthDataType.HEART_RATE)
        .toList();
    final workouts = data
        .where((point) => point.type == HealthDataType.WORKOUT)
        .toList();
    final distanceDeltas = data
        .where((point) => point.type == HealthDataType.DISTANCE_DELTA)
        .toList();
    return WorkoutWindow(
      workouts: workouts,
      distanceDeltas: distanceDeltas,
      heartRates: heartRates,
    );
  }

  /// Fetch external_ids already in Supabase so we can distinguish truly new
  /// imports from re-syncs of the same activity (the full-window rescan
  /// intentionally re-reads everything to catch late-syncing watches).
  /// If this lookup fails (offline / Supabase down), fall back to an empty
  /// set — every activity counts as "new", which matches the old behaviour
  /// and avoids blocking the import entirely.
  Future<Set<String>> existingExternalIds(
    String userId,
    String source,
    DateTime from,
    DateTime to,
  ) async {
    var existingIds = <String>{};
    try {
      final existingRows = await _client
          .from('activities')
          .select('external_id')
          .eq('user_id', userId)
          .eq('source', source)
          .gte('started_at', from.toUtc().toIso8601String())
          .lte('started_at', to.toUtc().toIso8601String());
      existingIds = <String>{
        for (final row in existingRows as List<dynamic>)
          if (row['external_id'] != null) row['external_id'] as String,
      };
    } catch (_) {
      // Network failure — proceed with empty set (old behaviour).
    }
    return existingIds;
  }

  /// Transform and upsert a single [workout], returning the [SyncOutcome].
  ///
  /// Distance and HR are computed from [window] (all in-window DISTANCE_DELTA /
  /// HEART_RATE records, grouped by source), NEVER from the workout's isolated
  /// `totalDistance`. [existingExternalIds] determines new vs already-synced.
  Future<SyncOutcome> syncSingleActivity({
    required String userId,
    required String source,
    required HealthDataPoint workout,
    required WorkoutWindow window,
    required Set<String> existingExternalIds,
    void Function(Map<String, dynamic> diag)? onDistanceDiag,
  }) async {
    final value = workout.value;
    if (value is! WorkoutHealthValue) {
      // Defensive: the manual path pre-filters non-workout values (so it can
      // track them in diagnostics). WORKOUT points always carry a
      // WorkoutHealthValue in practice, so this branch is only a safety net
      // for the background path.
      return SyncOutcome.skippedOverlap;
    }

    // ── Cross-source dedup: skip imports that overlap with Outpace GPS ──
    // If the user tracked from Outpace AND their watch simultaneously,
    // the Outpace GPS activity is the primary record (has map route).
    // The import is redundant — skip it entirely so it never appears
    // in the feed and doesn't double-count points.
    final workoutType = _mapActivityType(value.workoutActivityType);
    if (await _overlapsOutpaceActivity(
      userId: userId,
      start: workout.dateFrom.toUtc(),
      end: workout.dateTo.toUtc(),
    )) {
      return SyncOutcome.skippedOverlap;
    }

    final heartRates = window.heartRates
        .where(
          (sample) =>
              !sample.dateFrom.isBefore(workout.dateFrom) &&
              !sample.dateFrom.isAfter(workout.dateTo),
        )
        .map((sample) => sample.value)
        .whereType<NumericHealthValue>()
        .map((sample) => sample.numericValue.toInt())
        .toList();
    // ── Source-aware distance ─────────────────────────────────────
    // Health Connect's totalDistance sums ALL DistanceRecord entries
    // in the workout window regardless of source. If Garmin AND the
    // phone pedometer both write distance records, the result is
    // inflated by 10-20%. Fix: sum only the DISTANCE_DELTA records
    // from the same sourceId as the workout itself. Fall back to
    // totalDistance when no per-source records are available (iOS /
    // older data).
    final distResult = _computeSourceAwareDistance(
      workout: workout,
      distanceRecords: window.distanceDeltas,
      fallback: value.totalDistance?.toDouble(),
    );
    final sourceAwareDistance = distResult.distance;
    // Emit the per-workout distance decision to the optional diag sink.
    // Invoked only AFTER the overlap-skip above, so the manual import's
    // collected list is empty exactly when there were no non-overlapping
    // workouts (restores the original persisted-diagnostics trigger). The
    // shape matches the pre-extraction `distanceDiags.add({...})` entry.
    onDistanceDiag?.call({
      'type': workoutType,
      'started_at': workout.dateFrom.toUtc().toIso8601String(),
      'uuid': workout.uuid,
      ...distResult.diag,
    });

    final activity = <String, dynamic>{
      'user_id': userId,
      'type': workoutType,
      'started_at': workout.dateFrom.toUtc().toIso8601String(),
      'ended_at': workout.dateTo.toUtc().toIso8601String(),
      'distance_m': sourceAwareDistance?.round(),
      // The health Flutter package does not expose moving/active time —
      // Health Connect's ExerciseSessionRecord has no activeDuration field
      // and the plugin doesn't read ExerciseSegments. Setting moving_time_s
      // to the wall-clock duration was WRONG: Datta's 3h walk showed
      // "Moving time: 3h" when real moving time was 1h 6m (from Garmin).
      // Leave moving_time_s null so the card shows only elapsed time and
      // calculates pace from elapsed (honest, if slightly conservative).
      'moving_time_s': null,
      'elapsed_s': workout.dateTo.difference(workout.dateFrom).inSeconds,
      'avg_hr': heartRates.isEmpty
          ? null
          : (heartRates.reduce((sum, rate) => sum + rate) / heartRates.length)
                .round(),
      'max_hr': heartRates.isEmpty
          ? null
          : heartRates.reduce(
              (current, rate) => current > rate ? current : rate,
            ),
      'calories': value.totalEnergyBurned?.round(),
      'source': source,
      'external_id': workout.uuid,
      'status': 'pending',
    };
    await _localRepository.cacheActivity(activity, syncStatus: 'pending');
    // Local same-source dedup (belt-and-suspenders): checks against the
    // on-device cache for overlapping activities from the same source.
    // If the cache is stale (app reinstalled / cleared), this may miss a
    // duplicate — but the Supabase upsert on (user_id, source, external_id)
    // is the authoritative safety net and prevents actual data corruption.
    final duplicate = await _localRepository.flagDuplicateIfNeeded(activity);
    if (duplicate != null) {
      activity['review_state'] = 'needs_review';
      activity['dup_group_id'] = duplicate.groupId;
      await _localRepository.cacheActivity(activity, syncStatus: 'pending');
      await _syncActivity(duplicate.candidatePayload);
    }
    final isNew = !existingExternalIds.contains(workout.uuid);
    if (await _syncActivity(activity)) {
      await _localRepository.markSynced(activity);
      return isNew ? SyncOutcome.imported : SyncOutcome.alreadySynced;
    }
    return isNew ? SyncOutcome.queued : SyncOutcome.alreadySynced;
  }

  Future<void> syncPendingActivities() async {
    for (final pending in await _localRepository.pendingSyncs()) {
      final activity = _localRepository.decodePayload(pending);
      try {
        await _client
            .from('activities')
            .upsert(activity, onConflict: 'user_id,source,external_id');
        await _localRepository.markSynced(activity);
        await _localRepository.removePendingSync(pending.id);
      } catch (_) {
        continue;
      }
    }
  }

  Future<bool> _syncActivity(Map<String, dynamic> activity) async {
    try {
      await _client
          .from('activities')
          .upsert(activity, onConflict: 'user_id,source,external_id');
      return true;
    } catch (_) {
      await _localRepository.queueActivity(activity);
      return false;
    }
  }

  /// Returns true if [start]–[end] overlaps an existing Outpace GPS activity
  /// for the same user by more than 70% of the shorter activity's duration.
  /// This prevents imports from HealthKit / Health Connect from creating
  /// duplicates when the user tracked from both Outpace and their watch
  /// simultaneously.
  ///
  /// The check is **type-agnostic**: a walk in Outpace and a "mixed cardio"
  /// import from the watch ARE the same activity if the time windows overlap.
  /// Earlier versions required an exact type match, which caused duplicates
  /// when the watch auto-classified the activity differently.
  Future<bool> _overlapsOutpaceActivity({
    required String userId,
    required DateTime start,
    required DateTime end,
  }) async {
    // Widen the query window by ±2 minutes to catch activities where the
    // watch and phone were started/stopped a few seconds apart.
    final windowStart = start.subtract(const Duration(minutes: 2));
    final windowEnd = end.add(const Duration(minutes: 2));

    // Query ALL Outpace GPS activities (any type) that overlap the window.
    final response = await _client
        .from('activities')
        .select('started_at, ended_at')
        .eq('user_id', userId)
        .eq('source', 'phone_gps')
        .lte('started_at', windowEnd.toIso8601String())
        .gte('ended_at', windowStart.toIso8601String());

    final candidates = response as List<dynamic>;
    if (candidates.isEmpty) return false;

    final importDuration = end.difference(start).inSeconds;
    if (importDuration <= 0) return false;

    for (final row in candidates) {
      final gpsStart = DateTime.parse(row['started_at'] as String);
      final gpsEnd = DateTime.parse(row['ended_at'] as String);
      final gpsDuration = gpsEnd.difference(gpsStart).inSeconds;
      if (gpsDuration <= 0) continue;

      // Calculate overlap using the ORIGINAL (non-widened) timestamps.
      final overlapStart = start.isAfter(gpsStart) ? start : gpsStart;
      final overlapEnd = end.isBefore(gpsEnd) ? end : gpsEnd;
      final overlapSecs = overlapEnd.difference(overlapStart).inSeconds;
      if (overlapSecs <= 0) continue;

      // 70% threshold (was 80%) — more forgiving when the watch and phone
      // disagree on exact start/stop times.
      final shorterDuration =
          importDuration < gpsDuration ? importDuration : gpsDuration;
      if (overlapSecs / shorterDuration > 0.7) {
        return true;
      }
    }
    return false;
  }

  /// Compute distance for a workout, using the workout's own `totalDistance`
  /// (fallback) as the primary value, with overlap detection as a safety net.
  ///
  /// Previous approach tried to pick one source's DISTANCE_DELTA records,
  /// but this broke Samsung Health imports where two sources (Samsung Health
  /// + phone step counter) write COMPLEMENTARY (not duplicate) distance
  /// records — each covering ~50% of the real distance.
  ///
  /// New strategy (v2):
  /// 1. Default to `totalDistance` from the workout — this is what Health
  ///    Connect computes internally and is correct for most devices.
  /// 2. Only override when we detect temporal overlap in a SINGLE source
  ///    bucket (all sourceIds/sourceNames collapse to one key), which
  ///    indicates true duplication (e.g. Garmin + phone pedometer both
  ///    writing identical DistanceRecords with empty sourceId). In that
  ///    case, halve the distance.
  /// 3. Still collect per-source diagnostics for debugging.
  ({double? distance, Map<String, dynamic> diag}) _computeSourceAwareDistance({
    required HealthDataPoint workout,
    required List<HealthDataPoint> distanceRecords,
    required double? fallback,
  }) {
    // Filter to records within the workout window.
    final windowRecords = distanceRecords.where((d) {
      return !d.dateFrom.isBefore(workout.dateFrom) &&
          !d.dateTo.isAfter(
            workout.dateTo.add(const Duration(seconds: 30)),
          );
    }).toList();

    if (windowRecords.isEmpty) {
      return (
        distance: fallback,
        diag: <String, dynamic>{
          'decision': 'fallback_no_window_records',
          'total_distance_records': distanceRecords.length,
          'window_records': 0,
          'fallback_m': fallback,
          'workout_source': workout.sourceId,
          'workout_sourceName': workout.sourceName,
        },
      );
    }

    // ── Determine source key ──────────────────────────────────────────
    String sourceKey(HealthDataPoint p) {
      if (p.sourceId.isNotEmpty) return p.sourceId;
      if (p.sourceName.isNotEmpty) return 'name:${p.sourceName}';
      return '';
    }

    // Group by source key and sum distance per source (for diagnostics).
    final distanceBySource = <String, double>{};
    for (final record in windowRecords) {
      final value = record.value;
      if (value is NumericHealthValue) {
        final key = sourceKey(record);
        distanceBySource[key] =
            (distanceBySource[key] ?? 0) + value.numericValue.toDouble();
      }
    }

    if (distanceBySource.isEmpty) {
      return (
        distance: fallback,
        diag: <String, dynamic>{
          'decision': 'fallback_no_numeric',
          'window_records': windowRecords.length,
          'fallback_m': fallback,
          'workout_source': workout.sourceId,
          'workout_sourceName': workout.sourceName,
        },
      );
    }

    final sourceNames = windowRecords.map((r) => r.sourceName).toSet();
    final ownerKey = sourceKey(workout);

    // ── Pick the authoritative source ──────────────────────────────────
    // Health Connect's `totalDistance` SUMS every source's DistanceRecords.
    // For walk/run the phone's own Health Connect aggregator
    // (com.android.healthconnect.phone.*) writes a parallel duplicate of the
    // watch's distance, so that sum — and thus totalDistance — is ~2x the real
    // distance. The authoritative value is the single device that owns the
    // workout, never the cross-source sum. A prior "cleanup" (commit ceb118c)
    // regressed this to `fallback`/totalDistance, which is exactly what
    // doubled Garmin / Samsung Health / HealthSync walk & run imports.
    final result = chooseSourceAwareDistance(
      distanceBySource: distanceBySource,
      ownerKey: ownerKey,
      fallback: fallback,
    );

    developer.log(
      'sourceAwareDist: ${result.decision} '
      'chosen=${result.distance?.round()}m owner=$ownerKey '
      'fallback=${fallback?.round()}m '
      'sources=${distanceBySource.map((k, v) => MapEntry(k, v.round()))}',
      name: 'HealthImport',
    );

    return (
      distance: result.distance,
      diag: <String, dynamic>{
        'decision': result.decision,
        'workout_source': workout.sourceId,
        'workout_sourceName': workout.sourceName,
        'source_key': ownerKey,
        'all_sources': distanceBySource.map((k, v) => MapEntry(k, v.round())),
        'distinct_sourceNames': sourceNames.toList(),
        'chosen_m': result.distance?.round(),
        'fallback_m': fallback,
      },
    );
  }

  /// Pick the authoritative distance from per-source DISTANCE_DELTA sums.
  ///
  /// Rules (restored after the `ceb118c` "cleanup" regression that summed all
  /// sources via `totalDistance` and doubled walk/run imports):
  ///   • Prefer the workout owner's own source — one device's own total is
  ///     authoritative and never double-counts.
  ///   • If the owner wrote no in-window records, use the largest single
  ///     source (the device that tracked the full session).
  ///   • NEVER sum across sources: the phone's Health Connect aggregator
  ///     (`com.android.healthconnect.phone.*`) duplicates the watch's distance,
  ///     so summing (i.e. `totalDistance`) ~doubles walk/run distance.
  ///
  /// `distanceBySource` maps a source key to its summed in-window distance (m).
  /// `ownerKey` is the workout's own source key. `fallback` is the workout's
  /// `totalDistance`, used only when there are no per-source records at all.
  @visibleForTesting
  static ({double? distance, String decision}) chooseSourceAwareDistance({
    required Map<String, double> distanceBySource,
    required String ownerKey,
    required double? fallback,
  }) {
    if (distanceBySource.isEmpty) {
      return (distance: fallback, decision: 'fallback_no_sources');
    }
    final ownerDistance = distanceBySource[ownerKey];
    if (ownerDistance != null) {
      return (distance: ownerDistance, decision: 'source_match');
    }
    final largest = distanceBySource.values.reduce((a, b) => a > b ? a : b);
    return (distance: largest, decision: 'largest_source');
  }

  String _mapActivityType(HealthWorkoutActivityType type) {
    return switch (type) {
      HealthWorkoutActivityType.RUNNING ||
      HealthWorkoutActivityType.RUNNING_TREADMILL => 'run',
      HealthWorkoutActivityType.WALKING => 'walk',
      HealthWorkoutActivityType.BIKING => 'cycle',
      HealthWorkoutActivityType.FUNCTIONAL_STRENGTH_TRAINING ||
      HealthWorkoutActivityType.TRADITIONAL_STRENGTH_TRAINING ||
      HealthWorkoutActivityType.STRENGTH_TRAINING => 'strength',
      _ => 'other',
    };
  }

  /// Returns the `external_id`s in [window] to SKIP because they duplicate an
  /// already-imported activity (same type + >80% time-window overlap) or an
  /// earlier workout in this same batch. Keeps the first; UUID-agnostic.
  ///
  /// Needed because HealthKit holds multiple workouts for one real activity
  /// (Apple Watch + third-party apps like Strava, which re-export the same
  /// workout under NEW UUIDs over time), so `external_id` dedup is insufficient.
  /// Offline-safe: if the Supabase lookup fails, only within-batch duplicates
  /// are collapsed (never drops a genuinely new activity).
  Future<Set<String>> duplicateSkipIdsForWindow({
    required String userId,
    required String source,
    required WorkoutWindow window,
    required DateTime from,
    required DateTime to,
  }) async {
    final existing = <ActivityFingerprint>[];
    try {
      final rows = await _client
          .from('activities')
          .select('external_id, type, started_at, ended_at')
          .eq('user_id', userId)
          .eq('source', source)
          .gte('started_at', from.toUtc().toIso8601String())
          .lte('started_at', to.toUtc().toIso8601String());
      for (final row in rows as List<dynamic>) {
        final extId = row['external_id'] as String?;
        if (extId == null) continue;
        final startedAt = DateTime.tryParse(row['started_at'] as String? ?? '');
        if (startedAt == null) continue;
        final endedRaw = row['ended_at'] as String?;
        existing.add(
          ActivityFingerprint(
            externalId: extId,
            activityType: row['type'] as String? ?? 'other',
            startedAt: startedAt,
            endedAt:
                (endedRaw == null ? null : DateTime.tryParse(endedRaw)) ??
                startedAt,
          ),
        );
      }
    } catch (_) {
      // Network failure — within-batch dedup below still applies.
    }

    final incoming = <ActivityFingerprint>[
      for (final workout in window.workouts)
        if (workout.value is WorkoutHealthValue)
          ActivityFingerprint(
            externalId: workout.uuid,
            activityType: _mapActivityType(
              (workout.value as WorkoutHealthValue).workoutActivityType,
            ),
            startedAt: workout.dateFrom,
            endedAt: workout.dateTo,
          ),
    ];
    return duplicateExternalIdsToSkip(incoming: incoming, existing: existing);
  }

  /// Pure skip-decision over [incoming] (this run's workouts, in read order)
  /// against [existing] (already-imported activities). Reuses [DuplicateDetector]
  /// (same type + >80% time overlap). Keeps the already-imported / first-seen
  /// activity and skips later duplicates.
  @visibleForTesting
  static Set<String> duplicateExternalIdsToSkip({
    required List<ActivityFingerprint> incoming,
    required List<ActivityFingerprint> existing,
  }) {
    final skip = <String>{};
    final accepted = <ActivityFingerprint>[...existing];
    for (final candidate in incoming) {
      final match = DuplicateDetector.findCandidate(
        activity: candidate,
        candidates: accepted,
      );
      if (match != null) {
        skip.add(candidate.externalId);
      } else {
        accepted.add(candidate);
      }
    }
    return skip;
  }
}
