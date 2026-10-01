# RXPWR, saturation, NLOS and background subtraction: notes

Written 2026-09-29 from your background-check plot and the `frame_metadata.csv` you sent
(291 frames, the ch5 sep 1 m capture). Claims about the DW1000 itself cite a source.
Claims about your data were computed from that CSV.

## 1. What "learning the environment" does, compared with CIR_capture

| | CIR_capture + cir_phase_analysis2 | cir_mti_live learning |
|---|---|---|
| Per frame | \|CIR\| / RXPACC, resampled onto the FP-relative grid | Complex I/Q on the FP grid, refined by up to ±0.75 tap, then **divided by the frame's own complex direct-path gain** |
| Background | Mean of *magnitudes* over 0-10 s | Complex (coherent) mean of the normalised frames over 10 s, after dropping 3 s of settling = the clutter map B (5 s and 1 s before 30 Sep) |
| Threshold | 3σ from the negatives of the difference | Per-tap residual \|y − B\|² seen during learning, × ThresholdFactor |
| Comparison | One difference of two long averages (phase 2 − background) | Every new frame on its own against B. B keeps updating slowly (α = 0.02, 20× slower where there is motion) |

So the alignment idea is the same. What's new is the complex mean after phase/gain
normalisation, the per-frame comparison, and the threshold learned from the noise.

## 2. Reading your background check (-8 dB I/Q vs -13 dB magnitude)

- For random phase jitter φ, coherent cancellation is limited to about 10·log10(φ²).
  φ = 24° RMS gives -7.6 dB, which is almost exactly your -8.1 dB. The shortfall is
  all relative-phase jitter.
- Four things in the first version of the check made it look worse than it is.
  All four are fixed in the updated `mti_check_background.m`:
  1. **Wrong echo.** It picked tap +5.8, only about 4 taps after the direct-path peak.
     That tap sits on the tail of the direct pulse with several overlapping paths, so a
     tiny sub-tap timing error rotates its phase. It now uses an echo at least 6 taps
     after the peak (your wall around +24 in the static plots).
  2. **Unwrapping.** The relative phase was unwrapped, so one noisy frame adds a 360°
     slip (the spikes near 1 s and 33 s). It is now measured around its circular mean.
     The script reports a robust sigma and a count of frames more than 45° off.
  3. **Corrupted frames.** In your CIR_capture metadata, 19 of 291 frames (6.5%) do not
     have 150 samples:
     - 14 are truncated (85-149 rows).
     - 5 are spliced (250-287 rows, two frames merged after a lost `# END` or header).

     Frame numbers 76, 113, 147, 238 and 268 are missing altogether. The old per-row
     check lets all of these through. `mti_parse_line` now rejects any frame that is
     not one contiguous run of the usual length, and each script prints how many it dropped.
  4. **Metric bias.** On a noise-only tap, a magnitude cannot "cancel" below about
     -6.7 dB (a Rayleigh variable's spread versus its mean square), while complex noise
     sits at 0 dB. Weak taps therefore favoured magnitude. The summary now uses only
     taps whose static power is at least 10× the noise.
- **Step near 8 s** in the middle plot: something in the scene changed. Most likely it
  was you walking away after starting the capture. The check now skips the first 3 s
  (`'SkipSeconds'`). Starting with `cir_mti_live(..., 'StartupDelayS', 10)` also helps.
- **Decision rule:** re-run the check.
  - Robust sigma under about 10°: coherent MTI is fine.
  - Over about 15°: compare `cir_mti_analysis` on a walking recording with and without
    `'Coherent', false`, and keep whichever detects more.
- Magnitude will always cancel a *static* room slightly better, because it throws the
  phase noise away. Coherent's advantage is sensing motion that changes only the phase:
  at channel 5, about 1.2 cm of body movement rotates the echo by 180°.

## 3. RXPWR and "saturation"

- RXPWR is an **estimate** calculated from the CIR power C, the preamble accumulation
  count N (RXPACC) and a constant A: 10·log10(C·2^17 / N²) − A (DW1000 User Manual
  §4.7.2). Qorvo staff state that it is only correct below about -85 dBm: "for signals
  with greater power the DW1000 cannot estimate the RX level correctly, as per Figure 22
  in UM" ([Qorvo forum](https://forum.qorvo.com/t/using-the-dwm1000-to-estimate-the-receive-signal-power-level/2549)).
- So **RXPWR above -88 dBm means "the power reading is no longer reliable", not "the
  receiver is saturated".** The AGC is built to receive a 1 m link, and every one of
  your frames decoded.
- **The RXPWR in your files is already corrected by the library.** `getReceivePower()`
  (`lib/DW1000_library/src/DW1000.cpp`, from line 1843) adds (estimate + 88) × 2.33 to
  the chip's estimate above −88 dBm, a straight-line fit to the manual's Fig. 22. A
  reported −60 dBm is a chip estimate of about −80 dBm. (Added 30 Sep; more in
  `notes_answers_0930.md` section 6.)
- **What your data shows:**
  - RXPWR runs from -61.7 to -57.4 dBm. The background mean is -60.2 and the phase-2
    mean is -59.0; the body adds about 1.2 dB of multipath power.
  - **Accumulation is not linear in RXPACC.** PEAK_AMPL grows only as RXPACC^0.56
    rather than ∝ RXPACC. So amplitude/RXPACC falls by 0.8 dB from low-RXPACC to
    high-RXPACC frames (correlation -0.87).
  - The `amplitude_norm` scaling therefore over-corrects and adds gain jitter from frame
    to frame. The MTI code's direct-path normalisation removes it. In the static
    analysis it averages out over about 100 frames.
  - I can't tell from the data whether this comes from the AGC, the accumulator, or how
    RXPACC is counted.
- **Why the static peak at 1 m is still right:**
  1. The distance comes from *where* the peak is (its delay after FP, calibrated with k0),
     which is set by timing. Gain compression changes peak heights far more than positions.
  2. The difference is taken between two phases of the same session, so any fixed
     compression is common to both and cancels.
  3. At 1 m the body echo is about as strong as the direct path. The LDE's reported
     peak moves from about +2 taps to +5-7 taps in 17 of 97 phase-2 frames, and in 0 of
     96 background frames. The receiver is linear enough for the echo to appear at the
     right tap.
- **Where a high signal level does hurt:**
  - **Leading-edge bias.** The first-path estimate shifts with signal level (the reason
    for Decawave's range-bias-versus-RX-level correction in TWR). That moves every
    distance by a few cm, which is small next to the 0.3 m tap.
  - **Real front-end clipping** (very close range or high TX power) would compress the
    strongest paths relative to the weak ones. The MTI assumption that "one complex gain
    per frame scales the whole CIR" then breaks, and AGC gain changes leave a residual.
    To test for it, plot a weak static echo's normalised amplitude against RXPWR or
    RXPACC. A flat line means the front end is linear. `mti_linearity_check.m` draws
    this (added 30 Sep).

## 4. Static subtraction vs MTI: what each is sensitive to

- **Static (mean vs mean):** insensitive to jitter between frames, because it is averaged
  away. Sensitive to *slow drift between the two phases* (AGC state, temperature, a
  different mix of RXPACC values), which biases the difference.
- **MTI clutter map:** frame-to-frame jitter (phase, gain, alignment) sets the residual
  floor. That raises the threshold and costs range and sensitivity. Slow drift is
  absorbed by the slow update of B.
- **MTI 'diff' mode:** almost blind to drift; only jitter matters.

## 5. NLOS

- Everything is referenced to the first path: the frame alignment, the phase/gain
  normalisation, and the excess delay that becomes distance.
- If the direct path between the modules is blocked or weak (an absorber, a person
  standing on the baseline, modules angled apart):
  - FP can lock onto a later path or jump between paths from frame to frame. The whole
    CIR then shifts, and both static subtraction and MTI fail.
  - The phase reference becomes noisy.
  - Distances come out biased short, because the excess delay is measured from a
    detoured "first" path.
- **Detecting it:** APS006 Part 3's rule of thumb compares first-path power with the
  total RX power. A difference under 6 dB is likely LOS; over 10 dB is likely NLOS.
  This needs FP_AMPL1-3 from the anchor, which the sketch does not print yet (that would
  be a firmware change).
- **If NLOS is deliberate:** reference each frame to a strong, stable static reflector,
  or do a least-squares gain fit over all strong static taps, instead of the direct path.

## 6. Assumptions and when they break

| Assumption | Breaks when | Symptom |
|---|---|---|
| One complex gain per frame scales the whole CIR (linear front end) | Clipping at very close range or high TX power; AGC steps with a nonlinear front end | Residual that tracks RXPWR / RXPACC |
| Direct path is stable and strong | NLOS, a person near the baseline, modules moved | FP jumps, relative-phase outliers |
| Scene is static while learning | People, doors, fans moving | A step in relative phase, a high threshold |
| Fixed geometry and separation | Modules bumped or moved | Everything must be learned again |

**Trade-offs:**
- **Lowering TX power** does *not* improve the echo-to-direct ratio, because both scale
  equally. It only helps if the front end is genuinely clipping.
- **Reducing direct coupling** (rotating the antennas, adding an absorber between the
  modules) usually leaves more dynamic range for weak echoes, because the AGC is set by
  the direct path. But it weakens the phase reference and moves you towards NLOS.
