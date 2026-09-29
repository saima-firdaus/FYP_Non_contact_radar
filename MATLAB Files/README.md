# MTI for moving targets (DW1000 CIR, bistatic)

New files only. `CIR_capture.m`, `cir_phase_analysis2.m` and the firmware are untouched.

## Quick start (MATLAB)

```matlab
addpath('path/to/mti')

% 1. Check the chain with no hardware (synthetic walking person)
d = mti_make_test_capture();          % writes Capture_MTI_SYNTH/
cir_mti_analysis(d)                   % distance vs time figure + mti_track.csv
cir_mti_live('Replay', d)             % the live display, replayed in real time

% 2. Live, with the tag + anchor running the current sketches
cir_mti_live('Port', "COM4", 'Separation', 1.0)
%    keep the area in front EMPTY until ">>> READY" (about 6 s), then walk.
%    Close the figure (or Ctrl+C) to stop. The session is saved to
%    Capture_MTI_yyyymmdd_HHMMSS/ (serial_log.txt has I/Q + host time).

% 3. Afterwards
cir_mti_analysis('Capture_MTI_yyyymmdd_HHMMSS')
cir_mti_live('Replay', 'Capture_MTI_yyyymmdd_HHMMSS', 'ReplaySpeed', 2)
```

`cir_mti_live` opens the same port and reads the same stream as `CIR_capture.m`,
so don't run both at once. Unlike `CIR_capture.m` it keeps I and Q: the
coherent MTI needs them, and `CIR_capture.m` only saves amplitude.

## Files

| File | What it does |
|---|---|
| `cir_mti_live.m` | Live (or replayed) distance display + Command Window readout, records the session |
| `cir_mti_analysis.m` | Same processing over a whole saved capture; figure + `mti_track.csv` |
| `mti_config.m` | Every setting and its default, with the reasoning. Edit here or pass `'Name', value` |
| `mti_step.m` / `mti_init.m` | The per-frame MTI chain and tracker (shared by both scripts) |
| `mti_parse_line.m` | Parser for the anchor's serial format |
| `mti_read_capture.m` | Loads `serial_log.txt`, or an old `CIR_capture` folder (magnitude only) |
| `mti_geometry.m` | Tap to distance on the ellipse (same convention as `cir_phase_analysis2`) |
| `mti_make_test_capture.m` | Synthetic capture in the exact serial format, with a truth file |
| `example_synthetic/` | What the two figures look like on the synthetic capture |

## What the chain does per frame

1. **Align.** Resample onto taps relative to `FP_INDEX` (0.25 tap grid), then refine by
   up to ±0.75 tap by matching the direct-path shape. FP jitter on the steep direct
   path would otherwise look like motion at short range.
2. **Normalise.** Divide by the frame's complex direct-path gain. The tag and anchor
   oscillators are not locked, so every frame arrives with a random carrier phase and
   a slightly different AGC gain. After this the static scene is identical frame to
   frame, which is what makes coherent (I/Q) clutter removal work.
3. **MTI.** `'clutter'` (default): subtract a clutter map of the static room, learned
   while the scene is empty and then slowly updated (about 5 s memory). Taps with
   motion on them update 20x slower so a lingering person is not absorbed and
   left behind as a ghost. `'diff'`: classic two-pulse canceller (`y(n) - y(n-1)`),
   which only sees change, so it suits arm motions but a person who pauses vanishes.
4. **Detect.** `|MTI|²` averaged over 3 frames, compared tap by tap with 4x the residual
   that tap showed in the empty room (a clutter-map CFAR). Searches 0.5 to 3.5 m.
   It picks the **nearest** strong echo: whatever the body shadows or re-reflects
   arrives *later* than the body's own echo, so the earliest one is the person.
5. **Distance + track.** `excess = (tap - k0) x 0.30028 m`, where k0 is the direct path's
   lead-edge-to-peak offset. Distance = ellipse semi-minor axis
   `sqrt(((D+excess)/2)² - (D/2)²)`, i.e. distance from the modules' midpoint when
   you are on the centre line. An alpha-beta filter smooths it and gives the speed.

## Tested, and not tested

- **Not run in MATLAB** (not available here), and **not run on real data**. The
  example capture folder has no `02_lde_aligned/` per-frame files, so there was
  nothing per-frame to replay; and old captures have no I/Q anyway.
- Run in GNU Octave 8.4 on synthetic captures (random carrier phase, AGC changes,
  FP jitter, noise, body shadowing, a 1 Hz arm wave): tracked distance within
  0.10 m RMS of truth while walking 0.8 to 3.1 m, no false detections in the empty
  room. Halving the echo strength drops detections to about 50% of frames (mostly
  beyond 2.5 m), and the tracker coasts through the gaps.
- The serial reading in `cir_mti_live` (`serialport`, `readline`) is MATLAB-only and
  was not exercised; it copies what `CIR_capture.m` already does.

## Things to know when you try it for real

- **Frame rate.** The anchor manages about 10 frames/s (serial printing is the
  bottleneck). That is fine for distance, but too slow for coherent Doppler: at
  channel 5 (4.6 cm wavelength) walking aliases many times over. That is why the
  output is distance + a speed estimate from the track, not a Doppler spectrum.
- **Near range.** Below about 0.5 m the echo sits on the direct pulse itself.
- **Empty start.** The first ~6 s must be empty. If you are in view while it learns,
  you become "background". Restart, or set `'LearnSeconds'`.
- **Tuning.** False detections: raise `ThresholdFactor` (4 → 6). Losing the person
  far out: lower it to 3 or set `IntegrateFrames` to 5. Person stands still and
  disappears: that is MTI. Set `ClutterAlpha` to 0 to freeze the background (they
  stay visible, but slow room drift will too).
- **Old captures.** `cir_mti_analysis('Capture_2026...')` works on folders that still
  have `02_lde_aligned/`, in magnitude-only mode. Their 0 to 10 s background phase is
  used as the learning window automatically.
