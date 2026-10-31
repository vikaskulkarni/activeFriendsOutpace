import 'package:activefriends/data/local/app_database.dart';
import 'package:activefriends/features/import/data/background_sync_service.dart';
import 'package:activefriends/features/import/data/feature_flag_service.dart';
import 'package:activefriends/features/import/data/health_sync_core.dart';
import 'package:activefriends/features/import/data/local_import_repository.dart';
import 'package:activefriends/features/import/data/sync_state_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';
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
      required HealthDataPoint workout,
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

  test('non-workout value in workouts list is silently skipped (never counted or synced)',
      () async {
    final prefs = await SharedPreferences.getInstance();
    // Construct a HealthDataPoint whose value is NumericHealthValue — NOT a
    // WorkoutHealthValue. The syncIncremental pre-filter must `continue` past
    // it without incrementing imported/skipped or calling syncSingleActivity.
    final nonWorkoutPoint = HealthDataPoint(
      uuid: 'non-workout-uuid',
      value: NumericHealthValue(numericValue: 42),
      type: HealthDataType.STEPS,
      unit: HealthDataUnit.COUNT,
      dateFrom: DateTime(2025),
      dateTo: DateTime(2025),
      sourcePlatform: HealthPlatformType.appleHealth,
      sourceDeviceId: 'device',
      sourceId: 'source',
      sourceName: 'Test',
    );
    final core = _FakeCore(
      window: WorkoutWindow(
        workouts: [nonWorkoutPoint],
        distanceDeltas: [],
        heartRates: [],
      ),
    );
    final svc = BackgroundSyncService(
      flags: _flagOn(prefs),
      core: core,
      localRepository: LocalImportRepository(db),
      syncStateRepository: SyncStateRepository(db),
    );
    final result = await svc.syncIncremental(userId: 'u');
    // The non-workout point must not appear in any count and must never reach
    // syncSingleActivity.
    expect(result.imported, 0,
        reason: 'non-workout point must not be imported');
    expect(result.skipped, 0,
        reason: 'non-workout point must not inflate skipped count');
    expect(core.singleCalls, 0,
        reason: 'syncSingleActivity must not be called for non-workout value');
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
