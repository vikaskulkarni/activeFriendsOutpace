# Background Auto-Sync — Wiring & Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the already-built auto-sync foundation into real platform execution (Android WorkManager + `health.getChanges` delta; iOS `HKObserverQuery` background delivery), add the §6 user-facing toggle + "last synced" + notification, enforce the two-gate (remote flag && user toggle), and ship the kill-switch seeded ON — in one build on `integration/next-build`.

**Architecture:** The dormant foundation (`BackgroundSyncService`, `HealthSyncCore`, `SyncStateRepository`, `FeatureFlagService`, `SyncState` table v6, `app_config` migration) already exists and is correct. This build adds: (a) Android Changes-API delta resolution inside `BackgroundSyncService` behind testable fetcher seams; (b) a real-run hardening pass (authorize + non-workout pre-filter + failure recording + backoff); (c) `AutoSyncPreferences` (per-user toggle) and `AutoSyncManager` (register/teardown orchestrator honoring the two-gate); (d) a `SyncNotifier`; (e) native iOS observer + background delivery + a no-arg method channel (`app.activefriends.app/health_sync`); (f) Android WorkManager `callbackDispatcher` in `main.dart`; (g) startup register/teardown wiring; (h) the `WatchImportSection` UI; (i) flipping the `app_config` seed to ON. **iOS uses observer → full 30-day rescan** (idempotent dedup; no native anchored query). Android gets the real delta.

**Tech Stack:** Flutter (Dart 3.13), `health: ^13.3.2`, `workmanager` (new), `drift`, `supabase_flutter`, `firebase_*`, `flutter_local_notifications` (existing dep), `shared_preferences` (existing), native Swift (HealthKit) + Android manifest.

## Global Constraints

Every task's requirements implicitly include this section. Values copied verbatim from `docs/RESUME-background-auto-sync.md` and `docs/SPEC-background-auto-sync.md`.

- Work ONLY on branch `integration/next-build`. **Never `git push`.** Commit with the repo-local identity `Vikas Kulkarni <vikas.kulkarni@gmail.com>` — never the global SAP identity. Never rewrite `main`'s history.
- **Regression gates (must stay green throughout):** `app/test/health_import_source_distance_test.dart` (double-distance `ceb118c` guard — its fixtures MUST NOT change), `app/test/health_import_duplicate_skip_test.dart`, and the full `flutter test` suite EXCEPT the one pre-existing failure `test/widget_test.dart` "Shows the unconfigured backend state" (fails on `main` too — ignore it).
- `flutter analyze` must introduce **no new** issues beyond the pre-existing info/warnings + cosmetic `prefer_initializing_formals`.
- `DISTANCE_DELTA` is **Android-only** in the `health` package (iOS → `INVALID_TYPE` kills the whole read). Do NOT touch the `if (Platform.isAndroid)` guard in `HealthSyncCore.readTypes`.
- Source-aware distance keeps **window context**: do NOT modify `HealthSyncCore.chooseSourceAwareDistance` or `_computeSourceAwareDistance`.
- **One watermark system.** Data coverage lives in `ImportWatermarks` (`importedThrough`, via `LocalImportRepository.saveWatermark`). `SyncState` holds ONLY delta cursors (`changesToken`, `hkAnchor`) + run status (`lastSuccessfulAt`/`lastAttemptAt`/`consecutiveFailures`). Never use `lastSuccessfulAt` to narrow a read window.
- Do NOT break the stable manual import (`HealthImportService`). Prefer adding to `HealthSyncCore` over editing `HealthImportService`; where this plan edits the manual path, it is an additive call only.
- Commands run from the Flutter app dir: `cd app` before `flutter` commands. Test paths below are relative to `app/`.
- Kill-switch `FeatureFlagService` fail-safe-to-off logic must NOT be inverted.

---

## Task 0: Baseline verification (no code)

**Files:** none.

- [ ] **Step 1: Confirm branch & clean tree**

Run: `git -C /Users/I589392/mygit/activeFriendsOutpace branch --show-current`
Expected: `integration/next-build`

- [ ] **Step 2: Establish the green baseline**

Run: `cd app && flutter test 2>&1 | tail -20`
Expected: all pass EXCEPT `test/widget_test.dart` "Shows the unconfigured backend state". Record the exact pass/fail counts — this is the baseline every later task must preserve.

Run: `cd app && flutter analyze 2>&1 | tail -20`
Expected: only pre-existing info/warnings + `prefer_initializing_formals`. Record the count.

---

## Task 1: Add `workmanager` dependency + Android background-read permission

**Files:**
- Modify: `app/pubspec.yaml` (dependencies block, after line 42 `health: ^13.3.2`)
- Modify: `app/android/app/src/main/AndroidManifest.xml:7` (after the `READ_HEALTH_DATA_HISTORY` line)

**Interfaces:**
- Produces: the `workmanager` package import path `package:workmanager/workmanager.dart` (used by Task 9), and the `android.permission.health.READ_HEALTH_DATA_IN_BACKGROUND` grant (used by Task 5's background-read request).

- [ ] **Step 1: Add the dependency**

In `app/pubspec.yaml`, directly under `  health: ^13.3.2`, add:

```yaml
  workmanager: ^0.5.2
```

> Version note: `workmanager ^0.6.0` (named in the spec) requires an AGP/Kotlin combo that may exceed this project's Android config; `^0.5.2` is the widely-compatible floor. If `flutter pub get` resolves `^0.6.0` cleanly against the existing `android/` Gradle setup, prefer it. Pin whichever resolves — do not leave it unpinned.

- [ ] **Step 2: Resolve and verify it compiles into the lock**

Run: `cd app && flutter pub get 2>&1 | tail -5`
Expected: resolves with no version conflict. If it conflicts, lower to the highest `0.5.x`/`0.6.x` that resolves and note it in the commit message.

- [ ] **Step 3: Add the Android background-read permission**

In `app/android/app/src/main/AndroidManifest.xml`, after the line
`<uses-permission android:name="android.permission.health.READ_HEALTH_DATA_HISTORY" />`
add:

```xml
    <uses-permission android:name="android.permission.health.READ_HEALTH_DATA_IN_BACKGROUND" />
```

- [ ] **Step 4: Verify analyze is still clean**

Run: `cd app && flutter analyze 2>&1 | tail -10`
Expected: no NEW issues vs. Task 0 baseline.

- [ ] **Step 5: Commit**

```bash
cd /Users/I589392/mygit/activeFriendsOutpace
git add app/pubspec.yaml app/pubspec.lock app/android/app/src/main/AndroidManifest.xml
git commit -m "feat(sync): add workmanager dep + Android background-read permission"
```

---

## Task 2: Android Changes-API delta resolution in `BackgroundSyncService`

**Files:**
- Modify: `app/lib/features/import/data/background_sync_service.dart`
- Test: `app/test/background_sync_service_delta_test.dart` (new)

**Interfaces:**
- Consumes: `SyncStateRepository.getChangesToken/saveChangesToken/invalidateToken` (existing), `HealthSyncCore.authTypes` (existing).
- Produces:
  - `class ChangesDelta { final Set<String> upsertedIds; final bool tokenExpired; final String? nextToken; const ChangesDelta({required this.upsertedIds, required this.tokenExpired, this.nextToken}); }`
  - `typedef ChangesTokenFetcher = Future<String?> Function(List<HealthDataType> types);`
  - `typedef ChangesFetcher = Future<ChangesDelta?> Function(String token);`
  - `static Future<Set<String>?> resolveAndroidChangedIds({required SyncStateRepository repo, required String userId, required String source, required ChangesTokenFetcher tokenFetcher, required ChangesFetcher changesFetcher})` — returns `null` to mean "rescan all workouts in the window"; a non-null set means "only process workouts whose uuid is in it".
  - Two new optional constructor params on `BackgroundSyncService`: `ChangesTokenFetcher? changesTokenFetcher, ChangesFetcher? changesFetcher`.

- [ ] **Step 1: Write the failing test**

Create `app/test/background_sync_service_delta_test.dart`:

```dart
import 'package:activefriends/data/local/app_database.dart';
import 'package:activefriends/features/import/data/background_sync_service.dart';
import 'package:activefriends/features/import/data/sync_state_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late SyncStateRepository repo;
  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = SyncStateRepository(db);
  });
  tearDown(() => db.close());

  test('no stored token: establishes a baseline token and rescans all (null)',
      () async {
    var tokenCalls = 0;
    final result = await BackgroundSyncService.resolveAndroidChangedIds(
      repo: repo,
      userId: 'u',
      source: 'health_connect',
      tokenFetcher: (_) async {
        tokenCalls++;
        return 'TBASE';
      },
      changesFetcher: (_) async => fail('getChanges must not run with no token'),
    );
    expect(result, isNull); // rescan all this run
    expect(tokenCalls, 1);
    expect(await repo.getChangesToken(userId: 'u', source: 'health_connect'),
        'TBASE');
  });

  test('valid token: returns changed ids and saves the next token', () async {
    await repo.saveChangesToken(
        userId: 'u', source: 'health_connect', token: 'T1');
    final result = await BackgroundSyncService.resolveAndroidChangedIds(
      repo: repo,
      userId: 'u',
      source: 'health_connect',
      tokenFetcher: (_) async => fail('must not re-establish with a valid token'),
      changesFetcher: (token) async {
        expect(token, 'T1');
        return const ChangesDelta(
          upsertedIds: {'w1', 'w2'},
          tokenExpired: false,
          nextToken: 'T2',
        );
      },
    );
    expect(result, {'w1', 'w2'});
    expect(await repo.getChangesToken(userId: 'u', source: 'health_connect'),
        'T2');
  });

  test('expired token: invalidates, re-establishes baseline, rescans (null)',
      () async {
    await repo.saveChangesToken(
        userId: 'u', source: 'health_connect', token: 'OLD');
    final result = await BackgroundSyncService.resolveAndroidChangedIds(
      repo: repo,
      userId: 'u',
      source: 'health_connect',
      tokenFetcher: (_) async => 'TNEW',
      changesFetcher: (_) async => const ChangesDelta(
        upsertedIds: {},
        tokenExpired: true,
      ),
    );
    expect(result, isNull); // force full rescan
    expect(await repo.getChangesToken(userId: 'u', source: 'health_connect'),
        'TNEW');
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd app && flutter test test/background_sync_service_delta_test.dart -r expanded 2>&1 | tail -15`
Expected: FAIL — `resolveAndroidChangedIds` / `ChangesDelta` undefined.

- [ ] **Step 3: Implement the delta types + resolver**

In `app/lib/features/import/data/background_sync_service.dart`, add at the top (after the imports, before `class BackgroundSyncResult`):

```dart
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
```

Add the two optional fields + constructor params to `BackgroundSyncService` (extend the existing constructor initializer list and field block):

```dart
  BackgroundSyncService({
    required FeatureFlagService flags,
    HealthSyncCore? core,
    LocalImportRepository? localRepository,
    SyncStateRepository? syncStateRepository,
    ChangesTokenFetcher? changesTokenFetcher,
    ChangesFetcher? changesFetcher,
  })  : _flags = flags,
        _core = core,
        _localRepository = localRepository,
        _syncStateRepository = syncStateRepository,
        _changesTokenFetcher = changesTokenFetcher,
        _changesFetcher = changesFetcher;
```

```dart
  final ChangesTokenFetcher? _changesTokenFetcher;
  final ChangesFetcher? _changesFetcher;
```

Add the static resolver (anywhere in the class body):

```dart
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
```

Add the needed imports at the top of the file:

```dart
import 'package:flutter/foundation.dart' show visibleForTesting;
```

(`package:health/health.dart` is already imported, giving `HealthDataType`.)

Replace the existing stub body of `_resolveChangedIds` with platform dispatch:

```dart
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
```

Wire real fetchers in `forBackgroundIsolate()` — capture one `Health` instance and reuse it for both the core and the fetchers:

```dart
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
    );
  }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd app && flutter test test/background_sync_service_delta_test.dart -r expanded 2>&1 | tail -15`
Expected: all 3 PASS.

- [ ] **Step 5: Verify nothing regressed**

Run: `cd app && flutter test test/background_sync_service_test.dart test/sync_state_repository_test.dart 2>&1 | tail -8`
Expected: PASS (the foundation flag-off test still green).

- [ ] **Step 6: Commit**

```bash
cd /Users/I589392/mygit/activeFriendsOutpace
git add app/lib/features/import/data/background_sync_service.dart app/test/background_sync_service_delta_test.dart
git commit -m "feat(sync): resolve Android changed workouts via health.getChanges delta"
```

---

## Task 3: Background real-run hardening (authorize, non-workout pre-filter, failure recording)

**Files:**
- Modify: `app/lib/features/import/data/health_sync_core.dart` (add `ensureAuthorized`)
- Modify: `app/lib/features/import/data/background_sync_service.dart` (`syncIncremental`)
- Test: `app/test/background_sync_hardening_test.dart` (new)

**Interfaces:**
- Produces on `HealthSyncCore`: `Future<bool> ensureAuthorized()` — runs `configure()` + READ-only `requestAuthorization(authTypes)` + (Android) history authorization; returns false if read permission is denied.
- Consumes: `SyncStateRepository.recordSyncAttempt` (existing), `BackgroundSyncResult.skippedReason` (existing).
- Produces: `syncIncremental` now (a) authorizes before `readWorkouts`, returning `skipped('unauthorized')` if denied; (b) skips `workout.value is! WorkoutHealthValue` points (never counted); (c) records a failed attempt on any thrown exception, rethrowing so WorkManager retries.

- [ ] **Step 1: Write the failing test**

Create `app/test/background_sync_hardening_test.dart`. It uses a fake `HealthSyncCore` (Dart `implements`) and a real in-memory `SyncStateRepository`:

```dart
import 'package:activefriends/data/local/app_database.dart';
import 'package:activefriends/features/import/data/background_sync_service.dart';
import 'package:activefriends/features/import/data/feature_flag_service.dart';
import 'package:activefriends/features/import/data/health_sync_core.dart';
import 'package:activefriends/features/import/data/local_import_repository.dart';
import 'package:activefriends/features/import/data/sync_state_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeCore implements HealthSyncCore {
  _FakeCore({required this.window, this.authorized = true});
  final WorkoutWindow window;
  final bool authorized;
  int singleCalls = 0;

  @override
  Future<bool> ensureAuthorized() async => authorized;
  @override
  Future<void> syncPendingActivities() async {}
  @override
  Future<WorkoutWindow> readWorkouts(
          {required DateTime from, required DateTime to}) async =>
      window;
  @override
  Future<Set<String>> existingExternalIds(
          String userId, String source, DateTime from, DateTime to) async =>
      <String>{};
  @override
  Future<Set<String>> duplicateSkipIdsForWindow(
          {required String userId,
          required String source,
          required WorkoutWindow window,
          required DateTime from,
          required DateTime to}) async =>
      <String>{};
  @override
  Future<SyncOutcome> syncSingleActivity(
      {required String userId,
      required String source,
      required dynamic workout,
      required WorkoutWindow window,
      required Set<String> existingExternalIds,
      void Function(Map<String, dynamic>)? onDistanceDiag}) async {
    singleCalls++;
    return SyncOutcome.imported;
  }
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

FeatureFlagService _flagOn(SharedPreferences p) => FeatureFlagService(
    fetchAutoSyncRow: () async => {'value': {'enabled': true}}, prefs: p);

void main() {
  late AppDatabase db;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
  });
  tearDown(() => db.close());

  test('unauthorized → skipped(unauthorized), core never reads', () async {
    final prefs = await SharedPreferences.getInstance();
    final core = _FakeCore(
        window: const WorkoutWindow(
            workouts: [], distanceDeltas: [], heartRates: []),
        authorized: false);
    final svc = BackgroundSyncService(
      flags: _flagOn(prefs),
      core: core,
      localRepository: LocalImportRepository(db),
      syncStateRepository: SyncStateRepository(db),
    );
    final result = await svc.syncIncremental(userId: 'u');
    expect(result.skippedReason, 'unauthorized');
    expect(core.singleCalls, 0);
  });

  test('records a failed attempt and rethrows when the read throws', () async {
    final prefs = await SharedPreferences.getInstance();
    final repo = SyncStateRepository(db);
    final svc = BackgroundSyncService(
      flags: _flagOn(prefs),
      core: _ThrowingCore(),
      localRepository: LocalImportRepository(db),
      syncStateRepository: repo,
    );
    await expectLater(svc.syncIncremental(userId: 'u'), throwsA(anything));
    final row = await (db.select(db.syncStates)
          ..where((r) => r.userId.equals('u')))
        .getSingleOrNull();
    expect(row?.consecutiveFailures, 1);
  });
}

class _ThrowingCore extends _FakeCore {
  _ThrowingCore()
      : super(
            window: const WorkoutWindow(
                workouts: [], distanceDeltas: [], heartRates: []));
  @override
  Future<WorkoutWindow> readWorkouts(
          {required DateTime from, required DateTime to}) async =>
      throw StateError('read failed');
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd app && flutter test test/background_sync_hardening_test.dart -r expanded 2>&1 | tail -15`
Expected: FAIL — `ensureAuthorized` not defined / `skippedReason` not `'unauthorized'`.

- [ ] **Step 3: Add `ensureAuthorized` to `HealthSyncCore`**

In `app/lib/features/import/data/health_sync_core.dart`, add this method to the class (its `_health` field already exists). Add `import 'dart:io';` if not already present (it is not — the file imports `dart:developer` and `package:flutter/foundation.dart`; add `dart:io`):

```dart
  /// Configure HealthKit/Health Connect and request READ-only authorization for
  /// [authTypes], plus Android health-history access. Mirrors the sequence the
  /// manual path runs before reading. Returns false if read permission is
  /// denied (the caller should abort the run). Safe to call repeatedly.
  Future<bool> ensureAuthorized() async {
    await _health.configure();
    final authorized = await _health.requestAuthorization(
      authTypes,
      permissions: authTypes.map((_) => HealthDataAccess.READ).toList(),
    );
    if (!authorized) return false;
    if (Platform.isAndroid) {
      if (!await _health.isHealthDataHistoryAuthorized()) {
        await _health.requestHealthDataHistoryAuthorization();
      }
    }
    return true;
  }
```

- [ ] **Step 4: Harden `syncIncremental`**

In `app/lib/features/import/data/background_sync_service.dart`, replace the body of `syncIncremental` from the `final source = ...` line onward with the hardened version. The flag gate (step 0) stays unchanged above it.

```dart
    // Flag passed → collaborators are required from here on.
    final core = _core!;
    final localRepository = _localRepository!;
    final syncStateRepository = _syncStateRepository!;

    final source = Platform.isIOS ? 'healthkit' : 'health_connect';

    // Authorize before any read (readWorkouts assumes it already ran).
    if (!await core.ensureAuthorized()) {
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

      return BackgroundSyncResult(
          imported: imported, skipped: skipped, queued: queued);
    } catch (_) {
      // Record the failure so backoff (Task 6) can throttle, then rethrow so
      // WorkManager retries with its own backoff.
      await syncStateRepository.recordSyncAttempt(
          userId: userId, source: source, success: false);
      rethrow;
    }
```

Delete the now-obsolete "Plans 2/3 integration notes" comment block that described this exact work as not-yet-implemented.

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd app && flutter test test/background_sync_hardening_test.dart test/background_sync_service_test.dart test/background_sync_service_delta_test.dart 2>&1 | tail -12`
Expected: all PASS.

- [ ] **Step 6: Verify analyze**

Run: `cd app && flutter analyze lib/features/import/data/ 2>&1 | tail -10`
Expected: no new issues.

- [ ] **Step 7: Commit**

```bash
cd /Users/I589392/mygit/activeFriendsOutpace
git add app/lib/features/import/data/health_sync_core.dart app/lib/features/import/data/background_sync_service.dart app/test/background_sync_hardening_test.dart
git commit -m "feat(sync): authorize + pre-filter + record failures in background run"
```

---

## Task 4: Backoff gate (§8.2)

**Files:**
- Modify: `app/lib/features/import/data/background_sync_service.dart`
- Test: `app/test/background_sync_backoff_test.dart` (new)

**Interfaces:**
- Consumes: the generated Drift row type `SyncState` (from `app_database.dart`) — fields `consecutiveFailures` (int), `lastAttemptAt` (`DateTime?`).
- Produces: `static bool shouldSkipForBackoff({required int consecutiveFailures, required DateTime? lastAttemptAt, required DateTime now})` — pure, no Drift dependency, so it is trivially testable. `syncIncremental` consults it (via a `SyncStateRepository` row lookup) right after the flag gate and returns `skipped('backoff')` when true.

- [ ] **Step 1: Write the failing test**

Create `app/test/background_sync_backoff_test.dart`:

```dart
import 'package:activefriends/features/import/data/background_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 10, 31, 12, 0);

  test('fewer than 3 failures never skips', () {
    expect(
        BackgroundSyncService.shouldSkipForBackoff(
            consecutiveFailures: 2, lastAttemptAt: now, now: now),
        isFalse);
  });

  test('3 failures: skip within 15 min of last attempt, run after', () {
    // 2^(3-3)=1 cycle * 15 min = 15 min backoff.
    expect(
        BackgroundSyncService.shouldSkipForBackoff(
            consecutiveFailures: 3,
            lastAttemptAt: now.subtract(const Duration(minutes: 10)),
            now: now),
        isTrue);
    expect(
        BackgroundSyncService.shouldSkipForBackoff(
            consecutiveFailures: 3,
            lastAttemptAt: now.subtract(const Duration(minutes: 20)),
            now: now),
        isFalse);
  });

  test('10+ failures always skips (until manual trigger)', () {
    expect(
        BackgroundSyncService.shouldSkipForBackoff(
            consecutiveFailures: 10,
            lastAttemptAt: now.subtract(const Duration(days: 7)),
            now: now),
        isTrue);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd app && flutter test test/background_sync_backoff_test.dart -r expanded 2>&1 | tail -12`
Expected: FAIL — `shouldSkipForBackoff` undefined.

- [ ] **Step 3: Implement the pure gate**

Add to `BackgroundSyncService`:

```dart
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
```

- [ ] **Step 4: Wire it into `syncIncremental`**

Immediately after the flag gate (before `final core = _core!;`), add:

```dart
    // Backoff throttle (§8.2). Read-only peek at the run-status row.
    final backoffRow = await _syncStateRepository
        ?.rowFor(userId, Platform.isIOS ? 'healthkit' : 'health_connect');
    if (backoffRow != null &&
        shouldSkipForBackoff(
          consecutiveFailures: backoffRow.consecutiveFailures,
          lastAttemptAt: backoffRow.lastAttemptAt,
          now: DateTime.now(),
        )) {
      return const BackgroundSyncResult.skippedReason('backoff');
    }
```

This needs a public read accessor on `SyncStateRepository`. In `app/lib/features/import/data/sync_state_repository.dart`, add:

```dart
  /// Read the current run-status row (or null), for the backoff gate.
  Future<SyncState?> rowFor(String userId, String source) =>
      _rowFor(userId, source).getSingleOrNull();
```

(`SyncState` is already in scope there via `package:activefriends/data/local/app_database.dart`.)

- [ ] **Step 5: Run tests**

Run: `cd app && flutter test test/background_sync_backoff_test.dart test/background_sync_hardening_test.dart test/sync_state_repository_test.dart 2>&1 | tail -10`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
cd /Users/I589392/mygit/activeFriendsOutpace
git add app/lib/features/import/data/background_sync_service.dart app/lib/features/import/data/sync_state_repository.dart app/test/background_sync_backoff_test.dart
git commit -m "feat(sync): exponential backoff gate after repeated failures"
```

---

## Task 5: `AutoSyncPreferences` (per-user toggle persistence)

**Files:**
- Create: `app/lib/features/import/data/auto_sync_preferences.dart`
- Test: `app/test/auto_sync_preferences_test.dart` (new)

**Interfaces:**
- Produces:
  - `class AutoSyncPreferences { AutoSyncPreferences({SharedPreferences? prefs}); }`
  - keys (from §6.3): `kEnabled='auto_sync_enabled'`, `kRegisteredAt='auto_sync_registered_at'`, `kLastSuccess='auto_sync_last_success'`.
  - `Future<bool> isEnabled()` (default false), `Future<void> setEnabled(bool)`, `Future<DateTime?> lastSuccess()`, `Future<void> setLastSuccess(DateTime)`, `Future<void> markRegistered()`.

- [ ] **Step 1: Write the failing test**

Create `app/test/auto_sync_preferences_test.dart`:

```dart
import 'package:activefriends/features/import/data/auto_sync_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('defaults to disabled', () async {
    final prefs = await SharedPreferences.getInstance();
    expect(await AutoSyncPreferences(prefs: prefs).isEnabled(), isFalse);
  });

  test('setEnabled round-trips', () async {
    final prefs = await SharedPreferences.getInstance();
    final p = AutoSyncPreferences(prefs: prefs);
    await p.setEnabled(true);
    expect(await p.isEnabled(), isTrue);
  });

  test('lastSuccess round-trips as a DateTime', () async {
    final prefs = await SharedPreferences.getInstance();
    final p = AutoSyncPreferences(prefs: prefs);
    final t = DateTime(2026, 10, 31, 9, 15);
    await p.setLastSuccess(t);
    expect(await p.lastSuccess(), t);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd app && flutter test test/auto_sync_preferences_test.dart -r expanded 2>&1 | tail -12`
Expected: FAIL — file/class missing.

- [ ] **Step 3: Implement**

Create `app/lib/features/import/data/auto_sync_preferences.dart`:

```dart
import 'package:shared_preferences/shared_preferences.dart';

/// Per-user (device-local) auto-sync toggle + last-sync timestamp. This is the
/// SECOND gate — it is AND'd with the remote `FeatureFlagService` kill switch.
/// The remote switch always wins; a user cannot force auto-sync on while ops
/// has it off.
class AutoSyncPreferences {
  AutoSyncPreferences({SharedPreferences? prefs}) : _prefs = prefs;

  static const kEnabled = 'auto_sync_enabled';
  static const kRegisteredAt = 'auto_sync_registered_at';
  static const kLastSuccess = 'auto_sync_last_success';

  SharedPreferences? _prefs;
  Future<SharedPreferences> get _p async =>
      _prefs ??= await SharedPreferences.getInstance();

  Future<bool> isEnabled() async => (await _p).getBool(kEnabled) ?? false;

  Future<void> setEnabled(bool value) async =>
      (await _p).setBool(kEnabled, value);

  Future<void> markRegistered() async =>
      (await _p).setString(kRegisteredAt, DateTime.now().toIso8601String());

  Future<DateTime?> lastSuccess() async {
    final raw = (await _p).getString(kLastSuccess);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  Future<void> setLastSuccess(DateTime at) async =>
      (await _p).setString(kLastSuccess, at.toIso8601String());
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd app && flutter test test/auto_sync_preferences_test.dart 2>&1 | tail -8`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/I589392/mygit/activeFriendsOutpace
git add app/lib/features/import/data/auto_sync_preferences.dart app/test/auto_sync_preferences_test.dart
git commit -m "feat(sync): add AutoSyncPreferences per-user toggle persistence"
```

---

## Task 6: `AutoSyncManager` — two-gate register/teardown orchestrator

**Files:**
- Create: `app/lib/features/import/data/auto_sync_manager.dart`
- Test: `app/test/auto_sync_manager_test.dart` (new)

**Interfaces:**
- Consumes: `FeatureFlagService.autoSyncEnabled()` (remote), `AutoSyncPreferences.isEnabled()` (user).
- Produces:
  - `static bool shouldAutoSyncRun({required bool remoteEnabled, required bool userEnabled}) => remoteEnabled && userEnabled;`
  - `class AutoSyncManager` with injectable platform seams (so no WorkManager/channel calls run under `flutter test`):
    - `typedef RegisterWorker = Future<void> Function();`
    - `typedef TeardownWorker = Future<void> Function();`
  - `AutoSyncManager({required FeatureFlagService flags, required AutoSyncPreferences prefs, required RegisterWorker register, required TeardownWorker teardown});`
  - `Future<bool> syncRegistration()` — resolves both gates; on true calls `register()` + `prefs.markRegistered()` and returns true; on false calls `teardown()` and returns false.

- [ ] **Step 1: Write the failing test**

Create `app/test/auto_sync_manager_test.dart`:

```dart
import 'package:activefriends/features/import/data/auto_sync_manager.dart';
import 'package:activefriends/features/import/data/auto_sync_preferences.dart';
import 'package:activefriends/features/import/data/feature_flag_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('two-gate AND is pure', () {
    expect(
        AutoSyncManager.shouldAutoSyncRun(
            remoteEnabled: true, userEnabled: true),
        isTrue);
    for (final pair in [
      [true, false],
      [false, true],
      [false, false]
    ]) {
      expect(
          AutoSyncManager.shouldAutoSyncRun(
              remoteEnabled: pair[0], userEnabled: pair[1]),
          isFalse);
    }
  });

  Future<AutoSyncManager> build({
    required bool remote,
    required bool user,
    required List<String> log,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await AutoSyncPreferences(prefs: prefs).setEnabled(user);
    return AutoSyncManager(
      flags: FeatureFlagService(
          fetchAutoSyncRow: () async => {'value': {'enabled': remote}},
          prefs: prefs),
      prefs: AutoSyncPreferences(prefs: prefs),
      register: () async => log.add('register'),
      teardown: () async => log.add('teardown'),
    );
  }

  test('both gates on → registers', () async {
    final log = <String>[];
    expect(await (await build(remote: true, user: true, log: log))
        .syncRegistration(), isTrue);
    expect(log, ['register']);
  });

  test('remote off → tears down even if user on', () async {
    final log = <String>[];
    expect(await (await build(remote: false, user: true, log: log))
        .syncRegistration(), isFalse);
    expect(log, ['teardown']);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd app && flutter test test/auto_sync_manager_test.dart -r expanded 2>&1 | tail -12`
Expected: FAIL — class/members missing.

- [ ] **Step 3: Implement**

Create `app/lib/features/import/data/auto_sync_manager.dart`:

```dart
import 'package:activefriends/features/import/data/auto_sync_preferences.dart';
import 'package:activefriends/features/import/data/feature_flag_service.dart';

typedef RegisterWorker = Future<void> Function();
typedef TeardownWorker = Future<void> Function();

/// Resolves the two-gate (remote kill switch AND per-user toggle) and either
/// registers the OS background worker/observer or tears it down. "Off" MUST
/// stop the OS waking the app — not merely no-op — so teardown is called
/// whenever either gate is off.
class AutoSyncManager {
  AutoSyncManager({
    required FeatureFlagService flags,
    required AutoSyncPreferences prefs,
    required RegisterWorker register,
    required TeardownWorker teardown,
  })  : _flags = flags,
        _prefs = prefs,
        _register = register,
        _teardown = teardown;

  final FeatureFlagService _flags;
  final AutoSyncPreferences _prefs;
  final RegisterWorker _register;
  final TeardownWorker _teardown;

  /// Remote switch always wins; a user cannot force it on while ops has it off.
  static bool shouldAutoSyncRun({
    required bool remoteEnabled,
    required bool userEnabled,
  }) =>
      remoteEnabled && userEnabled;

  /// Resolve both gates and register or tear down accordingly. Returns whether
  /// auto-sync is now active.
  Future<bool> syncRegistration() async {
    final remote = await _flags.autoSyncEnabled();
    final user = await _prefs.isEnabled();
    if (shouldAutoSyncRun(remoteEnabled: remote, userEnabled: user)) {
      await _register();
      await _prefs.markRegistered();
      return true;
    }
    await _teardown();
    return false;
  }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd app && flutter test test/auto_sync_manager_test.dart 2>&1 | tail -8`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/I589392/mygit/activeFriendsOutpace
git add app/lib/features/import/data/auto_sync_manager.dart app/test/auto_sync_manager_test.dart
git commit -m "feat(sync): add AutoSyncManager two-gate register/teardown orchestrator"
```

---

## Task 7: `SyncNotifier` — local notification on import (§7)

**Files:**
- Create: `app/lib/features/import/data/sync_notifier.dart`
- Modify: `app/lib/features/import/data/background_sync_service.dart` (invoke after a successful run)
- Test: `app/test/sync_notifier_test.dart` (new)

**Interfaces:**
- Produces:
  - `class SyncNotifier { SyncNotifier({required FlutterLocalNotificationsPlugin plugin}); Future<void> showSynced(int count); }`
  - `count == 0` → no-op; `count >= 1` → `plugin.show(42, 'Activities synced', <pluralized body>, <details with android channel 'outpace_sync', low importance>)`.
- Consumes in `BackgroundSyncService`: an optional `SyncNotifier? notifier` constructor param; called with `imported` when `imported > 0`.

- [ ] **Step 1: Write the failing test**

Create `app/test/sync_notifier_test.dart`. Fake the plugin via `implements`:

```dart
import 'package:activefriends/features/import/data/sync_notifier.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakePlugin implements FlutterLocalNotificationsPlugin {
  final calls = <String>[];
  @override
  Future<void> show(int id, String? title, String? body, dynamic details,
      {String? payload}) async {
    calls.add('$id|$title|$body');
  }
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

void main() {
  test('count 0 → no notification', () async {
    final p = _FakePlugin();
    await SyncNotifier(plugin: p).showSynced(0);
    expect(p.calls, isEmpty);
  });

  test('count 1 → singular copy', () async {
    final p = _FakePlugin();
    await SyncNotifier(plugin: p).showSynced(1);
    expect(p.calls.single, contains('1 new activity imported'));
  });

  test('count 3 → plural copy, fixed id 42', () async {
    final p = _FakePlugin();
    await SyncNotifier(plugin: p).showSynced(3);
    expect(p.calls.single, startsWith('42|Activities synced|'));
    expect(p.calls.single, contains('3 new activities imported'));
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd app && flutter test test/sync_notifier_test.dart -r expanded 2>&1 | tail -12`
Expected: FAIL — class missing.

- [ ] **Step 3: Implement**

Create `app/lib/features/import/data/sync_notifier.dart`:

```dart
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Low-importance local notification shown when a background sync imports new
/// activities. Fixed id 42 so a later sync replaces the previous banner.
class SyncNotifier {
  SyncNotifier({required FlutterLocalNotificationsPlugin plugin})
      : _plugin = plugin;
  final FlutterLocalNotificationsPlugin _plugin;

  Future<void> showSynced(int count) async {
    if (count <= 0) return;
    final body = count == 1
        ? '1 new activity imported from your watch.'
        : '$count new activities imported from your watch.';
    await _plugin.show(
      42,
      'Activities synced',
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'outpace_sync',
          'Activity Sync',
          channelDescription:
              'Notifications when activities are auto-imported',
          importance: Importance.low,
          priority: Priority.low,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: false,
          presentSound: false,
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Invoke from `BackgroundSyncService`**

Add an optional field + constructor param `SyncNotifier? notifier` (same pattern as the other nullable collaborators). After the successful-run `recordSyncAttempt(success: true)` line and before `return BackgroundSyncResult(...)`, add:

```dart
      if (imported > 0) {
        await _notifier?.showSynced(imported);
      }
```

In `forBackgroundIsolate()`, construct and pass `SyncNotifier(plugin: FlutterLocalNotificationsPlugin())` (add the import). The notifier stays null in unit tests, so no plugin runs there.

- [ ] **Step 5: Run tests**

Run: `cd app && flutter test test/sync_notifier_test.dart test/background_sync_hardening_test.dart 2>&1 | tail -10`
Expected: all PASS (hardening tests unaffected — notifier is null there).

- [ ] **Step 6: Commit**

```bash
cd /Users/I589392/mygit/activeFriendsOutpace
git add app/lib/features/import/data/sync_notifier.dart app/lib/features/import/data/background_sync_service.dart app/test/sync_notifier_test.dart
git commit -m "feat(sync): local notification on background import"
```

---

## Task 8: iOS native — observer, background delivery, method channel (NOT unit-testable)

**Files:**
- Modify: `app/ios/Runner/Runner.entitlements`
- Modify: `app/ios/Runner/Info.plist`
- Modify: `app/ios/Runner/AppDelegate.swift`

> **Verification reality:** background delivery cannot be exercised in `flutter test` or by the agent. Verification = (a) the iOS build compiles; (b) user device test. Keep this task's changes additive to the existing push setup.

- [ ] **Step 1: Add the background-delivery entitlement**

In `app/ios/Runner/Runner.entitlements`, inside the top-level `<dict>` (alongside the existing `com.apple.developer.healthkit`), add:

```xml
	<key>com.apple.developer.healthkit.background-delivery</key>
	<true/>
```

- [ ] **Step 2: Update the health usage description**

In `app/ios/Runner/Info.plist`, set `NSHealthShareUsageDescription`'s string value to:

```
Outpace reads your workouts to sync your activity feed automatically.
```

Do NOT add a `processing` `UIBackgroundMode` — background delivery needs only the entitlement.

- [ ] **Step 3: Implement the observer + channel in `AppDelegate.swift`**

Add `import HealthKit` at the top. Add a stored property and capture the messenger in the existing `didInitializeImplicitFlutterEngine`, then register the observer at launch. Full additions:

At class level (alongside the existing delegate code):

```swift
  private let healthStore = HKHealthStore()
  private var healthSyncChannel: FlutterMethodChannel?
```

In `didInitializeImplicitFlutterEngine(_:)`, AFTER the existing `GeneratedPluginRegistrant.register(...)` call, capture the application-level messenger and build the channel (the implicit bridge exposes `applicationRegistrar.messenger`, confirmed in `FlutterEngine.h`):

```swift
    let messenger = engineBridge.applicationRegistrar.messenger
    let channel = FlutterMethodChannel(
      name: "app.activefriends.app/health_sync",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "enableBackgroundDelivery":
        self?.enableHealthBackgroundDelivery()
        result(nil)
      case "disableBackgroundDelivery":
        self?.disableHealthBackgroundDelivery()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.healthSyncChannel = channel
    if HKHealthStore.isHealthDataAvailable() {
      self.registerHealthKitObserver()
    }
```

Add the three HealthKit methods to the class:

```swift
  private func registerHealthKitObserver() {
    let workoutType = HKObjectType.workoutType()
    let query = HKObserverQuery(sampleType: workoutType, predicate: nil) {
      [weak self] _, completionHandler, error in
      guard error == nil else { completionHandler(); return }
      self?.triggerDartSync { completionHandler() }
    }
    healthStore.execute(query)
  }

  private func triggerDartSync(completion: @escaping () -> Void) {
    DispatchQueue.main.async {
      guard let channel = self.healthSyncChannel else { completion(); return }
      channel.invokeMethod("onHealthDataChanged", arguments: nil) { _ in
        completion() // Apple requires the completion handler be called.
      }
    }
  }

  private func enableHealthBackgroundDelivery() {
    let workoutType = HKObjectType.workoutType()
    healthStore.enableBackgroundDelivery(for: workoutType, frequency: .immediate) {
      success, error in
      if let error = error {
        NSLog("[outpace][sync] enableBackgroundDelivery failed: %@",
              error.localizedDescription)
      }
    }
  }

  private func disableHealthBackgroundDelivery() {
    let workoutType = HKObjectType.workoutType()
    healthStore.disableBackgroundDelivery(for: workoutType) { _, _ in }
  }
```

> The observer is registered at launch regardless of the flag (so a wake can reach Dart), but `enableBackgroundDelivery` is only switched on when Dart calls `enableBackgroundDelivery` (Task 10, after the two-gate resolves true). Dart's `onHealthDataChanged` handler is itself flag-gated, so an unwanted wake is a cheap no-op.

- [ ] **Step 4: Verify the iOS build compiles (if a Mac/Xcode toolchain is available)**

Run: `cd app && flutter build ios --config-only --no-codesign 2>&1 | tail -15`
Expected: configuration succeeds (full signed build is the user's release step). If the toolchain is unavailable in this environment, note that and defer to the user's build.

- [ ] **Step 5: Commit**

```bash
cd /Users/I589392/mygit/activeFriendsOutpace
git add app/ios/Runner/Runner.entitlements app/ios/Runner/Info.plist app/ios/Runner/AppDelegate.swift
git commit -m "feat(ios): HKObserver background delivery + health_sync method channel"
```

---

## Task 9: Android WorkManager entry point in `main.dart` (NOT unit-testable)

**Files:**
- Modify: `app/lib/main.dart`

> **Verification reality:** the WorkManager isolate + `health` background read run only on-device. Verification = `flutter analyze` + user device test.

- [ ] **Step 1: Add the callback dispatcher + background sync runner**

In `app/lib/main.dart`, add imports:

```dart
import 'dart:developer' as developer;
import 'dart:io';
import 'package:workmanager/workmanager.dart';
import 'package:activefriends/core/config/supabase_config.dart';
import 'package:activefriends/features/import/data/background_sync_service.dart';
import 'package:activefriends/features/import/data/feature_flag_service.dart';
```

(`supabase_config.dart` and the rest are already partly imported — do not duplicate existing import lines.)

Add the top-level entry point and runner (both MUST be top-level, `@pragma('vm:entry-point')`):

```dart
const kHealthSyncTask = 'healthSyncPeriodic';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    if (taskName != kHealthSyncTask) return true;
    return _executeBackgroundHealthSync();
  });
}

Future<bool> _executeBackgroundHealthSync() async {
  try {
    WidgetsFlutterBinding.ensureInitialized();
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    if (!SupabaseConfig.isConfigured) return true;
    await Supabase.initialize(
      url: SupabaseConfig.url,
      publishableKey: SupabaseConfig.publishableKey,
    );
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return true; // no session — skip silently

    // Remote kill switch. If OFF, stop the OS waking us and exit.
    if (!await FeatureFlagService().autoSyncEnabled()) {
      await Workmanager().cancelByUniqueName(kHealthSyncTask);
      return true;
    }

    await BackgroundSyncService.forBackgroundIsolate()
        .syncIncremental(userId: user.id);
    return true;
  } catch (e) {
    developer.log('Background health sync failed: $e', name: 'HealthSync');
    return false; // WorkManager retries
  }
}
```

- [ ] **Step 2: Verify analyze**

Run: `cd app && flutter analyze lib/main.dart 2>&1 | tail -12`
Expected: no new issues (note: `callbackDispatcher` is referenced by Task 10's registration seam, so an "unused" lint should not fire once Task 10 lands; if it fires here, proceed — Task 10 resolves it).

- [ ] **Step 3: Commit**

```bash
cd /Users/I589392/mygit/activeFriendsOutpace
git add app/lib/main.dart
git commit -m "feat(android): WorkManager callbackDispatcher + flag-gated background sync"
```

---

## Task 10: Startup register/teardown wiring + iOS channel handler (`main.dart`)

**Files:**
- Modify: `app/lib/main.dart`
- Create: `app/lib/features/import/data/auto_sync_platform.dart` (the real platform seams)

**Interfaces:**
- Consumes: `AutoSyncManager` (Task 6), `callbackDispatcher`/`kHealthSyncTask` (Task 9), the iOS channel name `app.activefriends.app/health_sync` (Task 8).
- Produces: `app/lib/features/import/data/auto_sync_platform.dart` with the real `RegisterWorker`/`TeardownWorker` implementations and the iOS channel handle, plus `AutoSyncPlatform.start()` (called once from `main`).

> **Verification reality:** platform channel + WorkManager registration run only on-device. Verification = `flutter analyze`. Keep all platform calls in `auto_sync_platform.dart` so the rest stays testable.

- [ ] **Step 1: Create the platform seams**

Create `app/lib/features/import/data/auto_sync_platform.dart`:

```dart
import 'dart:io';

import 'package:activefriends/features/import/data/auto_sync_manager.dart';
import 'package:activefriends/features/import/data/auto_sync_preferences.dart';
import 'package:activefriends/features/import/data/background_sync_service.dart';
import 'package:activefriends/features/import/data/feature_flag_service.dart';
import 'package:flutter/services.dart';
import 'package:health/health.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:workmanager/workmanager.dart';

/// Owns every OS-level auto-sync side effect (WorkManager, HealthKit channel,
/// Health Connect background-read request). The rest of the feature stays
/// platform-free and unit-testable; this is the one place device behaviour
/// lives.
class AutoSyncPlatform {
  AutoSyncPlatform({
    required this.callbackDispatcher,
    required this.kHealthSyncTask,
  });

  final void Function() callbackDispatcher;
  final String kHealthSyncTask;

  static const _channel = MethodChannel('app.activefriends.app/health_sync');

  /// Call once from `main` after `Supabase.initialize`. Sets up the iOS
  /// Dart-side handler and resolves the two-gate to register or tear down.
  Future<void> start() async {
    if (Platform.isIOS) {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'onHealthDataChanged') {
          final user = Supabase.instance.client.auth.currentUser;
          if (user == null) return null;
          await BackgroundSyncService.forBackgroundIsolate()
              .syncIncremental(userId: user.id);
        }
        return null;
      });
    }
    await manager().syncRegistration();
  }

  AutoSyncManager manager() => AutoSyncManager(
        flags: FeatureFlagService(),
        prefs: AutoSyncPreferences(),
        register: _register,
        teardown: _teardown,
      );

  Future<void> _register() async {
    if (Platform.isAndroid) {
      final health = Health();
      if (await health.isHealthDataInBackgroundAvailable() &&
          !await health.isHealthDataInBackgroundAuthorized()) {
        await health.requestHealthDataInBackgroundAuthorization();
      }
      await Workmanager().initialize(callbackDispatcher, isInDebugMode: false);
      await Workmanager().registerPeriodicTask(
        kHealthSyncTask,
        kHealthSyncTask,
        frequency: const Duration(minutes: 15),
        constraints: Constraints(
          networkType: NetworkType.connected,
          requiresBatteryNotLow: true,
        ),
        existingWorkPolicy: ExistingWorkPolicy.keep,
        backoffPolicy: BackoffPolicy.exponential,
        initialDelay: const Duration(minutes: 1),
      );
    } else if (Platform.isIOS) {
      await _channel.invokeMethod('enableBackgroundDelivery');
    }
  }

  Future<void> _teardown() async {
    if (Platform.isAndroid) {
      await Workmanager().cancelByUniqueName(kHealthSyncTask);
    } else if (Platform.isIOS) {
      await _channel.invokeMethod('disableBackgroundDelivery');
    }
  }
}
```

- [ ] **Step 2: Wire it into `main()`**

In `app/lib/main.dart`, add the import:

```dart
import 'package:activefriends/features/import/data/auto_sync_platform.dart';
```

In `main()`, AFTER the `Supabase.initialize` block and `await ConnectivityService.instance.initialize();`, before `runApp`, add:

```dart
  if (SupabaseConfig.isConfigured) {
    await AutoSyncPlatform(
      callbackDispatcher: callbackDispatcher,
      kHealthSyncTask: kHealthSyncTask,
    ).start();
  }
```

- [ ] **Step 3: Verify analyze**

Run: `cd app && flutter analyze lib/main.dart lib/features/import/data/auto_sync_platform.dart 2>&1 | tail -12`
Expected: no new issues; the `callbackDispatcher` unused-warning from Task 9 is now resolved.

- [ ] **Step 4: Full suite still green**

Run: `cd app && flutter test 2>&1 | tail -15`
Expected: same pass/fail as Task 0 baseline (only `widget_test.dart` fails).

- [ ] **Step 5: Commit**

```bash
cd /Users/I589392/mygit/activeFriendsOutpace
git add app/lib/main.dart app/lib/features/import/data/auto_sync_platform.dart
git commit -m "feat(sync): startup two-gate register/teardown + iOS channel handler"
```

---

## Task 11: `WatchImportSection` UI — auto-sync toggle + last-synced

**Files:**
- Modify: `app/lib/features/import/presentation/watch_import_section.dart`
- Test: `app/test/watch_import_auto_sync_test.dart` (new, widget test)

**Interfaces:**
- Consumes: `AutoSyncPreferences` (Task 5), `FeatureFlagService` (remote gate), `AutoSyncManager` (register/teardown).
- Produces: the widget gains optional injected seams so the widget test runs without platform calls: `WatchImportSection({super.key, AutoSyncPreferences? autoSyncPrefs, FeatureFlagService? flags, Future<void> Function()? onToggle})`.

- [ ] **Step 1: Write the failing widget test**

Create `app/test/watch_import_auto_sync_test.dart`:

```dart
import 'package:activefriends/features/import/data/auto_sync_preferences.dart';
import 'package:activefriends/features/import/data/feature_flag_service.dart';
import 'package:activefriends/features/import/presentation/watch_import_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('shows the Auto-Sync toggle reflecting the stored pref',
      (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await AutoSyncPreferences(prefs: prefs).setEnabled(true);
    var toggled = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: WatchImportSection(
          autoSyncPrefs: AutoSyncPreferences(prefs: prefs),
          flags: FeatureFlagService(
              fetchAutoSyncRow: () async => {'value': {'enabled': true}},
              prefs: prefs),
          onToggle: () async => toggled++,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Auto-Sync'), findsOneWidget);
    final sw = tester.widget<Switch>(find.byType(Switch));
    expect(sw.value, isTrue);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(toggled, 1);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd app && flutter test test/watch_import_auto_sync_test.dart -r expanded 2>&1 | tail -15`
Expected: FAIL — constructor params / `Auto-Sync` text / `Switch` missing.

- [ ] **Step 3: Implement the UI**

Edit `app/lib/features/import/presentation/watch_import_section.dart`. Add imports:

```dart
import 'package:activefriends/features/import/data/auto_sync_manager.dart';
import 'package:activefriends/features/import/data/auto_sync_platform.dart';
import 'package:activefriends/features/import/data/auto_sync_preferences.dart';
import 'package:activefriends/features/import/data/feature_flag_service.dart';
import 'package:activefriends/main.dart' show callbackDispatcher, kHealthSyncTask;
```

Replace the widget constructor and add injected seams:

```dart
class WatchImportSection extends StatefulWidget {
  const WatchImportSection({
    super.key,
    AutoSyncPreferences? autoSyncPrefs,
    FeatureFlagService? flags,
    Future<void> Function()? onToggle,
  })  : _autoSyncPrefs = autoSyncPrefs,
        _flags = flags,
        _onToggle = onToggle;

  final AutoSyncPreferences? _autoSyncPrefs;
  final FeatureFlagService? _flags;
  final Future<void> Function()? _onToggle;

  @override
  State<WatchImportSection> createState() => _WatchImportSectionState();
}
```

In the state, add fields + load logic + toggle handler:

```dart
  late final AutoSyncPreferences _prefs =
      widget._autoSyncPrefs ?? AutoSyncPreferences();
  late final FeatureFlagService _flags = widget._flags ?? FeatureFlagService();
  bool _autoSyncOn = false;
  bool _remoteAllowed = false;
  DateTime? _lastSynced;

  @override
  void initState() {
    super.initState();
    _loadAutoSyncState();
  }

  Future<void> _loadAutoSyncState() async {
    final on = await _prefs.isEnabled();
    final remote = await _flags.autoSyncEnabled();
    final last = await _prefs.lastSuccess();
    if (mounted) {
      setState(() {
        _autoSyncOn = on;
        _remoteAllowed = remote;
        _lastSynced = last;
      });
    }
  }

  Future<void> _toggleAutoSync(bool value) async {
    await _prefs.setEnabled(value);
    setState(() => _autoSyncOn = value);
    final onToggle = widget._onToggle;
    if (onToggle != null) {
      await onToggle();
    } else {
      // Real platform path: resolve the two-gate and register/teardown.
      await AutoSyncPlatform(
        callbackDispatcher: callbackDispatcher,
        kHealthSyncTask: kHealthSyncTask,
      ).manager().syncRegistration();
    }
  }

  String _relative(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }
```

Add the toggle UI into `build`, at the top of the `Column` children (before the existing manual-import Row):

```dart
        Row(
          children: [
            const Expanded(child: Text('Auto-Sync')),
            Switch(
              value: _autoSyncOn,
              onChanged: _remoteAllowed || _autoSyncOn
                  ? (v) => _toggleAutoSync(v)
                  : null,
            ),
          ],
        ),
        Text(
          _remoteAllowed
              ? 'Automatically import new workouts when your watch syncs.'
              : 'Auto-sync is currently unavailable.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (_lastSynced != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Last sync: ${_relative(_lastSynced!)}',
                style: Theme.of(context).textTheme.bodySmall),
          ),
        const Divider(height: 24),
```

> Note the import of `main.dart` for `callbackDispatcher`/`kHealthSyncTask`. If that creates an undesirable import cycle under analyze, move those two symbols into `auto_sync_platform.dart` (define `kHealthSyncTask` there and have `main.dart` import it) and update Task 9/10 references. Prefer no cycle.

- [ ] **Step 4: Run the widget test**

Run: `cd app && flutter test test/watch_import_auto_sync_test.dart -r expanded 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 5: Verify analyze + full suite**

Run: `cd app && flutter analyze 2>&1 | tail -12 && flutter test 2>&1 | tail -15`
Expected: no new analyze issues; suite green minus `widget_test.dart`.

- [ ] **Step 6: Commit**

```bash
cd /Users/I589392/mygit/activeFriendsOutpace
git add app/lib/features/import/presentation/watch_import_section.dart app/test/watch_import_auto_sync_test.dart
git commit -m "feat(ui): auto-sync toggle + last-synced in WatchImportSection"
```

---

## Task 12: Flip the `app_config` seed to ON

**Files:**
- Modify: `supabase/migrations/20261030120000_app_config.sql`

> **Context:** The user confirmed this migration has NOT been `db push`ed yet, so editing the seed value is sufficient. If it HAD been deployed, `on conflict do nothing` would make the edit a no-op and a NEW migration doing `update ... set value='{"enabled": true}'` would be required. The verification step surfaces this.

- [ ] **Step 1: Flip the seed**

In `supabase/migrations/20261030120000_app_config.sql`, change the seed insert's value from `'{"enabled": false}'::jsonb` to `'{"enabled": true}'::jsonb`, and update the adjacent comment from "ships OFF" to "ships ON (remote OFF via `update app_config set value='{\"enabled\": false}'`)".

Resulting lines:

```sql
-- Background auto-sync global kill switch — ships ON; disable fleet-wide with
--   update public.app_config set value='{"enabled": false}' where key='auto_sync';
insert into public.app_config (key, value)
values ('auto_sync', '{"enabled": true}'::jsonb)
on conflict (key) do nothing;
```

- [ ] **Step 2: Verify the change**

Run: `grep -n 'enabled' /Users/I589392/mygit/activeFriendsOutpace/supabase/migrations/20261030120000_app_config.sql`
Expected: shows `"enabled": true`.

- [ ] **Step 3: Commit**

```bash
cd /Users/I589392/mygit/activeFriendsOutpace
git add supabase/migrations/20261030120000_app_config.sql
git commit -m "feat(sync): seed app_config.auto_sync ON for release"
```

---

## Task 13: Final verification + release-prerequisite surfacing (no code)

**Files:** none.

- [ ] **Step 1: Full suite + analyze**

Run: `cd app && flutter test 2>&1 | tail -20`
Expected: green EXCEPT `test/widget_test.dart` "Shows the unconfigured backend state" — identical to the Task 0 baseline, plus all the NEW tests passing (`background_sync_service_delta_test`, `background_sync_hardening_test`, `background_sync_backoff_test`, `auto_sync_preferences_test`, `auto_sync_manager_test`, `sync_notifier_test`, `watch_import_auto_sync_test`).

Run: `cd app && flutter analyze 2>&1 | tail -20`
Expected: no new issues vs. Task 0.

- [ ] **Step 2: Confirm the regression gates specifically**

Run: `cd app && flutter test test/health_import_source_distance_test.dart test/health_import_duplicate_skip_test.dart 2>&1 | tail -8`
Expected: PASS. Confirm `git diff main -- app/test/health_import_source_distance_test.dart` shows NO fixture changes.

- [ ] **Step 3: Surface the user-owned release prerequisites**

These GATE the release and the agent cannot do them. Report to the user:
1. **iOS:** add `com.apple.developer.healthkit.background-delivery` to the App ID / provisioning profile + an App Review note.
2. **Android:** complete the `READ_HEALTH_DATA_IN_BACKGROUND` runtime consent flow on-device + a Play Console data-safety update.
3. **Supabase:** run `supabase db push` so `app_config` (now seeded ON) is deployed; else the flag reads absent → fail-safe OFF. (Prod is read-only to the agent; user runs it.)
4. **Device test** auto-sync on a real iPhone + Pixel (ideally Mahesh's iPhone where the dup bug appeared) before public release. The kill switch is the safety net.
5. **Build & release** from `integration/next-build` (do not push without explicit instruction).

- [ ] **Step 4: (No commit — verification only.)**

---

## Self-Review

**Spec coverage** (against `SPEC` §3–§9 and `RESUME` items 1–5):
- Android WorkManager wiring + bg permission + `health.getChanges` delta → Tasks 1, 2, 9. ✓
- iOS HKObserver + entitlement + method channel → Task 8 (anchored query intentionally deferred per the agreed "observer + full rescan" decision; iOS `_resolveChangedIds` returns null in Task 2). ✓
- Startup flag resolution + register/teardown (both platforms) → Tasks 6, 10. ✓
- `configure()` + auth + non-workout pre-filter before real reads → Task 3. ✓
- Two-gate AND (remote && user toggle) → Tasks 5, 6, 11. ✓
- §6 UX (toggle + last-synced) → Task 11; §7 notification → Task 7. ✓
- §8.2 backoff → Task 4; §8 failure recording → Task 3. ✓
- `app_config` seed ON → Task 12. ✓
- Diagnostics (§8.3): the manual path's `distance_debug` persistence is untouched; background-sync-specific `import_diagnostics` rows are **not** added in this build (deferred — not required for function). NOTE: if the user wants §8.3 background diagnostics, add a follow-up task; flagged here as a conscious omission.

**Placeholder scan:** no TBD/placeholder steps; every code step shows complete code. Native/config tasks (8, 9, 10, 12) are explicitly marked not-unit-testable with build/analyze verification, which is honest, not a placeholder.

**Type consistency:** `ChangesDelta`, `ChangesTokenFetcher`, `ChangesFetcher`, `resolveAndroidChangedIds`, `shouldSkipForBackoff`, `rowFor`, `ensureAuthorized`, `AutoSyncPreferences`, `AutoSyncManager.shouldAutoSyncRun`/`syncRegistration`, `SyncNotifier.showSynced`, `AutoSyncPlatform.start/manager`, `callbackDispatcher`/`kHealthSyncTask` are defined before first use and referenced consistently across tasks. The iOS channel name `app.activefriends.app/health_sync` and method names `onHealthDataChanged`/`enableBackgroundDelivery`/`disableBackgroundDelivery` match between Task 8 (Swift) and Task 10 (Dart).

**Known risk to watch during execution:** the `main.dart` ↔ `watch_import_section.dart` import of `callbackDispatcher`/`kHealthSyncTask` (Task 11 note) — resolve by relocating those two symbols if analyze flags a cycle.
