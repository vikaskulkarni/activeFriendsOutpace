class ActivityFingerprint {
  const ActivityFingerprint({
    required this.externalId,
    required this.activityType,
    required this.startedAt,
    required this.endedAt,
  });

  final String externalId;
  final String activityType;
  final DateTime startedAt;
  final DateTime endedAt;
}

class DuplicateDetector {
  const DuplicateDetector._();

  static ActivityFingerprint? findCandidate({
    required ActivityFingerprint activity,
    required Iterable<ActivityFingerprint> candidates,
  }) {
    for (final candidate in candidates) {
      if (candidate.externalId == activity.externalId || !_typesMatch(activity.activityType, candidate.activityType)) continue;
      final shorterDuration = _duration(activity).compareTo(_duration(candidate)) <= 0 ? _duration(activity) : _duration(candidate);
      if (shorterDuration <= Duration.zero) continue;
      if (_overlap(activity, candidate) > shorterDuration * 0.8) return candidate;
    }
    return null;
  }

  static bool _typesMatch(String left, String right) => left == 'other' || right == 'other' || left == right;

  /// Returns true when the windows [aStart]–[aEnd] and [bStart]–[bEnd] overlap
  /// by more than [threshold] of the SHORTER window's duration. Integer-second
  /// math; type-agnostic. Returns false for any non-positive duration or no
  /// overlap. Shared by the import-time skip and the GPS-save supersede check
  /// so the two directions use identical math.
  static bool overlapExceeds(
    DateTime aStart,
    DateTime aEnd,
    DateTime bStart,
    DateTime bEnd, {
    double threshold = 0.7,
  }) {
    final aDuration = aEnd.difference(aStart).inSeconds;
    final bDuration = bEnd.difference(bStart).inSeconds;
    if (aDuration <= 0 || bDuration <= 0) return false;
    final overlapStart = aStart.isAfter(bStart) ? aStart : bStart;
    final overlapEnd = aEnd.isBefore(bEnd) ? aEnd : bEnd;
    final overlapSeconds = overlapEnd.difference(overlapStart).inSeconds;
    if (overlapSeconds <= 0) return false;
    final shorterDuration = aDuration < bDuration ? aDuration : bDuration;
    return overlapSeconds / shorterDuration > threshold;
  }

  static Duration _duration(ActivityFingerprint activity) => activity.endedAt.difference(activity.startedAt);

  static Duration _overlap(ActivityFingerprint left, ActivityFingerprint right) {
    final start = left.startedAt.isAfter(right.startedAt) ? left.startedAt : right.startedAt;
    final end = left.endedAt.isBefore(right.endedAt) ? left.endedAt : right.endedAt;
    return end.isAfter(start) ? end.difference(start) : Duration.zero;
  }
}