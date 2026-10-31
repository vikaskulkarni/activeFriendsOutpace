import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:activefriends/data/local/app_database.dart' as local;
import 'package:activefriends/features/tracking/data/tracking_local_repository.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

class TrackingSnapshot {
  const TrackingSnapshot({
    required this.startedAt,
    required this.elapsed,
    required this.movingTime,
    required this.isAutoPaused,
    required this.isManuallyPaused,
    required this.distanceM,
    required this.elevationGainM,
    required this.acceptedFixes,
    required this.receivedFixes,
    required this.rejectedAccuracyFixes,
    required this.rejectedSpeedFixes,
    required this.lastAccuracyM,
    required this.points,
  });

  final DateTime startedAt;
  final Duration elapsed;
  final Duration movingTime;
  final bool isAutoPaused;
  final bool isManuallyPaused;

  bool get isPaused => isAutoPaused || isManuallyPaused;
  final double distanceM;
  final double elevationGainM;
  final int acceptedFixes;
  final int receivedFixes;
  final int rejectedAccuracyFixes;
  final int rejectedSpeedFixes;
  final double? lastAccuracyM;
  final List<TrackingPoint> points;

  double get paceSecondsPerKm =>
      distanceM <= 0 ? 0 : movingTime.inSeconds / (distanceM / 1000);

  double get maxSpeedKmh {
    var maximum = 0.0;
    for (var index = 1; index < points.length; index++) {
      final seconds = points[index].timestamp
          .difference(points[index - 1].timestamp)
          .inSeconds;
      if (seconds <= 0) continue;
      final segmentM = Geolocator.distanceBetween(
        points[index - 1].latitude,
        points[index - 1].longitude,
        points[index].latitude,
        points[index].longitude,
      );
      final speedKmh = segmentM / seconds * 3.6;
      if (speedKmh > maximum && speedKmh <= 43.2) maximum = speedKmh;
    }
    return maximum;
  }

  double get maxElevationM => points.isEmpty
      ? 0
      : points.map((point) => point.elevation).reduce((a, b) => a > b ? a : b);
}

class TrackingPoint {
  const TrackingPoint({
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    required this.elevation,
    required this.accuracy,
  });

  final double latitude;
  final double longitude;
  final DateTime timestamp;
  final double elevation;
  final double accuracy;
}

class GpsTracker {
  GpsTracker(this._localRepository);

  final TrackingLocalRepository _localRepository;
  StreamSubscription<Position>? _positions;
  Position? _previous;
  DateTime? _startedAt;
  GpsDistanceAccumulator _distanceAcc = GpsDistanceAccumulator();
  double _elevationGainM = 0;
  Duration _movingTime = Duration.zero;
  AutoPauseDetector _pauseDetector =
      AutoPauseDetector(pauseSpeedMs: 0.7, resumeSpeedMs: 1.4);
  bool _manuallyPaused = false;
  String? _activeSessionId;
  int _acceptedFixes = 0;
  int _receivedFixes = 0;
  int _rejectedAccuracyFixes = 0;
  int _rejectedSpeedFixes = 0;
  double? _lastAccuracyM;
  final List<TrackingPoint> _points = [];

  TrackingSnapshot? get snapshot {
    final startedAt = _startedAt;
    if (startedAt == null) return null;
    return TrackingSnapshot(
      startedAt: startedAt,
      elapsed: DateTime.now().difference(startedAt),
      movingTime: _movingTime,
      isAutoPaused: _pauseDetector.isPaused,
      isManuallyPaused: _manuallyPaused,
      distanceM: _distanceAcc.distanceM,
      elevationGainM: _elevationGainM,
      acceptedFixes: _acceptedFixes,
      receivedFixes: _receivedFixes,
      rejectedAccuracyFixes: _rejectedAccuracyFixes,
      rejectedSpeedFixes: _rejectedSpeedFixes,
      lastAccuracyM: _lastAccuracyM,
      points: List.unmodifiable(_points),
    );
  }

  Future<void> start(
    void Function(TrackingSnapshot snapshot) onUpdate, {
    required String sessionId,
    required String activityType,
    local.TrackingSession? restoredSession,
    List<local.TrackingPoint> restoredPoints = const [],
    void Function(Object error)? onError,
  }) async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const TrackingException('Location services are turned off.');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw const TrackingException('Location permission was not granted.');
    }

    _startedAt = restoredSession?.startedAt ?? DateTime.now();
    _activeSessionId = sessionId;
    _manuallyPaused = false;
    _pauseDetector = AutoPauseDetector(
      pauseSpeedMs: activityType == 'walk' ? 0.5 : 0.7,
      resumeSpeedMs: activityType == 'walk' ? 0.8 : 1.4,
      initiallyPaused: restoredSession?.status == 'paused',
    );
    _distanceAcc = GpsDistanceAccumulator(
      initialDistanceM: restoredSession?.distanceM ?? 0,
    );
    _elevationGainM = restoredSession?.elevationGainM ?? 0;
    _movingTime = Duration(seconds: restoredSession?.movingTimeS ?? 0);
    _acceptedFixes = restoredSession?.acceptedFixes ?? 0;
    _receivedFixes = 0;
    _rejectedAccuracyFixes = 0;
    _rejectedSpeedFixes = 0;
    _lastAccuracyM = null;
    _points
      ..clear()
      ..addAll(
        restoredPoints.map(
          (point) => TrackingPoint(
            latitude: point.latitude,
            longitude: point.longitude,
            timestamp: point.timestamp,
            elevation: point.elevation,
            accuracy: point.accuracy,
          ),
        ),
      );
    _previous = null;
    final LocationSettings settings;
    if (Platform.isIOS) {
      settings = AppleSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 1,
        activityType: ActivityType.fitness,
        allowBackgroundLocationUpdates: true,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: true,
      );
    } else {
      settings = AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 1,
        intervalDuration: const Duration(seconds: 2),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'OUTPACE is tracking',
          notificationText: 'Your activity is being recorded.',
          notificationChannelName: 'Activity tracking',
          enableWakeLock: true,
          setOngoing: true,
        ),
      );
    }
    _positions = Geolocator.getPositionStream(locationSettings: settings)
        .listen((position) async {
          _receivedFixes++;
          _lastAccuracyM = position.accuracy;
          if (position.accuracy > 50) {
            _rejectedAccuracyFixes++;
            return;
          }
          final previous = _previous;
          // Auto-pause via the detector: speed when the platform reports it
          // (Android), net displacement when it doesn't (iOS withholds speed at
          // walking pace → `hasSpeed == false`, a 0.0 placeholder that must NOT
          // be read as "stopped" or it false-pauses mid-walk and drops distance).
          final wasPaused = _pauseDetector.isPaused;
          _pauseDetector.update(
            speedKnown: position.hasSpeed && position.speed.isFinite,
            speed: position.speed,
            latitude: position.latitude,
            longitude: position.longitude,
            timestamp: position.timestamp,
          );
          final nowPaused = _pauseDetector.isPaused;
          if (!wasPaused && nowPaused) {
            _distanceAcc.resetAnchor();
            await _localRepository.updateStatus(sessionId, 'paused');
          } else if (wasPaused && !nowPaused) {
            await _localRepository.updateStatus(sessionId, 'active');
          }
          if (previous != null) {
            final segmentM = Geolocator.distanceBetween(
              previous.latitude,
              previous.longitude,
              position.latitude,
              position.longitude,
            );
            final durationS = position.timestamp
                .difference(previous.timestamp)
                .inSeconds;
            final segmentSpeed = durationS <= 0 ? 0 : segmentM / durationS;
            if (segmentSpeed > 12) {
              _rejectedSpeedFixes++;
              return;
            }
            if (!_pauseDetector.isPaused && durationS > 0 && !_manuallyPaused) {
              _movingTime += Duration(seconds: durationS);
            }
            // ── Distance via net-displacement anchoring ───────────────
            // Summing every raw Haversine segment inflates distance (GPS
            // jitter random-walk). A per-segment minimum instead DROPS real
            // ~1 m walking steps — distanceFilter:1 samples ~every metre, so
            // real walk segments straddle the old 1.5 m gate — which
            // under-counted walks 18-40%. GpsDistanceAccumulator commits
            // distance only once a fix has moved `thresholdM` from the anchor,
            // so sub-threshold jitter cancels while real movement accumulates.
            // Cycling is unaffected (its segments already exceed the
            // threshold). Elevation gain stays per-fix.
            if (!_pauseDetector.isPaused && !_manuallyPaused) {
              _distanceAcc.addFix(
                latitude: position.latitude,
                longitude: position.longitude,
                accuracy: position.accuracy,
              );
              final climb = position.altitude - previous.altitude;
              if (climb >= 3 &&
                  previous.accuracy <= 20 &&
                  position.accuracy <= 20) {
                _elevationGainM += climb;
              }
            }
          }
          _previous = position;
          _acceptedFixes++;
          _points.add(
            TrackingPoint(
              latitude: position.latitude,
              longitude: position.longitude,
              timestamp: position.timestamp,
              elevation: position.altitude,
              accuracy: position.accuracy,
            ),
          );
          final current = snapshot;
          if (current != null) {
            await _localRepository.savePoint(
              sessionId: sessionId,
              sequence: _points.length - 1,
              point: TrackingPointData(
                latitude: position.latitude,
                longitude: position.longitude,
                timestamp: position.timestamp,
                elevation: position.altitude,
                accuracy: position.accuracy,
              ),
              distanceM: _distanceAcc.distanceM,
              elevationGainM: _elevationGainM,
              movingTimeS: _movingTime.inSeconds,
              status: _pauseDetector.isPaused ? 'paused' : 'active',
            );
            onUpdate(current);
          }
        }, onError: (Object error, StackTrace _) => onError?.call(error));
  }

  Future<void> pause() async {
    if (_manuallyPaused || _activeSessionId == null) return;
    _manuallyPaused = true;
    _distanceAcc.resetAnchor();
    await _localRepository.updateStatus(_activeSessionId!, 'paused');
  }

  Future<void> resume() async {
    if (_activeSessionId == null) return;
    _manuallyPaused = false;
    _pauseDetector.reset();
    await _localRepository.updateStatus(_activeSessionId!, 'active');
  }

  Future<TrackingSnapshot?> stop() async {
    await _positions?.cancel();
    _positions = null;
    return snapshot;
  }

  Future<void> dispose() => _positions?.cancel() ?? Future.value();
}

/// Accumulates GPS distance using net-displacement anchoring to suppress GPS
/// jitter without discarding real movement.
///
/// Why not sum raw segments or use a per-segment minimum: at
/// `distanceFilter: 1` the OS emits a fix roughly every metre, so summing every
/// Haversine segment inflates distance (jitter random-walk), while a
/// per-segment minimum (the old `segmentM >= 1.5` gate) DROPS real ~1 m walking
/// steps and under-counted walks 18-40%. A single 1 m step is also smaller than
/// GPS accuracy (~9 m), so real-vs-jitter can't be judged per segment — only
/// via NET displacement over several fixes, where jitter cancels and real
/// movement survives.
///
/// Anchoring: keep an anchor point; only when a fix has moved [thresholdM] from
/// it do we add that displacement and advance the anchor. Cycling is unaffected
/// — its segments already exceed the threshold.
@visibleForTesting
class GpsDistanceAccumulator {
  GpsDistanceAccumulator({this.thresholdM = 8.0, double initialDistanceM = 0})
    : _distanceM = initialDistanceM;

  /// Net displacement (m) a fix must travel from the anchor before its movement
  /// is counted. ≈ GPS accuracy: large enough that jitter cancels, small enough
  /// to preserve route curvature. The on-device tuning knob — validate against
  /// a known loop / Strava before changing.
  final double thresholdM;

  /// Fixes looser than this never move the anchor or commit distance: a loose
  /// fix can sit `accuracy` metres from truth and fake a real move.
  static const double maxAnchorAccuracyM = 30;

  double _distanceM;
  double? _anchorLat;
  double? _anchorLon;

  double get distanceM => _distanceM;

  /// Drop the anchor (e.g. on pause). The next accurate fix re-anchors without
  /// committing the gap, so movement during a pause isn't counted.
  void resetAnchor() {
    _anchorLat = null;
    _anchorLon = null;
  }

  /// Feed one accepted fix. Returns the distance (m) this fix committed (0 if
  /// it was jitter, below threshold, or too inaccurate to anchor on).
  double addFix({
    required double latitude,
    required double longitude,
    required double accuracy,
  }) {
    if (accuracy > maxAnchorAccuracyM) return 0;
    final anchorLat = _anchorLat;
    final anchorLon = _anchorLon;
    if (anchorLat == null || anchorLon == null) {
      _anchorLat = latitude;
      _anchorLon = longitude;
      return 0;
    }
    final moved = _haversineM(anchorLat, anchorLon, latitude, longitude);
    if (moved < thresholdM) return 0;
    _distanceM += moved;
    _anchorLat = latitude;
    _anchorLon = longitude;
    return moved;
  }

  static double _haversineM(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const earthRadiusM = 6371000.0;
    final dLat = _toRad(lat2 - lat1);
    final dLon = _toRad(lon2 - lon1);
    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_toRad(lat1)) *
            math.cos(_toRad(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return earthRadiusM * 2 * math.asin(math.min(1.0, math.sqrt(a)));
  }

  static double _toRad(double degrees) => degrees * math.pi / 180.0;
}

/// Decides when to auto-pause/resume, robust to platforms that withhold speed.
///
/// On Android `Position.speed` is reliable, so movement is judged by speed with
/// hysteresis (pause below [pauseSpeedMs], resume above [resumeSpeedMs]) — the
/// original, proven behaviour. On iOS `CLLocation.speed` is frequently
/// unavailable at walking pace, arriving as a `0.0` placeholder with
/// `hasSpeed == false`; treating that as "stopped" false-paused mid-walk and
/// dropped ~half the distance. When speed is unknown, movement is judged by NET
/// DISPLACEMENT instead: the user is "moving" once a fix is more than
/// [moveThresholdM] from the stillness anchor, so real walking never pauses
/// while a genuine standstill (jitter only) still does after [stillWindow].
@visibleForTesting
class AutoPauseDetector {
  AutoPauseDetector({
    required this.pauseSpeedMs,
    required this.resumeSpeedMs,
    this.stillWindow = const Duration(seconds: 20),
    this.moveThresholdM = 8.0,
    bool initiallyPaused = false,
  }) : _paused = initiallyPaused;

  final double pauseSpeedMs;
  final double resumeSpeedMs;
  final Duration stillWindow;

  /// Net metres a fix must sit from the stillness anchor to count as moving when
  /// speed is unknown. ≈ GPS accuracy: jitter stays under it, a real walker
  /// clears it within [stillWindow]. The on-device tuning knob.
  final double moveThresholdM;

  bool _paused;
  DateTime? _stillSince;
  double? _anchorLat;
  double? _anchorLon;

  bool get isPaused => _paused;

  /// Clear auto-pause and the movement anchor (e.g. on manual resume).
  void reset() {
    _paused = false;
    _stillSince = null;
    _anchorLat = null;
    _anchorLon = null;
  }

  /// Feed one accepted fix, updating [isPaused]. [speedKnown] MUST be false when
  /// the platform did not report speed (iOS at walking pace) — then movement is
  /// judged by displacement rather than the placeholder `0.0` speed.
  void update({
    required bool speedKnown,
    required double speed,
    required double latitude,
    required double longitude,
    required DateTime timestamp,
  }) {
    final bool moving;
    if (speedKnown) {
      // Hysteresis: higher bar to resume than to keep going.
      moving = _paused ? speed > resumeSpeedMs : speed >= pauseSpeedMs;
    } else {
      final anchorLat = _anchorLat;
      final anchorLon = _anchorLon;
      moving = anchorLat != null &&
          anchorLon != null &&
          GpsDistanceAccumulator._haversineM(
                  anchorLat, anchorLon, latitude, longitude) >
              moveThresholdM;
    }

    if (moving) {
      _stillSince = null;
      _paused = false;
      _anchorLat = latitude;
      _anchorLon = longitude;
    } else {
      _stillSince ??= timestamp;
      if (!_paused && timestamp.difference(_stillSince!) >= stillWindow) {
        _paused = true;
      }
      // Anchor stays put while still so displacement is measured from where the
      // stillness began; initialise it on the first still fix.
      _anchorLat ??= latitude;
      _anchorLon ??= longitude;
    }
  }
}

class TrackingException implements Exception {
  const TrackingException(this.message);

  final String message;

  @override
  String toString() => message;
}
