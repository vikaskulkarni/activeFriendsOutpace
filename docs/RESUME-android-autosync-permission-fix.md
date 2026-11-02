# RESUME PROMPT — Android background auto-sync permission fix (+ diagnostics), then iOS device test

> Paste this whole file as your first message in a new Claude Code session. It is self-contained; you have no prior context. Read `MEMORY.md`, `docs/SPEC-background-auto-sync.md`, and `.superpowers/sdd/progress.md` early for deeper detail.

## Goal of the new session
Fix the **Android background auto-sync permission bug** (diagnosed below — background sync fires but imports nothing because it tries to *request* health permission in a headless isolate), add **background-run diagnostics** so the next on-device test is conclusive, keep everything else intact, and keep it shippable in one build. After that, the user will device-test on **iOS (iPhone)**. Use TDD where testable; the native/background parts are verified on-device by the user.

## Repo / environment
- Repo: `/Users/I589392/mygit/activeFriendsOutpace` (Flutter app under `app/`). Android + iOS. Supabase + Drift + `health: ^13.3.2` + `workmanager: ^0.6.0` + Firebase + `flutter_local_notifications`.
- `flutter` is on PATH (`/Users/I589392/develop/flutter/bin/flutter`). Run `flutter` from `app/` (`cd app && …`).
- **Git identity:** PERSONAL repo. Repo-local identity is already set to `Vikas Kulkarni <vikas.kulkarni@gmail.com>` — all commits use it, never a SAP identity. **Never `git push` without the user explicitly asking.** Never rewrite `main`'s history.
- **Work branch: `integration/next-build`** (the single release branch). Current HEAD: **`b9d39b1`**. Do everything here.

## Current state — START HERE
- Run `git log --oneline main..integration/next-build` to confirm. The background auto-sync feature is fully built and reviewed (16-commit plan `d2be7f7..2167505`) plus follow-ups: iOS Swift `messenger()` fix, the sync notification icon, Android notification init-in-isolate + one-off-on-enable, and auto-sync **ON by default** + trimmed UI.
- Baseline health: `cd app && flutter test` → **59 pass / 1 fail**, where the ONLY failure is the pre-existing, unrelated `test/widget_test.dart` "Shows the unconfigured backend state" (fails on `main` too — ignore it). `flutter analyze` → **28** pre-existing info/warnings, 0 new. These are the gates: keep them.
- The user has already run `supabase db push` (so `app_config.auto_sync = {"enabled": true}` is live in prod). The released Play build that "didn't auto-sync" turned out to be a **stale build** (pre-feature) — not a bug.
- SDD progress ledger: `.superpowers/sdd/progress.md` (append your progress there).

## THE BUG TO FIX (primary task) — root cause already found
On the user's Pixel 9 + emulator, the WorkManager background task **runs and returns SUCCESS**, but imports nothing. Console logs showed:
```
I/WM-WorkerWrapper: Worker result SUCCESS … workmanager.BackgroundWorker   ← worker fired (wiring OK)
I/FLUTTER_HEALTH: Health Connect permissions were not granted!
I/FLUTTER_HEALTH: Permission launcher not found                            ← the smoking gun
```
**Root cause:** `HealthSyncCore.ensureAuthorized()` (called only from the background path, `BackgroundSyncService.syncIncremental`) calls `_health.requestAuthorization(authTypes, …)`. `requestAuthorization` tries to **launch the Health Connect permission UI, which requires a foreground Activity**. A WorkManager isolate has no Activity → "Permission launcher not found" → it returns `false` → `syncIncremental` returns `skipped('unauthorized')` → worker reports SUCCESS but imports 0. The manual import works because it runs in the foreground (has an Activity).

### The fix (3 parts)
1. **`ensureAuthorized()` must only CHECK, never request, in the background.** File: `app/lib/features/import/data/health_sync_core.dart` (method `ensureAuthorized()`, currently does `configure()` + `requestAuthorization(authTypes, READ)` + Android history).
   Replace the request with a platform-aware verify:
   - Always `await _health.configure()`.
   - **Android:** return `await _health.hasPermissions(authTypes, permissions: [READ…])` (treat `null` as `false`). Do **NOT** call `requestAuthorization` here — it needs an Activity.
   - **iOS:** ⚠️ **do NOT gate on `hasPermissions` — on iOS/HealthKit `hasPermissions` is unreliable for READ access (Apple hides read-permission status for privacy; it returns `null`/`false` even when granted).** On iOS the background callback runs on the **main isolate** (via `forMainIsolate`), so either call `requestAuthorization` (it no-ops with no UI if already determined) or simply return `true` and let the read proceed (a granted read returns data; an ungranted one returns empty). Pick the iOS branch so iOS auto-sync is NOT broken by this change.
   - This method is **background-only** (only `BackgroundSyncService` calls it). `HealthImportService` (manual) has its own foreground `requestAuthorization` — **do not touch it.**
2. **Move the GRANT to the foreground.** When the user enables auto-sync, the registration runs with an Activity, so request the foreground health read permissions there (in addition to the existing background-read request). File: `app/lib/features/import/data/auto_sync_platform.dart`, `_register()` Android branch — it currently only calls `health.requestHealthDataInBackgroundAuthorization()`. Also request `HealthSyncCore.authTypes` with READ (foreground) so that, by the time the worker runs, `hasPermissions` is true. (Users who did a manual import already granted foreground perms; this covers users who never did.) Keep the iOS branch as-is.
3. **Add background-run diagnostics (SPEC §8.3)** so the next real-device run is conclusive. On each background wake persist one row to the existing `import_diagnostics` Supabase table with: `type: 'background_sync'`, trigger (`oneoff`/`periodic` — pass it through from the WorkManager taskName / iOS channel), session present (bool), flag value, `hasPermissions` result, workouts read count, imported/skipped/queued, and any error. Put it in `BackgroundSyncService.syncIncremental` (and/or `_executeBackgroundHealthSync` in `auto_sync_platform.dart`). Mirror the manual path's best-effort insert (`health_import_service.dart` already inserts to `import_diagnostics`; copy that pattern — wrap in try/catch so diagnostics never fail the run). The user can then read the row in Supabase after a test.

### How to verify
- TDD the testable Dart: `ensureAuthorized` Android-vs-iOS branch behavior via a fake `Health` seam (or refactor so the permission-check is injectable). The foreground request + the actual background read are platform — user device-tests.
- `cd app && flutter test` must stay **59/1** (+ any new tests), `flutter analyze` **28**.
- For iOS native changes use `flutter build ios --no-codesign` (it **compiles Swift** — unlike `--config-only`, which does NOT and is how an earlier `messenger()` Swift error slipped through). For the aab: `flutter build appbundle`.

## Hard constraints / scar tissue (DO NOT violate)
- **Do not break the stable manual import** (`HealthImportService`) or the Android distance logic. `ensureAuthorized` is background-only; leave the manual path's own auth sequence byte-unchanged.
- **iOS `hasPermissions` is unreliable for READ** — never gate iOS reads on it (see fix part 1).
- Regression gates stay green: `app/test/health_import_source_distance_test.dart` (double-distance `ceb118c` guard — fixtures unchanged), `app/test/health_import_duplicate_skip_test.dart`, full suite minus the known `widget_test.dart`. `flutter analyze` adds no new issues (baseline 28).
- `DISTANCE_DELTA` is Android-only in `health` (iOS → INVALID_TYPE kills the read) — keep the `if (Platform.isAndroid)` guard in `HealthSyncCore.readTypes`. Don't touch `chooseSourceAwareDistance`/`_computeSourceAwareDistance`.
- One watermark system: coverage in `ImportWatermarks`; `SyncState` only delta cursors + run status.
- Two-gate: remote `FeatureFlagService.autoSyncEnabled()` (fail-safe to OFF, seeded ON) **AND** per-user `AutoSyncPreferences.isEnabled()` (now defaults **true** = opt-out). Remote always wins; "off" tears down OS wake-ups (Android `cancelByUniqueName` for both `healthSyncPeriodic` and `healthSyncOnce`; iOS `disableBackgroundDelivery`).
- Isolate DB: Android WorkManager path uses `BackgroundSyncService.forBackgroundIsolate()` (own Drift connection); iOS channel path uses `forMainIsolate()` (shared `AppDatabase.shared`). Keep this split.
- Commit as the personal identity; never push.

## Key files
- `app/lib/features/import/data/health_sync_core.dart` — shared read/transform/upsert; `ensureAuthorized()` (FIX 1), `readTypes`/`authTypes`, `chooseSourceAwareDistance`, Changes-delta helpers.
- `app/lib/features/import/data/background_sync_service.dart` — `syncIncremental` (flag gate → backoff → ensureAuthorized → read → loop → watermark/recordSyncAttempt → notifier), `resolveAndroidChangedIds`, `forBackgroundIsolate`/`forMainIsolate`. (FIX 3 diagnostics here.)
- `app/lib/features/import/data/auto_sync_platform.dart` — `start()`, `syncRegistration()`, `_register`/`_teardown` (FIX 2 here), `callbackDispatcher`, `kHealthSyncTask`, `_executeBackgroundHealthSync` (notification init + session/flag gate).
- `app/lib/features/import/data/auto_sync_preferences.dart` — per-user toggle (defaults true), `lastSuccess`.
- `app/lib/features/import/presentation/watch_import_section.dart` — the Auto-Sync toggle + manual Import button (only import entry point, used at `clubs_screen.dart:633`).
- `app/lib/features/import/data/health_import_service.dart` — manual import (DO NOT TOUCH); reference for the `import_diagnostics` insert pattern.
- `app/ios/Runner/AppDelegate.swift` — HKObserver + background delivery + method channel `app.activefriends.app/health_sync` (`messenger()` already fixed).
- `app/android/app/src/main/res/drawable/ic_sync_notification.png` — sync notification icon (generated placeholder; refine by swapping this one PNG).
- `supabase/migrations/20261030120000_app_config.sql` — kill switch seeded ON (already db-pushed).

## USER's external tasks / gating (surface these; you can't do them)
1. **Bump `app/pubspec.yaml` version before building** — currently `1.0.0+23`; Play needs a higher `versionCode`, so build as `1.0.0+24` (or let the user bump). The user builds/uploads.
2. **Play "Health apps" declaration** — the app declares `READ_HEALTH_DATA_IN_BACKGROUND` (new). Category = **Activity and fitness** only (no Medical). Must justify the background permission ("auto-import new workouts from Health Connect into the activity feed when the wearable syncs, like Garmin→Strava"); a short demo video may be required. Background health access gets extra scrutiny.
3. **Device test** on a real **iPhone** (user doing next) and the **Pixel** (grant Health Connect foreground + "allow in background" permission; the fix makes the background isolate verify instead of request). Keep Outpace battery = Unrestricted (Doze delays WorkManager). Read the new `import_diagnostics` background rows to confirm.
4. **Share routes** — already on-by-default for NEW users (`profiles.share_routes` default `true` via migration `20260911004000` + client `?? true`). Do **NOT** add a migration that force-flips existing `false→true` (privacy: some users opted out deliberately). No code change was made for this.

## Suggested workflow
Phase-1 root cause is already done (this doc). Use `superpowers:subagent-driven-development` or inline TDD: implement FIX 1/2/3, review each (fresh reviewer, spec + quality), keep the gates green, then hand back the build checklist. Append progress to `.superpowers/sdd/progress.md`.

## End-state checklist
- [ ] `ensureAuthorized()` verifies (Android `hasPermissions`) instead of requesting; iOS not gated on `hasPermissions`
- [ ] Foreground grant added to the auto-sync enable path (`_register`, Android)
- [ ] Background `import_diagnostics` telemetry added (best-effort)
- [ ] `flutter test` 59/1 (+ new tests) green; `flutter analyze` 28; `flutter build ios --no-codesign` compiles
- [ ] User bumps to `1.0.0+24`, builds aab, uploads to internal testing, completes Play Health declaration
- [ ] User device-tests Android (Pixel) + iOS (iPhone); reads background diagnostics
- [ ] Nothing pushed; build/release from `integration/next-build` on the user's go
