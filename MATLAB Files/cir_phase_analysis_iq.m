function out = cir_phase_analysis_iq(captureDir, varargin)
%CIR_PHASE_ANALYSIS_IQ  Where you stood: BSDA vs complex I/Q subtraction, same re-aligned frames.
%
%   out = CIR_PHASE_ANALYSIS_IQ(captureDir)
%   out = CIR_PHASE_ANALYSIS_IQ(captureDir, 'TrueDistance', 1.5, ...)
%   out = CIR_PHASE_ANALYSIS_IQ()          newest Capture_IQ_* folder in pwd
%
% For a static session recorded with cir_iq_capture (its serial_log.txt
% keeps I and Q). The session is split exactly as in cir_phase_analysis2:
% background before walk_prompt_at_s, the walking break thrown away,
% phase 2 after it. The SAME frames then go through two methods:
%
%   BSDA     cir_phase_analysis_variance's statistic: per tap, the SD of
%            |I+jQ| / RXPACC across phase 2 minus its SD across the
%            background, against the per-tap F threshold for Pfa. A still
%            scene has no spread whatever its level, so this needs no phase
%            reference and ignores slow drift.
%   Complex  what the MTI code does: I/Q on the same grid, refined by up to
%            +/-0.75 tap against the direct-path shape, divided by the
%            frame's own complex direct-path gain; then the complex mean of
%            each phase and the size of their difference,
%            |mean(phase 2) - mean(background)|.
%
% Re-alignment. Every frame is put on the grid by FP_INDEX, which is where
% the DW1000's leading-edge detector found the first path - and on the
% directional-antenna PCB it locks onto different paths in different frames
% (shifts of about 4 taps, in up to 90% of the frames), so each phase would
% be averaged over a mix of misaligned frames. Before either method, each
% frame's |CIR| is slid over +/-MaxShiftTaps against the empty room's median
% shape and moved to the best match, its I/Q with it ('Realign', false
% turns this off).
%
% Range zero (k0): the TALLEST point 0..15 taps after FP in the empty room,
% the dominant path; every distance is measured from it. The target is
% searched from SkipTaps past it - the direct path's own zone, where the
% body disturbing strong early paths makes big changes that are not the
% target - and from MinRangeM out.
%
% Figure (cir_iq_compare.png), top to bottom:
%   1. background level (solid) and frame-to-frame scatter (dashed)
%   2. BSDA: SD change vs distance, with its F threshold
%   3. complex difference vs distance
%   4. readings through phase 2: BSDA over a sliding BsdaWindowS window,
%      complex from every frame on its own
%
% Options:
%   'TrueDistance'   []     m from the modules' midpoint; default from
%                           session_info.csv (cir_iq_capture 'TrueDistance')
%   'Separation'     []     m; default from session_info.csv, else 1
%   'SettleSeconds'  0      drop frames before this (both methods)
%   'WalkPromptAtS'  [], 'WalkDurationS' []   override session_info.csv
%   'Realign'        true   re-align every frame by its shape
%   'MaxShiftTaps'   5      largest shift the re-alignment tries
%   'PeakOffsetTaps' []     force k0 (taps after FP)
%   'SkipTaps'       3      the search starts this many taps past k0 ...
%   'MinRangeM'      0.75   ... and this far out ...
%   'MaxRangeM'      6      ... and stops here
%   'Pfa'            1e-3   BSDA per-tap false-alarm probability
%   'BsdaWindowS'    2      window of the BSDA readings through phase 2
%   'NoiseSigmaK'    3      complex thresholds, in sigma
%   'MinFrameFrac'   0.8    grid coverage rule, as cir_phase_analysis2
%   'Plot'           true
%   'Verbose'        true
%
% Writes cir_iq_compare.png, cir_iq_compare.csv (per tap) and
% cir_iq_frames.csv (per phase-2 frame) into the capture folder.

% The mti_*.m helpers must sit in the same folder as this file.
addpath(fileparts(mfilename('fullpath')));
if exist('mti_config', 'file') ~= 2
    error(['mti_config.m not found. Copy the WHOLE mti folder (all mti_*.m ' ...
           'files) next to this script.']);
end
if nargin < 1 || isempty(captureDir), captureDir = local_newest(pwd); end
captureDir = char(captureDir);

o = struct('TrueDistance', [], 'Separation', [], 'SettleSeconds', 0, ...
           'WalkPromptAtS', [], 'WalkDurationS', [], 'Realign', true, ...
           'MaxShiftTaps', 5, 'PeakOffsetTaps', [], 'SkipTaps', 3, ...
           'MinRangeM', 0.75, 'MaxRangeM', 6, 'Pfa', 1e-3, 'BsdaWindowS', 2, ...
           'NoiseSigmaK', 3, 'MinFrameFrac', 0.8, 'Plot', true, 'Verbose', true);
names = fieldnames(o);
for k = 1:2:numel(varargin)
    hit = find(strcmpi(names, varargin{k}), 1);
    if isempty(hit)
        error('cir_phase_analysis_iq: unknown option "%s".', char(varargin{k}));
    end
    o.(names{hit}) = varargin{k+1};
end

% ---- Session --------------------------------------------------------------------
[frames, info] = mti_read_capture(captureDir);
if ~info.coherent
    error(['%s has no I/Q (CIR_capture saves amplitude only). Record the ' ...
           'session with cir_iq_capture.'], captureDir);
end
Ss = info.session;
walkAt  = local_pick_num(o.WalkPromptAtS, Ss, 'walk_prompt_at_s', NaN);
walkDur = local_pick_num(o.WalkDurationS, Ss, 'walk_duration_s', NaN);
if ~isfinite(walkAt) || ~isfinite(walkDur)
    error(['No phase timings in %s/session_info.csv. Pass WalkPromptAtS and ' ...
           'WalkDurationS.'], captureDir);
end
tb   = local_num(Ss, 'taps_before_fp', 50);
ta   = local_num(Ss, 'taps_after_fp', 100);
step = local_num(Ss, 'mean_grid_step', 0.5);
t2m  = local_num(Ss, 'tap_to_metres', 0.30028);
sep  = local_pick_num(o.Separation, Ss, 'tag_anchor_dist_m', NaN);
if ~isfinite(sep), sep = local_num(Ss, 'separation_m', NaN); end
if ~isfinite(sep)
    sep = 1;
    fprintf('Separation not recorded - assuming 1 m (pass ''Separation'').\n');
end
trueD = local_pick_num(o.TrueDistance, Ss, 'true_distance_m', NaN);
label = '';
if isfield(Ss, 'run_label'), label = char(num2str(Ss.run_label)); end

g  = (-tb : step : ta).';
nG = numel(g);
nF = numel(frames);
el = nan(1, nF);
for i = 1:nF
    if isfield(frames{i}.meta, 'elapsed_s'), el(i) = frames{i}.meta.elapsed_s; end
end
if all(isnan(el))
    error('The frames carry no elapsed_s: record with cir_iq_capture.');
end

% ---- |I+jQ| / RXPACC on the FP grid, then shape re-alignment ------------------------
Amag  = local_magnitudes(frames, g, zeros(1, nF));
shift = zeros(1, nF);
if o.Realign
    bg0 = el >= o.SettleSeconds & el < walkAt & any(isfinite(Amag), 1);
    shift = local_realign(Amag, g, bg0, o.MaxShiftTaps);
    Amag  = local_magnitudes(frames, g, shift);       % again from the raw samples
end

% ---- Complex chain: the MTI's own mti_step, run without ever "finishing
% learning", so each frame is only aligned and normalised. Each frame goes in
% with FP_INDEX moved by its shape shift, so its I/Q lands where its |CIR| did.
cfg = mti_config('Separation', sep, 'TapToMetres', t2m, 'TapsBeforeFP', tb, ...
                 'TapsAfterFP', ta, 'GridStep', step, 'SettleSeconds', 0, ...
                 'LearnSeconds', 1e9);
S = mti_init(cfg);
Y = nan(nG, nF);
gainAbs = nan(1, nF);
for i = find(el >= o.SettleSeconds)
    f = frames{i};
    f.meta.FP_INDEX = f.meta.FP_INDEX + shift(i);
    [S, R] = mti_step(S, f);
    if isempty(R.y), continue; end
    y = R.y;
    y(~isfinite(R.xAligned)) = NaN;              % outside this frame's window
    Y(:, i) = y;
    gainAbs(i) = abs(R.gain);
end
% mti_step scales every frame to the first one; bring it back to the
% average amplitude_norm scale so both methods share one y axis.
Y = Y * mean(gainAbs(isfinite(gainAbs)));

use  = el >= o.SettleSeconds & any(isfinite(Amag), 1) & any(isfinite(Y), 1);
isBg = use & el < walkAt;
isP2 = use & el >= walkAt + walkDur;
if sum(isBg) < 3 || sum(isP2) < 3
    error('Need frames in both phases: %d background, %d phase 2.', ...
        sum(isBg), sum(isP2));
end

% ---- Phase statistics ---------------------------------------------------------------
[muB, sdB, nB] = local_stats(Amag(:, isBg), o.MinFrameFrac);
[~,   sdP, nP] = local_stats(Amag(:, isP2), o.MinFrameFrac);
dSD = sdP - sdB;
[cB, vB, nCB]  = local_stats(Y(:, isBg), o.MinFrameFrac);
[cP, ~,  nCP]  = local_stats(Y(:, isP2), o.MinFrameFrac);
dIQ = abs(cP - cB);

% ---- k0 and the distance axis (shared) ----------------------------------------------
k0 = local_tallest(g, muB, 15);
if ~isempty(o.PeakOffsetTaps), k0 = o.PeakOffsetTaps; end
dist = mti_geometry('tap2range', g, cfg, k0);
win  = isfinite(dist) & dist >= o.MinRangeM & dist <= o.MaxRangeM & g >= k0 + o.SkipTaps;
rStart = min(dist(win));
if isempty(rStart), rStart = o.MinRangeM; end

% ---- Thresholds ---------------------------------------------------------------------
% BSDA: under "nothing changed at this tap" SD_p2^2 / SD_bg^2 is F(nP-1, nB-1)
% distributed, so this is a constant-false-alarm threshold on the SD change
% (cir_phase_analysis_variance). Complex: a length, |difference|, Rayleigh-
% distributed when nothing changed, so the factor for the same false-alarm
% rate as K sigma is sqrt(-ln(Pfa)) = 2.57 for K = 3.
K = o.NoiseSigmaK;
fK = sqrt(-log(0.5 * erfc(K / sqrt(2))));
thrSD = sdB .* (sqrt(local_finv(1 - o.Pfa, nP - 1, nB - 1)) - 1);
thrIQ = fK * sqrt(vB .* (1 ./ nCB + 1 ./ nCP));

% ---- Averaged picks ---------------------------------------------------------------
pb = local_pick(max(dSD, 0), thrSD, dist, win);
pc = local_pick(dIQ, thrIQ, dist, win);
% Taps where the complex difference is big but it is the static path itself
% getting weaker, keeping its phase (the change points straight against the
% background, within ~25 deg): most likely a path you are blocking, not your
% echo. Your own echo cancelling part of a static path can also make a tap
% weaker, but its change then points in some other direction.
along = real((cP - cB) .* conj(cB)) ./ (abs(cP - cB) .* abs(cB));
weaker = abs(cP) < abs(cB) & dIQ > thrIQ & along < -0.9;

% ---- Readings through phase 2 ---------------------------------------------------------
% BSDA needs a spread, so it reads from a sliding window of the last
% BsdaWindowS of phase-2 frames; complex reads every frame on its own.
iP2 = find(isP2);
nP2f = numel(iP2);
readB = nan(1, nP2f); readC = nan(1, nP2f);
nWin = max(3, round(o.BsdaWindowS / median(diff(el(iP2)), 'omitnan')));
thrW = sdB .* (sqrt(local_finv(1 - o.Pfa, (nWin - 1) * ones(nG, 1), nB - 1)) - 1);
% Complex: detected on each tap's own scatter (sigma units), then placed on
% the top of the difference itself, up to one tap away: where the scatter
% changes across an echo (a static path beside it), the sigma-scaled peak
% sits off the echo.
climb = max(1, round(1 / step));
for j = 1:nP2f
    if j >= nWin
        vW = std(Amag(:, iP2(j - nWin + 1 : j)), 0, 2, 'omitnan') - sdB;
        vW(~(vW > thrW)) = 0;                         % a reading needs a detection
        a = local_pick(vW, thrW, dist, win);
        readB(j) = a.strongR;
    end
    dC1 = abs(Y(:, iP2(j)) - cB);                     % the MTI's statistic
    b = local_pick(dC1 ./ sqrt(vB), fK * ones(nG, 1), dist, win, dC1, climb);
    readC(j) = b.nearR;
end
nWinRead = max(nP2f - nWin + 1, 0);                % full windows only
fb = local_frame_summary(readB(nP2f - nWinRead + 1 : end), trueD);
fc = local_frame_summary(readC, trueD);

% ---- Scatter on the strong static taps: why one method has the lower floor ----------
noiseM = median(muB(g >= -45 & g <= -8 & isfinite(muB)));
strong = g >= k0 + 3 & isfinite(muB) & muB > 5 * noiseM & isfinite(vB);
scatM = median(sdB(strong) ./ muB(strong));
scatC = median(sqrt(vB(strong)) ./ abs(cB(strong)));

% ---- Report ---------------------------------------------------------------------------
moved = abs(shift) >= 1.5 & use;
if o.Verbose
    fprintf('\n=== BSDA vs complex I/Q: %s ===\n', captureDir);
    if ~isempty(label), fprintf('Run label : %s\n', label); end
    fprintf(['Frames    : %d background (%.1f-%.1f s) | %d phase 2 ' ...
             '(%.1f-%.1f s), the same frames for both\n'], sum(isBg), ...
        min(el(isBg)), max(el(isBg)), sum(isP2), min(el(isP2)), max(el(isP2)));
    if isfield(info, 'nBadFrames') && info.nBadFrames > 0
        fprintf('            (%d corrupted frames dropped first)\n', info.nBadFrames);
    end
    if o.Realign
        fprintf('Re-aligned: %d of %d frames moved by 1.5 taps or more', sum(moved), sum(use));
        if any(moved)
            [u, ~, kk] = unique(round(shift(moved)));
            cnt = accumarray(kk(:), 1);
            fprintf(' (%s) - FP_INDEX locked on another path', ...
                strjoin(arrayfun(@(a, n) sprintf('%+d taps x%d', a, n), u(:).', cnt(:).', ...
                'UniformOutput', false), ', '));
        end
        fprintf('\n');
    else
        fprintf('Re-aligned: off (frames placed by FP_INDEX only)\n');
    end
    fprintf('Geometry  : foci %g m apart, range zero k0 = %+.2f taps', sep, k0);
    if ~isempty(o.PeakOffsetTaps)
        fprintf(' (given)\n');
    else
        fprintf(' (tallest point 0-15 taps after FP)\n');
    end
    fprintf('            searching %.2f-%.2f m (from %g taps past k0)\n', rStart, ...
        o.MaxRangeM, o.SkipTaps);
    if isfinite(trueD), fprintf('You stood : %.2f m\n', trueD); end
    fprintf('\n%-34s %-24s %-24s\n', '', 'BSDA (SD change)', 'Complex I/Q (MTI chain)');
    fprintf('%-34s %-24s %-24s\n', 'Averaged: strongest peak', ...
        local_peak_str(pb.strongR, pb.strongDB), local_peak_str(pc.strongR, pc.strongDB));
    fprintf('%-34s %-24s %-24s\n', 'Averaged: nearest detection', ...
        local_peak_str(pb.nearR, pb.nearDB), local_peak_str(pc.nearR, pc.nearDB));
    if isfinite(trueD)
        fprintf('%-34s %-24s %-24s\n', 'Averaged: error, strongest / nearest', ...
            local_err2_str(pb, trueD), local_err2_str(pc, trueD));
    end
    fprintf('%-34s %-24s %-24s\n', 'Readings: detected', ...
        sprintf('%.0f%% of %d windows', 100 * fb.hit, nWinRead), ...
        sprintf('%.0f%% of %d frames', 100 * fc.hit, nP2f));
    fprintf('%-34s %-24s %-24s\n', 'Readings: median / spread', ...
        local_ms_str(fb), local_ms_str(fc));
    if isfinite(trueD)
        fprintf('%-34s %-24s %-24s\n', 'Readings: RMS error', ...
            local_err_str(fb.rms, true), local_err_str(fc.rms, true));
    end
    for r = unique([pc.strongR pc.nearR])
        if ~isfinite(r), continue; end
        [~, j] = min(abs(dist - r));
        if weaker(j)
            fprintf(['  NOTE: the complex pick at %.2f m is a static path that got WEAKER ' ...
                     'with its phase unchanged -\n        most likely one you are ' ...
                     'blocking, not your own echo (grey rings on the figure).\n'], r);
        end
    end
    fprintf('%-34s %-24s %-24s\n', 'Background scatter, strong taps', ...
        sprintf('%.1f%% of level', 100 * scatM), ...
        sprintf('%.1f%% (~%.0f deg)', 100 * scatC, rad2deg(scatC)));
    fprintf(['\n(dB = height of the peak over its own threshold: higher stands out ' ...
             'more, negative = under it.\n Nearest detection = the closest peak over ' ...
             'threshold within 10 dB of the strongest. BSDA readings: SD over\n the ' ...
             'last %d phase-2 frames (%g s) vs the background; complex readings: one ' ...
             'frame vs the\n background, no averaging - what the MTI sees.)\n'], ...
        nWin, o.BsdaWindowS);
end

% ---- Save --------------------------------------------------------------------------------
fid = fopen(fullfile(captureDir, 'cir_iq_compare.csv'), 'w');
fprintf(fid, ['taps_from_fp,offset_m,bg_mean,bg_sd,p2_sd,sd_diff,bsda_threshold,' ...
              'iq_bg_abs,iq_bg_scatter,iq_p2_abs,iq_diff,iq_threshold\n']);
fprintf(fid, '%.4f,%.4f,%.6g,%.6g,%.6g,%.6g,%.6g,%.6g,%.6g,%.6g,%.6g,%.6g\n', ...
    [g dist muB sdB sdP dSD thrSD abs(cB) sqrt(vB) abs(cP) dIQ thrIQ].');
fclose(fid);
fid = fopen(fullfile(captureDir, 'cir_iq_frames.csv'), 'w');
fprintf(fid, 'elapsed_s,bsda_reading_m,complex_reading_m,shift_taps\n');
fprintf(fid, '%.4f,%.4f,%.4f,%.3f\n', [el(iP2); readB; readC; shift(iP2)]);
fclose(fid);

out = struct('dir', captureDir, 'grid', g, 'distance', dist, 'k0', k0, ...
    'separation', sep, 'trueDistance', trueD, 'searchFromM', rStart, ...
    'shift', shift, 'elapsed', el, ...
    'bsda', struct('bgMean', muB, 'bgSD', sdB, 'p2SD', sdP, 'diff', dSD, ...
        'threshold', thrSD, 'pick', pb, 'frameReadings', readB, 'frames', fb, ...
        'windowFrames', nWin, 'bgScatter', scatM), ...
    'complex', struct('bgMean', cB, 'bgScatter2', vB, 'p2Mean', cP, 'diff', dIQ, ...
        'threshold', thrIQ, 'pick', pc, 'frameReadings', readC, 'frames', fc, ...
        'bgScatter', scatC, 'weaker', weaker), ...
    'frameTimes', el(iP2), 'counts', [sum(isBg) sum(isP2)]);

if o.Plot
    out.fig = local_plot(out, o, label, sum(isBg), sum(isP2), sum(moved));
    print(out.fig, fullfile(captureDir, 'cir_iq_compare.png'), '-dpng', '-r150');
    if o.Verbose, fprintf('Saved cir_iq_compare.png, cir_iq_compare.csv, cir_iq_frames.csv\n'); end
end
end

% =============================================================================
function A = local_magnitudes(frames, g, shift)
% |I+jQ| / RXPACC of every frame on the FP grid (amplitude_norm, as
% CIR_capture saves it), each frame placed with FP_INDEX + shift.
A = nan(numel(g), numel(frames));
for i = 1:numel(frames)
    f   = frames{i};
    acc = 1;
    if isfield(f.meta, 'RXPACC') && f.meta.RXPACC > 0, acc = f.meta.RXPACC; end
    [u, ia] = unique(f.sample - (f.meta.FP_INDEX + shift(i)));
    a = hypot(f.re, f.im) / acc;
    if numel(u) >= 2
        A(:, i) = interp1(u, a(ia), g, 'linear', NaN);
    end
end
end

% =============================================================================
function shift = local_realign(A, g, isBg, maxShift)
% Shift (taps) that lines each frame's |CIR| shape, -5..25 taps after FP, up
% with the background's median shape: normalised correlation, so gain does
% not matter, refined between grid steps. Two passes: the second against the
% median of the background frames already moved by the first.
step = g(2) - g(1);
w    = find(g >= -5 & g <= 25);
lags = round(-maxShift / step) : round(maxShift / step);
nF   = size(A, 2);
shift = zeros(1, nF);
for pass = 1:2
    B = A(:, isBg);
    if pass == 2
        ib = find(isBg);
        for q = 1:numel(ib)
            B(:, q) = interp1(g, A(:, ib(q)), g + shift(ib(q)), 'linear', NaN);
        end
    end
    ref = median(B, 2, 'omitnan');
    r0  = ref(w) - mean(ref(w), 'omitnan');
    if any(~isfinite(r0)), return; end
    for i = 1:nF
        sc = -inf(size(lags));
        for q = 1:numel(lags)
            idx = w + lags(q);
            if idx(1) < 1 || idx(end) > numel(g), continue; end
            v = A(idx, i);
            if any(~isfinite(v)), continue; end
            v = v - mean(v);
            sc(q) = (v' * r0) / (norm(v) * norm(r0) + eps);
        end
        [best, b] = max(sc);
        if ~isfinite(best), shift(i) = 0; continue; end
        d = 0;
        if b > 1 && b < numel(lags) && all(isfinite(sc(b-1:b+1)))
            den = sc(b-1) - 2 * sc(b) + sc(b+1);
            if den < 0, d = 0.5 * (sc(b-1) - sc(b+1)) / den; end
        end
        shift(i) = (lags(b) + d) * step;
    end
end
end

% =============================================================================
function [mu, sd2, n] = local_stats(A, frac)
% Mean and spread over frames (columns), ignoring NaN, with
% cir_phase_analysis2's coverage rule: a grid point reached by fewer than
% frac of the frames is dropped. For real A, sd2 is the standard deviation;
% for complex A it is the mean squared residual |A - mean|^2.
ok = isfinite(A);
n  = sum(ok, 2);
A0 = A; A0(~ok) = 0;
mu = sum(A0, 2) ./ max(n, 1);
d  = A - mu; d(~ok) = 0;
v  = sum(abs(d).^2, 2) ./ max(n - 1, 1);
if isreal(A), sd2 = sqrt(v); else, sd2 = v; end
thin = n < max(ceil(frac * size(A, 2)), 1);
mu(thin) = NaN;
sd2(thin | n < 2) = NaN;
n(thin) = NaN;
end

% =============================================================================
function p = local_pick(v, thr, dist, win, vLoc, maxClimb)
% strongR : distance of the largest value in the search window
% nearR   : nearest local peak over its threshold, among those within 10 dB
%           (energy) of the strongest one over threshold (cir_mti_live's rule)
% vLoc, maxClimb (optional): after picking on v, move nearR up to maxClimb
%           grid points uphill on vLoc and refine there
p = struct('strongR', NaN, 'strongDB', NaN, 'nearR', NaN, 'nearDB', NaN);
v = v(:); thr = thr(:);
v(~win | ~isfinite(v)) = NaN;
[pk, j] = max(v);
if isempty(j) || ~isfinite(pk) || pk <= 0, return; end
p.strongR  = local_refine(v, dist, j);
p.strongDB = 20 * log10(pk / thr(j));
isMax = false(size(v));
isMax(2:end-1) = v(2:end-1) >= v(1:end-2) & v(2:end-1) > v(3:end);
cand = find(isMax & v > thr);
if isempty(cand), return; end
cand = cand(v(cand) >= max(v(cand)) / sqrt(10));
[~, k] = min(dist(cand));
p.nearR  = local_refine(v, dist, cand(k));
p.nearDB = 20 * log10(v(cand(k)) / thr(cand(k)));
if nargin >= 6 && maxClimb > 0
    vL = vLoc(:);
    vL(~win | ~isfinite(vL)) = NaN;
    i = cand(k);
    for s = 1:maxClimb
        if i > 1 && vL(i-1) > vL(i)
            i = i - 1;
        elseif i < numel(vL) && vL(i+1) > vL(i)
            i = i + 1;
        else
            break
        end
    end
    p.nearR = local_refine(vL, dist, i);
end
end

function r = local_refine(v, dist, j)
% Parabola through the peak and its two neighbours: the same sub-grid
% refinement for both methods (and the MTI's detector), so neither is
% limited to the 0.5-tap grid.
r = dist(j);
if j < 2 || j > numel(v) - 1, return; end
a = v(j-1); b = v(j); c = v(j+1);
den = a - 2*b + c;
if ~(isfinite(den) && den < 0 && isfinite(dist(j-1)) && isfinite(dist(j+1))), return; end
dl = 0.5 * (a - c) / den;                      % grid points, |dl| <= 0.5
if dl >= 0
    r = dist(j) + dl * (dist(j+1) - dist(j));
else
    r = dist(j) + dl * (dist(j) - dist(j-1));
end
end

% =============================================================================
function s = local_frame_summary(r, trueD)
s = struct('hit', mean(isfinite(r)), 'median', NaN, 'spread', NaN, 'rms', NaN);
r = r(isfinite(r));
if isempty(r), return; end
s.median = median(r);
s.spread = 1.4826 * median(abs(r - s.median));      % robust SD
if isfinite(trueD), s.rms = sqrt(mean((r - trueD).^2)); end
end

% =============================================================================
function k = local_tallest(g, mu, upto)
% The dominant path: the largest background level 0..upto taps after FP,
% refined between grid steps.
k = 0;
w = find(g >= 0 & g <= upto & isfinite(mu));
if isempty(w), return; end
[pk, j] = max(mu(w));
if ~(pk > 0), return; end
j = w(j);
k = g(j);
if j > 1 && j < numel(mu) && all(isfinite(mu(j-1:j+1)))
    a = mu(j-1); b = mu(j); c = mu(j+1); den = a - 2*b + c;
    if den < 0, k = k + 0.5 * (a - c) / den * (g(2) - g(1)); end
end
end

function x = local_finv(p, d1, d2)
% F-distribution quantile without the Statistics Toolbox, as in
% cir_phase_analysis_variance: if X ~ F(d1,d2), d1 X/(d1 X + d2) ~ Beta(d1/2, d2/2).
x  = nan(size(d1));
ok = isfinite(d1) & isfinite(d2) & d1 >= 1 & d2 >= 1;
if ~any(ok), return; end
b = betaincinv(p, d1(ok) / 2, d2(ok) / 2);
x(ok) = (d2(ok) .* b) ./ (d1(ok) .* (1 - b));
end

% =============================================================================
function v = local_num(S, name, dflt)
v = dflt;
if ~isfield(S, name), return; end
x = S.(name);
if ischar(x) || (exist('isstring', 'builtin') && isstring(x)), x = str2double(x); end
if isnumeric(x) && isscalar(x) && isfinite(x), v = x; end
end

function v = local_pick_num(given, S, name, dflt)
if ~isempty(given), v = given; else, v = local_num(S, name, dflt); end
end

function s = local_peak_str(r, db)
if ~isfinite(r), s = 'none'; return; end
s = sprintf('%.2f m (%+.1f dB)', r, db);
end

function s = local_err_str(e, unsignedRms)
if ~isfinite(e), s = '-'; return; end
if nargin > 1 && unsignedRms, s = sprintf('%.2f m', e);
else, s = sprintf('%+.2f m', e); end
end

function s = local_err2_str(p, trueD)
s = sprintf('%s / %s', local_err_str(p.strongR - trueD), local_err_str(p.nearR - trueD));
end

function s = local_ms_str(f)
if ~isfinite(f.median), s = '-'; return; end
s = sprintf('%.2f m / %.2f m', f.median, f.spread);
end

function d = local_newest(root)
dd = dir(fullfile(root, 'Capture_*'));
dd = dd([dd.isdir]);
keep = false(size(dd));
for i = 1:numel(dd)
    keep(i) = exist(fullfile(root, dd(i).name, 'serial_log.txt'), 'file') == 2;
end
dd = dd(keep);
if isempty(dd)
    error('No Capture_* folder with serial_log.txt in %s - pass the folder.', root);
end
[~, j] = max([dd.datenum]);
d = fullfile(root, dd(j).name);
end

% =============================================================================
function fig = local_plot(R, o, label, nBg, nP2, nMoved)
cB = [0 0.35 0.75];          % BSDA: blue
cC = [0.85 0.33 0.1];        % complex: orange
cT = [0 0.6 0.25];           % where you stood
fig = figure('Color', 'w', 'Position', [40 30 1250 1150]);
% Fixed axes, legends to the right: the panels share one x position, so the
% two difference panels line up for comparing by eye, and no legend hides data.
pos = @(row) [0.07, 0.05 + (4 - row) * 0.235, 0.60, 0.165];
g = R.grid; x = R.distance;
B = R.bsda; C = R.complex;

% 1. Background level and scatter, in dB
ax1 = axes('Position', pos(1)); hold(ax1, 'on'); grid(ax1, 'on');
db = @local_db;
k = g >= -10 & g <= min(60, max(g));
h1 = plot(ax1, g(k), db(B.bgMean(k)), '-', 'Color', cB, 'LineWidth', 1.6);
h2 = plot(ax1, g(k), db(abs(C.bgMean(k))), '-', 'Color', cC, 'LineWidth', 1.6);
h3 = plot(ax1, g(k), db(B.bgSD(k)), '--', 'Color', cB, 'LineWidth', 1);
h4 = plot(ax1, g(k), db(sqrt(C.bgScatter2(k))), '--', 'Color', cC, 'LineWidth', 1);
top = max(local_db([B.bgMean(k); abs(C.bgMean(k))]));
yl = [top - 75, top + 8];
plot(ax1, [R.k0 R.k0], yl, '-', 'Color', [0.8 0 0], 'LineWidth', 1);
ylim(ax1, yl); xlim(ax1, [g(find(k, 1)) g(find(k, 1, 'last'))]);
xlabel(ax1, 'Taps from first path (FP), after re-alignment'); ylabel(ax1, 'Amplitude (dB)');
ttl = sprintf(['Background (n = %d): level (solid) and frame-to-frame scatter (dashed); ' ...
    'red = range zero %+.2f; %d frames re-aligned'], nBg, R.k0, nMoved);
if ~isempty(label), ttl = {label, ttl}; end
title(ax1, ttl, 'Interpreter', 'none');
local_legend(ax1, [h1 h2 h3 h4], {'|CIR| mean', '|Complex mean|', ...
    sprintf('|CIR| SD (%.1f%% on strong taps)', 100 * B.bgScatter), ...
    sprintf('Complex scatter (%.1f%%)', 100 * C.bgScatter)});

% 2. BSDA, 3. complex: each on its own scale
view = isfinite(x) & x >= R.searchFromM & x <= o.MaxRangeM;
dB = max(B.diff, 0);
ax2 = axes('Position', pos(2));
local_diff_panel(ax2, x, dB, B.threshold, B.pick, cB, local_top(dB, view), R.trueDistance, ...
    o, R.searchFromM, sprintf('BSDA: SD in phase 2 - SD in background, negatives removed (n = %d vs %d)', ...
    nP2, nBg), [], '\Delta SD / RXPACC', 'F threshold (per tap)');
ax3 = axes('Position', pos(3));
local_diff_panel(ax3, x, C.diff, C.threshold, C.pick, cC, local_top(C.diff, view), R.trueDistance, ...
    o, R.searchFromM, '|Complex mean of phase 2 - complex mean of background|  (normalised I/Q)', ...
    C.weaker, '\Delta amplitude / RXPACC', 'Threshold (per tap)');

% 4. Readings through phase 2
ax4 = axes('Position', pos(4)); hold(ax4, 'on'); grid(ax4, 'on');
t = R.frameTimes;
h5 = plot(ax4, t, B.frameReadings, 'o', 'Color', cB, 'MarkerSize', 5);
h6 = plot(ax4, t, C.frameReadings, '.', 'Color', cC, 'MarkerSize', 14);
hh = [h5 h6];
lg = {sprintf('BSDA (%d-frame window): %.0f%%, median %s', B.windowFrames, 100 * B.frames.hit, ...
          local_num_str(B.frames.median)), ...
      sprintf('Complex (each frame): %.0f%%, median %s', 100 * C.frames.hit, ...
          local_num_str(C.frames.median))};
if isfinite(R.trueDistance)
    hh(end+1) = plot(ax4, [min(t) max(t)], R.trueDistance * [1 1], '-', ...
        'Color', cT, 'LineWidth', 2);
    lg{end+1} = sprintf('You stood at %.2f m', R.trueDistance);
end
ylim(ax4, [0 min(o.MaxRangeM, 4.5)]);
if numel(t) > 1, xlim(ax4, [min(t) max(t)]); end
xlabel(ax4, 'Time (s)'); ylabel(ax4, 'Distance (m)');
title(ax4, 'Readings through phase 2 (BSDA: sliding window vs background; complex: each frame alone)');
local_legend(ax4, hh, lg);
end

function y = local_top(v, view)
y = 1.15 * max([v(view & isfinite(v)); eps]);
end

function local_diff_panel(ax, x, v, thr, pk, col, yTop, trueD, o, rStart, ttl, weaker, ...
                          yLab, thrName)
hold(ax, 'on'); grid(ax, 'on');
ok = isfinite(x) & isfinite(v) & x <= o.MaxRangeM;
patch(ax, [0 rStart rStart 0], [0 0 yTop yTop], [0.94 0.94 0.94], 'EdgeColor', 'none', ...
    'HandleVisibility', 'off');
hs = plot(ax, x(ok), v(ok), '-', 'Color', col, 'LineWidth', 1.6, 'Marker', '*', ...
    'MarkerSize', 3);
okT = isfinite(x) & isfinite(thr) & x <= o.MaxRangeM;
ht = plot(ax, x(okT), thr(okT), '--', 'Color', col * 0.6 + 0.4, 'LineWidth', 1.2);
hh = [hs ht];
lg = {'Difference', thrName};
if ~isempty(weaker)
    w = weaker & isfinite(x) & x <= o.MaxRangeM;
    if any(w)
        hh(end+1) = plot(ax, x(w), v(w), 'o', 'Color', [0.45 0.45 0.45], 'MarkerSize', 7, ...
            'LineWidth', 1.2);
        lg{end+1} = 'Static path got weaker (one you block?)';
    end
end
if isfinite(pk.strongR)
    [~, j] = min(abs(x - pk.strongR));
    hh(end+1) = plot(ax, pk.strongR, v(j), 'kd', 'MarkerFaceColor', 'k', 'MarkerSize', 8);
    lg{end+1} = sprintf('Strongest %.2f m (%+.1f dB)', pk.strongR, pk.strongDB);
end
if isfinite(pk.nearR) && abs(pk.nearR - pk.strongR) > 1e-6
    [~, j] = min(abs(x - pk.nearR));
    hh(end+1) = plot(ax, pk.nearR, v(j), 'v', 'Color', 'k', 'MarkerFaceColor', col, ...
        'MarkerSize', 9);
    lg{end+1} = sprintf('Nearest detection %.2f m', pk.nearR);
end
if isfinite(trueD)
    hh(end+1) = plot(ax, trueD * [1 1], [0 yTop], '-', 'Color', [0 0.6 0.25], 'LineWidth', 2);
    lg{end+1} = sprintf('You stood at %.2f m', trueD);
end
text(ax, rStart / 2, 0.92 * yTop, {'not', 'searched'}, 'HorizontalAlignment', 'center', ...
    'Color', [0.55 0.55 0.55], 'FontSize', 8);
xlim(ax, [0 o.MaxRangeM]); ylim(ax, [0 yTop]);
xlabel(ax, 'Distance from the midpoint of the modules (m)');
ylabel(ax, yLab);
title(ax, ttl);
local_legend(ax, hh, lg);
end

function s = local_num_str(v)
if isfinite(v), s = sprintf('%.2f m', v); else, s = '-'; end
end

function y = local_db(v)
y = 20 * log10(v);
y(~isfinite(y) | imag(y) ~= 0) = NaN;
end

function local_legend(ax, h, labels)
% Legend just right of its axes, top-aligned with it.
lgd = legend(ax, h, labels, 'Interpreter', 'tex');
set(lgd, 'Units', 'normalized');
pa = get(ax, 'Position');
pl = get(lgd, 'Position');
set(lgd, 'Position', [pa(1) + pa(3) + 0.015, pa(2) + pa(4) - pl(4), pl(3), pl(4)]);
end
