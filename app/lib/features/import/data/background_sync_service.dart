import 'dart:io';

import 'package:activefriends/data/local/app_database.dart';
import 'package:activefriends/features/import/data/feature_flag_service.dart';
import 'package:activefriends/features/import/data/health_sync_core.dart';
import 'package:activefriends/features/import/data/local_import_repository.dart';
import 'package:activefriends/features/import/data/sync_state_repository.dart';
import 'package:health/health.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
  })  : _flags = flags,
        _core = core,
        _localRepository = localRepository,
        _syncStateRepository = syncStateRepository;

  /// Factory for the WorkManager background isolate. Opens its OWN Drift
  /// connection — never `AppDatabase.shared`, which is uninitialised in a fresh
  /// isolate and would crash.
  factory BackgroundSyncService.forBackgroundIsolate() {
    final db = AppDatabase();
    final local = LocalImportRepository(db);
    return BackgroundSyncService(
      flags: FeatureFlagService(),
      core: HealthSyncCore(
        health: Health(),
        client: Supabase.instance.client,
        localRepository: local,
      ),
      localRepository: local,
      syncStateRepository: SyncStateRepository(db),
    );
  }

  /// Test seam: only [flags] is needed to exercise the flag gate.
  factory BackgroundSyncService.forTest({required FeatureFlagService flags}) =>
      BackgroundSyncService(flags: flags);

  final FeatureFlagService _flags;
  final HealthSyncCore? _core;
  final LocalImportRepository? _localRepository;
  final SyncStateRepository? _syncStateRepository;

  Future<BackgroundSyncResult> syncIncremental({required String userId}) async {
    // 0. Remote kill switch. Fail-safe: disabled unless explicitly enabled.
    if (!await _flags.autoSyncEnabled()) {
      return const BackgroundSyncResult.skippedReason('flag_off');
    }

    // Flag passed → collaborators are required from here on.
    final core = _core!;
    final localRepository = _localRepository!;
    final syncStateRepository = _syncStateRepository!;

    // ── Plans 2/3 integration notes (NOT implemented here) ──────────────────
    // When Plans 2 (iOS HKAnchoredObjectQuery) and 3 (Android health.getChanges)
    // wire the real background sync run, they MUST:
    //   (a) Pre-filter non-WorkoutHealthValue points before calling
    //       `core.syncSingleActivity`, the same way the manual path does.
    //       Without pre-filtering, non-workout values reach syncSingleActivity
    //       and are returned as SyncOutcome.skippedOverlap, causing the skipped
    //       count to be inflated and the imported count to be understated.
    //   (b) Call `_health.configure()` + request authorization BEFORE calling
    //       `core.readWorkouts`. The manual path does this; `readWorkouts` assumes
    //       authorization has already been granted and will silently return an
    //       empty list (or throw) if it has not.
    // ────────────────────────────────────────────────────────────────────────

    final source = Platform.isIOS ? 'healthkit' : 'health_connect';

    // 1. Drain pending offline syncs.
    await core.syncPendingActivities();

    // 2. Full 30-day rescan window (delta narrowing added in Plans 2/3).
    final now = DateTime.now();
    final from = now.subtract(const Duration(days: 30));

    // 3. Read window + upsert each via the SAME core functions as manual import.
    final window = await core.readWorkouts(from: from, to: now);
    final existingIds =
        await core.existingExternalIds(userId, source, from, now);
    final changedIds = await _resolveChangedIds(userId, source); // null ⇒ all

    var imported = 0, skipped = 0, queued = 0;
    for (final workout in window.workouts) {
      if (changedIds != null && !changedIds.contains(workout.uuid)) continue;
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

    // 4. Watermark (single system) + run status.
    await localRepository.saveWatermark(
        userId: userId, source: source, importedThrough: now);
    await syncStateRepository.recordSyncAttempt(
        userId: userId, source: source, success: true);

    return BackgroundSyncResult(
        imported: imported, skipped: skipped, queued: queued);
  }

  /// Platform delta source. Stubbed to "rescan all" (null) in Plan 1; Plan 2
  /// (iOS HKAnchoredObjectQuery) and Plan 3 (Android health.getChanges) fill
  /// this in. Returning null means "process every workout in the window",
  /// which is correct (dedup is idempotent) if less efficient.
  Future<Set<String>?> _resolveChangedIds(String userId, String source) async {
    return null;
  }
}
