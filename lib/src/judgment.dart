import 'dart:math' as math;

import 'beat_grid.dart';
import 'chart.dart';

/// Ordered timing accuracy tiers from tightest ([marvelous]) to invalid/dropped ([miss]).
enum HitGrade {
  marvelous,
  perfect,
  great,
  good,
  miss,
}

/// Configurable symmetric timing half-windows in seconds.
final class HitWindows {
  final double marvelous;
  final double perfect;
  final double great;
  final double good;
  final double miss;

  const HitWindows({
    this.marvelous = 0.022,
    this.perfect = 0.045,
    this.great = 0.090,
    this.good = 0.135,
    this.miss = 0.180,
  });

  const HitWindows.strict()
      : marvelous = 0.016,
        perfect = 0.032,
        great = 0.064,
        good = 0.100,
        miss = 0.140;

  const HitWindows.standard() : this();

  const HitWindows.relaxed()
      : marvelous = 0.032,
        perfect = 0.065,
        great = 0.120,
        good = 0.175,
        miss = 0.230;

  HitGrade evaluate(double deltaSeconds) {
    final absDelta = deltaSeconds.abs();
    if (absDelta <= marvelous) return HitGrade.marvelous;
    if (absDelta <= perfect) return HitGrade.perfect;
    if (absDelta <= great) return HitGrade.great;
    if (absDelta <= good) return HitGrade.good;
    return HitGrade.miss;
  }

  double weightForGrade(HitGrade grade) {
    switch (grade) {
      case HitGrade.marvelous:
        return 1.0;
      case HitGrade.perfect:
        return 0.90;
      case HitGrade.great:
        return 0.65;
      case HitGrade.good:
        return 0.35;
      case HitGrade.miss:
        return 0.0;
    }
  }
}

/// Judgment output from hitting, holding, releasing, or missing a [RhythmNote].
final class NoteJudgment {
  final String noteId;
  final int lane;
  final HitGrade grade;

  /// Signed hit delta (`actualSeconds - expectedSeconds`): negative = early, positive = late.
  final double deltaSeconds;
  final int scoreAwarded;
  final int comboAfter;
  final int multiplierAfter;
  final bool isHoldTail;

  const NoteJudgment({
    required this.noteId,
    required this.lane,
    required this.grade,
    required this.deltaSeconds,
    required this.scoreAwarded,
    required this.comboAfter,
    required this.multiplierAfter,
    this.isHoldTail = false,
  });

  bool get isHit => grade != HitGrade.miss;
  bool get isEarly => deltaSeconds < -1e-4;
  bool get isLate => deltaSeconds > 1e-4;
  double get deltaMs => deltaSeconds * 1000.0;
}

final class _ActiveHoldState {
  final RhythmNote note;
  final double endSeconds;
  double lastTickSeconds;

  _ActiveHoldState({
    required this.note,
    required this.endSeconds,
    required this.lastTickSeconds,
  });
}

/// Evaluates live rhythm inputs against a [RhythmChart] & [BeatGrid] with combo, score & accuracy.
final class RhythmSessionTracker {
  final HitWindows windows;
  final int baseNotePoints;
  final int holdTickPoints;
  final double holdTickIntervalSeconds;
  final int maxRecentSamples;

  final Set<String> _judgedNoteIds = {};
  final Map<int, _ActiveHoldState> _activeHoldsByLane = {};
  final Map<HitGrade, int> _gradeCounts = {
    for (final g in HitGrade.values) g: 0,
  };
  final List<double> _recentHitDeltas = [];

  int _combo = 0;
  int _maxCombo = 0;
  int _score = 0;
  double _weightedAccuracySum = 0.0;
  int _judgedEventCount = 0;
  NoteJudgment? _lastJudgment;

  RhythmSessionTracker({
    this.windows = const HitWindows.standard(),
    this.baseNotePoints = 1000,
    this.holdTickPoints = 150,
    this.holdTickIntervalSeconds = 0.125,
    this.maxRecentSamples = 64,
  });

  int get combo => _combo;
  int get maxCombo => _maxCombo;
  int get score => _score;
  int get judgedCount => _judgedEventCount;
  NoteJudgment? get lastJudgment => _lastJudgment;
  Set<String> get judgedNoteIds => Set.unmodifiable(_judgedNoteIds);
  List<double> get recentHitDeltas => List.unmodifiable(_recentHitDeltas);
  Map<HitGrade, int> get gradeCounts => Map.unmodifiable(_gradeCounts);

  int get multiplier {
    if (_combo >= 50) return 8;
    if (_combo >= 25) return 4;
    if (_combo >= 10) return 2;
    return 1;
  }

  double get accuracy =>
      _judgedEventCount == 0 ? 1.0 : (_weightedAccuracySum / _judgedEventCount);

  double get meanHitDeltaSeconds {
    if (_recentHitDeltas.isEmpty) return 0.0;
    var sum = 0.0;
    for (final d in _recentHitDeltas) {
      sum += d;
    }
    return sum / _recentHitDeltas.length;
  }

  bool isHoldActiveOnLane(int lane) => _activeHoldsByLane.containsKey(lane);

  void reset() {
    _judgedNoteIds.clear();
    _activeHoldsByLane.clear();
    for (final g in HitGrade.values) {
      _gradeCounts[g] = 0;
    }
    _recentHitDeltas.clear();
    _combo = 0;
    _maxCombo = 0;
    _score = 0;
    _weightedAccuracySum = 0.0;
    _judgedEventCount = 0;
    _lastJudgment = null;
  }

  NoteJudgment _recordJudgment({
    required String noteId,
    required int lane,
    required HitGrade grade,
    required double deltaSeconds,
    bool isHoldTail = false,
  }) {
    _gradeCounts[grade] = (_gradeCounts[grade] ?? 0) + 1;
    _judgedEventCount++;
    final weight = windows.weightForGrade(grade);
    _weightedAccuracySum += weight;

    var points = 0;
    if (grade != HitGrade.miss) {
      _combo++;
      if (_combo > _maxCombo) _maxCombo = _combo;
      final mult = multiplier;
      points = (baseNotePoints * weight * mult).round();
      _score += points;

      if (!isHoldTail) {
        _recentHitDeltas.add(deltaSeconds);
        if (_recentHitDeltas.length > maxRecentSamples) {
          _recentHitDeltas.removeAt(0);
        }
      }
    } else {
      _combo = 0;
    }

    final judgment = NoteJudgment(
      noteId: noteId,
      lane: lane,
      grade: grade,
      deltaSeconds: deltaSeconds,
      scoreAwarded: points,
      comboAfter: _combo,
      multiplierAfter: multiplier,
      isHoldTail: isHoldTail,
    );
    _lastJudgment = judgment;
    return judgment;
  }

  /// Evaluates a lane press at [songSeconds] against the earliest unjudged note in [lane].
  NoteJudgment? judgeInput({
    required int lane,
    required double songSeconds,
    required RhythmChart chart,
    required BeatGrid grid,
  }) {
    for (final note in chart.notes) {
      if (note.lane != lane) continue;
      if (_judgedNoteIds.contains(note.id)) continue;

      final targetSec = grid.judgedSecondsForBeat(note.beat);
      final delta = songSeconds - targetSec;
      if (delta < -windows.miss) {
        // Chart notes are sorted by beat; subsequent notes in this lane are even later.
        break;
      }
      if (delta > windows.miss) {
        continue;
      }

      _judgedNoteIds.add(note.id);
      final grade = windows.evaluate(delta);
      final judgment = _recordJudgment(
        noteId: note.id,
        lane: lane,
        grade: grade,
        deltaSeconds: delta,
      );

      if (note.isHold && grade != HitGrade.miss) {
        final endSec = grid.judgedSecondsForBeat(note.endBeat);
        if (endSec > songSeconds) {
          _activeHoldsByLane[lane] = _ActiveHoldState(
            note: note,
            endSeconds: endSec,
            lastTickSeconds: math.max(targetSec, songSeconds),
          );
        }
      }
      return judgment;
    }
    return null;
  }

  /// Handles releasing a held lane at [songSeconds], scoring tail completion or early drop.
  NoteJudgment? releaseHold({
    required int lane,
    required double songSeconds,
  }) {
    final active = _activeHoldsByLane.remove(lane);
    if (active == null) return null;

    final delta = songSeconds - active.endSeconds;
    final grade = delta >= -windows.good ? HitGrade.perfect : HitGrade.miss;
    return _recordJudgment(
      noteId: active.note.id,
      lane: lane,
      grade: grade,
      deltaSeconds: delta,
      isHoldTail: true,
    );
  }

  /// Advances active holds and auto-misses unhit notes whose [HitWindows.miss] expired.
  List<NoteJudgment> advance({
    required double songSeconds,
    required RhythmChart chart,
    required BeatGrid grid,
  }) {
    final generated = <NoteJudgment>[];

    // 1. Progress active holds and complete tails when reaching endSeconds
    final completedLanes = <int>[];
    for (final entry in _activeHoldsByLane.entries) {
      final hold = entry.value;
      final cappedTime = math.min(songSeconds, hold.endSeconds);
      while (hold.lastTickSeconds + holdTickIntervalSeconds <= cappedTime + 1e-6) {
        hold.lastTickSeconds += holdTickIntervalSeconds;
        _score += holdTickPoints * multiplier;
      }
      if (songSeconds >= hold.endSeconds) {
        completedLanes.add(entry.key);
      }
    }
    for (final lane in completedLanes) {
      final hold = _activeHoldsByLane.remove(lane)!;
      generated.add(
        _recordJudgment(
          noteId: hold.note.id,
          lane: lane,
          grade: HitGrade.marvelous,
          deltaSeconds: 0.0,
          isHoldTail: true,
        ),
      );
    }

    // 2. Expire notes past targetSeconds + windows.miss
    for (final note in chart.notes) {
      if (_judgedNoteIds.contains(note.id)) continue;
      final targetSec = grid.judgedSecondsForBeat(note.beat);
      if (songSeconds - targetSec > windows.miss) {
        _judgedNoteIds.add(note.id);
        generated.add(
          _recordJudgment(
            noteId: note.id,
            lane: note.lane,
            grade: HitGrade.miss,
            deltaSeconds: songSeconds - targetSec,
          ),
        );
      } else if (targetSec - songSeconds > windows.miss) {
        break;
      }
    }

    return generated;
  }
}
