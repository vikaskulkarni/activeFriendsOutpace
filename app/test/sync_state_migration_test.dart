import 'package:activefriends/data/local/app_database.dart';
import 'package:drift/drift.dart';
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
