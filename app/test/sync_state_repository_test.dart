import 'dart:typed_data';

import 'package:activefriends/data/local/app_database.dart';
import 'package:activefriends/features/import/data/sync_state_repository.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
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
