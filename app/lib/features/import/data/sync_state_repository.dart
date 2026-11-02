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

  /// Read the current run-status row (or null), for the backoff gate.
  Future<SyncState?> rowFor(String userId, String source) =>
      _rowFor(userId, source).getSingleOrNull();

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
