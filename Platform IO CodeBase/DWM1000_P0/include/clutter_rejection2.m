% clutter_rejection2.m
%
% Post-processing comparison for a capture produced by cir_cap3.m.
% Runs the same dataset through several normalisation and clutter-suppression
% variants side by side, so the effect of each can be seen on the plots
% rather than argued about in the abstract.
%
% Variants compared:
%   NORMALISATION
%     (N1) RXPACC-normalised            - as logged by the anchor
%     (N2) per-frame peak self-norm     - AGC gain cancels, no RXPACC needed
%     (N3) per-frame energy self-norm   - same idea, total-energy reference
%   CLUTTER SUPPRESSION
%     (C1) adjacent-frame coherent MTI  - baseline
%     (C2) recursive exponential clutter map
%     (C3) per-tap z-score vs quiet-period baseline
%     (C4) CFAR adaptive threshold on the z-score map
%
% USAGE:
%   Run cir_cap3.m first, then run this. It picks up the newest Capture_*
%   folder automatically unless CAPTURE_DIR is set explicitly. Set
%   QUIET_PERIOD_S to however long the scene was empty at the start.
%
% INPUT:
%   This reads 02_lde_aligned/cir_grid.mat - the pre-aligned complex grid
%   cir_cap3.m writes - NOT the raw per-frame CSVs. The alignment
%   (sample -> taps_from_fp -> common grid) is already done there, so redoing
%   it here would be a second copy of the same logic, free to drift out of
%   step with the capture script, plus one readtable() call per frame.
%
% NOTE ON SELF-NORMALISATION:
%   The DW1000 applies ONE AGC gain per frame across the whole accumulator
%   buffer. So tap-to-tap ratios WITHIN a frame are unaffected by AGC; only
%   absolute comparisons BETWEEN frames are corrupted. Dividing each frame by
%   its own internal reference cancels that per-frame gain algebraically,
%   without depending on RXPACC being accurate or stable.
%
%   Because interpolation is linear and the references are per-frame
%   constants, scaling the stored RXPACC-normalised grid column-by-column is
%   exactly equivalent to normalising each raw frame before resampling.

close all; clear; clc;

% ---- Config ----------------------------------------------------------
CAPTURE_DIR    = 'Capture_20260918_112841';     % empty = use the newest Capture_* folder here
QUIET_PERIOD_S = 15;     % seconds of empty scene at the start of the capture

ALPHA_CLUTTER  = 0.05;   % C2: exponential clutter-map update rate (small = slow)
CFAR_GUARD     = 2;      % C4: guard cells either side of the cell under test
CFAR_TRAIN     = 8;      % C4: training cells either side
CFAR_SCALE     = 3;      % C4: threshold multiplier on local noise estimate
ZSCORE_THRESH  = 4;      % C3: detection threshold in baseline std-devs

NEAR_BAND_TAPS = [0 30]; % tap range quoted in the summary statistics

% ---- Locate the capture ----------------------------------------------
% Hardcoding a folder name goes stale the moment another capture is taken,
% so default to the most recent one.
if isempty(CAPTURE_DIR)
    d = dir('Capture_*');
    d = d([d.isdir]);
    assert(~isempty(d), 'No Capture_* folder found in %s', pwd);
    [~, newest] = max([d.datenum]);
    CAPTURE_DIR = d(newest).name;
    fprintf('Using newest capture: %s\n', CAPTURE_DIR);
end

gridPath = fullfile(CAPTURE_DIR, '02_lde_aligned', 'cir_grid.mat');
assert(isfile(gridPath), ...
    ['%s not found.\nThis script reads the pre-aligned grid written by ' ...
     'cir_cap3.m. Re-run cir_cap3.m to produce it.'], gridPath);

S = load(gridPath);

tapGrid = S.grid_taps_from_fp;
xVec    = S.elapsed_s;
numTaps = numel(tapGrid);
nFrames = numel(S.frame_numbers);

fprintf('Loaded %d taps x %d frames, %.1f s elapsed, D = %.2f m\n', ...
    numTaps, nFrames, xVec(end), S.tag_anchor_dist_m);

% ---- Three parallel normalisations ------------------------------------
% Zgrid_rxpacc is already RXPACC-normalised; the self-normalised variants
% are one scalar multiply per column (see the note in the header).
Z_rxpacc = S.Zgrid_rxpacc;
Z_peak   = Z_rxpacc .* (S.rxpacc ./ S.peak_ref).';
Z_energy = Z_rxpacc .* (S.rxpacc ./ S.energy_ref).';

quietMask = xVec < QUIET_PERIOD_S;
fprintf('Quiet-period frames: %d of %d (first %.1f s)\n', ...
    nnz(quietMask), nFrames, QUIET_PERIOD_S);
if nnz(quietMask) < 5
    warning(['Very few quiet-period frames - the z-score baseline (C3/C4) ' ...
             'will be poorly estimated. Check QUIET_PERIOD_S against the ' ...
             '%.1f s this capture actually covers.'], xVec(end));
end

% ---- C1: adjacent-frame coherent MTI, all three normalisations --------
mti_rxpacc = abs(diff(Z_rxpacc, 1, 2));
mti_peak   = abs(diff(Z_peak,   1, 2));
mti_energy = abs(diff(Z_energy, 1, 2));
mtiTime    = xVec(2:end);

figure('Position',[50 400 1400 420]);
tl = tiledlayout(1,3,'TileSpacing','compact');
title(tl, 'C1: adjacent-frame coherent MTI under three normalisations');

nexttile; imagesc(mtiTime, tapGrid, mti_rxpacc); axis xy; colormap(jet); colorbar;
xlabel('Elapsed (s)'); ylabel('Tap offset from FP'); title('N1: RXPACC-normalised');
xline(QUIET_PERIOD_S,'w--');

nexttile; imagesc(mtiTime, tapGrid, mti_peak); axis xy; colormap(jet); colorbar;
xlabel('Elapsed (s)'); title('N2: peak self-normalised');
xline(QUIET_PERIOD_S,'w--');

nexttile; imagesc(mtiTime, tapGrid, mti_energy); axis xy; colormap(jet); colorbar;
xlabel('Elapsed (s)'); title('N3: energy self-normalised');
xline(QUIET_PERIOD_S,'w--');

% Quantitative comparison: residual during the quiet period is pure artifact,
% since nothing was moving then. Lower = better normalisation.
quietMtiMask = mtiTime < QUIET_PERIOD_S;
nearBand = tapGrid >= NEAR_BAND_TAPS(1) & tapGrid <= NEAR_BAND_TAPS(2);
fprintf('\n--- Quiet-period MTI residual in taps %d-%d (lower is better) ---\n', ...
    NEAR_BAND_TAPS(1), NEAR_BAND_TAPS(2));
fprintf('N1 RXPACC : mean %.4g, median %.4g\n', ...
    mean(mti_rxpacc(nearBand, quietMtiMask), 'all', 'omitnan'), ...
    median(mti_rxpacc(nearBand, quietMtiMask), 'all', 'omitnan'));
fprintf('N2 peak   : mean %.4g, median %.4g\n', ...
    mean(mti_peak(nearBand, quietMtiMask), 'all', 'omitnan'), ...
    median(mti_peak(nearBand, quietMtiMask), 'all', 'omitnan'));
fprintf('N3 energy : mean %.4g, median %.4g\n', ...
    mean(mti_energy(nearBand, quietMtiMask), 'all', 'omitnan'), ...
    median(mti_energy(nearBand, quietMtiMask), 'all', 'omitnan'));
fprintf(['(These are on different scales - compare each against ITS OWN\n' ...
         ' post-quiet values below, not across normalisations.)\n']);

% Contrast ratio: post-quiet residual vs quiet residual, per normalisation.
% This IS comparable across normalisations - it is a ratio, so scale cancels.
fprintf('\n--- Contrast: post-quiet / quiet residual (higher = target stands out more) ---\n');
cr = @(M) mean(M(nearBand, ~quietMtiMask), 'all', 'omitnan') ./ ...
          mean(M(nearBand,  quietMtiMask), 'all', 'omitnan');
fprintf('N1 RXPACC : %.3f\n', cr(mti_rxpacc));
fprintf('N2 peak   : %.3f\n', cr(mti_peak));
fprintf('N3 energy : %.3f\n', cr(mti_energy));

% ---- Pick one normalisation for the remaining techniques --------------
% Peak self-norm is the default here because it removes the AGC gain factor
% without relying on the RXPACC estimate. Change this to compare.
Zsel    = Z_peak;
selName = 'peak self-normalised';
ampSel  = abs(Zsel);

% ---- C2: recursive exponential clutter map ----------------------------
% A single averaged background is brittle - one bad estimate is baked in
% permanently. An exponential moving average adapts slowly, treating only
% fast changes as target and tracking slow drift as clutter.
clutterMap = nan(numTaps,1);
residualC2 = nan(numTaps, nFrames);
for i = 1:nFrames
    col = ampSel(:,i);
    if all(isnan(col)), continue; end
    if all(isnan(clutterMap))
        clutterMap = col;
        residualC2(:,i) = 0;
    else
        residualC2(:,i) = col - clutterMap;
        upd = ~isnan(col);
        clutterMap(upd) = (1-ALPHA_CLUTTER)*clutterMap(upd) + ALPHA_CLUTTER*col(upd);
    end
end

figure('Position',[50 60 1400 420]);
tl2 = tiledlayout(1,3,'TileSpacing','compact');
title(tl2, sprintf('Clutter suppression on %s data', selName));

nexttile;
imagesc(xVec, tapGrid, abs(residualC2)); axis xy; colormap(jet); colorbar;
xlabel('Elapsed (s)'); ylabel('Tap offset from FP');
title(sprintf('C2: recursive clutter map (\\alpha=%.2f)', ALPHA_CLUTTER));
xline(QUIET_PERIOD_S,'w--');

% ---- C3: per-tap z-score against the quiet-period baseline ------------
% Per-tap mean AND std: a tap with naturally high background variance needs
% a higher bar than a rock-stable tap. A single global threshold cannot
% express that; scaling by per-tap std can.
bgMean = mean(ampSel(:, quietMask), 2, 'omitnan');
bgStd  = std( ampSel(:, quietMask), 0, 2, 'omitnan');
zMap   = (ampSel - bgMean) ./ (bgStd + eps);

nexttile;
imagesc(xVec, tapGrid, zMap); axis xy; colormap(jet); colorbar;
xlabel('Elapsed (s)');
title('C3: per-tap z-score vs quiet baseline');
xline(QUIET_PERIOD_S,'w--');
caxis([-ZSCORE_THRESH ZSCORE_THRESH]); %#ok<CAXIS> % clim() is R2022a+

% ---- C4: CFAR adaptive threshold on the z-score map -------------------
% Clutter strength varies hugely across the tap range (strong near FP,
% decaying further out), so one fixed cutoff either misses weak far-field
% targets or false-triggers on near-field clutter. CFAR compares each tap
% against a locally estimated level from its neighbours, excluding guard
% cells so a wide target cannot raise its own threshold.
cfarDet = false(numTaps, nFrames);
for i = 1:nFrames
    col = zMap(:,i);
    if all(isnan(col)), continue; end
    for t = 1:numTaps
        lo = max(1, t - CFAR_TRAIN - CFAR_GUARD) : max(1, t - CFAR_GUARD - 1);
        hi = min(numTaps, t + CFAR_GUARD + 1) : min(numTaps, t + CFAR_TRAIN + CFAR_GUARD);
        trainIdx = [lo, hi];
        trainIdx(trainIdx == t) = [];
        localNoise = mean(abs(col(trainIdx)), 'omitnan');
        if ~isnan(col(t)) && col(t) > CFAR_SCALE * localNoise
            cfarDet(t,i) = true;
        end
    end
end

nexttile;
imagesc(xVec, tapGrid, double(cfarDet)); axis xy; colormap(gray); colorbar;
xlabel('Elapsed (s)');
title(sprintf('C4: CFAR detections (scale=%.1f)', CFAR_SCALE));
xline(QUIET_PERIOD_S,'r--','LineWidth',1.5);

% ---- False-alarm sanity check ----------------------------------------
% Detections during the quiet period are false alarms by construction -
% nothing was moving. This is the honest measure of whether C4 is working.
faQuiet = mean(cfarDet(:, quietMask), 'all');
faAfter = mean(cfarDet(:, ~quietMask), 'all');
fprintf('\n--- CFAR detection rates ---\n');
fprintf('During quiet period (false alarms) : %.3f%% of cells\n', 100*faQuiet);
fprintf('After quiet period                 : %.3f%% of cells\n', 100*faAfter);
if faAfter <= faQuiet * 1.5
    fprintf(['WARNING: post-quiet detection rate is not meaningfully above the\n' ...
             'false-alarm rate. Either no target signal is present, or clutter\n' ...
             'suppression is still inadequate. Do not interpret C4 as detection yet.\n']);
end

% ---- AGC diagnostic: is normalisation actually decorrelating gain? ----
% If a normalisation is working, the normalised peak amplitude should no
% longer track RXPACC. A surviving correlation means gain variation is
% still leaking into the data.
[~, peakTapIdx] = min(abs(tapGrid));    % grid point closest to the first path
validIdx = ~isnan(S.rxpacc) & ~isnan(abs(Z_peak(peakTapIdx,:))).';
if nnz(validIdx) > 3
    [r1,p1] = corr(S.rxpacc(validIdx), abs(Z_rxpacc(peakTapIdx,validIdx)).');
    [r2,p2] = corr(S.rxpacc(validIdx), abs(Z_peak(peakTapIdx,validIdx)).');
    [r3,p3] = corr(S.rxpacc(validIdx), abs(Z_energy(peakTapIdx,validIdx)).');
    fprintf('\n--- Residual RXPACC correlation at tap 0 (want |r| near 0) ---\n');
    fprintf('N1 RXPACC : r=%+.3f (p=%.3f)\n', r1, p1);
    fprintf('N2 peak   : r=%+.3f (p=%.3f)\n', r2, p2);
    fprintf('N3 energy : r=%+.3f (p=%.3f)\n', r3, p3);
end

fprintf('\nDone.\n');
