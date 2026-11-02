import 'dart:io';

import 'package:activefriends/data/local/app_database.dart';
import 'package:activefriends/features/import/data/auto_sync_preferences.dart';
import 'package:activefriends/features/import/data/feature_flag_service.dart';
import 'package:activefriends/features/import/data/health_sync_core.dart';
import 'package:activefriends/features/import/data/local_import_repository.dart';
import 'package:activefriends/features/import/data/sync_notifier.dart';
import 'package:activefriends/features/import/data/sync_state_repository.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:health/health.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Platform-agnostic shape of an Android Health Connect Changes-API delta, so
/// tests need not construct a `HealthChangesResponse`.
class ChangesDelta {
  const ChangesDelta({
    required this.upsertedIds,
    required this.tokenExpired,
    this.nextToken,
  });
  final Set<String> upsertedIds;
  final bool tokenExpired;
  final String? nextToken;
}

typedef ChangesTokenFetcher = Future<String?> Function(List<HealthDataType> types);
typedef ChangesFetcher = Future<ChangesDelta?> Function(String token);

/// Best-effort sink for a single background-run diagnostics row (SPEC §8.3).
/// Given the user id and a payload map, persists it (production: inserts into
/// the `import_diagnostics` Supabase table). Must never throw into the run.
typedef BackgroundDiagnosticsRecorder = Future<void> Function(
    String userId, Map<String, dynamic> payload);

class BackgroundSyncResult {
  const BackgroundSyncResult({
    this.imported = 0,
    this.skipped = 0,
    this.queued = 0,
    this.skippedReason,
  });
  const BackgroundSyncResult.skippedReason(String reason)
      : imported = 0,
        skipped = 0,
        queued = 0,
        skippedReason = reason;

  final int imported;
  final int skipped;
  final int queued;
  final String? skippedReason;
}

class BackgroundSyncService {
  /// Collaborators are injected and NULLABLE. They are accessed ONLY after the
  /// flag gate passes, so a flag-off unit test can construct the service with
  /// just [flags] and never touch Supabase/Drift/Health (none are initialised
  /// in a plain `flutter test`).
  BackgroundSyncService({
    required FeatureFlagService flags,
    HealthSyncCore? core,
    LocalImportRepository? localRepository,
    SyncStateRepository? syncStateRepository,
    ChangesTokenFetcher? changesTokenFetcher,
    ChangesFetcher? changesFetcher,
    SyncNotifier? notifier,
    AutoSyncPreferences? autoSyncPrefs,
    BackgroundDiagnosticsRecorder? diagnosticsRecorder,
  })  : _flags = flags, // ignore: prefer_initializing_formals
        _core = core, // ignore: prefer_initializing_formals
        _localRepository = localRepository, // ignore: prefer_initializing_formals
        _syncStateRepository = syncStateRepository, // ignore: prefer_initializing_formals
        _changesTokenFetcher = changesTokenFetcher, // ignore: prefer_initializing_formals
        _changesFetcher = changesFetcher, // ignore: prefer_initializing_formals
        _notifier = notifier, // ignore: prefer_initializing_formals
        _autoSyncPrefs = autoSyncPrefs, // ignore: prefer_initializing_formals
        _diagnosticsRecorder = diagnosticsRecorder; // ignore: prefer_initializing_formals

  /// Factory for the WorkManager background isolate. Opens its OWN Drift
  /// connection — never `AppDatabase.shared`, which is uninitialised in a fresh
  /// isolate and would crash.
  factory BackgroundSyncService.forBackgroundIsolate() {
    final db = AppDatabase();
    final local = LocalImportRepository(db);
    final health = Health();
    return BackgroundSyncService(
      flags: FeatureFlagService(),
      core: HealthSyncCore(
        health: health,
        client: Supabase.instance.client,
        localRepository: local,
      ),
      localRepository: local,
      syncStateRepository: SyncStateRepository(db),
      changesTokenFetcher: (types) => health.getChangesToken(types: types),
      changesFetcher: (token) async {
        final resp = await health.getChanges(changesToken: token);
        if (resp == null) return null;
        return ChangesDelta(
          upsertedIds:
              resp.upsertedDataPoints.map((p) => p.uuid).toSet(),
          tokenExpired: resp.changesTokenExpired,
          nextToken:
              resp.nextChangesToken.isEmpty ? null : resp.nextChangesToken,
        );
      },
      notifier: SyncNotifier(plugin: FlutterLocalNotificationsPlugin()),
      autoSyncPrefs: AutoSyncPreferences(),
      diagnosticsRecorder: _insertDiagnostics,
    );
  }

  /// Factory for the iOS HealthKit channel handler, which fires in the MAIN
  /// isolate. Uses [AppDatabase.shared] so there is exactly ONE Drift
  /// connection to the on-disk database — opening a second instance would
  /// cause stale stream invalidation and potential write-lock contention with
  /// GPS tracking.
  factory BackgroundSyncService.forMainIsolate() {
    final db = AppDatabase.shared;
    final local = LocalImportRepository(db);
    final health = Health();
    return BackgroundSyncService(
      flags: FeatureFlagService(),
      core: HealthSyncCore(
        health: health,
        client: Supabase.instance.client,
        localRepository: local,
      ),
      localRepository: local,
      syncStateRepository: SyncStateRepository(db),
      changesTokenFetcher: (types) => health.getChangesToken(types: types),
      changesFetcher: (token) async {
        final resp = await health.getChanges(changesToken: token);
        if (resp == null) return null;
        return ChangesDelta(
          upsertedIds:
              resp.upsertedDataPoints.map((p) => p.uuid).toSet(),
          tokenExpired: resp.changesTokenExpired,
          nextToken:
              resp.nextChangesToken.isEmpty ? null : resp.nextChangesToken,
        );
      },
      notifier: SyncNotifier(plugin: FlutterLocalNotificationsPlugin()),
      autoSyncPrefs: AutoSyncPreferences(),
      diagnosticsRecorder: _insertDiagnostics,
    );
  }

  /// Production diagnostics sink: insert one row into `import_diagnostics`,
  /// matching the manual path's shape (`health_import_service.dart`). Shared by
  /// both factories; wrapped best-effort by [_recordDiag] at the call site.
  static Future<void> _insertDiagnostics(
      String userId, Map<String, dynamic> payload) async {
    await Supabase.instance.client.from('import_diagnostics').insert({
      'user_id': userId,
      'platform': Platform.isIOS ? 'ios' : 'android',
      'payload': payload,
    });
  }

  /// Test seam: only [flags] is needed to exercise the flag gate.
  factory BackgroundSyncService.forTest({required FeatureFlagService flags}) =>
      BackgroundSyncService(flags: flags);

  final FeatureFlagService _flags;
  final HealthSyncCore? _core;
  final LocalImportRepository? _localRepository;
  final SyncStateRepository? _syncStateRepository;
  final ChangesTokenFetcher? _changesTokenFetcher;
  final ChangesFetcher? _changesFetcher;
  final SyncNotifier? _notifier;
  final AutoSyncPreferences? _autoSyncPrefs;
  final BackgroundDiagnosticsRecorder? _diagnosticsRecorder;

  /// Best-effort diagnostics write. Swallows every error: a diagnostics failure
  /// must NEVER throw into a background run or flip its success/failure outcome.
  Future<void> _recordDiag(String userId, Map<String, dynamic> payload) async {
    final recorder = _diagnosticsRecorder;
    if (recorder == null) return;
    try {
      await recorder(userId, payload);
    } catch (_) {
      // best-effort: diagnostics never affect the run
    }
  }

  Future<BackgroundSyncResult> syncIncremental({
    required String userId,
    String? trigger,
  }) async {
    // Background-run diagnostics (SPEC §8.3). One row is persisted per wake at
    // whichever exit we reach, so a device test can tell WHY a run imported
    // nothing. Best-effort only (see [_recordDiag]) — never affects the run.
    final diag = <String, dynamic>{
      'type': 'background_sync',
      'trigger': trigger,
      'session_present': true, // syncIncremental is only called with a session
      'platform': Platform.isIOS ? 'ios' : 'android',
    };

    // 0. Remote kill switch. Fail-safe: disabled unless explicitly enabled.
    final flagEnabled = await _flags.autoSyncEnabled();
    diag['flag_enabled'] = flagEnabled;
    if (!flagEnabled) {
      diag['skipped_reason'] = 'flag_off';
      await _recordDiag(userId, diag);
      return const BackgroundSyncResult.skippedReason('flag_off');
    }

    // Backoff throttle (§8.2). Read-only peek at the run-status row.
    final backoffRow = await _syncStateRepository
        ?.rowFor(userId, Platform.isIOS ? 'healthkit' : 'health_connect');
    if (backoffRow != null &&
        shouldSkipForBackoff(
          consecutiveFailures: backoffRow.consecutiveFailures,
          lastAttemptAt: backoffRow.lastAttemptAt,
          now: DateTime.now(),
        )) {
      diag['skipped_reason'] = 'backoff';
      await _recordDiag(userId, diag);
      return const BackgroundSyncResult.skippedReason('backoff');
    }

    // Flag passed → collaborators are required from here on.
    final core = _core!;
    final localRepository = _localRepository!;
    final syncStateRepository = _syncStateRepository!;

    final source = Platform.isIOS ? 'healthkit' : 'health_connect';

    // Authorize before any read (readWorkouts assumes it already ran).
    final authorized = await core.ensureAuthorized();
    diag['authorized'] = authorized;
    if (!authorized) {
      diag['skipped_reason'] = 'unauthorized';
      await _recordDiag(userId, diag);
      return const BackgroundSyncResult.skippedReason('unauthorized');
    }

    try {
      // 1. Drain pending offline syncs.
      await core.syncPendingActivities();

      // 2. Full 30-day rescan window. Android narrows to changed workouts via
      //    the Changes API; iOS always rescans (idempotent dedup).
      final now = DateTime.now();
      final from = now.subtract(const Duration(days: 30));

      final window = await core.readWorkouts(from: from, to: now);
      diag['workouts_read'] = window.workouts.length;
      final existingIds =
          await core.existingExternalIds(userId, source, from, now);
      final changedIds = await _resolveChangedIds(userId, source); // null ⇒ all
      final duplicateSkipIds = await core.duplicateSkipIdsForWindow(
        userId: userId,
        source: source,
        window: window,
        from: from,
        to: now,
      );

      var imported = 0, skipped = 0, queued = 0;
      for (final workout in window.workouts) {
        // Pre-filter non-workout values like the manual path, so they never
        // inflate the skipped count.
        if (workout.value is! WorkoutHealthValue) continue;
        if (changedIds != null && !changedIds.contains(workout.uuid)) continue;
        if (duplicateSkipIds.contains(workout.uuid)) {
          skipped++;
          continue;
        }
        switch (await core.syncSingleActivity(
          userId: userId,
          source: source,
          workout: workout,
          window: window,
          existingExternalIds: existingIds,
        )) {
          case SyncOutcome.imported:
            imported++;
          case SyncOutcome.skippedOverlap:
            skipped++;
          case SyncOutcome.queued:
            queued++;
          case SyncOutcome.alreadySynced:
            break;
        }
      }

      await localRepository.saveWatermark(
          userId: userId, source: source, importedThrough: now);
      await syncStateRepository.recordSyncAttempt(
          userId: userId, source: source, success: true);

      diag['imported'] = imported;
      diag['skipped'] = skipped;
      diag['queued'] = queued;
      await _recordDiag(userId, diag);

      // Best-effort side effects: a notification plugin crash or SharedPreferences
      // write failure must NEVER flip a successful import to a failure. These are
      // isolated here so the outer catch (which records a failed attempt and
      // rethrows for WorkManager retry) cannot be reached from this block.
      try {
        await _autoSyncPrefs?.setLastSuccess(now);
        if (imported > 0) {
          await _notifier?.showSynced(imported);
        }
      } catch (_) {
        // best-effort: last-sync + notification must never fail a successful run
      }

      return BackgroundSyncResult(
          imported: imported, skipped: skipped, queued: queued);
    } catch (e) {
      // Record the failure so backoff (Task 6) can throttle, then rethrow so
      // WorkManager retries with its own backoff.
      await syncStateRepository.recordSyncAttempt(
          userId: userId, source: source, success: false);
      diag['error'] = e.toString();
      await _recordDiag(userId, diag);
      rethrow;
    }
  }

  /// Exponential backoff after repeated failures (§8.2). 0–2 failures never
  /// skip; 3–9 skip for 2^(n-3) * 15 minutes since the last attempt; 10+ always
  /// skip until a manual import resets `consecutiveFailures` to 0.
  @visibleForTesting
  static bool shouldSkipForBackoff({
    required int consecutiveFailures,
    required DateTime? lastAttemptAt,
    required DateTime now,
  }) {
    if (consecutiveFailures < 3) return false;
    if (consecutiveFailures >= 10) return true;
    if (lastAttemptAt == null) return false;
    final skipCycles = 1 << (consecutiveFailures - 3);
    final backoffMinutes = skipCycles * 15;
    return now.difference(lastAttemptAt).inMinutes < backoffMinutes;
  }

  /// Platform delta source. Returning null means "process every workout in the
  /// window", which is correct (dedup is idempotent) if less efficient.
  Future<Set<String>?> _resolveChangedIds(String userId, String source) async {
    if (Platform.isIOS) return null; // observer → full 30-day rescan (idempotent)
    final tokenFetcher = _changesTokenFetcher;
    final changesFetcher = _changesFetcher;
    if (tokenFetcher == null || changesFetcher == null) return null;
    return resolveAndroidChangedIds(
      repo: _syncStateRepository!,
      userId: userId,
      source: source,
      tokenFetcher: tokenFetcher,
      changesFetcher: changesFetcher,
    );
  }

  /// Resolve the set of changed workout uuids for Android via the Health
  /// Connect Changes API. Returns `null` to mean "rescan every workout in the
  /// 30-day window" (the safe fallback — dedup is idempotent). A non-null set
  /// narrows the per-workout loop to only changed workouts.
  ///
  /// - No stored token  → establish a baseline token for next run, rescan now.
  /// - Valid token      → return upserted ids, persist nextToken.
  /// - Expired/absent   → invalidate, re-establish baseline, rescan now.
  @visibleForTesting
  static Future<Set<String>?> resolveAndroidChangedIds({
    required SyncStateRepository repo,
    required String userId,
    required String source,
    required ChangesTokenFetcher tokenFetcher,
    required ChangesFetcher changesFetcher,
  }) async {
    final token = await repo.getChangesToken(userId: userId, source: source);
    if (token == null) {
      final fresh = await tokenFetcher(const [HealthDataType.WORKOUT]);
      if (fresh != null) {
        await repo.saveChangesToken(userId: userId, source: source, token: fresh);
      }
      return null;
    }
    final delta = await changesFetcher(token);
    if (delta == null || delta.tokenExpired) {
      await repo.invalidateToken(userId: userId, source: source);
      final fresh = await tokenFetcher(const [HealthDataType.WORKOUT]);
      if (fresh != null) {
        await repo.saveChangesToken(userId: userId, source: source, token: fresh);
      }
      return null;
    }
    final next = delta.nextToken;
    if (next != null && next.isNotEmpty) {
      await repo.saveChangesToken(userId: userId, source: source, token: next);
    }
    return delta.upsertedIds;
  }
}
