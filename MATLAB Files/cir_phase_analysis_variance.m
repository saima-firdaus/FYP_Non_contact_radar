function out = cir_phase_analysis_variance(captureDir, varargin)
%CIR_PHASE_ANALYSIS_VARIANCE  Bi-static standard deviation algorithm (BSDA).
%
%   out = CIR_PHASE_ANALYSIS_VARIANCE(captureDir)
%   out = CIR_PHASE_ANALYSIS_VARIANCE(captureDir, 'Name', value, ...)
%   out = CIR_PHASE_ANALYSIS_VARIANCE()        % newest Capture_* folder in pwd
%
% Variance counterpart of CIR_PHASE_ANALYSIS2. Same capture layout, same
% background / walk-break / phase-2 split, same ellipse distance axis - but
% the per-tap statistic is the STANDARD DEVIATION of the aligned CIR
% magnitude across frames, not its mean.
%
% Method (Van Herbruggen et al., "Impact of CIR processing for UWB radar
% distance estimation with the DW1000 transceiver", IPIN 2023,
% doi:10.1109/IPIN57070.2023.10332499, Sec. IV-B.2):
%
%   1. Align every CIR on the reported first path (ICIR or UCIR, Sec. IV-A).
%   2. Per tap, take the SD across the background frames and across the
%      target-present frames.
%   3. Subtract: dSD(k) = SD_phase2(k) - SD_background(k).
%   4. The target range is the highest peak of dSD.
%
% Why it works for people: a static reflector adds a constant to every
% frame and leaves the SD alone, whereas a person breathes, sways and shifts
% weight, so the taps their reflection lands in fluctuate frame to frame.
% The paper found BSDA the best estimator for persons (ICIR/UCIR alignment,
% widest TX-RX spacing, ~5 s of CIRs) and worse than the mean-based BMA for
% static metal objects. ACIR is deliberately not offered here: it merges
% frames into one fractional-bin CIR before any per-frame statistic exists,
% and the paper reports ACIR+BSDA as its worst combination (137 cm MAE).
%
% Two additions to the paper, both switchable:
%
%   Per-tap adaptive threshold. Under "nothing changed at tap k" the ratio
%   SD_p2^2 / SD_bg^2 is F(n_p2-1, n_bg-1) distributed, so
%       thresh(k) = SD_bg(k) * (sqrt(F_{1-Pfa}) - 1)
%   is a constant-false-alarm threshold in the same units as dSD. It scales
%   with each tap's own background fluctuation, so strong-clutter taps (whose
%   SD is inflated by residual alignment jitter and AGC wander) need a larger
%   rise before they count. Assumes roughly Gaussian per-tap amplitudes, so
%   treat Pfa as nominal on noise-only taps.
%
%   'PeakMode','first'. Any path involving the person is at least as long as
%   tag -> person -> anchor, so the person can only change taps at or after
%   their own delay. Second-order paths (person -> wall -> anchor) and
%   shadowing therefore always appear LATER than the true return. 'first'
%   takes the earliest run of above-threshold taps and the local maximum
%   within one pulse width of it, instead of the global maximum. 'max' is
%   the paper's rule and is the default.
%
% Name-value options:
%   'Plot'           true     draw and save the three-panel figure
%   'Alignment'      'ucir'   'ucir' = fractional-FP alignment, interpolated
%                             onto the MEAN_GRID_STEP grid (what CIR_capture
%                             writes); 'icir' = integer alignment on
%                             floor(FP_INDEX), 1-tap grid, no interpolation
%   'Interp'         'linear' interp1 method for UCIR ('linear','pchip',
%                             'makima','spline'). The paper used a quadratic
%                             upsampling filter; pchip/makima are the closest
%                             shape-preserving equivalents
%   'Normalise'      'rxpacc' 'rxpacc' = amplitude/RXPACC as captured;
%                             'direct' = additionally divide each frame by its
%                             own direct-path peak, removing gain wander that
%                             otherwise inflates SD at strong-clutter taps
%   'PeakMode'       'max'    'max' (paper) or 'first' (earliest change)
%   'Pfa'            1e-3     per-tap false-alarm probability for the threshold
%   'MinTapsAfterFP' 2        ignore taps closer than this to the direct-path
%                             lobe peak (its edges carry alignment jitter)
%   'MinRunTaps'     1        'first' mode: the change must stay above the
%                             threshold for at least this many taps
%   'PulseWidthTaps' 3        'first' mode: peak search window after the edge
%   'RejectOutliers' true     drop frames with a bad LDE lock, an RXPWR
%                             excursion or merged serial output
%   'MaxFpDevTaps'   10       FP_INDEX deviation from the capture median
%   'MaxRxPwrDevDb'  3        RXPWR deviation from the capture median
%   'MinFrameFrac'   0.8      coverage filter, as in CIR_PHASE_ANALYSIS2
%   'WalkPromptAtS'  []       override session_info.csv
%   'WalkDurationS'  []       likewise
%   'Separation'     []       tag-anchor separation override, metres
%   'MaxRangeM'      6        x-limit and peak-search limit, metres
%   'Verbose'        true
%
% Writes into captureDir (does not touch the mean-based outputs):
%   cir_bsda.csv                per-tap means, SDs, dSD, threshold, detections
%   cir_bsda_analysis.png / .fig
%
% See also CIR_PHASE_ANALYSIS2, CIR_CAPTURE, APS006_STYLE.

% ---- Arguments -----------------------------------------------------------
if nargin < 1 || isempty(captureDir)
    captureDir = local_newest_capture(pwd);
end
captureDir = char(captureDir);
if ~isfolder(captureDir)
    error('Capture folder not found: %s', captureDir);
end

isFlag = @(x) islogical(x) || isnumeric(x);
p = inputParser;
p.addParameter('Plot',           true,     isFlag);
p.addParameter('Alignment',      'ucir',   @(x) any(strcmpi(x, {'ucir','icir'})));
p.addParameter('Interp',         'linear', @(x) any(strcmpi(x, {'linear','pchip','makima','spline'})));
p.addParameter('Normalise',      'rxpacc', @(x) any(strcmpi(x, {'rxpacc','direct'})));
p.addParameter('PeakMode',       'max',    @(x) any(strcmpi(x, {'max','first'})));
p.addParameter('Pfa',            1e-3,     @(x) isscalar(x) && x > 0 && x < 0.5);
p.addParameter('MinTapsAfterFP', 2,        @(x) isscalar(x) && x >= 0);
p.addParameter('MinRunTaps',     1,        @(x) isscalar(x) && x >= 0);
p.addParameter('PulseWidthTaps', 3,        @(x) isscalar(x) && x >= 0);
p.addParameter('RejectOutliers', true,     isFlag);
p.addParameter('MaxFpDevTaps',   10,       @(x) isscalar(x) && x > 0);
p.addParameter('MaxRxPwrDevDb',  3,        @(x) isscalar(x) && x > 0);
p.addParameter('MinFrameFrac',   0.8,      @(x) isscalar(x) && x >= 0 && x <= 1);
p.addParameter('WalkPromptAtS',  [],       @(x) isempty(x) || isscalar(x));
p.addParameter('WalkDurationS',  [],       @(x) isempty(x) || isscalar(x));
p.addParameter('Separation',     [],       @(x) isempty(x) || (isscalar(x) && x > 0));
p.addParameter('MaxRangeM',      6,        @(x) isscalar(x) && x > 0);
p.addParameter('Verbose',        true,     isFlag);
p.parse(varargin{:});
opt = p.Results;
opt.Alignment = lower(char(opt.Alignment));
opt.Interp    = lower(char(opt.Interp));
opt.Normalise = lower(char(opt.Normalise));
opt.PeakMode  = lower(char(opt.PeakMode));

% ---- Session description -------------------------------------------------
S = local_read_session(captureDir);
if ~isempty(opt.WalkPromptAtS), S.walk_prompt_at_s = opt.WalkPromptAtS; end
if ~isempty(opt.WalkDurationS), S.walk_duration_s  = opt.WalkDurationS; end
if isnan(S.walk_prompt_at_s) || isnan(S.walk_duration_s)
    error(['No session_info.csv in %s and no phase timings given. Pass ' ...
           'WalkPromptAtS and WalkDurationS.'], captureDir);
end
breakEndsAt = S.walk_prompt_at_s + S.walk_duration_s;

% ---- Frame metadata ------------------------------------------------------
metaFile = fullfile(captureDir, 'frame_metadata.csv');
if ~isfile(metaFile)
    error('No frame_metadata.csv in %s', captureDir);
end
M = readtable(metaFile);
if ~ismember('elapsed_s', M.Properties.VariableNames)
    error('frame_metadata.csv in %s has no elapsed_s column.', captureDir);
end

% ---- Frame rejection -----------------------------------------------------
% An SD is far less forgiving of outliers than a mean: one frame whose LDE
% locked 78 taps early moves its whole CIR, and its squared deviation lands
% on every tap it touches. Reject before splitting into phases.
[keep, why] = local_frame_filter(M, S, opt);

el     = M.elapsed_s;
isWalk = el >= S.walk_prompt_at_s & el < breakEndsAt;
isBg   = el <  S.walk_prompt_at_s & keep;
isP2   = el >= breakEndsAt        & keep;
nRej   = sum(~keep & ~isWalk);

if opt.Verbose
    fprintf('\n=== %s  [BSDA] ===\n', captureDir);
    if strlength(S.run_label) > 0
        fprintf('Run label : %s\n', S.run_label);
    end
    fprintf('Phases    : background 0-%gs | break %g-%gs | phase2 %g-%gs\n', ...
        S.walk_prompt_at_s, S.walk_prompt_at_s, breakEndsAt, breakEndsAt, ...
        S.capture_seconds);
    fprintf('Frames    : %d background | %d discarded (walk) | %d phase2 | %d rejected (of %d)\n', ...
        sum(isBg), sum(isWalk), sum(isP2), nRej, height(M));
    if nRej > 0
        fprintf('Rejected  : %d bad FP lock, %d RXPWR excursion, %d merged/oversized\n', ...
            sum(why.fp & ~isWalk), sum(why.pwr & ~isWalk), sum(why.len & ~isWalk));
    end
    fprintf('Method    : %s alignment, %s normalisation, peak mode ''%s'', Pfa %g\n', ...
        upper(opt.Alignment), opt.Normalise, opt.PeakMode, opt.Pfa);
end

if sum(isBg) < 3 || sum(isP2) < 3
    error(['Need at least 3 frames in each phase for a standard deviation: ' ...
           'got %d background and %d phase2.'], sum(isBg), sum(isP2));
end

% ---- Common delay grid ---------------------------------------------------
% ICIR has integer taps by construction, so its grid is integer too. UCIR
% uses the capture's own averaging grid.
if strcmp(opt.Alignment, 'icir')
    step = 1;
else
    step = S.mean_grid_step;
end
gTaps = (-S.taps_before_fp : step : S.taps_after_fp)';

bg = local_phase_stats(captureDir, M(isBg, :), gTaps, S, 'background', opt);
p2 = local_phase_stats(captureDir, M(isP2, :), gTaps, S, 'phase2',     opt);

% ---- BSDA statistic ------------------------------------------------------
dSD  = p2.sd - bg.sd;
dPos = dSD;
dPos(dPos < 0) = 0;             % NaN stays NaN

% ---- Distance axis (identical to cir_phase_analysis2) --------------------
sepM      = local_separation(S, M, opt);
pulseTaps = local_pulse_peak_offset(gTaps, bg.mu);
[offM, resFloorM] = local_offset_metres(gTaps - pulseTaps, S.tap_to_metres, sepM);

% ---- Per-tap adaptive threshold -----------------------------------------
Fq  = local_finv(1 - opt.Pfa, p2.nPer - 1, bg.nPer - 1);
thr = bg.sd .* (sqrt(Fq) - 1);
thr(~isfinite(dSD)) = NaN;

% ---- Search region and detections ---------------------------------------
search = isfinite(dSD) & isfinite(thr) & (gTaps - pulseTaps) >= opt.MinTapsAfterFP;
if isfinite(sepM)
    search = search & isfinite(offM) & offM <= opt.MaxRangeM;
end
isDet = search & dSD > thr;

kMax   = local_max_peak(dSD, search);
kFirst = local_first_change(dSD, isDet, gTaps, opt);
if strcmp(opt.PeakMode, 'first')
    kSel = kFirst;
else
    kSel = kMax;
end

if opt.Verbose
    if isnan(sepM)
        fprintf('Separation : unknown - reporting taps only. Pass Separation.\n');
    else
        fprintf('Separation : %.3g m (foci) -> offset resolvable from %.2f m\n', ...
            sepM, resFloorM);
    end
    fprintf('Pulse shape: direct-path peak %+g tap(s) after leading edge, removed from axis\n', ...
        pulseTaps);
    fprintf('Detections : %d of %d searched taps above the per-tap threshold\n', ...
        sum(isDet), sum(search));
    local_print_peak('Max peak   ', kMax,   gTaps, offM, dSD, thr, strcmp(opt.PeakMode,'max'));
    local_print_peak('First chg. ', kFirst, gTaps, offM, dSD, thr, strcmp(opt.PeakMode,'first'));
end

% ---- Save ----------------------------------------------------------------
T = table(gTaps, offM, bg.mu, p2.mu, bg.sd, p2.sd, dSD, dPos, thr, isDet, ...
    bg.nPer, p2.nPer, 'VariableNames', ...
    {'taps_from_fp','offset_m','background_mean','phase2_mean', ...
     'background_sd','phase2_sd','sd_diff','sd_diff_pos','sd_diff_thresh', ...
     'detected','n_background','n_phase2'});
writetable(T, fullfile(captureDir, 'cir_bsda.csv'));
if opt.Verbose
    fprintf('Saved cir_bsda.csv\n');
end

% ---- Result --------------------------------------------------------------
out = struct();
out.dir        = captureDir;
out.session    = S;
out.options    = opt;
out.gTaps      = gTaps;
out.background = bg;
out.phase2     = p2;
out.sdDiff     = dSD;
out.sdDiffPos  = dPos;
out.sdThresh   = thr;
out.detected   = isDet;
out.search     = search;
out.offsetM    = offM;
out.separation = sepM;
out.pulseTaps  = pulseTaps;
out.resFloorM  = resFloorM;
out.maxRangeM  = opt.MaxRangeM;
out.kMax       = kMax;
out.kFirst     = kFirst;
out.kSelected  = kSel;
out.rangeM     = NaN;
out.rangeTaps  = NaN;
if ~isempty(kSel)
    out.rangeTaps = gTaps(kSel) - pulseTaps;
    out.rangeM    = offM(kSel);
end
out.counts = struct('background', sum(isBg), 'discarded', sum(isWalk), ...
                    'phase2', sum(isP2), 'rejected', nRej, 'total', height(M));
if strcmp(opt.Normalise, 'direct')
    out.yUnit = 'CIR Amplitude / direct-path peak';
else
    out.yUnit = 'CIR Amplitude / RXPACC';
end

% ---- Figure --------------------------------------------------------------
if opt.Plot
    out.fig = local_plot(out);
    exportgraphics(out.fig, fullfile(captureDir, 'cir_bsda_analysis.png'), ...
        'Resolution', 200);
    savefig(out.fig, fullfile(captureDir, 'cir_bsda_analysis.fig'));
    if opt.Verbose
        fprintf('Saved cir_bsda_analysis.png / .fig\n');
    end
end
end

% =========================================================================
function [keep, why] = local_frame_filter(M, S, opt)
%LOCAL_FRAME_FILTER  Frames that are safe to put into a standard deviation.
n   = height(M);
why = struct('fp', false(n,1), 'pwr', false(n,1), 'len', false(n,1));
keep = true(n,1);
if ~opt.RejectOutliers
    return
end
v = M.Properties.VariableNames;

% FP_INDEX drifts a few taps over a capture with the clock offset; that is
% legitimate. A lock tens of taps away from the median is not.
if ismember('FP_INDEX', v)
    fp = M.FP_INDEX;
    why.fp = ~isfinite(fp) | abs(fp - median(fp, 'omitnan')) > opt.MaxFpDevTaps;
end
if ismember('RXPWR', v)
    pw = M.RXPWR;
    why.pwr = ~isfinite(pw) | abs(pw - median(pw, 'omitnan')) > opt.MaxRxPwrDevDb;
end
% More samples than the window holds means two frames' output ran together
% on the serial link. Short (truncated) frames are left to the coverage filter.
if ismember('n_samples', v)
    nExp = S.taps_before_fp + S.taps_after_fp;
    why.len = M.n_samples > nExp;
end
keep = ~(why.fp | why.pwr | why.len);
end

% =========================================================================
function ph = local_phase_stats(captureDir, Mp, gTaps, S, name, opt)
%LOCAL_PHASE_STATS  Per-tap mean and SD of one phase's aligned magnitudes.
%
% Magnitudes only: the aligned CSVs carry no I/Q, and the carrier phase is
% random frame to frame anyway. The mean is kept because the distance-axis
% pulse calibration is measured on the background's direct-path lobe.
nWanted  = height(Mp);
ampGrid  = nan(numel(gTaps), nWanted);
nUsed    = 0;
nMissing = 0;
method   = opt.Interp;
if strcmp(opt.Alignment, 'icir')
    method = 'linear';          % integer taps onto an integer grid: exact
end

for i = 1:nWanted
    f = local_frame_path(captureDir, Mp, i, S.aligned_subdir);
    if isempty(f) || ~isfile(f)
        nMissing = nMissing + 1;
        continue
    end
    T = readtable(f);
    if ~all(ismember({'taps_from_fp','amplitude_norm'}, T.Properties.VariableNames))
        nMissing = nMissing + 1;
        continue
    end

    if strcmp(opt.Alignment, 'icir')
        x = local_icir_axis(T, Mp, i);
    else
        x = T.taps_from_fp;
    end
    a = T.amplitude_norm;

    if strcmp(opt.Normalise, 'direct')
        win = T.taps_from_fp >= -1 & T.taps_from_fp <= 8;
        ref = max(a(win));
        if isempty(ref) || ~isfinite(ref) || ref <= 0
            nMissing = nMissing + 1;
            continue
        end
        a = a ./ ref;
    end

    [ux, ia] = unique(x);
    if numel(ux) < 2
        nMissing = nMissing + 1;
        continue
    end
    nUsed = nUsed + 1;
    ampGrid(:, nUsed) = interp1(ux, a(ia), gTaps, method, NaN);
end
ampGrid = ampGrid(:, 1:nUsed);

if nUsed < 3
    error('Phase "%s" has only %d readable aligned frame(s) in %s.', ...
        name, nUsed, captureDir);
end
if nMissing > 0 && opt.Verbose
    fprintf('  %s: skipped %d unreadable/empty frame file(s).\n', name, nMissing);
end

nPer = sum(~isnan(ampGrid), 2);
mu   = mean(ampGrid, 2, 'omitnan');
sd   = std(ampGrid, 0, 2, 'omitnan');
mu(nPer == 0) = NaN;
sd(nPer <  2) = NaN;

% Coverage: an SD over 6 frames and one over 90 are not the same estimator,
% and the F threshold below would be wrong for the thin ones anyway.
minPer = ceil(opt.MinFrameFrac * nUsed);
thin   = nPer < max(minPer, 3);
mu(thin) = NaN;
sd(thin) = NaN;
nPer(thin) = 0;

ph = struct('name', name, 'mu', mu, 'sd', sd, 'nPer', nPer, ...
            'nFrames', nUsed, 'rxpwr', local_phase_rxpwr(Mp));

if opt.Verbose
    kept = ~isnan(sd);
    fprintf('  %s: %d frame(s); SD kept on %d of %d grid points', ...
        name, nUsed, sum(kept), numel(gTaps));
    if any(kept)
        fprintf(' (taps %+g to %+g)', min(gTaps(kept)), max(gTaps(kept)));
    end
    fprintf('.\n');
end
end

% =========================================================================
function x = local_icir_axis(T, Mp, i)
%LOCAL_ICIR_AXIS  Taps relative to floor(FP_INDEX), per the paper's ICIR.
v = Mp.Properties.VariableNames;
if ismember('sample', T.Properties.VariableNames) && ismember('FP_INT', v)
    x = T.sample - Mp.FP_INT(i);
elseif ismember('FP_INDEX', v)
    fp = Mp.FP_INDEX(i);
    x  = T.taps_from_fp + (fp - floor(fp));   % sample - floor(FP)
else
    x = T.taps_from_fp;
end
x = round(x);                                  % kill float residue
end

% =========================================================================
function x = local_finv(p, d1, d2)
%LOCAL_FINV  F-distribution quantile without the Statistics Toolbox.
% If X ~ F(d1,d2) then B = d1 X / (d1 X + d2) ~ Beta(d1/2, d2/2).
x  = nan(size(d1));
ok = isfinite(d1) & isfinite(d2) & d1 >= 1 & d2 >= 1;
if ~any(ok), return; end
b = betaincinv(p, d1(ok) / 2, d2(ok) / 2);
x(ok) = (d2(ok) .* b) ./ (d1(ok) .* (1 - b));
end

% =========================================================================
function k = local_max_peak(d, search)
%LOCAL_MAX_PEAK  The paper's rule: highest positive dSD in the search region.
k = [];
v = d;
v(~search) = NaN;
if ~any(isfinite(v)), return; end
[pk, j] = max(v);
if isfinite(pk) && pk > 0
    k = j;
end
end

% =========================================================================
function k = local_first_change(d, isDet, gTaps, opt)
%LOCAL_FIRST_CHANGE  Earliest sustained above-threshold run, then its peak.
k = [];
if ~any(isDet), return; end
step = median(diff(gTaps));
nRun = floor(opt.MinRunTaps / step) + 1;     % points spanning MinRunTaps taps
n    = numel(isDet);
k1   = [];
for j = 1:(n - nRun + 1)
    if all(isDet(j:j + nRun - 1))
        k1 = j;
        break
    end
end
if isempty(k1), return; end
jEnd = find(gTaps <= gTaps(k1) + opt.PulseWidthTaps, 1, 'last');
w    = k1:jEnd;
[~, r] = max(d(w));
k = w(r);
end

% =========================================================================
function local_print_peak(label, k, gTaps, offM, d, thr, selected)
tag = '';
if selected, tag = '  <- selected'; end
if isempty(k)
    fprintf('%s: none%s\n', label, tag);
    return
end
state = 'above threshold';
if ~(d(k) > thr(k)), state = 'BELOW threshold - not a detection'; end
if isfinite(offM(k))
    fprintf('%s: tap %+g, %.2f m, dSD %.4g (thresh %.4g, %s)%s\n', ...
        label, gTaps(k), offM(k), d(k), thr(k), state, tag);
else
    fprintf('%s: tap %+g, dSD %.4g (thresh %.4g, %s)%s\n', ...
        label, gTaps(k), d(k), thr(k), state, tag);
end
end

% =========================================================================
% Helpers below are unchanged from cir_phase_analysis2.m so both scripts
% resolve separation, pulse offset and distance identically.
% =========================================================================
function D = local_separation(S, M, opt)
D = NaN;
if ~isempty(opt.Separation)
    D = opt.Separation;
    return
end
if isfield(S, 'tag_anchor_dist_m') && isscalar(S.tag_anchor_dist_m) && ...
        isnumeric(S.tag_anchor_dist_m) && isfinite(S.tag_anchor_dist_m) && ...
        S.tag_anchor_dist_m > 0
    D = S.tag_anchor_dist_m;
    return
end
if ismember('tag_anchor_dist_m', M.Properties.VariableNames)
    v = M.tag_anchor_dist_m;
    v = v(isfinite(v) & v > 0);
    if ~isempty(v)
        D = median(v);
        return
    end
end
tok = regexp(char(S.run_label), 'sep([0-9]+(?:p[0-9]+)?)m', 'tokens', 'once');
if ~isempty(tok)
    val = str2double(strrep(tok{1}, 'p', '.'));
    if isfinite(val) && val > 0
        D = val;
        warning(['Separation %g m parsed from the run label "%s" - nothing in ' ...
                 'this capture recorded it. Pass Separation to be sure.'], ...
                 val, S.run_label);
    end
end
end

% =========================================================================
function k = local_pulse_peak_offset(gTaps, bgMu)
k = 0;
win = gTaps >= 0 & gTaps <= 8;
if ~any(win), return; end
v = bgMu;
v(~win) = NaN;
[pk, j] = max(v);
if ~isfinite(pk) || pk <= 0, return; end
k = gTaps(j);
if ~isfinite(k) || k < 0, k = 0; end
end

% =========================================================================
function [b, resFloor] = local_offset_metres(gTaps, tapToMetres, D)
b        = nan(size(gTaps));
resFloor = NaN;
if isnan(D) || D <= 0, return; end
excess = gTaps * tapToMetres;
c      = D / 2;
a      = (excess + D) / 2;
ok     = excess > 0;
b(ok)  = sqrt(max(a(ok).^2 - c^2, 0));
if any(ok), resFloor = min(b(ok)); end
end

% =========================================================================
function p = local_phase_rxpwr(Mp)
p = NaN;
if ~ismember('RXPWR', Mp.Properties.VariableNames), return; end
v = Mp.RXPWR;
v = v(isfinite(v));
if ~isempty(v), p = mean(v); end
end

% =========================================================================
function f = local_frame_path(captureDir, Mp, i, alignedSubdir)
f = '';
v = Mp.Properties.VariableNames;
if ismember('aligned_csv', v)
    rel = Mp.aligned_csv(i);
    if iscell(rel)
        rel = rel{1};
    elseif isstring(rel)
        rel = char(rel);
    elseif ~ischar(rel)
        rel = '';
    end
    if ~isempty(rel)
        rel = strrep(rel, char(92), filesep);
        rel = strrep(rel, '/', filesep);
        f   = fullfile(captureDir, rel);
    end
end
if (isempty(f) || ~isfile(f)) && ismember('FRAME', v)
    f = fullfile(captureDir, alignedSubdir, ...
        sprintf('frame_%04d_aligned.csv', Mp.FRAME(i)));
end
end

% =========================================================================
function S = local_read_session(captureDir)
S = struct('run_label', "", 'run_stamp', "", 'capture_seconds', NaN, ...
           'walk_prompt_at_s', NaN, 'walk_duration_s', NaN, ...
           'taps_before_fp', 50, 'taps_after_fp', 100, ...
           'mean_grid_step', 0.5, 'tap_to_metres', 0.30028, ...
           'tag_anchor_dist_m', NaN, ...
           'aligned_subdir', '02_lde_aligned');
f = fullfile(captureDir, 'session_info.csv');
if ~isfile(f)
    warning('No session_info.csv in %s - falling back to script defaults.', captureDir);
    return
end
T  = readtable(f, 'TextType', 'string');
fn = fieldnames(S);
for i = 1:numel(fn)
    if ismember(fn{i}, T.Properties.VariableNames)
        val = T.(fn{i})(1);
        if isstring(val) || ischar(val)
            S.(fn{i}) = string(val);
        else
            S.(fn{i}) = val;
        end
    end
end
S.aligned_subdir = char(S.aligned_subdir);
S.run_label      = string(S.run_label);
end

% =========================================================================
function d = local_newest_capture(root)
dd = dir(fullfile(root, 'Capture_*'));
dd = dd([dd.isdir]);
if isempty(dd)
    error('No Capture_* folder found in %s - pass a capture folder path.', root);
end
[~, newest] = max([dd.datenum]);
d = fullfile(root, dd(newest).name);
end

% =========================================================================
% Plotting
% =========================================================================
function fig = local_plot(R)
st  = aps006_style();
fig = figure('Color', st.figureColour, 'Position', [80 40 950 940]);
tl  = tiledlayout(fig, 3, 1, 'TileSpacing', 'compact', 'Padding', 'compact');

ttl = 'CIR standard deviation by phase (BSDA)';
if strlength(R.session.run_label) > 0
    ttl = sprintf('%s  -  %s', ttl, R.session.run_label);
end
title(tl, ttl, 'FontSize', st.labelFontSize + 1, 'FontWeight', 'bold', ...
    'Interpreter', 'none');

% One y-range for both SD panels, so they compare by eye.
both = [R.background.sd; R.phase2.sd];
both = both(isfinite(both));
if isempty(both)
    yr = [0 1];
else
    yr = [0 max(max(both) * st.headroom, eps)];
end

ax1 = local_sd_panel(tl, R, R.background, [], st, yr, ...
    sprintf('Background SD (n = %d frames)', R.background.nFrames));
ax2 = local_sd_panel(tl, R, R.phase2, R.background.sd, st, yr, ...
    sprintf('Phase 2 SD, target present (n = %d frames)', R.phase2.nFrames));
linkaxes([ax1 ax2], 'x');
xlim(ax1, [min(R.gTaps) max(R.gTaps)]);

local_bsda_panel(tl, R, st);
end

% =========================================================================
function ax = local_sd_panel(tl, R, ph, refSd, st, yr, titleStr)
ax = nexttile(tl); hold(ax, 'on');
g  = R.gTaps;

hR = gobjects(0);
if ~isempty(refSd)
    hR = plot(ax, g, refSd, st.controlStyle, 'Color', st.controlColour, ...
        'LineWidth', st.controlWidth, 'DisplayName', 'Background SD');
end
hC = plot(ax, g, ph.sd, '-', 'Color', st.cirColour, ...
    'LineWidth', st.cirWidth, 'Marker', st.cirMarker, ...
    'MarkerSize', st.cirMarkerSize, ...
    'MarkerIndices', local_marker_indices(g), ...
    'DisplayName', 'SD across frames');
hF = plot(ax, [0 0], yr, '-', 'Color', st.fpColour, ...
    'LineWidth', st.fpWidth, 'DisplayName', st.fpLabel);

local_style_axes(ax, st);
xlim(ax, [min(g) max(g)]);
ylim(ax, yr);
ylabel(ax, ['SD of ' R.yUnit], 'FontSize', st.labelFontSize);
title(ax, titleStr, 'FontSize', st.labelFontSize, 'FontWeight', 'normal');
if ~isnan(ph.rxpwr)
    subtitle(ax, sprintf('RXPWR %.1f dBm (mean)', ph.rxpwr), ...
        'FontSize', st.fontSize, 'FontWeight', 'normal');
end
legend(ax, [hC hR hF], 'Location', 'northeast', ...
    'FontSize', st.legendSize, 'Box', 'on', 'EdgeColor', [0 0 0]);
end

% =========================================================================
function ax = local_bsda_panel(tl, R, st)
ax = nexttile(tl); hold(ax, 'on');

y  = R.sdDiffPos;
th = R.sdThresh;
useM = isfinite(R.separation) && any(isfinite(R.offsetM) & isfinite(y));

if useM
    x  = R.offsetM;
    ok = isfinite(x) & isfinite(y);
    xMax = min(R.maxRangeM, max(x(ok)));
    if ~isfinite(xMax) || xMax <= R.resFloorM
        xMax = max(x(ok));
    end
    xLim   = [0 xMax];
    xLabel = 'Offset from tag-anchor baseline (m)';
else
    x  = R.gTaps;
    ok = isfinite(y);
    xLim   = [min(x) max(x)];
    xLabel = st.xLabelFP;
end
inView = ok & x >= xLim(1) & x <= xLim(2);

% Threshold only sets the scale where it is actually used, otherwise the
% huge SD at the direct-path lobe edges flattens everything else.
thView = th(inView & R.search & isfinite(th));
yTop   = max([y(inView); thView; eps]) * st.headroom;
dr     = [0 yTop];

plot(ax, xLim, [0 0], '-', 'Color', st.zeroColour, 'LineWidth', st.zeroWidth);

hD = plot(ax, x(ok), y(ok), '-', 'Color', st.diffColour, ...
    'LineWidth', st.cirWidth, 'Marker', st.cirMarker, ...
    'MarkerSize', st.cirMarkerSize, ...
    'DisplayName', 'SD_{phase2} - SD_{background}');

okT = R.search & isfinite(th) & isfinite(x);
hT = plot(ax, x(okT), th(okT), '--', 'Color', st.noiseColour, ...
    'LineWidth', st.noiseWidth, ...
    'DisplayName', sprintf('Per-tap F threshold (P_{fa} %g)', R.options.Pfa));

if useM
    hF = plot(ax, [R.resFloorM R.resFloorM], dr, '-', 'Color', st.fpColour, ...
        'LineWidth', st.fpWidth, ...
        'DisplayName', sprintf('Resolution floor (%.2f m)', R.resFloorM));
    unit = @(k) sprintf('%.2f m', x(k));
else
    hF = plot(ax, [0 0], dr, '-', 'Color', st.fpColour, ...
        'LineWidth', st.fpWidth, 'DisplayName', st.fpLabel);
    unit = @(k) sprintf('%+g taps', x(k));
end

sel = @(mode) ternary(strcmp(R.options.PeakMode, mode), ' (selected)', '');
hM = gobjects(0);
if ~isempty(R.kMax)
    hM = plot(ax, x(R.kMax), y(R.kMax), st.peakMarker, ...
        'Color', st.peakColour, 'MarkerFaceColor', st.peakFace, ...
        'MarkerSize', st.peakSize, ...
        'DisplayName', ['Max peak @ ' unit(R.kMax) sel('max')]);
end
hE = gobjects(0);
if ~isempty(R.kFirst) && ~isequal(R.kFirst, R.kMax)
    hE = plot(ax, x(R.kFirst), y(R.kFirst), 'o', ...
        'Color', st.fpColour, 'LineWidth', 1.5, 'MarkerSize', st.peakSize + 2, ...
        'DisplayName', ['First change @ ' unit(R.kFirst) sel('first')]);
end

local_style_axes(ax, st);
xlim(ax, xLim);
ylim(ax, dr);
xlabel(ax, xLabel, 'FontSize', st.labelFontSize);
ylabel(ax, ['\Delta SD of ' R.yUnit], 'FontSize', st.labelFontSize);
title(ax, 'BSDA: Phase 2 SD - Background SD, negatives removed', ...
    'FontSize', st.labelFontSize, 'FontWeight', 'normal');
subtitle(ax, sprintf('%s alignment, %s normalisation; lead-edge-to-peak offset %+g tap(s) removed', ...
    upper(R.options.Alignment), R.options.Normalise, R.pulseTaps), ...
    'FontSize', st.fontSize, 'FontWeight', 'normal');
legend(ax, [hD hT hF hM hE], 'Location', 'northeast', ...
    'FontSize', st.legendSize, 'Box', 'on', 'EdgeColor', [0 0 0]);
end

% =========================================================================
function out = ternary(c, a, b)
if c, out = a; else, out = b; end
end

% =========================================================================
function local_style_axes(ax, st)
grid(ax, 'on');
ax.GridLineStyle = st.gridStyle;
ax.GridColor     = st.gridColour;
ax.GridAlpha     = st.gridAlpha;
ax.Layer         = 'bottom';
ax.FontSize      = st.fontSize;
ax.LineWidth     = st.axesWidth;
ax.TickDir       = 'in';
box(ax, 'on');
end

% =========================================================================
function idx = local_marker_indices(gTaps)
step = 1;
if numel(gTaps) > 1
    gridStep = median(diff(gTaps));
    if gridStep > 0
        step = max(1, round(1 / gridStep));
    end
end
idx = 1:step:numel(gTaps);
end