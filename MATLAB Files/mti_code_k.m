clc;
clear;
close all;
%% ===============================
% Load files — from CIR_capture.m raw + metadata output
% ================================
captureDir = 'Capture_20260913_195707';   % set to your Capture_YYYYMMDD_HHMMSS folder
rawFolder  = fullfile(captureDir, '01_raw_frames');

files = dir(fullfile(rawFolder, 'frame_*.csv'));
files = sortFramesByNumber(files);
numFrames = numel(files);
fprintf("Loaded %d frames\n", numFrames);

meta = readtable(fullfile(captureDir, 'frame_metadata.csv'));

%% ===============================
% Common tap grid (FP-relative) — required since FP_INDEX is fractional
% and differs per frame, so raw sample axes don't line up frame-to-frame
% ================================
gridStep     = 0.5;   % taps; match CIR_capture.m's MEAN_GRID_STEP if comparing directly
tapsBeforeFP = 50;
tapsAfterFP  = 100;
tapsFromFP   = (-tapsBeforeFP : gridStep : tapsAfterFP)';
minSamples   = numel(tapsFromFP);
fprintf("Using %d taps on common FP-relative grid\n", minSamples);

%% ===============================
% Import + RXPACC-normalize + resample CIR data onto common grid
% ================================
I = nan(minSamples, numFrames);
Q = nan(minSamples, numFrames);
keptFrameOrder = [];

for k = 1:numFrames
    data = readmatrix(files(k).name);   % [sample, real, imag, amplitude, amplitude_norm]

    frameNum = str2double(regexp(files(k).name, '\d+', 'match', 'once'));
    metaRow  = meta.FRAME == frameNum;
    if nnz(metaRow) ~= 1
        warning('%s: expected exactly 1 metadata match, found %d — skipping.', ...
            files(k).name, nnz(metaRow));
        continue
    end
    fpIndex = meta.FP_INDEX(metaRow);
    rxpacc  = meta.RXPACC(metaRow);

    tapsThisFrame = data(:,1) - fpIndex;
    realNorm = data(:,2) / rxpacc;
    imagNorm = data(:,3) / rxpacc;

    [uTaps, ia] = unique(tapsThisFrame);
    I(:,k) = interp1(uTaps, realNorm(ia), tapsFromFP, 'linear', NaN);
    Q(:,k) = interp1(uTaps, imagNorm(ia), tapsFromFP, 'linear', NaN);
    keptFrameOrder(end+1) = k; %#ok<SAGROW>
end

%% ===============================
% Convert taps to distance — now correctly FP-relative
% ================================
c = 3e8;
sample_period = 1.0016e-9;
range_resolution = c*sample_period/2;
distance = tapsFromFP * (c*sample_period);   % excess path length (round trip halved not applied here — see note)
fprintf("\nRange resolution %.4f m/tap\n", c*sample_period);

%% ===============================
% Complex CIR
% ================================
CIR = I + 1j*Q;
Amplitude = abs(CIR);

%% ===============================
% MTI PROCESSING — consecutive-frame subtraction
% ================================
MTI = diff(CIR, 1, 2, 'omitnan');
MTI_mag = abs(MTI);

%% ===============================
% MTI energy profile
% ================================
range_energy = mean(MTI_mag, 2, 'omitnan');
range_energy = range_energy ./ max(range_energy);

%% ===============================
% Remove invalid edge peaks
% ================================
valid = distance > 0.3 & distance < 5;
detect_signal = zeros(size(range_energy));
detect_signal(valid) = range_energy(valid);

%% ===============================
% Automatic peak detection
% ================================
threshold = mean(detect_signal(valid), 'omitnan') + ...
            3*std(detect_signal(valid), 'omitnan');
[pks,locs] = findpeaks(detect_signal,...
    'MinPeakHeight',threshold,...
    'MinPeakDistance',5);
detected_distance = distance(locs);

%% ===============================
% Plot 1 — Raw CIR vs distance
% ================================
figure;
plot(distance, mean(Amplitude,2,'omitnan'),'LineWidth',1.5);
grid on;
xlabel("Excess path length (m)");
ylabel("Amplitude");
title("Average Raw CIR vs Distance (FP-aligned)");

%% ===============================
% Plot 2 — MTI Human Detection
% ================================
figure;
plot(distance, range_energy, 'LineWidth',1.5);
hold on;
plot(detected_distance, pks, 'ro', 'MarkerSize',10, 'LineWidth',2);
xlabel("Excess path length (m)");
ylabel("Normalised MTI Energy");
title("Automatic Human Motion Detection");
legend("MTI Energy","Detected Peaks");
grid on;

%% ===============================
% Plot 3 — MTI Heatmap
% ================================
figure;
imagesc(1:size(MTI_mag,2), distance, MTI_mag);
axis xy;
xlabel("Frame Transition Number");
ylabel("Excess path length (m)");
title("MTI CIR Heatmap");
colorbar;

%% ===============================
% Print detections
% ================================
fprintf("\n============================\n");
fprintf("Detected Moving Targets\n");
fprintf("============================\n");
if isempty(locs)
    fprintf("No moving targets detected\n");
else
    for i=1:length(locs)
        fprintf("Peak %d : %.2f metres\n", i, detected_distance(i));
    end
end

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