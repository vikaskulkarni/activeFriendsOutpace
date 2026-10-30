import 'dart:developer' as developer;
import 'dart:io';

import 'package:activefriends/data/local/app_database.dart';
import 'package:activefriends/features/import/data/health_sync_core.dart';
import 'package:activefriends/features/import/data/local_import_repository.dart';
import 'package:health/health.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class HealthImportResult {
  const HealthImportResult({
    required this.importedCount,
    required this.queuedCount,
    required this.historyAuthorized,
    required this.diagnostics,
    required this.skippedDuplicates,
    required this.alreadySyncedCount,
  });

  final int importedCount;
  final int queuedCount;
  final bool historyAuthorized;

  /// Count of imported workouts skipped because they overlap an existing
  /// Outpace activity (already logged — e.g. a ride also tracked via GPS).
  final int skippedDuplicates;

  /// Count of activities that were already synced from a previous import
  /// (re-scanned but not new).
  final int alreadySyncedCount;

  /// Human-readable breakdown of the Health Connect / HealthKit read, shown
  /// only when nothing came through, so an empty result is explainable
  /// on-device (no ADB on the Pixel). Empty string otherwise.
  final String diagnostics;
}

class HealthImportService {
  HealthImportService({
    Health? health,
    SupabaseClient? client,
    LocalImportRepository? localRepository,
  }) : _health = health ?? Health(),
       _client = client ?? Supabase.instance.client,
       _localRepository =
           localRepository ?? LocalImportRepository(AppDatabase.shared);

  final Health _health;
  final SupabaseClient _client;
  final LocalImportRepository _localRepository;

  // Shared read/transform/upsert logic. The manual import and the future
  // background auto-sync path call the SAME core functions.
  late final HealthSyncCore _core = HealthSyncCore(
    health: _health,
    client: _client,
    localRepository: _localRepository,
  );

  Future<HealthImportResult> importRecentWorkouts() async {
    await _health.configure();

    // Diagnostic (Android, no-ADB): capture the exact Health Connect SDK status
    // up front. The corporate Pixel 9 can't be inspected via logcat, so we fold
    // this status into any failure below — whatever UI surfaces
    // HealthImportException becomes our on-device readout of what HC thinks.
    HealthConnectSdkStatus? hcStatus;
    if (Platform.isAndroid) {
      hcStatus = await _health.getHealthConnectSdkStatus();
    }

    // Explicitly request READ-only access. The health package defaults to
    // READ_WRITE when permissions is omitted, but the Android manifest only
    // declares READ_* permissions — Health Connect denies the request.
    final authorized = await _health.requestAuthorization(
      HealthSyncCore.authTypes,
      permissions:
          HealthSyncCore.authTypes.map((_) => HealthDataAccess.READ).toList(),
    );
    if (!authorized) {
      throw HealthImportException(
        'Health permission was not granted.${_hcStatusSuffix(hcStatus)}',
      );
    }

    // Health data history authorization is an Android Health Connect concept.
    // On iOS/HealthKit all history is available once read access is granted.
    // The health package no-ops on iOS, but guard explicitly to be safe.
    var historyAuthorized = true;
    if (Platform.isAndroid) {
      historyAuthorized = await _health.isHealthDataHistoryAuthorized();
      if (!historyAuthorized) {
        historyAuthorized = await _health.requestHealthDataHistoryAuthorization();
      }
    }

    final now = DateTime.now();
    final start = now.subtract(const Duration(days: 30));
    final user = _client.auth.currentUser;
    if (user == null) {
      throw const HealthImportException('Sign in before importing activities.');
    }

    final source = Platform.isIOS ? 'healthkit' : 'health_connect';
    await _core.syncPendingActivities();
    // Always rescan the full lookback window. A forward-only watermark
    // permanently skips activities that a watch syncs into Health Connect
    // LATE with their original (earlier) timestamps — the #1 cause of
    // "0 imported" when the sessions are clearly present in Health Connect.
    // The upsert on (user_id, source, external_id) dedups the rescan, so
    // re-reading already-imported sessions is harmless.
    final importStart = start;
    final window = await _core.readWorkouts(from: importStart, to: now);
    final existingIds =
        await _core.existingExternalIds(user.id, source, importStart, now);
    // Same-activity dedup: skip workouts that duplicate an already-imported
    // activity (Apple Watch + Strava, which re-exports under new UUIDs). Keeps
    // the first. external_id can't catch this because the UUIDs differ.
    final duplicateSkipIds = await _core.duplicateSkipIdsForWindow(
      userId: user.id,
      source: source,
      window: window,
      from: importStart,
      to: now,
    );

    var importedCount = 0;
    var queuedCount = 0;
    var skippedCount = 0;
    var alreadySyncedCount = 0;
    var nonWorkoutValues = 0;
    final distanceDiags = <Map<String, dynamic>>[];
    for (final workout in window.workouts) {
      // Pre-filter non-workout values here so they are reflected in the
      // diagnostics below (the core guards against them too, but does not
      // surface a count). WORKOUT points practically always carry a
      // WorkoutHealthValue, so this is effectively always 0.
      if (workout.value is! WorkoutHealthValue) {
        nonWorkoutValues++;
        continue;
      }
      if (duplicateSkipIds.contains(workout.uuid)) {
        skippedCount++;
        continue;
      }
      final outcome = await _core.syncSingleActivity(
        userId: user.id,
        source: source,
        workout: workout,
        window: window,
        existingExternalIds: existingIds,
        onDistanceDiag: distanceDiags.add,
      );
      switch (outcome) {
        case SyncOutcome.imported:
          importedCount++;
        case SyncOutcome.queued:
          // A new activity whose upsert was queued offline. The original
          // manual path counted such workouts as BOTH imported and queued,
          // so preserve that exact behaviour here.
          queuedCount++;
          importedCount++;
        case SyncOutcome.skippedOverlap:
          skippedCount++;
        case SyncOutcome.alreadySynced:
          alreadySyncedCount++;
      }
    }

    await _localRepository.saveWatermark(
      userId: user.id,
      source: source,
      importedThrough: now,
    );

    // ── Always-on distance diagnostics ──────────────────────────────────
    // Persisted on every import so we can diagnose source-aware distance
    // decisions even when workouts import successfully (doubled-distance
    // bugs only show when data DOES come through).
    if (distanceDiags.isNotEmpty) {
      developer.log(
        'Distance diagnostics (${distanceDiags.length} workouts): '
        'total DISTANCE_DELTA records=${window.distanceDeltas.length}',
        name: 'HealthImport',
      );
      try {
        await _client.from('import_diagnostics').insert({
          'user_id': user.id,
          'platform': Platform.isIOS ? 'ios' : 'android',
          'payload': {
            'type': 'distance_debug',
            'raw_distances': window.distanceDeltas.length,
            'raw_workouts': window.workouts.length,
            'per_workout': distanceDiags,
          },
        });
      } catch (_) {
        // Best-effort: diagnostics must never break the import.
      }
    }

    // ── Diagnostics (only when NOTHING came through) ────────────────────
    // Gather + persist the full read breakdown only in the problem case:
    // no imports AND no duplicates skipped. Successful imports and
    // "all duplicates" outcomes stay clean — no probe, no DB row, no
    // on-screen dump. (No ADB on the corporate Pixel, so when it IS empty we
    // surface this on-screen AND persist to import_diagnostics.)
    var diagnostics = '';
    if (importedCount == 0 && skippedCount == 0 && alreadySyncedCount == 0) {
      final perms = <String, String>{};
      for (final t in HealthSyncCore.authTypes) {
        try {
          final has = await _health.hasPermissions(
            [t],
            permissions: [HealthDataAccess.READ],
          );
          perms[t.name] = '${has ?? 'null'}';
        } catch (e) {
          perms[t.name] = 'err:$e';
        }
      }

      var probeWorkouts365 = -1; // -1 = probe not run
      String? probeError;
      try {
        final probe = await _health.getHealthDataFromTypes(
          startTime: now.subtract(const Duration(days: 365)),
          endTime: now,
          types: [HealthDataType.WORKOUT],
        );
        probeWorkouts365 =
            probe.where((p) => p.type == HealthDataType.WORKOUT).length;
      } catch (e) {
        probeError = e.toString();
      }

      final sample = window.workouts.isEmpty
          ? 'none'
          : '${window.workouts.first.value.runtimeType} '
                'uuid=${window.workouts.first.uuid}';

      final diag = <String, dynamic>{
        'platform': Platform.isIOS ? 'ios' : 'android',
        'hc_status': hcStatus?.name,
        'authorized': authorized,
        'history_authorized': historyAuthorized,
        'permissions': perms,
        'window_start': importStart.toIso8601String(),
        'window_end': now.toIso8601String(),
        'raw_total': window.workouts.length +
            window.heartRates.length +
            window.distanceDeltas.length,
        'raw_workouts': window.workouts.length,
        'raw_distances': window.distanceDeltas.length,
        'raw_heart_rates': window.heartRates.length,
        'non_workout_values': nonWorkoutValues,
        'skipped_duplicates': skippedCount,
        'imported': importedCount,
        'queued': queuedCount,
        'probe_workouts_365d': probeWorkouts365,
        'probe_error': probeError,
        'first_workout_sample': sample,
      };
      await _recordDiagnostics(user.id, diag);
      diagnostics = _formatDiagnostics(diag);
    }

    return HealthImportResult(
      importedCount: importedCount,
      queuedCount: queuedCount,
      skippedDuplicates: skippedCount,
      alreadySyncedCount: alreadySyncedCount,
      historyAuthorized: historyAuthorized,
      diagnostics: diagnostics,
    );
  }

  /// Human-readable Health Connect status, appended to error messages so the
  /// device's actual state is visible on-screen (no ADB on the corporate
  /// Pixel 9). Uses only the documented enum constants so it compiles
  /// regardless of the enum's internal representation.
  String _hcStatusSuffix(HealthConnectSdkStatus? status) {
    if (!Platform.isAndroid) return '';
    final label = switch (status) {
      HealthConnectSdkStatus.sdkAvailable =>
        'sdkAvailable (Health Connect reachable — issue is elsewhere)',
      HealthConnectSdkStatus.sdkUnavailableProviderUpdateRequired =>
        'sdkUnavailableProviderUpdateRequired (device Health Connect is older '
            'than the app expects — update Health Connect on the device)',
      HealthConnectSdkStatus.sdkUnavailable =>
        'sdkUnavailable (Health Connect not installed/enabled)',
      _ => 'unknown',
    };
    return ' [HC status: $label]';
  }

  Future<void> _recordDiagnostics(String userId, Map<String, dynamic> diag) async {
    try {
      await _client.from('import_diagnostics').insert({
        'user_id': userId,
        'platform': diag['platform'],
        'payload': diag,
      });
    } catch (_) {
      // Best-effort: diagnostics must never break the import itself.
    }
  }

  String _formatDiagnostics(Map<String, dynamic> d) {
    final probeErr = d['probe_error'];
    return 'Diagnostics\n'
        'HC status: ${d['hc_status']}\n'
        'authorized: ${d['authorized']} | history: ${d['history_authorized']}\n'
        'perms: ${d['permissions']}\n'
        'window: ${d['window_start']} → ${d['window_end']}\n'
        'read: total=${d['raw_total']} workouts=${d['raw_workouts']} '
        'hr=${d['raw_heart_rates']} nonWorkoutVal=${d['non_workout_values']}\n'
        'skippedDup=${d['skipped_duplicates']} imported=${d['imported']} '
        'queued=${d['queued']}\n'
        'probe(365d workouts)=${d['probe_workouts_365d']}'
        '${probeErr != null ? ' probeErr=$probeErr' : ''}\n'
        'sample: ${d['first_workout_sample']}';
  }
}

class HealthImportException implements Exception {
  const HealthImportException(this.message);

  final String message;
}
