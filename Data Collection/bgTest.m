% VER 1
% background subtraction code - from raw (aligned to FP) data 
close all
clear all
clc

bgFolder  = 'Test New - Aligned/bg';
objFolder = 'Test New - Aligned/obj';

bgFiles  = dir(fullfile(bgFolder,  '*.csv'));
objFiles = dir(fullfile(objFolder, '*.csv'));

first = readtable(fullfile(bgFolder, bgFiles(1).name));
numSamples = height(first);   % now guaranteed identical across all files

bgReal = zeros(numSamples, numel(bgFiles));
bgImag = zeros(numSamples, numel(bgFiles));

for k = 1:numel(bgFiles)
    T = readtable(fullfile(bgFolder, bgFiles(k).name));
    bgReal(:,k) = T.real;
    bgImag(:,k) = T.imag;
end

meanBgReal = mean(bgReal, 2);
meanBgImag = mean(bgImag, 2);
meanBgComplex = meanBgReal + 1i*meanBgImag;

%% Step 2: Subtract Background from Each Object Frame & Export
numObjFrames = length(objFiles);
subAmplitude = zeros(numSamples, numObjFrames);
for k = 1:numObjFrames
    filePath = fullfile(objFolder, objFiles(k).name);
    T_obj = readtable(filePath);
    
    % Express current frame as complex numbers
    Z_obj = T_obj.real + 1i * T_obj.imag;
    
    % Coherent subtraction
    Z_sub = Z_obj - meanBgComplex;
    
    % Update table variables with residual data
    T_sub = T_obj;
    T_sub.real = real(Z_sub);
    T_sub.imag = imag(Z_sub);
    T_sub.amplitude = abs(Z_sub);
    T_sub.amplitude_norm = T_sub.amplitude / max(T_sub.amplitude);
    subAmplitude(:,k) = T_sub.amplitude;
    % Save subtracted table to the output directory
    % outputPath = fullfile(outputFolder, objFiles(k).name);
    % writetable(T_sub, outputPath);
end
% subAmplitude_norm = subAmplitude / max(subAmplitude(:));

% Plotting
tapsFromFP = first.tapsFromFP;
disp('Background subtraction completed successfully.');

%% Plot
figure(); hold on; grid on;
for k = 1:numObjFrames
    plot(tapsFromFP, subAmplitude(:,k), 'DisplayName', sprintf('Frame %d', k));
end
xlabel('Tap offset from first path');
ylabel('Subtracted amplitude');
title('Background-subtracted amplitude');
xline(0, 'k--', 'first path');
legend('show', 'Location', 'eastoutside');

%% 1. Heatmap / Waterfall Plot (Tap Offset vs. Frame Number)
figure();
imagesc(1:numObjFrames, tapsFromFP, subAmplitude);
axis xy; colormap(jet); colorbar;
xlabel('Frame Number');
ylabel('Tap offset from first path');
title('2D Background-Subtracted Energy');

%% 2. Dynamic (Slow-Time) Subtraction
% Removes static leakage (e.g., tap 0-10 wall residual) across object frames
dynamicSignal = subAmplitude - mean(subAmplitude, 2); % mean(x,2) - the 2 is for dimensions [numSamples × numObjFrames] - difine the fast time and slow time 
dynamicAmplitude = abs(dynamicSignal);

figure();
imagesc(1:numObjFrames, tapsFromFP, dynamicAmplitude);
axis xy; colormap(jet); colorbar;
xlabel('Frame Number');
ylabel('Tap offset from first path');
title('Dynamic Target Track (Static Wall Leakage Removed)');

%% 3. Dynamic Profile Plot
figure(); hold on; grid on;
for k = 1:numObjFrames
    plot(tapsFromFP, dynamicAmplitude(:,k), 'DisplayName', sprintf('Frame %d', k));
end
xlabel('Tap offset from first path');
ylabel('Dynamic amplitude');
title('Dynamic-Only Amplitude per Frame');
xline(0, 'k--', 'first path');
legend('show', 'Location', 'eastoutside');