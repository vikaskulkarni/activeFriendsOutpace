# SPEC: Background Auto-Sync from Health Connect & HealthKit

| Field           | Value                                             |
|-----------------|---------------------------------------------------|
| **Status**      | Draft                                             |
| **Author**      | Vikas Kulkarni                                    |
| **Created**     | 2026-10-30                                        |
| **App version** | 1.0.0+22                                          |
| **Platforms**   | Android (API 26+), iOS 15+                        |
| **Priority**    | P1 — Quality-of-life feature, high user impact    |

> **Revision 2 (2026-10-30):** Corrected against the actual codebase after an
> implementation-readiness review. Key changes: Android no longer needs a native
> Kotlin Changes-API bridge (the `health` 13.3.2 package already exposes it); the
> whole feature ships behind a Supabase-controlled global kill switch
> (`app_config.auto_sync`, default **off**); shared read/upsert logic is extracted
> so the manual and background paths run the *same* code; and the background
> lookback no longer narrows the window in a way that drops late-syncing watch
> activities. See §4, §5.1, §5.2, §5.4, §9.

---

## 1. Overview

### 1.1 Problem Statement

Outpace currently supports importing workouts from Health Connect (Android) and HealthKit (iOS) via a **manual "Import" button** in the UI (`WatchImportSection`). The user must:

1. Open Outpace
2. Navigate to the import section
3. Tap "Import"
4. Wait for the 30-day lookback scan to complete

This creates friction, especially for users with wearables (Garmin, Apple Watch, Samsung Galaxy Watch) that auto-sync to Health Connect / HealthKit. The expected behavior — analogous to Garmin → Strava auto-sync — is that activities appear in Outpace automatically without user intervention.

### 1.2 Goal

Implement **automatic background synchronization** so that when a wearable syncs new workout data into Health Connect or HealthKit, Outpace detects the change and imports the workout(s) — without the user opening the app or tapping any button.

### 1.3 Non-Goals

- Writing data back to Health Connect / HealthKit (Outpace is read-only)
- Real-time sub-second sync (best-effort latency of seconds to minutes is acceptable)
- Background GPS tracking (separate feature, already implemented)
- Replacing the manual import button (it remains as a fallback and first-time trigger)
- Shipping auto-sync unconditionally — the entire feature is gated behind a remote kill switch (§5.4) and is **off by default**

### 1.4 Success Criteria

| Metric                                   | Target                                          |
|------------------------------------------|------------------------------------------------|
| Background sync fires after Garmin sync  | Within 1 min (iOS), within 15 min (Android)    |
| New workout appears in Outpace feed      | Without user opening the app                    |
| Battery impact                           | < 1% per day attributable to background sync    |
| No duplicate activities created          | Existing dedup logic handles re-scans           |
| Offline resilience                       | Queued locally, synced on next connectivity     |

---

## 2. Architecture

### 2.1 High-Level Flow

```
┌──────────────┐     ┌───────────────────────┐     ┌──────────────────┐
│   Wearable   │────▶│  Health Connect (A)    │────▶│   Outpace        │
│  (Garmin,    │     │  HealthKit      (iOS)  │     │   Background     │
│   Apple Watch│     │                        │     │   Sync Worker    │
│   etc.)      │     │  New WORKOUT record    │     │                  │
└──────────────┘     │  written               │     │  1. Detect change│
                     └───────────────────────┘     │  2. Read workouts│
                                                    │  3. Dedup        │
                                                    │  4. Upsert to    │
                                                    │     Supabase     │
                                                    │  5. Local notify │
                                                    └──────────────────┘
```

### 2.2 Platform Strategy Summary

| Aspect                  | iOS (HealthKit)                                | Android (Health Connect)                        |
|-------------------------|------------------------------------------------|------------------------------------------------|
| **Trigger mechanism**   | Push — `HKObserverQuery` with background delivery | Poll — `WorkManager` periodic task              |
| **Latency**             | Near real-time (seconds to low minutes)        | Up to 15 minutes (WorkManager minimum interval) |
| **Incremental strategy**| `HKAnchoredObjectQuery` with persisted anchor  | Changes API with persisted `ChangesToken`       |
| **Permission required** | `com.apple.developer.healthkit.background-delivery` entitlement | `READ_HEALTH_DATA_IN_BACKGROUND` runtime permission |
| **Background runtime**  | ~30s per wake (sufficient for workout sync)    | ~10 min (WorkManager default limit)             |
| **Survives force-quit** | No — delivery stops until next launch          | Yes — WorkManager persists across reboots       |
| **Flutter integration** | Native Swift via Method Channel                | `workmanager` + `health` package (no custom Kotlin)   |

### 2.3 Component Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                        Flutter Layer                         │
│                                                              │
│  ┌──────────────────────┐    ┌─────────────────────────┐    │
│  │ HealthImportService  │    │ BackgroundSyncService    │    │
│  │ (existing — manual)  │    │ (NEW — orchestrator)     │    │
│  └──────────┬───────────┘    └────────┬────────────────┘    │
│             │                         │                      │
│             │    ┌────────────────────┘                      │
│             ▼    ▼                                           │
│  ┌─────────────────────────┐                                │
│  │ HealthSyncCore          │  ← shared logic extracted from │
│  │ (NEW — platform-agnostic│    HealthImportService          │
│  │  read + upsert logic)   │                                │
│  └──────────┬──────────────┘                                │
│             │                                                │
│  ┌──────────▼──────────────┐    ┌─────────────────────┐    │
│  │ LocalImportRepository   │    │ SyncStateRepository  │    │
│  │ (existing)              │    │ (NEW — tokens/anchors│    │
│  └─────────────────────────┘    └─────────────────────┘    │
│                                                              │
├──────────────────────────────────────────────────────────────┤
│                     Method Channel                            │
│              "app.activefriends.app/health_sync"             │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌─────────────────────┐      ┌────────────────────────┐   │
│  │ iOS Native (Swift)  │      │ Android Native (Kotlin)│   │
│  │                     │      │                        │   │
│  │ • HKObserverQuery   │      │ • WorkManager setup    │   │
│  │ • Background        │      │ • HealthConnectWorker  │   │
│  │   Delivery           │      │ • Changes API          │   │
│  │ • HKAnchoredObject  │      │ • Background Read      │   │
│  │   Query             │      │   Permission           │   │
│  └─────────────────────┘      └────────────────────────┘   │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

> **Correction to the Android column of this diagram:** Android needs **no custom
> native Kotlin**. The Changes API and background-read permission are used
> directly through the `health` package (v13.3.2). The only native/Method-Channel
> bridge is on **iOS** (HKObserver → Dart). See §4.4.

---

## 3. Detailed Design — iOS

### 3.1 Entitlements & Capabilities

**File: `ios/Runner/Runner.entitlements`**

Add the background delivery entitlement:

```xml
<key>com.apple.developer.healthkit.background-delivery</key>
<true/>
```

**File: `ios/Runner/Info.plist`**

> **Correction:** Do **not** add `processing` to `UIBackgroundModes`. That mode is
> for `BGTaskScheduler`/`BGProcessingTask`, which this design does not use — iOS
> wake-ups come from HealthKit **background delivery** (§3.2), which needs only the
> `background-delivery` entitlement, not a background mode. Adding an unused
> `processing` mode is dead config and an avoidable App Review question. Leave
> `UIBackgroundModes` as-is (`remote-notification`, `location`).

Update the health usage description:

```xml
<key>NSHealthShareUsageDescription</key>
<string>Outpace reads your workouts to sync your activity feed automatically.</string>
```

### 3.2 Observer Query Registration

**File: `ios/Runner/AppDelegate.swift`**

Add HealthKit observer registration at launch — this is the **earliest possible point** and is required by Apple's documentation.

```swift
import HealthKit

// At class level:
private let healthStore = HKHealthStore()

override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
) -> Bool {
    FirebaseApp.configure()
    UNUserNotificationCenter.current().delegate = self
    application.registerForRemoteNotifications()

    // ── NEW: HealthKit background observer ──
    if HKHealthStore.isHealthDataAvailable() {
        registerHealthKitObservers()
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
}

private func registerHealthKitObservers() {
    guard let workoutType = HKObjectType.workoutType() else { return }

    // 1. Create observer query — fires on any workout insert/delete
    let observerQuery = HKObserverQuery(
        sampleType: workoutType,
        predicate: nil
    ) { [weak self] query, completionHandler, error in
        guard error == nil else {
            completionHandler()
            return
        }

        // 2. Trigger the Dart-side sync via Method Channel
        self?.triggerDartSync {
            // 3. MUST call completion handler — Apple requires this
            completionHandler()
        }
    }

    healthStore.execute(observerQuery)

    // 4. Enable background delivery — wakes app when new workouts arrive
    healthStore.enableBackgroundDelivery(
        for: workoutType,
        frequency: .immediate
    ) { success, error in
        if let error = error {
            print("[HealthSync] Background delivery registration failed: \(error)")
        }
    }
}
```

### 3.3 Dart Method Channel Bridge (iOS)

The observer callback invokes Dart over the **existing** Flutter engine. This app
uses the new implicit-engine embedding (`AppDelegate` conforms to
`FlutterImplicitEngineDelegate` and plugins register against
`engineBridge.pluginRegistry` — see `ios/Runner/AppDelegate.swift`), so do **not**
reach for `self.window?.rootViewController as? FlutterViewController`; hold a
reference to the implicit engine's `binaryMessenger` captured during
`didFinishLaunchingWithOptions` and build the channel from that.

```swift
// Captured when the implicit engine is available (see existing engineBridge setup).
private var healthSyncMessenger: FlutterBinaryMessenger?

private func triggerDartSync(completion: @escaping () -> Void) {
    DispatchQueue.main.async {
        guard let messenger = self.healthSyncMessenger else {
            // Engine not up yet (cold wake) — let background delivery re-fire;
            // the delta is preserved by the persisted HKQueryAnchor (§3.4).
            completion()
            return
        }
        let channel = FlutterMethodChannel(
            name: "app.activefriends.app/health_sync",
            binaryMessenger: messenger
        )
        channel.invokeMethod("onHealthDataChanged", arguments: nil) { _ in
            completion()  // Apple requires the completion handler be called.
        }
    }
}
```

> **Dropped: the headless-engine strategy.** The original draft spun up a second
> `FlutterEngine` running a `backgroundSyncEntrypoint` when the app was suspended.
> We do not do this: there is no such Dart entrypoint, booting a second engine +
> Supabase init inside HealthKit's ~30 s background-delivery budget is wasteful and
> flaky, and background delivery already wakes the existing engine. Because the
> `HKQueryAnchor` is persisted (§3.4), any wake we cannot service immediately is
> picked up on the next one — no data is lost. If the engine proves reliably
> unavailable at wake time in testing, fall back to the Android-style approach
> (schedule a catch-up sync on next foreground) rather than a headless engine.

### 3.4 Anchored Object Query (Incremental Reads)

Instead of the current 30-day full rescan, the background worker uses `HKAnchoredObjectQuery` with a persisted anchor for efficient delta reads.

**Persist anchor**: Serialize `HKQueryAnchor` to `UserDefaults` (or pass to Dart side for SQLite storage).

```swift
func fetchNewWorkouts(since anchor: HKQueryAnchor?, completion: @escaping ([HKWorkout], HKQueryAnchor?) -> Void) {
    let workoutType = HKObjectType.workoutType()
    let query = HKAnchoredObjectQuery(
        type: workoutType,
        predicate: nil,
        anchor: anchor,
        limit: HKObjectQueryNoLimit
    ) { query, added, deleted, newAnchor, error in
        let workouts = (added ?? []).compactMap { $0 as? HKWorkout }
        completion(workouts, newAnchor)
    }
    healthStore.execute(query)
}
```

### 3.5 iOS Flow Summary

```
App Launch
    │
    ├── registerHealthKitObservers()
    │       │
    │       ├── HKObserverQuery(workoutType) → registered
    │       └── enableBackgroundDelivery(.immediate) → registered
    │
    ▼
[App goes to background / suspended]
    │
    ▼
Garmin Connect syncs → HealthKit receives new ExerciseSession
    │
    ▼
iOS wakes Outpace (background delivery)
    │
    ├── Observer callback fires
    │       │
    │       ├── triggerDartSync() via Method Channel
    │       │       │
    │       │       ├── BackgroundSyncService.syncIncremental()
    │       │       │       │
    │       │       │       ├── Read anchor from SyncStateRepository
    │       │       │       ├── HKAnchoredObjectQuery (delta)
    │       │       │       ├── Map workouts → activity payloads
    │       │       │       ├── Dedup (existing logic)
    │       │       │       ├── Upsert to Supabase (or queue locally)
    │       │       │       ├── Save new anchor
    │       │       │       └── (Optional) Show local notification
    │       │       │
    │       │       └── Return result to Swift
    │       │
    │       └── Call completionHandler() ← CRITICAL
    │
    ▼
[App returns to suspended state]
```

---

## 4. Detailed Design — Android

### 4.1 Permissions

**File: `android/app/src/main/AndroidManifest.xml`**

Add background read permission:

```xml
<!-- NEW: Background health data access -->
<uses-permission android:name="android.permission.health.READ_HEALTH_DATA_IN_BACKGROUND" />
```

### 4.2 Background Read Permission Request

The background read permission requires **explicit user consent** via the Health Connect permissions UI. This should be requested:

- **When**: After the user completes their first successful manual import (they've already granted foreground read permissions)
- **Where**: In a dedicated settings toggle or a post-import prompt
- **How**: Directly via the `health` package — **v13.3.2 already exposes these
  methods natively**, no custom Kotlin required:

```dart
// In Dart — check and request background read (health 13.3.2 API).
Future<bool> requestBackgroundReadPermission() async {
  if (!Platform.isAndroid) return true; // iOS uses entitlements, not runtime

  // 1. Device/HC support for the background-read feature.
  if (!await _health.isHealthDataInBackgroundAvailable()) return false;

  // 2. Already granted?
  if (await _health.isHealthDataInBackgroundAuthorized()) return true;

  // 3. Request it (opens the Health Connect permission UI).
  return await _health.requestHealthDataInBackgroundAuthorization();
}
```

> **Verified against source:** `isHealthDataInBackgroundAvailable()`,
> `isHealthDataInBackgroundAuthorized()`, and
> `requestHealthDataInBackgroundAuthorization()` all exist in
> `health-13.3.2/lib/src/health_plugin.dart`. The earlier draft's
> `HealthConnectFeature.READ_HEALTH_DATA_IN_BACKGROUND` +
> `requestAuthorization(permissions:)` sample was incorrect and would not compile.

### 4.3 WorkManager Setup

**New dependency in `pubspec.yaml`:**

```yaml
dependencies:
  workmanager: ^0.6.0
```

**Dart-side initialization in `main.dart`:**

```dart
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    switch (taskName) {
      case 'healthSyncPeriodic':
        return await _executeBackgroundHealthSync();
      default:
        return Future.value(true);
    }
  });
}

Future<bool> _executeBackgroundHealthSync() async {
  try {
    // 1. Initialize dependencies (background isolate has no prior state)
    WidgetsFlutterBinding.ensureInitialized();
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    if (SupabaseConfig.isConfigured) {
      await Supabase.initialize(
        url: SupabaseConfig.url,
        publishableKey: SupabaseConfig.publishableKey,
      );
    }

    // 2. Check for authenticated session
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return true; // No session — skip silently

    // 3. Remote kill switch (§5.4). Fail-safe: off unless explicitly enabled.
    //    If disabled, tear down this periodic task so the OS stops waking us.
    if (!await FeatureFlagService().autoSyncEnabled()) {
      await Workmanager().cancelByUniqueName('healthSyncPeriodic');
      return true;
    }

    // 4. Run incremental sync. BackgroundSyncService opens its OWN Drift
    //    connection for this isolate (never AppDatabase.shared — see §5.1).
    final syncService = BackgroundSyncService.forBackgroundIsolate();
    await syncService.syncIncremental(userId: user.id);

    return true; // success
  } catch (e) {
    developer.log('Background health sync failed: $e', name: 'HealthSync');
    return false; // will be retried by WorkManager
  }
}
```

**Registration (call once after first successful manual import):**

```dart
Future<void> registerPeriodicSync() async {
  await Workmanager().initialize(callbackDispatcher, isInDebugMode: false);
  await Workmanager().registerPeriodicTask(
    'healthSyncPeriodic',                     // uniqueName
    'healthSyncPeriodic',                     // taskName
    frequency: const Duration(minutes: 15),   // minimum allowed
    constraints: Constraints(
      networkType: NetworkType.connected,      // need network for Supabase
      requiresBatteryNotLow: true,            // respect battery
    ),
    existingWorkPolicy: ExistingWorkPolicy.keep, // don't duplicate
    backoffPolicy: BackoffPolicy.exponential,
    initialDelay: const Duration(minutes: 1),
  );
}
```

### 4.4 Changes API Integration (Incremental Reads)

The Changes API provides a token-based delta mechanism. **No native Kotlin is
required** — the `health` package (v13.3.2) exposes it directly, verified in
`health-13.3.2/lib/src/health_plugin.dart`:

- `getChangesToken({required List<HealthDataType> types})` → opaque token string
- `getChanges({required String changesToken})` → `HealthChangesResponse`, with
  `changes`, `nextChangesToken`, `hasMore`, `changesTokenExpired`, and the
  convenience getters `upsertedDataPoints` and `deletedRecordIds`

So the original draft's `HealthSyncPlugin.kt`, the custom
`app.activefriends.app/health_sync` **Android** channel, and the `MainActivity.kt`
registration are all **removed from scope**. (The Method Channel named in §2.3 is
iOS-only — it bridges the HKObserver callback to Dart; Android needs no channel.)

Dart-side delta read, used by `BackgroundSyncService` (§5.1):

```dart
Future<_ChangesResult> _readAndroidChanges(String token) async {
  final resp = await _health.getChanges(changesToken: token);
  if (resp == null || resp.changesTokenExpired) {
    return _ChangesResult.expired();   // caller falls back to 30-day rescan
  }
  return _ChangesResult(
    upsertedIds: resp.upsertedDataPoints.map((p) => p.uuid).toSet(),
    deletedIds: resp.deletedRecordIds.toSet(),
    nextToken: resp.nextChangesToken,
    hasMore: resp.hasMore,
  );
}
```

> **Why still fetch a window?** `getChanges` tells you *which* records changed, but
> the authoritative walk/run distance is computed from **all** in-window
> `DISTANCE_DELTA` records grouped by source (§9 / `chooseSourceAwareDistance`).
> Reading changed records in isolation would strip that context and re-introduce
> the `ceb118c` double-distance bug. The delta is used to decide *whether* to sync
> and to bound the window, not to bypass the source-aware distance step.

### 4.5 Android Flow Summary

```
First Manual Import succeeds
    │
    ├── Request READ_HEALTH_DATA_IN_BACKGROUND (health pkg, §4.2)
    ├── Get initial ChangesToken (health.getChangesToken) → persist to SyncState
    └── Register WorkManager periodic task (15 min)
    │
    ▼
[Every ~15 minutes — WorkManager fires]
    │
    ├── callbackDispatcher() → _executeBackgroundHealthSync()
    │       │
    │       ├── Initialize Firebase, Supabase (background isolate)
    │       ├── Check authenticated session (skip if none)
    │       ├── Remote kill switch (§5.4): if OFF → cancel task, exit
    │       │
    │       ├── BackgroundSyncService.syncIncremental()  [own Drift connection]
    │       │       │
    │       │       ├── Drain pending offline queue first
    │       │       ├── Read ChangesToken from SyncState
    │       │       ├── health.getChanges(token)
    │       │       │       ├── expired/absent → FULL 30-day rescan
    │       │       │       │     (NOT a 1h/24h window — late-syncing
    │       │       │       │      watches backfill older timestamps)
    │       │       │       └── valid → changed ID set + nextToken
    │       │       │
    │       │       ├── readWorkouts(from, to) ← workouts AND the window's
    │       │       │     DISTANCE_DELTA + HEART_RATE batches (§9)
    │       │       ├── For each changed workout:
    │       │       │       └── syncSingleActivity(...) ← SAME core fn as
    │       │       │             manual import: overlap dedup, source-aware
    │       │       │             distance, local dedup, upsert/queue
    │       │       │
    │       │       ├── Save nextChangesToken + ImportWatermark
    │       │       └── (Optional) local notification on new imports
    │       │
    │       └── Return true/false to WorkManager
    │
    ▼
[WorkManager reschedules for next interval]
```

---

## 5. Shared Flutter Layer — `BackgroundSyncService`

### 5.1 New Class: `BackgroundSyncService`

**File: `lib/features/import/data/background_sync_service.dart`** (NEW)

This class extracts the reusable sync logic from `HealthImportService` and adds incremental support.

```dart
class BackgroundSyncService {
  BackgroundSyncService({
    required HealthSyncCore core,
    Health? health,
    SupabaseClient? client,
    LocalImportRepository? localRepository,
    SyncStateRepository? syncStateRepository,
    FeatureFlagService? flags,
  }) : _core = core,
       _health = health ?? Health(),
       _client = client ?? Supabase.instance.client,
       _localRepository = localRepository ?? LocalImportRepository(AppDatabase.shared),
       _syncStateRepository = syncStateRepository ?? SyncStateRepository(AppDatabase.shared),
       _flags = flags ?? FeatureFlagService();

  /// Factory for the WorkManager background isolate. The isolate does NOT share
  /// the main isolate's `AppDatabase.shared` singleton; it opens its own Drift
  /// connection to the same file. Using `.shared` here would reference an
  /// uninitialised static in the fresh isolate and crash — this is the §11
  /// "High" risk, resolved here rather than merely noted.
  factory BackgroundSyncService.forBackgroundIsolate() {
    final db = AppDatabase(); // fresh connection for THIS isolate
    final local = LocalImportRepository(db);
    final syncState = SyncStateRepository(db);
    return BackgroundSyncService(
      core: HealthSyncCore(
        health: Health(),
        client: Supabase.instance.client,
        localRepository: local,
      ),
      localRepository: local,
      syncStateRepository: syncState,
    );
  }

  final HealthSyncCore _core;
  final Health _health;
  final SupabaseClient _client;
  final LocalImportRepository _localRepository;
  final SyncStateRepository _syncStateRepository;
  final FeatureFlagService _flags;

  /// Incremental background sync. Called from:
  /// - iOS: HKObserverQuery callback via the iOS Method Channel
  /// - Android: WorkManager periodic task
  Future<BackgroundSyncResult> syncIncremental({required String userId}) async {
    // 0. Remote kill switch (§5.4). Fail-safe: disabled unless explicitly on.
    if (!await _flags.autoSyncEnabled()) {
      return BackgroundSyncResult.skipped(reason: 'flag_off');
    }

    final source = Platform.isIOS ? 'healthkit' : 'health_connect';

    // 1. Drain any pending offline syncs first (reuses HealthSyncCore).
    await _core.syncPendingActivities();

    // 2. Determine the read window.
    //    - Android: ask the Changes API what changed; expired/absent → full
    //      30-day rescan (NOT a 1h/24h window — a watch may backfill an
    //      activity with a timestamp hours older than the last sync, which a
    //      narrow window silently drops; the manual path already guards against
    //      this, see health_import_service.dart:129-135).
    //    - iOS: HKAnchoredObjectQuery delta; no anchor → 30-day rescan.
    final now = DateTime.now();
    final from = now.subtract(const Duration(days: 30));

    // 3. Read workouts PLUS the window's DISTANCE_DELTA + HEART_RATE batches
    //    together, so source-aware distance keeps its cross-source context
    //    (§9). Then upsert each via the SAME core function manual import uses.
    final window = await _core.readWorkouts(from: from, to: now);
    final changedIds = await _resolveChangedIds(userId, source); // null ⇒ all
    final existingIds = await _core.existingExternalIds(userId, source, from, now);

    var imported = 0, skipped = 0, queued = 0;
    for (final workout in window.workouts) {
      if (changedIds != null && !changedIds.contains(workout.uuid)) continue;
      final outcome = await _core.syncSingleActivity(
        userId: userId,
        source: source,
        workout: workout,
        window: window,                 // carries DISTANCE_DELTA + HR batches
        existingExternalIds: existingIds,
      );
      switch (outcome) {
        case SyncOutcome.imported: imported++;
        case SyncOutcome.skippedOverlap: skipped++;
        case SyncOutcome.queued: queued++;
        case SyncOutcome.alreadySynced: break;
      }
    }

    // 4. Persist delta cursor (SyncState) + watermark (existing ImportWatermarks).
    await _persistCursor(userId, source);
    await _localRepository.saveWatermark(
      userId: userId, source: source, importedThrough: now,
    );
    return BackgroundSyncResult(imported: imported, skipped: skipped, queued: queued);
  }

  // _resolveChangedIds: Android → health.getChanges(token) ids (null on expiry
  //   to force full rescan); iOS → ids from HKAnchoredObjectQuery via channel.
  // _persistCursor: save nextChangesToken (Android) / HKQueryAnchor (iOS).
}
```

### 5.2 New Table: `SyncState`

**File: `lib/data/local/tables/sync_state.dart`** (NEW)

```dart
class SyncState extends Table {
  TextColumn     get userId           => text()();
  TextColumn     get source           => text()();
  TextColumn     get changesToken     => text().nullable()();  // Android Changes API
  BlobColumn     get hkAnchor         => blob().nullable()();  // iOS HKQueryAnchor
  DateTimeColumn get lastSuccessfulAt => dateTime().nullable()();
  DateTimeColumn get lastAttemptAt    => dateTime().nullable()();
  IntColumn      get consecutiveFailures => integer().withDefault(const Constant(0))();
  DateTimeColumn get updatedAt        => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {userId, source};
}
```

**Schema migration**: v5 → v6 — add `SyncState` table. Confirmed: current
`schemaVersion` is **5** (`app_database.dart:100`), so v6 is the correct next
version; add it to the existing `onUpgrade` ladder.

> **Relationship to the existing `ImportWatermarks` table.** `SyncState` holds
> **delta cursors and run status only** — `changesToken` (Android), `hkAnchor`
> (iOS), and the wall-clock `lastSuccessfulAt` / `lastAttemptAt` /
> `consecutiveFailures` used for the "last synced X ago" UI (§6.1) and the §8.2
> backoff. It does **not** store a data-coverage watermark; that stays in the
> existing `ImportWatermarks` (`importedThrough`), written via
> `LocalImportRepository.saveWatermark`. There is deliberately **one** watermark
> system. `lastSuccessfulAt` is a *run* timestamp and is **never** used to narrow
> the read window — the window is delta-cursor-driven with a full 30-day rescan
> fallback (§5.1).

### 5.3 SyncStateRepository

**File: `lib/features/import/data/sync_state_repository.dart`** (NEW)

```dart
class SyncStateRepository {
  SyncStateRepository(this._database);
  final AppDatabase _database;

  Future<bool> hasChangesToken({
    required String userId,
    required String source,
  }) async { /* query SyncState */ }

  Future<String?> getChangesToken({
    required String userId,
    required String source,
  }) async { /* query SyncState */ }

  Future<void> saveChangesToken({
    required String userId,
    required String source,
    required String token,
  }) async { /* upsert SyncState */ }

  Future<Uint8List?> getHkAnchor({
    required String userId,
    required String source,
  }) async { /* query SyncState */ }

  Future<void> saveHkAnchor({
    required String userId,
    required String source,
    required Uint8List anchor,
  }) async { /* upsert SyncState */ }

  Future<DateTime?> lastSuccessfulSync({
    required String userId,
    required String source,
  }) async { /* query SyncState */ }

  Future<void> recordSyncAttempt({
    required String userId,
    required String source,
    required bool success,
  }) async { /* update lastAttempt, lastSuccessful, consecutiveFailures */ }

  Future<void> invalidateToken({
    required String userId,
    required String source,
  }) async { /* set changesToken = null to force fallback */ }
}
```

### 5.4 Feature Flag & Remote Kill Switch (`app_config.auto_sync`)

The **entire** feature is gated behind a single global boolean controlled from
Supabase, so it can be disabled fleet-wide without an app release. It ships
**off**.

**Supabase migration (new):**

```sql
create table public.app_config (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.app_config enable row level security;

-- Any authenticated client may read config; writes are service-role only.
create policy "app_config readable by authenticated"
  on public.app_config for select to authenticated using (true);

insert into public.app_config (key, value)
values ('auto_sync', '{"enabled": false}'::jsonb)
on conflict (key) do nothing;
```

This reuses the project's existing jsonb-config idiom (`clubs.points_config`).
Flipping the switch is one row update:
`update public.app_config set value = '{"enabled": true}' where key = 'auto_sync';`.

**`FeatureFlagService` (new, Dart):**

```dart
class FeatureFlagService {
  FeatureFlagService({SupabaseClient? client, SharedPreferences? prefs});

  static const _kCacheKey = 'auto_sync_remote_enabled';

  /// Resolves the global kill switch. FAIL-SAFE: on any error (offline, RLS,
  /// row missing) return the last-known-good cached value, and if there is no
  /// cache, return FALSE. Auto-sync never turns itself on by accident.
  Future<bool> autoSyncEnabled() async {
    try {
      final row = await _client
          .from('app_config').select('value').eq('key', 'auto_sync').maybeSingle();
      final enabled = (row?['value']?['enabled'] as bool?) ?? false;
      await _prefs.setBool(_kCacheKey, enabled);   // cache last-known-good
      return enabled;
    } catch (_) {
      return _prefs.getBool(_kCacheKey) ?? false;  // fail safe → off
    }
  }
}
```

**Two gates, AND'd.** Auto-sync runs only when
`remote.autoSyncEnabled() && userToggle` (the §6.1 per-user toggle). The remote
switch always wins — a user cannot force it on while ops has it off.

**Enforcement points:**

| When | Action |
|------|--------|
| App startup (foreground, after `Supabase.initialize`) | Resolve flag; if off, ensure workers are torn down (below). |
| WorkManager wake (`_executeBackgroundHealthSync`, §4.3) | Resolve flag at entry; if off, `cancelByUniqueName('healthSyncPeriodic')` and return. |
| iOS observer callback → `syncIncremental` | Resolve flag at entry; if off, skip and (on next foreground) disable HK background delivery. |

**Teardown on "off" (critical).** A disabled flag must *stop the OS waking the
app*, not merely no-op. When the flag resolves false while workers are
registered: Android cancels the WorkManager unique task; iOS calls
`disableBackgroundDelivery(for: workoutType)` on next foreground launch (a
suspended app cannot act on a remote change until it next runs). This protects
the §1.4 battery budget when the switch is thrown during an incident.

---

## 6. User-Facing Settings & Permissions Flow

### 6.1 Settings UI

Add a toggle in the import section or app settings:

```
┌─────────────────────────────────────────────┐
│  Watch & Health Import                       │
│                                              │
│  ┌────────────────────────────────────────┐  │
│  │ ⌚ Auto-Sync                    [ON]  │  │
│  │                                        │  │
│  │ Automatically import new workouts      │  │
│  │ from Health Connect / Apple Health     │  │
│  │ when your watch syncs.                 │  │
│  │                                        │  │
│  │ Last sync: 2 minutes ago              │  │
│  └────────────────────────────────────────┘  │
│                                              │
│  ┌────────────────────────────────────────┐  │
│  │ [⟳ Import Now]  Manual import          │  │
│  │                                        │  │
│  │ No new activities found.              │  │
│  └────────────────────────────────────────┘  │
└─────────────────────────────────────────────┘
```

### 6.2 Permission Flow (First-Time Activation)

```
User taps "Auto-Sync" toggle ON
    │
    ├── [iOS] Already covered by healthkit entitlement
    │         Observer queries register at launch
    │         → Toggle enables/disables the Dart-side processing
    │
    ├── [Android] Check device support for background reads
    │       │
    │       ├── Not supported → Show message:
    │       │   "Your device doesn't support background health sync.
    │       │    Use 'Import Now' to sync manually."
    │       │   Toggle reverts to OFF.
    │       │
    │       └── Supported → Request READ_HEALTH_DATA_IN_BACKGROUND
    │               │
    │               ├── Granted → Register WorkManager task
    │               │              Get initial ChangesToken
    │               │              Toggle stays ON
    │               │
    │               └── Denied → Show message:
    │                   "Background access was not granted.
    │                    You can enable it in Health Connect settings."
    │                   Toggle reverts to OFF.
    │
    └── Persist preference in SharedPreferences
        Key: 'auto_sync_enabled' (bool)
```

### 6.3 Preference Storage

```dart
// SharedPreferences keys
static const kAutoSyncEnabled = 'auto_sync_enabled';
static const kAutoSyncRegisteredAt = 'auto_sync_registered_at';
static const kAutoSyncLastSuccess = 'auto_sync_last_success';
```

---

## 7. Local Notifications

When a background sync imports new activities, show a local notification to inform the user:

```dart
Future<void> _showSyncNotification(int count) async {
  if (count == 0) return;

  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.show(
    42,  // notification ID (fixed — replaces previous sync notification)
    'Activities synced',
    count == 1
        ? '1 new activity imported from your watch.'
        : '$count new activities imported from your watch.',
    const NotificationDetails(
      android: AndroidNotificationDetails(
        'outpace_sync',         // channel ID
        'Activity Sync',       // channel name
        channelDescription: 'Notifications when activities are auto-imported',
        importance: Importance.low,      // no sound/vibration
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
```

**Android**: Create a new notification channel `outpace_sync` with low importance (silent).

**User control**: The notification can be turned off via the auto-sync settings toggle or via OS notification channel settings.

---

## 8. Error Handling & Resilience

### 8.1 Failure Modes

| Failure                           | Detection                                     | Recovery                                                          |
|-----------------------------------|-----------------------------------------------|------------------------------------------------------------------|
| No network                        | `ConnectivityService` check or Supabase error | Queue locally via `LocalImportRepository.queueActivity()` — drain on next sync |
| Supabase session expired          | `auth.currentUser == null`                    | Skip sync silently — user must open app to re-auth               |
| Health Connect unavailable        | `getHealthConnectSdkStatus()` ≠ installed     | Skip sync, log diagnostic                                        |
| Changes token expired (30 days)   | `changesTokenExpired == true`                 | Fall back to full 30-day rescan, get a new token                 |
| HealthKit permission revoked      | Observer callback receives error              | Log, show notification: "Health access was revoked"               |
| Repeated failures (≥ 5)           | `SyncState.consecutiveFailures >= 5`          | Back off — skip next N cycles, log diagnostic to `import_diagnostics` |
| WorkManager killed by OS          | WorkManager handles automatically             | Rescheduled by OS (WorkManager is persistent)                    |
| iOS force-quit by user            | Observer queries stop                         | Re-registered on next app launch                                 |

### 8.2 Exponential Backoff

```dart
bool shouldSkipSync(SyncState state) {
  if (state.consecutiveFailures < 3) return false;
  if (state.consecutiveFailures >= 10) {
    // After 10 consecutive failures, stop until user manually triggers
    return true;
  }
  // Exponential backoff: skip 2^(failures-3) cycles
  // failures=3 → skip 1, failures=4 → skip 2, failures=5 → skip 4, etc.
  final skipCycles = 1 << (state.consecutiveFailures - 3);
  final timeSinceLastAttempt = DateTime.now().difference(state.lastAttemptAt!);
  final backoffMinutes = skipCycles * 15; // 15 min base interval
  return timeSinceLastAttempt.inMinutes < backoffMinutes;
}
```

### 8.3 Diagnostics

Extend the existing `import_diagnostics` table for background sync events:

```dart
await _client.from('import_diagnostics').insert({
  'user_id': userId,
  'platform': Platform.isIOS ? 'ios' : 'android',
  'payload': {
    'type': 'background_sync',
    'trigger': trigger,         // 'observer_query' | 'workmanager' | 'manual'
    'duration_ms': elapsed,
    'imported': importedCount,
    'skipped': skippedCount,
    'queued': queuedCount,
    'error': errorMessage,
    'changes_token_expired': tokenExpired,
  },
});
```

---

## 9. Refactoring Plan — Extract Shared Logic

The current `HealthImportService.importRecentWorkouts()` is a 300+ line monolith. For background sync, extract reusable logic into `HealthSyncCore`:

### 9.1 Extract: `HealthSyncCore`

```dart
/// Platform-agnostic workout read + transform + upsert logic.
/// Used by both HealthImportService (manual) and BackgroundSyncService (auto),
/// so a regression here shows up in the manual path too — where it is easy to
/// see and is covered by existing tests.
class HealthSyncCore {
  HealthSyncCore({
    required Health health,
    required SupabaseClient client,
    required LocalImportRepository localRepository,
  });

  /// Read a time window and return workouts TOGETHER with the window-level
  /// DISTANCE_DELTA and HEART_RATE batches. These batches MUST travel with the
  /// workouts: `chooseSourceAwareDistance` needs every in-window DISTANCE_DELTA
  /// record (grouped by source) to pick the owner source. Reading a workout in
  /// isolation and relying on `totalDistance` is exactly the `ceb118c`
  /// double-distance regression (health_import_service.dart:561-609).
  /// Extracted from the batched reads + filtering (health_import_service.dart:136-149).
  Future<WorkoutWindow> readWorkouts({
    required DateTime from,
    required DateTime to,
  }) async { /* ... */ }

  /// Supabase external_ids already present in [from,to] (dedup helper).
  /// Extracted from health_import_service.dart:151-172.
  Future<Set<String>> existingExternalIds(
    String userId, String source, DateTime from, DateTime to) async { /* ... */ }

  /// Map → cross-source overlap dedup → source-aware distance → local dedup →
  /// upsert/queue, for ONE workout. Takes the whole [window] so distance/HR
  /// context is available. Extracted from the per-workout loop body
  /// (health_import_service.dart:180-290), INCLUDING the overlap guard (187-200),
  /// HR aggregation (202-211) and source-aware distance (212-231) — these live
  /// inside the loop *before* line 233 and depend on the window batches, so the
  /// draft's clean "split at 233" boundary was wrong.
  Future<SyncOutcome> syncSingleActivity({
    required String userId,
    required String source,
    required HealthDataPoint workout,
    required WorkoutWindow window,
    required Set<String> existingExternalIds,
  }) async { /* ... */ }

  /// Drain pending offline queue (existing _syncPendingActivities).
  Future<void> syncPendingActivities() async { /* ... */ }
}

/// Workouts plus the window-level batches they depend on.
class WorkoutWindow {
  final List<HealthDataPoint> workouts;       // WORKOUT points
  final List<HealthDataPoint> distanceDeltas; // DISTANCE_DELTA points
  final List<HealthDataPoint> heartRates;     // HEART_RATE points
  const WorkoutWindow({
    required this.workouts,
    required this.distanceDeltas,
    required this.heartRates,
  });
}
```

### 9.2 Refactor: `HealthImportService`

After extraction, the manual import becomes a thin wrapper:

```dart
class HealthImportService {
  Future<HealthImportResult> importRecentWorkouts() async {
    // 1. Configure, authorize, check history (unchanged — still 30-day window)
    // 2. Delegate to HealthSyncCore (SAME functions the background path calls):
    final window = await _core.readWorkouts(from: start, to: now);
    final existing = await _core.existingExternalIds(user.id, source, start, now);
    for (final workout in window.workouts) {
      await _core.syncSingleActivity(
        userId: user.id, source: source,
        workout: workout, window: window, existingExternalIds: existing,
      );
    }
    // 3. Diagnostics (unchanged)
  }
}
```

> **Extraction safety gate.** `chooseSourceAwareDistance` is already
> `@visibleForTesting` and covered by
> `test/health_import_source_distance_test.dart`. Do the extraction as a **pure
> move** (no behaviour change), keep that function static/pure, and keep its tests
> green *throughout* the refactor — they are the regression net for the
> double-distance bug. Run the suite before wiring in the background path.

---

## 10. Implementation Plan

### Phase 1: Foundation (Estimated: 2 days)

| # | Task | Files |
|---|------|-------|
| 1.1 | Create `SyncState` table + migration v5→v6 | `app_database.dart`, new table file |
| 1.2 | Create `SyncStateRepository` | New file |
| 1.3 | `app_config` Supabase migration + `FeatureFlagService` (fail-safe, cached) | New SQL migration, new Dart file |
| 1.4 | Extract `HealthSyncCore` as a PURE move; keep distance tests green | Refactor existing file, new file |
| 1.5 | Create `BackgroundSyncService` (incl. `forBackgroundIsolate`) using `HealthSyncCore` | New file |
| 1.6 | iOS-only Method Channel `app.activefriends.app/health_sync` (Dart side) | New file |
| 1.7 | Unit tests: `HealthSyncCore`, `BackgroundSyncService`, `FeatureFlagService` | New test files |

### Phase 2: iOS Background Delivery (Estimated: 2 days)

| # | Task | Files |
|---|------|-------|
| 2.1 | Add `com.apple.developer.healthkit.background-delivery` entitlement | `Runner.entitlements` |
| 2.2 | Add `processing` to `UIBackgroundModes` | `Info.plist` |
| 2.3 | Update `NSHealthShareUsageDescription` | `Info.plist` |
| 2.4 | Implement `HKObserverQuery` + `enableBackgroundDelivery` in `AppDelegate.swift` | `AppDelegate.swift` |
| 2.5 | Implement Method Channel bridge (Swift → Dart) | `AppDelegate.swift` |
| 2.6 | Implement `HKAnchoredObjectQuery` for delta reads | New Swift file or `AppDelegate.swift` |
| 2.7 | Test: Garmin → Apple Health → Outpace auto-sync | Manual test on device |

### Phase 3: Android WorkManager + Changes API (Estimated: 1.5 days)

| # | Task | Files |
|---|------|-------|
| 3.1 | Add `READ_HEALTH_DATA_IN_BACKGROUND` permission | `AndroidManifest.xml` |
| 3.2 | Add `workmanager` dependency | `pubspec.yaml` |
| 3.3 | Background-read request via `health` pkg (`requestHealthDataInBackgroundAuthorization`) | `background_sync_service.dart` |
| 3.4 | Changes API via `health.getChangesToken` / `getChanges` (NO native Kotlin) | `background_sync_service.dart` |
| 3.5 | Implement `callbackDispatcher` + WorkManager registration + flag gate | `main.dart`, new file |
| 3.6 | Background isolate init: own Drift connection, Supabase, flag check | `background_sync_service.dart` |
| 3.7 | Test: Garmin → Health Connect → Outpace auto-sync | Manual test on Pixel 9 |

### Phase 4: UX & Polish (Estimated: 1 day)

| # | Task | Files |
|---|------|-------|
| 4.1 | Add "Auto-Sync" toggle to settings/import UI | `watch_import_section.dart` or new widget |
| 4.2 | Add local notification on background import | `background_sync_service.dart` |
| 4.3 | Add `outpace_sync` Android notification channel | Notification setup code |
| 4.4 | Show "Last synced: X ago" in import section | `watch_import_section.dart` |
| 4.5 | Diagnostic logging for background syncs | `background_sync_service.dart` |
| 4.6 | Resolve kill switch at startup + teardown-on-off (both platforms) | `main.dart`, `background_sync_service.dart` |
| 4.7 | Wire two-gate AND (remote flag && user toggle) into registration | `watch_import_section.dart` or new widget |

### Phase 5: Testing & Hardening (Estimated: 1 day)

| # | Task | Details |
|---|------|---------|
| 5.1 | Test iOS: app backgrounded, suspended, force-quit + relaunch | Verify observer re-registration |
| 5.2 | Test Android: app backgrounded, killed, device reboot | Verify WorkManager persistence |
| 5.3 | Test offline: airplane mode during background sync | Verify local queue + drain |
| 5.4 | Test token expiry: manually invalidate Changes token | Verify fallback to full 30-day rescan |
| 5.5 | Test duplicate prevention: manual import + auto sync | Verify no duplicates |
| 5.6 | Battery profiling: 24-hour test with auto-sync enabled | Verify < 1% battery impact |
| 5.7 | Test with multiple watch sources (Garmin + Apple Watch) | Verify source-aware dedup |

---

## 11. Risks & Mitigations

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| iOS background delivery is best-effort — iOS may delay or skip wakes | Delayed sync | Medium | Accept latency; manual import remains as fallback |
| Android 15-min minimum interval feels slow vs Strava near-instant sync | User expectation gap | Medium | Strava uses push notifications from Garmin API, not Health Connect polling. Document this. Consider FCM-triggered sync (see §12) |
| Background isolate cannot access `AppDatabase.shared` singleton | Crash in background | High | **Resolved in design:** `BackgroundSyncService.forBackgroundIsolate()` opens its own Drift connection (§5.1), never `.shared`. |
| `health` package doesn't expose Changes API or background read permission | Blocked implementation | None | **Resolved:** `health` 13.3.2 exposes `getChangesToken`/`getChanges` and `requestHealthDataInBackgroundAuthorization` natively (§4.2, §4.4). No native Kotlin needed. |
| Remote flag fetch fails, leaving auto-sync in an undefined state | Unexpected on/off | Low | `FeatureFlagService` fails safe to last-known-good, else **off** (§5.4). |
| User revokes health permission while auto-sync is registered | Silent failure | Low | Check permissions at each sync attempt; deregister WorkManager if revoked |
| App Store review: Apple may question background HealthKit access | App rejection | Low | Clearly document the use case in App Store review notes; the entitlement is designed for this |

---

## 12. Future Enhancements

### 12.1 FCM-Triggered Sync (Push-Based for Android)

For near-instant Android sync (matching iOS behavior):

1. Set up a Supabase Edge Function or backend webhook that receives Garmin Connect webhooks (Garmin's Health API supports push notifications for new activities)
2. When a new Garmin activity arrives, send an FCM **data-only** message to the user's device
3. The existing `_firebaseMessagingBackgroundHandler` in `main.dart` wakes the app
4. Handler triggers `BackgroundSyncService.syncIncremental()`

This bypasses the 15-minute WorkManager delay entirely. The WorkManager task remains as a safety net.

**Payload shape:**

```json
{
  "data": {
    "type": "health_sync_trigger",
    "source": "garmin"
  }
}
```

### 12.2 Supabase Realtime — Instant Feed Update

After a background sync upserts a new activity, the Supabase Realtime channel can notify other Outpace users in the same club — their feed updates without polling.

### 12.3 Watch Companion App

A native watchOS / Wear OS companion app could sync directly from the watch's health store, bypassing the phone entirely.

---

## 13. File Inventory — New & Modified

### New Files

| File | Purpose |
|------|---------|
| `lib/features/import/data/background_sync_service.dart` | Background sync orchestrator |
| `lib/features/import/data/health_sync_core.dart` | Extracted shared read/upsert logic |
| `lib/features/import/data/sync_state_repository.dart` | Delta-cursor/anchor persistence |
| `lib/features/import/data/feature_flag_service.dart` | Supabase-backed global kill switch (fail-safe) |
| `lib/data/local/tables/sync_state.dart` | New Drift table definition |
| `supabase/migrations/<ts>_app_config.sql` | `app_config` table + RLS + seed `auto_sync=off` |
| `test/features/import/data/background_sync_service_test.dart` | Unit tests |
| `test/features/import/data/health_sync_core_test.dart` | Unit tests |
| `test/features/import/data/feature_flag_service_test.dart` | Unit tests (fail-safe + cache) |

### Modified Files

| File | Change |
|------|--------|
| `ios/Runner/Runner.entitlements` | Add `background-delivery` entitlement |
| `ios/Runner/Info.plist` | Add `processing` background mode, update health description |
| `ios/Runner/AppDelegate.swift` | Add HealthKit observer registration, Method Channel |
| `android/app/src/main/AndroidManifest.xml` | Add `READ_HEALTH_DATA_IN_BACKGROUND` permission |
| `app/lib/main.dart` | Add WorkManager `callbackDispatcher` + flag gate; resolve kill switch at startup; iOS Method Channel handler |
| `app/pubspec.yaml` | Add `workmanager` dependency |
| `app/lib/data/local/app_database.dart` | Add `SyncState` table, migration v5→v6 |
| `app/lib/features/import/data/health_import_service.dart` | Refactor to use `HealthSyncCore` |
| `app/lib/features/import/presentation/watch_import_section.dart` | Add auto-sync toggle, last-sync timestamp |

---

## 14. References

- [Health Connect — Synchronize Data (Android)](https://developer.android.com/health-and-fitness/health-connect/sync-data)
- [Health Connect — Read Data / Background Reads (Android)](https://developer.android.com/health-and-fitness/health-connect/read-data)
- [Health Connect — Background Reads Announcement (I/O 2024)](https://android-developers.googleblog.com/2024/05/the-latest-updates-from-android-health-io-2024.html)
- [HealthKit — Executing Observer Queries (Apple)](https://developer.apple.com/documentation/healthkit/executing-observer-queries)
- [HealthKit — enableBackgroundDelivery (Apple)](https://developer.apple.com/documentation/healthkit/hkhealthstore/enablebackgrounddelivery(for:frequency:withcompletion:))
- [HealthKit — Background Delivery Entitlement (Apple)](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.healthkit.background-delivery)
- [Flutter WorkManager Plugin](https://docs.page/fluttercommunity/flutter_workmanager/index)
- [Flutter `health` package](https://pub.dev/packages/health)
