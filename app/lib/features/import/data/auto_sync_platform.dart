import 'dart:io';

import 'package:activefriends/features/import/data/auto_sync_manager.dart';
import 'package:activefriends/features/import/data/auto_sync_preferences.dart';
import 'package:activefriends/features/import/data/background_sync_service.dart';
import 'package:activefriends/features/import/data/feature_flag_service.dart';
import 'package:flutter/services.dart';
import 'package:health/health.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:workmanager/workmanager.dart';

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
          await BackgroundSyncService.forBackgroundIsolate()
              .syncIncremental(userId: user.id);
        }
        return null;
      });
    }
    await _manager().syncRegistration();
  }

  AutoSyncManager _manager() => AutoSyncManager(
        flags: FeatureFlagService(),
        prefs: AutoSyncPreferences(),
        register: _register,
        teardown: _teardown,
      );

  Future<void> _register() async {
    if (Platform.isAndroid) {
      final health = Health();
      if (await health.isHealthDataInBackgroundAvailable() &&
          !await health.isHealthDataInBackgroundAuthorized()) {
        await health.requestHealthDataInBackgroundAuthorization();
      }
      await Workmanager().initialize(callbackDispatcher, isInDebugMode: false);
      await Workmanager().registerPeriodicTask(
        kHealthSyncTask,
        kHealthSyncTask,
        frequency: const Duration(minutes: 15),
        constraints: Constraints(
          networkType: NetworkType.connected,
          requiresBatteryNotLow: true,
        ),
        existingWorkPolicy: ExistingWorkPolicy.keep,
        backoffPolicy: BackoffPolicy.exponential,
        initialDelay: const Duration(minutes: 1),
      );
    } else if (Platform.isIOS) {
      await _channel.invokeMethod('enableBackgroundDelivery');
    }
  }

  Future<void> _teardown() async {
    if (Platform.isAndroid) {
      await Workmanager().cancelByUniqueName(kHealthSyncTask);
    } else if (Platform.isIOS) {
      await _channel.invokeMethod('disableBackgroundDelivery');
    }
  }
}
