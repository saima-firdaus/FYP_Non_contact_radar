# Answers, 30 Sep: files, echo taps, phase, clipping, learning time, static I/Q test

Numbers marked *synthetic* come from `mti_make_test_capture` runs in Octave, not from
your modules. Everything else cites a file, a line, or your `frame_metadata.csv`.

## 1. Which files did I change?

Nothing outside `mti/`. `CIR_capture.m`, `cir_phase_analysis2.m`, the other `cir_*.m` and
plot scripts, and the firmware (`src/`, `lib/`) still carry their 27 Sep dates. Everything I
wrote or edited is in `mti/`, plus `mti_folder.zip` next to it.

| Date | Files | What |
|---|---|---|
| 27 Sep | `cir_mti_live`, `cir_mti_analysis`, `mti_config`, `mti_step`, `mti_init`, `mti_geometry`, `mti_parse_line`, `mti_read_capture`, `mti_make_test_capture`, `README.md` | Created |
| 29 Sep | `mti_check_background` (new), `mti_step`, `mti_make_test_capture`, `cir_mti_live`, `cir_mti_analysis`, `README.md` | Background check, drift in the test data, "copy the whole folder" guard |
| 29 Sep (night) | `mti_parse_line`, `mti_read_capture`, `mti_check_background`, `notes_rxpwr_background.md` (new) | Drop corrupted frames; fixes to the check |
| 30 Sep | `cir_iq_capture`, `cir_phase_analysis_iq`, `mti_linearity_check`, this file (all new) | Sections 5-7 |
| 30 Sep | `mti_config`, `mti_step` | 3 s settle + 10 s learning; optional `PeakOffsetTaps` |
| 30 Sep | `mti_make_test_capture` | Static scene, phase jitter, TX gain, clipping |
| 30 Sep | `cir_mti_live` (one comment), `README.md`, `notes_rxpwr_background.md` (RXPWR bullet, 10 s learning) | Text |

## 2. "+x taps": the wrong echo, and does it matter?

- **What x = 0 is.** FP_INDEX marks where the direct pulse *starts rising*. The pulse
  peaks a little later, at k0 ≈ 1.5-2.5 taps. That is pulse shape, not distance.
- **Why it moves between setups.** FP is a threshold crossing, so it lands a fraction
  of a tap earlier or later with the signal level and noise. Both `cir_phase_analysis2`
  and the MTI code measure k0 from each capture's own background, so 1.5 vs 2.5 is
  handled.
- **What +5.8 is.** A peak at +5.8 is not the direct pulse. It is a reflection about
  4 taps (1.2 m of extra path) after it. The floor fits: with antennas about 1 m up
  and 1 m apart, the floor bounce is 2·√(0.5² + 1²) − 1 = 1.24 m longer, so it arrives
  4.1 taps late. A ceiling or table bounce behaves the same way.
- **Why it was the wrong echo for the check.** The check compares an echo's phase with
  the direct path's. At +5.8 the value is the bounce *plus the tail of the direct
  pulse*, which have different phases. A sub-tap timing error changes how much tail is
  in the mix, so the phase of the sum wobbles with timing, and that wobble looked like
  drift. The check now takes an echo at least 6 taps after the peak, where the direct
  pulse has died away.
- **Where it matters for distance.** If a bounce like that ever becomes the *maximum*
  0-8 taps after FP, both `cir_phase_analysis2` and the MTI take it as k0. Every
  distance then reads short by about 0.15-0.17 m per tap (about 0.6 m for 5.8 instead
  of 2).
  - `cir_phase_analysis_iq` now warns when an earlier peak within 6 dB exists.
  - You can force k0 with `'PeakOffsetTaps'`, in the comparison and in `mti_config`
    for the MTI.

## 3. Unwrapping, direct path vs wall echo, circular mean

- **Unwrapping.** A phase is only known modulo 360°: `angle()` returns −180..180.
  - `unwrap` adds ±360° whenever two consecutive values jump by more than 180°, to make
    a continuous curve. That is only right if the true change between frames is under
    180°.
  - In the first check, one noisy frame jumped by more than 180°, `unwrap` added 360°,
    and every later frame stayed 360° off. Those were the spikes and steps near 1 s and
    33 s, and they were not real.
- **Direct path vs wall echo.** They are the same transmitted pulse over two different
  routes.
  - The direct path goes straight from tag to anchor (1 m, first to arrive, near tap 0-2).
  - The wall echo goes tag → wall → anchor. It is longer, so it arrives later: +24 taps
    is about 7.2 m more path.
  - The DW1000 receives their sum, and the CIR separates them by delay. Each has its own
    amplitude and a phase set by its path length (360° per 4.6 cm at channel 5).
  - The two oscillators rotate the *whole* CIR by the same random angle each frame, so
    each raw phase looks random (top plot of the check). Their *difference* depends
    only on the path-length difference, so it is fixed (middle plot). That is why
    dividing each frame by its own direct path removes the drift.
- **Circular mean.** This is the average direction of a set of angles: the angle of
  the mean unit vector, `angle(mean(exp(1j*phi)))`. It is not a midpoint.
  - Example: for 170° and −170°, the arithmetic mean is 0° (wrong) and the circular
    mean is 180° (right).
  - The check uses the amplitude-weighted version, `angle(mean(Y))`. It measures each
    frame against it as `angle(Y .* conj(mean(Y)))`, which is always within ±180°, so
    no unwrapping is needed.

## 4. Why magnitude "cancels" noise and I/Q doesn't (the −6.7 dB)

The metric is: energy left after subtracting the tap's own average, divided by the
tap's energy. It measures how much of a tap repeats from frame to frame.

- **Complex noise on an empty tap.** It averages to about 0, so subtracting the average
  removes nothing: 0 dB. That is correct, because there is nothing static to cancel.
- **The magnitude of the same noise.** It is always positive (Rayleigh), so it has a
  non-zero average (0.89σ). Subtracting that average removes a "DC" level that taking
  the magnitude created:
  - variance / mean square = 1 − π/4 = 0.215, which is **−6.7 dB**.
  - That is rectification, not cancellation.
- **Is it theoretical?** Yes, and exact for Gaussian noise, which is what the receiver's
  thermal noise is. So it holds on your captures' noise-only taps. In
  `mti_check_background`'s bottom plot, the taps before FP should sit near 0 dB (I/Q)
  and −6.7 dB (magnitude).
  - Practical effects move it only slightly. Rounding weak taps to int16 and the 0.8 dB
    gain jitter make the magnitude figure a little higher than −6.7.
  - The same effect shows in the new comparison's top panel. On noise-only taps, the
    complex mean of about 100 frames sits about 20 dB (10·log10 100) below the magnitude
    mean.
- **On strong static taps it flips.** Magnitude sees only the part of the noise that
  lies along the static path (half of it) and ignores phase jitter, so it cancels a
  static room better. I/Q keeps the phase, which is what lets it see an echo that lands
  on a static reflection (section 7).

## 5. Echo vs RXPWR / RXPACC plot: `mti_linearity_check.m`

```matlab
mti_linearity_check('Capture_2026...')        % CIR_capture folder (needs 02_lde_aligned/)
mti_linearity_check('Capture_IQ_...')         % cir_iq_capture or cir_mti_live folder
mti_linearity_check({'Capture_IQ_a', 'Capture_IQ_b', 'Capture_IQ_c'})   % a TX sweep
```

- **Four panels:**
  - direct path vs RXPWR;
  - three static echoes vs RXPWR;
  - echo/direct vs RXPWR;
  - raw direct peak vs RXPACC.
- **Printed:** the echo/direct slope in dB per dB, the RXPACC exponent, and the int16
  headroom.
- Background frames are fitted and phase 2 is drawn grey. The echoes are picked
  automatically (≥ 6 taps after the direct peak), or pass `'EchoTaps'`.
- **Static vs MTI.** Both depend on the same linearity, in different ways:
  - Static averaging does not mind frame-to-frame gain jitter (it averages out). It is
    biased by a level-dependent distortion that differs between the two phases.
  - The MTI's per-frame normalisation assumes one gain scales the whole frame, so any
    compression hurts it directly.
- **Synthetic check.**
  - Linear front end: echo/direct was identical (0.0 dB spread) across captures 10 dB
    apart.
  - Soft limiter compressing the direct path by 2.7 dB: echo/direct rose by 2.6 dB, and
    the RXPACC exponent fell from 1.0 to 0.2.
- **Your data.** The project copy of the 21 Sep capture has no `02_lde_aligned/`, so I
  couldn't run it here. Run it on your copy.

## 6. How to see whether it is clipping

Two things can clip: the front end/ADC, and the accumulator, whose I and Q are int16
(full scale 32767).

1. **The accumulator (from data you already have).** In your 21 Sep
   `frame_metadata.csv`, PEAK_AMPL (the LDE's peak amplitude, in accumulator units) runs
   16,345-19,535. Even if all of it were in I or Q, that is 4.5 dB below full scale, so
   the accumulator was not clipping. `mti_linearity_check` prints the largest raw |I|
   or |Q| for new captures.
2. **What RXPWR is.** The number in your files is already corrected by the library.
   - `getReceivePower()` (`lib/DW1000_library/src/DW1000.cpp`, from line 1843) takes the
     chip's estimate. Above −88 dBm it adds (estimate + 88) × 2.33, a straight-line fit to
     the manual's Fig. 22.
   - For your −60 dBm frames, the chip's own estimate was about −80 dBm.
   - So "above −88" means the chip's estimate no longer tracks the input and the library
     extrapolates. It says nothing about whether the CIR *shape* is distorted.
3. **The test that answers it: a TX-power sweep.** Change only the tag's power; keep the
   scene, anchor and geometry fixed.
   - In `src/setup_tag.cpp`, change the `setTXPower(...)` value and reflash the tag.
   - Record 20-30 s of empty room with `cir_iq_capture('RunLabel', 'tx_0x61')` (the
     break and phase 2 do no harm). Repeat for each setting.
   - Then run `mti_linearity_check({...all folders...})`.

   | `setTXPower` | vs now | how |
   |---|---|---|
   | `0x48484848` | +1 to +1.5 dB | library default for channel 5 (`DW1000.cpp` line 666) |
   | `0x6B6B6B6B` | 0 | what the tag uses now |
   | `0x66666666` | −2.5 dB | fine field 11 → 6 (0.5 dB/step) |
   | `0x61616161` | −5 dB | fine field 11 → 1 |
   | `0xA1A1A1A1` | about −10 dB | coarse one step down as well |

   - **Linear:** echo/direct stays within about 0.5 dB in every capture, and the direct
     pulse keeps its shape.
   - **Compression:** echo/direct rises at the higher settings.
   - Don't go above the channel-5 default; that can exceed the UWB emission limit.
4. **Tag comment.** `setup_tag.cpp` says `0x6B6B6B6B` is "5 dB below the library
   default". That holds for channels 1/2 (default `0x75757575`). The tag now runs
   channel 5, whose default is `0x48484848`, so it is only about 1-1.5 dB below.
5. **Optional: log first-path power next to RXPWR.** In `NLOS_anchor.cpp`:
   ```cpp
   const float fpPwr = DW1000.getFirstPathPower();    // next to getReceivePower()
   ...
   Serial.print(F(",FP_PWR,")); Serial.print(fpPwr, 2); // before the ",START," print
   ```
   - Every parser (`CIR_capture.m`, `mti_parse_line`) keeps extra key,value pairs, so
     nothing else needs to change.
   - RXPWR − FP_PWR is APS006's NLOS indicator: under 6 dB means LOS, over 10 dB means
     NLOS.
   - Across the TX sweep it should stay constant if nothing compresses.
6. **Your PEAK_AMPL ∝ RXPACC^0.56.** In the synthetic test, clipping also lowers this
   exponent, so it fits compression. It also fits a loss of coherence while the chip
   accumulates the preamble (for example a residual carrier offset), which scales every
   tap alike and does no harm. The sweep tells the two apart.

## 7. The static I/Q comparison

```matlab
addpath('mti')
cir_iq_capture('Port', 'COM4', 'TrueDistance', 1.5, 'RunLabel', 'stand_1p5m')
%   same session as CIR_capture: 0-10 s empty, 10-20 s walk to your mark,
%   20-30 s stand still. Tape-measure where you stand (from the midpoint of
%   the modules) and pass it as TrueDistance.
cir_phase_analysis_iq('Capture_IQ_...')       % re-run the comparison later
cir_phase_analysis2('Capture_IQ_...')         % your original figure, same folder
```

- **What `cir_iq_capture` saves.** It writes the same files as `CIR_capture` (plus
  `real`/`imag` columns and `serial_log.txt`) and drops corrupted frames first. At the
  end it runs `cir_phase_analysis_iq`.
- **Magnitude method.** It follows `cir_phase_analysis2` step by step. On a test
  capture, its difference trace matched an independent re-implementation of
  `cir_phase_analysis2`, reading the written CSVs, to 5·10⁻⁶.
- **Complex method.** It uses `mti_step`'s own alignment and normalisation, then takes
  the complex mean of each phase and |difference|.
- **What is shared.** Both use the same frames, the same k0 and the same ellipse, so any
  difference in distance comes from the method.
- **Figure and table.** The figure is `cir_iq_compare.png`; the printed table has one
  column per method.
  - The last row gives each method's frame-to-frame scatter on strong static taps. For
    I/Q it is also shown in degrees, which is roughly your relative phase jitter.
  - Grey rings mark taps where a static path got weaker with its phase unchanged. That
    is most likely a path you are blocking, which the complex difference counts as a
    change.

**What to expect (synthetic, 2 rooms × 3 jitter levels (0/10/25°) at each distance):**

| You stood at | Magnitude (averaged) | Complex (averaged) |
|---|---|---|
| 1.0 m (your echo on the floor/table bounces) | missed you in one room (your echo cancelled a static path), 1.08 m in the other | 1.05-1.07 m, except 0.60 m in one room at 25° |
| 1.5 m (echo next to a static path) | 1.59-1.66 m | 1.50-1.55 m |
| 2.0 and 2.5 m (clear taps) | within 0.03 m | within 0.03 m |
| 3.0 m (weak echo) | 3.00 m | 3.00 m in one room; 3.94 m in the other (a wall you were blocking changed more than your echo) |

- **Single frames** (what the MTI sees): complex found you in 95-100% of frames and
  magnitude in about 85%.
  - Median of the readings: complex within 0.03 m of where you stood from 1.5 m out
    (except one run at 3 m, 3.91 m). Magnitude 0.07-0.16 m long at 1.5 m. Both
    0.03-0.08 m long at 1.0 m.
  - Per-frame RMS error was 0.20-0.22 m (complex) vs 0.29-0.37 m (magnitude). Most of
    it comes from the odd frame that picks another path.
- **Phase jitter 0 → 25°:** the complex peak's margin over its threshold dropped from
  about 26 to 17 dB. Magnitude stayed at about 22 dB.
- **The model's assumptions.** It uses 3 mm breathing, 3 mm sway, and shadowing of
  10-45% on every path behind you. Your capture decides; if the two methods agree
  within a tap on real data, they are equivalent for static use.

## 8. Learning for 10 s after 3 s of settling

- **The mean.** An N-frame background adds σ²/N to every later frame's residual: +2% at
  50 frames (5 s), +1% at 100 (10 s). Negligible either way.
- **The threshold.** It is estimated from the same frames and frozen after learning. Its
  relative error is about 1/√N: ±14% from 50 frames, ±10% from 100. That is the real
  gain, because fewer taps end up with a threshold that is too low by chance.
- **After learning.** The map keeps updating (α = 0.02 per frame, which has the noise of
  about a 10 s plain average), so the learned mean only matters for the first ~10 s of
  tracking.
- **The 3 s settle.** It skips the ESP32's restart when the port opens, and you walking
  out of view (the step near 8 s in your first check). That is probably the biggest real
  gain, and the synthetic data doesn't model it.
- **Synthetic walks (4 seeds, 27-34 s of empty room after learning).**
  - False alarms: 2.5% of empty frames with 5 s of learning vs 2.7% with 10 s.
  - Tracked RMS: 0.24 vs 0.23 m.
  - So there was no difference beyond noise.
- **Now the default.** `mti_config` has `SettleSeconds` 3 and `LearnSeconds` 10: keep
  the area empty for 13 s. `cir_mti_live` prints ">>> READY".
  - For old CIR_capture folders, `cir_mti_analysis` learns from 3 s to the end of the
    background.
  - To go back: `'SettleSeconds', 1, 'LearnSeconds', 5`.

**Coherent vs magnitude MTI while walking (synthetic, 2 seeds per jitter level):**

| Relative phase jitter | Coherent: detected / RMS | Magnitude only: detected / RMS |
|---|---|---|
| 0° | 87-88% / 0.24-0.25 m | 78-84% / 0.27-0.39 m |
| 10° | 84-87% / 0.24 m | 79-83% / 0.27-0.37 m |
| 25° | 59-61% / 0.27-0.32 m | 80-85% / 0.25-0.28 m |

This supports the decision rule in `notes_rxpwr_background.md`:
- **Under about 10° robust sigma** in `mti_check_background`: keep coherent.
- **Over about 15°:** try `'Coherent', false`.

The RMS here includes the jumps where the synthetic person teleports between segments,
so it is higher than the 0.10 m quoted on 27 Sep.
