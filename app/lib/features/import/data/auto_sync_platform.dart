import 'dart:developer' as developer;
import 'dart:io';

import 'package:activefriends/core/config/supabase_config.dart';
import 'package:activefriends/features/import/data/auto_sync_manager.dart';
import 'package:activefriends/features/import/data/auto_sync_preferences.dart';
import 'package:activefriends/features/import/data/background_sync_service.dart';
import 'package:activefriends/features/import/data/feature_flag_service.dart';
import 'package:activefriends/features/import/data/health_sync_core.dart';
import 'package:activefriends/firebase_options.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:health/health.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:workmanager/workmanager.dart';

const kHealthSyncTask = 'healthSyncPeriodic';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    if (taskName != kHealthSyncTask) return true;
    // 'periodic' | 'oneoff' — both register under the same taskName, so the
    // trigger is carried in inputData (see _register).
    final trigger = inputData?['trigger'] as String?;
    return _executeBackgroundHealthSync(trigger: trigger);
  });
}

Future<bool> _executeBackgroundHealthSync({String? trigger}) async {
  try {
    WidgetsFlutterBinding.ensureInitialized();
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    if (!SupabaseConfig.isConfigured) return true;
    await Supabase.initialize(
      url: SupabaseConfig.url,
      publishableKey: SupabaseConfig.publishableKey,
    );
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return true; // no session — skip silently

    // Remote kill switch. If OFF, stop the OS waking us and exit.
    if (!await FeatureFlagService().autoSyncEnabled()) {
      await Workmanager().cancelByUniqueName(kHealthSyncTask);
      return true;
    }

    // Initialize local notifications for this background isolate so
    // SyncNotifier can post the "activities imported" banner.
    try {
      final fln = FlutterLocalNotificationsPlugin();
      await fln.initialize(const InitializationSettings(
        android: AndroidInitializationSettings('ic_notification'),
      ));
      await fln
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(const AndroidNotificationChannel(
            'outpace_sync',
            'Activity Sync',
            description: 'Notifications when activities are auto-imported',
            importance: Importance.low,
          ));
    } catch (e) {
      developer.log('Notification setup failed: $e', name: 'HealthSync');
    }

    await BackgroundSyncService.forBackgroundIsolate()
        .syncIncremental(userId: user.id, trigger: trigger);
    return true;
  } catch (e) {
    developer.log('Background health sync failed: $e', name: 'HealthSync');
    return false; // WorkManager retries
  }
}

/// Owns every OS-level auto-sync side effect (WorkManager, HealthKit channel,
/// Health Connect background-read request). The rest of the feature stays
/// platform-free and unit-testable; this is the one place device behaviour
/// lives.
class AutoSyncPlatform {
  AutoSyncPlatform({
    required this.callbackDispatcher,
    required this.kHealthSyncTask,
  });

  final void Function() callbackDispatcher;
  final String kHealthSyncTask;

  static const _channel = MethodChannel('app.activefriends.app/health_sync');

  /// Call once from `main` after `Supabase.initialize`. Sets up the iOS
  /// Dart-side handler and resolves the two-gate to register or tear down.
  Future<void> start() async {
    if (Platform.isIOS) {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'onHealthDataChanged') {
          final user = Supabase.instance.client.auth.currentUser;
          if (user == null) return null;
          await BackgroundSyncService.forMainIsolate()
              .syncIncremental(userId: user.id, trigger: 'ios_observer');
        }
        return null;
      });
    }
    await _manager().syncRegistration();
  }

  /// Re-evaluate the two-gate and register or tear down. Used by the UI toggle
  /// after the user changes their preference.
  Future<void> syncRegistration() => _manager().syncRegistration();

  AutoSyncManager _manager() => AutoSyncManager(
        flags: FeatureFlagService(),
        prefs: AutoSyncPreferences(),
        register: _register,
        teardown: _teardown,
      );

  Future<void> _register() async {
    if (Platform.isAndroid) {
      final health = Health();
      await health.configure();
      // Foreground grant. The background isolate's HealthSyncCore.ensureAuthorized
      // only VERIFIES permission (it has no Activity to launch the Health Connect
      // consent UI), so the READ grant must be requested HERE — _register runs
      // with an Activity (app start / the enable toggle). This covers users who
      // enable auto-sync without ever running a manual import (which has its own
      // foreground request). No-ops silently if already granted.
      await health.requestAuthorization(
        HealthSyncCore.authTypes,
        permissions:
            HealthSyncCore.authTypes.map((_) => HealthDataAccess.READ).toList(),
      );
      if (await health.isHealthDataInBackgroundAvailable() &&
          !await health.isHealthDataInBackgroundAuthorized()) {
        await health.requestHealthDataInBackgroundAuthorization();
      }
      await Workmanager().initialize(callbackDispatcher, isInDebugMode: false);
      await Workmanager().registerPeriodicTask(
        kHealthSyncTask,
        kHealthSyncTask,
        frequency: const Duration(minutes: 15),
        inputData: const {'trigger': 'periodic'},
        constraints: Constraints(
          networkType: NetworkType.connected,
          requiresBatteryNotLow: true,
        ),
        existingWorkPolicy: ExistingWorkPolicy.keep,
        backoffPolicy: BackoffPolicy.exponential,
        initialDelay: const Duration(minutes: 1),
      );
      // Enqueue an immediate one-off run so the first sync + notification
      // fire within seconds of the user enabling auto-sync.
      await Workmanager().registerOneOffTask(
        'healthSyncOnce',
        kHealthSyncTask,
        inputData: const {'trigger': 'oneoff'},
        existingWorkPolicy: ExistingWorkPolicy.keep,
        constraints: Constraints(networkType: NetworkType.connected),
      );
    } else if (Platform.isIOS) {
      await _channel.invokeMethod('enableBackgroundDelivery');
    }
  }

  Future<void> _teardown() async {
    if (Platform.isAndroid) {
      await Workmanager().cancelByUniqueName(kHealthSyncTask);
      await Workmanager().cancelByUniqueName('healthSyncOnce');
    } else if (Platform.isIOS) {
      await _channel.invokeMethod('disableBackgroundDelivery');
    }
  }
}
