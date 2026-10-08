function out = cir_phase_analysis_iq(captureDir, varargin)
%CIR_PHASE_ANALYSIS_IQ  Where you stood: CIR_capture's magnitude method vs complex I/Q, same frames.
%
%   out = CIR_PHASE_ANALYSIS_IQ(captureDir)
%   out = CIR_PHASE_ANALYSIS_IQ(captureDir, 'TrueDistance', 1.5, ...)
%   out = CIR_PHASE_ANALYSIS_IQ()          newest Capture_IQ_* folder in pwd
%
% For a static session recorded with cir_iq_capture (its serial_log.txt
% keeps I and Q). The session is split exactly as in cir_phase_analysis2:
% background before walk_prompt_at_s, the walking break thrown away,
% phase 2 after it. The SAME frames then go through two chains:
%
%   Magnitude  what CIR_capture + cir_phase_analysis2 do: |I+jQ| / RXPACC on
%              the FP-relative grid, mean of each phase, phase 2 minus
%              background, negatives removed.
%   Complex    what the MTI code does: I/Q on the same grid, refined by up
%              to +/-0.75 tap against the direct-path shape, divided by the
%              frame's own complex direct-path gain; then the complex mean of
%              each phase and the size of their difference,
%              |mean(phase 2) - mean(background)|.
%
% Why they can differ. Where your echo p lands on a tap that already holds a
% static reflection B, the magnitude method sees |B + p| - |B|, which is
% about |p| x cos(angle between them): anything from +|p| down to -|p|, so
% you can vanish or even show up as a dip. The complex method sees |p|
% whatever the angle. Its costs: it also sees frame-to-frame phase jitter of
% strong static paths (|B| x jitter), which the magnitude ignores; your own
% breathing and sway rotate your echo and shrink its average; and a path you
% block counts as a change too (a positive bump behind you, where the
% magnitude method shows a dip it then clips).
%
% Both use the same k0 (direct-path lead-edge-to-peak offset, taken from the
% magnitude background like cir_phase_analysis2) and the same ellipse
% geometry, so any difference in distance comes from the method alone.
%
% Figure (cir_iq_compare.png), top to bottom:
%   1. background level (solid) and frame-to-frame scatter (dashed) of each
%      method: the floor each one has to beat, tap by tap
%   2. magnitude difference vs distance (cir_phase_analysis2's bottom panel)
%   3. complex difference vs distance, same scale
%   4. single-frame readings through phase 2 (what a tracker would see)
% Dashed lines in 2 and 3 are per-tap thresholds with the same false-alarm
% rate (NoiseSigmaK sigma), from the background frames' own scatter. The
% dotted line in 2 is cir_phase_analysis2's threshold (3 sigma from the
% negatives), for reference.
%
% Options:
%   'TrueDistance'   []     m from the modules' midpoint; default from
%                           session_info.csv (cir_iq_capture 'TrueDistance')
%   'Separation'     []     m; default from session_info.csv, else 1
%   'SettleSeconds'  0      drop frames before this (both methods)
%   'WalkPromptAtS'  [], 'WalkDurationS' []   override session_info.csv
%   'MinRangeM'      0.5    peaks are searched from here ...
%   'MaxRangeM'      6      ... to here (cir_phase_analysis2's default)
%   'NoiseSigmaK'    3
%   'PeakOffsetTaps' []     force k0 (taps); default: max of the background
%                           0..8 taps after FP, as cir_phase_analysis2
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
           'WalkPromptAtS', [], 'WalkDurationS', [], 'MinRangeM', 0.5, ...
           'MaxRangeM', 6, 'NoiseSigmaK', 3, 'PeakOffsetTaps', [], ...
           'MinFrameFrac', 0.8, 'Plot', true, 'Verbose', true);
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

% ---- Magnitude chain: exactly cir_phase_analysis2's per-frame step -------------
Amag = nan(nG, nF);
for i = 1:nF
    f   = frames{i};
    acc = 1;
    if isfield(f.meta, 'RXPACC') && f.meta.RXPACC > 0, acc = f.meta.RXPACC; end
    [u, ia] = unique(f.sample - f.meta.FP_INDEX);
    a = hypot(f.re, f.im) / acc;                 % amplitude_norm
    if numel(u) >= 2
        Amag(:, i) = interp1(u, a(ia), g, 'linear', NaN);
    end
end

% ---- Complex chain: the MTI's own mti_step, run without ever "finishing
% learning", so each frame is only aligned and normalised --------------------------
cfg = mti_config('Separation', sep, 'TapToMetres', t2m, 'TapsBeforeFP', tb, ...
                 'TapsAfterFP', ta, 'GridStep', step, 'SettleSeconds', 0, ...
                 'LearnSeconds', 1e9);
S = mti_init(cfg);
Y = nan(nG, nF);
gainAbs = nan(1, nF);
for i = find(el >= o.SettleSeconds)
    [S, R] = mti_step(S, frames{i});
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
[muP, ~,   nP] = local_stats(Amag(:, isP2), o.MinFrameFrac);
dMag = muP - muB;
[cB, vB, nCB]  = local_stats(Y(:, isBg), o.MinFrameFrac);
[cP, ~,  nCP]  = local_stats(Y(:, isP2), o.MinFrameFrac);
dIQ = abs(cP - cB);

% ---- k0 and the distance axis (shared) ----------------------------------------------
[k0auto, k0first] = local_k0(g, muB);
k0 = k0auto;
if ~isempty(o.PeakOffsetTaps), k0 = o.PeakOffsetTaps; end
dist = mti_geometry('tap2range', g, cfg, k0);
win  = isfinite(dist) & dist >= o.MinRangeM & dist <= o.MaxRangeM;

% ---- Thresholds ---------------------------------------------------------------------
K = o.NoiseSigmaK;
neg = dMag(isfinite(dMag) & dMag < 0);
thrNeg = NaN;                                   % cir_phase_analysis2's line
if numel(neg) >= 5, thrNeg = K * median(abs(neg)) / 0.6745; end
% Per tap, from the background frames' scatter. The magnitude difference is
% close to Gaussian (K sigma). The complex one is a length, |difference|,
% Rayleigh-distributed when nothing changed, so the factor for the same
% false-alarm rate is sqrt(-ln(Pfa)) = 2.57 for K = 3.
fK = sqrt(-log(0.5 * erfc(K / sqrt(2))));
thrMag = K  * sdB .* sqrt(1 ./ nB  + 1 ./ nP);
thrIQ  = fK * sqrt(vB .* (1 ./ nCB + 1 ./ nCP));

% ---- Averaged picks ---------------------------------------------------------------
pm = local_pick(max(dMag, 0), thrMag, dist, win);
pc = local_pick(dIQ, thrIQ, dist, win);
% Taps where the complex difference is big but it is the static path itself
% getting weaker, keeping its phase (the change points straight against the
% background, within ~25 deg): most likely a path you are blocking, not your
% echo. Your own echo cancelling part of a static path can also make a tap
% weaker, but its change then points in some other direction. (The
% magnitude method shows both as dips and clips them.)
along = real((cP - cB) .* conj(cB)) ./ (abs(cP - cB) .* abs(cB));
weaker = abs(cP) < abs(cB) & dIQ > thrIQ & along < -0.9;

% ---- Single-frame readings through phase 2 ------------------------------------------
iP2 = find(isP2);
nP2f = numel(iP2);
readM = nan(1, nP2f); readC = nan(1, nP2f);
% Detected on each tap's own scatter (sigma units), then placed on the top of
% the difference itself, up to one tap away: where the scatter changes across
% an echo (a static path beside it), the sigma-scaled peak sits off the echo.
climb = max(1, round(1 / step));
for j = 1:nP2f
    dM1 = Amag(:, iP2(j)) - muB;
    dC1 = abs(Y(:, iP2(j)) - cB);                     % the MTI's statistic
    a = local_pick(max(dM1 ./ sdB, 0), K  * ones(nG, 1), dist, win, max(dM1, 0), climb);
    b = local_pick(dC1 ./ sqrt(vB),    fK * ones(nG, 1), dist, win, dC1, climb);
    readM(j) = a.nearR;
    readC(j) = b.nearR;
end
fm = local_frame_summary(readM, trueD);
fc = local_frame_summary(readC, trueD);

% ---- Scatter on the strong static taps: why one method has the lower floor ----------
noiseM = median(muB(g >= -45 & g <= -8 & isfinite(muB)));
strong = g >= k0 + 3 & isfinite(muB) & muB > 5 * noiseM & isfinite(vB);
scatM = median(sdB(strong) ./ muB(strong));
scatC = median(sqrt(vB(strong)) ./ abs(cB(strong)));

% ---- Report ---------------------------------------------------------------------------
if o.Verbose
    fprintf('\n=== Magnitude vs complex I/Q: %s ===\n', captureDir);
    if ~isempty(label), fprintf('Run label : %s\n', label); end
    fprintf(['Frames    : %d background (%.1f-%.1f s) | %d phase 2 ' ...
             '(%.1f-%.1f s), the same frames for both\n'], sum(isBg), ...
        min(el(isBg)), max(el(isBg)), sum(isP2), min(el(isP2)), max(el(isP2)));
    if isfield(info, 'nBadFrames') && info.nBadFrames > 0
        fprintf('            (%d corrupted frames dropped first)\n', info.nBadFrames);
    end
    fprintf('Geometry  : foci %g m apart, direct-path peak k0 = %+.2f taps', sep, k0);
    if ~isempty(o.PeakOffsetTaps), fprintf(' (given)'); end
    fprintf('\n');
    if isempty(o.PeakOffsetTaps) && isfinite(k0first) && abs(k0first - k0auto) > 1
        fprintf(['  NOTE: the strongest point 0-8 taps after FP is at %+.1f, but an ' ...
                 'earlier peak within 6 dB sits at %+.1f.\n        If %+.1f is a ' ...
                 'floor/ceiling bounce rather than the direct pulse, every distance ' ...
                 'reads\n        about %.2f m short. Try ''PeakOffsetTaps'', %g.\n'], ...
            k0auto, k0first, k0auto, local_shift_m(k0auto, k0first, trueD, cfg), k0first);
    end
    if isfinite(trueD), fprintf('You stood : %.2f m\n', trueD); end
    fprintf('\n%-34s %-24s %-24s\n', '', 'Magnitude (CIR_capture)', 'Complex I/Q (MTI chain)');
    fprintf('%-34s %-24s %-24s\n', 'Averaged: strongest peak', ...
        local_peak_str(pm.strongR, pm.strongDB), local_peak_str(pc.strongR, pc.strongDB));
    fprintf('%-34s %-24s %-24s\n', 'Averaged: nearest detection', ...
        local_peak_str(pm.nearR, pm.nearDB), local_peak_str(pc.nearR, pc.nearDB));
    if isfinite(trueD)
        fprintf('%-34s %-24s %-24s\n', 'Averaged: error (nearest - true)', ...
            local_err_str(pm.nearR - trueD), local_err_str(pc.nearR - trueD));
    end
    fprintf('%-34s %-24s %-24s\n', 'Single frames: detected', ...
        sprintf('%.0f%% of %d', 100 * fm.hit, nP2f), sprintf('%.0f%% of %d', 100 * fc.hit, nP2f));
    fprintf('%-34s %-24s %-24s\n', 'Single frames: median / spread', ...
        local_ms_str(fm), local_ms_str(fc));
    if isfinite(trueD)
        fprintf('%-34s %-24s %-24s\n', 'Single frames: RMS error', ...
            local_err_str(fm.rms, true), local_err_str(fc.rms, true));
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
             'threshold within 10 dB of the strongest, the rule\n cir_mti_live uses. ' ...
             'Single frames = one frame against the background, no averaging: what the\n ' ...
             'MTI sees.)\n']);
end

% ---- Save --------------------------------------------------------------------------------
fid = fopen(fullfile(captureDir, 'cir_iq_compare.csv'), 'w');
fprintf(fid, ['taps_from_fp,offset_m,mag_bg_mean,mag_bg_sd,mag_p2_mean,mag_diff,' ...
              'mag_threshold,iq_bg_abs,iq_bg_scatter,iq_p2_abs,iq_diff,iq_threshold\n']);
fprintf(fid, '%.4f,%.4f,%.6g,%.6g,%.6g,%.6g,%.6g,%.6g,%.6g,%.6g,%.6g,%.6g\n', ...
    [g dist muB sdB muP dMag thrMag abs(cB) sqrt(vB) abs(cP) dIQ thrIQ].');
fclose(fid);
fid = fopen(fullfile(captureDir, 'cir_iq_frames.csv'), 'w');
fprintf(fid, 'elapsed_s,magnitude_reading_m,complex_reading_m\n');
fprintf(fid, '%.4f,%.4f,%.4f\n', [el(iP2); readM; readC]);
fclose(fid);

out = struct('dir', captureDir, 'grid', g, 'distance', dist, 'k0', k0, ...
    'separation', sep, 'trueDistance', trueD, ...
    'magnitude', struct('bgMean', muB, 'bgSD', sdB, 'p2Mean', muP, 'diff', dMag, ...
        'threshold', thrMag, 'thresholdNeg', thrNeg, 'pick', pm, ...
        'frameReadings', readM, 'frames', fm, 'bgScatter', scatM), ...
    'complex', struct('bgMean', cB, 'bgScatter2', vB, 'p2Mean', cP, 'diff', dIQ, ...
        'threshold', thrIQ, 'pick', pc, 'frameReadings', readC, 'frames', fc, ...
        'bgScatter', scatC, 'weaker', weaker), ...
    'frameTimes', el(iP2), 'counts', [sum(isBg) sum(isP2)]);

if o.Plot
    out.fig = local_plot(out, o, label, sum(isBg), sum(isP2));
    print(out.fig, fullfile(captureDir, 'cir_iq_compare.png'), '-dpng', '-r150');
    if o.Verbose, fprintf('Saved cir_iq_compare.png, cir_iq_compare.csv, cir_iq_frames.csv\n'); end
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
function [k, kFirst] = local_k0(g, mu)
% cir_phase_analysis2's rule: the maximum of the background 0..8 taps after
% FP. kFirst is the earliest local peak within 6 dB of it, to warn when the
% maximum is probably a floor/ceiling bounce sitting on the pulse's tail.
k = 0; kFirst = NaN;
w = find(g >= 0 & g <= 8 & isfinite(mu));
if isempty(w), return; end
[pk, j] = max(mu(w));
if ~(pk > 0), return; end
k = g(w(j));
v = mu(w);
if numel(v) < 3, kFirst = k; return; end
isMax = [v(1) > v(2); v(2:end-1) >= v(1:end-2) & v(2:end-1) > v(3:end); v(end) > v(end-1)];
c = find(isMax & v >= pk / 2, 1);
if ~isempty(c), kFirst = g(w(c)); end
end

function d = local_shift_m(kA, kB, r, cfg)
if ~isfinite(r), r = 1.5; end
tap = mti_geometry('range2tap', r, cfg, kA);
d = mti_geometry('tap2range', tap, cfg, kB) - r;
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
function fig = local_plot(R, o, label, nBg, nP2)
cM = [0 0.35 0.75];          % magnitude: blue, as cir_phase_analysis2
cC = [0.85 0.33 0.1];        % complex: orange
cT = [0 0.6 0.25];           % where you stood
fig = figure('Color', 'w', 'Position', [40 30 1250 1150]);
% Fixed axes, legends to the right: the panels share one x position, so the
% two difference panels line up for comparing by eye, and no legend hides data.
pos = @(row) [0.07, 0.05 + (4 - row) * 0.235, 0.60, 0.165];
g = R.grid; x = R.distance;
M = R.magnitude; C = R.complex;

% 1. Background level and scatter, in dB
ax1 = axes('Position', pos(1)); hold(ax1, 'on'); grid(ax1, 'on');
db = @local_db;
k = g >= -10 & g <= min(60, max(g));
h1 = plot(ax1, g(k), db(M.bgMean(k)), '-', 'Color', cM, 'LineWidth', 1.6);
h2 = plot(ax1, g(k), db(abs(C.bgMean(k))), '-', 'Color', cC, 'LineWidth', 1.6);
h3 = plot(ax1, g(k), db(M.bgSD(k)), '--', 'Color', cM, 'LineWidth', 1);
h4 = plot(ax1, g(k), db(sqrt(C.bgScatter2(k))), '--', 'Color', cC, 'LineWidth', 1);
top = max(local_db([M.bgMean(k); abs(C.bgMean(k))]));
yl = [top - 75, top + 8];
plot(ax1, [R.k0 R.k0], yl, '-', 'Color', [0.8 0 0], 'LineWidth', 1);
ylim(ax1, yl); xlim(ax1, [g(find(k, 1)) g(find(k, 1, 'last'))]);
xlabel(ax1, 'Taps from first path (FP)'); ylabel(ax1, 'Amplitude (dB)');
ttl = sprintf('Background (n = %d): level (solid) and frame-to-frame scatter (dashed); red = k0 %+.2f', ...
    nBg, R.k0);
if ~isempty(label), ttl = {label, ttl}; end
title(ax1, ttl, 'Interpreter', 'none');
local_legend(ax1, [h1 h2 h3 h4], {'Magnitude mean', '|Complex mean|', ...
    sprintf('Magnitude scatter (%.1f%% on strong taps)', 100 * M.bgScatter), ...
    sprintf('Complex scatter (%.1f%%)', 100 * C.bgScatter)});

% 2 + 3. The two differences, on one scale
view = isfinite(x) & x >= o.MinRangeM & x <= o.MaxRangeM;
dM = max(M.diff, 0);
yTop = 1.15 * max([dM(view & isfinite(dM)); C.diff(view & isfinite(C.diff)); eps]);
ax2 = axes('Position', pos(2));
local_diff_panel(ax2, x, dM, M.threshold, M.pick, cM, yTop, R.trueDistance, o, ...
    sprintf('Magnitude: |phase 2| - |background|, negatives removed (n = %d vs %d)', nP2, nBg), ...
    M.thresholdNeg, []);
ax3 = axes('Position', pos(3));
local_diff_panel(ax3, x, C.diff, C.threshold, C.pick, cC, yTop, R.trueDistance, o, ...
    '|Complex mean of phase 2 - complex mean of background|  (normalised I/Q)', NaN, ...
    C.weaker);

% 4. Single frames
ax4 = axes('Position', pos(4)); hold(ax4, 'on'); grid(ax4, 'on');
t = R.frameTimes;
h5 = plot(ax4, t, M.frameReadings, 'o', 'Color', cM, 'MarkerSize', 5);
h6 = plot(ax4, t, C.frameReadings, '.', 'Color', cC, 'MarkerSize', 14);
hh = [h5 h6];
lg = {sprintf('Magnitude: %.0f%% of frames, median %s', 100 * M.frames.hit, ...
          local_num_str(M.frames.median)), ...
      sprintf('Complex: %.0f%% of frames, median %s', 100 * C.frames.hit, ...
          local_num_str(C.frames.median))};
if isfinite(R.trueDistance)
    hh(end+1) = plot(ax4, [min(t) max(t)], R.trueDistance * [1 1], '-', ...
        'Color', cT, 'LineWidth', 2);
    lg{end+1} = sprintf('You stood at %.2f m', R.trueDistance);
end
ylim(ax4, [0 min(o.MaxRangeM, 4.5)]);
if numel(t) > 1, xlim(ax4, [min(t) max(t)]); end
xlabel(ax4, 'Time (s)'); ylabel(ax4, 'Distance (m)');
title(ax4, 'Single-frame readings in phase 2 (each frame vs the background, no averaging)');
local_legend(ax4, hh, lg);
end

function local_diff_panel(ax, x, v, thr, pk, col, yTop, trueD, o, ttl, thrNeg, weaker)
hold(ax, 'on'); grid(ax, 'on');
ok = isfinite(x) & isfinite(v) & x <= o.MaxRangeM;
hs = plot(ax, x(ok), v(ok), '-', 'Color', col, 'LineWidth', 1.6, 'Marker', '*', ...
    'MarkerSize', 3);
okT = isfinite(x) & isfinite(thr) & x <= o.MaxRangeM;
ht = plot(ax, x(okT), thr(okT), '--', 'Color', col * 0.6 + 0.4, 'LineWidth', 1.2);
hh = [hs ht];
lg = {'Difference', 'Threshold (per tap)'};
if isfinite(thrNeg)
    hh(end+1) = plot(ax, [0 o.MaxRangeM], thrNeg * [1 1], ':', 'Color', [0.4 0.4 0.4], ...
        'LineWidth', 1.2);
    lg{end+1} = 'cir\_phase\_analysis2 threshold';
end
if ~isempty(weaker)
    w = weaker & isfinite(x) & x <= o.MaxRangeM;
    if any(w)
        hh(end+1) = plot(ax, x(w), v(w), 'o', 'Color', [0.45 0.45 0.45], 'MarkerSize', 7, ...
            'LineWidth', 1.2);
        lg{end+1} = 'Static path got weaker (one you block?)';
    end
end
plot(ax, o.MinRangeM * [1 1], [0 yTop], ':', 'Color', [0.6 0.6 0.6]);
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
xlim(ax, [0 o.MaxRangeM]); ylim(ax, [0 yTop]);
xlabel(ax, 'Distance from the midpoint of the modules (m)');
ylabel(ax, '\Delta amplitude / RXPACC');
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
