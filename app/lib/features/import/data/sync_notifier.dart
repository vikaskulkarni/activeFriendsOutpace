import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Low-importance local notification shown when a background sync imports new
/// activities. Fixed id 42 so a later sync replaces the previous banner.
class SyncNotifier {
  SyncNotifier({required FlutterLocalNotificationsPlugin plugin})
      : _plugin = plugin; // ignore: prefer_initializing_formals
  final FlutterLocalNotificationsPlugin _plugin;

  Future<void> showSynced(int count) async {
    if (count <= 0) return;
    final body = count == 1
        ? '1 new activity imported from your watch.'
        : '$count new activities imported from your watch.';
    await _plugin.show(
      42,
      'Activities synced',
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'outpace_sync',
          'Activity Sync',
          channelDescription:
              'Notifications when activities are auto-imported',
          importance: Importance.low,
          priority: Priority.low,
          icon: 'ic_sync_notification',
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: false,
          presentSound: false,
        ),
      ),
    );
  }
}
