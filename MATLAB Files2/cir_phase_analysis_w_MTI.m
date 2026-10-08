function out = cir_phase_analysis_w_MTI(captureDir, varargin)
%CIR_PHASE_ANALYSIS  Static presence + aligned frame-to-frame MTI motion detection.
%
%   out = CIR_PHASE_ANALYSIS(captureDir)
%   out = CIR_PHASE_ANALYSIS(captureDir, 'Name', value, ...)
%   out = CIR_PHASE_ANALYSIS()            % newest Capture_* folder in pwd
%
% CIR_capture.m records every frame's host-side arrival time as elapsed_s in
% frame_metadata.csv, and the phase boundaries it used in session_info.csv.
% This function reads both and cuts the session into:
%
%   background   elapsed_s <  WALK_PROMPT_AT_S
%   discard      the WALK_DURATION_S break - you were walking, so these
%                frames are dropped entirely
%   phase2       everything after the break
%
% Both phases come from the same continuous serial session, so the AGC and
% oscillator state they share is the whole point: nothing was reset between
% them, and the difference is not swamped by restart drift.
%
% Frame counts per phase always vary - the blink rate wanders and truncated
% frames never get written - so every average here is over however many
% valid frames actually landed in the window, never a fixed count.
%
% Name-value options:
%   'Plot'           true    draw and save the three-panel figure
%   'ShowSD'         true    shade +/- 1 SD across frames on the phase panels
%   'MinFrameFrac'   0.8     a grid point is only averaged where at least this
%                            fraction of the phase's frames reach it. FP_INDEX
%                            moves between frames, so the far ends of the grid
%                            are covered by some frames and not others, and a
%                            mean taken over a different subset of frames at
%                            one tap than at the next is not comparable with
%                            it - those taps come out as NaN instead. Set 0 to
%                            keep everything.
%   'WalkPromptAtS'  []      override session_info.csv (for older captures)
%   'WalkDurationS'  []      likewise
%   'Verbose'        true
%   'RunMTI'         true    run aligned frame-to-frame motion detection
%   'MTIRegion'      'phase2' frames used for motion: 'phase2', 'walk', or 'all'
%   'MTIThresholdSigma' 3    threshold = background MTI mean + N*SD
%   'MTIMinTap'      1       ignore taps at/before first path by default
%   'MTIMaxTap'      Inf     maximum FP-relative tap considered for peaks
%   'MTIMinPeakDistanceTaps' 2.5  suppress nearby duplicate motion peaks
%
% Writes into captureDir:
%   cir_mean_background.csv   taps_from_fp, amplitude_norm_mean,
%   cir_mean_phase2.csv       amplitude_norm_sd, n_frames
%   cir_diff.csv              phase 2 mean minus background mean
%   cir_phase_analysis.png / .fig
%   cir_mti_profile.csv         aligned consecutive-frame MTI profile
%   cir_mti_analysis.png/.fig   MTI profile + slow-time heatmap
%
% Returns a struct with the grid, both phase means, the difference and the
% frame counts, so cir_compare_trial.m can reuse it without re-reading CSVs.
%
% See also CIR_COMPARE_TRIAL, CIR_MULTI_TRIAL, PLOT_CIR_APS006.

% ---- Arguments -----------------------------------------------------------
if nargin < 1 || isempty(captureDir)
    captureDir = local_newest_capture(pwd);
end
captureDir = char(captureDir);
if ~isfolder(captureDir)
    error('Capture folder not found: %s', captureDir);
end

p = inputParser;
p.addParameter('Plot',          true,  @(x) islogical(x) || isnumeric(x));
p.addParameter('ShowSD',        true,  @(x) islogical(x) || isnumeric(x));
p.addParameter('MinFrameFrac',  0.8,   @(x) isscalar(x) && x >= 0 && x <= 1);
p.addParameter('WalkPromptAtS', [],    @(x) isempty(x) || isscalar(x));
p.addParameter('WalkDurationS', [],    @(x) isempty(x) || isscalar(x));
p.addParameter('Verbose',       true,  @(x) islogical(x) || isnumeric(x));

% ---- MTI options ---------------------------------------------------------
% MTI is performed AFTER FP alignment and interpolation to the common tap
% grid.  The current CIR_capture.m aligned CSVs contain amplitude_norm but not
% I/Q, so this implementation subtracts consecutive aligned magnitudes:
%       |A(:,n) - A(:,n-1)|
% This is the same slow-time MTI idea as diff(CIR,1,2), but not coherent
% complex-I/Q MTI.  See the notes printed at the end of this file.
p.addParameter('RunMTI',         true,     @(x) islogical(x) || isnumeric(x));
p.addParameter('MTIRegion',      'phase2', @(x) ischar(x) || isstring(x));
p.addParameter('MTIThresholdSigma', 3,     @(x) isscalar(x) && x >= 0);
p.addParameter('MTIMinTap',      1,        @(x) isscalar(x));
p.addParameter('MTIMaxTap',      Inf,      @(x) isscalar(x));
p.addParameter('MTIMinPeakDistanceTaps', 2.5, @(x) isscalar(x) && x >= 0);
p.addParameter('MTIMaxGapFactor', 3,       @(x) isscalar(x) && x >= 1);
p.parse(varargin{:});
opt = p.Results;

% ---- Session description -------------------------------------------------
S = local_read_session(captureDir);
if ~isempty(opt.WalkPromptAtS), S.walk_prompt_at_s = opt.WalkPromptAtS; end
if ~isempty(opt.WalkDurationS), S.walk_duration_s  = opt.WalkDurationS; end
if isnan(S.walk_prompt_at_s) || isnan(S.walk_duration_s)
    error(['No session_info.csv in %s and no phase timings given. Pass ' ...
           'WalkPromptAtS and WalkDurationS if this capture predates ' ...
           'session_info.csv.'], captureDir);
end
breakEndsAt = S.walk_prompt_at_s + S.walk_duration_s;

% ---- Frame metadata ------------------------------------------------------
metaFile = fullfile(captureDir, 'frame_metadata.csv');
if ~isfile(metaFile)
    error('No frame_metadata.csv in %s', captureDir);
end
M = readtable(metaFile);
if ~ismember('elapsed_s', M.Properties.VariableNames)
    error(['frame_metadata.csv in %s has no elapsed_s column, so its frames ' ...
           'cannot be assigned to a phase. It predates the phased capture ' ...
           'script - recapture with the current CIR_capture.m.'], captureDir);
end

el     = M.elapsed_s;
isBg   = el <  S.walk_prompt_at_s;
isWalk = el >= S.walk_prompt_at_s & el < breakEndsAt;
isP2   = el >= breakEndsAt;

if opt.Verbose
    fprintf('\n=== %s ===\n', captureDir);
    if strlength(S.run_label) > 0
        fprintf('Run label : %s\n', S.run_label);
    end
    fprintf('Phases    : background 0-%gs | break %g-%gs | phase2 %g-%gs\n', ...
        S.walk_prompt_at_s, S.walk_prompt_at_s, breakEndsAt, breakEndsAt, ...
        S.capture_seconds);
    fprintf('Frames    : %d background | %d discarded | %d phase2 (of %d)\n', ...
        sum(isBg), sum(isWalk), sum(isP2), height(M));
end

if sum(isBg) == 0 || sum(isP2) == 0
    error(['Need frames in both phases: got %d background and %d phase2. ' ...
           'This capture cannot be differenced.'], sum(isBg), sum(isP2));
end

% ---- Common delay grid ---------------------------------------------------
% The same grid CIR_capture.m averages onto, rebuilt from session_info.csv
% so that the two can never drift apart.
gTaps = (-S.taps_before_fp : S.mean_grid_step : S.taps_after_fp)';

bg = local_phase_average(captureDir, M(isBg, :), gTaps, S, 'background', opt);
p2 = local_phase_average(captureDir, M(isP2, :), gTaps, S, 'phase2',     opt);

% ---- Difference ----------------------------------------------------------
% Non-coherent magnitudes, so this is a change in reflected energy per tap,
% and it is free to go negative where the target shadowed an existing path.
dAmp = p2.mu - bg.mu;

% ---- Save ----------------------------------------------------------------
bgT = table(gTaps, bg.mu, bg.sd, bg.nPer, 'VariableNames', ...
    {'taps_from_fp','amplitude_norm_mean','amplitude_norm_sd','n_frames'});
p2T = table(gTaps, p2.mu, p2.sd, p2.nPer, 'VariableNames', ...
    {'taps_from_fp','amplitude_norm_mean','amplitude_norm_sd','n_frames'});
dT  = table(gTaps, dAmp, bg.mu, p2.mu, bg.nPer, p2.nPer, 'VariableNames', ...
    {'taps_from_fp','amplitude_norm_diff','background_mean','phase2_mean', ...
     'n_background','n_phase2'});

writetable(bgT, fullfile(captureDir, 'cir_mean_background.csv'));
writetable(p2T, fullfile(captureDir, 'cir_mean_phase2.csv'));
writetable(dT,  fullfile(captureDir, 'cir_diff.csv'));

if opt.Verbose
    fprintf('Saved cir_mean_background.csv, cir_mean_phase2.csv, cir_diff.csv\n');
end

% ---- Result --------------------------------------------------------------
out = struct();
out.dir        = captureDir;
out.session    = S;
out.gTaps      = gTaps;
out.background = bg;
out.phase2     = p2;
out.diff       = dAmp;
out.counts     = struct('background', sum(isBg), 'discarded', sum(isWalk), ...
                        'phase2', sum(isP2), 'total', height(M));

% =========================================================================
% MTI MOVING-TARGET DETECTION
% =========================================================================
% The static/presence branch above answers:
%   "How did the mean CIR change once the person was present?"
%
% The MTI branch below answers a different question:
%   "Which aligned taps changed from one frame to the next?"
%
% Because CIR_capture.m already referenced every saved frame to FP_INDEX, MTI
% is done on that common FP-relative axis.  This prevents small first-path
% timing shifts from being mistaken for motion.
if logical(opt.RunMTI)
    region = lower(string(opt.MTIRegion));
    switch region
        case "phase2"
            Mmotion = M(isP2, :);
        case "walk"
            Mmotion = M(isWalk, :);
        case "all"
            Mmotion = M;
        otherwise
            error('MTIRegion must be ''phase2'', ''walk'', or ''all'' (got "%s").', ...
                string(opt.MTIRegion));
    end

    % Empty-room frame-to-frame changes provide the MTI noise/clutter
    % reference. The motion window is then tested against that baseline.
    bgMTI = local_mti_grid(captureDir, M(isBg, :), gTaps, S, opt, 'background');
    tgMTI = local_mti_grid(captureDir, Mmotion,    gTaps, S, opt, char(region));

    validTap = isfinite(gTaps) & ...
               gTaps >= opt.MTIMinTap & gTaps <= opt.MTIMaxTap;

    % Background-derived threshold.  This is preferable to deriving a
    % threshold from the target window itself because genuine human motion
    % would otherwise increase its own threshold.
    bgVals = bgMTI.profile(validTap & isfinite(bgMTI.profile));
    if numel(bgVals) >= 2
        mtiThreshold = mean(bgVals) + opt.MTIThresholdSigma * std(bgVals);
        thresholdSource = "background";
    else
        % Safe fallback for very short/old captures.
        tgVals = tgMTI.profile(validTap & isfinite(tgMTI.profile));
        if numel(tgVals) >= 2
            mtiThreshold = mean(tgVals) + opt.MTIThresholdSigma * std(tgVals);
            thresholdSource = "motion-window fallback";
        else
            mtiThreshold = Inf;
            thresholdSource = "unavailable";
        end
    end

    [peakIdx, peakVals] = local_mti_peaks( ...
        tgMTI.profile, gTaps, validTap, mtiThreshold, ...
        opt.MTIMinPeakDistanceTaps);

    detected = false(size(gTaps));
    detected(peakIdx) = true;

    tgMTI.threshold       = mtiThreshold;
    tgMTI.thresholdSource = thresholdSource;
    tgMTI.detectedIdx     = peakIdx;
    tgMTI.detectedTaps    = gTaps(peakIdx);
    tgMTI.detectedValues  = peakVals;
    tgMTI.background      = bgMTI.profile;

    % Save one compact MTI result table. taps_from_fp is a delay coordinate,
    % not direct target range in this bistatic tag/anchor geometry.
    thresholdCol = repmat(mtiThreshold, size(gTaps));
    mtiT = table(gTaps, tgMTI.profile, bgMTI.profile, thresholdCol, detected, ...
        'VariableNames', {'taps_from_fp','mti_mean_abs_frame_difference', ...
        'background_mti_mean','threshold','detected_peak'});
    writetable(mtiT, fullfile(captureDir, 'cir_mti_profile.csv'));

    out.mti = tgMTI;
    out.mti.region = region;

    if opt.Verbose
        fprintf('\nMTI motion analysis (%s): %d usable frames -> %d frame pairs\n', ...
            region, tgMTI.nFrames, tgMTI.nPairs);
        fprintf('  Threshold: %.6g (%s, mean + %.1f SD)\n', ...
            mtiThreshold, thresholdSource, opt.MTIThresholdSigma);
        if isempty(peakIdx)
            fprintf('  No moving-target peaks exceeded the MTI threshold.\n');
        else
            fprintf('  Moving-target peak tap(s), relative to FP_INDEX: ');
            fprintf('%+.2f ', gTaps(peakIdx));
            fprintf('\n');
        end
        fprintf(['  NOTE: these are FP-relative delay taps, not metres to the ' ...
                 'person. Bistatic range requires the TX-target-RX geometry.\n']);
        fprintf('Saved cir_mti_profile.csv\n');
    end

    if opt.Plot
        out.mtiFig = local_plot_mti(out.mti, gTaps, S);
        exportgraphics(out.mtiFig, fullfile(captureDir, 'cir_mti_analysis.png'), ...
            'Resolution', 200);
        savefig(out.mtiFig, fullfile(captureDir, 'cir_mti_analysis.fig'));
        if opt.Verbose
            fprintf('Saved cir_mti_analysis.png / .fig\n');
        end
    end
else
    out.mti = [];
end

% ---- Figure --------------------------------------------------------------
if opt.Plot
    out.fig = local_plot(out, logical(opt.ShowSD));
    exportgraphics(out.fig, fullfile(captureDir, 'cir_phase_analysis_w_MTI.png'), ...
        'Resolution', 200);
    savefig(out.fig, fullfile(captureDir, 'cir_phase_analysis_w_MTI.fig'));
    if opt.Verbose
        fprintf('Saved cir_phase_analysis_w_MTI.png / .fig\n');
    end
end
end

% =========================================================================
function R = local_mti_grid(captureDir, Mp, gTaps, S, opt, name)
%LOCAL_MTI_GRID  Consecutive-frame MTI after FP alignment.
%
% Current aligned CSVs contain amplitude_norm rather than I and Q. Therefore
% this routine computes magnitude-domain MTI:
%
%       D(:,n) = A_aligned(:,n+1) - A_aligned(:,n)
%       MTI     = abs(D)
%
% This is intentionally computed AFTER every frame is interpolated onto the
% same taps_from_fp grid.  Subtracting row n from row n+1 before alignment
% can create a large false MTI response when FP_INDEX moves slightly.

if isempty(Mp) || height(Mp) < 2
    error('MTI region "%s" needs at least two frames.', name);
end

% Chronological order matters for a temporal high-pass / two-pulse canceller.
if ismember('elapsed_s', Mp.Properties.VariableNames)
    [~, order] = sort(Mp.elapsed_s);
    Mp = Mp(order, :);
end

nWanted  = height(Mp);
ampGrid  = nan(numel(gTaps), nWanted);
times    = nan(1, nWanted);
nUsed    = 0;
nMissing = 0;

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

    [uTaps, ia] = unique(T.taps_from_fp);
    if numel(uTaps) < 2
        nMissing = nMissing + 1;
        continue
    end

    nUsed = nUsed + 1;
    ampGrid(:, nUsed) = interp1(uTaps, T.amplitude_norm(ia), ...
                                 gTaps, 'linear', NaN);
    if ismember('elapsed_s', Mp.Properties.VariableNames)
        times(nUsed) = Mp.elapsed_s(i);
    else
        times(nUsed) = nUsed;
    end
end

ampGrid = ampGrid(:, 1:nUsed);
times   = times(1:nUsed);

if nUsed < 2
    error('MTI region "%s" has fewer than two readable aligned frames.', name);
end

% Two-pulse canceller: same aligned tap, consecutive frames.
signedDiff = diff(ampGrid, 1, 2);
mtiMag     = abs(signedDiff);
pairTime   = (times(1:end-1) + times(2:end)) / 2;

% If frame files were dropped/missing, do not call a subtraction across a
% very large time gap "consecutive-frame MTI".
if numel(times) >= 3
    dt = diff(times);
    finiteDt = dt(isfinite(dt) & dt > 0);
    if ~isempty(finiteDt)
        typicalDt = median(finiteDt);
        badGap = dt > opt.MTIMaxGapFactor * typicalDt;
        if any(badGap)
            mtiMag(:, badGap) = NaN;
            signedDiff(:, badGap) = NaN;
        end
    end
end

profile = mean(mtiMag, 2, 'omitnan');
nPerTap = sum(isfinite(mtiMag), 2);
profile(nPerTap == 0) = NaN;

R = struct();
R.name       = string(name);
R.ampGrid    = ampGrid;
R.signedDiff = signedDiff;
R.magnitude  = mtiMag;
R.profile    = profile;
R.nPerTap    = nPerTap;
R.time       = times;
R.pairTime   = pairTime;
R.nFrames    = nUsed;
R.nPairs     = size(mtiMag, 2);
R.nMissing   = nMissing;

if opt.Verbose && nMissing > 0
    fprintf('  MTI %s: skipped %d unreadable/empty frame file(s).\n', ...
        name, nMissing);
end
end

% =========================================================================
function [idx, vals] = local_mti_peaks(profile, gTaps, validTap, threshold, minDistTaps)
%LOCAL_MTI_PEAKS  Toolbox-free local-max detector with peak separation.
%
% Candidates must be local maxima, inside the requested tap window and above
% the threshold.  Stronger peaks are selected first, then nearby duplicates
% are suppressed by minDistTaps.

n = numel(profile);
candidate = false(n,1);

for i = 2:n-1
    if ~validTap(i) || ~isfinite(profile(i)) || profile(i) < threshold
        continue
    end
    left  = profile(i-1);
    right = profile(i+1);
    if (~isfinite(left)  || profile(i) >= left) && ...
       (~isfinite(right) || profile(i) >= right)
        candidate(i) = true;
    end
end

cand = find(candidate);
if isempty(cand)
    idx = zeros(0,1);
    vals = zeros(0,1);
    return
end

[~, order] = sort(profile(cand), 'descend');
chosen = zeros(0,1);

for k = 1:numel(order)
    c = cand(order(k));
    if isempty(chosen) || all(abs(gTaps(c) - gTaps(chosen)) >= minDistTaps)
        chosen(end+1,1) = c; %#ok<AGROW>
    end
end

[~, orderByTap] = sort(gTaps(chosen));
idx = chosen(orderByTap);
vals = profile(idx);
end

% =========================================================================
function fig = local_plot_mti(M, gTaps, S)
%LOCAL_PLOT_MTI  MTI energy profile + slow-time heatmap.

fig = figure('Color','w', 'Position', [100 80 1050 760]);
tl = tiledlayout(fig, 2, 1, 'TileSpacing','compact', 'Padding','compact');
title(tl, sprintf('Aligned frame-to-frame MTI - %s', M.name), ...
    'FontWeight','bold', 'Interpreter','none');

% ---- Mean MTI profile ----------------------------------------------------
ax1 = nexttile(tl); hold(ax1,'on');
plot(ax1, gTaps, M.profile, 'LineWidth', 1.4, ...
    'DisplayName','Mean |A_n - A_{n-1}|');
plot(ax1, gTaps, M.background, '--', 'LineWidth', 1.0, ...
    'DisplayName','Empty-room MTI mean');

if isfinite(M.threshold)
    plot(ax1, [min(gTaps) max(gTaps)], [M.threshold M.threshold], ':', ...
        'LineWidth', 1.2, 'DisplayName','Detection threshold');
end

if ~isempty(M.detectedIdx)
    plot(ax1, M.detectedTaps, M.detectedValues, 'o', ...
        'MarkerSize', 8, 'LineWidth', 1.5, ...
        'DisplayName','Detected moving peak');
end

grid(ax1,'on');
xlim(ax1,[min(gTaps) max(gTaps)]);
xlabel(ax1,'Taps relative to LDE first path');
ylabel(ax1,'Mean absolute frame difference');
title(ax1,'MTI motion-energy profile');
legend(ax1,'Location','best');

% ---- Heatmap -------------------------------------------------------------
ax2 = nexttile(tl);
imagesc(ax2, M.pairTime, gTaps, M.magnitude);
axis(ax2,'xy');
xlabel(ax2,'Elapsed time (s)');
ylabel(ax2,'Taps relative to LDE first path');
title(ax2,'MTI heatmap: consecutive aligned frames');
colorbar(ax2);

% Helpful reminder on the figure itself. One tap is propagation delay, not
% direct human range, because the project uses separated TX/RX (bistatic).
if isfield(S,'tap_to_metres') && isfinite(S.tap_to_metres)
    subtitle(ax2, sprintf('1 tap = %.5g m excess propagation path; not direct target range', ...
        S.tap_to_metres));
end
end

% =========================================================================
function ph = local_phase_average(captureDir, Mp, gTaps, S, name, opt)
%LOCAL_PHASE_AVERAGE  Non-coherent average of one phase's frames.
%
% Each frame is resampled onto the shared taps-from-FP grid before averaging,
% because FP_INDEX is fractional and differs frame to frame. Magnitudes are
% averaged, never I/Q: the carrier phase of every path rotates between
% frames, so a coherent average would cancel real energy.

verbose  = opt.Verbose;
nWanted  = height(Mp);
ampGrid  = nan(numel(gTaps), nWanted);
nUsed    = 0;
nMissing = 0;

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
    [uTaps, ia] = unique(T.taps_from_fp);
    if numel(uTaps) < 2
        nMissing = nMissing + 1;
        continue
    end
    nUsed = nUsed + 1;
    ampGrid(:, nUsed) = interp1(uTaps, T.amplitude_norm(ia), gTaps, 'linear', NaN);
end
ampGrid = ampGrid(:, 1:nUsed);

if nUsed == 0
    error('Phase "%s" has no readable aligned frame CSVs in %s', name, captureDir);
end
if nMissing > 0 && verbose
    fprintf('  %s: skipped %d unreadable/empty frame file(s).\n', name, nMissing);
end

nPer = sum(~isnan(ampGrid), 2);
mu   = mean(ampGrid, 2, 'omitnan');
sd   = std(ampGrid, 0, 2, 'omitnan');
mu(nPer == 0) = NaN;
sd(nPer <  2) = NaN;

% ---- Coverage ------------------------------------------------------------
% The grid runs from -TAPS_BEFORE_FP to +TAPS_AFTER_FP, but FP_INDEX drifts
% between frames, so near the ends only some frames reach a given tap. A mean
% over 6 of 41 frames at the last tap and over all 41 in the middle are not
% the same quantity, and differencing two such means manufactures excursions
% at the edges that have nothing to do with the scene. Drop the under-covered
% taps rather than let them turn into detections.
minPer = ceil(opt.MinFrameFrac * nUsed);
thin   = nPer < minPer;
mu(thin) = NaN;
sd(thin) = NaN;

ph = struct();
ph.name    = name;
ph.mu      = mu;
ph.sd      = sd;
ph.nPer    = nPer;
ph.nFrames = nUsed;
ph.noise   = local_phase_noise(Mp);
ph.rxpwr   = local_phase_rxpwr(Mp);

if verbose
    kept = ~isnan(mu);
    fprintf('  %s: averaged %d frame(s); kept %d of %d taps with >= %d frame(s)', ...
        name, nUsed, sum(kept), numel(gTaps), max(minPer,1));
    if any(kept)
        fprintf(' (taps %+g to %+g)', min(gTaps(kept)), max(gTaps(kept)));
    end
    fprintf('.\n');
end
end

% =========================================================================
function lvl = local_phase_noise(Mp)
%LOCAL_PHASE_NOISE  Averaged noise level for a phase, in amplitude/RXPACC units.
%
% The DW1000 reports STD_NOISE x NTM in raw accumulator magnitude, but these
% traces are averaged in amplitude/RXPACC, so each frame's threshold has to be
% divided by that frame's own RXPACC before averaging. Anything less than that
% - averaging raw thresholds, or borrowing one frame's RXPACC - puts the cyan
% line on the wrong scale, so when the columns needed are absent this returns
% NaN and the line is simply left off rather than guessed at.
lvl = NaN;
v = Mp.Properties.VariableNames;
if ~ismember('RXPACC', v), return; end

if ismember('NOISE_THRESH', v)
    thr = Mp.NOISE_THRESH;
elseif all(ismember({'STD_NOISE','NTM'}, v))
    thr = Mp.STD_NOISE .* Mp.NTM;
else
    return
end

acc = Mp.RXPACC;
ok  = isfinite(thr) & isfinite(acc) & acc > 0 & thr > 0;
if any(ok)
    lvl = mean(thr(ok) ./ acc(ok));
end
end

% =========================================================================
function p = local_phase_rxpwr(Mp)
%LOCAL_PHASE_RXPWR  Mean RXPWR over a phase's frames, in dBm, or NaN.
%
% Averaged in dBm as reported rather than converted to linear power first.
% This is a label on a figure, not a radiometric quantity - what it is for is
% spotting that the receive power sat in a different place in phase 2 than it
% did in the background, which is drift showing itself.
p = NaN;
if ~ismember('RXPWR', Mp.Properties.VariableNames), return; end
v = Mp.RXPWR;
v = v(isfinite(v));
if ~isempty(v), p = mean(v); end
end

% =========================================================================
function f = local_frame_path(captureDir, Mp, i, alignedSubdir)
%LOCAL_FRAME_PATH  Where this row's aligned CSV lives.
% Prefers the path frame_metadata.csv recorded, and falls back to rebuilding
% it from the frame number so a hand-edited metadata file still resolves.
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
%LOCAL_READ_SESSION  session_info.csv, with defaults for anything absent.
S = struct('run_label', "", 'run_stamp', "", 'capture_seconds', NaN, ...
           'walk_prompt_at_s', NaN, 'walk_duration_s', NaN, ...
           'taps_before_fp', 50, 'taps_after_fp', 100, ...
           'mean_grid_step', 0.5, 'tap_to_metres', 0.30028, ...
           'aligned_subdir', '02_lde_aligned');

f = fullfile(captureDir, 'session_info.csv');
if ~isfile(f)
    warning('No session_info.csv in %s - falling back to script defaults.', ...
        captureDir);
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
%LOCAL_NEWEST_CAPTURE  Most recently modified Capture_* folder under root.
dd = dir(fullfile(root, 'Capture_*'));
dd = dd([dd.isdir]);
if isempty(dd)
    error('No Capture_* folder found in %s - pass a capture folder path.', root);
end
[~, newest] = max([dd.datenum]);
d = fullfile(root, dd(newest).name);
end

% =========================================================================
function fig = local_plot(R, showSD)
%LOCAL_PLOT  Background / phase 2 / difference, drawn like APS006 Figure 1.
%
% Same instrument as plot_cir_aps006.m: blue asterisk-marked trace, red
% first-path line, filled black diamond on the peak, cyan noise level,
% dashed black grid. Every value comes from aps006_style so the single-frame
% figure and these three panels cannot drift apart.
st  = aps006_style();
fig = figure('Color', st.figureColour, 'Position', [80 40 950 940]);
tl  = tiledlayout(fig, 3, 1, 'TileSpacing', 'compact', 'Padding', 'compact');

ttl = 'CIR by phase';
if strlength(R.session.run_label) > 0
    ttl = sprintf('%s  -  %s', ttl, R.session.run_label);
end
% Interpreter none: run labels are full of underscores, and TeX would turn
% trial1_human_2m_los into subscripts.
title(tl, ttl, 'FontSize', st.labelFontSize + 1, 'FontWeight', 'bold', ...
    'Interpreter', 'none');

axList = gobjects(3,1);

% One y-range for both phase panels. Two panels meant to be compared by eye
% cannot be on scales that differ by however much autoscaling felt like - a
% background panel stretched to its own noise would read as the louder scene.
% The noise line is drawn after these limits are fixed, so a threshold far
% off the trace clips instead of flattening the CIR against the axis.
yr = local_y_range({R.background, R.phase2}, showSD, st);

axList(1) = local_phase_panel(tl, R.gTaps, R.background, st, showSD, yr, ...
    sprintf('Background (n = %d frames)', R.background.nFrames));
axList(2) = local_phase_panel(tl, R.gTaps, R.phase2, st, showSD, yr, ...
    sprintf('Phase 2, target present (n = %d frames)', R.phase2.nFrames));

% ---- Difference ----------------------------------------------------------
ax = nexttile(tl); hold(ax,'on');
plot(ax, [min(R.gTaps) max(R.gTaps)], [0 0], '-', ...
    'Color', st.zeroColour, 'LineWidth', st.zeroWidth);
% cirWidth, not diffWidth: an asterisk drawn with a heavier stroke fills in
% and reads as a dot, which would make this panel's marker look like a
% different symbol from the two above it.
hD = plot(ax, R.gTaps, R.diff, '-', 'Color', st.diffColour, ...
    'LineWidth', st.cirWidth, 'Marker', st.cirMarker, ...
    'MarkerSize', st.cirMarkerSize, ...
    'MarkerIndices', local_marker_indices(R.gTaps), ...
    'DisplayName', 'Phase 2 - Background');

dr = local_pad_range(R.diff, st);
hF = plot(ax, [0 0], dr, '-', 'Color', st.fpColour, ...
    'LineWidth', st.fpWidth, 'DisplayName', st.fpLabel);

% The largest excursion either way. Same filled diamond as Rep:Peak, because
% it plays the same role: this is the tap the eye should go to.
hP = gobjects(0);
[~, j] = max(abs(R.diff));
if isfinite(R.diff(j))
    hP = plot(ax, R.gTaps(j), R.diff(j), st.peakMarker, ...
        'Color', st.peakColour, 'MarkerFaceColor', st.peakFace, ...
        'MarkerSize', st.peakSize, ...
        'DisplayName', sprintf('Peak @ %+g', R.gTaps(j)));
end

local_style_axes(ax, st);
xlim(ax, [min(R.gTaps) max(R.gTaps)]);
ylim(ax, dr);
xlabel(ax, st.xLabelFP, 'FontSize', st.labelFontSize);
ylabel(ax, ['\Delta ' st.yLabelNorm], 'FontSize', st.labelFontSize);
title(ax, 'Difference (Phase 2 - Background)', ...
    'FontSize', st.labelFontSize, 'FontWeight', 'normal');
legend(ax, [hD hF hP], 'Location', 'northeast', ...
    'FontSize', st.legendSize, 'Box', 'on', 'EdgeColor', [0 0 0]);
axList(3) = ax;

linkaxes(axList, 'x');
xlim(axList(1), [min(R.gTaps) max(R.gTaps)]);
end

% =========================================================================
function ax = local_phase_panel(tl, gTaps, ph, st, showSD, yr, titleStr)
%LOCAL_PHASE_PANEL  One averaged phase, drawn like the single-frame figure.
%
% The first path sits at taps_from_fp = 0 by construction, since every frame
% was aligned onto it before averaging, so the red line goes there rather
% than at FP_INDEX. The diamond marks the peak of the averaged trace; it is
% deliberately labelled "Peak" and not "Rep:Peak", because the chip reports
% Rep:Peak for one frame and never reported this.
ax = nexttile(tl); hold(ax,'on');

hSD = gobjects(0);
if showSD
    ok = ~isnan(ph.mu) & ~isnan(ph.sd);
    if any(ok)
        xs  = gTaps(ok);
        lo  = ph.mu(ok) - ph.sd(ok);
        hi  = ph.mu(ok) + ph.sd(ok);
        hSD = fill(ax, [xs; flipud(xs)], [lo; flipud(hi)], st.sdFaceColour, ...
            'FaceAlpha', st.sdFaceAlpha, 'EdgeColor', 'none', ...
            'DisplayName', '\pm1 SD across frames');
    end
end

hC = plot(ax, gTaps, ph.mu, '-', 'Color', st.cirColour, ...
    'LineWidth', st.cirWidth, 'Marker', st.cirMarker, ...
    'MarkerSize', st.cirMarkerSize, ...
    'MarkerIndices', local_marker_indices(gTaps), ...
    'DisplayName', 'Mean CIR');

hF = plot(ax, [0 0], yr, '-', 'Color', st.fpColour, ...
    'LineWidth', st.fpWidth, 'DisplayName', st.fpLabel);

hP = gobjects(0);
[~, j] = max(ph.mu);
if ~isempty(j) && isfinite(ph.mu(j))
    hP = plot(ax, gTaps(j), ph.mu(j), st.peakMarker, ...
        'Color', st.peakColour, 'MarkerFaceColor', st.peakFace, ...
        'MarkerSize', st.peakSize, ...
        'DisplayName', sprintf('Peak @ %+g', gTaps(j)));
end

hN = gobjects(0);
if ~isnan(ph.noise)
    if ph.noise < yr(1) || ph.noise > yr(2)
        % Say so rather than let it look absent: a threshold off the top of
        % the panel means the averaged CIR never cleared it.
        nLabel = sprintf('%s (off scale, %.4g)', st.noiseLabel, ph.noise);
    else
        nLabel = st.noiseLabel;
    end
    hN = plot(ax, [min(gTaps) max(gTaps)], [ph.noise ph.noise], '-', ...
        'Color', st.noiseColour, 'LineWidth', st.noiseWidth, ...
        'DisplayName', nLabel);
end

local_style_axes(ax, st);
xlim(ax, [min(gTaps) max(gTaps)]);
ylim(ax, yr);   % fixed before anything else can rescale it
ylabel(ax, st.yLabelNorm, 'FontSize', st.labelFontSize);
title(ax, titleStr, 'FontSize', st.labelFontSize, 'FontWeight', 'normal');

if ~isnan(ph.rxpwr)
    subtitle(ax, sprintf('RXPWR %.1f dBm (mean)', ph.rxpwr), ...
        'FontSize', st.fontSize, ...
        'FontWeight', 'normal');
end

legend(ax, [hC hF hP hN hSD], 'Location', 'northeast', ...
    'FontSize', st.legendSize, 'Box', 'on', 'EdgeColor', [0 0 0]);
end

% =========================================================================
function local_style_axes(ax, st)
%LOCAL_STYLE_AXES  The application note's axes, straight out of the style.
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
%LOCAL_MARKER_INDICES  One asterisk per tap, whatever the grid step is.
%
% plot_cir_aps006 puts a marker on every accumulator sample, i.e. one per
% tap. The averaging grid is finer than that (MEAN_GRID_STEP is 0.5 taps by
% default), so mark every Nth point instead of every one - otherwise the same
% style comes out twice as dense here as on the single-frame figure.
step = 1;
if numel(gTaps) > 1
    gridStep = median(diff(gTaps));
    if gridStep > 0
        step = max(1, round(1 / gridStep));
    end
end
idx = 1:step:numel(gTaps);
end

% =========================================================================
function yr = local_y_range(phases, showSD, st)
%LOCAL_Y_RANGE  A single y-range covering every phase trace on the figure.
lo = []; hi = [];
for i = 1:numel(phases)
    mu = phases{i}.mu;
    sd = phases{i}.sd;
    if showSD
        band = [mu - sd; mu + sd];
    else
        band = mu;
    end
    band = band(isfinite(band));
    if isempty(band), continue; end
    lo = min([lo; band]);
    hi = max([hi; band]);
end
if isempty(lo)
    yr = [0 1];
    return
end
% The note's axis starts at zero and leaves headroom above the peak; keep
% that unless the SD band actually reaches below zero.
yr = [min(0, lo), max(hi * st.headroom, eps)];
end

% =========================================================================
function r = local_pad_range(v, st)
%LOCAL_PAD_RANGE  Symmetric-ish limits for a trace that can go negative.
v = v(isfinite(v));
if isempty(v), r = [-1 1]; return; end
lo = min(v); hi = max(v);
pad = (st.headroom - 1) * max(hi - lo, eps);
r = [lo - pad, hi + pad];
end