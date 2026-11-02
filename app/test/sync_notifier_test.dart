import 'package:activefriends/features/import/data/sync_notifier.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakePlugin implements FlutterLocalNotificationsPlugin {
  final calls = <String>[];
  NotificationDetails? lastDetails;
  @override
  Future<void> show(int id, String? title, String? body, dynamic details,
      {String? payload}) async {
    calls.add('$id|$title|$body');
    if (details is NotificationDetails) lastDetails = details;
  }
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

void main() {
  test('count 0 → no notification', () async {
    final p = _FakePlugin();
    await SyncNotifier(plugin: p).showSynced(0);
    expect(p.calls, isEmpty);
  });

  test('count 1 → singular copy, uses ic_sync_notification icon', () async {
    final p = _FakePlugin();
    await SyncNotifier(plugin: p).showSynced(1);
    expect(p.calls.single, contains('1 new activity imported'));
    expect(p.lastDetails?.android?.icon, 'ic_sync_notification');
  });

  test('count 3 → plural copy, fixed id 42', () async {
    final p = _FakePlugin();
    await SyncNotifier(plugin: p).showSynced(3);
    expect(p.calls.single, startsWith('42|Activities synced|'));
    expect(p.calls.single, contains('3 new activities imported'));
  });
}
