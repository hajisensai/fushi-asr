/// A conservative clock model for already matched subtitle/ASR boundaries.
/// This module never infers speech boundaries from character positions.
library;

import 'dart:math' as math;

const _maxGapMs = 180000;
const _ordinaryGapMs = 90000;
const _extrapolationMs = 30000;
const _residualMs = 2000.0;

class SubtitleClockAnchor {
  const SubtitleClockAnchor({
    required this.sourceMs,
    required this.targetMs,
    required this.cuePosition,
  });

  final int sourceMs;
  final int targetMs;

  /// One-based original cue position. Multiple endpoints of one cue supply
  /// only one independent vote when estimating its local clock.
  final int cuePosition;
}

class SubtitleClockMapping {
  SubtitleClockMapping._(
      this._regions, this.acceptedCueCount, this.rejectedCueCount);

  final List<_Region> _regions;
  final int acceptedCueCount;
  final int rejectedCueCount;
  int get regionCount => _regions.length;

  /// Both endpoints must lie in the same supported region. A cue crossing an
  /// uncertain edit, an unsupported gap, or an extrapolation limit is rejected.
  /// Applying this shared increasing clock to non-overlapping source cues
  /// preserves their order and separation; mixing it with untouched source
  /// timings still requires a caller-side conflict check.
  (int, int)? mapCue(int startMs, int endMs) {
    if (startMs < 0 || endMs <= startMs) return null;
    var low = 0;
    var high = _regions.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (_regions[middle].domainEnd < startMs) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    // Shared region boundaries may belong to either side. Do not let a cue
    // starting exactly on one prevent selection of the following region.
    for (var i = low; i < math.min(low + 2, _regions.length); i++) {
      final region = _regions[i];
      if (startMs < region.domainStart || endMs > region.domainEnd) continue;
      final start = region.map(startMs).round();
      final end = region.map(endMs).round();
      if (start >= 0 && end > start) return (start, end);
    }
    return null;
  }

  Map<String, Object?> toStats() => {
        'acceptedCueCount': acceptedCueCount,
        'rejectedCueCount': rejectedCueCount,
        'regionCount': regionCount,
        'maxExtrapolationMs': _extrapolationMs,
        'regions': [
          for (final region in _regions.take(50))
            {
              'sourceStartMs': region.domainStart.ceil(),
              'sourceEndMs': region.domainEnd.floor(),
              'firstAnchorMs': region.points.first.source,
              'lastAnchorMs': region.points.last.source,
              'cueCount': region.points.length,
              'rate': region.rate,
              'offsetMs': region.offset.round(),
            },
        ],
      };
}

/// Fit local offset/drift models only with >= 4 independently matched cues.
/// Every retained region needs >= 2 cue votes at distinct times. Stable clocks
/// retain a rate of 1, preserving cue durations exactly. Well-supported drift
/// is limited to +/-10%; version cuts create separate supported regions.
SubtitleClockMapping? fitSubtitleClock(List<SubtitleClockAnchor> anchors) {
  if (anchors.length > 40000) return null;
  final byCue = <int, List<SubtitleClockAnchor>>{};
  for (final anchor in anchors) {
    if (anchor.sourceMs < 0 ||
        anchor.targetMs < 0 ||
        anchor.sourceMs > 360000000000 ||
        anchor.targetMs > 360000000000 ||
        anchor.cuePosition < 1) {
      continue;
    }
    byCue.putIfAbsent(anchor.cuePosition, () => []).add(anchor);
  }
  if (byCue.length < 4) return null;
  final targets = <int, List<SubtitleClockAnchor>>{};
  for (final values in byCue.values) {
    for (final anchor in values) {
      targets.putIfAbsent(anchor.targetMs, () => []).add(anchor);
    }
  }
  final independent = <int, List<SubtitleClockAnchor>>{};
  for (final values in targets.values) {
    final cuePositions = values.map((a) => a.cuePosition).toSet();
    if (cuePositions.length > 1) {
      // A repeated ASR edge is one observation, regardless of how many source
      // cue prefixes matched it. Different source positions make it ambiguous;
      // identical neighboring source edges can contribute exactly one vote.
      if (values.any((a) => a.sourceMs != values.first.sourceMs)) continue;
      final first = values.first;
      independent.putIfAbsent(first.cuePosition, () => []).add(first);
    } else {
      independent
          .putIfAbsent(values.first.cuePosition, () => [])
          .addAll(values);
    }
  }
  if (independent.length < 4) return null;
  final points = <_Point>[
    for (final entry in independent.entries)
      _Point(
          _median(entry.value.map((a) => a.sourceMs.toDouble()).toList()),
          _median(entry.value
              .map((a) => (a.targetMs - a.sourceMs).toDouble())
              .toList()),
          entry.key),
  ]..sort((a, b) => a.source.compareTo(b.source));
  final groups = <List<_Point>>[];
  var current = <_Point>[];
  for (var i = 0; i < points.length; i++) {
    final point = points[i];
    if (current.isEmpty || _compatible(current.last, point)) {
      current.add(point);
      continue;
    }
    final next = i + 1 < points.length ? points[i + 1] : null;
    // An isolated jump which immediately returns to the previous clock is
    // not a version edit. Keep the region and discard that single cue vote.
    if (next != null &&
        !_compatible(point, next) &&
        _compatible(current.last, next)) {
      continue;
    }
    groups.add(current);
    current = [point];
  }
  if (current.isNotEmpty) groups.add(current);
  final regions = <_Region>[];
  for (final group in groups) {
    final fit = _fit(group);
    if (fit == null) continue;
    // Removing an outlier must not accidentally bridge an unsupported gap.
    var chunk = <_Point>[];
    for (final point in fit.points) {
      if (chunk.isNotEmpty && !_compatible(chunk.last, point)) {
        final local = _fit(chunk);
        if (local != null) regions.add(local);
        chunk = [];
      }
      chunk.add(point);
    }
    final local = _fit(chunk);
    if (local != null) regions.add(local);
  }
  if (regions.isEmpty) return null;
  // A noisy run may have separated two groups before its outliers were
  // rejected. If the surviving clocks agree, join their support instead of
  // leaving an artificial midpoint seam which would strand a crossing cue.
  final merged = <_Region>[];
  for (final region in regions) {
    final joint = merged.isEmpty ? null : _merge(merged.last, region);
    if (joint == null) {
      merged.add(region);
    } else {
      merged[merged.length - 1] = joint;
    }
  }
  regions
    ..clear()
    ..addAll(merged);
  // Retain a monotonic set of supported regions. Contradictory neighboring
  // clocks cannot both map the source ordering, even without extrapolation.
  var i = 1;
  while (i < regions.length) {
    final left = regions[i - 1];
    final right = regions[i];
    if (left.map(left.points.last.source) >
        right.map(right.points.first.source)) {
      if (left.points.length < right.points.length) {
        regions.removeAt(i - 1);
      } else {
        regions.removeAt(i);
      }
      i = math.max(1, i - 1);
    } else {
      i++;
    }
  }
  for (var i = 1; i < regions.length; i++) {
    final left = regions[i - 1];
    final right = regions[i];
    final sourceMiddle =
        (left.points.last.source + right.points.first.source) / 2;
    left.domainEnd = math.min(left.domainEnd, sourceMiddle);
    right.domainStart = math.max(right.domainStart, sourceMiddle);
    if (left.map(left.domainEnd) > right.map(right.domainStart)) {
      // A negative version offset needs a source gap. Shrink the extrapolation
      // windows towards their actual anchors instead of reversing output time
      // or spreading the cut across speech with an invented fast clock.
      final targetMiddle = (left.map(left.points.last.source) +
              right.map(right.points.first.source)) /
          2;
      left.domainEnd = math.min(left.domainEnd, left.inverse(targetMiddle));
      right.domainStart =
          math.max(right.domainStart, right.inverse(targetMiddle));
    }
  }
  final accepted = regions.fold<int>(0, (n, r) => n + r.points.length);
  if (accepted < 4) return null;
  return SubtitleClockMapping._(regions, accepted, byCue.length - accepted);
}

class _Point {
  const _Point(this.source, this.shift, this.cuePosition);
  final double source;
  final double shift;
  final int cuePosition;
  double get target => source + shift;
}

bool _compatible(_Point left, _Point right) {
  final gap = right.source - left.source;
  if (gap < 0 || gap > _maxGapMs) return false;
  final difference = (right.shift - left.shift).abs();
  // Sparse same-version anchors can support a constant clock across up to
  // three minutes. A long gap plus a clock jump remains an uncertain cut.
  if (gap > _ordinaryGapMs) return difference <= 1500;
  return difference <= 2000 + math.min(2000, gap * 0.05);
}

class _Region {
  _Region(this.points, this.rate, this.offset)
      : domainStart = math.max(0,
            math.max(points.first.source - _extrapolationMs, -offset / rate)),
        domainEnd = points.last.source + _extrapolationMs;
  final List<_Point> points;
  final double rate;
  final double offset;
  double domainStart;
  double domainEnd;
  double map(num source) => rate * source + offset;
  double inverse(double target) => (target - offset) / rate;
}

_Region? _merge(_Region left, _Region right) {
  final leftEdge = left.points.last.source;
  final rightEdge = right.points.first.source;
  if (rightEdge - leftEdge > _maxGapMs ||
      rightEdge < leftEdge ||
      (left.map(leftEdge) - right.map(leftEdge)).abs() > 500 ||
      (left.map(rightEdge) - right.map(rightEdge)).abs() > 500) {
    return null;
  }
  final points = [...left.points, ...right.points];
  final joint = _fit(points);
  if (joint == null || joint.points.length < points.length * 0.9) return null;
  final retained = joint.points.map((p) => p.cuePosition).toSet();
  if (left.points.where((p) => retained.contains(p.cuePosition)).length < 2 ||
      right.points.where((p) => retained.contains(p.cuePosition)).length < 2) {
    return null;
  }
  for (var i = 1; i < joint.points.length; i++) {
    if (!_compatible(joint.points[i - 1], joint.points[i])) return null;
  }
  return joint;
}

_Region? _fit(List<_Point> points) {
  if (points.length < 2 || points.last.source - points.first.source < 1000) {
    return null;
  }
  var rate = _robustRate(points);
  var offset = _median(points.map((p) => p.target - rate * p.source).toList());
  var inliers = points
      .where(
          (p) => (p.target - (rate * p.source + offset)).abs() <= _residualMs)
      .toList();
  if (inliers.length < 2 || inliers.last.source - inliers.first.source < 1000) {
    return null;
  }
  rate = _robustRate(inliers);
  offset = _median(inliers.map((p) => p.target - rate * p.source).toList());
  inliers = inliers
      .where(
          (p) => (p.target - (rate * p.source + offset)).abs() <= _residualMs)
      .toList();
  if (inliers.length < 2 || inliers.last.source - inliers.first.source < 1000) {
    return null;
  }
  return _Region(inliers, rate, offset);
}

double _robustRate(List<_Point> points) {
  final span = points.last.source - points.first.source;
  if (points.length < 4 || span < 60000) return 1;
  // Bounded Theil-Sen estimate: quantile sampling retains coverage of the
  // complete local region without allocating a quadratic matrix for a movie.
  final sampleCount = math.min(32, points.length);
  final sampled = [
    for (var i = 0; i < sampleCount; i++)
      points[(i * (points.length - 1) / (sampleCount - 1)).round()],
  ];
  final slopes = <double>[];
  for (var i = 0; i < sampled.length; i++) {
    for (var j = i + 1; j < sampled.length; j++) {
      final gap = sampled[j].source - sampled[i].source;
      if (gap >= 15000) {
        slopes.add((sampled[j].target - sampled[i].target) / gap);
      }
    }
  }
  if (slopes.isEmpty) return 1;
  final rate = _median(slopes);
  if (rate < 0.9 || rate > 1.1 || (rate - 1).abs() * span < 1500) return 1;
  return rate;
}

double _median(List<double> values) {
  values.sort();
  final middle = values.length ~/ 2;
  return values.length.isOdd
      ? values[middle]
      : (values[middle - 1] + values[middle]) / 2;
}
