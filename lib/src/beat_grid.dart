import 'dart:math' as math;

/// A tempo change event starting at [beat] with a new [bpm].
final class BeatTempoEvent {
  final double beat;
  final double bpm;

  const BeatTempoEvent({
    required this.beat,
    required this.bpm,
  }) : assert(bpm > 0.0, 'BPM must be positive');

  double get beatDurationSeconds => 60.0 / bpm;
}

final class _TempoSegment {
  final double startBeat;
  final double startSeconds;
  final double bpm;

  const _TempoSegment({
    required this.startBeat,
    required this.startSeconds,
    required this.bpm,
  });

  double get secPerBeat => 60.0 / bpm;
}

/// Maps musical beats <-> song seconds with optional tempo map and DSP latency offset.
final class BeatGrid {
  double bpm;
  int beatsPerBar;
  int subdivision;
  double audioOffsetSeconds;

  final List<BeatTempoEvent> _tempoChanges;
  final List<_TempoSegment> _segments = [];

  BeatGrid({
    this.bpm = 120.0,
    this.beatsPerBar = 4,
    this.subdivision = 4,
    this.audioOffsetSeconds = 0.0,
    List<BeatTempoEvent> tempoChanges = const [],
  }) : _tempoChanges = List<BeatTempoEvent>.from(tempoChanges) {
    _rebuildSegments();
  }

  List<BeatTempoEvent> get tempoChanges => List.unmodifiable(_tempoChanges);

  double get baseBeatDurationSeconds => 60.0 / math.max(1.0, bpm);
  double get audioOffsetMs => audioOffsetSeconds * 1000.0;

  void setBaseBpm(double nextBpm) {
    bpm = math.max(1.0, nextBpm);
    _rebuildSegments();
  }

  void setTempoChanges(List<BeatTempoEvent> events) {
    _tempoChanges
      ..clear()
      ..addAll(events);
    _rebuildSegments();
  }

  void _rebuildSegments() {
    _segments.clear();
    final baseBpm = math.max(1.0, bpm);
    if (_tempoChanges.isEmpty) {
      _segments.add(_TempoSegment(startBeat: 0.0, startSeconds: 0.0, bpm: baseBpm));
      return;
    }

    final sorted = List<BeatTempoEvent>.from(_tempoChanges)
      ..sort((a, b) => a.beat.compareTo(b.beat));

    var curBeat = 0.0;
    var curSec = 0.0;
    var curBpm = baseBpm;

    if (sorted.first.beat <= 0.0) {
      curBpm = math.max(1.0, sorted.first.bpm);
    }
    _segments.add(_TempoSegment(startBeat: curBeat, startSeconds: curSec, bpm: curBpm));

    for (final ev in sorted) {
      if (ev.beat <= 0.0) {
        curBpm = math.max(1.0, ev.bpm);
        _segments[0] = _TempoSegment(startBeat: 0.0, startSeconds: 0.0, bpm: curBpm);
        continue;
      }
      final deltaBeats = ev.beat - curBeat;
      if (deltaBeats > 1e-9) {
        curSec += deltaBeats * (60.0 / curBpm);
        curBeat = ev.beat;
        curBpm = math.max(1.0, ev.bpm);
        _segments.add(_TempoSegment(startBeat: curBeat, startSeconds: curSec, bpm: curBpm));
      } else {
        curBpm = math.max(1.0, ev.bpm);
        _segments[_segments.length - 1] =
            _TempoSegment(startBeat: curBeat, startSeconds: curSec, bpm: curBpm);
      }
    }
  }

  /// Uncompensated musical time in seconds for [beat] from song beat 0.
  double beatToSeconds(double beat) {
    if (_segments.isEmpty) _rebuildSegments();
    if (beat < 0.0) {
      return beat * _segments.first.secPerBeat;
    }
    var seg = _segments.first;
    for (var i = 1; i < _segments.length; i++) {
      if (beat >= _segments[i].startBeat) {
        seg = _segments[i];
      } else {
        break;
      }
    }
    return seg.startSeconds + (beat - seg.startBeat) * seg.secPerBeat;
  }

  /// Compensated receptor target timestamp (in song seconds) accounting for [audioOffsetSeconds].
  double judgedSecondsForBeat(double beat) => beatToSeconds(beat) + audioOffsetSeconds;

  /// Converts elapsed [songSeconds] into musical beat coordinates.
  double secondsToBeat(double songSeconds, {bool applyAudioOffset = true}) {
    if (_segments.isEmpty) _rebuildSegments();
    final t = applyAudioOffset ? (songSeconds - audioOffsetSeconds) : songSeconds;
    if (t < 0.0) {
      return t / _segments.first.secPerBeat;
    }
    var seg = _segments.first;
    for (var i = 1; i < _segments.length; i++) {
      if (t >= _segments[i].startSeconds) {
        seg = _segments[i];
      } else {
        break;
      }
    }
    return seg.startBeat + (t - seg.startSeconds) / seg.secPerBeat;
  }

  /// Instantaneous BPM active at [beat].
  double bpmAtBeat(double beat) {
    if (_segments.isEmpty) _rebuildSegments();
    var seg = _segments.first;
    for (var i = 1; i < _segments.length; i++) {
      if (beat >= _segments[i].startBeat) {
        seg = _segments[i];
      } else {
        break;
      }
    }
    return seg.bpm;
  }

  /// Instantaneous BPM active at [songSeconds].
  double bpmAtSeconds(double songSeconds, {bool applyAudioOffset = true}) =>
      bpmAtBeat(secondsToBeat(songSeconds, applyAudioOffset: applyAudioOffset));

  /// Current normalized phase `[0, 1)` within the beat at [songSeconds].
  double beatPhaseAt(double songSeconds, {bool applyAudioOffset = true}) {
    final b = secondsToBeat(songSeconds, applyAudioOffset: applyAudioOffset);
    return b - b.floorToDouble();
  }

  /// Whole bar index and beat within bar at [songSeconds].
  ({int bar, int beatInBar, double exactBeat}) barPositionAt(
    double songSeconds, {
    bool applyAudioOffset = true,
  }) {
    final b = secondsToBeat(songSeconds, applyAudioOffset: applyAudioOffset);
    final whole = (b + 1e-9).floor();
    final bpb = math.max(1, beatsPerBar);
    final bar = whole >= 0 ? whole ~/ bpb : -((-whole + bpb - 1) ~/ bpb);
    final inBar = ((whole % bpb) + bpb) % bpb;
    return (bar: bar, beatInBar: inBar, exactBeat: b);
  }

  /// Snaps [beat] to the nearest grid step defined by [gridSubdivision] or [subdivision].
  double quantizeBeat(double beat, {int? gridSubdivision}) {
    final div = math.max(1, gridSubdivision ?? subdivision);
    return (beat * div).roundToDouble() / div;
  }

  /// Updates [audioOffsetSeconds] from recent signed hit error samples
  /// (`actualInputSeconds - expectedJudgedSeconds`) using an outlier-trimmed mean.
  double calibrateOffsetFromSamples(
    List<double> signedDeltaSeconds, {
    double damping = 1.0,
    double maxOffsetSeconds = 0.25,
  }) {
    if (signedDeltaSeconds.isEmpty) return audioOffsetSeconds;
    final sorted = List<double>.from(signedDeltaSeconds)..sort();
    var start = 0;
    var end = sorted.length;
    if (sorted.length >= 5) {
      final trim = math.max(1, (sorted.length * 0.1).floor());
      if (trim * 2 < sorted.length) {
        start = trim;
        end = sorted.length - trim;
      }
    }
    var sum = 0.0;
    for (var i = start; i < end; i++) {
      sum += sorted[i];
    }
    final trimmedMean = sum / (end - start);
    audioOffsetSeconds = (audioOffsetSeconds + trimmedMean * damping)
        .clamp(-maxOffsetSeconds, maxOffsetSeconds)
        .toDouble();
    return audioOffsetSeconds;
  }
}
