%% UWB MATCHED FILTER + SVD DEMONSTRATION
% Final Year Project: Through-the-Wall Human Detection using UWB Radar
%
% This script demonstrates two processing stages:
%   1) Matched filtering: correlates each received fast-time waveform with a
%      known reference UWB pulse to improve pulse detectability in noise.
%   2) Singular Value Decomposition (SVD): treats repeated captures as a
%      range-bin x slow-time matrix and removes the dominant low-rank mode,
%      which is used here as an estimate of static direct-path/wall clutter.
%
% The supplied CIR CSV data are SYNTHETIC/ILLUSTRATIVE, not experimental data.
% Replace them with your own exported measurements when available.
%
% IMPORTANT DW1000 NOTE:
% The DW1000 CIR accumulator is already the result of correlation inside the
% receiver. Therefore, a conventional matched filter is most physically
% meaningful for raw/MSO waveform samples (Phase 2). On DW1000 CIR data, the
% equivalent step is better described as template correlation / peak
% enhancement. SVD can be applied directly to repeated CIR frames.
%
% Data orientation expected below:
%   rows    = fast-time/range samples
%   columns = repeated frames (slow time)
%
% No specialist toolbox is required: the script uses readmatrix, conv and svd.\n% This corrected version requires only synthetic_uwb_cir.csv.

clear; close all; clc;

%% 1. LOAD DEMONSTRATION DATA
% Only synthetic_uwb_cir.csv is required for this corrected version.
% Keep this .m file and the CSV in the same folder.

rawFile = 'synthetic_uwb_cir.csv';

% Build a path relative to the script so MATLAB does not depend on the
% current working directory.
scriptFolder = fileparts(mfilename('fullpath'));
if isempty(scriptFolder)
    scriptFolder = pwd;
end
rawPath = fullfile(scriptFolder,rawFile);

if ~isfile(rawPath)
    error(['Cannot find ',rawFile,'. Put synthetic_uwb_cir.csv in the same ', ...
           'folder as this MATLAB script.']);
end

rawCSV = readmatrix(rawPath,'NumHeaderLines',1);
rangeAxis = rawCSV(:,1);             % metres
raw = rawCSV(:,2:end);               % [range bins x frames]

[nRange,nFrames] = size(raw);

% Synthetic slow-time axis used only for the demonstration.
framePeriod = 0.10;                   % 10 frames/s
timeAxis = (0:nFrames-1)'*framePeriod;

% Illustrative synthetic target trajectory used only for validation.
% Replace this with your measured ground-truth range for real experiments.
groundTruthRange = 3.35 + 0.18*sin(2*pi*0.20*timeAxis);

% Build a data-derived pulse template from the strongest static return.
% This avoids requiring the missing reference_pulse.csv file.
meanProfile = mean(raw,2);
[~,templateCentre] = max(abs(meanProfile));
halfWidth = 8;
lo = max(1,templateCentre-halfWidth);
hi = min(nRange,templateCentre+halfWidth);
referencePulse = meanProfile(lo:hi);
referencePulse = referencePulse - mean(referencePulse);
referencePulse = referencePulse ./ (norm(referencePulse) + eps);

fprintf('Loaded %d range samples x %d frames.\n',nRange,nFrames);

%% 2. MATCHED FILTERING
% The optimum matched-filter impulse response is the time-reversed complex
% conjugate of the known reference signal.
hMF = flipud(conj(referencePulse));
matched = zeros(size(raw));

for frame = 1:nFrames
    matched(:,frame) = conv(raw(:,frame),hMF,'same');
end

%% 3. SVD STATIC-CLUTTER REMOVAL
% X = U*S*V'. In a stationary environment, strong direct-path leakage and
% wall reflections are highly correlated from frame to frame and tend to
% dominate the first singular component(s).
[U,S,V] = svd(matched,'econ');

% Start conservatively with k = 1. Removing too many components can remove
% slow human motion as well, so k should be tuned using real measurements.
kClutter = 1;
clutterEstimate = U(:,1:kClutter) * S(1:kClutter,1:kClutter) * V(:,1:kClutter)';
processed = matched - clutterEstimate;

%% 4. SIMPLE VALIDATION METRICS
% These metrics use the supplied synthetic ground truth. For real testing,
% replace groundTruthRange with the measured tape/laser range to the subject.
meanTrueRange = mean(groundTruthRange);

% Estimate the strongest return outside the near-field/direct-leakage region.
searchMask = rangeAxis >= 0.8 & rangeAxis <= 5.0;
searchBins = find(searchMask);

rawPower       = mean(abs(raw).^2,2);
matchedPower   = mean(abs(matched).^2,2);
processedPower = mean(abs(processed).^2,2);

[~,iRawLocal] = max(rawPower(searchBins));
[~,iProcLocal] = max(processedPower(searchBins));
rawPeakBin = searchBins(iRawLocal);
processedPeakBin = searchBins(iProcLocal);

rawRangeEstimate = rangeAxis(rawPeakBin);
processedRangeEstimate = rangeAxis(processedPeakBin);
rawRangeError = abs(rawRangeEstimate - meanTrueRange);
processedRangeError = abs(processedRangeEstimate - meanTrueRange);

% Known target-bin SNR comparison for the synthetic validation dataset.
% The 4.6-5.8 m interval contains noise only in this generated example.
noiseMask = rangeAxis >= 4.6 & rangeAxis <= 5.8;
targetSamplesRaw = zeros(nFrames,1);
targetSamplesMF  = zeros(nFrames,1);
for frame = 1:nFrames
    [~,targetBin] = min(abs(rangeAxis-groundTruthRange(frame)));
    targetSamplesRaw(frame) = abs(raw(targetBin,frame));
    targetSamplesMF(frame)  = abs(matched(targetBin,frame));
end
rawNoise = raw(noiseMask,:);
mfNoise  = matched(noiseMask,:);
rawTargetSNR = 20*log10(rmsLocal(targetSamplesRaw) / (std(rawNoise(:)) + eps));
mfTargetSNR  = 20*log10(rmsLocal(targetSamplesMF)  / (std(mfNoise(:))  + eps));

% In the supplied synthetic data the strong wall return is at approximately
% 1.22 m. For real data, obtain wallBin from an empty-room/wall-only baseline.
[~,wallBin] = min(abs(rangeAxis-1.2235294118));
wallPowerMF = mean(abs(matched(wallBin,:)).^2);
wallPowerProcessed = mean(abs(processed(wallBin,:)).^2);
wallSuppression_dB = 10*log10((wallPowerMF+eps)/(wallPowerProcessed+eps));

[~,targetMeanBin] = min(abs(rangeAxis-meanTrueRange));
targetToWallSCR_dB = 10*log10((processedPower(targetMeanBin)+eps) / ...
                              (processedPower(wallBin)+eps));

fprintf('\n--- Processing summary ---\n');
fprintf('Mean simulated target range       : %.3f m\n',meanTrueRange);
fprintf('Raw strongest-return estimate     : %.3f m (error %.3f m)\n', ...
        rawRangeEstimate,rawRangeError);
fprintf('MF + SVD range estimate           : %.3f m (error %.3f m)\n', ...
        processedRangeEstimate,processedRangeError);
fprintf('Raw target SNR                    : %.2f dB\n',rawTargetSNR);
fprintf('Matched-filter target SNR         : %.2f dB\n',mfTargetSNR);
fprintf('Matched-filter SNR improvement    : %.2f dB\n',mfTargetSNR-rawTargetSNR);
fprintf('SVD wall-clutter suppression      : %.2f dB\n',wallSuppression_dB);
fprintf('MF + SVD target-to-wall SCR       : %.2f dB\n',targetToWallSCR_dB);

%% 5. FIGURE: RANGE PROFILE BEFORE/AFTER PROCESSING
% Each profile is normalized to its own maximum so the location of the
% dominant return can be compared directly.
rawProfile_dB = 10*log10(rawPower/(max(rawPower)+eps)+eps);
mfProfile_dB  = 10*log10(matchedPower/(max(matchedPower)+eps)+eps);
svdProfile_dB = 10*log10(processedPower/(max(processedPower)+eps)+eps);

figure('Name','Matched Filter and SVD Range Profiles');
plot(rangeAxis,rawProfile_dB,'LineWidth',1.2); hold on;
plot(rangeAxis,mfProfile_dB,'LineWidth',1.2);
plot(rangeAxis,svdProfile_dB,'LineWidth',1.5);
xline(rangeAxis(wallBin),'--','Wall');
xline(meanTrueRange,':','Mean target range');
grid on; xlim([0 5]); ylim([-25 2]);
xlabel('Range (m)'); ylabel('Normalized mean power (dB)');
title('Raw vs matched-filtered vs matched-filter + SVD');
legend('Raw','Matched filtered','Matched filter + SVD','Location','best');

%% 6. FIGURE: RANGE-SLOW-TIME HEATMAP AFTER SVD
figure('Name','SVD Residual Heatmap');
imagesc(timeAxis,rangeAxis,abs(processed)); axis xy;
hold on;
plot(timeAxis,groundTruthRange,'w','LineWidth',1.2);
xlabel('Slow time (s)'); ylabel('Range (m)');
title('SVD residual: moving target after static-clutter suppression');
colorbar;
ylim([0 5]);

%% 7. FIGURE: SINGULAR VALUES
singularValues = diag(S);
figure('Name','SVD Singular Values');
plot(1:min(25,numel(singularValues)), ...
     20*log10(singularValues(1:min(25,end))/(singularValues(1)+eps)+eps), ...
     '-o','LineWidth',1.2,'MarkerSize',4);
grid on;
xlabel('Singular-value index'); ylabel('Relative magnitude (dB)');
title('Dominant singular mode associated with static clutter');

%% 8. HOW TO USE YOUR REAL DATA
% DW1000 CIR pathway:
%   - Export many repeated CIR captures, preferably complex I/Q if available.
%   - Build matrix X where each column is one CIR frame.
%   - Apply SVD directly to X (or to a calibrated/normalized version of X).
%   - Use an empty-room or wall-only baseline to identify stationary clutter.
%
% MSO/raw waveform pathway:
%   - Export each captured waveform to a column of X.
%   - Capture a clean reference pulse with a short LOS path.
%   - Use that pulse as referencePulse for the matched filter.
%   - Apply SVD to repeated matched-filter outputs to remove stationary wall
%     and environmental returns.
%
% Recommended experimental datasets:
%   A) Empty room / no wall / no human       (noise baseline)
%   B) Wall only / no human                  (static-clutter baseline)
%   C) Wall + stationary human               (presence baseline)
%   D) Wall + forward/backward body motion   (current easiest target)
%   E) Repeat D at 1 m, 2 m and 3 m behind wall, >=100 frames per run
%
% Report performance using range MAE, target SNR, signal-to-clutter ratio
% (SCR), detection rate and false-alarm rate rather than only visual plots.

%% LOCAL FUNCTION
function value = rmsLocal(x)
    value = sqrt(mean(abs(x).^2));
end
