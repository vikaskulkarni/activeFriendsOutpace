import 'dart:developer' as developer;

import 'package:activefriends/features/import/data/auto_sync_platform.dart';
import 'package:activefriends/features/import/data/auto_sync_preferences.dart';
import 'package:activefriends/features/import/data/feature_flag_service.dart';
import 'package:activefriends/features/import/data/health_import_service.dart';
import 'package:flutter/material.dart';

class WatchImportSection extends StatefulWidget {
  const WatchImportSection({
    super.key,
    this._autoSyncPrefs,
    this._flags,
    this._onToggle,
  });

  final AutoSyncPreferences? _autoSyncPrefs;
  final FeatureFlagService? _flags;
  final Future<void> Function()? _onToggle;

  @override
  State<WatchImportSection> createState() => _WatchImportSectionState();
}

class _WatchImportSectionState extends State<WatchImportSection> {
  late final _service = HealthImportService();
  var _isImporting = false;
  String? _message;

  late final AutoSyncPreferences _prefs =
      widget._autoSyncPrefs ?? AutoSyncPreferences();
  late final FeatureFlagService _flagsSvc = widget._flags ?? FeatureFlagService();
  bool _autoSyncOn = false;
  bool _remoteAllowed = false;
  DateTime? _lastSynced;

  @override
  void initState() {
    super.initState();
    _loadAutoSyncState();
  }

  Future<void> _loadAutoSyncState() async {
    final on = await _prefs.isEnabled();
    final remote = await _flagsSvc.autoSyncEnabled();
    final last = await _prefs.lastSuccess();
    if (mounted) {
      setState(() {
        _autoSyncOn = on;
        _remoteAllowed = remote;
        _lastSynced = last;
      });
    }
  }

  Future<void> _toggleAutoSync(bool value) async {
    await _prefs.setEnabled(value);
    setState(() => _autoSyncOn = value);
    final onToggle = widget._onToggle;
    if (onToggle != null) {
      await onToggle();
    } else {
      // Real platform path: resolve the two-gate and register/teardown.
      await AutoSyncPlatform(
        callbackDispatcher: callbackDispatcher,
        kHealthSyncTask: kHealthSyncTask,
      ).syncRegistration();
    }
  }

  String _relative(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }

  Future<void> _import() async {
    setState(() {
      _isImporting = true;
      _message = null;
    });
    try {
      final result = await _service.importRecentWorkouts();
      if (mounted) {
        setState(() {
          final parts = <String>[];
          if (result.importedCount > 0) {
            final a = result.importedCount == 1 ? 'activity' : 'activities';
            parts.add('${result.importedCount} new $a synced');
          }
          if (result.alreadySyncedCount > 0) {
            parts.add('${result.alreadySyncedCount} already synced');
          }
          if (result.skippedDuplicates > 0) {
            final a = result.skippedDuplicates == 1 ? 'activity' : 'activities';
            parts.add('${result.skippedDuplicates} $a tracked via Outpace');
          }
          if (result.queuedCount > 0) {
            parts.add('${result.queuedCount} queued for sync');
          }
          var summary = parts.isEmpty
              ? 'No new activities found in your health hub.'
              : '${parts.join(' · ')}.';
          if (!result.historyAuthorized) {
            summary = '$summary Older history was not authorized.';
          }
          // The raw diagnostics are non-empty only when nothing came through.
          _message = result.diagnostics.isEmpty
              ? summary
              : '$summary\n\n${result.diagnostics}';
        });
      }
    } on HealthImportException catch (error) {
      if (mounted) setState(() => _message = error.message);
    } catch (error, stack) {
      developer.log('Watch import failed', error: error, stackTrace: stack, name: 'WatchImport');
      if (mounted) setState(() => _message = 'Watch import could not finish.\n\nDetails: $error');
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(child: Text('Auto-Sync')),
            Switch(
              value: _autoSyncOn,
              onChanged: _remoteAllowed || _autoSyncOn
                  ? (v) => _toggleAutoSync(v)
                  : null,
            ),
          ],
        ),
        Text(
          _remoteAllowed
              ? 'Automatically import new workouts when your watch syncs.'
              : 'Auto-sync is currently unavailable.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (_lastSynced != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Last sync: ${_relative(_lastSynced!)}',
                style: Theme.of(context).textTheme.bodySmall),
          ),
        const Divider(height: 24),
        Row(
          children: [
            Expanded(child: Text('Health Connect or Apple Health', style: Theme.of(context).textTheme.bodyMedium)),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: _isImporting ? null : _import,
              icon: const Icon(Icons.watch_outlined, size: 18),
              label: Text(_isImporting ? 'Syncing' : 'Import'),
            ),
          ],
        ),
        if (_message != null) ...[
          const SizedBox(height: 8),
          SelectableText(_message!),
        ],
      ],
    );
  }
}
