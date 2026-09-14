% cir_live_capture.m
%
% Live-captures DW1000 CIR frames from the ESP32 anchor over serial, parses
% them, saves the data to CSV, and plots the channel impulse response.
%
% Every run creates its own output folder named Capture_yyyymmdd_HHMMSS so
% that repeated captures never overwrite each other. Inside that folder the
% data is split into two subdirectories:
%
%   Capture_yyyymmdd_HHMMSS/
%     01_raw_frames/            <- exactly what the serial monitor sent
%       frame_0000.csv ...        one CSV per captured frame
%     02_lde_aligned/           <- everything referenced to the LDE first path
%       frame_0000_aligned.csv    one CSV per frame, on the FP-relative axis
%       cir_mean.csv              the frame-averaged CIR plotted in panels 2/3
%     frame_metadata.csv        header values (RX_TS, FP_INDEX, ...) per frame
%     cir_plot.png              the figure below
%     cir_plot.fig              editable MATLAB figure
%
% 01_raw_frames columns (untouched accumulator data):
%   sample            absolute accumulator index
%   real, imag        raw accumulator I/Q
%   amplitude         |I+jQ|
%   amplitude_norm    amplitude / RXPACC
%
% 02_lde_aligned columns (same samples, re-referenced to the first path):
%   sample            absolute accumulator index (traces back to the raw file)
%   taps_from_fp      sample - FP_INDEX, i.e. taps relative to the first path
%   excess_path_m     extra distance travelled vs the direct path
%   reflector_off_m   perpendicular offset of the reflector from the midpoint
%                     of the tag-anchor line (see ellipse geometry below)
%   amplitude, amplitude_norm
%
% Expects the header line emitted by the corrected anchor sketch:
%   # FRAME,3,RX_TS,123456789,FP_INDEX,748.34,FP_INT,748,RXPACC,1024,RXPWR,-62.1,START,728
%   sample,real,imag,amplitude,amplitude_norm
%   ... rows ...
%   # END
%
% Usage: set PORT and TAG_ANCHOR_DIST_M below, then run.

PORT             = "COM4";
BAUD             = 921600;      % must match Serial.begin() in the sketch
CAPTURE_SECONDS  = 30;
STARTUP_DELAY_S  = 10;          % time to let the anchor boot before listening
OUTPUT_ROOT      = pwd;         % parent directory for the Capture_* folders

% ---- Subdirectory names --------------------------------------------------
% Change these if you prefer different labels. The numeric prefixes just keep
% them in a sensible order in the file browser.
RAW_SUBDIR       = '01_raw_frames';
ALIGNED_SUBDIR   = '02_lde_aligned';

% ---- Geometry ------------------------------------------------------------
% Straight-line distance between the tag and the anchor, in metres. MEASURE
% THIS for every capture - the reflector-offset conversion below is wrong if
% it is wrong, and it is recorded in frame_metadata.csv for traceability.
TAG_ANCHOR_DIST_M = 0.6;

% ---- Plot window ---------------------------------------------------------
% Absolute accumulator taps to display in the top axes. Must lie inside what
% the sketch actually captured (CIR_BEFORE_FP / CIR_AFTER_FP), otherwise you
% are zooming into a region the anchor never transmitted.
PLOT_TAP_MIN     = 720;
PLOT_TAP_MAX     = 850;

% Taps either side of the LDE first path for the aligned axes.
TAPS_BEFORE_FP   = 50;          % matches CIR_BEFORE_FP
TAPS_AFTER_FP    = 100;         % matches CIR_AFTER_FP

% One accumulator tap = 1.0016 ns = 30.028 cm of propagation.
TAP_TO_METRES    = 0.30028;

% ---- Frame averaging -----------------------------------------------------
% FP_INDEX is fractional and differs frame to frame, so the frames do not
% share a common delay axis. Each frame is resampled onto this uniform grid
% of taps-relative-to-FP before averaging.
MEAN_GRID_STEP   = 0.5;         % taps
SHOW_STD_BAND    = true;        % shade +/- 1 standard deviation

% NOTE: the original script called delay(30000), which is an Arduino
% function, not a MATLAB one. pause() takes seconds.
if STARTUP_DELAY_S > 0
    fprintf("Waiting %d s before opening the port...\n", STARTUP_DELAY_S);
    pause(STARTUP_DELAY_S);
end

% ---- Output folders for this run ----------------------------------------
runStamp   = datestr(now, 'yyyymmdd_HHMMSS');   %#ok<TNOW1,DATST>
outDir     = fullfile(OUTPUT_ROOT, ['Capture_' runStamp]);
rawDir     = fullfile(outDir, RAW_SUBDIR);
alignedDir = fullfile(outDir, ALIGNED_SUBDIR);

for d = {outDir, rawDir, alignedDir}
    if ~exist(d{1}, 'dir')
        mkdir(d{1});
    end
end
fprintf("Saving this capture to %s\n", outDir);
fprintf("  raw serial frames  -> %s\n", RAW_SUBDIR);
fprintf("  LDE-aligned data   -> %s\n", ALIGNED_SUBDIR);

% ---- Serial capture ------------------------------------------------------
s = serialport(PORT, BAUD);
configureTerminator(s, "LF");
flush(s);
cleanupPort = onCleanup(@() clear('s'));   % close the port even on error/Ctrl-C

fprintf("Listening on %s for %d seconds...\n", PORT, CAPTURE_SECONDS);

frames   = containers.Map('KeyType','double','ValueType','any');
meta     = containers.Map('KeyType','double','ValueType','any');
complete = containers.Map('KeyType','double','ValueType','any');
currentFrame = NaN;
nRejected    = 0;

tStart = tic;
while toc(tStart) < CAPTURE_SECONDS
    if s.NumBytesAvailable == 0, continue; end
    line = strtrim(readline(s));
    if line == "", continue; end

    % ---- Frame header ----
    if startsWith(line, "# FRAME")
        parts = strsplit(line, ",");
        kv = struct();
        for k = 1:2:numel(parts)-1
            key = strtrim(erase(parts(k), "#"));
            kv.(matlab.lang.makeValidName(key)) = str2double(parts(k+1));
        end
        currentFrame = kv.FRAME;
        frames(currentFrame)   = zeros(0,5);
        meta(currentFrame)     = kv;
        complete(currentFrame) = false;
        continue
    end

    % ---- Frame terminator: only frames that reach this are trustworthy ----
    if startsWith(line, "# END")
        if ~isnan(currentFrame)
            complete(currentFrame) = true;
        end
        currentFrame = NaN;
        continue
    end

    if startsWith(line, "#") || startsWith(line, "sample,")
        continue
    end

    vals = str2double(strsplit(line, ","));
    if isnan(currentFrame) || numel(vals) ~= 5 || any(isnan(vals))
        nRejected = nRejected + 1;
        continue
    end

    % Sanity check on the absolute sample index. A byte dropped at 921600 baud
    % can splice two rows together and still parse as five numbers.
    m = meta(currentFrame);
    if vals(1) < m.START || vals(1) > m.START + 1024 || mod(vals(1),1) ~= 0
        nRejected = nRejected + 1;
        continue
    end

    frames(currentFrame) = [frames(currentFrame); vals];
end

clear cleanupPort s

if nRejected > 0
    fprintf("Discarded %d malformed sample line(s).\n", nRejected);
end

% ---- Save + plot ---------------------------------------------------------
fig = figure('Position',[100 60 900 950]);
tiledlayout(3,1);

ax1 = nexttile; hold(ax1,'on'); grid(ax1,'on');   % absolute tap, every frame
ax2 = nexttile; hold(ax2,'on'); grid(ax2,'on');   % excess path length, mean
ax3 = nexttile; hold(ax3,'on'); grid(ax3,'on');   % reflector offset, mean

ks = sort(cell2mat(frames.keys));
metaRows    = {};
nIncomplete = 0;
D           = TAG_ANCHOR_DIST_M;
c           = D / 2;                              % half the focal separation

% Common delay grid for averaging, in taps relative to the first path.
gTaps   = (-TAPS_BEFORE_FP : MEAN_GRID_STEP : TAPS_AFTER_FP)';
ampGrid = [];                                     % one column per frame

for k = ks
    data = frames(k);
    if isempty(data), continue; end

    % Skip frames that were cut off by the end of the capture window.
    if ~complete(k)
        nIncomplete = nIncomplete + 1;
        continue
    end

    m    = meta(k);
    data = sortrows(data, 1);

    % ---- Save the untouched frame into the raw subdirectory --------------
    rawT = array2table(data, 'VariableNames', ...
        {'sample','real','imag','amplitude','amplitude_norm'});
    rawName = sprintf('frame_%04d.csv', k);
    writetable(rawT, fullfile(rawDir, rawName));

    % ---- Excess path length, referenced to the LDE first path ------------
    tapsFromFP = data(:,1) - m.FP_INDEX;
    excess     = tapsFromFP * TAP_TO_METRES;      % tau, metres

    % ---- Ellipse geometry: excess delay -> reflector offset --------------
    % A multipath component arriving tau later than the direct path travelled
    % tag -> reflector -> anchor = D + tau in total. Every point with that
    % total path length lies on an ellipse whose foci are the tag and the
    % anchor, with semi-major axis a = (D + tau)/2. The semi-minor axis
    %   b = sqrt(a^2 - (D/2)^2)
    % is the perpendicular distance from the midpoint of the tag-anchor line
    % out to that ellipse.
    a = (excess + D) / 2;
    b = sqrt(max(a.^2 - c^2, 0));
    b(excess < 0) = NaN;                          % pre-arrival noise

    % ---- Save the aligned frame into the aligned subdirectory ------------
    alignedT = table(data(:,1), tapsFromFP, excess, b, data(:,4), data(:,5), ...
        'VariableNames', {'sample','taps_from_fp','excess_path_m', ...
                          'reflector_off_m','amplitude','amplitude_norm'});
    alignedName = sprintf('frame_%04d_aligned.csv', k);
    writetable(alignedT, fullfile(alignedDir, alignedName));

    fprintf("Saved %s + %s (%d samples, FP_INDEX=%.2f, RXPACC=%d, RXPWR=%.1f dBm)\n", ...
        rawName, alignedName, height(rawT), m.FP_INDEX, m.RXPACC, m.RXPWR);

    mr = m;
    mr.tag_anchor_dist_m = D;
    mr.n_samples   = height(rawT);
    mr.raw_csv     = string(fullfile(RAW_SUBDIR, rawName));
    mr.aligned_csv = string(fullfile(ALIGNED_SUBDIR, alignedName));
    metaRows{end+1} = mr; %#ok<SAGROW>

    % ---- Top panel keeps every frame, unaveraged -------------------------
    plot(ax1, data(:,1), data(:,4), 'DisplayName', sprintf('Frame %d', k));

    % ---- Resample onto the common grid for the average -------------------
    % Non-coherent (magnitude) averaging: the carrier phase of each path
    % rotates frame to frame, so averaging I/Q would cancel real energy.
    [uTaps, ia] = unique(tapsFromFP);
    ampGrid(:, end+1) = interp1(uTaps, data(ia,5), gTaps, 'linear', NaN); %#ok<SAGROW>
end

if nIncomplete > 0
    fprintf("Skipped %d truncated frame(s) with no # END marker.\n", nIncomplete);
end

% ---- Frame average -------------------------------------------------------
nFrames   = size(ampGrid, 2);
excessG   = gTaps * TAP_TO_METRES;
aG        = (excessG + D) / 2;
bG        = sqrt(max(aG.^2 - c^2, 0));
bG(excessG < 0) = NaN;

if nFrames > 0
    nPerPoint = sum(~isnan(ampGrid), 2);
    muAmp     = mean(ampGrid, 2, 'omitnan');
    sdAmp     = std(ampGrid, 0, 2, 'omitnan');
    muAmp(nPerPoint == 0) = NaN;
    sdAmp(nPerPoint <  2) = NaN;

    % --- Panel 2: mean vs excess path length ---
    v = ~isnan(muAmp);
    if SHOW_STD_BAND && any(~isnan(sdAmp))
        vb = v & ~isnan(sdAmp);
        fill(ax2, [excessG(vb); flipud(excessG(vb))], ...
                  [muAmp(vb)+sdAmp(vb); flipud(max(muAmp(vb)-sdAmp(vb),0))], ...
             [0.2 0.4 0.8], 'FaceAlpha',0.18, 'EdgeColor','none', ...
             'DisplayName','\pm1 SD');
    end
    plot(ax2, excessG(v), muAmp(v), 'b-', 'LineWidth', 1.6, ...
        'DisplayName', sprintf('Mean of %d frames', nFrames));
    legend(ax2, 'Location','northeast');

    % --- Panel 3: mean vs reflector offset ---
    v3 = v & ~isnan(bG);
    if SHOW_STD_BAND && any(~isnan(sdAmp))
        v3b = v3 & ~isnan(sdAmp);
        fill(ax3, [bG(v3b); flipud(bG(v3b))], ...
                  [muAmp(v3b)+sdAmp(v3b); flipud(max(muAmp(v3b)-sdAmp(v3b),0))], ...
             [0.2 0.4 0.8], 'FaceAlpha',0.18, 'EdgeColor','none', ...
             'DisplayName','\pm1 SD');
    end
    plot(ax3, bG(v3), muAmp(v3), 'b-', 'LineWidth', 1.6, ...
        'DisplayName', sprintf('Mean of %d frames', nFrames));
    legend(ax3, 'Location','northeast');

    % --- Save the averaged trace alongside the per-frame aligned files ---
    meanT = table(gTaps, excessG, bG, muAmp, sdAmp, nPerPoint, ...
        'VariableNames', {'taps_from_fp','excess_path_m','reflector_off_m', ...
                          'amplitude_norm_mean','amplitude_norm_sd','n_frames'});
    writetable(meanT, fullfile(alignedDir, 'cir_mean.csv'));
    fprintf("Saved %s (%d grid points, %d frames averaged)\n", ...
        fullfile(ALIGNED_SUBDIR, 'cir_mean.csv'), height(meanT), nFrames);
end

xlabel(ax1, 'Accumulator index (tap)');
ylabel(ax1, 'Amplitude  |I+jQ|');
title(ax1, 'DW1000 CIR - absolute accumulator index (all frames)');
xlim(ax1, [PLOT_TAP_MIN PLOT_TAP_MAX]);

xlabel(ax2, 'Excess path length relative to first path (m)');
ylabel(ax2, 'Amplitude / RXPACC');
title(ax2, sprintf('DW1000 CIR - aligned on LDE first path (mean of %d frames)', nFrames));
xlim(ax2, [-TAPS_BEFORE_FP TAPS_AFTER_FP] * TAP_TO_METRES);
xline(ax2, 0, 'k--', 'first path', ...
    'LabelOrientation','horizontal', 'LabelVerticalAlignment','top', ...
    'HandleVisibility','off');

xlabel(ax3, 'Reflector offset from tag-anchor midline (m)');
ylabel(ax3, 'Amplitude / RXPACC');
title(ax3, sprintf(['DW1000 CIR - ellipse geometry, D = %.2f m ' ...
    '(mean of %d frames)'], D, nFrames));
xlim(ax3, [0 sqrt(((TAPS_AFTER_FP*TAP_TO_METRES + D)/2)^2 - c^2)]);

% ---- Per-frame metadata summary -----------------------------------------
% Stays at the top level of the capture folder because it describes both
% subdirectories, and points at the matching file in each.
if ~isempty(metaRows)
    allFields = {};
    for i = 1:numel(metaRows)
        allFields = union(allFields, fieldnames(metaRows{i}), 'stable');
    end
    for i = 1:numel(metaRows)
        missing = setdiff(allFields, fieldnames(metaRows{i}));
        for f = 1:numel(missing)
            metaRows{i}.(missing{f}) = NaN;
        end
        metaRows{i} = orderfields(metaRows{i}, allFields);
    end
    metaTable = struct2table([metaRows{:}], 'AsArray', true);
    writetable(metaTable, fullfile(outDir, 'frame_metadata.csv'));
    fprintf("Saved frame_metadata.csv (%d frames)\n", height(metaTable));

    fpMin = min(metaTable.FP_INDEX);
    fpMax = max(metaTable.FP_INDEX);
    fprintf("FP_INDEX range this capture: %.2f to %.2f\n", fpMin, fpMax);
    if fpMax + TAPS_AFTER_FP < PLOT_TAP_MIN || fpMin - TAPS_BEFORE_FP > PLOT_TAP_MAX
        warning(['The captured taps fall outside [%d %d]. Check that ' ...
                 'CIR_BEFORE_FP/CIR_AFTER_FP in the sketch match this script.'], ...
                 PLOT_TAP_MIN, PLOT_TAP_MAX);
    end

    % One tap of delay maps to a large offset near tau = 0 and a shrinking
    % one further out, so quote the resolution at the first tap.
    tau1 = TAP_TO_METRES;
    fprintf("One tap (%.3f m excess) = %.3f m reflector offset at tau=0.\n", ...
        tau1, sqrt(((tau1 + D)/2)^2 - c^2));
else
    warning('No complete frames were captured - only the empty figure was saved.');
end

saveas(fig, fullfile(outDir, 'cir_plot.png'));
savefig(fig, fullfile(outDir, 'cir_plot.fig'));

fprintf("Done. All output written to %s\n", outDir);