% VER 2
% Background subtraction from LDE-aligned CIR data (CIR_capture.m output)
close all
clear all
clc

bgFolder  = 'Capture_20260913_195501/02_lde_aligned';
objFolder = 'Capture_20260913_195707/02_lde_aligned';

bgFiles  = dir(fullfile(bgFolder,  'frame_*_aligned.csv'));
objFiles = dir(fullfile(objFolder, 'frame_*_aligned.csv'));

assert(~isempty(bgFiles),  'No aligned CSVs found in %s', bgFolder);
assert(~isempty(objFiles), 'No aligned CSVs found in %s', objFolder);

% Sort by frame number (dir() order is not guaranteed)
bgFiles  = sortFramesByNumber(bgFiles);
objFiles = sortFramesByNumber(objFiles);

%% Common tap grid — matches CIR_capture.m's own MEAN_GRID_STEP approach.
% Individual aligned frames are NOT on a shared grid (FP_INDEX is fractional
% and differs per frame), so every frame must be interpolated onto one
% common axis before tap-by-tap subtraction is meaningful.
gridStep     = 0.5;     % taps; match CIR_capture.m's MEAN_GRID_STEP if you want consistency
tapsBeforeFP = 50;
tapsAfterFP  = 100;
tapsFromFP   = (-tapsBeforeFP : gridStep : tapsAfterFP)';   % common axis
numSamples   = numel(tapsFromFP);

%% Step 1: Read + normalize + resample background frames
numBgFrames = numel(bgFiles);
bgRealNorm  = zeros(numSamples, numBgFrames);
bgImagNorm  = zeros(numSamples, numBgFrames);

for k = 1:numBgFrames
    T = readtable(fullfile(bgFolder, bgFiles(k).name));

    % Recover RXPACC (amplitude_norm = amplitude / RXPACC, per CIR_capture.m)
    validRows = T.amplitude > 50;
    rxpaccEst = median(T.amplitude(validRows) ./ T.amplitude_norm(validRows));

    realNorm = T.real / rxpaccEst;
    imagNorm = T.imag / rxpaccEst;

    % Resample onto the common grid (linear interp, NaN outside this frame's range)
    [uTaps, ia] = unique(T.taps_from_fp);
    bgRealNorm(:,k) = interp1(uTaps, realNorm(ia), tapsFromFP, 'linear', NaN);
    bgImagNorm(:,k) = interp1(uTaps, imagNorm(ia), tapsFromFP, 'linear', NaN);
end

meanBgReal    = mean(bgRealNorm, 2, 'omitnan');
meanBgImag    = mean(bgImagNorm, 2, 'omitnan');
meanBgComplex = meanBgReal + 1i*meanBgImag;

%% Step 2: Subtract background from each object frame (also resampled)
numObjFrames = numel(objFiles);
subAmplitude = zeros(numSamples, numObjFrames);
excessPathM  = zeros(numSamples, numObjFrames);    % carried through for physical-unit plots
reflectorOffM = zeros(numSamples, numObjFrames);

for k = 1:numObjFrames
    T_obj = readtable(fullfile(objFolder, objFiles(k).name));

    validRows = T_obj.amplitude > 50;
    rxpaccEst = median(T_obj.amplitude(validRows) ./ T_obj.amplitude_norm(validRows));

    realNorm = T_obj.real / rxpaccEst;
    imagNorm = T_obj.imag / rxpaccEst;

    [uTaps, ia] = unique(T_obj.taps_from_fp);
    realGrid = interp1(uTaps, realNorm(ia),            tapsFromFP, 'linear', NaN);
    imagGrid = interp1(uTaps, imagNorm(ia),             tapsFromFP, 'linear', NaN);
    excessGrid = interp1(uTaps, T_obj.excess_path_m(ia), tapsFromFP, 'linear', NaN);
    reflGrid   = interp1(uTaps, T_obj.reflector_off_m(ia), tapsFromFP, 'linear', NaN);

    Z_obj = realGrid + 1i * imagGrid;
    Z_sub = Z_obj - meanBgComplex;         % coherent subtraction, both normalized + on common grid

    subAmplitude(:,k)  = abs(Z_sub);
    excessPathM(:,k)   = excessGrid;
    reflectorOffM(:,k) = reflGrid;
end

fprintf('Background subtraction completed (%d bg frames, %d object frames, %d taps).\n', ...
    numBgFrames, numObjFrames, numSamples);

%% Plot — tap domain (as before)
figure(); hold on; grid on;
for k = 1:numObjFrames
    plot(tapsFromFP, subAmplitude(:,k), 'DisplayName', sprintf('Frame %d', k));
end
xlabel('Tap offset from first path');
ylabel('Subtracted amplitude');
title('Background-subtracted amplitude');
xline(0, 'k--', 'first path');
legend('show', 'Location', 'eastoutside');

%% Heatmap
figure();
imagesc(1:numObjFrames, tapsFromFP, subAmplitude);
axis xy; colormap(jet); colorbar;
xlabel('Frame Number'); ylabel('Tap offset from first path');
title('2D Background-Subtracted Energy');

%% Dynamic (slow-time) subtraction
dynamicSignal    = subAmplitude - mean(subAmplitude, 2, 'omitnan');
dynamicAmplitude = abs(dynamicSignal);

figure();
imagesc(1:numObjFrames, tapsFromFP, dynamicAmplitude);
axis xy; colormap(jet); colorbar;
xlabel('Frame Number'); ylabel('Tap offset from first path');
title('Dynamic Target Track (Static Wall Leakage Removed)');

%% Dynamic profile
figure(); hold on; grid on;
for k = 1:numObjFrames
    plot(tapsFromFP, dynamicAmplitude(:,k), 'DisplayName', sprintf('Frame %d', k));
end
xlabel('Tap offset from first path'); ylabel('Dynamic amplitude');
title('Dynamic-Only Amplitude per Frame');
xline(0, 'k--', 'first path');
legend('show', 'Location', 'eastoutside');

%% --- helper ---
function filesSorted = sortFramesByNumber(files)
    names = {files.name};
    nums = zeros(numel(names),1);
    for i = 1:numel(names)
        tok = regexp(names{i}, '(\d+)', 'match');
        nums(i) = str2double(tok{end});
    end
    [~, order] = sort(nums);
    filesSorted = files(order);
end