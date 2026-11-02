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
