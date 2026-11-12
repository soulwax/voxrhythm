import 'dart:math' as math;

import 'beat_grid.dart';

/// Note interaction style on a rhythm lane.
enum RhythmNoteType {
  tap,
  hold,
}

/// Immutable rhythm note event at [beat] on [lane].
final class RhythmNote {
  final String id;
  final int lane;
  final double beat;
  final double durationBeats;
  final double accentStrength;
  final String? tag;

  const RhythmNote({
    required this.id,
    required this.lane,
    required this.beat,
    this.durationBeats = 0.0,
    this.accentStrength = 1.0,
    this.tag,
  });

  bool get isHold => durationBeats > 1e-6;
  RhythmNoteType get type => isHold ? RhythmNoteType.hold : RhythmNoteType.tap;
  double get endBeat => beat + math.max(0.0, durationBeats);
}

/// Visual spawn/scroll descriptor returned by [RhythmChart.queryLookahead].
final class LookaheadNoteView {
  final RhythmNote note;
  final double startSeconds;
  final double endSeconds;
  final double deltaSeconds;
  final double normalizedApproach;

  const LookaheadNoteView({
    required this.note,
    required this.startSeconds,
    required this.endSeconds,
    required this.deltaSeconds,
    required this.normalizedApproach,
  });
}

/// Sorted rhythm note chart supporting lookahead spawn windows & density queries.
final class RhythmChart {
  final String title;
  final int laneCount;
  final List<RhythmNote> notes;

  RhythmChart({
    required this.title,
    this.laneCount = 4,
    List<RhythmNote> notes = const [],
  }) : notes = List<RhythmNote>.unmodifiable(
          List<RhythmNote>.from(notes)
            ..sort((a, b) {
              final cmp = a.beat.compareTo(b.beat);
              if (cmp != 0) return cmp;
              final laneCmp = a.lane.compareTo(b.lane);
              if (laneCmp != 0) return laneCmp;
              return a.id.compareTo(b.id);
            }),
        );

  int get noteCount => notes.length;

  double get totalDurationBeats {
    if (notes.isEmpty) return 0.0;
    var maxBeat = 0.0;
    for (final n in notes) {
      if (n.endBeat > maxBeat) maxBeat = n.endBeat;
    }
    return maxBeat;
  }

  double totalDurationSeconds(BeatGrid grid) =>
      grid.beatToSeconds(totalDurationBeats);

  /// Queries notes active inside `[songSeconds - pastGraceSeconds, songSeconds + lookaheadSeconds]`.
  List<LookaheadNoteView> queryLookahead({
    required BeatGrid grid,
    required double songSeconds,
    double lookaheadSeconds = 1.5,
    double pastGraceSeconds = 0.25,
    Set<String>? excludeNoteIds,
  }) {
    if (notes.isEmpty || lookaheadSeconds <= 0.0) return const [];
    final minTime = songSeconds - pastGraceSeconds;
    final maxTime = songSeconds + lookaheadSeconds;
    final out = <LookaheadNoteView>[];

    for (final n in notes) {
      if (excludeNoteIds != null && excludeNoteIds.contains(n.id)) continue;
      final startSec = grid.judgedSecondsForBeat(n.beat);
      if (startSec > maxTime) break;
      final endSec = grid.judgedSecondsForBeat(n.endBeat);
      if (endSec < minTime) continue;

      final delta = startSec - songSeconds;
      final approach = (1.0 - (delta / lookaheadSeconds)).clamp(0.0, 1.5).toDouble();
      out.add(
        LookaheadNoteView(
          note: n,
          startSeconds: startSec,
          endSeconds: endSec,
          deltaSeconds: delta,
          normalizedApproach: approach,
        ),
      );
    }
    return out;
  }

  /// Peak note onset density (notes per second) measured over sliding [windowSeconds].
  double peakNoteDensity(BeatGrid grid, {double windowSeconds = 1.0}) {
    if (notes.isEmpty || windowSeconds <= 0.0) return 0.0;
    final times = [
      for (final n in notes) grid.beatToSeconds(n.beat),
    ];
    var left = 0;
    var maxCount = 0;
    for (var right = 0; right < times.length; right++) {
      while (times[right] - times[left] > windowSeconds + 1e-9) {
        left++;
      }
      final count = right - left + 1;
      if (count > maxCount) maxCount = count;
    }
    return maxCount / windowSeconds;
  }

  double averageNoteDensity(BeatGrid grid) {
    final dur = totalDurationSeconds(grid);
    if (notes.isEmpty || dur <= 1e-6) return notes.isEmpty ? 0.0 : notes.length.toDouble();
    return notes.length / dur;
  }
}
