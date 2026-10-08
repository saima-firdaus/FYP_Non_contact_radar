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
%    keep the area in front EMPTY until ">>> READY" (3 s settling + 10 s
%    learning, about 13 s), then walk.
%    Close the figure (or Ctrl+C) to stop. The session is saved to
%    Capture_MTI_yyyymmdd_HHMMSS/ (serial_log.txt has I/Q + host time).

% 3. Afterwards
cir_mti_analysis('Capture_MTI_yyyymmdd_HHMMSS')
cir_mti_live('Replay', 'Capture_MTI_yyyymmdd_HHMMSS', 'ReplaySpeed', 2)
```

`cir_mti_live` opens the same port and reads the same stream as `CIR_capture.m`,
so don't run both at once. Unlike `CIR_capture.m` it keeps I and Q: the
coherent MTI needs them, and `CIR_capture.m` only saves amplitude.

## Static test: magnitude vs complex I/Q

```matlab
cir_iq_capture('Port', 'COM4', 'TrueDistance', 1.5, 'RunLabel', 'stand_1p5m')
%   CIR_capture's session: 0-10 s empty, 10-20 s walk to your mark,
%   20-30 s stand still. TrueDistance = tape-measured distance from the
%   modules' midpoint, drawn on the figure.
cir_phase_analysis_iq('Capture_IQ_yyyymmdd_HHMMSS')   % re-run the comparison
cir_phase_analysis2('Capture_IQ_yyyymmdd_HHMMSS')     % your original figure, same folder
```

`cir_iq_capture` writes the same files as `CIR_capture.m` plus I/Q, and drops
corrupted frames. `cir_phase_analysis_iq` runs `cir_phase_analysis2`'s magnitude
method and the MTI chain's complex method on the same frames, with the same k0 and
ellipse, and saves `cir_iq_compare.png` and `cir_iq_compare.csv`.

## Clipping / linearity check

```matlab
mti_linearity_check('Capture_IQ_yyyymmdd_HHMMSS')          % one capture
mti_linearity_check({'Capture_IQ_a', 'Capture_IQ_b'})      % a TX-power sweep
```

Plots static echoes' amplitude against RXPWR and RXPACC and prints the echo/direct
slope, the RXPACC exponent and the int16 headroom. Works on `CIR_capture` folders
that still have `02_lde_aligned/`. The TX sweep is in `notes_answers_0930.md`
section 6.

## Files

| File | What it does |
|---|---|
| `cir_mti_live.m` | Live (or replayed) distance display + Command Window readout, records the session |
| `cir_mti_analysis.m` | Same processing over a whole saved capture; figure + `mti_track.csv` |
| `cir_iq_capture.m` | `CIR_capture.m`'s static session keeping I/Q; runs `cir_phase_analysis_iq` at the end |
| `cir_phase_analysis_iq.m` | Static comparison: magnitude (`cir_phase_analysis2`'s method) vs complex I/Q |
| `mti_linearity_check.m` | Static echo vs RXPWR / RXPACC, to see whether the receiver compresses |
| `mti_config.m` | Every setting and its default, with the reasoning. Edit here or pass `'Name', value` |
| `mti_step.m` / `mti_init.m` | The per-frame MTI chain and tracker (shared by the scripts) |
| `mti_parse_line.m` | Parser for the anchor's serial format; rejects truncated or spliced frames |
| `mti_read_capture.m` | Loads `serial_log.txt`, or an old `CIR_capture` folder (magnitude only) |
| `mti_geometry.m` | Tap to distance on the ellipse (same convention as `cir_phase_analysis2`) |
| `mti_check_background.m` | Checks on an empty-room recording that I/Q background subtraction works despite the modules' phase drift |
| `mti_make_test_capture.m` | Synthetic capture in the exact serial format, with a truth file (`'Scenario'`: `'walk'` or `'static'`) |
| `notes_rxpwr_background.md` | 29 Sep: learning vs CIR_capture, the first background check, RXPWR, NLOS |
| `notes_answers_0930.md` | 30 Sep: echo taps and k0, phase, the −6.7 dB, clipping tests, static comparison, learning time |
| `example_synthetic/` | What the figures look like on synthetic captures |

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
   lead-edge-to-peak offset (set it with `'PeakOffsetTaps'` if a floor bounce is taken
   for the direct peak). Distance = ellipse semi-minor axis
   `sqrt(((D+excess)/2)² - (D/2)²)`, i.e. distance from the modules' midpoint when
   you are on the centre line. An alpha-beta filter smooths it and gives the speed.

## Module phase drift (why raw I/Q subtraction failed before)

The tag and anchor run on separate crystals, so every frame's carrier phase is
effectively random and raw I/Q of a static room never subtracts. That drift rotates
the **whole CIR of a frame together**; the phase of a wall echo relative to the
direct path depends only on geometry and stays put. So step 2 above (divide each
frame by its own complex direct-path value) removes the drift, and the background
then cancels. Check it on your own modules:

```matlab
cir_mti_live('Port', "COM4", 'DurationS', 20, 'Display', false)   % empty room
mti_check_background('Capture_MTI_yyyymmdd_HHMMSS')
```
It prints how much static energy is left after subtraction for raw I/Q, normalised
I/Q and magnitude, the relative phase jitter as a robust sigma, and plots the drift.
Robust sigma under about 10°: keep coherent. Over about 15°: compare with
`'Coherent', false` (magnitude only) and keep whichever detects more.

## Tested, and not tested

- **On your modules:** one run of `mti_check_background` on an empty room (29 Sep, before
  that script's fixes). Nothing has run on a real walking or standing person yet.
- **GNU Octave 8.4, synthetic captures** (random carrier phase, 10° relative phase
  jitter, AGC changes, FP jitter, noise, body shadowing, breathing and sway, a 1 Hz arm
  wave):
  - Walking 0.8 to 3.1 m: about 85% of frames detected, 0.24 m RMS from truth. That
    includes the jumps where the synthetic person teleports between segments.
    False detections in about 3% of empty-room frames.
  - Static comparison: both methods within 0.03 m on clear taps (2 to 2.5 m); complex
    better where the echo overlaps a static path (1 to 1.5 m). The magnitude side
    matches an independent re-implementation of `cir_phase_analysis2` to 5·10⁻⁶.
    Details in `notes_answers_0930.md` section 7.
- The serial reading in `cir_mti_live` and `cir_iq_capture` (`serialport`, `readline`) is
  MATLAB-only and was not exercised; it copies what `CIR_capture.m` already does.

## Things to know when you try it for real

- **Frame rate.** The anchor manages about 10 frames/s (serial printing is the
  bottleneck). That is fine for distance, but too slow for coherent Doppler: at
  channel 5 (4.6 cm wavelength) walking aliases many times over. That is why the
  output is distance + a speed estimate from the track, not a Doppler spectrum.
- **Near range.** Below about 0.5 m the echo sits on the direct pulse itself.
- **Lag.** Frame times come from the anchor's RX timestamps (`RX_TS`), not from when
  MATLAB read the frame. If MATLAB can't keep up, the readout says "MATLAB x s behind"
  and the figure redraws once a second until it catches up. `cir_mti_analysis` prints
  the lag of a saved run. Up to 30 Sep, host read times were used, so a backlog made
  the tracker see bursts of frames a few ms apart: speeds hit 3 m/s and the distance
  drifted. Remaining built-in delay: 3-frame integration (about 0.1-0.2 s) and the
  tracker; for faster response try `'IntegrateFrames', 1` and `'TrackBeta', 0.3`.
- **Empty start.** The first 13 s must be empty (3 s settling, then 10 s learning). If you
  are in view while it learns, you become "background". Restart, or change
  `'SettleSeconds'` / `'LearnSeconds'`.
- **Tuning.** False detections: raise `ThresholdFactor` (4 → 6). Losing the person
  far out: lower it to 3 or set `IntegrateFrames` to 5. Person stands still and
  disappears: that is MTI. Set `ClutterAlpha` to 0 to freeze the background (they
  stay visible, but slow room drift will too).
- **Old captures.** `cir_mti_analysis('Capture_2026...')` works on folders that still
  have `02_lde_aligned/`, in magnitude-only mode. It learns from their background phase
  after the first 3 s automatically.
