% clutter_analysis.m
%
% Post-processing comparison script for a capture produced by capture2.m.
% Runs the same dataset through several normalisation and clutter-suppression
% variants side by side, so the effect of each can be seen on the plots
% rather than argued about in the abstract.
%
% Variants compared:
%   NORMALISATION
%     (N1) RXPACC back-calculated       - what capture2.m currently does
%     (N2) per-frame peak self-norm     - AGC gain cancels, no RXPACC needed
%     (N3) per-frame energy self-norm   - same idea, total-energy reference
%   CLUTTER SUPPRESSION
%     (C1) adjacent-frame coherent MTI  - baseline, as in capture2.m
%     (C2) recursive exponential clutter map
%     (C3) per-tap z-score vs quiet-period baseline
%     (C4) CFAR adaptive threshold on the z-score map
%
% USAGE:
%   Set CAPTURE_DIR to a Capture_yyyymmdd_HHMMSS folder, set QUIET_PERIOD_S
%   to whatever was used for that capture, then run.
%
% NOTE ON SELF-NORMALISATION:
%   The DW1000 applies ONE AGC gain per frame across the whole accumulator
%   buffer. So tap-to-tap ratios WITHIN a frame are unaffected by AGC; only
%   absolute comparisons BETWEEN frames are corrupted. Dividing each frame by
%   its own internal reference cancels that per-frame gain algebraically,
%   without depending on RXPACC being accurate or stable.

close all; clear; clc;

% ---- Config ----------------------------------------------------------
CAPTURE_DIR    = 'Capture_20260917_133318';   % <-- set this
QUIET_PERIOD_S = 15;                          % used only if elapsed_s exists
QUIET_PERIOD_FRAMES = 20;                     % used as fallback otherwise -
                                               % set to the frame COUNT that
                                               % was empty-scene, not seconds

RAW_SUBDIR     = '01_raw_frames';
TAPS_BEFORE_FP = 50;
TAPS_AFTER_FP  = 100;
MEAN_GRID_STEP = 0.5;
TAP_TO_METRES  = 0.30028;

RXPACC_MIN_AMPLITUDE = 50;

ALPHA_CLUTTER  = 0.05;   % C2: exponential clutter-map update rate (small = slow)
CFAR_GUARD     = 2;      % C4: guard cells either side of the cell under test
CFAR_TRAIN     = 8;      % C4: training cells either side
CFAR_SCALE     = 3;      % C4: threshold multiplier on local noise estimate
ZSCORE_THRESH  = 4;      % C3: detection threshold in baseline std-devs

% ---- Load ------------------------------------------------------------
rawDir    = fullfile(CAPTURE_DIR, RAW_SUBDIR);
metaTable = readtable(fullfile(CAPTURE_DIR, 'frame_metadata.csv'));

assert(exist(rawDir,'dir') == 7, 'Raw frame folder not found: %s', rawDir);

% frame_metadata.csv from CIR_capture.m (single-session snapshots) has no
% elapsed_s column - only capture2.m's continuous-session format does. Fall
% back to frame index as the time axis; MTI only needs frame ORDER, not
% real elapsed time, so this loses nothing for the MTI/clutter analysis
% itself - only the x-axis label and the quiet-period cutoff units change.
HAS_ELAPSED = ismember('elapsed_s', metaTable.Properties.VariableNames);
if HAS_ELAPSED
    xLabelStr = 'Elapsed (s)';
else
    warning(['No elapsed_s column in frame_metadata.csv - this capture was not ' ...
        'made with capture2.m. Falling back to frame index as the time axis. ' ...
        'Set QUIET_PERIOD_FRAMES (frame COUNT), not QUIET_PERIOD_S, to match.']);
    xLabelStr = 'Frame index';
end

tapGrid = (-TAPS_BEFORE_FP : MEAN_GRID_STEP : TAPS_AFTER_FP)';
excessM = tapGrid * TAP_TO_METRES;
numTaps = numel(tapGrid);
nFrames = height(metaTable);

% Three parallel normalisations, complex-valued, on a common tap grid.
Z_rxpacc = nan(numTaps, nFrames);
Z_peak   = nan(numTaps, nFrames);
Z_energy = nan(numTaps, nFrames);
xVec      = nan(nFrames,1);
rxpaccVec = nan(nFrames,1);

fprintf('Loading %d frames...\n', nFrames);
for i = 1:nFrames
    frameNum = metaTable.FRAME(i);
    fpath = fullfile(rawDir, sprintf('frame_%04d.csv', frameNum));
    if ~isfile(fpath)
        warning('Missing %s - skipping.', fpath);
        continue
    end
    T = readtable(fpath);

    tapsThisFrame = T.sample - metaTable.FP_INDEX(i);
    [uTaps, ia] = unique(tapsThisFrame);

    % --- N1: RXPACC back-calculation (current capture2.m behaviour) -----
    validRows = T.amplitude > RXPACC_MIN_AMPLITUDE;
    if nnz(validRows) < 5
        continue
    end
    rxpaccEst = median(T.amplitude(validRows) ./ T.amplitude_norm(validRows));
    rxpaccVec(i) = rxpaccEst;

    reG = interp1(uTaps, T.real(ia) / rxpaccEst, tapGrid, 'linear', NaN);
    imG = interp1(uTaps, T.imag(ia) / rxpaccEst, tapGrid, 'linear', NaN);
    Z_rxpacc(:,i) = reG + 1i*imG;

    % --- N2: per-frame PEAK self-normalisation --------------------------
    % Reference is this frame's own strongest tap, so the AGC gain factor
    % divides out. Phase is preserved (dividing by a real scalar).
    peakRef = max(T.amplitude);
    if peakRef > 0
        reG = interp1(uTaps, T.real(ia) / peakRef, tapGrid, 'linear', NaN);
        imG = interp1(uTaps, T.imag(ia) / peakRef, tapGrid, 'linear', NaN);
        Z_peak(:,i) = reG + 1i*imG;
    end

    % --- N3: per-frame ENERGY self-normalisation ------------------------
    % Less sensitive than peak-norm to a single anomalous tap, but more
    % sensitive to changes in total scene energy (which a target causes).
    energyRef = sum(T.amplitude, 'omitnan');
    if energyRef > 0
        reG = interp1(uTaps, T.real(ia) / energyRef, tapGrid, 'linear', NaN);
        imG = interp1(uTaps, T.imag(ia) / energyRef, tapGrid, 'linear', NaN);
        Z_energy(:,i) = reG + 1i*imG;
    end

    if HAS_ELAPSED
        xVec(i) = metaTable.elapsed_s(i);
    else
        xVec(i) = i;   % frame index, 1-based - order is all MTI needs
    end
end

if HAS_ELAPSED
    quietCutoff = QUIET_PERIOD_S;
else
    quietCutoff = QUIET_PERIOD_FRAMES;
end
quietMask = xVec < quietCutoff;
fprintf('Quiet-period frames: %d of %d\n', nnz(quietMask), nFrames);
if nnz(quietMask) < 5
    if HAS_ELAPSED
        warning('Very few quiet-period frames - the z-score baseline (C3/C4) will be poorly estimated. Check QUIET_PERIOD_S.');
    else
        warning('Very few quiet-period frames - the z-score baseline (C3/C4) will be poorly estimated. Check QUIET_PERIOD_FRAMES.');
    end
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
xlabel(xLabelStr); ylabel('Tap offset from FP'); title('N1: RXPACC-normalised');
xline(quietCutoff,'w--');

nexttile; imagesc(mtiTime, tapGrid, mti_peak); axis xy; colormap(jet); colorbar;
xlabel(xLabelStr); title('N2: peak self-normalised');
xline(quietCutoff,'w--');

nexttile; imagesc(mtiTime, tapGrid, mti_energy); axis xy; colormap(jet); colorbar;
xlabel(xLabelStr); title('N3: energy self-normalised');
xline(quietCutoff,'w--');

% Quantitative comparison: residual during the quiet period is pure artifact,
% since nothing was moving then. Lower = better normalisation.
quietMtiMask = mtiTime < quietCutoff;
nearBand = tapGrid >= 0 & tapGrid <= 30;   % the AGC-dominated region
fprintf('\n--- Quiet-period MTI residual in taps 0-30 (lower is better) ---\n');
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
xlabel(xLabelStr); ylabel('Tap offset from FP');
title(sprintf('C2: recursive clutter map (\\alpha=%.2f)', ALPHA_CLUTTER));
xline(quietCutoff,'w--');

% ---- C3: per-tap z-score against the quiet-period baseline ------------
% Per-tap mean AND std: a tap with naturally high background variance needs
% a higher bar than a rock-stable tap. A single global threshold cannot
% express that; scaling by per-tap std can.
bgMean = mean(ampSel(:, quietMask), 2, 'omitnan');
bgStd  = std( ampSel(:, quietMask), 0, 2, 'omitnan');
zMap   = (ampSel - bgMean) ./ (bgStd + eps);

nexttile;
imagesc(xVec, tapGrid, zMap); axis xy; colormap(jet); colorbar;
xlabel(xLabelStr);
title('C3: per-tap z-score vs quiet baseline');
xline(quietCutoff,'w--');
caxis([-ZSCORE_THRESH ZSCORE_THRESH]);

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
xlabel(xLabelStr);
title(sprintf('C4: CFAR detections (scale=%.1f)', CFAR_SCALE));
xline(quietCutoff,'r--','LineWidth',1.5);

% ---- False-alarm sanity check ----------------------------------------
% Detections during the quiet period are false alarms by construction -
% nothing was moving. This is the honest measure of whether C4 is working.
faQuiet = mean(cfarDet(:, quietMask), 'all');
faAfter = mean(cfarDet(:, ~quietMask & ~isnan(xVec)'), 'all');
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
peakTapIdx = find(abs(tapGrid) < MEAN_GRID_STEP/2, 1);
if ~isempty(peakTapIdx)
    validIdx = ~isnan(rxpaccVec) & ~isnan(abs(Z_peak(peakTapIdx,:)))';
    if nnz(validIdx) > 3
        [r1,p1] = corr(rxpaccVec(validIdx), abs(Z_rxpacc(peakTapIdx,validIdx))');
        [r2,p2] = corr(rxpaccVec(validIdx), abs(Z_peak(peakTapIdx,validIdx))');
        [r3,p3] = corr(rxpaccVec(validIdx), abs(Z_energy(peakTapIdx,validIdx))');
        fprintf('\n--- Residual RXPACC correlation at tap 0 (want |r| near 0) ---\n');
        fprintf('N1 RXPACC : r=%+.3f (p=%.3f)\n', r1, p1);
        fprintf('N2 peak   : r=%+.3f (p=%.3f)\n', r2, p2);
        fprintf('N3 energy : r=%+.3f (p=%.3f)\n', r3, p3);
    end
end

fprintf('\nDone.\n');