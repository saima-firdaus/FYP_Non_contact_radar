% CIR LDE alignement because cir capture doesn't save this

% alignFrames.m
% Reads raw CIR frames from bgFolder and objFolder, estimates the first-path
% tap per frame, re-references each frame's sample axis to tapsFromFP, finds
% the common tap range across ALL frames (bg + obj), and writes fixed-length
% aligned CSVs to outputFolder/bg and outputFolder/obj.
% Run once; bgTest.m then just loads the aligned files directly.

close all; clear all; clc;

bgFolder     = 'Test 11/1 - closer to door';
objFolder    = 'Test 11/2 - TX closer to door';
outputFolder = 'Test New - Aligned';

bgOutFolder  = fullfile(outputFolder, 'bg');
objOutFolder = fullfile(outputFolder, 'obj');
if ~exist(bgOutFolder, 'dir'),  mkdir(bgOutFolder);  end
if ~exist(objOutFolder,'dir'),  mkdir(objOutFolder); end

bgFiles  = dir(fullfile(bgFolder,  '*.csv'));
objFiles = dir(fullfile(objFolder, '*.csv'));

noiseWindowLen = 15;   % samples assumed to precede first path — tune to your data
threshFactor   = 6;    % sigma multiplier above noise floor

%% Step 1: read every frame once, estimate FP, compute tapsFromFP
allData = struct('tapsFromFP', {}, 'real', {}, 'imag', {}, ...
                  'amplitude', {}, 'amplitude_norm', {}, ...
                  'srcFolder', {}, 'srcName', {}, 'outFolder', {});

fileGroups = {bgFiles, objFiles};
folders    = {bgFolder, objFolder};
outFolders = {bgOutFolder, objOutFolder};

for g = 1:2
    files = fileGroups{g};
    for k = 1:numel(files)
        T = readtable(fullfile(folders{g}, files(k).name));
        fp = estimateFirstPath(T.sample, T.amplitude, noiseWindowLen, threshFactor);

        entry.tapsFromFP     = T.sample - fp;
        entry.real           = T.real;
        entry.imag           = T.imag;
        entry.amplitude      = T.amplitude;
        entry.amplitude_norm = T.amplitude_norm;
        entry.srcFolder      = folders{g};
        entry.srcName        = files(k).name;
        entry.outFolder      = outFolders{g};

        allData(end+1) = entry; %#ok<SAGROW>
    end
end

%% Step 2: find common tap range across every frame (bg + obj together)
commonTaps = allData(1).tapsFromFP;
for i = 2:numel(allData)
    commonTaps = intersect(commonTaps, allData(i).tapsFromFP);
end

if isempty(commonTaps)
    error('No common taps found across all frames — check FP estimation / noiseWindowLen.');
end
fprintf('Common tap range: %d to %d (%d taps)\n', ...
    min(commonTaps), max(commonTaps), numel(commonTaps));

%% Step 3: re-index every frame onto commonTaps and write aligned CSV
for i = 1:numel(allData)
    d = allData(i);
    [~, idx] = ismember(commonTaps, d.tapsFromFP);
    if any(idx == 0)
        error('Frame %s missing common taps after intersection — should not happen.', d.srcName);
    end

    Taligned = table(commonTaps, d.real(idx), d.imag(idx), ...
                      d.amplitude(idx), d.amplitude_norm(idx), ...
                      'VariableNames', {'tapsFromFP','real','imag','amplitude','amplitude_norm'});

    writetable(Taligned, fullfile(d.outFolder, d.srcName));
end

% Save the common tap axis alongside the data for reference/sanity checks
writematrix(commonTaps, fullfile(outputFolder, 'commonTaps.csv'));

fprintf('Done. Aligned frames written to %s\n', outputFolder);

%% --- helper function ---
function fpIdx = estimateFirstPath(sampleVec, ampVec, noiseWindowLen, threshFactor)
    nw = min(noiseWindowLen, numel(ampVec));
    noiseFloor = mean(ampVec(1:nw));
    noiseStd   = std(ampVec(1:nw));
    thresh = noiseFloor + threshFactor * noiseStd;

    idx = find(ampVec > thresh, 1, 'first');
    if isempty(idx)
        [~, idx] = max(ampVec);
    end
    fpIdx = sampleVec(idx);
end