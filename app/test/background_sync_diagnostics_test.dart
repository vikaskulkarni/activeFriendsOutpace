import 'package:activefriends/data/local/app_database.dart';
import 'package:activefriends/features/import/data/background_sync_service.dart';
import 'package:activefriends/features/import/data/feature_flag_service.dart';
import 'package:activefriends/features/import/data/health_sync_core.dart';
import 'package:activefriends/features/import/data/local_import_repository.dart';
import 'package:activefriends/features/import/data/sync_state_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Background-run diagnostics (SPEC §8.3): every background wake persists one
/// `background_sync` row to `import_diagnostics` so a device test is conclusive
/// about WHY a run imported nothing (flag off? unauthorized? zero workouts?).
class _FakeCore implements HealthSyncCore {
  _FakeCore({required this.window, this.authorized = true});
  final WorkoutWindow window;
  final bool authorized;

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
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

FeatureFlagService _flags(SharedPreferences p, {required bool enabled}) =>
    FeatureFlagService(
        fetchAutoSyncRow: () async => {
              'value': {'enabled': enabled}
            },
        prefs: p);

const _emptyWindow =
    WorkoutWindow(workouts: [], distanceDeltas: [], heartRates: []);

void main() {
  late AppDatabase db;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
  });
  tearDown(() => db.close());

  test('flag-off path records a background_sync row (flag_enabled false)',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final rows = <Map<String, dynamic>>[];
    final svc = BackgroundSyncService(
      flags: _flags(prefs, enabled: false),
      diagnosticsRecorder: (uid, payload) async =>
          rows.add({'_uid': uid, ...payload}),
    );

    await svc.syncIncremental(userId: 'u1', trigger: 'periodic');

    expect(rows, hasLength(1));
    final row = rows.single;
    expect(row['_uid'], 'u1');
    expect(row['type'], 'background_sync');
    expect(row['trigger'], 'periodic');
    expect(row['session_present'], true);
    expect(row['flag_enabled'], false);
    expect(row['skipped_reason'], 'flag_off');
  });

  test('unauthorized path records authorized=false', () async {
    final prefs = await SharedPreferences.getInstance();
    final rows = <Map<String, dynamic>>[];
    final svc = BackgroundSyncService(
      flags: _flags(prefs, enabled: true),
      core: _FakeCore(window: _emptyWindow, authorized: false),
      localRepository: LocalImportRepository(db),
      syncStateRepository: SyncStateRepository(db),
      diagnosticsRecorder: (uid, payload) async => rows.add(payload),
    );

    await svc.syncIncremental(userId: 'u1', trigger: 'oneoff');

    expect(rows, hasLength(1));
    expect(rows.single['flag_enabled'], true);
    expect(rows.single['authorized'], false);
    expect(rows.single['skipped_reason'], 'unauthorized');
  });

  test('success path records authorized, workouts read count, and counts',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final rows = <Map<String, dynamic>>[];
    final svc = BackgroundSyncService(
      flags: _flags(prefs, enabled: true),
      core: _FakeCore(window: _emptyWindow, authorized: true),
      localRepository: LocalImportRepository(db),
      syncStateRepository: SyncStateRepository(db),
      diagnosticsRecorder: (uid, payload) async => rows.add(payload),
    );

    final result = await svc.syncIncremental(userId: 'u1', trigger: 'oneoff');

    expect(result.skippedReason, isNull);
    expect(rows, hasLength(1));
    final row = rows.single;
    expect(row['flag_enabled'], true);
    expect(row['authorized'], true);
    expect(row['workouts_read'], 0);
    expect(row['imported'], 0);
    expect(row['skipped'], 0);
    expect(row['queued'], 0);
    expect(row['skipped_reason'], isNull);
  });

  test('a throwing diagnostics recorder never fails a successful run',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final svc = BackgroundSyncService(
      flags: _flags(prefs, enabled: true),
      core: _FakeCore(window: _emptyWindow, authorized: true),
      localRepository: LocalImportRepository(db),
      syncStateRepository: SyncStateRepository(db),
      diagnosticsRecorder: (uid, payload) async =>
          throw StateError('diagnostics insert failed'),
    );

    final result = await svc.syncIncremental(userId: 'u1');

    // Best-effort: the run succeeds regardless of the diagnostics failure.
    expect(result.skippedReason, isNull);
    expect(result.imported, 0);
  });

  test('failure path: rethrows, records a failed attempt, and the diag row '
      'carries the error', () async {
    final prefs = await SharedPreferences.getInstance();
    final rows = <Map<String, dynamic>>[];
    final repo = SyncStateRepository(db);
    final svc = BackgroundSyncService(
      flags: _flags(prefs, enabled: true),
      core: _ThrowingCore(),
      localRepository: LocalImportRepository(db),
      syncStateRepository: repo,
      diagnosticsRecorder: (uid, payload) async => rows.add(payload),
    );

    // (a) The read failure propagates so WorkManager retries.
    await expectLater(
      svc.syncIncremental(userId: 'u1', trigger: 'periodic'),
      throwsA(isA<StateError>()),
    );

    // (b) A failed attempt is recorded so backoff can throttle.
    final row = await (db.select(db.syncStates)
          ..where((r) => r.userId.equals('u1')))
        .getSingleOrNull();
    expect(row?.consecutiveFailures, 1);

    // (c) The diagnostics row is still persisted and carries the error.
    expect(rows, hasLength(1));
    expect(rows.single['authorized'], true);
    expect(rows.single['skipped_reason'], isNull);
    expect(rows.single['error'], contains('read failed'));
  });
}

class _ThrowingCore extends _FakeCore {
  _ThrowingCore() : super(window: _emptyWindow, authorized: true);
  @override
  Future<WorkoutWindow> readWorkouts(
          {required DateTime from, required DateTime to}) async =>
      throw StateError('read failed');
}
