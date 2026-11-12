<p align="center">
  <img src="assets/logo.svg" width="88" alt="voxrhythm logo"/>
</p>

# voxrhythm

Pure Dart beat-synced rhythm game sequencer, note chart analyzer, hit-timing judge, and DSP latency calibration library.

## Features

- **`BeatGrid`**: Constant and multi-tempo BPM mapping between beats and song seconds with audio latency compensation, quantization, and outlier-resistant DSP offset calibration.
- **`RhythmChart` & `RhythmNote`**: Tap and hold note timelines, lookahead spawn queries, and sliding-window note density analysis.
- **`HitWindows` & `RhythmSessionTracker`**: Configurable Marvelous/Perfect/Great/Good/Miss timing windows, signed hit deltas, hold completion/drop logic, accuracy, combo tracking, and score multipliers.
