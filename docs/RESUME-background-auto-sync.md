# RESUME PROMPT — Background Auto-Sync: build & release

> Paste this whole file as your first message in a new Claude Code session. It is self-contained; you have no prior context. The repo's `MEMORY.md` and `docs/SPEC-background-auto-sync.md` carry more detail — read them early.

## Goal of the new session
Finish and ship **background auto-sync** for the Outpace app in **one build/release**: wire up the background execution (iOS + Android) on top of the already-built foundation, ship the remote kill-switch flag **ON**, and leave me able to switch it **OFF** remotely later. Everything from the prior session is already on one branch — continue on it.

## Repo / environment
- Repo: `/Users/I589392/mygit/activeFriendsOutpace` (Flutter app under `app/`). Android + iOS. Supabase + Drift + `health: ^13.3.2` + Firebase.
- **Git identity:** this is a PERSONAL GitHub repo (`github.com/vikaskulkarni/activeFriendsOutpace`), NOT SAP. A repo-local git identity is set to `Vikas Kulkarni <vikas.kulkarni@gmail.com>` — all commits must use it, never the global SAP identity (`I589392` / `*.sap.com`). **Never `git push` without me explicitly asking.** Never rewrite `main`'s published history.

## Current branch state — START HERE
- Work branch: **`integration/next-build`** (off `main` at `69102dc`). Run `git log --oneline main..integration/next-build` to confirm; expected 9 commits:
  - `d2be7f7` fix(import): dedup HealthKit workouts by identity in shared HealthSyncCore
  - `bea0710` chore(ios): remove Push debug info from account actions sheet
  - `9a5caaa` BackgroundSyncService shell (flag gate)
  - `d8b12a6` restore per-workout distance_debug diagnostics
  - `304dbda` extract HealthSyncCore (manual + background share one path)
  - `44a429d` FeatureFlagService kill switch + app_config migration
  - `551370b` SyncStateRepository
  - `ae5900e` SyncState table + migration v5→v6
  - `fc005f9` spec (rev 2) + foundation plan
- **Do everything on `integration/next-build`.** Do NOT merge branch `fix/ios-duplicate-import` (its commits are already represented here — merging would conflict/duplicate).
- Baseline health: `cd app && flutter test` → full suite green EXCEPT one pre-existing failure `test/widget_test.dart` "Shows the unconfigured backend state" (fails on `main` too — ignore it, it's unrelated). `flutter analyze` → only pre-existing info/warnings + cosmetic `prefer_initializing_formals`.

## What's already DONE (do not redo)
- **Duplicate-import fix (iOS Apple-Watch/Strava):** root-caused + fixed. Strava writes its own `HKWorkout` into Apple Health and re-exports under NEW UUIDs over time; dedup on `external_id` missed them. Fix = `HealthSyncCore.duplicateSkipIdsForWindow` + static `duplicateExternalIdsToSkip` (keep already-imported, skip newcomer; same type + >80% time overlap via `DuplicateDetector`; offline-safe). Both manual and background paths pre-filter with it. Tests: `app/test/health_import_duplicate_skip_test.dart`. (Memory: `ios-healthkit-duplicate-strava-reexport`.)
- **Push-debug-info removal** from the account-actions sheet.
- **Background-sync FOUNDATION (dormant):** `SyncState` Drift table (schema v6), `SyncStateRepository` (changesToken/hkAnchor/recordSyncAttempt/invalidateToken), `FeatureFlagService` (reads Supabase `app_config.auto_sync`, FAIL-SAFE to off), `HealthSyncCore` (shared read/transform/upsert — `readWorkouts`→`WorkoutWindow`, `existingExternalIds`, `syncSingleActivity`, `syncPendingActivities`, static `chooseSourceAwareDistance`, `duplicateSkipIdsForWindow`), and `BackgroundSyncService` (flag-gated shell; `forBackgroundIsolate()` opens its OWN Drift connection; `_resolveChangedIds` is a STUB returning null = rescan-all).
- Design reference (already corrected against the codebase): `docs/SPEC-background-auto-sync.md` §3 (iOS), §4 (Android), §5, §9. `docs/PLAN-background-auto-sync-foundation.md` (foundation, shipped).

## What REMAINS to build this session (the wiring + enable)
Build the deferred platform execution so the flag actually does something, keeping it scoped so it cannot touch the stable manual-import or Android-distance logic. Suggested: brainstorm only if needed, then `writing-plans` → `subagent-driven-development`, TDD where testable.

1. **Android (`health` pkg already supports this — NO native Kotlin plugin needed):**
   - `android/app/src/main/AndroidManifest.xml`: add `android.permission.health.READ_HEALTH_DATA_IN_BACKGROUND`.
   - `app/pubspec.yaml`: add `workmanager` (check latest compatible version).
   - `app/lib/main.dart`: `@pragma('vm:entry-point')` `callbackDispatcher` + WorkManager periodic task (15 min). On wake: init Firebase/Supabase in the isolate, check session, **check `FeatureFlagService().autoSyncEnabled()` at entry — if off, `cancelByUniqueName` and return**, else `BackgroundSyncService.forBackgroundIsolate().syncIncremental(...)`.
   - Request background-read via the `health` pkg: `isHealthDataInBackgroundAvailable()` / `isHealthDataInBackgroundAuthorized()` / `requestHealthDataInBackgroundAuthorization()`.
   - `BackgroundSyncService._resolveChangedIds` (Android): use `health.getChangesToken({types})` + `health.getChanges(changesToken)` → `HealthChangesResponse` (`upsertedDataPoints`, `deletedRecordIds`, `nextChangesToken`, `hasMore`, `changesTokenExpired`); persist token via `SyncStateRepository`; **on expired/absent → full 30-day rescan (NEVER a 1h/24h window — late-syncing watches backfill older timestamps).**
2. **iOS (native Swift required — the `health` pkg does NOT do observer background delivery):**
   - `ios/Runner/Runner.entitlements`: `com.apple.developer.healthkit.background-delivery`.
   - `ios/Runner/Info.plist`: update `NSHealthShareUsageDescription`. Do NOT add a `processing` UIBackgroundMode (not used — background delivery needs only the entitlement).
   - `ios/Runner/AppDelegate.swift`: register `HKObserverQuery(workoutType)` + `enableBackgroundDelivery(.immediate)` at launch. Observer callback → invoke Dart over the EXISTING engine via method channel `app.activefriends.app/health_sync` method `onHealthDataChanged`. **This app uses the new implicit-engine embedding (`FlutterAppDelegate, FlutterImplicitEngineDelegate`, plugins register on `engineBridge.pluginRegistry`) — capture the implicit engine's `binaryMessenger`; do NOT use `window.rootViewController as? FlutterViewController`, and do NOT spin up a headless `FlutterEngine`/`backgroundSyncEntrypoint`.** Use `HKAnchoredObjectQuery` with a persisted `HKQueryAnchor` (store via `SyncStateRepository.saveHkAnchor`) for delta reads; feed results into `BackgroundSyncService._resolveChangedIds` (iOS).
   - Dart `main.dart`: handle the `onHealthDataChanged` method call → run `BackgroundSyncService(...).syncIncremental(...)` (flag-gated).
3. **Startup flag enforcement:** on app launch (after `Supabase.initialize` in `main.dart`), resolve the flag; if ON register the workers/observer, if OFF tear them down (Android `cancelByUniqueName`; iOS `disableBackgroundDelivery`). "Off in Supabase" must actually stop OS wake-ups, not just no-op.
4. **Before `readWorkouts` on the real run:** call `_health.configure()` + authorization (the manual path does this; `readWorkouts` assumes it ran). Also pre-filter non-`WorkoutHealthValue` points like the manual path (the shared core returns `skippedOverlap` for them otherwise).
5. **Enable the flag:** change the `app_config` seed migration (`supabase/migrations/..._app_config.sql`) from `{"enabled": false}` to `{"enabled": true}`. KEEP `FeatureFlagService`'s fail-safe-to-off logic (do NOT invert it). "On by default" = seeded true + deployed; remote OFF = `update public.app_config set value = '{"enabled": false}' where key = 'auto_sync';`. (Optional, if time: the §6 user-facing auto-sync toggle + "last synced" + local notification from Plan 4.)

`select key, value, value->>'enabled' as enabled, updated_at from app_config where key = 'auto_sync';`


## Hard constraints / scar tissue (DO NOT violate)
- **Do not break the stable manual import or the Android path.** Cross-platform breakage has happened before (an Android change once broke iOS). Keep changes scoped.
- **Regression gates (must stay green):** `app/test/health_import_source_distance_test.dart` (double-distance `ceb118c` guard — fixtures must NOT change), `app/test/health_import_duplicate_skip_test.dart`, and the full suite (minus the known `widget_test.dart`).
- `DISTANCE_DELTA` is **Android-only** in the `health` pkg (iOS → `INVALID_TYPE` kills the whole read). Preserve the `if (Platform.isAndroid)` guard in `HealthSyncCore.readTypes`.
- Source-aware distance must keep **window context** (compute from `WorkoutWindow.distanceDeltas`, never a workout's isolated `totalDistance`).
- One watermark system: data coverage in `ImportWatermarks`; `SyncState` only holds delta cursors + run status.

## External prerequisites that are the USER's and GATE the release (surface these; you can't do them)
1. **iOS entitlement** `com.apple.developer.healthkit.background-delivery` must be on the App ID / provisioning profile + an App Review note. Without it iOS background sync will not work regardless of code. (User confirmed they can add it.)
2. **Android** `READ_HEALTH_DATA_IN_BACKGROUND` needs the runtime consent flow + a Play Console data-safety update.
3. **Device testing:** background delivery / WorkManager cannot be verified in `flutter test` or by the agent — user must test on a real device (ideally the friend "Mahesh"'s iPhone where the dup bug appeared) before public release. The kill switch is the safety net.
4. **Deploy** the `app_config` migration (seeded ON) via `supabase db push` before release, else the flag reads absent → fail-safe OFF. Supabase: `activefriends-dev`, ref `eswypmvrdgilkljytrxq`, PRODUCTION, **read-only — the user runs all DB queries/migrations manually.**

## Release checklist (end state for the single build)
- [ ] Android WorkManager wiring + bg permission + `health.getChanges` delta
- [ ] iOS HKObserver + entitlement + anchored query + method channel
- [ ] Startup flag resolution + register/teardown
- [ ] `app_config` seed flipped to `enabled: true`
- [ ] Full `flutter test` green (except known `widget_test.dart`) + `flutter analyze` no new issues
- [ ] User adds iOS entitlement to provisioning; updates Android data-safety
- [ ] User runs `supabase db push` (app_config on)
- [ ] User device-tests auto-sync on iOS + Android before release
- [ ] Build & release from `integration/next-build`
