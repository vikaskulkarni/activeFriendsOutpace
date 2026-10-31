import 'dart:developer' as developer;

import 'package:activefriends/core/app.dart';
import 'package:activefriends/core/config/supabase_config.dart';
import 'package:activefriends/core/data/connectivity_service.dart';
import 'package:activefriends/features/import/data/auto_sync_platform.dart';
import 'package:activefriends/features/import/data/background_sync_service.dart';
import 'package:activefriends/features/import/data/feature_flag_service.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:workmanager/workmanager.dart';

import 'firebase_options.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
}

const kHealthSyncTask = 'healthSyncPeriodic';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    if (taskName != kHealthSyncTask) return true;
    return _executeBackgroundHealthSync();
  });
}

Future<bool> _executeBackgroundHealthSync() async {
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

    await BackgroundSyncService.forBackgroundIsolate()
        .syncIncremental(userId: user.id);
    return true;
  } catch (e) {
    developer.log('Background health sync failed: $e', name: 'HealthSync');
    return false; // WorkManager retries
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  if (SupabaseConfig.isConfigured) {
    await Supabase.initialize(
      url: SupabaseConfig.url,
      publishableKey: SupabaseConfig.publishableKey,
      authOptions: FlutterAuthClientOptions(
        detectSessionInUriPredicate: (uri) =>
            uri.queryParameters.containsKey('code') ||
            uri.queryParameters.containsKey('access_token') ||
            (uri.queryParameters['type'] == 'recovery' &&
                uri.queryParameters.containsKey('token')) ||
            uri.fragment.contains('access_token='),
      ),
    );
  }
  await ConnectivityService.instance.initialize();
  if (SupabaseConfig.isConfigured) {
    await AutoSyncPlatform(
      callbackDispatcher: callbackDispatcher,
      kHealthSyncTask: kHealthSyncTask,
    ).start();
  }
  runApp(const ActiveFriendsApp());
}
