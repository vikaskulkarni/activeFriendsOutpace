# Background Auto-Sync — Plan 1: Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the device-independent, unit-tested foundation for background auto-sync — shared read/upsert logic, delta-cursor state, and the Supabase-controlled kill switch — all behind a flag that ships **off**, so the stable app is unaffected.

**Architecture:** Extract the reusable read/transform/upsert logic out of `HealthImportService` into a `HealthSyncCore` that both the manual and (future) background paths call, so a regression shows up in the manual path too. Add a `SyncState` Drift table for delta cursors, a `SyncStateRepository`, a `FeatureFlagService` reading a global `app_config.auto_sync` boolean (fail-safe → off), and a `BackgroundSyncService` orchestrator whose entry is gated by that flag. No platform wiring (iOS observer / Android WorkManager) in this plan.

**Tech Stack:** Flutter/Dart, Drift (`^2.35.0`) with `drift_flutter`, `health ^13.3.2`, `supabase_flutter ^2.17.2`, `shared_preferences`, `flutter_test`.

## Global Constraints

- Drift `schemaVersion` goes **5 → 6**; add the new table to the existing `onUpgrade` ladder in `app/lib/data/local/app_database.dart`. (Current value is `5` at `app_database.dart:100`.)
- Drift tables are declared **inline in `app/lib/data/local/app_database.dart`** (there is no `lib/data/local/tables/` directory). Follow that pattern.
- Tests live **flat in `app/test/`** (e.g. `app/test/feature_flag_service_test.dart`), matching existing files like `test/health_import_source_distance_test.dart`.
- The feature ships **off**: `app_config.auto_sync` seeds `{"enabled": false}`, and `FeatureFlagService` fails safe to `false`.
- **No regression to manual import.** The existing suite — especially `test/health_import_source_distance_test.dart` — MUST stay green after every task. The `HealthSyncCore` extraction is a **behaviour-preserving move**, not a rewrite.
- Source-aware distance MUST keep its window context: workouts travel with the window's `DISTANCE_DELTA` + `HEART_RATE` batches (never read a workout in isolation and fall back to `totalDistance` — that is the `ceb118c` double-distance bug).
- All commands run from the `app/` directory. Regenerate Drift code with `dart run build_runner build --delete-conflicting-outputs` after any table change.

---

### Task 1: `SyncState` Drift table + migration v5→v6

**Files:**
- Modify: `app/lib/data/local/app_database.dart` (add table class, register it, bump `schemaVersion`, extend `onUpgrade`)
- Regenerate: `app/lib/data/local/app_database.g.dart` (via build_runner)
- Test: `app/test/sync_state_migration_test.dart`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: Drift table class `SyncStates` → generated row class `SyncState`, companion `SyncStatesCompanion`. Columns: `userId` (text), `source` (text), `changesToken` (text?), `hkAnchor` (blob?), `lastSuccessfulAt` (dateTime?), `lastAttemptAt` (dateTime?), `consecutiveFailures` (int, default 0), `updatedAt` (dateTime, default now). Primary key `{userId, source}`. Accessor `db.syncStates`.

- [ ] **Step 1: Write the failing test**

Create `app/test/sync_state_migration_test.dart`:

```dart
import 'package:activefriends/data/local/app_database.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SyncStates table exists and round-trips a row', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await db.into(db.syncStates).insert(
          SyncStatesCompanion.insert(
            userId: 'u1',
            source: 'health_connect',
            changesToken: const Value('tok-123'),
          ),
        );

    final row = await (db.select(db.syncStates)
          ..where((r) => r.userId.equals('u1') & r.source.equals('health_connect')))
        .getSingle();

    expect(row.changesToken, 'tok-123');
    expect(row.consecutiveFailures, 0); // default applied
  });

  test('schemaVersion is 6', () {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    expect(db.schemaVersion, 6);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/sync_state_migration_test.dart`
Expected: FAIL — `db.syncStates` / `SyncStatesCompanion` undefined, and `schemaVersion` is 5.

- [ ] **Step 3: Add the table class**

In `app/lib/data/local/app_database.dart`, after the `TrackingPoints` table declaration (before the `@DriftDatabase(` annotation at line ~85), add:

```dart
class SyncStates extends Table {
  TextColumn get userId => text()();
  TextColumn get source => text()();
  TextColumn get changesToken => text().nullable()();        // Android Changes API cursor
  BlobColumn get hkAnchor => blob().nullable()();            // iOS HKQueryAnchor
  DateTimeColumn get lastSuccessfulAt => dateTime().nullable()();
  DateTimeColumn get lastAttemptAt => dateTime().nullable()();
  IntColumn get consecutiveFailures => integer().withDefault(const Constant(0))();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {userId, source};
}
```

- [ ] **Step 4: Register the table and bump the schema**

In the `@DriftDatabase(tables: [...])` list, add `SyncStates` after `TrackingPoints`:

```dart
@DriftDatabase(
  tables: [
    LocalActivities,
    ImportWatermarks,
    PendingActivitySyncs,
    TrackingSessions,
    TrackingPoints,
    SyncStates,
  ],
)
```

Change `int get schemaVersion => 5;` to `=> 6;`.

In `MigrationStrategy.onUpgrade`, append after the `if (from < 5)` block:

```dart
      if (from < 6) {
        await migrator.createTable(syncStates);
      }
```

- [ ] **Step 5: Regenerate Drift code**

Run: `cd app && dart run build_runner build --delete-conflicting-outputs`
Expected: completes; `app_database.g.dart` now defines `SyncState`, `SyncStatesCompanion`, `syncStates`.

- [ ] **Step 6: Run test to verify it passes**

Run: `cd app && flutter test test/sync_state_migration_test.dart`
Expected: PASS (both tests).

- [ ] **Step 7: Confirm no regression in the full suite**

Run: `cd app && flutter test`
Expected: PASS (all existing tests still green).

- [ ] **Step 8: Commit**

```bash
git add app/lib/data/local/app_database.dart app/lib/data/local/app_database.g.dart app/test/sync_state_migration_test.dart
git commit -m "feat(sync): add SyncState table + migration v5->v6"
```

---

### Task 2: `SyncStateRepository`

**Files:**
- Create: `app/lib/features/import/data/sync_state_repository.dart`
- Test: `app/test/sync_state_repository_test.dart`

**Interfaces:**
- Consumes: `AppDatabase`, `db.syncStates`, `SyncStatesCompanion` (Task 1).
- Produces: `SyncStateRepository(AppDatabase db)` with:
  - `Future<String?> getChangesToken({required String userId, required String source})`
  - `Future<void> saveChangesToken({required String userId, required String source, required String token})`
  - `Future<void> invalidateToken({required String userId, required String source})`
  - `Future<Uint8List?> getHkAnchor({required String userId, required String source})`
  - `Future<void> saveHkAnchor({required String userId, required String source, required Uint8List anchor})`
  - `Future<void> recordSyncAttempt({required String userId, required String source, required bool success})`

- [ ] **Step 1: Write the failing test**

Create `app/test/sync_state_repository_test.dart`:

```dart
import 'dart:typed_data';

import 'package:activefriends/data/local/app_database.dart';
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

  test('token round-trips and can be invalidated', () async {
    expect(await repo.getChangesToken(userId: 'u', source: 's'), isNull);

    await repo.saveChangesToken(userId: 'u', source: 's', token: 'T1');
    expect(await repo.getChangesToken(userId: 'u', source: 's'), 'T1');

    await repo.invalidateToken(userId: 'u', source: 's');
    expect(await repo.getChangesToken(userId: 'u', source: 's'), isNull);
  });

  test('hkAnchor round-trips as bytes', () async {
    final anchor = Uint8List.fromList([1, 2, 3, 4]);
    await repo.saveHkAnchor(userId: 'u', source: 'healthkit', anchor: anchor);
    expect(await repo.getHkAnchor(userId: 'u', source: 'healthkit'), anchor);
  });

  test('recordSyncAttempt increments failures and resets on success', () async {
    await repo.recordSyncAttempt(userId: 'u', source: 's', success: false);
    await repo.recordSyncAttempt(userId: 'u', source: 's', success: false);
    var row = await (db.select(db.syncStates)
          ..where((r) => r.userId.equals('u') & r.source.equals('s')))
        .getSingle();
    expect(row.consecutiveFailures, 2);
    expect(row.lastSuccessfulAt, isNull);

    await repo.recordSyncAttempt(userId: 'u', source: 's', success: true);
    row = await (db.select(db.syncStates)
          ..where((r) => r.userId.equals('u') & r.source.equals('s')))
        .getSingle();
    expect(row.consecutiveFailures, 0);
    expect(row.lastSuccessfulAt, isNotNull);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/sync_state_repository_test.dart`
Expected: FAIL — `sync_state_repository.dart` not found.

- [ ] **Step 3: Write the implementation**

Create `app/lib/features/import/data/sync_state_repository.dart`:

```dart
import 'dart:typed_data';

import 'package:activefriends/data/local/app_database.dart';
import 'package:drift/drift.dart';

/// Persistence for background-sync delta cursors and run status.
///
/// Holds ONLY cursors (`changesToken`, `hkAnchor`) and run metadata
/// (`lastSuccessfulAt` / `lastAttemptAt` / `consecutiveFailures`). The
/// data-coverage watermark stays in `ImportWatermarks` via
/// `LocalImportRepository.saveWatermark` — there is one watermark system.
class SyncStateRepository {
  SyncStateRepository(this._db);
  final AppDatabase _db;

  SimpleSelectStatement<$SyncStatesTable, SyncState> _rowFor(
      String userId, String source) {
    return _db.select(_db.syncStates)
      ..where((r) => r.userId.equals(userId) & r.source.equals(source));
  }

  Future<String?> getChangesToken(
      {required String userId, required String source}) async {
    return (await _rowFor(userId, source).getSingleOrNull())?.changesToken;
  }

  Future<void> saveChangesToken(
      {required String userId,
      required String source,
      required String token}) async {
    await _db.into(_db.syncStates).insertOnConflictUpdate(
          SyncStatesCompanion.insert(
            userId: userId,
            source: source,
            changesToken: Value(token),
            updatedAt: Value(DateTime.now()),
          ),
        );
  }

  Future<void> invalidateToken(
      {required String userId, required String source}) async {
    await (_db.update(_db.syncStates)
          ..where((r) => r.userId.equals(userId) & r.source.equals(source)))
        .write(const SyncStatesCompanion(changesToken: Value(null)));
  }

  Future<Uint8List?> getHkAnchor(
      {required String userId, required String source}) async {
    return (await _rowFor(userId, source).getSingleOrNull())?.hkAnchor;
  }

  Future<void> saveHkAnchor(
      {required String userId,
      required String source,
      required Uint8List anchor}) async {
    await _db.into(_db.syncStates).insertOnConflictUpdate(
          SyncStatesCompanion.insert(
            userId: userId,
            source: source,
            hkAnchor: Value(anchor),
            updatedAt: Value(DateTime.now()),
          ),
        );
  }

  Future<void> recordSyncAttempt(
      {required String userId,
      required String source,
      required bool success}) async {
    final existing = await _rowFor(userId, source).getSingleOrNull();
    final now = DateTime.now();
    final failures =
        success ? 0 : (existing?.consecutiveFailures ?? 0) + 1;
    await _db.into(_db.syncStates).insertOnConflictUpdate(
          SyncStatesCompanion.insert(
            userId: userId,
            source: source,
            lastAttemptAt: Value(now),
            lastSuccessfulAt:
                success ? Value(now) : Value(existing?.lastSuccessfulAt),
            consecutiveFailures: Value(failures),
            updatedAt: Value(now),
          ),
        );
  }
}
```

> Note: `$SyncStatesTable` and `SyncState` are generated by Task 1's build_runner run. If the editor flags them as undefined, re-run `dart run build_runner build --delete-conflicting-outputs`.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && flutter test test/sync_state_repository_test.dart`
Expected: PASS (all three tests).

- [ ] **Step 5: Commit**

```bash
git add app/lib/features/import/data/sync_state_repository.dart app/test/sync_state_repository_test.dart
git commit -m "feat(sync): add SyncStateRepository for delta cursors + run status"
```

---

### Task 3: `FeatureFlagService` + `app_config` Supabase migration

**Files:**
- Create: `app/lib/features/import/data/feature_flag_service.dart`
- Create: `supabase/migrations/<timestamp>_app_config.sql` (timestamp format `YYYYMMDDHHMMSS`, e.g. `20261030120000_app_config.sql`, matching existing migration filenames)
- Test: `app/test/feature_flag_service_test.dart`

**Interfaces:**
- Consumes: `shared_preferences`, optionally `SupabaseClient`.
- Produces: `FeatureFlagService({ConfigFetcher? fetchAutoSyncRow, SharedPreferences? prefs, SupabaseClient? client})`, where `typedef ConfigFetcher = Future<Map<String, dynamic>?> Function()`. Method `Future<bool> autoSyncEnabled()`. Static `const cacheKey = 'auto_sync_remote_enabled'`.

> **Testability note:** the production path reads `app_config` via Supabase, but mocking the Supabase query builder is painful. So `FeatureFlagService` accepts an injectable `fetchAutoSyncRow` returning the raw row map (`{'value': {...}}`). Production leaves it null and the service builds the Supabase query itself; tests inject a fake. This keeps the fail-safe logic unit-testable without a live client.

- [ ] **Step 1: Write the failing test**

Create `app/test/feature_flag_service_test.dart`:

```dart
import 'package:activefriends/features/import/data/feature_flag_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<FeatureFlagService> serviceWith(ConfigFetcher fetch) async {
    final prefs = await SharedPreferences.getInstance();
    return FeatureFlagService(fetchAutoSyncRow: fetch, prefs: prefs);
  }

  test('enabled=true is returned and cached', () async {
    final svc = await serviceWith(() async => {'value': {'enabled': true}});
    expect(await svc.autoSyncEnabled(), isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(FeatureFlagService.cacheKey), isTrue);
  });

  test('missing/null enabled → false (never accidentally on)', () async {
    final svc = await serviceWith(() async => {'value': <String, dynamic>{}});
    expect(await svc.autoSyncEnabled(), isFalse);
  });

  test('row absent → false', () async {
    final svc = await serviceWith(() async => null);
    expect(await svc.autoSyncEnabled(), isFalse);
  });

  test('fetch throws → falls back to cached last-known-good', () async {
    SharedPreferences.setMockInitialValues(
        {FeatureFlagService.cacheKey: true});
    final prefs = await SharedPreferences.getInstance();
    final svc = FeatureFlagService(
      fetchAutoSyncRow: () async => throw Exception('offline'),
      prefs: prefs,
    );
    expect(await svc.autoSyncEnabled(), isTrue); // last-known-good
  });

  test('fetch throws with NO cache → false (fail safe)', () async {
    final prefs = await SharedPreferences.getInstance();
    final svc = FeatureFlagService(
      fetchAutoSyncRow: () async => throw Exception('offline'),
      prefs: prefs,
    );
    expect(await svc.autoSyncEnabled(), isFalse);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/feature_flag_service_test.dart`
Expected: FAIL — `feature_flag_service.dart` not found.

- [ ] **Step 3: Write the implementation**

Create `app/lib/features/import/data/feature_flag_service.dart`:

```dart
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

typedef ConfigFetcher = Future<Map<String, dynamic>?> Function();

/// Supabase-controlled global kill switch for background auto-sync.
///
/// FAIL-SAFE: any error (offline, RLS, missing row, malformed value) resolves
/// to the last-known-good cached value, and to `false` when there is no cache.
/// Auto-sync never turns itself on by accident.
class FeatureFlagService {
  FeatureFlagService({
    ConfigFetcher? fetchAutoSyncRow,
    SharedPreferences? prefs,
    SupabaseClient? client,
  })  : _fetch = fetchAutoSyncRow,
        _prefs = prefs,
        _client = client;

  static const cacheKey = 'auto_sync_remote_enabled';

  final ConfigFetcher? _fetch;
  SharedPreferences? _prefs;
  final SupabaseClient? _client;

  Future<bool> autoSyncEnabled() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    try {
      final row = await (_fetch ?? _supabaseFetch)();
      final value = row?['value'];
      final enabled =
          (value is Map && value['enabled'] is bool) ? value['enabled'] as bool : false;
      await prefs.setBool(cacheKey, enabled);
      return enabled;
    } catch (_) {
      return prefs.getBool(cacheKey) ?? false;
    }
  }

  Future<Map<String, dynamic>?> _supabaseFetch() async {
    final client = _client ?? Supabase.instance.client;
    final row = await client
        .from('app_config')
        .select('value')
        .eq('key', 'auto_sync')
        .maybeSingle();
    return row;
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && flutter test test/feature_flag_service_test.dart`
Expected: PASS (all five tests).

- [ ] **Step 5: Write the Supabase migration**

Create `supabase/migrations/20261030120000_app_config.sql` (use the actual current UTC timestamp for the prefix):

```sql
-- Global app configuration (jsonb key/value), reusing the clubs.points_config idiom.
create table if not exists public.app_config (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now()
);

alter table public.app_config enable row level security;

-- Any authenticated client may READ config; writes are service-role only.
drop policy if exists "app_config readable by authenticated" on public.app_config;
create policy "app_config readable by authenticated"
  on public.app_config for select to authenticated using (true);

-- Background auto-sync global kill switch — ships OFF.
insert into public.app_config (key, value)
values ('auto_sync', '{"enabled": false}'::jsonb)
on conflict (key) do nothing;
```

- [ ] **Step 6: Commit**

```bash
git add app/lib/features/import/data/feature_flag_service.dart app/test/feature_flag_service_test.dart supabase/migrations/20261030120000_app_config.sql
git commit -m "feat(sync): add FeatureFlagService kill switch + app_config migration"
```

> **Deploy note (not a code step):** the migration is applied with `supabase db push` against the project when you're ready. Because the seeded value is `{"enabled": false}`, applying it early is safe — nothing turns on.

---

### Task 4: Extract `HealthSyncCore` (behaviour-preserving move)

**Files:**
- Create: `app/lib/features/import/data/health_sync_core.dart`
- Modify: `app/lib/features/import/data/health_import_service.dart` (delegate to core; relocate `chooseSourceAwareDistance`)
- Modify: `app/test/health_import_source_distance_test.dart` (re-point the static call target only)
- Create: `app/test/health_sync_core_test.dart` (move + extend the distance regression tests)

**Interfaces:**
- Consumes: `Health`, `SupabaseClient`, `LocalImportRepository`.
- Produces:
  - `class WorkoutWindow { final List<HealthDataPoint> workouts; final List<HealthDataPoint> distanceDeltas; final List<HealthDataPoint> heartRates; const WorkoutWindow({required this.workouts, required this.distanceDeltas, required this.heartRates}); }`
  - `enum SyncOutcome { imported, skippedOverlap, queued, alreadySynced }`
  - `class HealthSyncCore` with: `Future<WorkoutWindow> readWorkouts({required DateTime from, required DateTime to})`; `Future<Set<String>> existingExternalIds(String userId, String source, DateTime from, DateTime to)`; `Future<SyncOutcome> syncSingleActivity({required String userId, required String source, required HealthDataPoint workout, required WorkoutWindow window, required Set<String> existingExternalIds})`; `Future<void> syncPendingActivities()`; and the relocated `static ({double? distance, String decision}) chooseSourceAwareDistance({required Map<String, double> distanceBySource, required String ownerKey, required double? fallback})`.

> **This is a MOVE, not a rewrite.** The logic already exists and works in `health_import_service.dart`. Move it verbatim; change only what the new seams require (method boundaries, passing `WorkoutWindow` instead of relying on closure-captured lists). The existing regression tests are the gate — they must pass with identical fixtures and assertions.

- [ ] **Step 1: Create `HealthSyncCore` and move the shared logic**

Create `app/lib/features/import/data/health_sync_core.dart`. Move the following from `health_import_service.dart` **without changing behaviour**:
- The batched read + filtering (`getHealthDataFromTypes` + the `WORKOUT`/`HEART_RATE`/`DISTANCE_DELTA` partitioning, currently `health_import_service.dart:136-149`) → `readWorkouts`, returning a `WorkoutWindow`.
- The Supabase `existing external_id` lookup (`health_import_service.dart:151-172`) → `existingExternalIds`.
- The per-workout loop body (`health_import_service.dart:180-290`): the overlap guard (`_overlapsOutpaceActivity`), HR aggregation, `_computeSourceAwareDistance`, activity-map construction, `cacheActivity`, `flagDuplicateIfNeeded`, `_syncActivity`/`queueActivity` → `syncSingleActivity`, returning a `SyncOutcome`. It reads distance/HR from the passed `WorkoutWindow`, not from closure variables.
- `_overlapsOutpaceActivity`, `_computeSourceAwareDistance`, `_mapActivityType`, `_syncActivity`, `_syncPendingActivities` (→ public `syncPendingActivities`), and the `static chooseSourceAwareDistance` (move the static verbatim — same signature, same body).

Keep `_readTypes` / `_authTypes` with `readWorkouts` (they describe the read). Keep diagnostics writing in `HealthImportService` for now (Task is foundation; diagnostics are unchanged manual-path behaviour).

- [ ] **Step 2: Re-point the existing regression test to the new home**

In `app/test/health_import_source_distance_test.dart`, change the import and the 9 call sites from `HealthImportService.chooseSourceAwareDistance(` to `HealthSyncCore.chooseSourceAwareDistance(`. Change nothing else — same fixtures, same expected values.

```dart
// at top
import 'package:activefriends/features/import/data/health_sync_core.dart';
// (remove the health_import_service import if now unused)
```

Then in every `final r = HealthImportService.chooseSourceAwareDistance(` replace the class name with `HealthSyncCore`.

- [ ] **Step 3: Rewrite `importRecentWorkouts` to delegate**

In `health_import_service.dart`, make the manual import call the same core functions (so manual and background share one path). Replace the read + loop (lines ~136-296) with:

```dart
    final window = await _core.readWorkouts(from: importStart, to: now);
    final existingIds =
        await _core.existingExternalIds(user.id, source, importStart, now);

    var importedCount = 0, skippedCount = 0, queuedCount = 0, alreadySyncedCount = 0;
    for (final workout in window.workouts) {
      final outcome = await _core.syncSingleActivity(
        userId: user.id,
        source: source,
        workout: workout,
        window: window,
        existingExternalIds: existingIds,
      );
      switch (outcome) {
        case SyncOutcome.imported: importedCount++;
        case SyncOutcome.skippedOverlap: skippedCount++;
        case SyncOutcome.queued: queuedCount++;
        case SyncOutcome.alreadySynced: alreadySyncedCount++;
      }
    }

    await _localRepository.saveWatermark(
      userId: user.id, source: source, importedThrough: now,
    );
```

Add a `HealthSyncCore` field to `HealthImportService`, constructed from its existing `_health`, `_client`, `_localRepository`:

```dart
late final HealthSyncCore _core = HealthSyncCore(
  health: _health, client: _client, localRepository: _localRepository,
);
```

Keep the diagnostics block (distance_debug etc.) as-is — it now reads `window.distanceDeltas` instead of the old local `incrementalDistances`.

- [ ] **Step 4: Run the existing suite — the extraction gate**

Run: `cd app && flutter test`
Expected: PASS. In particular `test/health_import_source_distance_test.dart` passes **unchanged in fixtures/assertions** (only the class name moved). If any distance test fails, the move changed behaviour — revert and redo the move precisely.

- [ ] **Step 5: Analyze for dead code / type errors**

Run: `cd app && flutter analyze`
Expected: no new errors. (Remove any now-unused private members left behind in `health_import_service.dart`.)

- [ ] **Step 6: Commit**

```bash
git add app/lib/features/import/data/health_sync_core.dart app/lib/features/import/data/health_import_service.dart app/test/health_import_source_distance_test.dart app/test/health_sync_core_test.dart
git commit -m "refactor(import): extract HealthSyncCore shared by manual + background paths"
```

> `health_sync_core_test.dart` in this commit may simply re-export the moved regression cases if you prefer them to live beside the new class; if you keep them only in `health_import_source_distance_test.dart`, create `health_sync_core_test.dart` with at least one `WorkoutWindow` construction test so the file is not empty, or omit it from the `git add`.

---

### Task 5: `BackgroundSyncService` skeleton with flag gate

**Files:**
- Create: `app/lib/features/import/data/background_sync_service.dart`
- Test: `app/test/background_sync_service_test.dart`

**Interfaces:**
- Consumes: `HealthSyncCore`, `SyncOutcome`, `WorkoutWindow` (Task 4); `FeatureFlagService` (Task 3); `SyncStateRepository` (Task 2); `LocalImportRepository`; `AppDatabase`.
- Produces:
  - `class BackgroundSyncResult { final int imported, skipped, queued; final String? skippedReason; const BackgroundSyncResult({this.imported = 0, this.skipped = 0, this.queued = 0, this.skippedReason}); const BackgroundSyncResult.skippedReason(String reason) : imported = 0, skipped = 0, queued = 0, skippedReason = reason; }`
  - `class BackgroundSyncService` with constructor `BackgroundSyncService({required FeatureFlagService flags, HealthSyncCore? core, LocalImportRepository? localRepository, SyncStateRepository? syncStateRepository})` — collaborators nullable and accessed **only after** the flag gate passes; factory `BackgroundSyncService.forBackgroundIsolate()`; factory `BackgroundSyncService.forTest({required FeatureFlagService flags})`; `Future<BackgroundSyncResult> syncIncremental({required String userId})`.

> This task delivers the **flag gate and orchestration shell**, which is the device-independent, testable part. The platform delta sources (`_resolveChangedIds` for Android `health.getChanges`, iOS `HKAnchoredObjectQuery`) and cursor persistence are stubbed to "rescan all" here and completed in Plans 2 (iOS) and 3 (Android). The 30-day-rescan fallback keeps it correct even with the stub.

- [ ] **Step 1: Write the failing test**

Create `app/test/background_sync_service_test.dart`:

```dart
import 'package:activefriends/features/import/data/background_sync_service.dart';
import 'package:activefriends/features/import/data/feature_flag_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('flag OFF → returns skipped(flag_off) without syncing', () async {
    final prefs = await SharedPreferences.getInstance();
    final flags = FeatureFlagService(
      fetchAutoSyncRow: () async => {'value': {'enabled': false}},
      prefs: prefs,
    );
    final svc = BackgroundSyncService.forTest(flags: flags);

    final result = await svc.syncIncremental(userId: 'u1');

    expect(result.skippedReason, 'flag_off');
    expect(result.imported, 0);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/background_sync_service_test.dart`
Expected: FAIL — `background_sync_service.dart` not found.

- [ ] **Step 3: Write the implementation**

Create `app/lib/features/import/data/background_sync_service.dart`:

```dart
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
```

> **Why collaborators are nullable:** the flag-off path returns before any of
> them is touched, so the unit test constructs with only `flags` and avoids
> `Supabase.instance.client` (which throws when Supabase is not initialised, as
> in `flutter test`). `forBackgroundIsolate()` always supplies non-null
> collaborators, so the `!` assertions never fire in production.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && flutter test test/background_sync_service_test.dart`
Expected: PASS — returns `skippedReason == 'flag_off'`.

- [ ] **Step 5: Confirm full suite + analyze**

Run: `cd app && flutter test && flutter analyze`
Expected: all tests PASS; no new analyzer errors.

- [ ] **Step 6: Commit**

```bash
git add app/lib/features/import/data/background_sync_service.dart app/test/background_sync_service_test.dart
git commit -m "feat(sync): add BackgroundSyncService shell with fail-safe flag gate"
```

---

## Out of Scope (follow-on plans)

These are intentionally **not** in this plan — they need on-device testing and build on this foundation:

- **Plan 2 — iOS background delivery:** `Runner.entitlements` background-delivery entitlement; `AppDelegate.swift` `HKObserverQuery` + `enableBackgroundDelivery` integrated with the existing `FlutterImplicitEngineDelegate`/`engineBridge`; iOS-only `app.activefriends.app/health_sync` Method Channel → Dart `onHealthDataChanged`; `HKAnchoredObjectQuery` delta + anchor persistence filling `_resolveChangedIds`.
- **Plan 3 — Android WorkManager + Changes API:** `READ_HEALTH_DATA_IN_BACKGROUND` manifest permission; `workmanager` dependency; `callbackDispatcher` + `_executeBackgroundHealthSync` in `main.dart` with the flag gate + `cancelByUniqueName` teardown; `health.getChangesToken`/`getChanges` wired into `_resolveChangedIds`; background isolate using `BackgroundSyncService.forBackgroundIsolate()`.
- **Plan 4 — UX & polish:** auto-sync toggle (two-gate AND with the remote flag), "last synced X ago", local notification + `outpace_sync` channel, startup flag resolution + teardown-on-off, background-sync diagnostics.

---

## Self-Review

**Spec coverage (Foundation subset of the spec):**
- §5.2 `SyncState` table + v5→v6 migration → Task 1 ✓ (corrected: inline in `app_database.dart`, not a `tables/` dir).
- §5.3 `SyncStateRepository` → Task 2 ✓.
- §5.4 Feature flag + `app_config` migration → Task 3 ✓ (fail-safe, cache, RLS, seed off).
- §9 `HealthSyncCore` extraction + `WorkoutWindow` coupling + test gate → Task 4 ✓.
- §5.1 `BackgroundSyncService` + `forBackgroundIsolate` + flag gate + 30-day fallback → Task 5 ✓.
- iOS §3 / Android §4 / UX §6–§7 → explicitly deferred to Plans 2–4 ✓.

**Placeholder scan:** No "TBD/TODO" tasks. The two `>`-noted caveats (Task 4 optional test file, Task 5 `forTest` seam) are honest limitations with concrete instructions, not deferred work.

**Type consistency:** `WorkoutWindow`, `SyncOutcome`, `HealthSyncCore.chooseSourceAwareDistance`, `SyncStatesCompanion`, `FeatureFlagService.cacheKey`/`ConfigFetcher`, `BackgroundSyncResult.skippedReason` are defined once and referenced consistently across tasks.
