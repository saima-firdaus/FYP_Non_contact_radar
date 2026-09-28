% cir_live_capture.m
%
% Live-captures DW1000 CIR frames from the ESP32 anchor over serial, parses
% them, saves the data to CSV, and plots the channel impulse response.
%
% ONE RUN = ONE EXPERIMENT. Opening the serial port pulls DTR/RTS and resets
% the ESP32, so its AGC and oscillator restart from scratch every time the
% port is reopened. That restart moves the CIR by far more than a human body
% does, which is why a "background" run and a "target present" run captured
% as two separate script invocations cannot be subtracted from each other.
% Instead this script captures both conditions inside a single continuous
% session and labels them by elapsed time:
%
%   t = 0 .. WALK_PROMPT_AT_S                    background (empty scene)
%   .. + WALK_DURATION_S                         break: walk to your mark
%                                                (captured, but discarded)
%   .. CAPTURE_SECONDS                           phase 2 (target present)
%
% The break is announced with a plain fprintf, never pause(), because the
% board keeps streaming the whole time - blocking the read loop would let the
% serial buffer overflow and drop frames.
%
% Every run creates its own output folder named Capture_yyyymmdd_HHMMSS so
% that repeated captures never overwrite each other:
%
%   Capture_yyyymmdd_HHMMSS/
%     02_lde_aligned/           <- everything referenced to the LDE first path
%       frame_0000_aligned.csv    one CSV per frame, on the FP-relative axis
%       cir_mean.csv              the frame-average over the whole session
%     frame_metadata.csv        header values (RX_TS, FP_INDEX, ...) per frame
%     session_info.csv          the phase timings this run actually used
%     cir_plot.png              the figure below
%     cir_plot.fig              editable MATLAB figure
%
% 02_lde_aligned columns (accumulator samples, re-referenced to the first path):
%   sample            absolute accumulator index (for traceability/debugging)
%   taps_from_fp      sample - FP_INDEX, i.e. taps relative to the first path
%   amplitude         |I+jQ|, raw accumulator magnitude
%   amplitude_norm    amplitude / RXPACC
%
% This stage is deliberately on a raw tap axis only: no ranging, no distance
% conversion, no reflector geometry. The question it answers is simply
% "does a human put a detectable peak anywhere in the CIR".
%
% Split the session into its phases and compare them with
% cir_phase_analysis.m; compare a trial against an empty-room control with
% cir_compare_trial.m.
%
% Expects the header line emitted by the corrected anchor sketch:
%   # FRAME,3,RX_TS,123456789,FP_INDEX,748.34,FP_INT,748,RXPACC,1024,RXPWR,-62.1,START,728
%   sample,real,imag,amplitude,amplitude_norm
%   ... rows ...
%   # END
%
% Usage: set PORT and RUN_LABEL below, then run.

PORT             = "COM4";
BAUD             = 921600;      % must match Serial.begin() in the sketch
CAPTURE_SECONDS  = 30;      % 10 s background + 10 s break + 10 s phase 2
STARTUP_DELAY_S  = 10;          % time to let the anchor boot before listening
OUTPUT_ROOT      = pwd;         % parent directory for the Capture_* folders

% ---- Phases within this one session --------------------------------------
% Background runs from t=0 to WALK_PROMPT_AT_S. The next WALK_DURATION_S
% seconds are the break: those frames are still read and saved (the port is
% never left undrained) but cir_phase_analysis.m throws them away, because
% that is when you are walking through the scene. Phase 2 is everything after
% the break, up to CAPTURE_SECONDS.
%
% Leave enough phase-2 time to be worth averaging: with the anchor blinking
% at roughly 10 Hz, 10 s is ~100 frames, though the true count always varies.
WALK_PROMPT_AT_S = 10;          % background ends here
WALK_DURATION_S  = 10;          % break length; walk to your mark in this window

% ---- Bookkeeping ---------------------------------------------------------
% Free-text label for this run. It changes nothing about the capture, it just
% lands in session_info.csv so a folder full of timestamps is still readable
% six weeks later. Examples: "trial1_human_2m_los", "control_empty".
%RUN_LABEL        = "trial1_human_2m_los";
RUN_LABEL        = "ch5_sep1m_d3m";

% ---- Subdirectory names --------------------------------------------------
% Change these if you prefer different labels. The numeric prefix just keeps
% it in a sensible order in the file browser.
ALIGNED_SUBDIR   = '02_lde_aligned';

% ---- Geometry ------------------------------------------------------------
% Straight-line distance between the tag and the anchor, in metres. Recorded
% in frame_metadata.csv for traceability only - nothing in this pipeline
% computes from it any more, since this stage stays on the raw tap axis.
TAG_ANCHOR_DIST_M = 1;

% ---- Plot ----------------------------------------------------------------
% The figure reproduces Figure 1 of Qorvo APS006 Part 3: one frame's CIR on
% the absolute accumulator axis, with the three reported LDE diagnostics
% drawn on top - first path (red), peak path (black diamond) and the noise
% threshold (cyan).
%
% Amplitudes are the RAW accumulator magnitude |I+jQ|, not amplitude/RXPACC.
% That is what the application note plots, it puts the y-axis on the same
% x10^4 scale, and it is the only scale on which STD_NOISE x NTM is a
% meaningful threshold.
ANCHOR_ID        = 1;           % for the title, e.g. "Anchor 5  Blink 215"
PLOT_FRAME       = [];          % frame number to plot; [] = the first one

% Absolute accumulator taps to display. Empty auto-fits to the captured
% window. Must lie inside what the sketch captured (CIR_BEFORE_FP /
% CIR_AFTER_FP), otherwise you are zooming into a region never transmitted.
PLOT_TAP_MIN     = [];
PLOT_TAP_MAX     = [];

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

% A break that starts after the capture has already ended, or one that eats
% the whole session, leaves phase 2 empty and the run is wasted. Catch it now
% rather than after standing in a room for half a minute.
if WALK_PROMPT_AT_S + WALK_DURATION_S >= CAPTURE_SECONDS
    error(['No time left for phase 2: WALK_PROMPT_AT_S (%g) + ' ...
           'WALK_DURATION_S (%g) must be less than CAPTURE_SECONDS (%g).'], ...
           WALK_PROMPT_AT_S, WALK_DURATION_S, CAPTURE_SECONDS);
end

% NOTE: the original script called delay(30000), which is an Arduino
% function, not a MATLAB one. pause() takes seconds.
if STARTUP_DELAY_S > 0
    fprintf("Waiting %d s before opening the port...\n", STARTUP_DELAY_S);
    pause(STARTUP_DELAY_S);
end

% ---- Output folders for this run ----------------------------------------
runStamp   = datestr(now, 'yyyymmdd_HHMMSS');   %#ok<TNOW1,DATST>
outDir     = fullfile(OUTPUT_ROOT, ['Capture_' runStamp]);
alignedDir = fullfile(outDir, ALIGNED_SUBDIR);

for d = {outDir, alignedDir}
    if ~exist(d{1}, 'dir')
        mkdir(d{1});
    end
end
fprintf("Saving this capture to %s\n", outDir);
fprintf("  LDE-aligned data   -> %s\n", ALIGNED_SUBDIR);
fprintf("  run label          -> %s\n", RUN_LABEL);

% ---- Session description -------------------------------------------------
% Written before the port is even opened, so that a run interrupted halfway
% still leaves behind the phase boundaries its frames were timed against.
% cir_phase_analysis.m reads this instead of asking you to retype the
% timings, which is the only way the two can never disagree.
sessionT = table( ...
    string(RUN_LABEL), string(runStamp), CAPTURE_SECONDS, WALK_PROMPT_AT_S, ...
    WALK_DURATION_S, TAPS_BEFORE_FP, TAPS_AFTER_FP, MEAN_GRID_STEP, ...
    TAP_TO_METRES, string(PORT), BAUD, string(ALIGNED_SUBDIR), ...
    'VariableNames', {'run_label','run_stamp','capture_seconds', ...
        'walk_prompt_at_s','walk_duration_s','taps_before_fp','taps_after_fp', ...
        'mean_grid_step','tap_to_metres','port','baud','aligned_subdir'});
writetable(sessionT, fullfile(outDir, 'session_info.csv'));
fprintf("  phases             -> background 0-%gs | break %g-%gs | phase2 %g-%gs\n", ...
    WALK_PROMPT_AT_S, WALK_PROMPT_AT_S, WALK_PROMPT_AT_S + WALK_DURATION_S, ...
    WALK_PROMPT_AT_S + WALK_DURATION_S, CAPTURE_SECONDS);

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

walkAnnounced   = false;
phase2Announced = false;
breakEndsAt     = WALK_PROMPT_AT_S + WALK_DURATION_S;

tStart = tic;
while true
    elapsed = toc(tStart);
    if elapsed >= CAPTURE_SECONDS, break; end

    % ---- Phase cues -----------------------------------------------------
    % Printed, never paused. These sit above the NumBytesAvailable check so
    % that a quiet moment on the port cannot swallow the cue, and the loop
    % carries straight on into readline() either way - the board is still
    % streaming while you walk, and those frames still get saved.
    if ~walkAnnounced && elapsed >= WALK_PROMPT_AT_S
        fprintf("\n>>> Walk to your position now, stand still by t=%gs.\n", ...
            breakEndsAt);
        fprintf(">>> (frames from %gs to %gs are captured but discarded)\n\n", ...
            WALK_PROMPT_AT_S, breakEndsAt);
        walkAnnounced = true;
    end
    if ~phase2Announced && elapsed >= breakEndsAt
        fprintf("\n>>> PHASE 2 - hold still until t=%gs.\n\n", CAPTURE_SECONDS);
        phase2Announced = true;
    end

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
        % Host-side arrival time, which is what the phases are defined
        % against. The ESP32 knows nothing about it and needs no change.
        kv.elapsed_s = toc(tStart);
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
ks = sort(cell2mat(frames.keys));
plotFrame = struct('n', NaN, 'sample', [], 'amp', []);
metaRows    = {};
nIncomplete = 0;

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

    % ---- Align on the LDE first path -------------------------------------
    % FP_INDEX is fractional and moves frame to frame, so the absolute
    % accumulator index is not a common axis. Subtracting it is what makes
    % frames addable; it is not a distance conversion, and nothing further
    % is derived from it at this stage.
    tapsFromFP = data(:,1) - m.FP_INDEX;

    % ---- Save the aligned frame into the aligned subdirectory ------------
    % sample is kept purely for traceability: with no raw file written any
    % more, it is the only way back to the accumulator index when a frame
    % looks wrong.
    alignedT = table(data(:,1), tapsFromFP, data(:,4), data(:,5), ...
        'VariableNames', {'sample','taps_from_fp','amplitude','amplitude_norm'});
    alignedName = sprintf('frame_%04d_aligned.csv', k);
    writetable(alignedT, fullfile(alignedDir, alignedName));

    fprintf("Saved %s (%d samples, t=%.1fs, FP_INDEX=%.2f, RXPACC=%d, RXPWR=%.1f dBm)\n", ...
        alignedName, height(alignedT), m.elapsed_s, m.FP_INDEX, m.RXPACC, m.RXPWR);

    mr = m;
    mr.tag_anchor_dist_m = TAG_ANCHOR_DIST_M;
    mr.n_samples   = height(alignedT);
    mr.aligned_csv = string(fullfile(ALIGNED_SUBDIR, alignedName));
    metaRows{end+1} = mr; %#ok<SAGROW>

    % ---- Keep one frame aside for the APS006-style figure ----------------
    % Raw magnitude, not amplitude/RXPACC: the noise threshold is in raw
    % accumulator units and has to be plotted against the same scale.
    if (isempty(PLOT_FRAME) && isnan(plotFrame.n)) || isequal(PLOT_FRAME, k)
        plotFrame.n      = k;
        plotFrame.sample = data(:,1);
        plotFrame.amp    = data(:,4);
        plotFrame.meta   = m;
    end

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
% Whole-session average, phases and all. It is a sanity check on the capture,
% not the experiment: the background/phase-2 split that actually answers the
% question is done by cir_phase_analysis.m.
nFrames = size(ampGrid, 2);

if nFrames > 0
    nPerPoint = sum(~isnan(ampGrid), 2);
    muAmp     = mean(ampGrid, 2, 'omitnan');
    sdAmp     = std(ampGrid, 0, 2, 'omitnan');
    muAmp(nPerPoint == 0) = NaN;
    sdAmp(nPerPoint <  2) = NaN;

    % --- Save the averaged trace alongside the per-frame aligned files ---
    meanT = table(gTaps, muAmp, sdAmp, nPerPoint, ...
        'VariableNames', {'taps_from_fp', ...
                          'amplitude_norm_mean','amplitude_norm_sd','n_frames'});
    writetable(meanT, fullfile(alignedDir, 'cir_mean.csv'));
    fprintf("Saved %s (%d grid points, %d frames averaged)\n", ...
        fullfile(ALIGNED_SUBDIR, 'cir_mean.csv'), height(meanT), nFrames);
end

% =========================================================================
%  FIGURE - Qorvo APS006 Part 3, Figure 1
% =========================================================================
% One frame's CIR on the absolute accumulator axis, with the LDE's own
% reported diagnostics drawn on top:
%   Rep:Fp          red vertical line at FP_INDEX
%   Rep:Peak        black diamond at LDE_PPINDX
%   Rep: Noise Level  cyan horizontal line at STD_NOISE x NTM
if isnan(plotFrame.n)
    warning('No complete frame available to plot.');
    fig = figure('Color','w');
else
    if ~isfield(plotFrame.meta, 'STD_NOISE')
        fprintf(['No STD_NOISE in this capture - the noise level line will ' ...
                 'be omitted.\nReflash the anchor with the updated ' ...
                 'ESP32_UWB_NLOS_anchor.ino to record it.\n']);
    end
    fig = plot_cir_aps006(plotFrame.sample, plotFrame.amp, plotFrame.meta, ...
        struct('anchorId', ANCHOR_ID, 'blink', plotFrame.n, ...
               'tapMin', PLOT_TAP_MIN, 'tapMax', PLOT_TAP_MAX));
    fprintf('Plotted frame %d (%d samples)\n', ...
        plotFrame.n, numel(plotFrame.sample));
end

% ---- Per-frame metadata summary -----------------------------------------
% Stays at the top level of the capture folder because it describes the whole
% run, and points at the aligned file for each frame. The elapsed_s column
% added at header-parse time is what cir_phase_analysis.m splits on.
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
    if ~isempty(PLOT_TAP_MIN) && ~isempty(PLOT_TAP_MAX) && ...
       (fpMax + TAPS_AFTER_FP < PLOT_TAP_MIN || fpMin - TAPS_BEFORE_FP > PLOT_TAP_MAX)
        warning(['The captured taps fall outside [%d %d]. Check that ' ...
                 'CIR_BEFORE_FP/CIR_AFTER_FP in the sketch match this script.'], ...
                 PLOT_TAP_MIN, PLOT_TAP_MAX);
    end

    % ---- How the frames actually fell across the phases ------------------
    % Never assume a fixed count: the blink rate wanders and truncated frames
    % are dropped, so both windows end up with whatever they end up with.
    el    = metaTable.elapsed_s;
    nBg   = sum(el <  WALK_PROMPT_AT_S);
    nWalk = sum(el >= WALK_PROMPT_AT_S & el < WALK_PROMPT_AT_S + WALK_DURATION_S);
    nP2   = sum(el >= WALK_PROMPT_AT_S + WALK_DURATION_S);
    fprintf("Frames per phase: background %d | break %d (discarded) | phase2 %d\n", ...
        nBg, nWalk, nP2);
    if nBg == 0 || nP2 == 0
        warning(['One of the phases captured no frames - this run cannot be ' ...
                 'differenced. Check the anchor was blinking throughout.']);
    end
else
    warning('No complete frames were captured - only the empty figure was saved.');
end

exportgraphics(fig, fullfile(outDir, 'cir_plot.png'), 'Resolution', 200);
savefig(fig, fullfile(outDir, 'cir_plot.fig'));

fprintf("Done. All output written to %s\n", outDir);
fprintf("Next: cir_phase_analysis('%s')\n", outDir);