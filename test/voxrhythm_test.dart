import 'package:test/test.dart';
import 'package:voxrhythm/voxrhythm.dart';

void main() {
  test('BeatGrid converts beats/seconds across BPM changes and calibrates DSP offset', () {
    final grid = BeatGrid(
      bpm: 120.0,
      subdivision: 4,
      audioOffsetSeconds: 0.025,
      tempoChanges: const [
        BeatTempoEvent(beat: 4.0, bpm: 240.0),
      ],
    );

    // First 4 beats @ 120 BPM = 2.0s uncompensated; beats 4..8 @ 240 BPM = 1.0s
    expect(grid.beatToSeconds(4.0), closeTo(2.0, 1e-6));
    expect(grid.beatToSeconds(8.0), closeTo(3.0, 1e-6));
    expect(grid.judgedSecondsForBeat(4.0), closeTo(2.025, 1e-6));
    expect(grid.secondsToBeat(3.025), closeTo(8.0, 1e-6));
    expect(grid.quantizeBeat(1.13), closeTo(1.25, 1e-6));

    // Outlier-resistant DSP calibration shifts audioOffsetSeconds toward +20ms (+45ms total)
    final calibrated = grid.calibrateOffsetFromSamples(
      const [0.019, 0.021, 0.020, 0.020, 0.018, 0.220, -0.180],
    );
    expect(calibrated, closeTo(0.045, 0.003));
  });

  test('RhythmChart sorts notes, queries lookahead windows, and computes peak density', () {
    final grid = BeatGrid(bpm: 120.0); // 2 beats per second
    final chart = RhythmChart(
      title: 'Test Groove',
      laneCount: 4,
      notes: const [
        RhythmNote(id: 'n3', lane: 2, beat: 2.5, durationBeats: 1.0),
        RhythmNote(id: 'n1', lane: 0, beat: 2.0),
        RhythmNote(id: 'n2', lane: 1, beat: 2.25),
        RhythmNote(id: 'n4', lane: 3, beat: 8.0),
      ],
    );

    expect(chart.notes.map((n) => n.id).toList(), ['n1', 'n2', 'n3', 'n4']);
    expect(chart.peakNoteDensity(grid, windowSeconds: 0.5), closeTo(6.0, 1e-6));

    // At 0.5s (beat 1.0) with 1.0s lookahead -> window [0.25s, 1.5s] captures n1(1.0s), n2(1.125s), n3(1.25s)
    final visible = chart.queryLookahead(
      grid: grid,
      songSeconds: 0.5,
      lookaheadSeconds: 1.0,
    );
    expect(visible.map((v) => v.note.id).toList(), ['n1', 'n2', 'n3']);
    expect(visible.first.normalizedApproach, closeTo(0.5, 1e-6));
  });

  test('RhythmSessionTracker grades hits, manages holds, auto-misses expired notes & builds combo', () {
    final grid = BeatGrid(bpm: 120.0);
    final chart = RhythmChart(
      title: 'Combo Test',
      notes: [
        for (var i = 0; i < 10; i++)
          RhythmNote(id: 'tap_$i', lane: i % 4, beat: (i + 1).toDouble()),
        const RhythmNote(id: 'hold_10', lane: 0, beat: 11.0, durationBeats: 2.0),
        const RhythmNote(id: 'miss_11', lane: 1, beat: 14.0),
      ],
    );

    final tracker = RhythmSessionTracker();
    for (var i = 0; i < 10; i++) {
      final targetSec = grid.judgedSecondsForBeat((i + 1).toDouble());
      final j = tracker.judgeInput(
        lane: i % 4,
        songSeconds: targetSec + 0.008, // within 22ms -> marvelous
        chart: chart,
        grid: grid,
      );
      expect(j, isNotNull);
      expect(j!.grade, HitGrade.marvelous);
    }

    expect(tracker.combo, 10);
    expect(tracker.multiplier, 2);

    // Hit hold start cleanly at beat 11 (t=5.5s), sustain until beat 13 (t=6.5s)
    final holdStart = tracker.judgeInput(
      lane: 0,
      songSeconds: 5.51,
      chart: chart,
      grid: grid,
    );
    expect(holdStart!.grade, HitGrade.marvelous);
    expect(tracker.isHoldActiveOnLane(0), isTrue);

    final adv1 = tracker.advance(songSeconds: 6.55, chart: chart, grid: grid);
    expect(tracker.isHoldActiveOnLane(0), isFalse);
    expect(adv1.any((j) => j.noteId == 'hold_10' && j.isHoldTail && j.isHit), isTrue);
    expect(tracker.maxCombo, 12);

    // Advance past beat 14 (7.0s) + miss window (0.18s) -> auto-miss on miss_11
    final adv2 = tracker.advance(songSeconds: 7.25, chart: chart, grid: grid);
    expect(adv2.length, 1);
    expect(adv2.single.grade, HitGrade.miss);
    expect(tracker.combo, 0);
  });
}
